# Autoscaling and Resilience

The stateless request path is replicated and autoscaled.

- `medusa`: starts with 2 replicas and can scale to 5.
- `storefront`: starts with 2 replicas and can scale to 5.
- `medusa-worker`: starts with 1 replica and can scale to 3.

The HPAs use CPU and memory metrics. CPU and memory requests are set because HPA
utilization depends on resource requests.

Medusa and storefront also use:

- rolling updates with `maxUnavailable: 0`
- topology spread preferences
- PodDisruptionBudgets in the local/base manifests

The tenant overlay omits PodDisruptionBudgets because this is a shared DETI
department cluster and the tenant service account cannot create
`poddisruptionbudgets.policy`. This is a shared-cluster RBAC limitation, not an
application design choice.

## Useful tests

```bash
./scripts/hpa-scale-test-k8s.sh
./scripts/resilience-test-k8s.sh
```

`resilience-test-k8s.sh` expects at least two ready replicas for `medusa` and
`storefront` before it deletes a pod.

## Current limits

- Deployment is still standard Kubernetes RollingUpdate, not a true canary or
  traffic-percentage rollout.
- There is no automated 5% -> 25% -> 50% -> 100% progressive rollout yet.
