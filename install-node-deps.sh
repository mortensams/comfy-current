#!/usr/bin/env bash
# Install a custom node's Python deps: install-node-deps.sh <node_dir>
# Used by both the image bake and the boot wrapper.
#
# pip's build isolation conflicts with PIP_CONSTRAINT for source builds
# that need torch at build time (e.g. Impact Pack's sam2 dep): the isolated
# build env can't resolve the CUDA-suffixed torch pin against PyPI. So on
# failure, retry with plain packages first, then each git+ source dep
# without build isolation, building against the torch already installed.
set -u

dir="$1"
req="$dir/requirements.txt"
[[ -f "$req" ]] || exit 0

if python3 -m pip install --no-cache-dir -r "$req"; then
    exit 0
fi

echo "Retrying $(basename "$dir") deps: plain packages, then source builds without build isolation"
filtered="$(mktemp)"
grep -vE '^[[:space:]]*git\+' "$req" > "$filtered" || true
python3 -m pip install --no-cache-dir -r "$filtered" || true
rm -f "$filtered"

status=0
while IFS= read -r line; do
    python3 -m pip install --no-cache-dir --no-build-isolation "$line" || status=1
done < <(grep -E '^[[:space:]]*git\+' "$req")
exit $status
