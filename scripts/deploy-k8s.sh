#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
NAMESPACE="${NAMESPACE:-pisofire}"
MEDUSA_IMAGE="my-medusa-store-medusa:latest"
STOREFRONT_IMAGE="my-medusa-store-storefront:latest"
DEPENDENCY_IMAGES="postgres:15-alpine redis:7-alpine busybox:1.36 rancher/mirrored-library-busybox:1.36.1"
APP_DEPLOYMENTS="medusa medusa-worker storefront"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-240s}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command docker
require_command k3d
require_command kubectl

show_recent_events() {
  echo "Recent events in namespace $NAMESPACE:" >&2
  kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp 2>/dev/null | tail -20 >&2 || true
}

wait_for_app_rollouts() {
  for deployment in $APP_DEPLOYMENTS; do
    if ! kubectl rollout status -n "$NAMESPACE" --timeout="$ROLLOUT_TIMEOUT" "deployment/$deployment"; then
      echo "Rollout failed for deployment/$deployment." >&2
      return 1
    fi
  done
}

rollback_app_deployments() {
  rollback_failed=false

  echo "Rolling back application deployments to the previous ReplicaSets." >&2
  for deployment in $APP_DEPLOYMENTS; do
    if ! kubectl rollout undo -n "$NAMESPACE" "deployment/$deployment" >&2; then
      echo "Could not start rollback for deployment/$deployment." >&2
      rollback_failed=true
    fi
  done

  for deployment in $APP_DEPLOYMENTS; do
    if ! kubectl rollout status -n "$NAMESPACE" --timeout="$ROLLOUT_TIMEOUT" "deployment/$deployment" >&2; then
      echo "Rollback did not complete for deployment/$deployment." >&2
      rollback_failed=true
    fi
  done

  if [ "$rollback_failed" = "true" ]; then
    echo "Rollback was attempted but did not fully complete." >&2
    return 1
  fi
}

CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
CURRENT_CLUSTER="$(kubectl config view --minify -o jsonpath='{.contexts[0].context.cluster}' 2>/dev/null || true)"
CLUSTER_NAME="${1:-}"

if [ -z "$CLUSTER_NAME" ]; then
  case "$CURRENT_CLUSTER" in
    k3d-*) CLUSTER_NAME="${CURRENT_CLUSTER#k3d-}" ;;
    *)
      case "$CURRENT_CONTEXT" in
        k3d-*) CLUSTER_NAME="${CURRENT_CONTEXT#k3d-}" ;;
        *) CLUSTER_NAME="pisofire" ;;
      esac
      ;;
  esac
fi

EXPECTED_CLUSTER="k3d-$CLUSTER_NAME"

if [ -z "$CURRENT_CONTEXT" ]; then
  echo "No current kubectl context is set." >&2
  echo "Select your local test cluster before running this script." >&2
  exit 1
fi

if [ "$CURRENT_CLUSTER" != "$EXPECTED_CLUSTER" ]; then
  echo "Refusing to deploy." >&2
  echo "Current context: $CURRENT_CONTEXT" >&2
  echo "Current cluster: ${CURRENT_CLUSTER:-<none>}" >&2
  echo "Expected cluster: $EXPECTED_CLUSTER" >&2
  echo "If this is a k3d cluster, run:" >&2
  echo "  k3d cluster start $CLUSTER_NAME" >&2
  echo "  k3d kubeconfig merge $CLUSTER_NAME --kubeconfig-switch-context" >&2
  exit 1
fi

if ! kubectl cluster-info >/tmp/pisofire-kubectl-cluster-info.out 2>&1; then
  echo "Unable to reach the Kubernetes API for context: $CURRENT_CONTEXT" >&2
  cat /tmp/pisofire-kubectl-cluster-info.out >&2 || true

  if k3d cluster list "$CLUSTER_NAME" >/tmp/pisofire-k3d-cluster.out 2>&1; then
    echo "k3d cluster '$CLUSTER_NAME' exists but is not reachable." >&2
    echo "Try:" >&2
    echo "  k3d cluster start $CLUSTER_NAME" >&2
    echo "  k3d kubeconfig merge $CLUSTER_NAME --kubeconfig-switch-context" >&2
  else
    echo "No k3d cluster named '$CLUSTER_NAME' was found." >&2
    echo "Available k3d clusters:" >&2
    k3d cluster list >&2 || true
    echo "Then switch to the intended one with:" >&2
    echo "  k3d kubeconfig merge <cluster-name> --kubeconfig-switch-context" >&2
  fi

  exit 1
fi

echo "Building $MEDUSA_IMAGE"
docker build -t "$MEDUSA_IMAGE" "$ROOT_DIR/my-medusa-store"

echo "Building $STOREFRONT_IMAGE"
docker build -t "$STOREFRONT_IMAGE" "$ROOT_DIR/my-medusa-storefront"

echo "Importing images into k3d cluster $CLUSTER_NAME"
k3d image import "$MEDUSA_IMAGE" -c "$CLUSTER_NAME"
k3d image import "$STOREFRONT_IMAGE" -c "$CLUSTER_NAME"

NAMESPACE_EXISTS=false
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  NAMESPACE_EXISTS=true
  echo "Deleting previous bootstrap jobs so immutable job template changes can apply"
  kubectl delete job -n "$NAMESPACE" bootstrap-admin --ignore-not-found
  kubectl delete job -n "$NAMESPACE" bootstrap-store --ignore-not-found
fi

echo "Ensuring dependency images are available locally"
for image in $DEPENDENCY_IMAGES; do
  docker pull "$image"
done

echo "Importing dependency images into k3d cluster $CLUSTER_NAME"
k3d image import $DEPENDENCY_IMAGES -c "$CLUSTER_NAME"

echo "Applying Kubernetes manifests"
if ! kubectl apply -k "$ROOT_DIR/k8s"; then
  echo "kubectl apply failed. Attempting application rollback." >&2
  rollback_app_deployments || true
  show_recent_events
  exit 1
fi

if [ "$NAMESPACE_EXISTS" = "true" ]; then
  echo "Restarting application deployments to pick up freshly imported :latest images"
  if ! kubectl rollout restart -n "$NAMESPACE" deployment/medusa deployment/medusa-worker deployment/storefront; then
    echo "Could not restart application deployments. Attempting rollback." >&2
    rollback_app_deployments || true
    show_recent_events
    exit 1
  fi
fi

echo "Waiting for application rollouts"
if ! wait_for_app_rollouts; then
  echo "Application rollout failed after deploy. Starting automatic rollback." >&2
  rollback_app_deployments || true
  kubectl get pods -n "$NAMESPACE" >&2 || true
  show_recent_events
  exit 1
fi

echo "Current pods in namespace $NAMESPACE"
kubectl get pods -n "$NAMESPACE"

echo "Deploy completed successfully."
echo "Current application rollout history:"
for deployment in $APP_DEPLOYMENTS; do
  kubectl rollout history -n "$NAMESPACE" "deployment/$deployment"
done
