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
- refuses to run unless the current context is `k3d-pisofire`
- applies the manifests in `k8s/`

For M1 functional verification:

```bash
./scripts/smoke-test-k8s.sh
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
