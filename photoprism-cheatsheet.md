# PhotoPrism Cheatsheet

Quick reference for common PhotoPrism CLI and MariaDB operations. All commands assume `cd ~/Projects/Photo/photoprism` first.

## Start / Stop

```bash
# Start the stack
docker compose up -d

# Stop
docker compose down

# Tail logs
docker compose logs -f photoprism

# Restart just PhotoPrism (e.g. after vision.yml change)
docker compose restart photoprism
```

## Indexing

Indexing scans the originals mounts, extracts EXIF, generates thumbnails, and populates the database. Vision models are **not** run during indexing — they must be triggered separately.

```bash
# Index all originals
docker compose exec photoprism photoprism index

# Force re-index (re-process even unchanged files)
docker compose exec photoprism photoprism index --force

# Clean up stale index entries (files that no longer exist on disk)
docker compose exec photoprism photoprism cleanup

# Index a specific subdirectory
docker compose exec photoprism photoprism index "Apple Photos/0"
```

## Vision Processing

Caption and label generation via Ollama (qwen2.5vl:7b on the Mac).

```bash
# List configured vision models
docker compose exec photoprism photoprism vision ls

# Dry run (preview without executing)
docker compose exec photoprism photoprism vision run --dry-run

# Test on a single image first
docker compose exec photoprism photoprism vision run -m caption --count 1 --force
docker compose exec photoprism photoprism vision run -m labels --count 1 --force

# Process full library (both tasks — recommended)
docker compose exec photoprism photoprism vision run -m caption,labels

# Only captions, only labels
docker compose exec photoprism photoprism vision run -m caption
docker compose exec photoprism photoprism vision run -m labels

# Force re-run (overwrite existing captions/labels)
docker compose exec photoprism photoprism vision run -m caption,labels --force
```

## Inspection — MariaDB Queries

All queries below use the MariaDB CLI inside the container:

```bash
docker compose exec mariadb mariadb -uphotoprism -pinsecure photoprism -e "<QUERY>"
```

### Coverage stats

```bash
docker compose exec mariadb mariadb -uphotoprism -pinsecure photoprism -e "
SELECT 
  COUNT(*) as total,
  SUM(CASE WHEN photo_caption != '' THEN 1 ELSE 0 END) as captioned,
  (SELECT COUNT(DISTINCT photo_id) FROM photos_labels) as with_labels
FROM photos WHERE deleted_at IS NULL;"
```

### Sample random captions

```bash
docker compose exec mariadb mariadb -uphotoprism -pinsecure photoprism -e "
SELECT photo_name, photo_caption 
FROM photos 
WHERE photo_caption != '' AND deleted_at IS NULL
ORDER BY RAND() LIMIT 20;"
```

### Top labels by frequency

```bash
docker compose exec mariadb mariadb -uphotoprism -pinsecure photoprism -e "
SELECT l.label_name, l.label_slug, COUNT(*) as count
FROM labels l
JOIN photos_labels pl ON pl.label_id = l.id
GROUP BY l.id
ORDER BY count DESC
LIMIT 30;"
```

### Caption length distribution

Spot outliers — very short captions are usually model failures, very long ones may have ignored the one-sentence prompt.

```bash
docker compose exec mariadb mariadb -uphotoprism -pinsecure photoprism -e "
SELECT 
  MIN(CHAR_LENGTH(photo_caption)) as shortest,
  AVG(CHAR_LENGTH(photo_caption)) as avg_len,
  MAX(CHAR_LENGTH(photo_caption)) as longest
FROM photos WHERE photo_caption != '';"
```

### Find weird/failed captions

```bash
# Very short captions (likely failures)
docker compose exec mariadb mariadb -uphotoprism -pinsecure photoprism -e "
SELECT photo_name, photo_caption 
FROM photos 
WHERE photo_caption != '' AND CHAR_LENGTH(photo_caption) < 30 
LIMIT 20;"

# Captions starting with banned phrases (the prompt tells the model to avoid these)
docker compose exec mariadb mariadb -uphotoprism -pinsecure photoprism -e "
SELECT photo_name, photo_caption 
FROM photos 
WHERE photo_caption LIKE 'This image%' 
   OR photo_caption LIKE 'The image%' 
   OR photo_caption LIKE 'A picture%' 
LIMIT 20;"
```

### Photos per source folder

See how many photos came from each mount point and their caption coverage.

```bash
docker compose exec mariadb mariadb -uphotoprism -pinsecure photoprism -e "
SELECT 
  SUBSTRING_INDEX(photo_path, '/', 1) as folder,
  COUNT(*) as photos,
  SUM(CASE WHEN photo_caption != '' THEN 1 ELSE 0 END) as captioned
FROM photos WHERE deleted_at IS NULL
GROUP BY folder ORDER BY photos DESC;"
```

### Photos with no labels

```bash
docker compose exec mariadb mariadb -uphotoprism -pinsecure photoprism -e "
SELECT p.photo_name, p.photo_path
FROM photos p
LEFT JOIN photos_labels pl ON pl.photo_id = p.id
WHERE pl.photo_id IS NULL AND p.deleted_at IS NULL
LIMIT 20;"
```

### Total photo count (by deletion status)

```bash
docker compose exec mariadb mariadb -uphotoprism -pinsecure photoprism -e "
SELECT 
  CASE WHEN deleted_at IS NULL THEN 'active' ELSE 'deleted' END as status,
  COUNT(*) as count
FROM photos GROUP BY status;"
```

## Inspection — PhotoPrism CLI

```bash
# Server status
docker compose exec photoprism photoprism status

# Show counts (photos, albums, files, etc.)
docker compose exec photoprism photoprism show counts

# Show active config
docker compose exec photoprism photoprism show config

# Filter config for vision settings
docker compose exec photoprism photoprism show config | grep -i vision

# List vision models
docker compose exec photoprism photoprism vision ls
```

## Backup / Restore

```bash
# Backup database
docker compose exec photoprism photoprism backup -a -i

# Backup albums as YAML sidecar files
docker compose exec photoprism photoprism backup --albums

# Restore
docker compose exec photoprism photoprism restore -a -i
```

## Troubleshooting

```bash
# View recent vision errors
docker compose logs photoprism 2>&1 | grep -i "vision.*error"

# Check if Ollama is reachable from PhotoPrism container
docker compose exec photoprism curl -s http://host.docker.internal:11434/api/tags

# See what vision processed most recently
docker compose logs --tail 100 photoprism | grep vision
```

## Clean Rebuild (Nuclear Option)

When changing volume mounts or if the database gets into a weird state:

```bash
cd ~/Projects/Photo/photoprism

# 1. Stop everything
docker compose down

# 2. Remove database volume and storage
docker volume rm photoprism_database
rm -rf ./storage

# 3. Recreate vision config
mkdir -p ./storage/config
# (copy vision.yml from photoprism-mac-m4.md)

# 4. Start fresh and re-index
docker compose up -d
docker compose exec photoprism photoprism index
```
