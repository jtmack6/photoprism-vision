# PhotoPrism on Arch Linux (mcarch)

Comprehensive guide to the PhotoPrism + photoprism-vision deployment on mcarch.

## Host Machine

| | |
|---|---|
| **Hostname** | mcarch (192.168.1.118) |
| **OS** | Arch Linux |
| **Desktop** | Hyprland via SDDM (omarchy) |
| **GPU** | NVIDIA GeForce RTX 4070 Ti (12GB VRAM) |
| **Docker** | Native (not Colima/Docker Desktop) |

## Network Topology

```
mcarch (192.168.1.118)
├── Docker: PhotoPrism        :2342  (photoprism/photoprism:latest)
├── Docker: MariaDB           :3306  (mariadb:11)
├── Docker: photoprism-vision :5050  (photoprism/vision:latest)
├── Docker: Ollama            :11434 (ollama/ollama:latest)
└── NFS mounts (read-only from kuc)

kuc.grave.loco (192.168.1.16) — Synology NAS
├── /rocket/Pictures          → /mnt/kuc-pictures
├── /mnt/extpool/pictures     → /mnt/extpool-pix
└── /Pictures                 → /mnt/pics

budgie.grave.loco (192.168.1.179) — M4 Pro Mac, 128GB RAM
└── Ollama :11434 (available for remote inference, has llama3.2-vision:90b)
```

## Docker Compose Projects

Two separate compose projects, each with their own network:

### 1. PhotoPrism (`~/Projects/Photo/photoprism/`)

Services: `photoprism`, `mariadb`

```bash
cd ~/Projects/Photo/photoprism
docker compose up -d          # Start
docker compose down           # Stop
docker compose logs -f        # Tail logs
```

Key configuration (`compose.yaml`):
- `extra_hosts: host.docker.internal:host-gateway` — allows container to reach host services
- `PHOTOPRISM_SITE_URL: "http://mcarch.grave.loco:2342/"`
- `PHOTOPRISM_VISION_SCHEDULE: "daily"` — runs vision models on a daily schedule
- `PHOTOPRISM_DETECT_NSFW: "false"` — NSFW auto-flagging during indexing is off
- MariaDB with 512MB InnoDB buffer pool, exposed on port 3306
- Database credentials: `photoprism` / `insecure` (private network only)

### 2. photoprism-vision (`~/Projects/Photo/photoprism-vision/`)

Services: `photoprism-vision`, `ollama`

```bash
cd ~/Projects/Photo/photoprism-vision
docker compose up -d          # Start
docker compose down           # Stop
docker compose logs -f        # Tail logs
```

## NFS Mounts

Three NFS4.1 read-only mounts from kuc, configured in `/etc/fstab` or mounted manually:

```
kuc.grave.loco:/rocket/Pictures        /mnt/kuc-pictures  nfs4  ro,soft,intr  0 0
kuc.grave.loco:/mnt/extpool/pictures   /mnt/extpool-pix   nfs4  ro,soft,intr  0 0
kuc.grave.loco:/Pictures               /mnt/pics          nfs4  ro,soft,intr  0 0
```

These are mounted into PhotoPrism as subdirectories under `/photoprism/originals`:
```yaml
- "/mnt/kuc-pictures:/photoprism/originals/kuc-pictures"
- "/mnt/extpool-pix:/photoprism/originals/extpool-pix"
- "/mnt/pics:/photoprism/originals/pics"
```

### NFS Permission Issue

~46 files on kuc have `0640`/`0700` permissions, making them unreadable by PhotoPrism. Fix on kuc:
```bash
find /mnt/extpool/pictures -type f ! -perm -o=r -exec chmod o+r {} +
find /rocket/Pictures -type f ! -perm -o=r -exec chmod o+r {} +
```

## Computer Vision Pipeline

PhotoPrism uses `vision.yml` to route vision tasks to the photoprism-vision API.

### vision.yml (`storage/config/vision.yml`)

```yaml
Models:
- Type: caption
  Model: kosmos-2
  Engine: vision
  Run: auto
  Service:
    Uri: http://172.17.0.1:5050/api/v1/vision/caption
- Type: labels
  Model: llama3.2-vision
  Engine: vision
  Run: auto
  Service:
    Uri: http://172.17.0.1:5050/api/v1/vision/labels
- Type: nsfw
  Model: nsfw_image_detector
  Engine: vision
  Run: auto
  Service:
    Uri: http://172.17.0.1:5050/api/v1/vision/nsfw
```

**Important:** Use `172.17.0.1` (docker0 bridge IP), not `host.docker.internal` — the latter resolves correctly but connections time out on this host.

### Model Performance

| Task | Model | Backend | Typical Speed |
|---|---|---|---|
| Caption | kosmos-2 | Local PyTorch (CPU) | ~130ms |
| Labels | llama3.2-vision:latest | Ollama (RTX 4070 Ti GPU) | ~7s |
| NSFW | nsfw_image_detector | Local PyTorch (CPU) | ~250ms |
| Face detection | facenet | TensorFlow (built-in) | Runs during indexing |

### Running Vision Models

**Vision models do not run during indexing.** They must be triggered separately.

```bash
cd ~/Projects/Photo/photoprism

# Run all vision models
docker compose exec photoprism photoprism vision run -m caption,labels,nsfw

# Run specific model type
docker compose exec photoprism photoprism vision run -m labels

# Force re-process (overwrite existing data)
docker compose exec photoprism photoprism vision run -m caption,labels,nsfw --force

# Limit number of pictures
docker compose exec photoprism photoprism vision run -m labels -n 100

# Preview without executing
docker compose exec photoprism photoprism vision run -m labels --dry-run

# List configured models
docker compose exec photoprism photoprism vision ls

# Reset vision data (interactive confirmation required)
echo "y" | docker compose exec -T photoprism photoprism vision reset -m caption
```

`PHOTOPRISM_VISION_SCHEDULE: "daily"` is set, so vision models also run automatically once per day.

### Data Source Priorities

Vision data has different priority levels. Use `--source` to control which level to write at:

| Source | Priority | Use |
|---|---|---|
| `image` | 8 | Built-in TensorFlow (during indexing) |
| `ollama` | 16 | Ollama direct |
| `vision` | 64 | External vision API (manual) |

Higher priority sources overwrite lower ones. `--force` is needed to overwrite same-priority data.

## GPU and VRAM Management

The RTX 4070 Ti has 12GB VRAM. The Hyprland desktop (via SDDM) typically consumes ~7.7GB, leaving insufficient room for large Ollama models.

### For best vision performance, stop the desktop:

```bash
# Switch to TTY first: Ctrl+Alt+F2
sudo systemctl stop sddm       # Frees ~7.7GB VRAM

# Restart when done
sudo systemctl start sddm
```

With SDDM stopped, `llama3.2-vision` runs fully on GPU at ~7s/image. With SDDM running, it falls back to CPU at ~45s+/image.

### NVIDIA Container Toolkit

Both `photoprism-vision` and `ollama` containers have GPU access via:
```yaml
deploy:
  resources:
    reservations:
      devices:
        - driver: "nvidia"
          capabilities: [ gpu ]
          count: "all"
```

Check GPU status from inside a container:
```bash
docker compose exec ollama nvidia-smi
```

## photoprism-vision Container Details

The container runs the upstream `photoprism/vision:latest` image but bind-mounts all local source files for development:

```yaml
volumes:
  - models:/app/models                                      # HuggingFace model cache
  - venv:/app/venv                                          # Python virtual environment
  - ./service/scripts/requirements.sh:/app/scripts/requirements.sh:ro
  - ./service/scripts/entrypoint.sh:/app/scripts/entrypoint.sh:ro
  - ./service/app.py:/app/app.py:ro
  - ./service/api.py:/app/api.py:ro
  - ./service/local_processor.py:/app/local_processor.py:ro
  - ./service/ollama_processor.py:/app/ollama_processor.py:ro
  - ./service/processor.py:/app/processor.py:ro
  - ./service/utils.py:/app/utils.py:ro
```

Code changes take effect after `docker compose restart photoprism-vision` — no rebuild needed.

### Startup Sequence

1. Entrypoint runs as root
2. `chown` venv and models volumes to `PHOTOPRISM_UID` (1000)
3. `requirements.sh` creates venv and installs packages if not already present
4. `gosu` switches to UID 1000
5. Gunicorn starts with 120s worker timeout
6. All HuggingFace models are downloaded on first boot (~5GB total)

### Port Conflict

Host port 5050 is used (not 5000) because `shairport-sync` (AirPlay) binds to port 5000 on Arch.

## Ollama Container

Local Ollama runs with NVIDIA GPU support. Models are stored in a named Docker volume.

```bash
# Pull a model
docker compose exec ollama ollama pull llama3.2-vision

# List models
docker compose exec ollama ollama list

# Interactive chat
docker compose exec ollama ollama run llama3.2-vision
```

Available models on mcarch: `llama3.2-vision:latest`, `moondream:latest`, `qwen2.5vl:3b`

Key settings:
- `OLLAMA_KEEP_ALIVE: "10m"` — models unload after 10 minutes of inactivity
- `OLLAMA_MAX_LOADED_MODELS: "1"` — only one model in memory at a time (VRAM constraint)
- `OLLAMA_CONTEXT_LENGTH: "4096"`

## Common Operations

### Fresh Install

```bash
# 1. Start PhotoPrism + MariaDB
cd ~/Projects/Photo/photoprism
docker compose up -d

# 2. Start photoprism-vision + Ollama
cd ~/Projects/Photo/photoprism-vision
docker compose up -d    # First boot downloads ~5GB of HuggingFace models

# 3. Pull Ollama vision model
docker compose exec ollama ollama pull llama3.2-vision

# 4. Create vision.yml (PhotoPrism creates storage/config/ on first start)
# Copy the vision.yml content from the "vision.yml" section above

# 5. Index photos
cd ~/Projects/Photo/photoprism
docker compose exec photoprism photoprism index

# 6. Run vision models (after indexing completes)
docker compose exec photoprism photoprism vision run -m caption,labels,nsfw
```

### Clean Restart (PhotoPrism)

Destroys all indexed data and starts fresh:
```bash
cd ~/Projects/Photo/photoprism
docker compose down -v
rm -rf ./storage
docker compose up -d
```

### Clean Restart (photoprism-vision)

Destroys venv and downloaded models:
```bash
cd ~/Projects/Photo/photoprism-vision
docker compose down -v
docker compose up -d    # Will re-download everything
```

### Database Access

```bash
cd ~/Projects/Photo/photoprism
docker compose exec mariadb mariadb -u photoprism -pinsecure photoprism

# Example: check caption data
SELECT photo_caption, caption_src FROM photos
WHERE photo_caption != '' ORDER BY updated_at DESC LIMIT 10;
```

### Debugging

```bash
# Vision service logs
cd ~/Projects/Photo/photoprism-vision
docker compose logs --tail 50 photoprism-vision

# PhotoPrism with debug logging
cd ~/Projects/Photo/photoprism
docker compose exec -e PHOTOPRISM_LOG_LEVEL=debug photoprism photoprism vision run -m labels -n 1

# Check container networking
docker compose exec photoprism curl -s http://172.17.0.1:5050/api/v1/vision/caption \
  -H "Content-Type: application/json" \
  -d '{"url":"https://dl.photoprism.app/img/team/avatar.jpg"}'
```

## Remote Ollama (budgie)

budgie.grave.loco (192.168.1.179) runs Ollama with `llama3.2-vision:90b` (55GB, M4 Pro with 128GB RAM). It produces higher quality labels (8 detailed labels vs 1-3 from the 11b model) but is slower (~26s/image vs ~7s local GPU).

To use budgie for labels, change vision.yml:
```yaml
- Type: labels
  Model: llama3.2-vision:90b
  Engine: ollama
  Service:
    Uri: http://192.168.1.179:11434/api/generate
```

**Note:** The PhotoPrism container cannot resolve local hostnames (`budgie.grave.loco`) — use the IP address. Docker's internal DNS (`127.0.0.11`) only resolves container names, not LAN hosts.
