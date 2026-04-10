# PhotoPrism Vision on AMD (Arch Linux)

Guide to running photoprism-vision with AMD ROCm GPU acceleration. This machine is a secondary test/benchmark host — the primary deployment is on mcarch (NVIDIA, see [[photoprism-arch]]).

## Host Machine

| | |
|---|---|
| **Hostname** | (local workstation) |
| **OS** | Arch Linux, kernel 6.12.65-1-lts |
| **Desktop** | Hyprland via SDDM |
| **GPU (discrete)** | AMD Radeon RX 7600 (Navi 33, gfx1102, RDNA 3, 8GB VRAM) |
| **GPU (integrated)** | AMD Phoenix1 780M (shared system RAM) |
| **Docker** | Native, `docker compose` v2 |
| **ROCm** | 7.1.1 (from Arch `extra` repo) |

## Architecture

```
Docker: photoprism-vision :5050  (photoprism/vision:latest)
  ├── Caption:  kosmos-2           (local PyTorch, CPU)
  ├── NSFW:     nsfw_image_detector (local PyTorch, CPU)
  └── Labels:   --> Ollama API

Docker: Ollama             :11434 (ollama/ollama:rocm)
  └── llama3.2-vision (ROCm, RX 7600 GPU)
```

No PhotoPrism instance runs on this machine — it's used for vision API testing and benchmarking only.

## AMD ROCm Setup

### gfx1102 Support Status

The RX 7600 (gfx1102) is **not in AMD's official ROCm compatibility matrix** — only gfx1100 (RX 7900 XTX) and gfx1101 (RX 7800 XT) are listed for RDNA 3. However:

- **Ollama** explicitly lists the RX 7600 as supported and ships gfx1102 binaries
- **PyTorch 2.9+** includes gfx1102 as a build target
- AMD's new build system (TheRock) includes gfx1102 — official support expected mid-2026

The workaround is `HSA_OVERRIDE_GFX_VERSION=11.0.0`, which tells the ROCm runtime to treat the GPU as gfx1100. Set in both containers via environment variable.

### Host Packages

Only `rocm-smi-lib` is needed on the host — the Docker containers bundle their own ROCm userspace. The kernel's built-in `amdgpu` driver handles the rest.

```bash
sudo pacman -S rocm-smi-lib    # GPU monitoring only
```

The full `rocm-hip-sdk` is only needed for local (non-Docker) GPU compute.

### User Groups

The user must be in `video` and `render` groups for `/dev/kfd` and `/dev/dri` access:

```bash
sudo usermod -aG video,render $USER
# Log out and back in for changes to take effect
```

### GPU Monitoring

```bash
/opt/rocm/bin/rocm-smi              # Overview (temp, power, VRAM%)
/opt/rocm/bin/rocm-smi --showmemuse # Detailed VRAM usage
```

## Docker Compose Configuration

Project directory: `~/Projects/Photo/photoprism-vision/`

### Key Differences from NVIDIA (mcarch)

| Setting | NVIDIA (mcarch) | AMD/ROCm (this machine) |
|---|---|---|
| Ollama image | `ollama/ollama:latest` | `ollama/ollama:rocm` |
| GPU passthrough | `deploy.resources.reservations` | `devices: [/dev/kfd, /dev/dri]` |
| Container groups | N/A | `group_add: ["983", "987"]` (video, render GIDs) |
| GPU env vars | `NVIDIA_VISIBLE_DEVICES` | `HSA_OVERRIDE_GFX_VERSION`, `ROCR_VISIBLE_DEVICES` |
| GPU check | `nvidia-smi` | `/opt/rocm/bin/rocm-smi` |

**Important:** `group_add` must use numeric GIDs, not group names — the container images don't have matching group entries.

### GPU Selection

This machine has two AMD GPUs. Without pinning, Ollama splits the model across both (including the slow APU with shared system RAM).

```yaml
environment:
  ROCR_VISIBLE_DEVICES: "0"   # RX 7600 only (discrete, /dev/dri/renderD128)
```

Device mapping:

| Device | Render Node | GPU | Type |
|---|---|---|---|
| 0 | renderD128 | RX 7600 (Navi 33) | Discrete, 8GB VRAM |
| 1 | renderD129 | Phoenix1 780M | iGPU, shared system RAM |

To restrict at the device level instead of environment variable:
```yaml
devices:
  - /dev/kfd:/dev/kfd
  - /dev/dri/renderD128:/dev/dri/renderD128   # RX 7600 only
```

### VRAM Constraints

The RX 7600 has 8GB VRAM. `llama3.2-vision` (11B, ~7.3GB) fits 30/41 layers on GPU with the rest spilling to CPU. This is acceptable performance.

Stopping the desktop compositor frees framebuffer VRAM:

```bash
sudo systemctl stop sddm     # Free ~200-500MB VRAM
sudo systemctl start sddm    # Restore desktop
```

### Model Layer Distribution (llama3.2-vision)

| Config | GPU Layers | GPU VRAM | CPU Offload |
|---|---|---|---|
| SDDM running, both GPUs | 41/41 split across 2 GPUs | RX 7600: 4GB + APU: 3GB | 286MB |
| SDDM running, RX 7600 only | 30/41 | 3.6GB | 3.7GB |
| SDDM stopped, RX 7600 only | 30/41 | 3.6GB | 3.7GB |

For full GPU offload, use a smaller model like `llava-phi3` (~3GB).

## Common Operations

### Start/Stop

```bash
cd ~/Projects/Photo/photoprism-vision
docker compose up -d
docker compose down
docker compose logs -f
```

### Pull/Manage Ollama Models

```bash
docker compose exec ollama ollama pull llama3.2-vision
docker compose exec ollama ollama list
docker compose exec ollama ollama rm <model>
```

### Test Vision API

```bash
# Caption (kosmos-2, local)
curl -s -X POST http://127.0.0.1:5050/api/v1/vision/caption \
  -H "Content-Type: application/json" \
  -d '{"url":"https://dl.photoprism.app/img/team/avatar.jpg"}' | python3 -m json.tool

# Labels (llama3.2-vision via Ollama/ROCm)
curl -s -X POST http://127.0.0.1:5050/api/v1/vision/labels/llama3.2-vision/latest \
  -H "Content-Type: application/json" \
  -d '{"url":"https://dl.photoprism.app/img/team/avatar.jpg"}' | python3 -m json.tool

# NSFW (nsfw_image_detector, local)
curl -s -X POST http://127.0.0.1:5050/api/v1/vision/nsfw/nsfw_image_detector/latest \
  -H "Content-Type: application/json" \
  -d '{"url":"https://dl.photoprism.app/img/team/avatar.jpg"}' | python3 -m json.tool
```

### Verify GPU in Ollama

```bash
docker compose logs ollama 2>&1 | grep "inference compute"
# Should show: library=ROCm compute=gfx1100 ... type=discrete total="8.0 GiB"
```

## Troubleshooting

| Issue | Fix |
|---|---|
| `rocm-smi` shows no GPU | Check `groups` output — need `video` and `render`. Reboot after `usermod`. |
| Ollama: "no compatible GPUs" | Add `HSA_OVERRIDE_GFX_VERSION: "11.0.0"` to environment |
| Ollama uses APU instead of RX 7600 | Set `ROCR_VISIBLE_DEVICES: "0"` |
| Container fails: "Unable to find group render" | Use numeric GIDs in `group_add`, not names |
| Permission denied on `/dev/kfd` | Add `group_add` with video/render GIDs to compose service |
| PyTorch `torch.cuda.is_available()` is False | Install `python-pytorch-rocm` (not regular pytorch). Set `HSA_OVERRIDE_GFX_VERSION`. |
| GPU OOM | RX 7600 has 8GB. Use quantized models <=7B params. Check with `rocm-smi`. |
| linux-firmware regression | Downgrade: `sudo pacman -U /var/cache/pacman/pkg/linux-firmware-amdgpu-<prev>.pkg.tar.zst` |

## Comparison: AMD (this) vs NVIDIA (mcarch) vs Mac (budgie)

| | AMD (this) | NVIDIA (mcarch) | Mac M4 (budgie) |
|---|---|---|---|
| GPU | RX 7600, 8GB | RTX 4070 Ti, 12GB | M4 Pro, 128GB unified |
| Ollama image | `ollama:rocm` | `ollama:latest` | Native (Metal) |
| GPU runtime | ROCm 7.1.1 | NVIDIA Container Toolkit | Metal (native) |
| llama3.2-vision layers on GPU | 30/41 | 41/41 | 41/41 |
| Labels speed (llama3.2-vision) | ~11s | ~7s | ~10s (90b model) |
| Caption speed (kosmos-2) | ~11s | ~130ms | N/A (uses qwen2.5vl) |
| NSFW speed | ~0.5s | ~250ms | N/A (built-in TF) |
| Desktop VRAM cost | ~200-500MB | ~7.7GB | N/A (unified memory) |
