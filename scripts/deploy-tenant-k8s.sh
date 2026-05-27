#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-$ROOT_DIR/tenant-pisofire-kubeconfig.yaml}"
EXPECTED_CONTEXT="${EXPECTED_CONTEXT:-tenant-pisofire-context}"
NAMESPACE="${NAMESPACE:-tenant-pisofire}"
IMAGE_PREFIX="${IMAGE_PREFIX:-registry.deti/tenant-pisofire}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
APP_DEPLOYMENTS="medusa medusa-worker storefront"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command kubectl

kubectl_tenant() {
  kubectl --kubeconfig "$KUBECONFIG_FILE" "$@"
}

show_recent_events() {
  echo "Recent events in namespace $NAMESPACE:" >&2
  kubectl_tenant get events -n "$NAMESPACE" --sort-by=.lastTimestamp 2>/dev/null | tail -20 >&2 || true
}

wait_for_app_rollouts() {
  for deployment in $APP_DEPLOYMENTS; do
    if ! kubectl_tenant rollout status -n "$NAMESPACE" --timeout="$ROLLOUT_TIMEOUT" "deployment/$deployment"; then
      echo "Rollout failed for deployment/$deployment." >&2
      return 1
    fi
  done
}

rollback_app_deployments() {
  rollback_failed=false

  echo "Rolling back application deployments to the previous ReplicaSets." >&2
  for deployment in $APP_DEPLOYMENTS; do
    if ! kubectl_tenant rollout undo -n "$NAMESPACE" "deployment/$deployment" >&2; then
      echo "Could not start rollback for deployment/$deployment." >&2
      rollback_failed=true
    fi
  done

  for deployment in $APP_DEPLOYMENTS; do
    if ! kubectl_tenant rollout status -n "$NAMESPACE" --timeout="$ROLLOUT_TIMEOUT" "deployment/$deployment" >&2; then
      echo "Rollback did not complete for deployment/$deployment." >&2
      rollback_failed=true
    fi
  done

  if [ "$rollback_failed" = "true" ]; then
    echo "Rollback was attempted but did not fully complete." >&2
    return 1
  fi
}

if [ ! -f "$KUBECONFIG_FILE" ]; then
  echo "Missing kubeconfig: $KUBECONFIG_FILE" >&2
  exit 1
fi

CURRENT_CONTEXT="$(kubectl_tenant config current-context 2>/dev/null || true)"

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
kubectl_tenant delete job bootstrap-admin -n "$NAMESPACE" --ignore-not-found
kubectl_tenant delete job bootstrap-store -n "$NAMESPACE" --ignore-not-found
if ! kubectl_tenant apply -k "$OVERLAY_DIR"; then
  echo "kubectl apply failed. Attempting application rollback." >&2
  rollback_app_deployments || true
  show_recent_events
  exit 1
fi

if ! kubectl_tenant rollout restart deployment/medusa deployment/medusa-worker deployment/storefront -n "$NAMESPACE"; then
  echo "Could not restart application deployments. Attempting rollback." >&2
  rollback_app_deployments || true
  show_recent_events
  exit 1
fi

echo "Waiting for application rollouts"
if ! wait_for_app_rollouts; then
  echo "Application rollout failed after tenant deploy. Starting automatic rollback." >&2
  rollback_app_deployments || true
  kubectl_tenant get pods -n "$NAMESPACE" >&2 || true
  show_recent_events
  exit 1
fi

echo "Tenant deploy completed successfully."
echo "Current application rollout history:"
for deployment in $APP_DEPLOYMENTS; do
  kubectl_tenant rollout history -n "$NAMESPACE" "deployment/$deployment"
done
