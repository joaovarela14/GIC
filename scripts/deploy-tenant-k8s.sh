#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-$ROOT_DIR/tenant-pisofire-kubeconfig.yaml}"
EXPECTED_CONTEXT="${EXPECTED_CONTEXT:-tenant-pisofire-context}"
NAMESPACE="${NAMESPACE:-tenant-pisofire}"
IMAGE_PREFIX="${IMAGE_PREFIX:-registry.deti/tenant-pisofire}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
APP_DEPLOYMENTS="medusa medusa-worker storefront"
STATEFUL_WORKLOADS="postgres redis"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"
KUBECTL_REQUEST_TIMEOUT="${KUBECTL_REQUEST_TIMEOUT:-30s}"
KUBECTL_PROBE_TIMEOUT="${KUBECTL_PROBE_TIMEOUT:-30s}"
ALLOW_PATRONI_MIGRATION="${ALLOW_PATRONI_MIGRATION:-false}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command kubectl
require_command timeout

kubectl_tenant() {
  kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" --kubeconfig "$KUBECONFIG_FILE" "$@"
}

kubectl_tenant_probe() {
  timeout "$KUBECTL_PROBE_TIMEOUT" \
    kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" --kubeconfig "$KUBECONFIG_FILE" "$@"
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

wait_for_stateful_rollouts() {
  for statefulset in $STATEFUL_WORKLOADS; do
    if ! kubectl_tenant rollout status -n "$NAMESPACE" --timeout="$ROLLOUT_TIMEOUT" "statefulset/$statefulset"; then
      echo "Rollout failed for statefulset/$statefulset." >&2
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

uses_patroni_image() {
  case "$1" in
    *postgres-patroni*) return 0 ;;
    *) return 1 ;;
  esac
}

postgres_needs_patroni_migration() {
  sts_image_file="$WORK_DIR/postgres-sts-image"
  optional_kubectl_jsonpath \
    statefulset/postgres \
    '{.spec.template.spec.containers[?(@.name=="postgres")].image}' \
    > "$sts_image_file"
  probe_status=$?
  if [ "$probe_status" -ne 0 ]; then
    return "$probe_status"
  fi
  sts_image="$(cat "$sts_image_file")"

  postgres0_image_file="$WORK_DIR/postgres-0-image"
  optional_kubectl_jsonpath \
    pod/postgres-0 \
    '{.spec.containers[?(@.name=="postgres")].image}' \
    > "$postgres0_image_file"
  probe_status=$?
  if [ "$probe_status" -ne 0 ]; then
    return "$probe_status"
  fi
  postgres0_image="$(cat "$postgres0_image_file")"

  if [ -n "$postgres0_image" ] && ! uses_patroni_image "$postgres0_image"; then
    return 0
  fi

  if [ -n "$sts_image" ] && ! uses_patroni_image "$sts_image"; then
    return 0
  fi

  return 1
}

optional_kubectl_jsonpath() {
  resource="$1"
  jsonpath_expr="$2"
  err_file="$WORK_DIR/kubectl-probe.err"

  rm -f "$err_file"
  if probe_output="$(
    kubectl_tenant_probe get "$resource" -n "$NAMESPACE" -o "jsonpath=$jsonpath_expr" 2>"$err_file"
  )"; then
    printf '%s' "$probe_output"
    return 0
  fi

  if grep -q "NotFound" "$err_file" 2>/dev/null; then
    return 0
  fi

  echo "Could not read $resource in namespace $NAMESPACE." >&2
  if [ -s "$err_file" ]; then
    cat "$err_file" >&2
  fi
  return 2
}

set_first_replicas() {
  file="$1"
  replicas="$2"
  tmp="$file.tmp"

  awk -v replicas="$replicas" '
    !done && /^[[:space:]]*replicas:/ {
      sub(/replicas:.*/, "replicas: " replicas)
      done = 1
    }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

remove_bootstrap_jobs_from_kustomization() {
  file="$1/kustomization.yaml"
  tmp="$file.tmp"

  awk '
    /^[[:space:]]*-[[:space:]]*autoscaling.yaml[[:space:]]*$/ { next }
    /^[[:space:]]*-[[:space:]]*bootstrap-admin-job.yaml[[:space:]]*$/ { next }
    /^[[:space:]]*-[[:space:]]*bootstrap-job.yaml[[:space:]]*$/ { next }
    /^[[:space:]]*-[[:space:]]*minio-setup.yaml[[:space:]]*$/ { next }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

prepare_patroni_migration_overlay() {
  migration_overlay="$1"

  cp -R "$OVERLAY_DIR" "$migration_overlay"
  set_first_replicas "$migration_overlay/postgres.yaml" 1
  set_first_replicas "$migration_overlay/medusa.yaml" 0
  set_first_replicas "$migration_overlay/medusa-worker.yaml" 0
  set_first_replicas "$migration_overlay/storefront.yaml" 0
  remove_bootstrap_jobs_from_kustomization "$migration_overlay"
}

scale_app_deployments() {
  replicas="$1"

  for deployment in $APP_DEPLOYMENTS; do
    if kubectl_tenant get deployment "$deployment" -n "$NAMESPACE" >/dev/null 2>&1; then
      kubectl_tenant patch deployment "$deployment" -n "$NAMESPACE" --type merge \
        -p "{\"spec\":{\"replicas\":$replicas}}"
    fi
  done

  for deployment in $APP_DEPLOYMENTS; do
    if kubectl_tenant get deployment "$deployment" -n "$NAMESPACE" >/dev/null 2>&1; then
      if [ "$replicas" = "0" ]; then
        pods="$(
          kubectl_tenant get pods -n "$NAMESPACE" -l "app=$deployment" -o name || true
        )"
        if [ -n "$pods" ]; then
          # shellcheck disable=SC2086
          kubectl_tenant wait -n "$NAMESPACE" --for=delete $pods --timeout="$ROLLOUT_TIMEOUT"
        fi
      else
        kubectl_tenant rollout status -n "$NAMESPACE" --timeout="$ROLLOUT_TIMEOUT" "deployment/$deployment"
      fi
    fi
  done
}

delete_patroni_dcs() {
  kubectl_tenant delete endpoints,configmaps \
    -l app=postgres,cluster-name=pisofire-postgres \
    -n "$NAMESPACE" --ignore-not-found
}

migrate_existing_postgres_to_patroni() {
  migration_overlay="$1"

  echo "Migrating existing Postgres StatefulSet to Patroni."
  echo "This intentionally stops application deployments while postgres-0 is restarted under Patroni."
  kubectl_tenant delete hpa medusa medusa-worker storefront -n "$NAMESPACE" --ignore-not-found
  scale_app_deployments 0

  kubectl_tenant delete job bootstrap-admin -n "$NAMESPACE" --ignore-not-found
  kubectl_tenant delete job bootstrap-store -n "$NAMESPACE" --ignore-not-found
  kubectl_tenant delete job minio-setup -n "$NAMESPACE" --ignore-not-found

  if kubectl_tenant get statefulset/postgres -n "$NAMESPACE" >/dev/null 2>&1; then
    kubectl_tenant patch statefulset/postgres -n "$NAMESPACE" --type merge \
      -p '{"spec":{"updateStrategy":{"type":"RollingUpdate","rollingUpdate":{"partition":1}}}}'
    kubectl_tenant patch statefulset/postgres -n "$NAMESPACE" --type merge \
      -p '{"spec":{"replicas":1}}'

    if kubectl_tenant get pod/postgres-1 -n "$NAMESPACE" >/dev/null 2>&1; then
      kubectl_tenant wait -n "$NAMESPACE" --for=delete pod/postgres-1 --timeout="$ROLLOUT_TIMEOUT"
    fi
  fi

  delete_patroni_dcs

  kubectl_tenant apply -k "$migration_overlay"
  kubectl_tenant patch statefulset/postgres -n "$NAMESPACE" --type merge \
    -p '{"spec":{"updateStrategy":{"type":"RollingUpdate","rollingUpdate":{"partition":0}}}}'

  kubectl_tenant rollout status -n "$NAMESPACE" --timeout="$ROLLOUT_TIMEOUT" statefulset/postgres
  kubectl_tenant wait -n "$NAMESPACE" --for=condition=Ready pod/postgres-0 --timeout="$ROLLOUT_TIMEOUT"

  postgres0_image="$(
    kubectl_tenant get pod/postgres-0 -n "$NAMESPACE" \
      -o jsonpath='{.spec.containers[?(@.name=="postgres")].image}'
  )"
  if ! uses_patroni_image "$postgres0_image"; then
    echo "postgres-0 is still not running the Patroni image: $postgres0_image" >&2
    return 1
  fi

  kubectl_tenant patch statefulset/postgres -n "$NAMESPACE" --type merge \
    -p '{"spec":{"replicas":2}}'
  kubectl_tenant rollout status -n "$NAMESPACE" --timeout="$ROLLOUT_TIMEOUT" statefulset/postgres
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

for required_key in POSTGRES_PASSWORD POSTGRES_REPLICATION_PASSWORD DATABASE_URL JWT_SECRET COOKIE_SECRET REVALIDATE_SECRET MEDUSA_ADMIN_EMAIL MEDUSA_ADMIN_PASSWORD MINIO_ROOT_USER MINIO_ROOT_PASSWORD S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY; do
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
      "my-medusa-store-storefront=$IMAGE_PREFIX/storefront:$IMAGE_TAG" \
      "my-medusa-store-postgres-patroni=$IMAGE_PREFIX/postgres-patroni:$IMAGE_TAG"
  )
else
  awk \
    -v medusa_image="$IMAGE_PREFIX/medusa" \
    -v storefront_image="$IMAGE_PREFIX/storefront" \
    -v postgres_image="$IMAGE_PREFIX/postgres-patroni" \
    -v image_tag="$IMAGE_TAG" '
      /^[[:space:]]*- name: my-medusa-store-medusa$/ {
        target = "medusa"
        print
        next
      }
      /^[[:space:]]*- name: my-medusa-store-storefront$/ {
        target = "storefront"
        print
        next
      }
      /^[[:space:]]*- name: my-medusa-store-postgres-patroni$/ {
        target = "postgres"
        print
        next
      }
      target == "medusa" && /^[[:space:]]*newName:/ {
        sub(/newName:.*/, "newName: " medusa_image)
        print
        next
      }
      target == "storefront" && /^[[:space:]]*newName:/ {
        sub(/newName:.*/, "newName: " storefront_image)
        print
        next
      }
      target == "postgres" && /^[[:space:]]*newName:/ {
        sub(/newName:.*/, "newName: " postgres_image)
        print
        next
      }
      (target == "medusa" || target == "storefront" || target == "postgres") && /^[[:space:]]*newTag:/ {
        sub(/newTag:.*/, "newTag: " image_tag)
        print
        target = ""
        next
      }
      { print }
    ' "$OVERLAY_DIR/kustomization.yaml" > "$OVERLAY_DIR/kustomization.yaml.tmp"
  mv "$OVERLAY_DIR/kustomization.yaml.tmp" "$OVERLAY_DIR/kustomization.yaml"
fi

PATRONI_MIGRATION_REQUIRED=false
if postgres_needs_patroni_migration; then
  PATRONI_MIGRATION_REQUIRED=true
  if [ "$ALLOW_PATRONI_MIGRATION" != "true" ]; then
    echo "Refusing to roll an existing non-Patroni Postgres StatefulSet into Patroni implicitly." >&2
    echo "This migration restarts postgres-0 and temporarily scales application deployments to zero." >&2
    echo "Re-run with ALLOW_PATRONI_MIGRATION=true after taking/confirming a fresh database backup." >&2
    exit 1
  fi
else
  migration_status=$?
  if [ "$migration_status" -ne 1 ]; then
    echo "Could not determine whether Patroni migration is required. Aborting before applying changes." >&2
    exit "$migration_status"
  fi
fi

echo "Applying tenant overlay to namespace $NAMESPACE"
kubectl_tenant delete job bootstrap-admin -n "$NAMESPACE" --ignore-not-found
kubectl_tenant delete job bootstrap-store -n "$NAMESPACE" --ignore-not-found
kubectl_tenant delete job minio-setup -n "$NAMESPACE" --ignore-not-found
kubectl_tenant delete deployment postgres -n "$NAMESPACE" --ignore-not-found
kubectl_tenant delete deployment redis -n "$NAMESPACE" --ignore-not-found

if [ "$PATRONI_MIGRATION_REQUIRED" = "true" ]; then
  MIGRATION_OVERLAY_DIR="$WORK_DIR/k8s/tenant-patroni-migration"
  prepare_patroni_migration_overlay "$MIGRATION_OVERLAY_DIR"
  if ! migrate_existing_postgres_to_patroni "$MIGRATION_OVERLAY_DIR"; then
    echo "Patroni migration failed. Application deployments may still be scaled down." >&2
    kubectl_tenant get pods -n "$NAMESPACE" >&2 || true
    show_recent_events
    exit 1
  fi
fi

if ! kubectl_tenant apply -k "$OVERLAY_DIR"; then
  echo "kubectl apply failed. Attempting application rollback." >&2
  rollback_app_deployments || true
  show_recent_events
  exit 1
fi

echo "Waiting for stateful rollouts"
if ! wait_for_stateful_rollouts; then
  echo "Stateful rollout failed after tenant deploy." >&2
  kubectl_tenant get pods -n "$NAMESPACE" >&2 || true
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
