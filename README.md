# PisoFire

PisoFire is an operations-first SRE project for a flash-sale e-commerce store.
The application uses MedusaJS for the backend, a Next.js storefront, PostgreSQL,
Redis, and Kubernetes manifests for local and department-cluster deployments.

## Repository Map

- `my-medusa-store/`: Medusa backend, operational endpoints, metrics, and seed/bootstrap scripts.
- `my-medusa-storefront/`: Next.js storefront with health, readiness, and metrics endpoints.
- `k8s/`: local `k3d` baseline manifests.
- `k8s/tenant/`: DETI tenant-cluster overlay.
- `scripts/`: deployment, smoke-test, HPA, backup, restore, and resilience scripts.
- `docs/`: operational documentation, SLI/SLO definitions, and validation notes.

## Key Documentation

- [Documentation index](docs/README.md)
- [Kubernetes baseline](k8s/README.md)
- [Tenant overlay](k8s/tenant/README.md)
- [Operations overview](docs/operations/README.md)
- [SLIs and SLOs](docs/sli-slo.md)

## Local Deploy

Prerequisites: Docker, `k3d`, and `kubectl` configured for the intended local
cluster.

From the repo root:

```bash
./scripts/deploy-k8s.sh
./scripts/smoke-test-k8s.sh
```

Medusa Admin demo credentials:

```text
URL: http://localhost:9000/app
Email: admin@pisofire.local
Password: PisoFire123!
```

If local ports are busy:

```bash
MEDUSA_PORT=19000 STOREFRONT_PORT=18000 ./scripts/smoke-test-k8s.sh
```

## Tenant Deploy

Create the local secrets file first:

```bash
cp k8s/tenant/tenant-secrets.env.example k8s/tenant/tenant-secrets.env
```

Replace every placeholder in `k8s/tenant/tenant-secrets.env` with real values.
This file is ignored by git and must not be committed.

Build, push, render, deploy, and validate:

```bash
IMAGE_TAG=$(git rev-parse --short HEAD) ./scripts/build-push-tenant-images.sh
IMAGE_TAG=$(git rev-parse --short HEAD) ./scripts/render-tenant-k8s.sh

KUBECONFIG_FILE=tenant-pisofire-kubeconfig.yaml \
EXPECTED_CONTEXT=tenant-pisofire-context \
NAMESPACE=tenant-pisofire \
IMAGE_TAG=$(git rev-parse --short HEAD) \
./scripts/deploy-tenant-k8s.sh

KUBECONFIG_FILE=tenant-pisofire-kubeconfig.yaml \
EXPECTED_CONTEXT=tenant-pisofire-context \
NAMESPACE=tenant-pisofire \
./scripts/smoke-test-tenant-k8s.sh
```

The tenant defaults use `registry.deti/tenant-pisofire`.

## Operational Scripts

```bash
./scripts/hpa-scale-test-k8s.sh
./scripts/resilience-test-k8s.sh
./scripts/backup-postgres-k8s.sh

CONFIRM_RESTORE=I_UNDERSTAND_THIS_OVERWRITES_POSTGRES \
  ./scripts/restore-postgres-k8s.sh latest.dump
```

For tenant runs, pass `KUBECONFIG_FILE`, `EXPECTED_CONTEXT`, and `NAMESPACE` as
shown above.
