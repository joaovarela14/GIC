# Known Limits

- PostgreSQL runs as a primary/standby StatefulSet, but failover is manual.
- Redis is a single-instance service.
- There is backup and restore, but no automatic database failover.
- Health checks are dependency-aware, but not version or schema-aware yet.
- Rollouts are safe RollingUpdates with rollback, but not canary rollouts.
- The local `k3d` setup is still a single-node test environment.
