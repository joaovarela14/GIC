import { MedusaRequest, MedusaResponse } from "@medusajs/framework/http"
import { ContainerRegistrationKeys } from "@medusajs/framework/utils"
import { getMedusaMetrics } from "../../lib/metrics"
import { pingRedis } from "../../lib/redis-health"

const DEFAULT_TIMEOUT_MS = 2000

const metricsTimeoutMs = () => {
  const configured = Number(process.env.METRICS_TIMEOUT_MS)
  return Number.isFinite(configured) && configured > 0
    ? configured
    : DEFAULT_TIMEOUT_MS
}

async function collectEntityCount(
  req: MedusaRequest,
  entity: string,
  metricEntityName = entity,
  filters?: Record<string, unknown>
) {
  const query = req.scope.resolve(ContainerRegistrationKeys.QUERY)
  const { data, metadata } = await query.graph({
    entity,
    fields: ["id"],
    pagination: {
      skip: 0,
      take: 1,
    },
    ...(filters ? { filters } : {}),
  })

  getMedusaMetrics().storeEntityCount.set(
    {
      entity: metricEntityName,
    },
    metadata?.count ?? (Array.isArray(data) ? data.length : 0)
  )
}

async function collectCustomMetrics(req: MedusaRequest) {
  const metrics = getMedusaMetrics()

  try {
    await collectEntityCount(req, "api_key", "publishable_api_keys", {
      type: "publishable",
    })
    await collectEntityCount(req, "region", "regions")
    await collectEntityCount(req, "product", "products")
    await collectEntityCount(req, "order", "orders")
    await collectEntityCount(req, "user", "admin_users")
    metrics.dependencyUp.set({ dependency: "database" }, 1)
  } catch (error) {
    metrics.dependencyUp.set({ dependency: "database" }, 0)
    metrics.collectionErrorsTotal.inc({ collector: "database" })
  }

  try {
    const redisUrl = process.env.REDIS_URL

    if (!redisUrl) {
      throw new Error("REDIS_URL is not configured")
    }

    await pingRedis(redisUrl, metricsTimeoutMs())
    metrics.dependencyUp.set({ dependency: "redis" }, 1)
  } catch (error) {
    metrics.dependencyUp.set({ dependency: "redis" }, 0)
    metrics.collectionErrorsTotal.inc({ collector: "redis" })
  }
}

export async function GET(req: MedusaRequest, res: MedusaResponse) {
  const metrics = getMedusaMetrics()
  const startedAt = process.hrtime.bigint()
  let status: "success" | "error" = "success"

  try {
    await collectCustomMetrics(req)
  } catch (error) {
    status = "error"
    metrics.collectionErrorsTotal.inc({ collector: "metrics" })
  } finally {
    const durationSeconds =
      Number(process.hrtime.bigint() - startedAt) / 1_000_000_000
    metrics.metricsScrapesTotal.inc({ status })
    metrics.metricsScrapeDuration.observe({ status }, durationSeconds)
  }

  res.set("Content-Type", metrics.register.contentType)
  res.send(await metrics.register.metrics())
}
