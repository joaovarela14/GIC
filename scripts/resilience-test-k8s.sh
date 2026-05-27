#!/bin/sh

set -eu

NAMESPACE="${NAMESPACE:-pisofire}"
SERVICE_CHECK_IMAGE="${SERVICE_CHECK_IMAGE:-busybox:1.36}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

show_recent_events() {
  echo "Recent events in namespace $NAMESPACE:" >&2
  kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp 2>/dev/null | tail -20 >&2 || true
}

require_command kubectl

CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
CURRENT_CLUSTER="$(kubectl config view --minify -o jsonpath='{.contexts[0].context.cluster}' 2>/dev/null || true)"
CLUSTER_NAME="${1:-}"

if [ -z "$CLUSTER_NAME" ]; then
  case "$CURRENT_CLUSTER" in
    k3d-*) CLUSTER_NAME="${CURRENT_CLUSTER#k3d-}" ;;
    *) CLUSTER_NAME="pisofire" ;;
  esac
fi

EXPECTED_CLUSTER="k3d-$CLUSTER_NAME"

if [ "$CURRENT_CLUSTER" != "$EXPECTED_CLUSTER" ]; then
  echo "Refusing to run resilience test." >&2
  echo "Current context: $CURRENT_CONTEXT" >&2
  echo "Current cluster: ${CURRENT_CLUSTER:-<none>}" >&2
  echo "Expected cluster: $EXPECTED_CLUSTER" >&2
  exit 1
fi

echo "Waiting for application deployments in namespace $NAMESPACE"
kubectl wait -n "$NAMESPACE" --for=condition=available --timeout=180s deployment/medusa deployment/storefront >/dev/null

for deployment in medusa storefront; do
  READY_REPLICAS="$(kubectl get deployment -n "$NAMESPACE" "$deployment" -o jsonpath='{.status.readyReplicas}')"
  if [ "${READY_REPLICAS:-0}" -lt 2 ]; then
    echo "deployment/$deployment needs at least 2 ready replicas for this test; found ${READY_REPLICAS:-0}." >&2
    exit 1
  fi
done

kubectl get hpa -n "$NAMESPACE" medusa storefront medusa-worker >/dev/null
kubectl get pdb -n "$NAMESPACE" medusa storefront medusa-worker >/dev/null

check_services_from_cluster() {
  CHECK_NAME="pisofire-resilience-smoke-$(date +%s)"

  kubectl run -n "$NAMESPACE" "$CHECK_NAME" \
    --rm -i --restart=Never \
    --image="$SERVICE_CHECK_IMAGE" \
    -- sh -ec '
      i=1
      while [ "$i" -le 20 ]; do
        wget -qO- http://medusa:9000/readyz >/dev/null
        wget -qO- http://storefront:8000/api/ready >/dev/null
        i=$((i + 1))
        sleep 1
      done
    '
}

delete_one_pod_and_verify() {
  app="$1"
  pod="$(kubectl get pods -n "$NAMESPACE" -l "app=$app" -o jsonpath='{.items[0].metadata.name}')"

  if [ -z "$pod" ]; then
    echo "No pod found for app=$app." >&2
    exit 1
  fi

  echo "Deleting one $app pod: $pod"
  kubectl delete pod -n "$NAMESPACE" "$pod" --wait=false >/dev/null

  if ! check_services_from_cluster; then
    echo "Service checks failed after deleting pod $pod." >&2
    kubectl get pods -n "$NAMESPACE" >&2 || true
    show_recent_events
    exit 1
  fi

  echo "Waiting for deployment/$app to recover"
  if ! kubectl rollout status -n "$NAMESPACE" --timeout=180s "deployment/$app" >/dev/null; then
    echo "deployment/$app did not recover after deleting $pod." >&2
    kubectl get pods -n "$NAMESPACE" >&2 || true
    show_recent_events
    exit 1
  fi
}

echo "Checking services before failure injection"
check_services_from_cluster

delete_one_pod_and_verify medusa
delete_one_pod_and_verify storefront

printf '%s\n' "Resilience test passed" \
  "Context: $CURRENT_CONTEXT" \
  "Namespace: $NAMESPACE" \
  "Medusa replicas survived single pod deletion" \
  "Storefront replicas survived single pod deletion" \
  "HPA resources: present" \
  "PodDisruptionBudgets: present"
