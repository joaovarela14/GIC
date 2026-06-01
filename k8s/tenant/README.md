# PisoFire Tenant Cluster Overlay

This overlay targets the teacher-provided Kubernetes tenant:

- context: `tenant-pisofire-context`
- namespace: `tenant-pisofire`

It intentionally does not include a `Namespace` resource, because the namespace is
expected to already exist in the shared department cluster.

The YAML files in this directory are self-contained copies of the local baseline
manifests. This avoids `kubectl kustomize` load-restriction issues when building the
tenant overlay.

## Images

## Secrets

Create a local secrets file before rendering or deploying:

```bash
cp k8s/tenant/tenant-secrets.env.example k8s/tenant/tenant-secrets.env
```

Replace every value with a real random value. For example:

```bash
openssl rand -base64 32
```

The real `tenant-secrets.env` file is ignored by git. Only
`tenant-secrets.env.example` should be committed.

The overlay generates a Kubernetes Secret named `pisofire-secrets` from this local file.
`DATABASE_URL` must use the same password as `POSTGRES_PASSWORD`, for example:

```text
POSTGRES_PASSWORD=<password>
DATABASE_URL=postgres://postgres:<password>@postgres:5432/medusa-store
```

## Images

The base manifests use local `k3d` image names. For the tenant cluster, images must be
available from a registry that the cluster can pull from.

Build and push both images:

```bash
IMAGE_TAG=$(git rev-parse --short HEAD) ./scripts/build-push-tenant-images.sh
```

Render the tenant manifests locally before applying:

```bash
IMAGE_TAG=$(git rev-parse --short HEAD) ./scripts/render-tenant-k8s.sh
```

Apply to the tenant cluster only when you are ready:

```bash
IMAGE_TAG=$(git rev-parse --short HEAD) ./scripts/deploy-tenant-k8s.sh
```

The deploy script checks that the kubeconfig context is `tenant-pisofire-context`.
It deletes and recreates the bootstrap Jobs before applying, because Kubernetes Jobs
cannot be updated in place when their image tag changes. It then waits for
`medusa`, `medusa-worker` and `storefront` rollouts. If the application rollout
fails, it runs `kubectl rollout undo` for those deployments and exits with a failure.

After deployment, run:

```bash
./scripts/smoke-test-tenant-k8s.sh
```

The tenant overlay includes the M2 monitoring and autoscaling resources:

- ServiceMonitors for Medusa, storefront, Postgres exporter and Redis exporter.
- PrometheusRule alerts for error rate, latency and dependency availability.
- Grafana dashboard ConfigMaps.
- HPAs for `medusa`, `storefront` and `medusa-worker`.
- PodDisruptionBudgets are omitted from the tenant overlay because the tenant
  service account cannot create `poddisruptionbudgets.policy`.
- A `postgres-backup` CronJob and `postgres-backups` PVC for database recovery.
- A three-pod Redis StatefulSet with Redis Sentinel, one PVC per pod, and AOF
  enabled for pod recreation and failover recovery.

The backend and storefront start with two replicas and can scale to five when CPU or
memory utilization crosses the configured HPA targets. The worker starts with one
replica and can scale to three.

Postgres runs as a two-pod Patroni-managed StatefulSet. Patroni uses
namespace-local Kubernetes objects for leader election, labels the writable pod
with `role=primary`, and the `postgres` Service follows that label instead of a
fixed pod ordinal. Redis runs as one master and two replicas with Sentinel quorum
`2`; Medusa connects through Sentinel so Redis writes follow the promoted master
after failover.

Migrating from the older single-pod Postgres/Redis Deployments or fixed-primary
Postgres StatefulSet creates/reuses StatefulSet PVCs. Existing data is not copied
automatically between PVC naming schemes, so take backups before deploying and
restore data into the new primaries if tenant data must be preserved.

Useful Redis Sentinel checks after deployment:

```bash
kubectl exec -n tenant-pisofire redis-0 -c sentinel -- \
  redis-cli -p 26379 SENTINEL get-master-addr-by-name pisofire-redis

kubectl exec -n tenant-pisofire redis-0 -c redis -- redis-cli role
kubectl exec -n tenant-pisofire redis-1 -c redis -- redis-cli role
kubectl exec -n tenant-pisofire redis-2 -c redis -- redis-cli role
```

Run the HPA scale-up demonstration against the tenant cluster:

```bash
KUBECONFIG_FILE=tenant-pisofire-kubeconfig.yaml \
EXPECTED_CONTEXT=tenant-pisofire-context \
NAMESPACE=tenant-pisofire \
./scripts/hpa-scale-test-k8s.sh
```

The script creates temporary in-cluster HTTP load, observes the HPA scale-up, and
restores the original HPA thresholds and replica count before exiting.

Run an immediate tenant backup:

```bash
KUBECONFIG_FILE=tenant-pisofire-kubeconfig.yaml \
EXPECTED_CONTEXT=tenant-pisofire-context \
NAMESPACE=tenant-pisofire \
./scripts/backup-postgres-k8s.sh
```

Restore requires explicit confirmation:

```bash
KUBECONFIG_FILE=tenant-pisofire-kubeconfig.yaml \
EXPECTED_CONTEXT=tenant-pisofire-context \
NAMESPACE=tenant-pisofire \
CONFIRM_RESTORE=I_UNDERSTAND_THIS_OVERWRITES_POSTGRES \
./scripts/restore-postgres-k8s.sh latest.dump
```

By default, images are built and pushed as:

- `registry.deti/tenant-pisofire/medusa:<tag>`
- `registry.deti/tenant-pisofire/storefront:<tag>`

## Ingress

The tenant overlay exposes:

- `http://pisofire.deti` -> `storefront`
- `http://medusa-pisofire.deti` -> `medusa`

Add these entries to `/etc/hosts` on Linux/macOS, or to
`C:\Windows\System32\drivers\etc\hosts` on Windows:

```text
193.136.82.35 traefik.deti
193.136.82.35 registry.deti
193.136.82.35 cdn.deti
193.136.82.35 cdn-console.deti
193.136.82.35 longhorn.deti
193.136.82.35 pisofire.deti
193.136.82.35 medusa-pisofire.deti
```

Do not reuse Ingress hostnames created by other groups.
