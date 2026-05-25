import { MedusaNextFunction, MedusaRequest, MedusaResponse } from "@medusajs/framework/http"
import { httpRequestsTotal, httpRequestDuration } from "./metrics/route"

export function defineMiddlewares() {
  return {
    routes: [
      {
        matcher: "*",
        middlewares: [
          (req: MedusaRequest, res: MedusaResponse, next: MedusaNextFunction) => {
            const end = httpRequestDuration.startTimer()
            res.on("finish", () => {
              const route = req.route?.path ?? req.path
              const labels = { method: req.method, route, status: String(res.statusCode) }
              httpRequestsTotal.inc(labels)
              end(labels)
            })
            next()
          },
        ],
      },
    ],
  }
}
