let cachedPublishableKey: string | null = null

export async function getPublishableKey(baseUrl: string): Promise<string> {
  if (cachedPublishableKey) {
    return cachedPublishableKey
  }

  const response = await fetch(`${baseUrl}/publishable-key`, {
    method: "GET",
    cache: "force-cache",
    next: {
      revalidate: 3600,
    },
  })

  const payload = await response.json()

  if (!response.ok || !payload.publishable_api_key) {
    throw new Error(
      payload.message || "Failed to retrieve the Medusa publishable API key."
    )
  }

  cachedPublishableKey = payload.publishable_api_key

  return cachedPublishableKey
}
