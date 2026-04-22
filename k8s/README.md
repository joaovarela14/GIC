# PisoFire Kubernetes Baseline

This directory contains a minimal M1 baseline for running PisoFire on Kubernetes with:

- `postgres`
- `redis`
- `medusa` server
- `medusa-worker`
- `bootstrap-store` job
- `storefront`

It uses plain manifests with `kustomization.yaml` so the deployment stays easy to debug.

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

Wait for the bootstrap job to complete successfully:

```bash
kubectl get jobs -n pisofire
kubectl logs -n pisofire job/bootstrap-store
```

## Access

Port-forward the storefront:

```bash
kubectl port-forward -n pisofire svc/storefront 8000:8000
```

Optional: port-forward the backend too:

```bash
kubectl port-forward -n pisofire svc/medusa 9000:9000
```

## Smoke Checks

Backend health:

```bash
curl http://localhost:9000/health
```

Storefront:

```bash
curl -I http://localhost:8000
```

Repeatable end-to-end smoke test:

```bash
./scripts/smoke-test-k8s.sh
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
- Store bootstrap depends on a one-shot Kubernetes job.
- The stack is still a local single-node baseline, not a production-ready deployment.
- The storefront retrieves the Medusa publishable key dynamically at runtime through a custom Medusa store route.
- Secrets are development defaults and must be replaced before any real deployment.
