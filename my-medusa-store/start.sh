#!/bin/sh

set -eu

max_attempts="${MEDUSA_MIGRATION_MAX_ATTEMPTS:-20}"
attempt=1

if [ "${MEDUSA_RUN_MIGRATIONS:-true}" = "true" ]; then
  echo "Running database migrations..."
  until npx medusa db:migrate; do
    if [ "$attempt" -ge "$max_attempts" ]; then
      echo "Database migrations failed after $attempt attempts."
      exit 1
    fi

    echo "Migration attempt $attempt failed. Retrying in 5 seconds..."
    attempt=$((attempt + 1))
    sleep 5
  done
else
  echo "Skipping database migrations."
fi

if [ "${MEDUSA_RUN_SEED:-false}" = "true" ]; then
  echo "Seeding database..."
  npm run seed
fi

if [ ! -f /server/.medusa/server/public/admin/index.html ]; then
  echo "Missing /server/.medusa/server/public/admin/index.html"
  echo "The Medusa production build is incomplete."
  exit 1
fi

echo "Starting Medusa production server..."
cd /server/.medusa/server
exec npm run start
