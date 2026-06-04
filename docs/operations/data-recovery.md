# Data Recovery

## PostgreSQL

PostgreSQL runs as a two-pod Patroni-managed StatefulSet. Patroni uses
namespace-local Kubernetes objects for leader election, promotes a replica after
primary failure, and labels pods so the `postgres` Service follows the current
primary.

Hardening added:

- PostgreSQL uses one PVC per StatefulSet pod.
- The current writable primary is the pod labeled `role=primary`.
- At least one standby replica is labeled `role=replica` when both pods are
  healthy.
- A `postgres-backup` CronJob creates nightly `pg_dump -Fc` backups.
- Backups are stored in the `postgres-backups` PVC.
- `latest.dump` points to the newest dump.
- A manual restore script scales application Deployments down, restores the
  database from a dump through the `postgres` writer Service, and scales the
  Deployments back up.
- In the local/base manifests, a PodDisruptionBudget with `maxUnavailable: 0`
  blocks voluntary PostgreSQL evictions. The tenant overlay omits PDBs because
  this is a shared DETI department cluster and the tenant service account cannot
  create them.

Commands:

```bash
./scripts/backup-postgres-k8s.sh

CONFIRM_RESTORE=I_UNDERSTAND_THIS_OVERWRITES_POSTGRES \
  ./scripts/restore-postgres-k8s.sh latest.dump
```

Current limits:

- PostgreSQL HA is namespace-local and does not protect against complete cluster
  or storage loss.
- Replication is asynchronous, so the latest transactions can be lost if the
  primary fails before replicas receive WAL.
- Restore is deliberately manual. It proves disaster recovery when executed,
  but it is not automatic failover and should be captured as separate evidence
  for grading.

## Redis

Tenant Redis runs as a three-pod StatefulSet with Redis Sentinel. Sentinel keeps
one writable master and promotes a replica when the current master is unavailable.
Medusa uses ioredis Sentinel discovery, so Redis clients reconnect to the promoted
master instead of writing through a fixed Kubernetes Service.

Hardening added:

- Redis uses one `redis-data-redis-N` PVC per StatefulSet pod.
- Redis AOF is enabled with `appendonly yes` and `appendfsync everysec`.
- Each Redis pod also runs a Sentinel container on port `26379`.
- Sentinel quorum is `2` for the `pisofire-redis` master name.
- Redis and Sentinel probes use `redis-cli ping`.

Current limits:

- The legacy single-pod local/base manifest still uses one Redis instance.
- Existing data in the old `redis-data` PVC is not migrated automatically to the
  new StatefulSet PVCs.
- Redis health does not yet validate pub/sub subscribers or expected channels.
