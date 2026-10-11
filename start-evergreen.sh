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
#   EVERGREEN_MODELS_DIR     where models live; 'none' keeps them local

COMFYUI_DIR=/workspace/runpod-slim/ComfyUI
VENV_DIR="$COMFYUI_DIR/.venv-cu128"
BAKED_DIR=/opt/comfyui-baked
CONSTRAINTS_FILE=/opt/comfyui-runtime-constraints.txt
NODES_FILE=/opt/default-nodes.txt
ROLLBACK_FILE=/workspace/runpod-slim/comfyui-previous-commit.txt
STATE_DIR=/workspace/runpod-slim/.evergreen-state
BUILD_ID_FILE=/opt/evergreen-build-id
MODELS_TARGET="${EVERGREEN_MODELS_DIR:-/workspace-global/models}"

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
# attached as well. RunPod cannot mount one volume inside another's tree,
# so ComfyUI's models/ becomes a symlink pointing across to it.

prepare_models_target() {
    [[ -n "$MODELS_TARGET" && "$MODELS_TARGET" != "none" ]] || return 1
    # The mount point itself must already exist; mkdir would otherwise
    # happily create the "global volume" on the local disk.
    [[ -d "$(dirname "$MODELS_TARGET")" ]] || return 1
    mkdir -p "$MODELS_TARGET" 2>/dev/null || return 1

    # Seed an empty volume with the configs and put_*_here placeholders the
    # image ships, so a linked tree looks like a normal ComfyUI models dir.
    # Only when empty: directory walks on object storage cost requests.
    if [[ -z "$(ls -A "$MODELS_TARGET" 2>/dev/null)" ]]; then
        log "Seeding $MODELS_TARGET from the baked models skeleton"
        cp -r "$BAKED_DIR/models/." "$MODELS_TARGET/" 2>/dev/null || true
    fi
}

# True when $1 holds nothing the image did not ship, and so can be replaced
# by the symlink. Anything else is the user's own download -- possibly
# hundreds of GB, far too much to migrate inside the boot timeout.
models_dir_is_pristine() {
    local dir="$1" f rel
    while IFS= read -r -d '' f; do
        rel="${f#"$dir"/}"
        [[ -e "$BAKED_DIR/models/$rel" ]] || return 1
    done < <(find "$dir" -type f -print0 2>/dev/null)
}

# /start.sh provisions a missing $COMFYUI_DIR with `cp -r` and then goes
# straight on to launch ComfyUI -- we never get control in between. So when
# the models link is wanted, do that copy here instead, with the symlink
# already in it. /start.sh then finds the directory present and skips its
# own copy; its separate venv check (start.sh:344) still runs, and its
# bundle rsync excludes /models, so the link survives later upgrades.
provision_with_model_link() {
    [[ -d "$COMFYUI_DIR" ]] && return 0
    prepare_models_target || return 0

    local staged="${COMFYUI_DIR}.provisioning.$$"
    log "First boot: provisioning $COMFYUI_DIR with models on the global volume"
    mkdir -p "$(dirname "$COMFYUI_DIR")" || return 0
    rm -rf "$staged"
    # Staged, then moved into place: a half-finished copy at $COMFYUI_DIR
    # would make /start.sh skip provisioning forever.
    if ! cp -r "$BAKED_DIR" "$staged"; then
        log "WARNING: staging copy failed — letting /start.sh provision normally"
        rm -rf "$staged"
        return 0
    fi
    rm -rf "$staged/models"
    ln -sfn "$MODELS_TARGET" "$staged/models"
    mv "$staged" "$COMFYUI_DIR" || {
        log "WARNING: could not move the staged install into place"
        rm -rf "$staged"
    }
}

link_models() {
    [[ -d "$COMFYUI_DIR" ]] || return 0
    local models="$COMFYUI_DIR/models"

    if ! prepare_models_target; then
        if [[ "$MODELS_TARGET" == "none" ]]; then
            log "EVERGREEN_MODELS_DIR=none — models stay on the local volume"
        else
            log "No global volume at $(dirname "$MODELS_TARGET") — models stay on the local volume"
        fi
        return 0
    fi

    if [[ -L "$models" ]]; then
        if [[ "$(readlink "$models")" == "$MODELS_TARGET" ]]; then
            log "models -> $MODELS_TARGET"
        else
            log "models: re-pointing $(readlink "$models") -> $MODELS_TARGET"
            ln -sfn "$MODELS_TARGET" "$models"
        fi
        return 0
    fi

    if [[ -d "$models" ]]; then
        if ! models_dir_is_pristine "$models"; then
            log "WARNING: $models holds model files — leaving it on the local volume."
            log "WARNING: move them to $MODELS_TARGET and restart to use the global volume."
            return 0
        fi
        rm -rf "$models"
    fi

    ln -sfn "$MODELS_TARGET" "$models" && log "models -> $MODELS_TARGET (global volume)"
}

# Both run before the skip-update escape hatch: a pod whose models live on
# the global volume must find them there even when updates are turned off.
provision_with_model_link
link_models

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
