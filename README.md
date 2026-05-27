## PisoFire 👟🔥

[Docker problems](https://docs.medusajs.com/learn/installation/docker)

[Storefront problems](https://docs.medusajs.com/resources/nextjs-starter)


# TODO

- [X] - change the job, change the way the publishable key works
- [ ] - we probably need MinIO



## Kubernetes Deploy

From the repo root, after you manually switch `kubectl` to the correct local test context:

```bash
./scripts/deploy-k8s.sh
```

The script:
- builds the Medusa and storefront images
- imports them into the `pisofire` `k3d` cluster
- refuses to run unless the current cluster is the expected `k3d` cluster
- imports dependency images used by the manifests
- recreates the bootstrap jobs when redeploying
- applies the manifests in `k8s/`

The local Kubernetes deployment includes two bootstrap jobs:

- `bootstrap-store`: seeds/repairs store data such as regions, products, shipping, payment and the publishable key.
- `bootstrap-admin`: creates the Medusa Admin demo user. If the user already exists, the job exits successfully.

Medusa Admin demo credentials:

```text
URL: http://localhost:9000/app
Email: admin@pisofire.local
Password: PisoFire123!
```

To open the Admin from the local `k3d` cluster:

```bash
kubectl port-forward -n pisofire svc/medusa 9000:9000
```

If login succeeds but returns to the login page, clear browser site data for `localhost:9000` or use a private window. The local Kubernetes config sets non-secure SameSite cookies so Admin sessions work over `http://localhost:9000`.

## Metrics

The Kubernetes manifests expose Prometheus-compatible metrics for the backend
and storefront through scrape annotations on both Pods and Services.

When the local port-forwards are active:

```bash
curl http://localhost:9000/metrics
curl http://localhost:8000/api/metrics
```

Prometheus should scrape:

- Medusa backend: `http://medusa:9000/metrics`
- Storefront: `http://storefront:8000/api/metrics`

The Services are labeled with `app=medusa` and `app=storefront`, so a
Prometheus Operator `ServiceMonitor` can select them directly if the monitoring
stack does not scrape `prometheus.io/*` annotations.

Useful custom metrics:

- `pisofire_medusa_info`: static backend process labels.
- `pisofire_medusa_http_requests_total`: backend requests by method, route and status.
- `pisofire_medusa_http_request_duration_seconds`: backend request latency.
- `pisofire_medusa_dependency_up`: backend view of `database` and `redis` availability.
- `pisofire_medusa_store_entity_count`: counts for key store entities such as products, regions, orders and admin users.
- `pisofire_storefront_info`: static storefront process labels.
- `pisofire_storefront_backend_up`: storefront view of Medusa readiness.
- `pisofire_storefront_backend_ready_latency_seconds`: latency from storefront to Medusa `/readyz`.

Both apps also export Node.js process metrics with these prefixes:

- `pisofire_medusa_...`
- `pisofire_storefront_...`

## Resilience and Autoscaling

For M2, the stateless request path is no longer single-replica:

- `medusa`: starts with 2 replicas and can scale to 5.
- `storefront`: starts with 2 replicas and can scale to 5.
- `medusa-worker`: starts with 1 replica and can scale to 3.

The HPAs use Kubernetes CPU and memory metrics:

- Medusa scales above 70% CPU or 80% memory utilization.
- Storefront scales above 70% CPU or 80% memory utilization.
- Worker scales above 75% CPU or 80% memory utilization.

The manifests also define CPU/memory requests and limits for application pods,
Postgres, Redis and tenant exporters. Medusa and storefront use rolling updates with
`maxUnavailable: 0`, topology spread preferences across nodes and
PodDisruptionBudgets so voluntary disruptions keep at least one serving pod.

To demonstrate routing around pod failures locally:

```bash
./scripts/resilience-test-k8s.sh
```

The script deletes one Medusa pod and one storefront pod, checks the Services from
inside the cluster during recovery, and waits for both Deployments to return to the
desired replica count.

Postgres and Redis are still single-instance stateful services. Postgres is protected
by a backup CronJob and manual restore procedure, but real database HA still
requires managed Postgres or a replicated database topology.

## PostgreSQL Backup and Restore

The manifests create:

- `postgres-backups`: a dedicated PVC for dump files.
- `postgres-backup`: a nightly CronJob that runs `pg_dump -Fc`.

Run an immediate backup:

```bash
./scripts/backup-postgres-k8s.sh
```

Restore is intentionally explicit because it drops and recreates the configured
database from a backup dump:

```bash
CONFIRM_RESTORE=I_UNDERSTAND_THIS_OVERWRITES_POSTGRES \
  ./scripts/restore-postgres-k8s.sh latest.dump
```

For the tenant cluster, use the same scripts with the tenant kubeconfig/context:

```bash
KUBECONFIG_FILE=tenant-pisofire-kubeconfig.yaml \
EXPECTED_CONTEXT=tenant-pisofire-context \
NAMESPACE=tenant-pisofire \
./scripts/backup-postgres-k8s.sh
```

## Kubernetes Smoke Test

For functional and M2 baseline verification:

```bash
./scripts/smoke-test-k8s.sh
```

The smoke test validates the deployment through Kubernetes Services, not only through container ports. It:

- confirms the current `kubectl` cluster is the expected `k3d` cluster
- fails early if the Kubernetes API is unreachable or nodes are under disk pressure
- waits for `postgres`, `redis`, `medusa`, `medusa-worker` and `storefront` rollouts
- waits for `bootstrap-admin` and `bootstrap-store` to complete
- checks HPA, PodDisruptionBudget and Kubernetes metrics API availability
- checks PostgreSQL backup CronJob and backup PVC availability
- starts temporary local port-forwards to Medusa and the storefront
- checks Medusa `/health`, `/readyz` and `/store-readyz`
- checks storefront `/api/health` and `/api/ready`
- checks Medusa `/metrics` and storefront `/api/metrics`
- tests Medusa Admin authentication with the bootstrapped admin user and verifies `/admin/users/me`
- runs a store checkout path: publishable key, region, product, variant, cart, shipping, payment collection and order creation
- runs in-cluster Service DNS checks from a temporary BusyBox pod against `medusa` and `storefront`, including the metrics endpoints

When it succeeds, expect output like:

```text
Smoke test passed
Context: k3d-pisofire
Namespace: pisofire
Backend health: 200
Backend readiness: 200
Store readiness: 200
Backend metrics: 200
Storefront health: 200
Storefront readiness: 200
Storefront metrics: 200
Autoscaling controls: present
PostgreSQL backup controls: present
Admin authentication: passed
Storefront page: 307
Service DNS checks: passed
Region: reg_...
Product: prod_...
Variant: variant_...
Cart: cart_...
Shipping option: so_...
Payment provider: pp_system_default
Payment collection: pay_col_...
Order: order_...
```

`Storefront page: 307` is expected in this baseline because the first storefront request can redirect while the storefront sets the Medusa region/cache cookie.

If ports `9000` or `8000` are already in use by Docker Compose or a manual port-forward, either stop that process or run the smoke test on alternative local ports:

```bash
MEDUSA_PORT=19000 STOREFRONT_PORT=18000 ./scripts/smoke-test-k8s.sh
```

## Department Tenant Deploy

The teacher-provided kubeconfig is for the shared tenant namespace, not for local
`k3d`. Keep `tenant-pisofire-kubeconfig.yaml` uncommitted.

Build and push registry images, then deploy the tenant overlay when ready:

```bash
cp k8s/tenant/tenant-secrets.env.example k8s/tenant/tenant-secrets.env
# Edit k8s/tenant/tenant-secrets.env with real random values before deploying.
# DATABASE_URL must use the same password as POSTGRES_PASSWORD.
IMAGE_TAG=$(git rev-parse --short HEAD) ./scripts/build-push-tenant-images.sh
IMAGE_TAG=$(git rev-parse --short HEAD) ./scripts/render-tenant-k8s.sh
IMAGE_TAG=$(git rev-parse --short HEAD) ./scripts/deploy-tenant-k8s.sh
./scripts/smoke-test-tenant-k8s.sh
```

The tenant defaults use `registry.deti/tenant-pisofire`.
`k8s/tenant/tenant-secrets.env` is ignored by git and must not be committed.
