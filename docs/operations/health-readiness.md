# Health and Readiness Checks

The project separates basic health from readiness.

## Medusa backend

- `/health` is the basic process health endpoint used by the liveness probe.
- `/readyz` checks if Medusa can query PostgreSQL and ping Redis.
- `/store-readyz` checks if the store is usable by verifying the publishable key,
  regions and products through the Store API.

## Storefront

- `/api/health` is the basic process health endpoint used by the liveness probe.
- `/api/ready` calls Medusa `/readyz` and only returns ready when the backend is
  reachable and ready.

## Kubernetes probe mapping

- Medusa startup and liveness: `/health`
- Medusa readiness: `/readyz`
- Storefront startup and liveness: `/api/health`
- Storefront readiness: `/api/ready`

This prevents traffic from going to application pods before their required
dependencies are available.

## Current limits

- Health responses do not yet include app versions, image tags, git commits or
  expected schema versions.
- Readiness does not yet validate a specific database migration version.
