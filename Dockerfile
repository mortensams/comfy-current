# Evergreen ComfyUI for RunPod.
# Thin layer on top of RunPod's official ComfyUI image: bakes a set of
# default custom nodes and swaps the entrypoint for a wrapper that updates
# ComfyUI + those nodes on the persistent volume at every pod start.
ARG BASE_IMAGE=runpod/comfyui:cuda13.0
FROM ${BASE_IMAGE}

COPY default-nodes.txt /opt/default-nodes.txt
COPY install-node-deps.sh /usr/local/bin/install-node-deps.sh
RUN chmod +x /usr/local/bin/install-node-deps.sh

# Bake the default custom nodes into /opt/comfyui-baked so they are present
# from the very first boot (RunPod's /start.sh copies that directory to the
# volume). Their Python deps go into system site-packages, which the runtime
# venv sees via --system-site-packages. PIP_CONSTRAINT keeps the image's
# CUDA-matched torch stack pinned. Dependency failures are non-fatal — the
# boot-time wrapper retries them on the volume.
RUN set -e; \
    export PIP_CONSTRAINT=/opt/comfyui-runtime-constraints.txt; \
    export COMFYUI_PATH=/opt/comfyui-baked; \
    touch /opt/comfyui-baked/custom_nodes/skip_download_model; \
    while IFS= read -r repo; do \
        repo="${repo%%#*}"; repo="$(echo "$repo" | xargs)"; \
        if [ -z "$repo" ]; then continue; fi; \
        name="$(basename "$repo" .git)"; \
        dir="/opt/comfyui-baked/custom_nodes/$name"; \
        if [ ! -d "$dir" ]; then \
            echo "Baking $name"; \
            git clone --depth=1 "$repo" "$dir"; \
        fi; \
        install-node-deps.sh "$dir" \
            || echo "WARNING: deps failed for $name (retried at boot)"; \
        if [ -f "$dir/install.py" ]; then \
            (cd "$dir" && python3.12 install.py) \
                || echo "WARNING: install.py failed for $name (retried at boot)"; \
        fi; \
    done < /opt/default-nodes.txt; \
    rm -f /opt/comfyui-baked/custom_nodes/skip_download_model

# Pre-install latest master's requirements into system site-packages so the
# boot-time sync on the (slow, network-volume) venv is a no-op for any pin
# already covered by this week's build. The heavyweight offenders are
# comfyui-frontend-package and comfyui-embedded-docs — thousands of small
# files that take minutes to install on network storage.
RUN export PIP_CONSTRAINT=/opt/comfyui-runtime-constraints.txt && \
    git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git /tmp/comfyui-latest && \
    python3.12 -m pip install --no-cache-dir -r /tmp/comfyui-latest/requirements.txt && \
    rm -rf /tmp/comfyui-latest

# SageAttention: a faster attention kernel than the PyTorch SDPA default on
# Ada/Hopper cards. The base image ships triton (its only real dependency)
# but not this, so ComfyUI falls back to "Using pytorch attention". Into
# system site-packages, which the volume's venv sees via
# --system-site-packages. Opt in per pod by adding --use-sage-attention to
# /workspace/runpod-slim/comfyui_args.txt; installing it costs nothing until
# then. Non-fatal: a broken wheel must never block the image build.
RUN export PIP_CONSTRAINT=/opt/comfyui-runtime-constraints.txt && \
    python3.12 -m pip install --no-cache-dir sageattention \
    || echo "WARNING: sageattention install failed — ComfyUI will use pytorch attention"

# Build ID for the boot-time dependency fingerprints. The venv on the volume
# sees this image's system site-packages (--system-site-packages), so a new
# image build must invalidate the volume's skip-markers: the ID is part of
# every fingerprint, forcing one full dependency re-sync per image update.
# Placed after the package layers so a cached (= unchanged) image keeps its ID.
RUN date -u +%Y-%m-%dT%H:%M:%SZ > /opt/evergreen-build-id

COPY start-evergreen.sh /start-evergreen.sh
RUN chmod +x /start-evergreen.sh

# The base image uses ENTRYPOINT (not CMD), so we must override ENTRYPOINT.
ENTRYPOINT ["/start-evergreen.sh"]
