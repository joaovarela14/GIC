import * as client from "prom-client"

type StorefrontMetrics = {
  register: client.Registry
  info: client.Gauge<"node_env">
  metricsScrapesTotal: client.Counter<"status">
  metricsScrapeDuration: client.Histogram<"status">
  backendUp: client.Gauge
  backendReadyLatency: client.Histogram<"status">
  collectionErrorsTotal: client.Counter<"collector">
}

const globalForMetrics = globalThis as typeof globalThis & {
  __pisofireStorefrontMetrics?: StorefrontMetrics
}

export function getStorefrontMetrics() {
  if (globalForMetrics.__pisofireStorefrontMetrics) {
    return globalForMetrics.__pisofireStorefrontMetrics
  }

  const register = new client.Registry()

  register.setDefaultLabels({
    app: "pisofire",
    service: "storefront",
  })

  client.collectDefaultMetrics({
    prefix: "pisofire_storefront_",
    register,
  })

  const metrics: StorefrontMetrics = {
    register,
    info: new client.Gauge({
      name: "pisofire_storefront_info",
      help: "Static information about the storefront process.",
      labelNames: ["node_env"],
      registers: [register],
    }),
    metricsScrapesTotal: new client.Counter({
      name: "pisofire_storefront_metrics_scrapes_total",
      help: "Total Prometheus scrapes served by the storefront.",
      labelNames: ["status"],
      registers: [register],
    }),
    metricsScrapeDuration: new client.Histogram({
      name: "pisofire_storefront_metrics_scrape_duration_seconds",
      help: "Duration of storefront metrics collection in seconds.",
      labelNames: ["status"],
      buckets: [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
      registers: [register],
    }),
    backendUp: new client.Gauge({
      name: "pisofire_storefront_backend_up",
      help: "Medusa backend readiness from the storefront perspective. 1 is up, 0 is down.",
      registers: [register],
    }),
    backendReadyLatency: new client.Histogram({
      name: "pisofire_storefront_backend_ready_latency_seconds",
      help: "Latency of the storefront readiness check against Medusa.",
      labelNames: ["status"],
      buckets: [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
      registers: [register],
    }),
    collectionErrorsTotal: new client.Counter({
      name: "pisofire_storefront_metric_collection_errors_total",
      help: "Total errors while collecting storefront custom metrics.",
      labelNames: ["collector"],
      registers: [register],
    }),
  }

  metrics.info.set(
    {
      node_env: process.env.NODE_ENV || "unknown",
    },
    1
  )

  globalForMetrics.__pisofireStorefrontMetrics = metrics

  return metrics
}
