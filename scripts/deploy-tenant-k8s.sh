#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-$ROOT_DIR/tenant-pisofire-kubeconfig.yaml}"
EXPECTED_CONTEXT="${EXPECTED_CONTEXT:-tenant-pisofire-context}"
NAMESPACE="${NAMESPACE:-tenant-pisofire}"
IMAGE_PREFIX="${IMAGE_PREFIX:-registry.deti/tenant-pisofire}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command kubectl

if [ ! -f "$KUBECONFIG_FILE" ]; then
  echo "Missing kubeconfig: $KUBECONFIG_FILE" >&2
  exit 1
fi

CURRENT_CONTEXT="$(kubectl --kubeconfig "$KUBECONFIG_FILE" config current-context 2>/dev/null || true)"

if [ "$CURRENT_CONTEXT" != "$EXPECTED_CONTEXT" ]; then
  echo "Refusing to deploy." >&2
  echo "Current context: $CURRENT_CONTEXT" >&2
  echo "Expected context: $EXPECTED_CONTEXT" >&2
  exit 1
fi

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
  echo "Create it from k8s/tenant/tenant-secrets.env.example before deploying." >&2
  exit 1
fi

for required_key in POSTGRES_PASSWORD DATABASE_URL JWT_SECRET COOKIE_SECRET REVALIDATE_SECRET MEDUSA_ADMIN_EMAIL MEDUSA_ADMIN_PASSWORD; do
  if ! grep -q "^$required_key=" "$SECRETS_FILE"; then
    echo "Missing $required_key in $SECRETS_FILE" >&2
    exit 1
  fi
done

cp "$SECRETS_FILE" "$OVERLAY_DIR/tenant-secrets.env"

if command -v kustomize >/dev/null 2>&1; then
  (
    cd "$OVERLAY_DIR"
    kustomize edit set image \
      "my-medusa-store-medusa=$IMAGE_PREFIX/medusa:$IMAGE_TAG" \
      "my-medusa-store-storefront=$IMAGE_PREFIX/storefront:$IMAGE_TAG"
  )
else
  sed -i \
    -e "s#registry.deti/tenant-pisofire/medusa#$IMAGE_PREFIX/medusa#g" \
    -e "s#registry.deti/tenant-pisofire/storefront#$IMAGE_PREFIX/storefront#g" \
    -e "s#newTag: latest#newTag: $IMAGE_TAG#g" \
    "$OVERLAY_DIR/kustomization.yaml"
fi

echo "Applying tenant overlay to namespace $NAMESPACE"
kubectl --kubeconfig "$KUBECONFIG_FILE" delete job bootstrap-admin -n "$NAMESPACE" --ignore-not-found
kubectl --kubeconfig "$KUBECONFIG_FILE" delete job bootstrap-store -n "$NAMESPACE" --ignore-not-found
kubectl --kubeconfig "$KUBECONFIG_FILE" apply -k "$OVERLAY_DIR"
kubectl --kubeconfig "$KUBECONFIG_FILE" rollout restart deployment/medusa deployment/medusa-worker deployment/storefront -n "$NAMESPACE"

echo "Done. Watch rollout with:"
echo "kubectl --kubeconfig $KUBECONFIG_FILE get pods -n $NAMESPACE -w"
