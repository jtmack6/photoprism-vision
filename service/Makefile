export VIRTUAL_ENV := $(abspath "./venv")
export VIRTUAL_ENV_BIN := $(abspath "./venv/bin")
export PATH := $(VIRTUAL_ENV_BIN):$(PATH)

BUILD_GIT ?= $(shell (cd .. && git describe --always))
BUILD_DATE ?= $(shell date -u +%y%m%d)
BUILD_TAG ?= $(BUILD_DATE)-$(BUILD_GIT)

all: deps
deps: upgrade
install: install-venv
upgrade: remove-venv install-venv

build: docker-build
docker-build:
	docker compose --profile=all pull --ignore-pull-failures
	docker compose build

start:
	docker compose up -d
	docker compose logs -f || true
stop:
	docker compose down -v
terminal:
	docker compose exec photoprism-vision bash
logs:
	docker compose logs -f || true

venv: install-venv
remove-venv:
	rm -rf ./venv
install-venv:
	python3 -m venv venv
	. ./venv/bin/activate
	./venv/bin/pip3 install --disable-pip-version-check -r requirements.txt

.PHONY: all deps upgrade build docker-build remove-venv build deploy;
