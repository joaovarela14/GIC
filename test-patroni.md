# Test Patroni Deployment

This file lists the commands to build, deploy, and validate the Patroni PostgreSQL setup.

## Start From This Branch

```bash
git checkout patroni
git status --short --branch
```

## Tenant Cluster

Use this flow for the department tenant namespace.

### 1. Set Variables

```bash
export KUBECONFIG_FILE=tenant-pisofire-kubeconfig.yaml
export EXPECTED_CONTEXT=tenant-pisofire-context
export NAMESPACE=tenant-pisofire
export IMAGE_PREFIX=registry.deti/tenant-pisofire
export IMAGE_TAG=$(git rev-parse --short HEAD)
export KUBECTL_REQUEST_TIMEOUT=30s
export KUBECTL_PROBE_TIMEOUT=30s
```

### 2. Preflight

```bash
kubectl --kubeconfig "$KUBECONFIG_FILE" config current-context
kubectl --kubeconfig "$KUBECONFIG_FILE" get namespace "$NAMESPACE"
kubectl --kubeconfig "$KUBECONFIG_FILE" get storageclass
kubectl --kubeconfig "$KUBECONFIG_FILE" get crd \
  servicemonitors.monitoring.coreos.com \
  prometheusrules.monitoring.coreos.com \
  probes.monitoring.coreos.com
```

Create tenant secrets if needed:

```bash
test -f k8s/tenant/tenant-secrets.env || cp k8s/tenant/tenant-secrets.env.example k8s/tenant/tenant-secrets.env
```

Edit `k8s/tenant/tenant-secrets.env` before deploying. `DATABASE_URL` must use the same password as `POSTGRES_PASSWORD`.

Render manifests before applying:

```bash
IMAGE_PREFIX="$IMAGE_PREFIX" IMAGE_TAG="$IMAGE_TAG" ./scripts/render-tenant-k8s.sh > /tmp/pisofire-tenant-rendered.yaml
rg -n "postgres-patroni|kind: StatefulSet|storageClassName|role: primary|role: replica" /tmp/pisofire-tenant-rendered.yaml
```

If this namespace already has data, take a backup before migrating:

```bash
KUBECONFIG_FILE="$KUBECONFIG_FILE" \
EXPECTED_CONTEXT="$EXPECTED_CONTEXT" \
NAMESPACE="$NAMESPACE" \
./scripts/backup-postgres-k8s.sh
```

### 3. Configure Registry Access

If Docker fails with a certificate error for `registry.deti`, configure it as an insecure registry on your machine:

```bash
sudo mkdir -p /etc/docker

if [ -f /etc/docker/daemon.json ]; then
  sudo cp /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%s)"
fi

sudo python3 - <<'PY'
import json
from pathlib import Path

path = Path("/etc/docker/daemon.json")
data = {}
if path.exists() and path.read_text().strip():
    data = json.loads(path.read_text())

registries = set(data.get("insecure-registries", []))
registries.add("registry.deti")
registries.add("registry.deti:443")
data["insecure-registries"] = sorted(registries)

path.write_text(json.dumps(data, indent=2) + "\n")
PY

sudo systemctl restart docker
docker info | sed -n '/Insecure Registries:/,/Live Restore Enabled:/p'
```

Then log in:

```bash
docker login registry.deti
```

### 4. Build And Push Images

```bash
IMAGE_PREFIX="$IMAGE_PREFIX" \
IMAGE_TAG="$IMAGE_TAG" \
./scripts/build-push-tenant-images.sh
```

### 5. Deploy

For a clean namespace, run the normal deploy:

```bash
KUBECONFIG_FILE="$KUBECONFIG_FILE" \
EXPECTED_CONTEXT="$EXPECTED_CONTEXT" \
NAMESPACE="$NAMESPACE" \
IMAGE_PREFIX="$IMAGE_PREFIX" \
IMAGE_TAG="$IMAGE_TAG" \
./scripts/deploy-tenant-k8s.sh
```

If the namespace already has the master-branch non-Patroni Postgres StatefulSet, the script refuses the implicit rolling migration. After confirming a fresh backup, run the controlled migration mode. It temporarily scales application deployments to zero, converts `postgres-0` first, then brings `postgres-1` back as the replica:

```bash
KUBECONFIG_FILE="$KUBECONFIG_FILE" \
EXPECTED_CONTEXT="$EXPECTED_CONTEXT" \
NAMESPACE="$NAMESPACE" \
IMAGE_PREFIX="$IMAGE_PREFIX" \
IMAGE_TAG="$IMAGE_TAG" \
ALLOW_PATRONI_MIGRATION=true \
./scripts/deploy-tenant-k8s.sh
```

### 6. Wait For Rollouts

```bash
kubectl --kubeconfig "$KUBECONFIG_FILE" rollout status -n "$NAMESPACE" --timeout=300s statefulset/postgres
kubectl --kubeconfig "$KUBECONFIG_FILE" rollout status -n "$NAMESPACE" --timeout=300s statefulset/redis
kubectl --kubeconfig "$KUBECONFIG_FILE" rollout status -n "$NAMESPACE" --timeout=300s deployment/medusa
kubectl --kubeconfig "$KUBECONFIG_FILE" rollout status -n "$NAMESPACE" --timeout=300s deployment/medusa-worker
kubectl --kubeconfig "$KUBECONFIG_FILE" rollout status -n "$NAMESPACE" --timeout=300s deployment/storefront
```

### 7. Run Full Smoke Test

```bash
KUBECONFIG_FILE="$KUBECONFIG_FILE" \
EXPECTED_CONTEXT="$EXPECTED_CONTEXT" \
NAMESPACE="$NAMESPACE" \
./scripts/smoke-test-tenant-k8s.sh
```

### 8. Patroni-Specific Checks

```bash
kubectl --kubeconfig "$KUBECONFIG_FILE" get pods -n "$NAMESPACE" -l app=postgres --show-labels
kubectl --kubeconfig "$KUBECONFIG_FILE" get svc -n "$NAMESPACE" postgres postgres-replica postgres-headless
kubectl --kubeconfig "$KUBECONFIG_FILE" get endpoints -n "$NAMESPACE" postgres postgres-replica postgres-headless
```

```bash
PRIMARY_POD="$(
  kubectl --kubeconfig "$KUBECONFIG_FILE" get pod -n "$NAMESPACE" \
    -l app=postgres,cluster-name=pisofire-postgres,role=primary \
    -o jsonpath='{.items[0].metadata.name}'
)"

REPLICA_POD="$(
  kubectl --kubeconfig "$KUBECONFIG_FILE" get pod -n "$NAMESPACE" \
    -l app=postgres,cluster-name=pisofire-postgres,role=replica \
    -o jsonpath='{.items[0].metadata.name}'
)"

echo "Primary: $PRIMARY_POD"
echo "Replica: $REPLICA_POD"
```

Primary must return `f`; replica must return `t`:

```bash
kubectl --kubeconfig "$KUBECONFIG_FILE" exec -n "$NAMESPACE" "$PRIMARY_POD" -- sh -ec \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT pg_is_in_recovery()"'

kubectl --kubeconfig "$KUBECONFIG_FILE" exec -n "$NAMESPACE" "$REPLICA_POD" -- sh -ec \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT pg_is_in_recovery()"'
```

Check Patroni cluster view:

```bash
kubectl --kubeconfig "$KUBECONFIG_FILE" exec -n "$NAMESPACE" "$PRIMARY_POD" -- \
  patronictl -c /tmp/patroni.yml list
```

Verify the `postgres` Service points to a writable primary:

```bash
POSTGRES_USER="$(
  kubectl --kubeconfig "$KUBECONFIG_FILE" get configmap -n "$NAMESPACE" pisofire-config \
    -o jsonpath='{.data.POSTGRES_USER}'
)"
POSTGRES_DB="$(
  kubectl --kubeconfig "$KUBECONFIG_FILE" get configmap -n "$NAMESPACE" pisofire-config \
    -o jsonpath='{.data.POSTGRES_DB}'
)"
POSTGRES_PASSWORD="$(
  kubectl --kubeconfig "$KUBECONFIG_FILE" get secret -n "$NAMESPACE" pisofire-secrets \
    -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d
)"

kubectl --kubeconfig "$KUBECONFIG_FILE" run -n "$NAMESPACE" "postgres-service-check-$(date +%s)" \
  --rm -i --restart=Never \
  --image=postgres:15-alpine \
  --env="PGPASSWORD=$POSTGRES_PASSWORD" \
  --env="POSTGRES_USER=$POSTGRES_USER" \
  --env="POSTGRES_DB=$POSTGRES_DB" \
  -- sh -ec 'pg_isready -h postgres -U "$POSTGRES_USER" -d "$POSTGRES_DB" && psql -h postgres -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT pg_is_in_recovery()"'
```

Expected final SQL output: `f`.

### 9. Application Checks

```bash
kubectl --kubeconfig "$KUBECONFIG_FILE" get pods,pvc,svc,ingress,hpa,cronjob -n "$NAMESPACE"
kubectl --kubeconfig "$KUBECONFIG_FILE" logs -n "$NAMESPACE" deployment/medusa --tail=80
kubectl --kubeconfig "$KUBECONFIG_FILE" logs -n "$NAMESPACE" deployment/storefront --tail=80
```

If `/etc/hosts` is configured for the tenant ingress:

```bash
curl -I http://pisofire.deti
curl -fsS http://medusa-pisofire.deti/health
curl -fsS http://medusa-pisofire.deti/readyz
curl -fsS http://medusa-pisofire.deti/store-readyz
```

### 10. Backup Check

```bash
KUBECONFIG_FILE="$KUBECONFIG_FILE" \
EXPECTED_CONTEXT="$EXPECTED_CONTEXT" \
NAMESPACE="$NAMESPACE" \
./scripts/backup-postgres-k8s.sh

kubectl --kubeconfig "$KUBECONFIG_FILE" get jobs -n "$NAMESPACE" | rg postgres-backup
kubectl --kubeconfig "$KUBECONFIG_FILE" get pvc -n "$NAMESPACE" postgres-backups
```

## Local k3d Cluster

Use this flow for local validation only.

### 1. Select Local Cluster

```bash
k3d cluster start pisofire
k3d kubeconfig merge pisofire --kubeconfig-switch-context
kubectl config current-context
kubectl get nodes
```

### 2. Build, Import, And Deploy

```bash
./scripts/deploy-k8s.sh pisofire
```

### 3. Run Smoke Test

```bash
./scripts/smoke-test-k8s.sh
```

### 4. Local Patroni Checks

```bash
kubectl get pods -n pisofire -l app=postgres --show-labels
kubectl get svc -n pisofire postgres postgres-replica postgres-headless
kubectl get endpoints -n pisofire postgres postgres-replica postgres-headless
```

```bash
PRIMARY_POD="$(
  kubectl get pod -n pisofire \
    -l app=postgres,cluster-name=pisofire-postgres,role=primary \
    -o jsonpath='{.items[0].metadata.name}'
)"

REPLICA_POD="$(
  kubectl get pod -n pisofire \
    -l app=postgres,cluster-name=pisofire-postgres,role=replica \
    -o jsonpath='{.items[0].metadata.name}'
)"

kubectl exec -n pisofire "$PRIMARY_POD" -- sh -ec \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT pg_is_in_recovery()"'

kubectl exec -n pisofire "$REPLICA_POD" -- sh -ec \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT pg_is_in_recovery()"'

kubectl exec -n pisofire "$PRIMARY_POD" -- patronictl -c /tmp/patroni.yml list
```

Primary must return `f`; replica must return `t`.

### 5. Local App Checks

```bash
kubectl get pods,pvc,svc,hpa,cronjob -n pisofire
kubectl port-forward -n pisofire svc/medusa 9000:9000
```

In another terminal:

```bash
curl -fsS http://127.0.0.1:9000/health
curl -fsS http://127.0.0.1:9000/readyz
curl -fsS http://127.0.0.1:9000/store-readyz
```

For storefront:

```bash
kubectl port-forward -n pisofire svc/storefront 8000:8000
```

In another terminal:

```bash
curl -I http://127.0.0.1:8000/pt
curl -fsS http://127.0.0.1:8000/api/health
curl -fsS http://127.0.0.1:8000/api/ready
```

## Troubleshooting

If `postgres-1` is crash-looping with a log like `system ID mismatch`, or the `postgres` Service has no endpoints, check for a partial migration from the old master Postgres StatefulSet:

```bash
kubectl --kubeconfig "$KUBECONFIG_FILE" get pods -n "$NAMESPACE" postgres-0 postgres-1 -o wide
kubectl --kubeconfig "$KUBECONFIG_FILE" describe pod -n "$NAMESPACE" postgres-1
kubectl --kubeconfig "$KUBECONFIG_FILE" logs -n "$NAMESPACE" postgres-1 -c postgres --previous --tail=120
kubectl --kubeconfig "$KUBECONFIG_FILE" get endpoints -n "$NAMESPACE" postgres postgres-headless postgres-replica pisofire-postgres pisofire-postgres-config
```

Complete the migration with the explicit mode:

```bash
KUBECONFIG_FILE="$KUBECONFIG_FILE" \
EXPECTED_CONTEXT="$EXPECTED_CONTEXT" \
NAMESPACE="$NAMESPACE" \
IMAGE_PREFIX="$IMAGE_PREFIX" \
IMAGE_TAG="$IMAGE_TAG" \
ALLOW_PATRONI_MIGRATION=true \
./scripts/deploy-tenant-k8s.sh
```

```bash
kubectl --kubeconfig "$KUBECONFIG_FILE" get events -n "$NAMESPACE" --sort-by=.lastTimestamp | tail -40
kubectl --kubeconfig "$KUBECONFIG_FILE" describe statefulset -n "$NAMESPACE" postgres
kubectl --kubeconfig "$KUBECONFIG_FILE" describe pod -n "$NAMESPACE" "$PRIMARY_POD"
kubectl --kubeconfig "$KUBECONFIG_FILE" logs -n "$NAMESPACE" "$PRIMARY_POD" -c postgres --tail=120
kubectl --kubeconfig "$KUBECONFIG_FILE" logs -n "$NAMESPACE" "$REPLICA_POD" -c postgres --tail=120
```

For local k3d, remove `--kubeconfig "$KUBECONFIG_FILE"` and use `-n pisofire`.
