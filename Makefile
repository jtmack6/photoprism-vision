BUILD_GIT ?= $(shell (cd .. && git describe --always))
BUILD_DATE ?= $(shell date -u +%y%m%d)
BUILD_TAG ?= $(BUILD_DATE)-$(BUILD_GIT)

all: deps
deps: sync
install: sync

sync:
	uv sync

build: docker-build
docker-build:
	(cd service && make docker-build)

preview: docker-preview
docker-preview:
	./build.sh service linux/amd64

release: docker-release
docker-release:
	./build.sh service linux/amd64,linux/arm64 $(BUILD_DATE)

ollama:
	docker compose pull ollama
	docker compose up -d ollama --remove-orphans
	docker compose exec ollama ollama run llama3.2-vision
ollama-down:
	docker compose down ollama --remove-orphans
start:
	docker compose --profile=all pull --ignore-pull-failures
	docker compose up -d
	docker compose logs -f || true
stop:
	docker compose down -v
terminal:
	docker compose exec photoprism-vision bash
logs:
	docker compose logs -f || true

export-requirements:
	uv export --no-hashes --no-dev -o service/requirements.txt

# Declare all targets as "PHONY", see https://www.gnu.org/software/make/manual/html_node/Phony-Targets.html.
MAKEFLAGS += --always-make
