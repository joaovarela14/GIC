import { NextResponse } from "next/server"

const DEFAULT_TIMEOUT_MS = 2000

const readinessTimeoutMs = () => {
  const configured = Number(process.env.READINESS_TIMEOUT_MS)
  return Number.isFinite(configured) && configured > 0
    ? configured
    : DEFAULT_TIMEOUT_MS
}

export async function GET() {
  const backendUrl = process.env.MEDUSA_BACKEND_URL

  if (!backendUrl) {
    return NextResponse.json(
      {
        ok: false,
        error: "MEDUSA_BACKEND_URL is not configured",
      },
      { status: 503 }
    )
  }

  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), readinessTimeoutMs())

  try {
    const response = await fetch(`${backendUrl}/readyz`, {
      cache: "no-store",
      signal: controller.signal,
    })

    if (!response.ok) {
      return NextResponse.json(
        {
          ok: false,
          checks: {
            backend: "unready",
          },
          backend_status: response.status,
        },
        { status: 503 }
      )
    }

    return NextResponse.json({
      ok: true,
      checks: {
        backend: "ok",
      },
    })
  } catch (error) {
    return NextResponse.json(
      {
        ok: false,
        checks: {
          backend: "unreachable",
        },
        error:
          error instanceof Error ? error.message : "Backend readiness failed",
      },
      { status: 503 }
    )
  } finally {
    clearTimeout(timeout)
  }
}
