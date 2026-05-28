# Known Limits

- PostgreSQL and Redis are single-instance services.
- There is backup and restore, but no automatic database failover.
- Health checks are dependency-aware, but not version or schema-aware yet.
- Rollouts are safe RollingUpdates with rollback, but not canary rollouts.
- The local `k3d` setup is still a single-node test environment.
