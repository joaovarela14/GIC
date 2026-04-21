import { MedusaRequest, MedusaResponse } from "@medusajs/framework/http"
import { ContainerRegistrationKeys } from "@medusajs/framework/utils"

type PublishableKeyRecord = {
  id: string
  token: string
  title?: string | null
}

export async function GET(req: MedusaRequest, res: MedusaResponse) {
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
    return res.status(404).json({
      message: "No publishable API key is configured.",
    })
  }

  return res.json({
    publishable_api_key: publishableKey.token,
  })
}
