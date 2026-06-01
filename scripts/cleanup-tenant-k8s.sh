#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-$ROOT_DIR/tenant-pisofire-kubeconfig.yaml}"
EXPECTED_CONTEXT="${EXPECTED_CONTEXT:-tenant-pisofire-context}"
NAMESPACE="${NAMESPACE:-tenant-pisofire}"
FORCE_PODS="${FORCE_PODS:-false}"

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

if [ ! -f "$KUBECONFIG_FILE" ]; then
  echo "Missing kubeconfig: $KUBECONFIG_FILE" >&2
  exit 1
fi

CURRENT_CONTEXT="$(kubectl_tenant config current-context 2>/dev/null || true)"

if [ "$CURRENT_CONTEXT" != "$EXPECTED_CONTEXT" ]; then
  echo "Refusing to clean up." >&2
  echo "Current context: $CURRENT_CONTEXT" >&2
  echo "Expected context: $EXPECTED_CONTEXT" >&2
  exit 1
fi

echo "Deleting tenant application workloads in namespace $NAMESPACE"
kubectl_tenant delete \
  deployment/medusa \
  deployment/medusa-worker \
  deployment/storefront \
  deployment/minio \
  statefulset/postgres \
  statefulset/redis \
  job/bootstrap-admin \
  job/bootstrap-store \
  job/minio-setup \
  cronjob/postgres-backup \
  service/medusa \
  service/storefront \
  service/minio \
  service/minio-console \
  service/postgres \
  service/postgres-headless \
  service/postgres-replica \
  service/redis \
  service/redis-headless \
  service/redis-sentinel \
  configmap/pisofire-config \
  configmap/redis-ha-scripts \
  configmap/postgres-patroni-config \
  secret/pisofire-secrets \
  -n "$NAMESPACE" --ignore-not-found

echo "Deleting tenant PVCs in namespace $NAMESPACE"
kubectl_tenant delete pvc \
  minio-data \
  postgres-backups \
  postgres-data-postgres-0 \
  postgres-data-postgres-1 \
  redis-data \
  redis-data-redis-0 \
  redis-data-redis-1 \
  redis-data-redis-2 \
  -n "$NAMESPACE" --ignore-not-found

if [ "$FORCE_PODS" = "true" ]; then
  echo "Force-deleting remaining non-exporter pods in namespace $NAMESPACE"
  pods="$(
    kubectl_tenant get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
      | rg -v '^(blackbox-exporter|postgres-exporter|redis-exporter)(-|$)' || true
  )"

  if [ -n "$pods" ]; then
    # shellcheck disable=SC2086
    kubectl_tenant delete pod -n "$NAMESPACE" --grace-period=0 --force $pods
  fi
fi

echo "Remaining resources in namespace $NAMESPACE"
kubectl_tenant get pods,pvc -n "$NAMESPACE"
