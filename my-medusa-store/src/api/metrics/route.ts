import { MedusaRequest, MedusaResponse } from "@medusajs/framework/http"
import { Registry, collectDefaultMetrics, Counter, Histogram } from "prom-client"

const registry = new Registry()
registry.setDefaultLabels({ app: "medusa", tenant: "pisofire" })
collectDefaultMetrics({ register: registry })

export const httpRequestsTotal = new Counter({
  name: "medusa_http_requests_total",
  help: "Total HTTP requests",
  labelNames: ["method", "route", "status"],
  registers: [registry],
})

export const httpRequestDuration = new Histogram({
  name: "medusa_http_request_duration_seconds",
  help: "HTTP request duration in seconds",
  labelNames: ["method", "route", "status"],
  buckets: [0.05, 0.1, 0.3, 0.5, 1, 2, 5],
  registers: [registry],
})

export const GET = async (req: MedusaRequest, res: MedusaResponse) => {
  res.set("Content-Type", registry.contentType)
  res.end(await registry.metrics())
}
