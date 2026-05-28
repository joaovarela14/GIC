# Metrics and Monitoring

The backend and storefront expose Prometheus metrics.

## Backend

- Endpoint: `/metrics`
- Main custom metrics:
  - `pisofire_medusa_http_requests_total`
  - `pisofire_medusa_http_request_duration_seconds`
  - `pisofire_medusa_dependency_up`
  - `pisofire_medusa_store_entity_count`

## Storefront

- Endpoint: `/api/metrics`
- Main custom metrics:
  - `pisofire_storefront_backend_up`
  - `pisofire_storefront_backend_ready_latency_seconds`

## Node.js process metrics

Both services also expose Node.js process metrics with these prefixes:

- `pisofire_medusa_...`
- `pisofire_storefront_...`

## Kubernetes scraping

The Kubernetes Services and Pods include Prometheus scrape annotations. The tenant
overlay also includes `ServiceMonitor`, `PrometheusRule` and Grafana dashboard
resources.
