# Known Limits

- PostgreSQL replication is asynchronous, so the latest transactions can be
  lost if the primary fails before the standby receives the WAL.
- PostgreSQL backup and restore exist, but restore is an operator-triggered DR
  action, not an automatic recovery loop.
- PodDisruptionBudgets are present in the local/base manifests. The tenant
  overlay omits them because this is a shared DETI department cluster and the
  tenant service account cannot create `poddisruptionbudgets.policy`.
- MinIO is a single-replica Deployment with one PVC, so media/object storage is
  not highly available. This is partially intentional: the expected
  cluster-wide storage was unavailable because of issues unrelated to this
  project, so the deployment uses a local PVC and does not focus on MinIO HA.
- Observability covers metrics, dashboards, synthetic probes, and alerts, but
  there is no centralized log aggregation or distributed tracing.
- Health checks are dependency-aware, but not version or schema-aware yet.
- Rollouts are safe RollingUpdates with rollback, but not canary rollouts.
- The local `k3d` setup is still a single-node test environment.
