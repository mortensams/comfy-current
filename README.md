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
- [ComfyUI-Easy-Use](https://github.com/yolain/ComfyUI-Easy-Use)
- [ComfyUI-Lora-Manager](https://github.com/willmiao/ComfyUI-Lora-Manager)
- [ComfyUI-Custom-Scripts](https://github.com/pythongosssss/ComfyUI-Custom-Scripts)
- [ComfyUI-QwenVL-Mod](https://github.com/huchukato/ComfyUI-QwenVL-Mod) —
  QwenVL Prompt Enhancer nodes (Qwen2.5-VL / Qwen3-VL, transformers + GGUF),
  including the Unredacted-MAX model variants; models auto-download on
  first use

Add or remove nodes by editing `default-nodes.txt` (one git URL per line).

## How it works

The official `/start.sh` copies its baked ComfyUI to
`/workspace/runpod-slim/ComfyUI` on first boot and never touches it again —
so a network volume goes stale. This image replaces the entrypoint with
`start-evergreen.sh`, which:

1. On the volume's **first boot**: does nothing — `/start.sh` provisions the
   baked copy (fresh from this image's weekly build).
2. On **every later boot**: activates the existing venv, force-updates the
   ComfyUI checkout to upstream `master`, clones any missing default nodes,
   force-updates the existing ones, then `exec /start.sh`.

Dependency work is skipped when nothing relevant changed. After each
successful `pip install` / `install.py` run, a fingerprint of its inputs —
the repo's `requirements.txt` (or `install.py`) content, RunPod's pip
constraints file, and the image build ID — is stored under
`/workspace/runpod-slim/.evergreen-state/`. On later boots a matching
fingerprint skips that step entirely, so a typical restart is just a set of
`git fetch`es (seconds) instead of minutes of pip resolution. New upstream
commits that don't touch `requirements.txt` update the code and still skip
pip; a new weekly image (new torch stack / system site-packages) changes
the build ID and forces one full re-sync. Failed installs never write a
fingerprint, so they retry on the next boot. Control this with the pod env
var `EVERGREEN_INSTALL_DEPS`: `changed` (default), `always` (old behavior,
pip every boot), or `never`.

Every update step is best-effort: if GitHub or PyPI is unreachable, or an
update fails, the pod still boots the existing installation — SSH, Jupyter,
FileBrowser and ComfyUI stay reachable. The previous ComfyUI commit is saved
to `/workspace/runpod-slim/comfyui-previous-commit.txt` for manual rollback.

Set the pod env var `EVERGREEN_SKIP_UPDATE=1` to boot without updating.

## Storage layout (network volume + global volume)

RunPod's **global volumes are object-backed, not a POSIX filesystem**: per
[their docs](https://docs.runpod.io/storage/globalvolume/overview) they
*"do not support file locking, atomic rename, or hard links"* and
*"cannot set file permission bits"*. A git checkout, a venv and pip all
depend on exactly those, so **the ComfyUI installation can never live on a
global volume** — `git` fails on `.git/config.lock` and `index.lock`, and
the venv's `bin/` scripts never get their exec bit.

So split the two:

| What | Where | Why |
|---|---|---|
| ComfyUI, venv, custom nodes, `user/`, `output/` | **network volume** at `/workspace` | needs real POSIX semantics; keeps deps across pods |
| `models/` | **global volume** at `/workspace-global` | large, written rarely, read often — the workload global volumes are for |

A global volume cannot be mounted *inside* the network volume's tree, so
the two are bridged with ComfyUI's own `extra_model_paths.yaml`, which
`start-evergreen.sh` generates on every boot:

```yaml
runpod_global:
    base_path: /workspace-global/models
    checkpoints: checkpoints
    loras: loras
    ...
```

ComfyUI auto-loads that file from its root directory at startup, so every
category on the global volume is searched **in addition to** the local
`models/` tree. Nothing is moved and nothing is linked.

> **Why not a symlink at `models/`?** It cannot survive. ComfyUI
> git-tracks 36 files under `models/` (the `put_*_here` placeholders and
> `models/configs/*.yaml`), so the `git checkout -f` in this script's own
> core update deletes any symlink there and restores a real directory —
> silently, on every boot. `extra_model_paths.yaml` is immune: git never
> touches it because it is untracked, and RunPod's bundle upgrade excludes
> it by name (`rsync --exclude="/extra_model_paths.yaml"`).

Node auto-downloads (Impact Pack's ~500 MB of SAM and ultralytics weights)
keep going to the local `models/` on the fast POSIX network volume, because
the generated config deliberately does **not** set `is_default`. Your
curated weights are read from the global volume. A model present in both
places is listed once — ComfyUI de-duplicates by relative name.

The network volume only holds the installation, not your weights — 50 GB is
comfortable.

> **Leave the global volume's mount path at its default.** If you edit that
> field at deploy time, RunPod reassigns the *network* volume to
> `/workspace-2`, and every `/workspace/runpod-slim/...` path here breaks.

Safeguards, all best-effort and non-fatal:

- No global volume attached → the yaml is not written at all and the pod
  boots on local models. The wrapper waits up to `EVERGREEN_MODELS_WAIT`
  seconds (default 20) for the mount, since it can lag container start.
- A `models/` symlink left over from an earlier version of this script is
  removed, and so is a stray `models/models` (see below).
- `EVERGREEN_MODELS_DIR` overrides the global models path; `none` stops the
  script managing `extra_model_paths.yaml` entirely.

> **Adding models? Restart ComfyUI — pressing "R" is not enough.**
> `folder_paths.py` invalidates its filename cache purely by comparing
> `os.path.getmtime()` on each model folder. Object-backed storage reports
> synthetic directory mtimes that often don't change when files appear
> beneath them, so the cache goes stale and never notices. `/object_info`
> (what "R" calls) runs inside `with folder_paths.cache_helper:`, which
> caches harder, not less.

> **Don't hand-create a link with `ln -s /workspace-global/models .`** —
> run from inside `models/` that creates `models/models`, which ComfyUI
> never reads, so your pickers stay empty. The wrapper detects and removes
> a stray `models/models` link.

> Models that custom nodes fetch at runtime via Hugging Face (e.g. QwenVL)
> still land in `~/.cache/huggingface` on container disk and are lost with
> the pod. Set `HF_HOME` to a path on the **network** volume — the HF cache
> uses file locks and symlinked blobs, which a global volume can't provide.

Because SSH/Jupyter only start after the update pass, every phase runs
under a hard timeout so a slow network volume can never leave the pod
unreachable: `EVERGREEN_UPDATE_TIMEOUT` (core update, default 900s) and
`EVERGREEN_NODE_TIMEOUT` (per custom node, default 600s). A timed-out
phase is skipped with a warning and retried on the next boot.

> Note: nodes in `default-nodes.txt` are **force-updated** (local changes
> discarded). Nodes you install yourself via ComfyUI-Manager are left alone.

## Setup

1. Push this repo to GitHub. The **Build evergreen ComfyUI image** workflow
   publishes to GHCR using the built-in `GITHUB_TOKEN` — no secrets needed.
   It runs weekly, on manual dispatch, and on pushes that touch the image
   inputs, producing `ghcr.io/mortensams/comfy-current:cuda13.0` and
   `:latest`.
2. After the first push, make the package public so RunPod can pull it
   without credentials: GitHub → your profile → Packages →
   `comfy-current` → Package settings → Change visibility → Public.
   (Alternatively keep it private and add a registry credential in RunPod
   with a GitHub PAT that has `read:packages`.)
3. In RunPod, duplicate the official **ComfyUI (CUDA 13)** template and
   change only the container image, or create a template from scratch:
   - Container image: `ghcr.io/mortensams/comfy-current:cuda13.0`
   - Volume mount path: `/workspace` (attach your network volume)
   - Optionally also attach a global volume for models — leave its mount
     path at the default so it lands on `/workspace-global`
     (see [Storage layout](#storage-layout-network-volume--global-volume))
   - HTTP ports: `8188` (ComfyUI), `8888` (Jupyter), `8080` (FileBrowser)
   - TCP port: `22` (SSH)
   - Optional env: `JUPYTER_PASSWORD`, `FILEBROWSER_PASSWORD`,
     `EVERGREEN_SKIP_UPDATE`, `EVERGREEN_INSTALL_DEPS`,
     `EVERGREEN_MODELS_DIR`
4. Deploy a pod (CUDA 13 targets Blackwell / RTX 5090-class GPUs). The first
   boot provisions the volume; every restart after that lands on the latest
   ComfyUI.

## Local build

```bash
docker build -t ghcr.io/mortensams/comfy-current:cuda13.0 .
docker push ghcr.io/mortensams/comfy-current:cuda13.0
```

Use `--build-arg BASE_IMAGE=runpod/comfyui:cuda12.8` for a CUDA 12.8 variant
(pre-Blackwell GPUs).
