# Deployment Automation

This repo has two deployment flows:

- Local baseline for `k3d`.
- Tenant overlay for the department cluster namespace.

## Local deploy (k3d)

```bash
./scripts/deploy-k8s.sh
```

What it does:

- validates the current `kubectl` context is the expected `k3d` cluster
- builds the Medusa and storefront images
- imports images into the `k3d` cluster
- applies the manifests in `k8s/`
- restarts application deployments when needed
- waits for rollouts and rolls back application deployments on failure

The script only runs on `k3d` contexts. It refuses to deploy to non-`k3d`
clusters by design.

## Tenant deploy (department cluster)

Prerequisites:

- a kubeconfig file with access to the tenant namespace
- a populated secrets file: `k8s/tenant/tenant-secrets.env`
- a container registry reachable by the cluster

Build and push images:

```bash
IMAGE_PREFIX=registry.deti/tenant-pisofire \
IMAGE_TAG=$(git rev-parse --short HEAD) \
./scripts/build-push-tenant-images.sh
```

Deploy the tenant overlay:

```bash
KUBECONFIG_FILE=tenant-pisofire-kubeconfig.yaml \
EXPECTED_CONTEXT=tenant-pisofire-context \
NAMESPACE=tenant-pisofire \
IMAGE_PREFIX=registry.deti/tenant-pisofire \
IMAGE_TAG=$(git rev-parse --short HEAD) \
./scripts/deploy-tenant-k8s.sh
```

Optional: render the final manifests before deploying:

```bash
IMAGE_TAG=$(git rev-parse --short HEAD) ./scripts/render-tenant-k8s.sh
```

## Rollback behavior

Rollback is based on Kubernetes ReplicaSet history. It uses
`kubectl rollout undo` for `medusa`, `medusa-worker` and `storefront` when
an apply, restart or rollout fails.
