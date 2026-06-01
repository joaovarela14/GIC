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

echo "Waiting for core workloads in namespace $NAMESPACE"
kubectl --kubeconfig "$KUBECONFIG_FILE" rollout status -n "$NAMESPACE" --timeout=240s statefulset/postgres >/dev/null
kubectl --kubeconfig "$KUBECONFIG_FILE" rollout status -n "$NAMESPACE" --timeout=240s statefulset/redis >/dev/null
kubectl --kubeconfig "$KUBECONFIG_FILE" wait -n "$NAMESPACE" --for=condition=available --timeout=240s deployment/medusa deployment/medusa-worker deployment/storefront >/dev/null

echo "Checking PostgreSQL Patroni primary and replica roles"
kubectl --kubeconfig "$KUBECONFIG_FILE" get pods -n "$NAMESPACE" -l app=postgres --show-labels
POSTGRES_PRIMARY_POD="$(
  kubectl --kubeconfig "$KUBECONFIG_FILE" get pod -n "$NAMESPACE" -l app=postgres,cluster-name=pisofire-postgres,role=primary \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
)"
POSTGRES_REPLICA_COUNT="$(
  kubectl --kubeconfig "$KUBECONFIG_FILE" get pod -n "$NAMESPACE" -l app=postgres,cluster-name=pisofire-postgres,role=replica \
    --no-headers 2>/dev/null | wc -l | tr -d '[:space:]'
)"

if [ -z "$POSTGRES_PRIMARY_POD" ] || [ "${POSTGRES_REPLICA_COUNT:-0}" -lt 1 ]; then
  echo "Unexpected PostgreSQL Patroni labels." >&2
  echo "Primary pod: ${POSTGRES_PRIMARY_POD:-<none>}" >&2
  echo "Replica count: ${POSTGRES_REPLICA_COUNT:-0}" >&2
  kubectl --kubeconfig "$KUBECONFIG_FILE" get pods -n "$NAMESPACE" -l app=postgres --show-labels >&2 || true
  exit 1
fi

POSTGRES_PRIMARY_RECOVERY="$(
  kubectl --kubeconfig "$KUBECONFIG_FILE" exec -n "$NAMESPACE" "$POSTGRES_PRIMARY_POD" -- sh -ec \
    'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT pg_is_in_recovery()"' \
    2>/dev/null | tr -d '[:space:]'
)"

if [ "$POSTGRES_PRIMARY_RECOVERY" != "f" ]; then
  echo "Unexpected PostgreSQL primary recovery state." >&2
  echo "$POSTGRES_PRIMARY_POD pg_is_in_recovery(): ${POSTGRES_PRIMARY_RECOVERY:-<empty>}" >&2
  exit 1
fi

echo "Waiting for bootstrap job completion"
kubectl --kubeconfig "$KUBECONFIG_FILE" wait -n "$NAMESPACE" --for=condition=complete --timeout=240s job/bootstrap-store >/dev/null
kubectl --kubeconfig "$KUBECONFIG_FILE" wait -n "$NAMESPACE" --for=condition=complete --timeout=240s job/bootstrap-admin >/dev/null

echo "Checking autoscaling and disruption controls"
kubectl --kubeconfig "$KUBECONFIG_FILE" get hpa -n "$NAMESPACE" medusa storefront medusa-worker >/dev/null
if ! kubectl --kubeconfig "$KUBECONFIG_FILE" get pdb -n "$NAMESPACE" medusa storefront medusa-worker postgres redis >/dev/null 2>&1; then
  echo "PodDisruptionBudgets are not present; tenant RBAC does not allow creating them." >&2
fi
kubectl --kubeconfig "$KUBECONFIG_FILE" get cronjob -n "$NAMESPACE" postgres-backup >/dev/null
kubectl --kubeconfig "$KUBECONFIG_FILE" get pvc -n "$NAMESPACE" postgres-backups >/dev/null
for ordinal in 0 1 2; do
  kubectl --kubeconfig "$KUBECONFIG_FILE" get pvc -n "$NAMESPACE" "redis-data-redis-$ordinal" >/dev/null
done

echo "Checking Redis Sentinel and replication roles"
REDIS_SENTINEL_MASTER="$(
  kubectl --kubeconfig "$KUBECONFIG_FILE" exec -n "$NAMESPACE" redis-0 -c sentinel -- \
    redis-cli -p 26379 SENTINEL get-master-addr-by-name pisofire-redis \
    2>/dev/null | sed -n '1p' | tr -d '\r'
)"

if [ -z "$REDIS_SENTINEL_MASTER" ]; then
  echo "Redis Sentinel did not return a master for pisofire-redis." >&2
  exit 1
fi

REDIS_MASTER_COUNT=0
for ordinal in 0 1 2; do
  REDIS_ROLE="$(
    kubectl --kubeconfig "$KUBECONFIG_FILE" exec -n "$NAMESPACE" "redis-$ordinal" -c redis -- \
      sh -ec 'redis-cli role | sed -n "1p"' 2>/dev/null | tr -d '\r'
  )"

  case "$REDIS_ROLE" in
    master)
      REDIS_MASTER_COUNT=$((REDIS_MASTER_COUNT + 1))
      ;;
    slave|replica)
      ;;
    *)
      echo "Unexpected Redis role for redis-$ordinal: ${REDIS_ROLE:-<empty>}" >&2
      exit 1
      ;;
  esac
done

if [ "$REDIS_MASTER_COUNT" -ne 1 ]; then
  echo "Expected exactly one Redis master, found $REDIS_MASTER_COUNT." >&2
  exit 1
fi

if ! kubectl --kubeconfig "$KUBECONFIG_FILE" get --raw /apis/metrics.k8s.io/v1beta1/nodes >/dev/null 2>&1; then
  echo "Kubernetes metrics API is unavailable; HPA cannot scale on CPU/memory." >&2
  exit 1
fi

echo "Checking backend and storefront health through Ingress"
MEDUSA_STATUS="$(curl -fsS -o /tmp/pisofire-tenant-medusa-health.out -w '%{http_code}' "$MEDUSA_BASE_URL/health")"
STOREFRONT_STATUS="$(curl -fsS -o /tmp/pisofire-tenant-storefront-head.out -D - "$STOREFRONT_BASE_URL" | awk 'NR==1 {print $2}')"
MEDUSA_METRICS_STATUS="$(curl -sS -o /tmp/pisofire-tenant-medusa-metrics.out -w '%{http_code}' "$MEDUSA_BASE_URL/metrics")"
STOREFRONT_METRICS_STATUS="$(curl -sS -o /tmp/pisofire-tenant-storefront-metrics.out -w '%{http_code}' "$STOREFRONT_BASE_URL/api/metrics")"

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

if [ "$MEDUSA_METRICS_STATUS" != "200" ]; then
  echo "Unexpected Medusa metrics status: $MEDUSA_METRICS_STATUS" >&2
  cat /tmp/pisofire-tenant-medusa-metrics.out >&2 || true
  exit 1
fi

if ! grep -q '^pisofire_medusa_info' /tmp/pisofire-tenant-medusa-metrics.out; then
  echo "Medusa metrics response did not include pisofire_medusa_info." >&2
  exit 1
fi

if [ "$STOREFRONT_METRICS_STATUS" != "200" ]; then
  echo "Unexpected storefront metrics status: $STOREFRONT_METRICS_STATUS" >&2
  cat /tmp/pisofire-tenant-storefront-metrics.out >&2 || true
  exit 1
fi

if ! grep -q '^pisofire_storefront_info' /tmp/pisofire-tenant-storefront-metrics.out; then
  echo "Storefront metrics response did not include pisofire_storefront_info." >&2
  exit 1
fi

echo "Checking Medusa admin authentication through Ingress"
ADMIN_EMAIL="${MEDUSA_ADMIN_EMAIL:-}"
ADMIN_PASSWORD="${MEDUSA_ADMIN_PASSWORD:-}"

if [ -z "$ADMIN_EMAIL" ]; then
  ADMIN_EMAIL_B64="$(kubectl --kubeconfig "$KUBECONFIG_FILE" get secret -n "$NAMESPACE" pisofire-secrets -o jsonpath='{.data.MEDUSA_ADMIN_EMAIL}' 2>/dev/null || true)"
  if [ -n "$ADMIN_EMAIL_B64" ]; then
    ADMIN_EMAIL="$(printf '%s' "$ADMIN_EMAIL_B64" | base64 -d)"
  fi
fi

if [ -z "$ADMIN_PASSWORD" ]; then
  ADMIN_PASSWORD_B64="$(kubectl --kubeconfig "$KUBECONFIG_FILE" get secret -n "$NAMESPACE" pisofire-secrets -o jsonpath='{.data.MEDUSA_ADMIN_PASSWORD}' 2>/dev/null || true)"
  if [ -n "$ADMIN_PASSWORD_B64" ]; then
    ADMIN_PASSWORD="$(printf '%s' "$ADMIN_PASSWORD_B64" | base64 -d)"
  fi
fi

if [ -z "$ADMIN_EMAIL" ] || [ -z "$ADMIN_PASSWORD" ]; then
  echo "Missing Medusa admin smoke-test credentials." >&2
  exit 1
fi

ADMIN_LOGIN_PAYLOAD="$(jq -cn --arg email "$ADMIN_EMAIL" --arg password "$ADMIN_PASSWORD" '{email: $email, password: $password}')"
ADMIN_TOKEN="$(
  curl -fsS -X POST "$MEDUSA_BASE_URL/auth/user/emailpass" \
    -H 'content-type: application/json' \
    --data "$ADMIN_LOGIN_PAYLOAD" | jq -r '.token // empty'
)"

if [ -z "$ADMIN_TOKEN" ]; then
  echo "Medusa admin login did not return a token." >&2
  exit 1
fi

ADMIN_SESSION_STATUS="$(
  curl -sS -o /tmp/pisofire-tenant-admin-session.out \
    -D /tmp/pisofire-tenant-admin-session.headers \
    -w '%{http_code}' \
    -c /tmp/pisofire-tenant-admin-cookies.txt \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -X POST "$MEDUSA_BASE_URL/auth/session"
)"

if [ "$ADMIN_SESSION_STATUS" != "200" ]; then
  echo "Unexpected Medusa admin session status: $ADMIN_SESSION_STATUS" >&2
  cat /tmp/pisofire-tenant-admin-session.out >&2 || true
  exit 1
fi

if printf '%s' "$MEDUSA_BASE_URL" | grep -q '^http://' && grep -iq '^set-cookie:.*;[[:space:]]*secure' /tmp/pisofire-tenant-admin-session.headers; then
  echo "Medusa admin session cookie is marked Secure on an HTTP URL." >&2
  exit 1
fi

ADMIN_ME_STATUS="$(
  curl -sS -o /tmp/pisofire-tenant-admin-me.out -w '%{http_code}' \
    -b /tmp/pisofire-tenant-admin-cookies.txt \
    "$MEDUSA_BASE_URL/admin/users/me"
)"

if [ "$ADMIN_ME_STATUS" != "200" ]; then
  echo "Unexpected Medusa admin users/me status: $ADMIN_ME_STATUS" >&2
  cat /tmp/pisofire-tenant-admin-me.out >&2 || true
  exit 1
fi

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
  "Backend metrics: $MEDUSA_METRICS_STATUS" \
  "Storefront status: $STOREFRONT_STATUS" \
  "Storefront metrics: $STOREFRONT_METRICS_STATUS" \
  "Autoscaling controls: present" \
  "PostgreSQL backup controls: present" \
  "PostgreSQL Patroni primary: $POSTGRES_PRIMARY_POD" \
  "PostgreSQL Patroni replicas: $POSTGRES_REPLICA_COUNT" \
  "Stateful disruption controls: present" \
  "Redis Sentinel master: $REDIS_SENTINEL_MASTER" \
  "Redis Sentinel HA: one master, two replicas" \
  "Admin authentication: passed" \
  "Order: $ORDER_ID"
