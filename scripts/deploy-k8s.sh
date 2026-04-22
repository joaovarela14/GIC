#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLUSTER_NAME="${1:-pisofire}"
NAMESPACE="${NAMESPACE:-pisofire}"
MEDUSA_IMAGE="my-medusa-store-medusa:latest"
STOREFRONT_IMAGE="my-medusa-store-storefront:latest"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command docker
require_command k3d
require_command kubectl

CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
EXPECTED_CONTEXT="k3d-$CLUSTER_NAME"

if [ -z "$CURRENT_CONTEXT" ]; then
  echo "No current kubectl context is set." >&2
  echo "Select your local test cluster before running this script." >&2
  exit 1
fi

if [ "$CURRENT_CONTEXT" != "$EXPECTED_CONTEXT" ]; then
  echo "Refusing to deploy." >&2
  echo "Current context: $CURRENT_CONTEXT" >&2
  echo "Expected context: $EXPECTED_CONTEXT" >&2
  echo "Switch context manually, then rerun." >&2
  exit 1
fi

echo "Building $MEDUSA_IMAGE"
docker build -t "$MEDUSA_IMAGE" "$ROOT_DIR/my-medusa-store"

echo "Building $STOREFRONT_IMAGE"
docker build -t "$STOREFRONT_IMAGE" "$ROOT_DIR/my-medusa-storefront"

echo "Importing images into k3d cluster $CLUSTER_NAME"
k3d image import "$MEDUSA_IMAGE" -c "$CLUSTER_NAME"
k3d image import "$STOREFRONT_IMAGE" -c "$CLUSTER_NAME"

echo "Applying Kubernetes manifests"
kubectl apply -k "$ROOT_DIR/k8s"

echo "Current pods in namespace $NAMESPACE"
kubectl get pods -n "$NAMESPACE"

echo "Done. Watch rollout with:"
echo "kubectl get pods -n $NAMESPACE -w"
