#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
IMAGE_PREFIX="${IMAGE_PREFIX:-registry.deti/tenant-pisofire}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command kubectl

WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

cp -R "$ROOT_DIR/k8s" "$WORK_DIR/"
OVERLAY_DIR="$WORK_DIR/k8s/tenant"
SECRETS_FILE="$ROOT_DIR/k8s/tenant/tenant-secrets.env"

if [ ! -f "$SECRETS_FILE" ]; then
  echo "Missing tenant secrets file: $SECRETS_FILE" >&2
  echo "Create it from k8s/tenant/tenant-secrets.env.example before rendering." >&2
  exit 1
fi

for required_key in POSTGRES_PASSWORD POSTGRES_REPLICATION_PASSWORD DATABASE_URL JWT_SECRET COOKIE_SECRET REVALIDATE_SECRET MEDUSA_ADMIN_EMAIL MEDUSA_ADMIN_PASSWORD; do
  if ! grep -q "^$required_key=" "$SECRETS_FILE"; then
    echo "Missing $required_key in $SECRETS_FILE" >&2
    exit 1
  fi
done

cp "$SECRETS_FILE" "$OVERLAY_DIR/tenant-secrets.env"

(
  cd "$OVERLAY_DIR"
  kubectl kustomize . >/dev/null
  if command -v kustomize >/dev/null 2>&1; then
    kustomize edit set image \
      "my-medusa-store-medusa=$IMAGE_PREFIX/medusa:$IMAGE_TAG" \
      "my-medusa-store-storefront=$IMAGE_PREFIX/storefront:$IMAGE_TAG"
  else
    awk \
      -v medusa_image="$IMAGE_PREFIX/medusa" \
      -v storefront_image="$IMAGE_PREFIX/storefront" \
      -v image_tag="$IMAGE_TAG" '
        /^[[:space:]]*- name: my-medusa-store-medusa$/ {
          target = "medusa"
          print
          next
        }
        /^[[:space:]]*- name: my-medusa-store-storefront$/ {
          target = "storefront"
          print
          next
        }
        target == "medusa" && /^[[:space:]]*newName:/ {
          sub(/newName:.*/, "newName: " medusa_image)
          print
          next
        }
        target == "storefront" && /^[[:space:]]*newName:/ {
          sub(/newName:.*/, "newName: " storefront_image)
          print
          next
        }
        (target == "medusa" || target == "storefront") && /^[[:space:]]*newTag:/ {
          sub(/newTag:.*/, "newTag: " image_tag)
          print
          target = ""
          next
        }
        { print }
      ' kustomization.yaml > kustomization.yaml.tmp
    mv kustomization.yaml.tmp kustomization.yaml
  fi
  kubectl kustomize .
)
