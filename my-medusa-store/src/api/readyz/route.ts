import { MedusaRequest, MedusaResponse } from "@medusajs/framework/http"
import { ContainerRegistrationKeys } from "@medusajs/framework/utils"
import { pingRedis } from "../../lib/redis-health"

const DEFAULT_TIMEOUT_MS = 2000

const readinessTimeoutMs = () => {
  const configured = Number(process.env.READINESS_TIMEOUT_MS)
  return Number.isFinite(configured) && configured > 0
    ? configured
    : DEFAULT_TIMEOUT_MS
}

async function checkDatabase(req: MedusaRequest) {
  const query = req.scope.resolve(ContainerRegistrationKeys.QUERY)

  await query.graph({
    entity: "api_key",
    fields: ["id"],
    filters: {
      type: "publishable",
    },
  })
}

async function checkRedis() {
  const redisUrl = process.env.REDIS_URL

  if (!redisUrl) {
    throw new Error("REDIS_URL is not configured")
  }

  await pingRedis(redisUrl, readinessTimeoutMs())
}

export async function GET(req: MedusaRequest, res: MedusaResponse) {
  const checks: Record<string, string> = {}

  try {
    await checkDatabase(req)
    checks.database = "ok"

    await checkRedis()
    checks.redis = "ok"

    return res.json({
      ok: true,
      checks,
    })
  } catch (error) {
    return res.status(503).json({
      ok: false,
      checks,
      error: error instanceof Error ? error.message : "Readiness check failed",
    })
  }
}
