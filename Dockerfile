# Evergreen ComfyUI for RunPod.
# Thin layer on top of RunPod's official ComfyUI image: bakes a set of
# default custom nodes and swaps the entrypoint for a wrapper that updates
# ComfyUI + those nodes on the persistent volume at every pod start.
ARG BASE_IMAGE=runpod/comfyui:cuda13.0
FROM ${BASE_IMAGE}

COPY default-nodes.txt /opt/default-nodes.txt

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
        if [ -f "$dir/requirements.txt" ]; then \
            python3.12 -m pip install --no-cache-dir -r "$dir/requirements.txt" \
                || echo "WARNING: deps failed for $name (retried at boot)"; \
        fi; \
        if [ -f "$dir/install.py" ]; then \
            (cd "$dir" && python3.12 install.py) \
                || echo "WARNING: install.py failed for $name (retried at boot)"; \
        fi; \
    done < /opt/default-nodes.txt; \
    rm -f /opt/comfyui-baked/custom_nodes/skip_download_model

COPY start-evergreen.sh /start-evergreen.sh
RUN chmod +x /start-evergreen.sh

# The base image uses ENTRYPOINT (not CMD), so we must override ENTRYPOINT.
ENTRYPOINT ["/start-evergreen.sh"]
