# Next Todo

## Current Status

Patroni migration for the tenant cluster is complete.

- Namespace: `tenant-pisofire`
- Image tag deployed: `f205e60`
- Postgres primary: `postgres-0`
- Postgres replica: `postgres-1`
- `service/postgres` points to the Patroni primary.
- `service/postgres-replica` points to the Patroni replica.
- HPAs were recreated.
- Bootstrap jobs completed.
- Tenant smoke test passed.

Validation results:

```text
Primary pg_is_in_recovery(): f
Replica pg_is_in_recovery(): t
Patroni replica lag: 0 MB
Backend health: 200
Backend metrics: 200
Storefront status: 307
Storefront metrics: 200
Admin authentication: passed
Tenant smoke test: passed
```

## Repo State

Branch: `patroni`

Uncommitted files:

- `scripts/deploy-tenant-k8s.sh`
- `test-patroni.md`
- `next-todo.md`

Do not delete PVCs. The migration reused the existing Postgres PVCs.

## Implemented Fix

`scripts/deploy-tenant-k8s.sh` now handles master-to-Patroni tenant migration explicitly.

- Refuses implicit non-Patroni to Patroni migration unless `ALLOW_PATRONI_MIGRATION=true`.
- Uses `patch spec.replicas` instead of `kubectl scale`, because tenant RBAC cannot patch `/scale`.
- Deletes HPAs before temporarily scaling app deployments to zero.
- Applies a temporary migration overlay with app deployments at zero replicas and Postgres at one replica.
- Removes stale Patroni DCS endpoints/configmaps before bootstrapping Patroni from `postgres-0`.
- Brings `postgres-1` back as the replica.
- Applies the full tenant overlay afterward, recreating HPAs and bootstrap jobs.
- Uses request/probe timeouts so API read failures abort before mutating the cluster.

## Recheck Commands

```bash
export KUBECONFIG_FILE=tenant-pisofire-kubeconfig.yaml
export EXPECTED_CONTEXT=tenant-pisofire-context
export NAMESPACE=tenant-pisofire
```

```bash
kubectl --kubeconfig "$KUBECONFIG_FILE" get pods -n "$NAMESPACE" -l app=postgres --show-labels -o wide
kubectl --kubeconfig "$KUBECONFIG_FILE" get endpoints -n "$NAMESPACE" postgres postgres-replica postgres-headless
kubectl --kubeconfig "$KUBECONFIG_FILE" get hpa -n "$NAMESPACE"
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

kubectl --kubeconfig "$KUBECONFIG_FILE" exec -n "$NAMESPACE" "$PRIMARY_POD" -- sh -ec \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT pg_is_in_recovery()"'

kubectl --kubeconfig "$KUBECONFIG_FILE" exec -n "$NAMESPACE" "$REPLICA_POD" -- sh -ec \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT pg_is_in_recovery()"'

kubectl --kubeconfig "$KUBECONFIG_FILE" exec -n "$NAMESPACE" "$PRIMARY_POD" -- \
  patronictl -c /tmp/patroni.yml list
```

```bash
KUBECONFIG_FILE="$KUBECONFIG_FILE" \
EXPECTED_CONTEXT="$EXPECTED_CONTEXT" \
NAMESPACE="$NAMESPACE" \
./scripts/smoke-test-tenant-k8s.sh
```

## If Something Regresses

Collect diagnostics first:

```bash
kubectl --kubeconfig "$KUBECONFIG_FILE" get events -n "$NAMESPACE" --sort-by=.lastTimestamp | tail -50
kubectl --kubeconfig "$KUBECONFIG_FILE" describe statefulset -n "$NAMESPACE" postgres
kubectl --kubeconfig "$KUBECONFIG_FILE" describe pod -n "$NAMESPACE" postgres-0
kubectl --kubeconfig "$KUBECONFIG_FILE" describe pod -n "$NAMESPACE" postgres-1
kubectl --kubeconfig "$KUBECONFIG_FILE" logs -n "$NAMESPACE" postgres-0 -c postgres --tail=160
kubectl --kubeconfig "$KUBECONFIG_FILE" logs -n "$NAMESPACE" postgres-1 -c postgres --tail=160
kubectl --kubeconfig "$KUBECONFIG_FILE" logs -n "$NAMESPACE" deployment/medusa --tail=160
```
