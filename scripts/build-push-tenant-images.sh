#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
IMAGE_PREFIX="${IMAGE_PREFIX:-registry.deti/tenant-pisofire}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
MEDUSA_IMAGE="$IMAGE_PREFIX/medusa:$IMAGE_TAG"
STOREFRONT_IMAGE="$IMAGE_PREFIX/storefront:$IMAGE_TAG"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command docker

echo "Building $MEDUSA_IMAGE"
docker build -t "$MEDUSA_IMAGE" "$ROOT_DIR/my-medusa-store"

echo "Building $STOREFRONT_IMAGE"
docker build -t "$STOREFRONT_IMAGE" "$ROOT_DIR/my-medusa-storefront"

echo "Pushing $MEDUSA_IMAGE"
docker push "$MEDUSA_IMAGE"

echo "Pushing $STOREFRONT_IMAGE"
docker push "$STOREFRONT_IMAGE"

printf '%s\n' \
  "Images pushed:" \
  "  $MEDUSA_IMAGE" \
  "  $STOREFRONT_IMAGE"
