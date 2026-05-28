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

Redis is still a single instance. It is not highly available.

Hardening added:

- Redis uses a `redis-data` PVC.
- Redis AOF is enabled with `appendonly yes`.
- Local Redis probes use `redis-cli ping`.
- A PodDisruptionBudget with `maxUnavailable: 0` blocks voluntary evictions.

Current limits:

- Redis does not yet use Sentinel or Redis Cluster.
- Tenant Redis still has a TCP probe and should be aligned with the local
  `redis-cli ping` probe.
- Redis health does not yet validate pub/sub subscribers or expected channels.
