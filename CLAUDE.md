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
- `service/ollama_processor.py` — Sends base64-encoded images to Ollama API. JSON schema responses parsed for structured output. Only sends one image at a time (most vision models don't support multi-image).

### Local Models

| Model name | HuggingFace model | Task | Notes |
|---|---|---|---|
| `kosmos-2` | `microsoft/kosmos-2-patch14-224` | Caption | Default. Always uses its own grounding prompt; ignores custom prompts. |
| `vit-gpt2` | `nlpconnect/vit-gpt2-image-captioning` | Caption | Broken with current `transformers` (`_reorder_cache` error) |
| `blip` | `Salesforce/blip-image-captioning-large` | Caption | Working alternative to kosmos-2 |
| `nsfw_image_detector` | `Freepik/nsfw_image_detector` | NSFW | Classifies Neutral/Drawing/Hentai/Porn/Sexy |

**Label generation is only supported via Ollama**, not local models.

### Key Environment Variables

| Variable | Description |
|---|---|
| `OLLAMA_ENABLED` | Enable Ollama processor |
| `OLLAMA_HOST` | Ollama API URL (default: `http://ollama:11434`) |
| `OLLAMA_MODEL` | Default Ollama model name |
| `OLLAMA_CAPTION_PROMPT` | Custom prompt for captions |
| `OLLAMA_LABELS_PROMPT` | Custom prompt for label generation |
| `OLLAMA_NSFW_PROMPT` | Custom prompt for NSFW detection |
| `GUNICORN_TIMEOUT` | Worker timeout in seconds (default: 120). Increase for slow Ollama inference. |

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
- `compose.yaml` (root) — Defines `photoprism-vision` (host port 5050, container port 5000) and `ollama` (port 11434) services with NVIDIA GPU support
- All `service/*.py` and `service/scripts/*.sh` are bind-mounted into the container for development without rebuilding the image
- Models and venv are stored in named Docker volumes to persist across restarts
- Entrypoint runs as root, `chown`s volume mounts, then `gosu`s to UID 1000 — do **not** set `user:` in compose.yaml (breaks permissions on native Linux)
- Gunicorn timeout defaults to 120s — configurable via `GUNICORN_TIMEOUT` env var

### Testing photoprism-vision

Service runs on host port 5050. Test with:
```bash
# Caption (default model: kosmos-2)
curl -s -X POST http://127.0.0.1:5050/api/v1/vision/caption \
  -H "Content-Type: application/json" \
  -d '{"url":"https://dl.photoprism.app/img/team/avatar.jpg"}' | python3 -m json.tool

# Labels (via Ollama)
curl -s -X POST http://127.0.0.1:5050/api/v1/vision/labels/llama3.2-vision/latest \
  -H "Content-Type: application/json" \
  -d '{"url":"https://dl.photoprism.app/img/team/avatar.jpg"}' | python3 -m json.tool

# NSFW detection
curl -s -X POST http://127.0.0.1:5050/api/v1/vision/nsfw/nsfw_image_detector/latest \
  -H "Content-Type: application/json" \
  -d '{"url":"https://dl.photoprism.app/img/team/avatar.jpg"}' | python3 -m json.tool
```

### Known Bugs Fixed

- **Caption prompt echo** — Kosmos-2 was echoing PhotoPrism's custom prompt back as the caption text. Fixed by always using the model's native grounding prompt.
- **Labels multi-image error** — `llama3.2-vision` only supports one image per request. Fixed `OllamaImageProcessor.generate_labels()` to send only the first image.
- **Gunicorn worker timeout** — Ollama inference can exceed the default 30s gunicorn timeout. Increased to 120s (configurable).
- **Docker volume permissions** — Named volumes owned by root caused permission denied on native Linux. Fixed by `chown` in entrypoint before `gosu`.
- **`parse_model_info_from_request()`** — Used to raise `ValueError` when no model was specified. Fixed to default to `kosmos-2` (configurable via `DEFAULT_MODEL` env var).
- **Flask bind address** — `app.run()` now binds to `0.0.0.0` so the service is reachable from other hosts.
- **`transformers` version** — `==4.41.2` (original pin) is too old. `TimmWrapperForImageClassification` requires >=4.45.0. Use `>=4.53.2,<5.0` (v5 removed `AutoModelForVision2Seq`).
