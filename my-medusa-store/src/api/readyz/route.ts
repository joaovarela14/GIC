import { MedusaRequest, MedusaResponse } from "@medusajs/framework/http"
import { ContainerRegistrationKeys } from "@medusajs/framework/utils"
import { Socket } from "node:net"

const DEFAULT_TIMEOUT_MS = 2000

const readinessTimeoutMs = () => {
  const configured = Number(process.env.READINESS_TIMEOUT_MS)
  return Number.isFinite(configured) && configured > 0
    ? configured
    : DEFAULT_TIMEOUT_MS
}

const redisPingCommand = "*1\r\n$4\r\nPING\r\n"

function pingRedis(redisUrl: string, timeoutMs: number): Promise<void> {
  return new Promise((resolve, reject) => {
    const url = new URL(redisUrl)
    const socket = new Socket()
    let settled = false

    const finish = (error?: Error) => {
      if (settled) {
        return
      }

      settled = true
      clearTimeout(timeout)
      socket.destroy()

      if (error) {
        reject(error)
      } else {
        resolve()
      }
    }

    const timeout = setTimeout(() => {
      finish(new Error(`Redis PING timed out after ${timeoutMs}ms`))
    }, timeoutMs)

    socket.once("error", (error) => {
      finish(error)
    })

    socket.on("data", (chunk) => {
      const response = chunk.toString("utf8").trim()

      if (response.startsWith("+PONG")) {
        finish()
        return
      }

      finish(new Error(`Unexpected Redis PING response: ${response}`))
    })

    socket.connect(Number(url.port || 6379), url.hostname, () => {
      socket.write(redisPingCommand)
    })
  })
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
