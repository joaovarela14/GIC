# PisoFire Kubernetes Baseline

This directory contains a minimal M1 baseline for running PisoFire on Kubernetes with:

- `postgres`
- `redis`
- `medusa` server
- `medusa-worker`
- `bootstrap-admin` job
- `bootstrap-store` job
- `storefront`

It uses plain manifests with `kustomization.yaml` so the deployment stays easy to debug.

The local baseline targets `k3d`. The department cluster overlay lives in
`k8s/tenant` and targets the pre-created `tenant-pisofire` namespace.

## Safety

Do not run any `kubectl apply` command until you are sure you are pointing at the intended local test cluster.

This repository may coexist with other clusters and contexts. Validate your target context manually before applying anything.

## Assumptions

- You are using `k3d` locally.
- The local cluster can use images loaded from your Docker daemon.
- This is a smoke-test baseline, not a production deployment.

## Images

Build the application images first:

```bash
docker build -t my-medusa-store-medusa:latest my-medusa-store
docker build -t my-medusa-store-storefront:latest my-medusa-storefront
```

If your `k3d` cluster was created without direct Docker image access, import the images:

```bash
k3d image import my-medusa-store-medusa:latest -c pisofire
k3d image import my-medusa-store-storefront:latest -c pisofire
```

Replace `pisofire` with your cluster name if needed.

## Deploy

Build, import, and apply in one step:

```bash
./scripts/deploy-k8s.sh
```

Or run the steps manually.

Apply the manifests:

```bash
kubectl apply -k k8s
```

Watch the rollout:

```bash
kubectl get pods -n pisofire -w
```

Wait for the bootstrap jobs to complete successfully:

```bash
kubectl get jobs -n pisofire
kubectl logs -n pisofire job/bootstrap-admin
kubectl logs -n pisofire job/bootstrap-store
```

`bootstrap-admin` creates the local Medusa Admin demo user. If that user already
exists, the job treats it as success so repeated deploys stay idempotent.

## Access

Port-forward the storefront:

```bash
kubectl port-forward -n pisofire svc/storefront 8000:8000
```

Optional: port-forward the backend too:

```bash
kubectl port-forward -n pisofire svc/medusa 9000:9000
```

Medusa Admin is available at `http://localhost:9000/app`.

Development admin credentials are bootstrapped by `bootstrap-admin`:

```text
URL: http://localhost:9000/app
Email: admin@pisofire.local
Password: PisoFire123!
```

## Smoke Checks

Backend health and readiness:

```bash
curl http://localhost:9000/health
curl http://localhost:9000/readyz
curl http://localhost:9000/store-readyz
```

Storefront health and readiness:

```bash
curl http://localhost:8000/api/health
curl http://localhost:8000/api/ready
curl -I http://localhost:8000/pt
```

Metrics for Prometheus/Grafana:

```bash
curl http://localhost:9000/metrics
curl http://localhost:8000/api/metrics
```

The manifests include standard Prometheus scrape annotations on the Medusa and
storefront Pods and Services:

```text
prometheus.io/scrape: "true"
prometheus.io/port: "9000"
prometheus.io/path: /metrics

prometheus.io/scrape: "true"
prometheus.io/port: "8000"
prometheus.io/path: /api/metrics
```

The Services are also labeled with `app=medusa` and `app=storefront` for
Prometheus Operator `ServiceMonitor` selectors.

Key custom metrics:

- `pisofire_medusa_http_requests_total`
- `pisofire_medusa_http_request_duration_seconds`
- `pisofire_medusa_dependency_up`
- `pisofire_medusa_store_entity_count`
- `pisofire_storefront_backend_up`
- `pisofire_storefront_backend_ready_latency_seconds`

Service-level checks from inside the cluster:

```bash
kubectl run -n pisofire service-smoke \
  --rm -i --restart=Never \
  --image=busybox:1.36 \
  -- sh -ec '
    wget -qO- http://medusa:9000/readyz
    wget -qO- http://medusa:9000/store-readyz
    wget -qO- http://medusa:9000/metrics | grep -q "^pisofire_medusa_info"
    wget -qO- http://storefront:8000/api/ready
    wget -qO- http://storefront:8000/api/metrics | grep -q "^pisofire_storefront_info"
    wget -qO- http://storefront:8000/pt >/dev/null
  '
```

Repeatable end-to-end smoke test:

```bash
./scripts/smoke-test-k8s.sh
```

The smoke test:

- verifies the current `kubectl` cluster is the expected local `k3d` cluster.
- checks Kubernetes API connectivity and node disk pressure before testing the app.
- waits for all core deployments and for both bootstrap jobs.
- checks backend health/readiness through `/health`, `/readyz` and `/store-readyz`.
- checks storefront health/readiness through `/api/health` and `/api/ready`.
- checks backend and storefront metrics through `/metrics` and `/api/metrics`.
- verifies Medusa Admin login by creating a session cookie and calling `/admin/users/me`.
- runs a checkout path from product discovery to order creation.
- validates in-cluster Service DNS by calling `medusa` and `storefront` from a temporary BusyBox pod, including their metrics endpoints.

Successful output ends with:

```text
Smoke test passed
Backend health: 200
Backend readiness: 200
Store readiness: 200
Backend metrics: 200
Storefront health: 200
Storefront readiness: 200
Storefront metrics: 200
Admin authentication: passed
Service DNS checks: passed
Order: order_...
```

`Storefront page: 307` is acceptable because the first localized storefront
request can redirect while the region/cache cookie is established.

If local ports are busy, override them:

```bash
MEDUSA_PORT=19000 STOREFRONT_PORT=18000 ./scripts/smoke-test-k8s.sh
```

Useful cluster checks:

```bash
kubectl get all -n pisofire
kubectl describe pod -n pisofire <pod-name>
kubectl logs -n pisofire deployment/medusa
kubectl logs -n pisofire deployment/storefront
```

## Current Limits

- Single replica for every component, including the Medusa server and worker.
- Postgres is a single instance backed by one PVC.
- Redis is single-instance and ephemeral.
- Store and admin bootstrap depend on one-shot Kubernetes jobs.
- The stack is still a local single-node baseline, not a production-ready deployment.
- The storefront can use `NEXT_PUBLIC_MEDUSA_PUBLISHABLE_KEY` when configured, but otherwise still retrieves the Medusa publishable key dynamically at runtime through a custom Medusa store route.
- Secrets are development defaults and must be replaced before any real deployment.
