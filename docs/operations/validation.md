# Validation and Smoke Tests

## Local smoke test (k3d)

```bash
./scripts/smoke-test-k8s.sh
```

The smoke test validates the deployment through Kubernetes Services, not only
through container ports. It checks:

- cluster context safety
- deployment rollouts
- bootstrap jobs
- health and readiness endpoints
- Prometheus metrics endpoints
- HPA and PodDisruptionBudget resources
- PostgreSQL backup resources
- Redis persistence resources and, in the tenant cluster, Sentinel role/quorum checks
- Medusa Admin login
- checkout journey from product discovery to order creation
- in-cluster Service DNS for Medusa and storefront

If local ports `9000` or `8000` are already in use, override them:

```bash
MEDUSA_PORT=19000 STOREFRONT_PORT=18000 ./scripts/smoke-test-k8s.sh
```

## Tenant smoke test (department cluster)

```bash
KUBECONFIG_FILE=tenant-pisofire-kubeconfig.yaml \
EXPECTED_CONTEXT=tenant-pisofire-context \
NAMESPACE=tenant-pisofire \
MEDUSA_BASE_URL=http://medusa-pisofire.deti \
STOREFRONT_BASE_URL=http://pisofire.deti \
./scripts/smoke-test-tenant-k8s.sh
```

The tenant smoke test uses Ingress URLs and validates the same functional path
as the local test, including Redis Sentinel master discovery, admin login and
checkout.
