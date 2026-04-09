# PhotoPrism on Mac M4 (budgie)

Host: **budgie.grave.loco** — M4 Mac, 128GB RAM

## Setup

- PhotoPrism + MariaDB via Docker Compose (Colima)
- Ollama runs **natively** (not in Docker) to get Metal GPU + unified memory
- No photoprism-vision service needed — PhotoPrism talks directly to Ollama via `vision.yml`
- Project directory: `~/Projects/Photo/photoprism/`

## Architecture

```
PhotoPrism (Docker/Colima)
  |
  |-- face/nsfw: built-in TensorFlow models
  |
  |-- labels/caption: --> http://host.docker.internal:11434 --> Ollama (native macOS, Metal)
```

Key difference from mcarch: on the Mac, `host.docker.internal` works correctly through Colima. On mcarch (Linux), it times out and you need the docker0 bridge IP (`172.17.0.1`).

## Vision Config

`storage/config/vision.yml` — uses `qwen2.5vl:7b` for both labels and captions. Using a single model avoids Ollama model-swap overhead during batch processing.

```yaml
Models:
- Type: face
  Default: true
- Type: nsfw
  Default: true
- Type: labels
  Model: qwen2.5vl:7b
  Engine: ollama
  Run: auto
  Options:
    Temperature: 0.01
    TopK: 40
    TopP: 0.9
    MinP: 0.05
    Seed: 3407
  Service:
    Uri: http://host.docker.internal:11434/api/generate
- Type: caption
  Model: qwen2.5vl:7b
  Engine: ollama
  Run: auto
  Prompt: >-
    Create a caption with exactly one sentence in the active voice
    that describes the main visual content. Begin with the main subject
    and clear action. Avoid text formatting, meta-language, and filler words.
  Options:
    Temperature: 0.1
  Service:
    Uri: http://host.docker.internal:11434/api/generate
```

### Why qwen2.5vl:7b

PhotoPrism benchmarks across 100 images:

| Model | Time/Image | Hallucination Rate | Error Rate |
|-------|-----------|-------------------|------------|
| **qwen2.5vl:7b** | ~36s | **0.33%** | 18% |
| qwen2.5vl:3b | ~24s | 1.33% | 19% |
| gemma3:4b | ~31s | 2.00% | 25% |

With 128GB RAM the 7B model fits trivially. Actual observed performance on M4: ~4.4s/caption, ~1.6s/label.

### Why not photoprism-vision service

On mcarch with the RTX 4070 Ti, the vision service makes sense — it offloads PyTorch models (kosmos-2, NSFW detector) to the GPU. On the Mac, those PyTorch models inside Docker/Colima can't access Metal and run CPU-only. Native Ollama with Metal is faster for everything. PhotoPrism's built-in TensorFlow handles face and NSFW detection without the external service.

## Ollama Setup

Ollama runs natively via `brew install ollama` or the desktop app.

```bash
# Pull the vision model
ollama pull qwen2.5vl:7b

# Keep model loaded during batch processing (set in shell profile or launchd)
export OLLAMA_KEEP_ALIVE=10m
```

Note the model name: `qwen2.5vl` (no hyphen before `vl`). `qwen2.5-vl` does not exist on Ollama.

## Originals Mounts

`~/Pictures` contains the Apple Photos Library (13GB, 64k files) alongside real photos. Mounting all of `~/Pictures` causes PhotoPrism to index ~21,000 junk files (thumbnails, derivatives, segmentation masks, etc.) — 96% noise.

Instead, mount individual directories and only the `originals/` subdirectory of the Photos Library:

```yaml
volumes:
  - "~/Pictures/Photos Library.photoslibrary/originals:/photoprism/originals/Apple Photos:ro"
  - "~/Pictures/Darkroom:/photoprism/originals/Darkroom:ro"
  - "~/Pictures/NIKON_D5500:/photoprism/originals/NIKON_D5500:ro"
  - "~/Pictures/Photoworks:/photoprism/originals/Photoworks:ro"
  - "~/Pictures/Saturn:/photoprism/originals/Saturn:ro"
  #- "~/Pictures/Screenshots:/photoprism/originals/Screenshots:ro"
  - "./storage:/photoprism/storage"
```

**Excluded:**
- `Photos Library.photoslibrary/resources/` — 19,814 thumbnails/derivatives/`.dat` blobs
- `Photos Library.photoslibrary/internal/` — 162 segmentation masks, portrait layers
- `Photos Library.photoslibrary/database/` — 15,387 Apple Photos SQLite/index files
- `Photos Library.photoslibrary/scopes/` — 60 Apple internal files
- `Screenshots/` — ~250 screenshots, not worth indexing

## Runbook: Clean Rebuild

After changing volume mounts, you need a clean rebuild (old DB has stale paths/entries).

```bash
cd ~/Projects/Photo/photoprism

# 1. Stop everything
docker compose down

# 2. Remove old database volume and storage
docker volume rm photoprism_database
rm -rf ./storage

# 3. Recreate vision config
mkdir -p ./storage/config
# (copy vision.yml contents from the Vision Config section above)

# 4. Start fresh
docker compose up -d

# 5. Wait for MariaDB to initialize (~10s), then index
docker compose exec photoprism photoprism index

# 6. Verify
docker compose exec photoprism photoprism vision ls
```

## Runbook: Vision Processing

Vision models are **not** run during indexing — they must be triggered separately.

```bash
cd ~/Projects/Photo/photoprism

# Test on a single image first
docker compose exec photoprism photoprism vision run -m caption --count 1 --force
docker compose exec photoprism photoprism vision run -m labels --count 1 --force

# Process full library (both tasks)
docker compose exec photoprism photoprism vision run -m caption,labels

# Dry run (preview without executing)
docker compose exec photoprism photoprism vision run --dry-run

# List configured models
docker compose exec photoprism photoprism vision ls

# Schedule automatic runs (add to compose.yaml environment)
# PHOTOPRISM_VISION_SCHEDULE: "daily"
```

## Commands

```bash
cd ~/Projects/Photo/photoprism

# Start/stop
docker compose up -d
docker compose down

# View logs
docker compose logs -f

# Re-index
docker compose exec photoprism photoprism index
```

## Performance Tips

- **OLLAMA_KEEP_ALIVE**: Set to `5m`-`10m` so the model stays loaded between requests during batch processing
- **OLLAMA_NUM_PARALLEL=1**: Prevents memory pressure from concurrent requests
- **Single model for both tasks**: `qwen2.5vl:7b` for labels AND captions avoids model swap overhead
- **Update Ollama regularly**: Versions 0.17+ and 0.19+ (MLX backend) have major Apple Silicon optimizations

## Comparison with mcarch

| | budgie (M4 Mac) | mcarch (Arch Linux) |
|---|---|---|
| GPU | Apple M4 (Metal) | NVIDIA RTX 4070 Ti |
| RAM | 128GB unified | Separate CPU/GPU RAM |
| Ollama | Native (Metal) | Docker (CUDA) |
| Vision service | Not used | Used (kosmos-2, NSFW) |
| Caption model | qwen2.5vl:7b (Ollama) | kosmos-2 (local PyTorch) |
| Label model | qwen2.5vl:7b (Ollama) | llama3.2-vision (Ollama) |
| NSFW model | Built-in TensorFlow | nsfw_image_detector (PyTorch) |
| Docker-to-Ollama | `host.docker.internal` | `172.17.0.1` (docker0 bridge) |

## Known Issues

- Vision config file must be named `vision.yml` (not `vision.yaml`).
- Ollama model name is `qwen2.5vl` (no hyphen). `qwen2.5-vl` does not exist.
- If new folders appear in `~/Pictures`, they won't be indexed until added as a mount in `compose.yaml`.
