#!/bin/sh

set -eu

max_attempts="${MEDUSA_MIGRATION_MAX_ATTEMPTS:-20}"
attempt=1

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

if [ "${MEDUSA_RUN_SEED:-false}" = "true" ]; then
  echo "Seeding database..."
  npm run seed
fi

echo "Starting Medusa development server..."
exec npm run dev
