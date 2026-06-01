#!/bin/sh

set -eu

NAMESPACE="${NAMESPACE:-pisofire}"
BACKUP_FILE="${1:-${BACKUP_FILE:-latest.dump}}"
RESTORE_TIMEOUT="${RESTORE_TIMEOUT:-600s}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-}"
EXPECTED_CONTEXT="${EXPECTED_CONTEXT:-}"
CONFIRM_RESTORE="${CONFIRM_RESTORE:-}"

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
      echo "Refusing to run restore." >&2
      echo "Current context: $current_context" >&2
      echo "Expected context: $EXPECTED_CONTEXT" >&2
      exit 1
    fi
    return
  fi

  current_cluster="$(kubectl_cmd config view --minify -o jsonpath='{.contexts[0].context.cluster}' 2>/dev/null || true)"
  cluster_name="${CLUSTER_NAME:-}"

  if [ -z "$cluster_name" ]; then
    case "$current_cluster" in
      k3d-*) cluster_name="${current_cluster#k3d-}" ;;
      *) cluster_name="pisofire" ;;
    esac
  fi

  expected_cluster="k3d-$cluster_name"

  if [ "$current_cluster" != "$expected_cluster" ]; then
    echo "Refusing to run restore." >&2
    echo "Current context: $current_context" >&2
    echo "Current cluster: ${current_cluster:-<none>}" >&2
    echo "Expected cluster: $expected_cluster" >&2
    echo "For tenant, set KUBECONFIG_FILE and EXPECTED_CONTEXT explicitly." >&2
    exit 1
  fi
}

case "$BACKUP_FILE" in
  ""|*/*)
    echo "Backup file must be a file name inside the postgres-backups PVC, not a path." >&2
    exit 1
    ;;
esac

if [ "$CONFIRM_RESTORE" != "I_UNDERSTAND_THIS_OVERWRITES_POSTGRES" ]; then
  echo "Refusing to restore without explicit confirmation." >&2
  echo "This drops and recreates the configured PostgreSQL database from a backup dump." >&2
  echo "Run with:" >&2
  echo "  CONFIRM_RESTORE=I_UNDERSTAND_THIS_OVERWRITES_POSTGRES $0 $BACKUP_FILE" >&2
  exit 1
fi

require_command kubectl
validate_context

kubectl_cmd get statefulset -n "$NAMESPACE" postgres >/dev/null
kubectl_cmd get pvc -n "$NAMESPACE" postgres-backups >/dev/null

MEDUSA_REPLICAS="$(kubectl_cmd get deployment -n "$NAMESPACE" medusa -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
MEDUSA_WORKER_REPLICAS="$(kubectl_cmd get deployment -n "$NAMESPACE" medusa-worker -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
STOREFRONT_REPLICAS="$(kubectl_cmd get deployment -n "$NAMESPACE" storefront -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"

MEDUSA_REPLICAS="${MEDUSA_REPLICAS:-1}"
MEDUSA_WORKER_REPLICAS="${MEDUSA_WORKER_REPLICAS:-1}"
STOREFRONT_REPLICAS="${STOREFRONT_REPLICAS:-1}"

echo "Scaling application deployments down before restore"
kubectl_cmd scale -n "$NAMESPACE" deployment/medusa --replicas=0 >/dev/null
kubectl_cmd scale -n "$NAMESPACE" deployment/medusa-worker --replicas=0 >/dev/null
kubectl_cmd scale -n "$NAMESPACE" deployment/storefront --replicas=0 >/dev/null

job_name="postgres-restore-$(date -u +%Y%m%d%H%M%S)"

echo "Creating restore job: $job_name"
kubectl_cmd apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $job_name
  namespace: $NAMESPACE
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        app: postgres-restore
    spec:
      restartPolicy: Never
      containers:
        - name: postgres-restore
          image: postgres:15-alpine
          imagePullPolicy: IfNotPresent
          env:
            - name: POSTGRES_DB
              valueFrom:
                configMapKeyRef:
                  name: pisofire-config
                  key: POSTGRES_DB
            - name: POSTGRES_USER
              valueFrom:
                configMapKeyRef:
                  name: pisofire-config
                  key: POSTGRES_USER
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: pisofire-secrets
                  key: POSTGRES_PASSWORD
            - name: BACKUP_FILE
              value: "$BACKUP_FILE"
          command:
            - sh
            - -ec
            - |
              backup_path="/backups/\$BACKUP_FILE"

              if [ ! -f "\$backup_path" ]; then
                echo "Backup not found: \$backup_path" >&2
                ls -lh /backups >&2 || true
                exit 1
              fi

              echo "Waiting for PostgreSQL to accept connections..."
              until pg_isready -h postgres -U "\$POSTGRES_USER" -d postgres; do
                sleep 5
              done

              echo "Dropping database \$POSTGRES_DB"
              dropdb -h postgres -U "\$POSTGRES_USER" --force --if-exists "\$POSTGRES_DB"

              echo "Creating database \$POSTGRES_DB"
              createdb -h postgres -U "\$POSTGRES_USER" "\$POSTGRES_DB"

              echo "Restoring \$backup_path"
              pg_restore \
                -h postgres \
                -U "\$POSTGRES_USER" \
                -d "\$POSTGRES_DB" \
                --no-owner \
                --no-acl \
                "\$backup_path"

              psql -h postgres -U "\$POSTGRES_USER" -d "\$POSTGRES_DB" -tAc 'SELECT 1' >/dev/null
              echo "Restore completed from \$backup_path"
          volumeMounts:
            - name: postgres-backups
              mountPath: /backups
          resources:
            requests:
              cpu: 200m
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 1Gi
      volumes:
        - name: postgres-backups
          persistentVolumeClaim:
            claimName: postgres-backups
EOF

if ! kubectl_cmd wait -n "$NAMESPACE" --for=condition=complete --timeout="$RESTORE_TIMEOUT" "job/$job_name" >/dev/null; then
  echo "Restore job did not complete: $job_name" >&2
  kubectl_cmd logs -n "$NAMESPACE" "job/$job_name" >&2 || true
  echo "Restoring application deployment replicas after failed restore" >&2
  kubectl_cmd scale -n "$NAMESPACE" deployment/medusa --replicas="$MEDUSA_REPLICAS" >/dev/null || true
  kubectl_cmd scale -n "$NAMESPACE" deployment/medusa-worker --replicas="$MEDUSA_WORKER_REPLICAS" >/dev/null || true
  kubectl_cmd scale -n "$NAMESPACE" deployment/storefront --replicas="$STOREFRONT_REPLICAS" >/dev/null || true
  exit 1
fi

kubectl_cmd logs -n "$NAMESPACE" "job/$job_name"

echo "Restoring application deployment replicas after restore"
kubectl_cmd scale -n "$NAMESPACE" deployment/medusa --replicas="$MEDUSA_REPLICAS" >/dev/null
kubectl_cmd scale -n "$NAMESPACE" deployment/medusa-worker --replicas="$MEDUSA_WORKER_REPLICAS" >/dev/null
kubectl_cmd scale -n "$NAMESPACE" deployment/storefront --replicas="$STOREFRONT_REPLICAS" >/dev/null
kubectl_cmd rollout restart -n "$NAMESPACE" deployment/medusa deployment/medusa-worker deployment/storefront >/dev/null
kubectl_cmd rollout status -n "$NAMESPACE" --timeout=240s deployment/medusa deployment/medusa-worker deployment/storefront >/dev/null

printf '%s\n' "PostgreSQL restore completed" \
  "Namespace: $NAMESPACE" \
  "Job: $job_name" \
  "Backup file: $BACKUP_FILE"
