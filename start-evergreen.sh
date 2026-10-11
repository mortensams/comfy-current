#!/usr/bin/env bash
# Evergreen wrapper for runpod/comfyui.
#
# Runs BEFORE RunPod's official /start.sh and updates the persistent
# installation on the network volume:
#   - ComfyUI core        -> latest upstream master
#   - default custom nodes (from /opt/default-nodes.txt) -> cloned if
#     missing, force-updated to upstream default branch otherwise
#
# Code updates run on every boot. Dependency work (pip, install.py) runs
# only when its inputs change: each repo's requirements.txt / install.py
# content is fingerprinted together with the pip constraints file and the
# image build ID, and the fingerprint of the last *successful* install is
# stored in .evergreen-state on the volume. Matching fingerprint -> skip.
# A new image build (new system site-packages under the venv) changes the
# build ID, so every fingerprint invalidates once per image update.
#
# Every step is best-effort: a failed update must never prevent the pod
# from starting (SSH, Jupyter, FileBrowser and ComfyUI all live behind
# /start.sh, which we always exec at the end).
#
# Escape hatches (pod env):
#   EVERGREEN_SKIP_UPDATE=1  boot whatever is on the volume, untouched
#   EVERGREEN_INSTALL_DEPS   changed (default) | always | never
#   EVERGREEN_MODELS_DIR     global-volume models dir; 'none' to not manage
#   EVERGREEN_MODELS_WAIT    seconds to wait for the mount, default 20

COMFYUI_DIR=/workspace/runpod-slim/ComfyUI
VENV_DIR="$COMFYUI_DIR/.venv-cu128"
BAKED_DIR=/opt/comfyui-baked
CONSTRAINTS_FILE=/opt/comfyui-runtime-constraints.txt
NODES_FILE=/opt/default-nodes.txt
ROLLBACK_FILE=/workspace/runpod-slim/comfyui-previous-commit.txt
STATE_DIR=/workspace/runpod-slim/.evergreen-state
BUILD_ID_FILE=/opt/evergreen-build-id
MODELS_TARGET="${EVERGREEN_MODELS_DIR:-/workspace-global/models}"
MODELS_WAIT="${EVERGREEN_MODELS_WAIT:-20}"

log() { echo "[evergreen] $*"; }

# If a future base image moves these paths, pick up its values instead of
# our hardcoded defaults. /start.sh defines them as plain assignments.
eval "$(grep -E '^(COMFYUI_DIR|VENV_DIR|BAKED_COMFYUI_DIR)=' /start.sh 2>/dev/null)" || true
BAKED_DIR="${BAKED_COMFYUI_DIR:-$BAKED_DIR}"

hand_off() {
    log "Handing off to official /start.sh"
    exec /start.sh
}

# --- models on a RunPod global volume ---------------------------------------
# Global volumes are object-backed: no file locking, no atomic rename, no
# permission bits. A git checkout, a venv and pip all need those, so the
# installation stays on the network volume at /workspace. Only models --
# large, written rarely, read often -- belong on the global volume, which
# the deploy flow mounts at /workspace-global whenever a network volume is
# attached as well.
#
# ComfyUI's models/ must NOT be a symlink to it. ComfyUI git-tracks 36
# files under models/ (the put_*_here placeholders, models/configs/*.yaml),
# so the `git checkout -f` in our own core update below deletes any symlink
# there and restores a real directory -- silently, on every single boot.
# extra_model_paths.yaml is immune: ComfyUI auto-loads it from its root
# (main.py calls load_extra_path_config on it at startup), git never
# touches it because it is untracked, and /start.sh's bundle rsync excludes
# it by name. The local models/ dir then stays exactly as ComfyUI ships it
# and the global volume is searched in addition to it -- no moving, no
# linking, nothing to clobber.

prepare_models_target() {
    [[ -n "$MODELS_TARGET" && "$MODELS_TARGET" != "none" ]] || return 1

    # The mount point itself must already exist; mkdir would otherwise
    # happily create the "global volume" on the local disk.
    local mount_point waited=0
    mount_point="$(dirname "$MODELS_TARGET")"

    # The mount can lag container start, so wait for it -- but only when a
    # volume is genuinely attached there and not yet usable. With no global
    # volume at all the path never appears, and burning MODELS_WAIT seconds
    # on every boot would slow down every pod that does not use one.
    if [[ ! -d "$mount_point" ]] && grep -qs " ${mount_point} " /proc/mounts; then
        log "Waiting up to ${MODELS_WAIT}s for $mount_point to become usable"
        while [[ ! -d "$mount_point" && "$waited" -lt "$MODELS_WAIT" ]]; do
            sleep 1
            waited=$((waited + 1))
        done
    fi
    [[ -d "$mount_point" ]] || return 1
    mkdir -p "$MODELS_TARGET" 2>/dev/null || return 1

    # Give an empty volume the standard category directories so it looks
    # like a models tree and the generated yaml has something to list.
    # Directories only -- copying the shipped configs/*.yaml across would
    # just duplicate files the local tree already has.
    if [[ -z "$(ls -A "$MODELS_TARGET" 2>/dev/null)" ]]; then
        log "Creating the model category directories on $MODELS_TARGET"
        local d
        for d in "$BAKED_DIR"/models/*/; do
            [[ -d "$d" ]] && mkdir -p "$MODELS_TARGET/$(basename "$d")" 2>/dev/null
        done
    fi
    return 0
}

# Generate extra_model_paths.yaml listing every model category on the
# global volume. Deliberately NOT is_default: node auto-downloads keep
# going to the local (fast, POSIX) network volume, while curated weights
# are read from the global one. ComfyUI de-duplicates by relative name, so
# a model present in both places is listed once.
write_extra_model_paths() {
    local root="$1"
    local yaml="$root/extra_model_paths.yaml"
    local tmp="${yaml}.evergreen.$$"
    local cats name

    cats="$(
        for d in "$BAKED_DIR"/models/*/ "$MODELS_TARGET"/*/; do
            [[ -d "$d" ]] && basename "$d"
        done | sort -u
    )"
    if [[ -z "$cats" ]]; then
        log "WARNING: no model categories found under $MODELS_TARGET"
        return 1
    fi

    {
        echo "# Generated by start-evergreen.sh on every boot -- do not edit,"
        echo "# your changes are overwritten. Set EVERGREEN_MODELS_DIR=none"
        echo "# to stop managing this file."
        echo "runpod_global:"
        echo "    base_path: $MODELS_TARGET"
        while IFS= read -r name; do
            [[ -n "$name" ]] && echo "    $name: $name"
        done <<< "$cats"
    } > "$tmp" 2>/dev/null || {
        log "WARNING: could not write $tmp — models stay local-only"
        rm -f "$tmp"
        return 1
    }

    mv "$tmp" "$yaml" 2>/dev/null || {
        log "WARNING: could not install $yaml — models stay local-only"
        rm -f "$tmp"
        return 1
    }
    log "extra_model_paths.yaml -> $MODELS_TARGET ($(wc -l <<< "$cats" | tr -d ' ') categories)"
}

# Undo the symlink earlier versions of this script created at models/.
# The core update's `git checkout -f` destroys it anyway; leaving it would
# also list every model twice, once through the link and once via the yaml.
clear_legacy_models_link() {
    local models="$COMFYUI_DIR/models"
    if [[ -L "$models" ]]; then
        log "Removing legacy models symlink (git restores a real directory anyway)"
        rm -f "$models"
        mkdir -p "$models"
    fi
    # `ln -s <target> .` run from inside models/ creates models/models,
    # which ComfyUI never reads. Clear it so it cannot cause confusion.
    if [[ -L "$models/models" ]]; then
        log "Removing stray $models/models symlink"
        rm -f "$models/models"
    fi
}

# /start.sh provisions a missing $COMFYUI_DIR with `cp -r` and then goes
# straight on to launch ComfyUI -- we never get control in between, so the
# yaml would not exist for the first run. Do that copy here instead, with
# the yaml already in it. /start.sh then finds the directory present and
# skips its own copy; its separate venv check (start.sh:344) still runs.
# Note /start.sh never creates $COMFYUI_DIR's parent, so a genuinely empty
# volume breaks its `cp -r`; the mkdir -p below also covers that.
provision_with_global_models() {
    [[ -d "$COMFYUI_DIR" ]] && return 0
    prepare_models_target || return 0

    local staged="${COMFYUI_DIR}.provisioning.$$"
    log "First boot: provisioning $COMFYUI_DIR"
    mkdir -p "$(dirname "$COMFYUI_DIR")" || return 0
    rm -rf "$staged"
    # Staged, then moved into place: a half-finished copy at $COMFYUI_DIR
    # would make /start.sh skip provisioning forever.
    if ! cp -r "$BAKED_DIR" "$staged"; then
        log "WARNING: staging copy failed — letting /start.sh provision normally"
        rm -rf "$staged"
        return 0
    fi
    write_extra_model_paths "$staged"
    mv "$staged" "$COMFYUI_DIR" || {
        log "WARNING: could not move the staged install into place"
        rm -rf "$staged"
    }
}

# Drop an extra_model_paths.yaml we generated for a global volume that is no
# longer attached. Its paths would simply not exist, and a config that lies
# about where models come from is worse than no config -- ComfyUI reports no
# error for a missing path, it just lists nothing from it.
remove_stale_yaml() {
    local yaml="$COMFYUI_DIR/extra_model_paths.yaml"
    [[ -f "$yaml" ]] || return 0
    # Only ever remove our own file, never a hand-written one.
    head -1 "$yaml" 2>/dev/null | grep -q 'Generated by start-evergreen.sh' || return 0
    rm -f "$yaml" && log "Removed stale extra_model_paths.yaml (no global volume)"
}

wire_global_models() {
    if ! prepare_models_target; then
        if [[ "$MODELS_TARGET" == "none" ]]; then
            log "EVERGREEN_MODELS_DIR=none — not managing extra_model_paths.yaml"
        else
            log "No global volume at $(dirname "$MODELS_TARGET") — models stay on the local volume"
        fi
        [[ -d "$COMFYUI_DIR" ]] && remove_stale_yaml
        return 0
    fi
    [[ -d "$COMFYUI_DIR" ]] || return 0
    clear_legacy_models_link
    write_extra_model_paths "$COMFYUI_DIR"
}

# Both run before the skip-update escape hatch: a pod whose models live on
# the global volume must find them there even when updates are turned off.
provision_with_global_models
wire_global_models

if [[ "${EVERGREEN_SKIP_UPDATE:-0}" == "1" ]]; then
    log "EVERGREEN_SKIP_UPDATE=1 — skipping all updates"
    hand_off
fi

if [[ ! -d "$COMFYUI_DIR/.git" || ! -d "$VENV_DIR" ]]; then
    log "No provisioned installation on the volume yet."
    log "/start.sh will copy the baked ComfyUI (fresh from this image build);"
    log "automatic updates apply from the next pod start onward."
    hand_off
fi

INSTALL_DEPS_MODE="${EVERGREEN_INSTALL_DEPS:-changed}"
case "$INSTALL_DEPS_MODE" in
    changed|always|never) ;;
    *)
        log "WARNING: unknown EVERGREEN_INSTALL_DEPS='$INSTALL_DEPS_MODE' — using 'changed'"
        INSTALL_DEPS_MODE=changed
        ;;
esac

mkdir -p "$STATE_DIR/nodes" 2>/dev/null || true

# Volume files can end up owned differently than the container user.
git config --global --add safe.directory '*' 2>/dev/null || true

# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

# Keep pip from ever touching the image's CUDA-matched torch stack.
if [[ -f "$CONSTRAINTS_FILE" ]]; then
    export PIP_CONSTRAINT="$CONSTRAINTS_FILE"
fi

# Hard caps: SSH/Jupyter only start after we hand off to /start.sh, so a
# stalled update (e.g. pip grinding on a slow network volume) must never
# block the boot indefinitely.
CORE_TIMEOUT="${EVERGREEN_UPDATE_TIMEOUT:-900}"
NODE_TIMEOUT="${EVERGREEN_NODE_TIMEOUT:-600}"

BOOT_T0=$(date +%s)

log "============================================="
log " Updating ComfyUI core (timeout ${CORE_TIMEOUT}s, deps: ${INSTALL_DEPS_MODE})"
log "============================================="
export COMFYUI_DIR ROLLBACK_FILE STATE_DIR BUILD_ID_FILE CONSTRAINTS_FILE INSTALL_DEPS_MODE
timeout --kill-after=30 "$CORE_TIMEOUT" bash -s <<'CORE' || log "WARNING: ComfyUI core update failed or timed out — starting the existing version"
set -e
cd "$COMFYUI_DIR"
git remote set-url origin https://github.com/comfyanonymous/ComfyUI.git
git fetch --depth=1 origin master
git rev-parse HEAD > "$ROLLBACK_FILE"
git checkout -f -B master origin/master

# Fingerprint of everything that determines the pip outcome: the (freshly
# updated) requirements, the torch-pinning constraints, and the image build.
fp() { cat "$@" "$CONSTRAINTS_FILE" "$BUILD_ID_FILE" 2>/dev/null | sha256sum | awk '{print $1}'; }

marker="$STATE_DIR/comfyui.reqs.sha256"
want="$(fp requirements.txt)"
if [[ "$INSTALL_DEPS_MODE" == "never" ]]; then
    echo "[evergreen] EVERGREEN_INSTALL_DEPS=never — skipping ComfyUI requirements"
elif [[ "$INSTALL_DEPS_MODE" == "changed" && -f "$marker" && "$(cat "$marker")" == "$want" ]]; then
    echo "[evergreen] ComfyUI requirements unchanged — skipping pip"
else
    echo "[evergreen] Syncing ComfyUI requirements (can take a few minutes when frontend/docs packages changed)"
    python -m pip install -r requirements.txt
    echo "$want" > "$marker"
fi
CORE

log "ComfyUI version: $(git -C "$COMFYUI_DIR" log -1 --format='%h %ci %s' 2>/dev/null || echo unknown)"
CORE_T1=$(date +%s)
log "timing: core update took $((CORE_T1 - BOOT_T0))s"

log "============================================="
log " Syncing default custom nodes"
log "============================================="
if [[ -f "$NODES_FILE" ]]; then
    while IFS= read -r repo; do
        repo="${repo%%#*}"
        repo="$(echo "$repo" | xargs)"
        [[ -z "$repo" ]] && continue

        name="$(basename "$repo" .git)"
        dir="$COMFYUI_DIR/custom_nodes/$name"

        export repo name dir
        timeout --kill-after=30 "$NODE_TIMEOUT" bash -s <<'NODE' || log "WARNING: sync failed or timed out for $name — continuing"
set -e
if [[ ! -d "$dir" ]]; then
    echo "[evergreen] Installing $name"
    git clone --depth=1 "$repo" "$dir"
elif [[ -d "$dir/.git" ]]; then
    echo "[evergreen] Updating $name"
    cd "$dir"
    branch="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
    if [[ -z "$branch" ]]; then
    branch="$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p')"
    fi
    [[ -z "$branch" ]] && { echo "[evergreen] WARNING: cannot determine default branch for $name"; exit 0; }
    git fetch --depth=1 origin "$branch"
    git checkout -f -B "$branch" "origin/$branch"
else
    echo "[evergreen] Skipping $name (exists but is not a git checkout)"
    exit 0
fi

fp() { cat "$@" "$CONSTRAINTS_FILE" "$BUILD_ID_FILE" 2>/dev/null | sha256sum | awk '{print $1}'; }

# pip only when the node's dependency inputs changed since the last
# successful install (marker written below, so failures retry next boot).
deps_synced=0
if [[ -f "$dir/requirements.txt" ]]; then
    marker="$STATE_DIR/nodes/$name.reqs.sha256"
    want="$(fp "$dir/requirements.txt")"
    if [[ "$INSTALL_DEPS_MODE" == "never" ]]; then
        echo "[evergreen] $name: EVERGREEN_INSTALL_DEPS=never — skipping dependencies"
    elif [[ "$INSTALL_DEPS_MODE" == "changed" && -f "$marker" && "$(cat "$marker")" == "$want" ]]; then
        echo "[evergreen] $name: dependencies unchanged — skipping pip"
    else
        install-node-deps.sh "$dir"
        echo "$want" > "$marker"
        deps_synced=1
    fi
fi

# Manager-style install script (Impact Pack etc. need this to finish
# setup: config files, model downloads, dep checks). Re-run whenever its
# content changes or this boot (re)installed the node's dependencies.
if [[ -f "$dir/install.py" ]]; then
    imarker="$STATE_DIR/nodes/$name.install.sha256"
    iwant="$(fp "$dir/install.py")"
    if [[ "$INSTALL_DEPS_MODE" == "never" ]]; then
        echo "[evergreen] $name: EVERGREEN_INSTALL_DEPS=never — skipping install.py"
    elif [[ "$INSTALL_DEPS_MODE" == "changed" && "$deps_synced" == "0" && -f "$imarker" && "$(cat "$imarker")" == "$iwant" ]]; then
        echo "[evergreen] $name: install.py unchanged — skipping"
    elif (cd "$dir" && COMFYUI_PATH="$COMFYUI_DIR" python install.py); then
        echo "$iwant" > "$imarker"
    else
        echo "[evergreen] WARNING: install.py failed for $name"
    fi
fi
NODE
    done < "$NODES_FILE"
else
    log "No default-nodes list at $NODES_FILE"
fi

deactivate 2>/dev/null || true
BOOT_T1=$(date +%s)
log "timing: node sync took $((BOOT_T1 - CORE_T1))s"
log "timing: update pass total $((BOOT_T1 - BOOT_T0))s"
log "Update pass complete."
hand_off
