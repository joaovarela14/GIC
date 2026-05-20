import { MedusaRequest, MedusaResponse } from "@medusajs/framework/http"
import { ContainerRegistrationKeys } from "@medusajs/framework/utils"

type PublishableKeyRecord = {
  id: string
  token: string
  title?: string | null
}

const DEFAULT_TIMEOUT_MS = 3000

const readinessTimeoutMs = () => {
  const configured = Number(process.env.READINESS_TIMEOUT_MS)
  return Number.isFinite(configured) && configured > 0
    ? configured
    : DEFAULT_TIMEOUT_MS
}

async function fetchWithTimeout(url: string, init: RequestInit = {}) {
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), readinessTimeoutMs())

  try {
    return await fetch(url, {
      ...init,
      signal: controller.signal,
    })
  } finally {
    clearTimeout(timeout)
  }
}

async function getPublishableKey(req: MedusaRequest) {
  const query = req.scope.resolve(ContainerRegistrationKeys.QUERY)

  const { data } = await query.graph({
    entity: "api_key",
    fields: ["id", "token", "title"],
    filters: {
      type: "publishable",
    },
  })

  const keys = (data ?? []) as PublishableKeyRecord[]
  const publishableKey =
    keys.find((key) => key.title === "Webshop") ?? keys[0]

  if (!publishableKey?.token) {
    throw new Error("No publishable API key is configured")
  }

  return publishableKey.token
}

export async function GET(req: MedusaRequest, res: MedusaResponse) {
  const checks: Record<string, string> = {}
  const selfUrl =
    process.env.MEDUSA_SELF_URL ||
    process.env.MEDUSA_INTERNAL_URL ||
    "http://127.0.0.1:9000"

  try {
    const publishableKey = await getPublishableKey(req)
    checks.publishable_key = "ok"

    const headers = {
      "x-publishable-api-key": publishableKey,
    }

    const regionsResponse = await fetchWithTimeout(`${selfUrl}/store/regions`, {
      headers,
      cache: "no-store",
    })
    const regionsPayload = await regionsResponse.json()

    if (!regionsResponse.ok || !regionsPayload.regions?.length) {
      throw new Error("No store-visible regions are available")
    }

    checks.regions = "ok"

    const regionId = regionsPayload.regions[0].id
    const productsResponse = await fetchWithTimeout(
      `${selfUrl}/store/products?limit=1&region_id=${regionId}`,
      {
        headers,
        cache: "no-store",
      }
    )
    const productsPayload = await productsResponse.json()

    if (!productsResponse.ok || !productsPayload.products?.length) {
      throw new Error("No store-visible products are available")
    }

    checks.products = "ok"

    return res.json({
      ok: true,
      checks,
      region_id: regionId,
      product_id: productsPayload.products[0].id,
    })
  } catch (error) {
    return res.status(503).json({
      ok: false,
      checks,
      error:
        error instanceof Error ? error.message : "Store readiness check failed",
    })
  }
}
