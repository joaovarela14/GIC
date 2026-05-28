# PisoFire SLIs and SLOs

## Scope

These SLIs and SLOs focus on the critical user journey defined for PisoFire: a user enters the flash-sale store, views a sneaker product, adds a size to the cart, completes checkout, and creates an order.

The main monitored services are:

- Storefront
- Medusa backend
- PostgreSQL
- Redis

The main metrics source is Prometheus, using the custom `pisofire_*` metrics exposed by the backend and storefront.

## Critical User Journey

Checkout path:

1. User opens the storefront.
2. User views products.
3. User creates or updates a cart.
4. User creates a payment collection.
5. User completes the order.

Relevant backend route groups:

- `/store/products.*`
- `/store/regions.*`
- `/store/carts.*`
- `/store/payment.*`
- `/store/orders.*`

## SLIs

### 1. Checkout Availability

Measures the percentage of successful backend requests in the checkout path.

Successful requests are requests that do not return a 5xx status code.

PromQL:

```promql
100 *
sum(rate(pisofire_medusa_http_requests_total{
  route=~"/store/(products|regions|carts|payment|orders).*",
  status_code!~"5.."
}[5m]))
/
sum(rate(pisofire_medusa_http_requests_total{
  route=~"/store/(products|regions|carts|payment|orders).*"
}[5m]))
```

SLO:

- Checkout availability should be at least 99.5% over the evaluation window.

## 2. Checkout Latency

Measures backend request latency for the checkout path.

Primary latency SLI:

- p95 latency for checkout-path requests.

PromQL:

```promql
histogram_quantile(
  0.95,
  sum(rate(pisofire_medusa_http_request_duration_seconds_bucket{
    route=~"/store/(products|regions|carts|payment|orders).*"
  }[5m])) by (le)
)
```

SLO:

- Checkout-path p95 latency should stay below 1 second over the evaluation window.

## 3. Backend Error Rate

Measures the percentage of all backend requests that return 5xx responses.

PromQL:

```promql
100 *
sum(rate(pisofire_medusa_http_requests_total{status_code=~"5.."}[5m]))
/
sum(rate(pisofire_medusa_http_requests_total[5m]))
```

SLO:

- Backend 5xx error rate should stay below 5% over 5 minutes.

## 4. Storefront to Backend Readiness

Measures whether the storefront can reach the Medusa backend readiness endpoint.

PromQL:

```promql
pisofire_storefront_backend_up
```

SLO:

- `pisofire_storefront_backend_up` should be `1` for at least 99.5% of the evaluation window.

## 5. Storefront to Backend Readiness Latency

Measures the latency from the storefront to Medusa `/readyz`.

PromQL:

```promql
histogram_quantile(
  0.95,
  sum(rate(pisofire_storefront_backend_ready_latency_seconds_bucket[5m])) by (le)
)
```

SLO:

- p95 storefront-to-backend readiness latency should stay below 500 ms.

## 6. Database Availability

Measures whether Medusa can reach and query PostgreSQL.

PromQL:

```promql
pisofire_medusa_dependency_up{dependency="database"}
```

SLO:

- Database dependency availability should be `1` for at least 99.5% of the evaluation window.

## 7. Redis Availability

Measures whether Medusa can reach Redis.

PromQL:

```promql
pisofire_medusa_dependency_up{dependency="redis"}
```

SLO:

- Redis dependency availability should be `1` for at least 99.5% of the evaluation window.

## Alert Mapping

Existing alert rules cover the most important SLO failures:

- `PisofireHighErrorRate`: backend error rate above 5%.
- `PisofireHighLatency`: backend p95 latency above 1 second.
- `PisofireMedusaDown`: Medusa metrics target unavailable.
- `PisofirePostgresDown`: Postgres exporter unavailable.
- `PisofireRedisDown`: Redis exporter unavailable.
- `PisofirePostgresBackupFailed`: backup job failed.
- `PisofirePostgresBackupStale`: no successful backup in more than 26 hours.

## Summary Table

| Area | SLI | SLO |
| --- | --- | --- |
| Checkout availability | Non-5xx rate for checkout-path backend requests | >= 99.5% |
| Checkout latency | p95 latency for checkout-path backend requests | < 1s |
| Backend errors | 5xx rate across backend requests | < 5% over 5m |
| Storefront to backend health | `pisofire_storefront_backend_up` | `1` for >= 99.5% |
| Storefront to backend latency | p95 latency to Medusa `/readyz` | < 500ms |
| Database availability | `pisofire_medusa_dependency_up{dependency="database"}` | `1` for >= 99.5% |
| Redis availability | `pisofire_medusa_dependency_up{dependency="redis"}` | `1` for >= 99.5% |
