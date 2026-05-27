import * as client from "prom-client"

type MedusaMetrics = {
  register: client.Registry
  info: client.Gauge<"worker_mode" | "node_env">
  httpRequestsTotal: client.Counter<"method" | "route" | "status_code">
  httpRequestDuration: client.Histogram<"method" | "route" | "status_code">
  metricsScrapesTotal: client.Counter<"status">
  metricsScrapeDuration: client.Histogram<"status">
  dependencyUp: client.Gauge<"dependency">
  storeEntityCount: client.Gauge<"entity">
  collectionErrorsTotal: client.Counter<"collector">
}

const globalForMetrics = globalThis as typeof globalThis & {
  __pisofireMedusaMetrics?: MedusaMetrics
}

export function getMedusaMetrics() {
  if (globalForMetrics.__pisofireMedusaMetrics) {
    return globalForMetrics.__pisofireMedusaMetrics
  }

  const register = new client.Registry()

  register.setDefaultLabels({
    app: "pisofire",
    service: "medusa",
  })

  client.collectDefaultMetrics({
    prefix: "pisofire_medusa_",
    register,
  })

  const metrics: MedusaMetrics = {
    register,
    info: new client.Gauge({
      name: "pisofire_medusa_info",
      help: "Static information about the Medusa process.",
      labelNames: ["worker_mode", "node_env"],
      registers: [register],
    }),
    httpRequestsTotal: new client.Counter({
      name: "pisofire_medusa_http_requests_total",
      help: "Total HTTP requests handled by Medusa.",
      labelNames: ["method", "route", "status_code"],
      registers: [register],
    }),
    httpRequestDuration: new client.Histogram({
      name: "pisofire_medusa_http_request_duration_seconds",
      help: "HTTP request duration in seconds for Medusa.",
      labelNames: ["method", "route", "status_code"],
      buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
      registers: [register],
    }),
    metricsScrapesTotal: new client.Counter({
      name: "pisofire_medusa_metrics_scrapes_total",
      help: "Total Prometheus scrapes served by Medusa.",
      labelNames: ["status"],
      registers: [register],
    }),
    metricsScrapeDuration: new client.Histogram({
      name: "pisofire_medusa_metrics_scrape_duration_seconds",
      help: "Duration of Medusa metrics collection in seconds.",
      labelNames: ["status"],
      buckets: [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
      registers: [register],
    }),
    dependencyUp: new client.Gauge({
      name: "pisofire_medusa_dependency_up",
      help: "Dependency health from Medusa perspective. 1 is up, 0 is down.",
      labelNames: ["dependency"],
      registers: [register],
    }),
    storeEntityCount: new client.Gauge({
      name: "pisofire_medusa_store_entity_count",
      help: "Count of selected Medusa store entities.",
      labelNames: ["entity"],
      registers: [register],
    }),
    collectionErrorsTotal: new client.Counter({
      name: "pisofire_medusa_metric_collection_errors_total",
      help: "Total errors while collecting Medusa custom metrics.",
      labelNames: ["collector"],
      registers: [register],
    }),
  }

  metrics.info.set(
    {
      worker_mode: process.env.MEDUSA_WORKER_MODE || "unknown",
      node_env: process.env.NODE_ENV || "unknown",
    },
    1
  )

  globalForMetrics.__pisofireMedusaMetrics = metrics

  return metrics
}

export function normalizeMedusaRoute(path: string) {
  if (!path || path === "/") {
    return "/"
  }

  if (path === "/metrics") {
    return "/metrics"
  }

  const parts = path.split("/").filter(Boolean)

  if (parts.length === 0) {
    return "/"
  }

  if (parts[0] === "store" || parts[0] === "admin" || parts[0] === "auth") {
    return parts[1] ? `/${parts[0]}/${parts[1]}` : `/${parts[0]}`
  }

  return `/${parts[0]}`
}
