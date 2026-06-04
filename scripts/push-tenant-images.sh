#!/bin/sh

set -eu

IMAGE_PREFIX="${IMAGE_PREFIX:-registry.deti/tenant-pisofire}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
MEDUSA_IMAGE="$IMAGE_PREFIX/medusa:$IMAGE_TAG"
STOREFRONT_IMAGE="$IMAGE_PREFIX/storefront:$IMAGE_TAG"
POSTGRES_PATRONI_IMAGE="$IMAGE_PREFIX/postgres-patroni:$IMAGE_TAG"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command docker

echo "Pushing $MEDUSA_IMAGE"
docker push "$MEDUSA_IMAGE"

echo "Pushing $STOREFRONT_IMAGE"
docker push "$STOREFRONT_IMAGE"

echo "Pushing $POSTGRES_PATRONI_IMAGE"
docker push "$POSTGRES_PATRONI_IMAGE"

printf '%s\n' \
  "Images pushed:" \
  "  $MEDUSA_IMAGE" \
  "  $STOREFRONT_IMAGE" \
  "  $POSTGRES_PATRONI_IMAGE"
