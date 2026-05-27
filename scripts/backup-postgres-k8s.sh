#!/bin/sh

set -eu

NAMESPACE="${NAMESPACE:-pisofire}"
BACKUP_TIMEOUT="${BACKUP_TIMEOUT:-300s}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-}"
EXPECTED_CONTEXT="${EXPECTED_CONTEXT:-}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

kubectl_cmd() {
  if [ -n "$KUBECONFIG_FILE" ]; then
    kubectl --kubeconfig "$KUBECONFIG_FILE" "$@"
  else
    kubectl "$@"
  fi
}

validate_context() {
  current_context="$(kubectl_cmd config current-context 2>/dev/null || true)"

  if [ -n "$EXPECTED_CONTEXT" ]; then
    if [ "$current_context" != "$EXPECTED_CONTEXT" ]; then
      echo "Refusing to run backup." >&2
      echo "Current context: $current_context" >&2
      echo "Expected context: $EXPECTED_CONTEXT" >&2
      exit 1
    fi
    return
  fi

  current_cluster="$(kubectl_cmd config view --minify -o jsonpath='{.contexts[0].context.cluster}' 2>/dev/null || true)"
  cluster_name="${1:-}"

  if [ -z "$cluster_name" ]; then
    case "$current_cluster" in
      k3d-*) cluster_name="${current_cluster#k3d-}" ;;
      *) cluster_name="pisofire" ;;
    esac
  fi

  expected_cluster="k3d-$cluster_name"

  if [ "$current_cluster" != "$expected_cluster" ]; then
    echo "Refusing to run backup." >&2
    echo "Current context: $current_context" >&2
    echo "Current cluster: ${current_cluster:-<none>}" >&2
    echo "Expected cluster: $expected_cluster" >&2
    echo "For tenant, set KUBECONFIG_FILE and EXPECTED_CONTEXT explicitly." >&2
    exit 1
  fi
}

require_command kubectl
validate_context "${1:-}"

kubectl_cmd get cronjob -n "$NAMESPACE" postgres-backup >/dev/null
kubectl_cmd get pvc -n "$NAMESPACE" postgres-backups >/dev/null

job_name="postgres-backup-manual-$(date -u +%Y%m%d%H%M%S)"

echo "Creating manual backup job: $job_name"
kubectl_cmd create job -n "$NAMESPACE" --from=cronjob/postgres-backup "$job_name" >/dev/null

if ! kubectl_cmd wait -n "$NAMESPACE" --for=condition=complete --timeout="$BACKUP_TIMEOUT" "job/$job_name" >/dev/null; then
  echo "Backup job did not complete: $job_name" >&2
  kubectl_cmd logs -n "$NAMESPACE" "job/$job_name" >&2 || true
  exit 1
fi

kubectl_cmd logs -n "$NAMESPACE" "job/$job_name"

printf '%s\n' "PostgreSQL backup completed" \
  "Namespace: $NAMESPACE" \
  "Job: $job_name" \
  "PVC: postgres-backups"
