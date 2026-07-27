#!/usr/bin/env bash
# Evergreen wrapper for runpod/comfyui.
#
# Runs BEFORE RunPod's official /start.sh and updates the persistent
# installation on the network volume:
#   - ComfyUI core        -> latest upstream master
#   - default custom nodes (from /opt/default-nodes.txt) -> cloned if
#     missing, force-updated to upstream default branch otherwise
#
# Every step is best-effort: a failed update must never prevent the pod
# from starting (SSH, Jupyter, FileBrowser and ComfyUI all live behind
# /start.sh, which we always exec at the end).
#
# Escape hatch: set EVERGREEN_SKIP_UPDATE=1 in the pod env to boot
# whatever is already on the volume, untouched.

COMFYUI_DIR=/workspace/runpod-slim/ComfyUI
VENV_DIR="$COMFYUI_DIR/.venv-cu128"
CONSTRAINTS_FILE=/opt/comfyui-runtime-constraints.txt
NODES_FILE=/opt/default-nodes.txt
ROLLBACK_FILE=/workspace/runpod-slim/comfyui-previous-commit.txt

log() { echo "[evergreen] $*"; }

# If a future base image moves these paths, pick up its values instead of
# our hardcoded defaults. /start.sh defines both as plain assignments.
eval "$(grep -E '^(COMFYUI_DIR|VENV_DIR)=' /start.sh 2>/dev/null)" || true

hand_off() {
    log "Handing off to official /start.sh"
    exec /start.sh
}

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

log "============================================="
log " Updating ComfyUI core (timeout ${CORE_TIMEOUT}s)"
log "============================================="
export COMFYUI_DIR ROLLBACK_FILE
timeout --kill-after=30 "$CORE_TIMEOUT" bash -s <<'CORE' || log "WARNING: ComfyUI core update failed or timed out — starting the existing version"
set -e
cd "$COMFYUI_DIR"
git remote set-url origin https://github.com/comfyanonymous/ComfyUI.git
git fetch --depth=1 origin master
git rev-parse HEAD > "$ROLLBACK_FILE"
git checkout -f -B master origin/master
echo "[evergreen] Syncing ComfyUI requirements (can take a few minutes when frontend/docs packages changed)"
python -m pip install -r requirements.txt
CORE

log "ComfyUI version: $(git -C "$COMFYUI_DIR" log -1 --format='%h %ci %s' 2>/dev/null || echo unknown)"

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

install-node-deps.sh "$dir"

# Manager-style install script (Impact Pack etc. need this to finish
# setup: config files, model downloads, dep checks)
if [[ -f "$dir/install.py" ]]; then
    (cd "$dir" && COMFYUI_PATH="$COMFYUI_DIR" python install.py) \
        || echo "[evergreen] WARNING: install.py failed for $name"
fi
NODE
    done < "$NODES_FILE"
else
    log "No default-nodes list at $NODES_FILE"
fi

deactivate 2>/dev/null || true
log "Update pass complete."
hand_off
