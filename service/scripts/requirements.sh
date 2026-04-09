#!/bin/bash

set -o errexit

VENV_DIRECTORY="/app/venv"

if [ ! -f "$VENV_DIRECTORY/bin/activate" ]; then
  echo "Creating python virtual environment..."
  python3 -m venv "$VENV_DIRECTORY"
  source "$VENV_DIRECTORY/bin/activate"
  pip install --disable-pip-version-check --no-cache-dir -r requirements.txt
else
  echo "venv already initialized"
fi
