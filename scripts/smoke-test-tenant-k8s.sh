#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-$ROOT_DIR/tenant-pisofire-kubeconfig.yaml}"
EXPECTED_CONTEXT="${EXPECTED_CONTEXT:-tenant-pisofire-context}"
NAMESPACE="${NAMESPACE:-tenant-pisofire}"
MEDUSA_BASE_URL="${MEDUSA_BASE_URL:-http://medusa-pisofire.deti}"
STOREFRONT_BASE_URL="${STOREFRONT_BASE_URL:-http://pisofire.deti}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command kubectl
require_command curl
require_command jq

if [ ! -f "$KUBECONFIG_FILE" ]; then
  echo "Missing kubeconfig: $KUBECONFIG_FILE" >&2
  exit 1
fi

CURRENT_CONTEXT="$(kubectl --kubeconfig "$KUBECONFIG_FILE" config current-context 2>/dev/null || true)"

if [ "$CURRENT_CONTEXT" != "$EXPECTED_CONTEXT" ]; then
  echo "Refusing to run smoke tests." >&2
  echo "Current context: $CURRENT_CONTEXT" >&2
  echo "Expected context: $EXPECTED_CONTEXT" >&2
  exit 1
fi

echo "Waiting for core deployments in namespace $NAMESPACE"
kubectl --kubeconfig "$KUBECONFIG_FILE" wait -n "$NAMESPACE" --for=condition=available --timeout=240s deployment/postgres deployment/redis deployment/medusa deployment/medusa-worker deployment/storefront >/dev/null

echo "Waiting for bootstrap job completion"
kubectl --kubeconfig "$KUBECONFIG_FILE" wait -n "$NAMESPACE" --for=condition=complete --timeout=240s job/bootstrap-store >/dev/null

echo "Checking backend and storefront health through Ingress"
MEDUSA_STATUS="$(curl -fsS -o /tmp/pisofire-tenant-medusa-health.out -w '%{http_code}' "$MEDUSA_BASE_URL/health")"
STOREFRONT_STATUS="$(curl -fsS -o /tmp/pisofire-tenant-storefront-head.out -D - "$STOREFRONT_BASE_URL" | awk 'NR==1 {print $2}')"

if [ "$MEDUSA_STATUS" != "200" ]; then
  echo "Unexpected Medusa health status: $MEDUSA_STATUS" >&2
  exit 1
fi

case "$STOREFRONT_STATUS" in
  200|301|302|307|308) ;;
  *)
    echo "Unexpected storefront status: $STOREFRONT_STATUS" >&2
    exit 1
    ;;
esac

echo "Running end-to-end store API journey"
PUBLISHABLE_KEY="$(curl -fsS "$MEDUSA_BASE_URL/publishable-key" | jq -r '.publishable_api_key')"
REGION_ID="$(curl -fsS -H "x-publishable-api-key: $PUBLISHABLE_KEY" "$MEDUSA_BASE_URL/store/regions" | jq -r '.regions[0].id')"
COUNTRY_CODE="$(curl -fsS -H "x-publishable-api-key: $PUBLISHABLE_KEY" "$MEDUSA_BASE_URL/store/regions/$REGION_ID" | jq -r '.region.countries[0].iso_2')"
PRODUCT_ID="$(curl -fsS -H "x-publishable-api-key: $PUBLISHABLE_KEY" "$MEDUSA_BASE_URL/store/products?limit=1&region_id=$REGION_ID" | jq -r '.products[0].id')"
VARIANT_ID="$(curl -fsS -H "x-publishable-api-key: $PUBLISHABLE_KEY" "$MEDUSA_BASE_URL/store/products/$PRODUCT_ID?region_id=$REGION_ID" | jq -r '.product.variants[0].id')"

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
  --data "{\"email\":\"sre-tenant@example.com\",\"shipping_address\":{\"first_name\":\"SRE\",\"last_name\":\"Tenant\",\"address_1\":\"Rua da Fiabilidade 1\",\"city\":\"Lisboa\",\"postal_code\":\"1000-001\",\"country_code\":\"$COUNTRY_CODE\",\"phone\":\"+351910000000\"},\"billing_address\":{\"first_name\":\"SRE\",\"last_name\":\"Tenant\",\"address_1\":\"Rua da Fiabilidade 1\",\"city\":\"Lisboa\",\"postal_code\":\"1000-001\",\"country_code\":\"$COUNTRY_CODE\",\"phone\":\"+351910000000\"}}" >/dev/null

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

printf '%s\n' "Tenant smoke test passed" \
  "Context: $CURRENT_CONTEXT" \
  "Namespace: $NAMESPACE" \
  "Backend health: $MEDUSA_STATUS" \
  "Storefront status: $STOREFRONT_STATUS" \
  "Order: $ORDER_ID"
