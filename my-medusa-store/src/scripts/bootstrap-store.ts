import { ExecArgs } from "@medusajs/framework/types"
import { ContainerRegistrationKeys, Modules } from "@medusajs/framework/utils"
import {
  createApiKeysWorkflow,
  linkSalesChannelsToApiKeyWorkflow,
} from "@medusajs/medusa/core-flows"
import { ApiKey } from "../../.medusa/types/query-entry-points"

import seedDemoData from "./seed"

export default async function bootstrapStore({ container }: ExecArgs) {
  const logger = container.resolve(ContainerRegistrationKeys.LOGGER)
  const query = container.resolve(ContainerRegistrationKeys.QUERY)
  const salesChannelModuleService = container.resolve(Modules.SALES_CHANNEL)
  const medusaInternalUrl =
    process.env.MEDUSA_INTERNAL_URL || "http://medusa:9000"

  const { data: publishableKeys } = await query.graph({
    entity: "api_key",
    fields: ["id", "token", "title"],
    filters: {
      type: "publishable",
    },
  })

  let publishableKey = (publishableKeys?.[0] || null) as ApiKey | null

  if (!publishableKey?.token) {
    logger.info(
      "Regions exist but no publishable API key was found. Repairing bootstrap state..."
    )

    const defaultSalesChannel =
      await salesChannelModuleService.listSalesChannels({
        name: "Default Sales Channel",
      })

    if (!defaultSalesChannel.length) {
      throw new Error(
        "Regions exist but the Default Sales Channel is missing. Refusing to repair automatically."
      )
    }

    const {
      result: [publishableApiKey],
    } = await createApiKeysWorkflow(container).run({
      input: {
        api_keys: [
          {
            title: "Webshop",
            type: "publishable",
            created_by: "",
          },
        ],
      },
    })

    await linkSalesChannelsToApiKeyWorkflow(container).run({
      input: {
        id: publishableApiKey.id,
        add: [defaultSalesChannel[0].id],
      },
    })

    logger.info("Repaired missing publishable API key.")
    publishableKey = publishableApiKey as ApiKey
  }

  const regionResponse = await fetch(`${medusaInternalUrl}/store/regions`, {
    headers: {
      "x-publishable-api-key": publishableKey.token,
    },
  })

  if (!regionResponse.ok) {
    throw new Error(
      `Failed to validate store regions via Medusa API: ${regionResponse.status}`
    )
  }

  const payload = await regionResponse.json()
  const regions = payload.regions ?? []

  if (!regions.length) {
    logger.info("No store-visible regions found. Running seed script...")
    await seedDemoData({ container })
    return
  }

  logger.info("Existing store bootstrap data found. Skipping seed.")
}
