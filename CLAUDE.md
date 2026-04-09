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
- `compose.yaml` (root) — Defines `photoprism-vision` (port 5000) and `ollama` (port 11434) services with GPU support
- Models and venv are stored in named Docker volumes to persist across restarts

## Infrastructure Notes

### Hosts

- **budgie.grave.loco** — M4 Mac, 128GB RAM. Runs PhotoPrism + Ollama + photoprism-vision via Colima (Docker)
- **kuc.grave.loco** — NAS with photo library (NFS source)
- **mcarch** — development machine

### PhotoPrism Setup (`../photoprism/`)

PhotoPrism runs in Docker via Colima on budgie. Config at `../photoprism/compose.yaml`.

**NFS mounts** — must be manually mounted inside the Colima VM on each restart (not yet automated). To make permanent, add to `~/.colima/default/colima.yaml` on budgie:

```yaml
provision:
  - mode: system
    script: |
      mkdir -p /mnt/kuc-pictures /mnt/extpool-pix /mnt/pics
      mount -t nfs -o ro,soft,intr,nfsvers=4.1 kuc.grave.loco:/rocket/Pictures /mnt/kuc-pictures
      mount -t nfs -o ro,soft,intr,nfsvers=4.1 kuc.grave.loco:/mnt/extpool/pictures /mnt/extpool-pix
      mount -t nfs -o ro,soft,intr,nfsvers=4.1 kuc.grave.loco:/Pictures /mnt/pics
```

**Volume mounts in compose.yaml** — each NFS share is a subdirectory under `/photoprism/originals`:
```yaml
- "~/Pictures:/photoprism/originals/local"
- "/mnt/kuc-pictures:/photoprism/originals/kuc-pictures"
- "/mnt/extpool-pix:/photoprism/originals/extpool-pix"
- "/mnt/pics:/photoprism/originals/pics"
```

**Clean restart:**
```bash
docker compose down -v
rm -rf ./storage
docker compose up -d
```

**vision.yml** (`../photoprism/storage/config/vision.yml`) — PhotoPrism's AI model config. Currently configured for Ollama labels via `gemma3:latest` at `http://budgie.grave.loco:11434/api/generate`.

### photoprism-vision on budgie

Run directly (not via Docker) from `service/` using the `venv`:
```bash
cd ~/Projects/Photo/photoprism-vision/service
./venv/bin/python app.py
```

Service binds to `0.0.0.0:5000`. Test with:
```bash
curl -s -X POST http://127.0.0.1:5000/api/v1/vision/caption -H "Content-Type: application/json" -d '{"url":"https://dl.photoprism.app/img/team/avatar.jpg"}' | python3 -m json.tool
```

Note: use `127.0.0.1` not `localhost` on macOS to avoid IPv6 resolution issues.

### Known Bugs Fixed

- `parse_model_info_from_request()` used to raise `ValueError` when no model was specified. Fixed to default to `kosmos-2` (configurable via `DEFAULT_MODEL` env var).
- Flask `app.run()` now binds to `0.0.0.0` so the service is reachable from other hosts.
- `transformers==4.41.2` (original pin) is too old — `TimmWrapperForImageClassification` requires >=4.45.0. Use `>=4.53.2,<5.0` (v5 removed `AutoModelForVision2Seq`).
