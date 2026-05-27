import {
  defineMiddlewares,
  MedusaNextFunction,
  MedusaRequest,
  MedusaResponse,
} from "@medusajs/framework/http"
import { getMedusaMetrics, normalizeMedusaRoute } from "../lib/metrics"

function prometheusHttpMiddleware(
  req: MedusaRequest,
  res: MedusaResponse,
  next: MedusaNextFunction
) {
  const metrics = getMedusaMetrics()
  const startedAt = process.hrtime.bigint()

  res.on("finish", () => {
    const durationSeconds =
      Number(process.hrtime.bigint() - startedAt) / 1_000_000_000
    const labels = {
      method: req.method,
      route: normalizeMedusaRoute(req.path),
      status_code: String(res.statusCode),
    }

    metrics.httpRequestsTotal.inc(labels)
    metrics.httpRequestDuration.observe(labels, durationSeconds)
  })

  next()
}

export default defineMiddlewares({
  routes: [
    {
      matcher: "*",
      middlewares: [prometheusHttpMiddleware],
    },
  ],
})
