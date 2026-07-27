# Evergreen ComfyUI for RunPod

A thin derived image on top of RunPod's official ComfyUI template
([`runpod/comfyui:cuda13.0`](https://github.com/runpod-workers/comfyui-base))
that keeps a persistent installation on a network volume permanently up to
date:

| Layer | How it stays current |
|---|---|
| ComfyUI core | Updated to upstream `master` on every pod start |
| Default custom nodes | Cloned/force-updated on every pod start (`default-nodes.txt`) |
| CUDA, PyTorch, system libs | Weekly image rebuild from the official base (GitHub Actions) |

Default custom nodes:

- [rgthree-comfy](https://github.com/rgthree/rgthree-comfy)
- [ComfyUI-Impact-Pack](https://github.com/ltdrdata/ComfyUI-Impact-Pack) +
  [ComfyUI-Impact-Subpack](https://github.com/ltdrdata/ComfyUI-Impact-Subpack)
- [ComfyUI_essentials](https://github.com/cubiq/ComfyUI_essentials)
- [ComfyUI-VideoHelperSuite](https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite)
- [ComfyUI-QwenVL](https://github.com/1038lab/ComfyUI-QwenVL) — QwenVL Prompt
  Enhancer nodes (Qwen2.5-VL / Qwen3-VL, transformers + GGUF); models
  auto-download to `models/LLM/` on first use

Add or remove nodes by editing `default-nodes.txt` (one git URL per line).

## How it works

The official `/start.sh` copies its baked ComfyUI to
`/workspace/runpod-slim/ComfyUI` on first boot and never touches it again —
so a network volume goes stale. This image replaces the entrypoint with
`start-evergreen.sh`, which:

1. On the volume's **first boot**: does nothing — `/start.sh` provisions the
   baked copy (fresh from this image's weekly build).
2. On **every later boot**: activates the existing venv, force-updates the
   ComfyUI checkout to upstream `master`, syncs `requirements.txt` (with
   RunPod's pip constraints so the CUDA-matched torch stack is never
   touched), clones any missing default nodes, force-updates the existing
   ones, then `exec /start.sh`.

Every update step is best-effort: if GitHub or PyPI is unreachable, or an
update fails, the pod still boots the existing installation — SSH, Jupyter,
FileBrowser and ComfyUI stay reachable. The previous ComfyUI commit is saved
to `/workspace/runpod-slim/comfyui-previous-commit.txt` for manual rollback.

Set the pod env var `EVERGREEN_SKIP_UPDATE=1` to boot without updating.

> Note: nodes in `default-nodes.txt` are **force-updated** (local changes
> discarded). Nodes you install yourself via ComfyUI-Manager are left alone.

## Setup

1. Push this repo to GitHub.
2. Add repo secrets `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`
   (a Docker Hub access token with write scope).
3. Run the **Build evergreen ComfyUI image** workflow (it also runs weekly
   and on pushes that touch the image inputs). It publishes
   `<user>/comfyui-evergreen:cuda13.0` and `:latest`.
4. In RunPod, duplicate the official **ComfyUI (CUDA 13)** template and
   change only the container image to `<user>/comfyui-evergreen:cuda13.0`,
   or create a template from scratch:
   - Container image: `<user>/comfyui-evergreen:cuda13.0`
   - Volume mount path: `/workspace` (attach your network volume)
   - HTTP ports: `8188` (ComfyUI), `8888` (Jupyter), `8080` (FileBrowser)
   - TCP port: `22` (SSH)
   - Optional env: `JUPYTER_PASSWORD`, `FILEBROWSER_PASSWORD`,
     `EVERGREEN_SKIP_UPDATE`
5. Deploy a pod (CUDA 13 targets Blackwell / RTX 5090-class GPUs). The first
   boot provisions the volume; every restart after that lands on the latest
   ComfyUI.

## Local build

```bash
docker build -t youruser/comfyui-evergreen:cuda13.0 .
docker push youruser/comfyui-evergreen:cuda13.0
```

Use `--build-arg BASE_IMAGE=runpod/comfyui:cuda12.8` for a CUDA 12.8 variant
(pre-Blackwell GPUs).
