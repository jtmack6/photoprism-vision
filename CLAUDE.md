# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A computer vision API service that integrates with PhotoPrism to provide image captioning, label generation, and NSFW detection. Supports both local PyTorch/HuggingFace models and remote Ollama inference.

## Commands

```bash
# Local development (uv)
make deps                    # Install dependencies via uv sync
make export-requirements     # Regenerate service/requirements.txt from pyproject.toml

# Docker (from repo root)
make start                   # Pull images, start all services, tail logs
make stop                    # Stop and remove containers/volumes
make logs                    # Tail container logs
make terminal                # Shell into running photoprism-vision container

# Docker build
make build                   # Build Docker image
make preview                 # Build for linux/amd64
make release                 # Build multi-arch (amd64 + arm64)

# Ollama
make ollama                  # Start Ollama service and pull llama3.2-vision
make ollama-down             # Stop Ollama service
```

**No automated tests exist in this project.**

## Architecture

All service code is in `service/`. The root `Makefile` and `compose.yaml` are thin wrappers around the `service/` subdirectory equivalents.

### Request Flow

1. Flask app (`service/app.py`) receives requests at `/api/v1/vision/{caption,labels,nsfw}[/<model>/<version>]`
2. Routes to either `LocalImageProcessor` or `OllamaImageProcessor` based on `OLLAMA_ENABLED` env var and requested model
3. Processors return `api.py` Pydantic models wrapped in `ApiResponse`

### Processor Design

- `service/processor.py` — Abstract base class defining the interface: `can_process()`, `generate_caption()`, `generate_labels()`, `detect_nsfw()`
- `service/local_processor.py` — Lazy-loading PyTorch models from HuggingFace. Factory pattern creates model-specific processors (Kosmos-2, ViT-GPT2, BLIP, NSFW detector). Models download on first use.
- `service/ollama_processor.py` — Sends base64-encoded images to Ollama API. JSON schema responses parsed for structured output.

### Local Models

| Model name | HuggingFace model | Task |
|---|---|---|
| `kosmos-2` | `microsoft/kosmos-2-patch14-224` | Caption |
| `vit-gpt2` | `nlpconnect/vit-gpt2-image-captioning` | Caption |
| `blip` | `Salesforce/blip-image-captioning-large` | Caption |
| `nsfw_image_detector` | `Falconsai/nsfw_image_detection` | NSFW |

### Key Environment Variables

| Variable | Description |
|---|---|
| `OLLAMA_ENABLED` | Enable Ollama processor |
| `OLLAMA_HOST` | Ollama API URL (default: `http://ollama:11434`) |
| `OLLAMA_MODEL` | Default Ollama model name |
| `OLLAMA_CAPTION_PROMPT` | Custom prompt for captions |
| `OLLAMA_LABELS_PROMPT` | Custom prompt for label generation |
| `OLLAMA_NSFW_PROMPT` | Custom prompt for NSFW detection |

### API Request Format

Requests accept JSON body or URL query parameters:
```json
{
  "url": "https://example.com/image.jpg",
  "model": "kosmos-2",
  "version": "latest",
  "prompt": "optional custom prompt",
  "id": "optional-uuid"
}
```

Or base64 images: `{"images": ["data:image/png;base64,..."]}`

### Docker Setup

- `service/Dockerfile` — Python 3.12-slim, runs as UID 1000, venv initialized at container start via `service/scripts/entrypoint.sh`
- `compose.yaml` (root) — Defines `photoprism-vision` (host port 5050, container port 5000) and `ollama` (port 11434) services with GPU support
- All `service/*.py` and `service/scripts/*.sh` are bind-mounted into the container for development without rebuilding
- Models and venv are stored in named Docker volumes to persist across restarts
- Entrypoint runs as root, `chown`s volume mounts, then `gosu`s to UID 1000 — do not set `user:` in compose.yaml (breaks permissions on native Linux)

## Infrastructure Notes

### Hosts

- **mcarch** — Arch Linux development machine (192.168.1.118). Runs PhotoPrism + photoprism-vision + Ollama via Docker. Has NVIDIA RTX 4070 Ti GPU.
- **budgie.grave.loco** — M4 Mac, 128GB RAM. Previously ran the stack via Colima (Docker)
- **kuc.grave.loco** — Synology NAS with photo library (NFS source, 192.168.1.16)

### PhotoPrism Setup (`../photoprism/`)

PhotoPrism runs in Docker on mcarch. Config at `../photoprism/compose.yaml`.

**NFS mounts from kuc** — three read-only NFS4.1 shares mounted on mcarch:
```
kuc.grave.loco:/rocket/Pictures        → /mnt/kuc-pictures
kuc.grave.loco:/mnt/extpool/pictures   → /mnt/extpool-pix
kuc.grave.loco:/Pictures               → /mnt/pics
```

**Volume mounts in compose.yaml** — each NFS share is a subdirectory under `/photoprism/originals`:
```yaml
- "/mnt/kuc-pictures:/photoprism/originals/kuc-pictures"
- "/mnt/extpool-pix:/photoprism/originals/extpool-pix"
- "/mnt/pics:/photoprism/originals/pics"
```

**NFS permission issue** — ~46 files on kuc have `0640`/`0700` permissions and are unreadable by PhotoPrism. Fix on kuc:
```bash
find /mnt/extpool/pictures -type f ! -perm -o=r -exec chmod o+r {} +
find /rocket/Pictures -type f ! -perm -o=r -exec chmod o+r {} +
```

**Clean restart:**
```bash
docker compose down -v
rm -rf ./storage
docker compose up -d
```

**vision.yml** (`../photoprism/storage/config/vision.yml`) — PhotoPrism's AI model config. Configured with `Engine: vision` pointing at `http://host.docker.internal:5050` for caption, labels, and NSFW. PhotoPrism's compose.yaml has `extra_hosts: host.docker.internal:host-gateway` to enable this.

**Vision models are not run during indexing.** They must be triggered separately:
```bash
# Manual run (after indexing completes)
docker compose exec photoprism photoprism vision run -m caption,labels,nsfw

# Or set a schedule in compose.yaml environment:
PHOTOPRISM_VISION_SCHEDULE: "daily"
```

Other useful vision commands:
```bash
docker compose exec photoprism photoprism vision ls      # List configured models
docker compose exec photoprism photoprism vision run --dry-run  # Preview without executing
```

### Testing photoprism-vision

Service runs on host port 5050. Test with:
```bash
# Caption (default model: kosmos-2)
curl -s -X POST http://127.0.0.1:5050/api/v1/vision/caption \
  -H "Content-Type: application/json" \
  -d '{"url":"https://dl.photoprism.app/img/team/avatar.jpg"}' | python3 -m json.tool

# NSFW detection
curl -s -X POST http://127.0.0.1:5050/api/v1/vision/nsfw/nsfw_image_detector/latest \
  -H "Content-Type: application/json" \
  -d '{"url":"https://dl.photoprism.app/img/team/avatar.jpg"}' | python3 -m json.tool
```

Note: `vit-gpt2` model has a known `_reorder_cache` compatibility issue with current `transformers` versions.

### Known Bugs Fixed

- `parse_model_info_from_request()` used to raise `ValueError` when no model was specified. Fixed to default to `kosmos-2` (configurable via `DEFAULT_MODEL` env var).
- Flask `app.run()` now binds to `0.0.0.0` so the service is reachable from other hosts.
- `transformers==4.41.2` (original pin) is too old — `TimmWrapperForImageClassification` requires >=4.45.0. Use `>=4.53.2,<5.0` (v5 removed `AutoModelForVision2Seq`).
