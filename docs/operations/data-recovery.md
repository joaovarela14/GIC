# Data Recovery

## PostgreSQL

PostgreSQL runs as a two-pod StatefulSet with a fixed primary and one standby
replica. It is replicated, but it does not provide automatic failover.

Hardening added:

- PostgreSQL uses one PVC per StatefulSet pod.
- `postgres-0` is the writable primary and `postgres-1` is the standby.
- A `postgres-backup` CronJob creates nightly `pg_dump -Fc` backups.
- Backups are stored in the `postgres-backups` PVC.
- `latest.dump` points to the newest dump.
- A manual restore script can restore the database from a dump.
- A PodDisruptionBudget with `maxUnavailable: 0` blocks voluntary evictions.

Commands:

```bash
./scripts/backup-postgres-k8s.sh

CONFIRM_RESTORE=I_UNDERSTAND_THIS_OVERWRITES_POSTGRES \
  ./scripts/restore-postgres-k8s.sh latest.dump
```

Current limits:

- Automatic PostgreSQL failover would require managed PostgreSQL or a
  PostgreSQL operator with leader election and safe primary promotion.

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
