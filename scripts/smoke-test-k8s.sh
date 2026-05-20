#!/bin/sh

set -eu

NAMESPACE="${NAMESPACE:-pisofire}"
MEDUSA_PORT="${MEDUSA_PORT:-9000}"
STOREFRONT_PORT="${STOREFRONT_PORT:-8000}"
MEDUSA_BASE_URL="http://127.0.0.1:$MEDUSA_PORT"
STOREFRONT_BASE_URL="http://127.0.0.1:$STOREFRONT_PORT"
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

fail_if_nodes_under_pressure() {
  NODE_PRESSURE="$(
    kubectl get nodes \
      -o jsonpath='{range .items[*]}{.metadata.name}{" DiskPressure="}{range .status.conditions[?(@.type=="DiskPressure")]}{.status}{end}{" Taints="}{range .spec.taints[*]}{.key}{":"}{.effect}{" "}{end}{"\n"}{end}' \
      2>/dev/null || true
  )"

  if printf '%s\n' "$NODE_PRESSURE" | grep -q 'DiskPressure=True\|node.kubernetes.io/disk-pressure'; then
    echo "Kubernetes nodes are under disk pressure; pods will remain Pending." >&2
    printf '%s\n' "$NODE_PRESSURE" >&2
    echo "Free host/Docker disk space, then wait for the taint to clear or restart the k3d cluster." >&2
    echo "Useful commands:" >&2
    echo "  df -h /" >&2
    echo "  docker system df" >&2
    echo "  docker builder prune -f" >&2
    show_recent_events
    exit 1
  fi
}

ensure_port_forward_running() {
  pid="$1"
  name="$2"
  log_file="$3"

  if ! kill -0 "$pid" >/dev/null 2>&1; then
    echo "$name port-forward failed to start." >&2
    echo "This often means localhost port $MEDUSA_PORT or $STOREFRONT_PORT is already in use by Docker Compose." >&2
    echo "Stop the local compose stack or override ports, for example:" >&2
    echo "  MEDUSA_PORT=19000 STOREFRONT_PORT=18000 ./scripts/smoke-test-k8s.sh" >&2
    echo "Port-forward log:" >&2
    cat "$log_file" >&2 || true
    exit 1
  fi
}

require_command kubectl
require_command curl
require_command jq

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
  exit 1
fi

if [ "$CURRENT_CLUSTER" != "$EXPECTED_CLUSTER" ]; then
  echo "Refusing to run smoke tests." >&2
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

  if command -v k3d >/dev/null 2>&1; then
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
  fi

  exit 1
fi

cleanup() {
  kill "${MEDUSA_PF_PID:-}" >/dev/null 2>&1 || true
  kill "${STOREFRONT_PF_PID:-}" >/dev/null 2>&1 || true
}

trap cleanup EXIT INT TERM

fail_if_nodes_under_pressure

echo "Waiting for core deployments in namespace $NAMESPACE"
if ! kubectl wait -n "$NAMESPACE" --for=condition=available --timeout=180s deployment/postgres deployment/redis deployment/medusa deployment/medusa-worker deployment/storefront >/dev/null; then
  echo "Core deployments did not become available." >&2
  kubectl get pods -n "$NAMESPACE" >&2 || true
  show_recent_events
  exit 1
fi

echo "Waiting for deployment rollouts to finish"
for deployment in postgres redis medusa medusa-worker storefront; do
  if ! kubectl rollout status -n "$NAMESPACE" --timeout=180s "deployment/$deployment" >/dev/null; then
    echo "Rollout did not finish for deployment/$deployment." >&2
    kubectl get pods -n "$NAMESPACE" >&2 || true
    show_recent_events
    exit 1
  fi
done

echo "Waiting for bootstrap job completion"
if ! kubectl wait -n "$NAMESPACE" --for=condition=complete --timeout=180s job/bootstrap-store >/dev/null; then
  echo "Bootstrap job did not complete." >&2
  kubectl get pods -n "$NAMESPACE" >&2 || true
  kubectl logs -n "$NAMESPACE" job/bootstrap-store >&2 || true
  show_recent_events
  exit 1
fi

echo "Starting local port-forwards"
kubectl port-forward -n "$NAMESPACE" svc/medusa "$MEDUSA_PORT:9000" >/tmp/pisofire-medusa-port-forward.log 2>&1 &
MEDUSA_PF_PID=$!
kubectl port-forward -n "$NAMESPACE" svc/storefront "$STOREFRONT_PORT:8000" >/tmp/pisofire-storefront-port-forward.log 2>&1 &
STOREFRONT_PF_PID=$!

sleep 2

ensure_port_forward_running "$MEDUSA_PF_PID" "Medusa" /tmp/pisofire-medusa-port-forward.log
ensure_port_forward_running "$STOREFRONT_PF_PID" "Storefront" /tmp/pisofire-storefront-port-forward.log

echo "Checking backend and storefront health/readiness"
MEDUSA_STATUS="$(curl -sS -o /tmp/pisofire-medusa-health.out -w '%{http_code}' "$MEDUSA_BASE_URL/health")"
MEDUSA_READY_STATUS="$(curl -sS -o /tmp/pisofire-medusa-ready.out -w '%{http_code}' "$MEDUSA_BASE_URL/readyz")"
STORE_READY_STATUS="$(curl -sS -o /tmp/pisofire-store-ready.out -w '%{http_code}' "$MEDUSA_BASE_URL/store-readyz")"
STOREFRONT_HEALTH_STATUS="$(curl -sS -o /tmp/pisofire-storefront-health.out -w '%{http_code}' "$STOREFRONT_BASE_URL/api/health")"
STOREFRONT_READY_STATUS="$(curl -sS -o /tmp/pisofire-storefront-ready.out -w '%{http_code}' "$STOREFRONT_BASE_URL/api/ready")"

if [ "$MEDUSA_STATUS" != "200" ]; then
  echo "Unexpected Medusa health status: $MEDUSA_STATUS" >&2
  exit 1
fi

if [ "$MEDUSA_READY_STATUS" != "200" ]; then
  echo "Unexpected Medusa readiness status: $MEDUSA_READY_STATUS" >&2
  cat /tmp/pisofire-medusa-ready.out >&2 || true
  exit 1
fi

if [ "$STORE_READY_STATUS" != "200" ]; then
  echo "Unexpected store readiness status: $STORE_READY_STATUS" >&2
  cat /tmp/pisofire-store-ready.out >&2 || true
  exit 1
fi

if [ "$STOREFRONT_HEALTH_STATUS" != "200" ]; then
  echo "Unexpected storefront health status: $STOREFRONT_HEALTH_STATUS" >&2
  exit 1
fi

if [ "$STOREFRONT_READY_STATUS" != "200" ]; then
  echo "Unexpected storefront readiness status: $STOREFRONT_READY_STATUS" >&2
  cat /tmp/pisofire-storefront-ready.out >&2 || true
  exit 1
fi

echo "Running end-to-end store API journey"
PUBLISHABLE_KEY="$(curl -fsS "$MEDUSA_BASE_URL/publishable-key" | jq -r '.publishable_api_key')"
REGION_ID="$(curl -fsS -H "x-publishable-api-key: $PUBLISHABLE_KEY" "$MEDUSA_BASE_URL/store/regions" | jq -r '.regions[0].id')"
COUNTRY_CODE="$(curl -fsS -H "x-publishable-api-key: $PUBLISHABLE_KEY" "$MEDUSA_BASE_URL/store/regions/$REGION_ID" | jq -r '.region.countries[0].iso_2')"
PRODUCT_ID="$(curl -fsS -H "x-publishable-api-key: $PUBLISHABLE_KEY" "$MEDUSA_BASE_URL/store/products?limit=1&region_id=$REGION_ID" | jq -r '.products[0].id')"
VARIANT_ID="$(curl -fsS -H "x-publishable-api-key: $PUBLISHABLE_KEY" "$MEDUSA_BASE_URL/store/products/$PRODUCT_ID?region_id=$REGION_ID" | jq -r '.product.variants[0].id')"

STOREFRONT_PAGE_STATUS="$(curl -sS -o /tmp/pisofire-storefront-page.out -w '%{http_code}' "$STOREFRONT_BASE_URL/$COUNTRY_CODE")"

case "$STOREFRONT_PAGE_STATUS" in
  200|301|302|307|308) ;;
  *)
    echo "Unexpected storefront page status: $STOREFRONT_PAGE_STATUS" >&2
    exit 1
    ;;
esac

echo "Checking service DNS from inside the cluster"
SERVICE_SMOKE_NAME="pisofire-service-smoke-$(date +%s)"
kubectl run -n "$NAMESPACE" "$SERVICE_SMOKE_NAME" \
  --rm -i --restart=Never \
  --image="$SERVICE_CHECK_IMAGE" \
  -- sh -ec "
    wget -qO- http://medusa:9000/readyz >/dev/null
    wget -qO- http://medusa:9000/store-readyz >/dev/null
    wget -qO- http://storefront:8000/api/ready >/dev/null
    wget -qO- --header 'Cookie: _medusa_cache_id=service-smoke' http://storefront:8000/$COUNTRY_CODE >/dev/null
  "

CART_ID="$(
  curl -fsS -X POST "$MEDUSA_BASE_URL/store/carts" \
    -H 'content-type: application/json' \
    -H "x-publishable-api-key: $PUBLISHABLE_KEY" \
    --data "{\"region_id\":\"$REGION_ID\"}" | jq -r '.cart.id'
)"

curl -fsS -X POST "$MEDUSA_BASE_URL/store/carts/$CART_ID/line-items" \
  -H 'content-type: application/json' \
  -H "x-publishable-api-key: $PUBLISHABLE_KEY" \
  --data "{\"variant_id\":\"$VARIANT_ID\",\"quantity\":1}" >/dev/null

curl -fsS -X POST "$MEDUSA_BASE_URL/store/carts/$CART_ID" \
  -H 'content-type: application/json' \
  -H "x-publishable-api-key: $PUBLISHABLE_KEY" \
  --data "{\"email\":\"sre-m1@example.com\",\"shipping_address\":{\"first_name\":\"SRE\",\"last_name\":\"Tester\",\"address_1\":\"Rua da Fiabilidade 1\",\"city\":\"Lisboa\",\"postal_code\":\"1000-001\",\"country_code\":\"$COUNTRY_CODE\",\"phone\":\"+351910000000\"},\"billing_address\":{\"first_name\":\"SRE\",\"last_name\":\"Tester\",\"address_1\":\"Rua da Fiabilidade 1\",\"city\":\"Lisboa\",\"postal_code\":\"1000-001\",\"country_code\":\"$COUNTRY_CODE\",\"phone\":\"+351910000000\"}}" >/dev/null

SHIPPING_OPTION_ID="$(curl -fsS -H "x-publishable-api-key: $PUBLISHABLE_KEY" "$MEDUSA_BASE_URL/store/shipping-options?cart_id=$CART_ID" | jq -r '.shipping_options[0].id')"

curl -fsS -X POST "$MEDUSA_BASE_URL/store/carts/$CART_ID/shipping-methods" \
  -H 'content-type: application/json' \
  -H "x-publishable-api-key: $PUBLISHABLE_KEY" \
  --data "{\"option_id\":\"$SHIPPING_OPTION_ID\"}" >/dev/null

PAYMENT_PROVIDER_ID="$(curl -fsS -H "x-publishable-api-key: $PUBLISHABLE_KEY" "$MEDUSA_BASE_URL/store/payment-providers?region_id=$REGION_ID" | jq -r '.payment_providers[0].id')"

PAYMENT_COLLECTION_ID="$(
  curl -fsS -X POST "$MEDUSA_BASE_URL/store/payment-collections" \
    -H 'content-type: application/json' \
    -H "x-publishable-api-key: $PUBLISHABLE_KEY" \
    --data "{\"cart_id\":\"$CART_ID\"}" | jq -r '.payment_collection.id'
)"

curl -fsS -X POST "$MEDUSA_BASE_URL/store/payment-collections/$PAYMENT_COLLECTION_ID/payment-sessions" \
  -H 'content-type: application/json' \
  -H "x-publishable-api-key: $PUBLISHABLE_KEY" \
  --data "{\"provider_id\":\"$PAYMENT_PROVIDER_ID\"}" >/dev/null

ORDER_ID="$(
  curl -fsS -X POST "$MEDUSA_BASE_URL/store/carts/$CART_ID/complete" \
    -H "x-publishable-api-key: $PUBLISHABLE_KEY" | jq -r 'if .type == "order" then .order.id else empty end'
)"

if [ -z "$ORDER_ID" ]; then
  echo "Checkout flow did not produce an order." >&2
  exit 1
fi

printf '%s\n' "Smoke test passed" \
  "Context: $CURRENT_CONTEXT" \
  "Namespace: $NAMESPACE" \
  "Backend health: $MEDUSA_STATUS" \
  "Backend readiness: $MEDUSA_READY_STATUS" \
  "Store readiness: $STORE_READY_STATUS" \
  "Storefront health: $STOREFRONT_HEALTH_STATUS" \
  "Storefront readiness: $STOREFRONT_READY_STATUS" \
  "Storefront page: $STOREFRONT_PAGE_STATUS" \
  "Service DNS checks: passed" \
  "Region: $REGION_ID" \
  "Product: $PRODUCT_ID" \
  "Variant: $VARIANT_ID" \
  "Cart: $CART_ID" \
  "Shipping option: $SHIPPING_OPTION_ID" \
  "Payment provider: $PAYMENT_PROVIDER_ID" \
  "Payment collection: $PAYMENT_COLLECTION_ID" \
  "Order: $ORDER_ID"
