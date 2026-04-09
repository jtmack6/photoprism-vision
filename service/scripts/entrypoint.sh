#!/bin/bash

# Fix ownership of mounted volumes so the app user can write to them
if [ ! -z "$PHOTOPRISM_UID" ]; then
  chown -R "$PHOTOPRISM_UID:${PHOTOPRISM_GID:-$PHOTOPRISM_UID}" /app/venv /app/models 2>/dev/null || true
fi

/app/scripts/requirements.sh

. ./venv/bin/activate

if [ ! -z "$PHOTOPRISM_UID" ]; then
  echo "Switching to user id $PHOTOPRISM_UID..."
  exec gosu $PHOTOPRISM_UID gunicorn "$@"
else
  # Run as default user
  exec gunicorn "$@"
fi
