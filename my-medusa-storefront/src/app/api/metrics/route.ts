import { NextResponse } from "next/server"
import { getStorefrontMetrics } from "@lib/metrics"

export const dynamic = "force-dynamic"
export const runtime = "nodejs"

const DEFAULT_TIMEOUT_MS = 2000

const metricsTimeoutMs = () => {
  const configured = Number(process.env.METRICS_TIMEOUT_MS)
  return Number.isFinite(configured) && configured > 0
    ? configured
    : DEFAULT_TIMEOUT_MS
}

async function collectBackendMetrics() {
  const metrics = getStorefrontMetrics()
  const backendUrl = process.env.MEDUSA_BACKEND_URL
  const startedAt = process.hrtime.bigint()
  let status = "error"

  try {
    if (!backendUrl) {
      throw new Error("MEDUSA_BACKEND_URL is not configured")
    }

    const controller = new AbortController()
    const timeout = setTimeout(() => controller.abort(), metricsTimeoutMs())

    try {
      const response = await fetch(`${backendUrl}/readyz`, {
        cache: "no-store",
        signal: controller.signal,
      })

      status = response.ok ? "success" : "unready"
      metrics.backendUp.set(response.ok ? 1 : 0)
    } finally {
      clearTimeout(timeout)
    }
  } catch (error) {
    metrics.backendUp.set(0)
    metrics.collectionErrorsTotal.inc({ collector: "backend" })
  } finally {
    const durationSeconds =
      Number(process.hrtime.bigint() - startedAt) / 1_000_000_000
    metrics.backendReadyLatency.observe({ status }, durationSeconds)
  }
}

export async function GET() {
  const metrics = getStorefrontMetrics()
  const startedAt = process.hrtime.bigint()
  let status: "success" | "error" = "success"

  try {
    await collectBackendMetrics()
  } catch (error) {
    status = "error"
    metrics.collectionErrorsTotal.inc({ collector: "metrics" })
  } finally {
    const durationSeconds =
      Number(process.hrtime.bigint() - startedAt) / 1_000_000_000
    metrics.metricsScrapesTotal.inc({ status })
    metrics.metricsScrapeDuration.observe({ status }, durationSeconds)
  }

  return new NextResponse(await metrics.register.metrics(), {
    status: 200,
    headers: {
      "Content-Type": metrics.register.contentType,
    },
  })
}
