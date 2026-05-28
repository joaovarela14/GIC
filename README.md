## PisoFire 👟🔥

[Docker problems](https://docs.medusajs.com/learn/installation/docker)

[Storefront problems](https://docs.medusajs.com/resources/nextjs-starter)

Documentation:

- [Docs index](docs/README.md)
- [Kubernetes baseline](k8s/README.md)
- [Operations](docs/operations/README.md)
- [SLIs and SLOs](docs/sli-slo.md)


# TODO

## Quick Local Deploy (k3d)

From the repo root, after you manually switch `kubectl` to the correct local test
context:

```bash
./scripts/deploy-k8s.sh
```

Medusa Admin demo credentials:

```text
URL: http://localhost:9000/app
Email: admin@pisofire.local
Password: PisoFire123!
```

Full deployment and validation steps live in:

- [Deployment automation](docs/operations/deployment.md)
- [Validation and smoke tests](docs/operations/validation.md)
IMAGE_TAG=$(git rev-parse --short HEAD) ./scripts/render-tenant-k8s.sh
IMAGE_TAG=$(git rev-parse --short HEAD) ./scripts/deploy-tenant-k8s.sh
./scripts/smoke-test-tenant-k8s.sh
```

The tenant defaults use `registry.deti/tenant-pisofire`.
`k8s/tenant/tenant-secrets.env` is ignored by git and must not be committed.
