import { Metadata } from "next"

import { SortOptions } from "@modules/store/components/refinement-list/sort-products"
import StoreTemplate from "@modules/store/templates"

export const metadata: Metadata = {
  title: "PisoFire",
  description: "Explore all of our products.",
}

export default async function Home(props: {
  params: Promise<{ countryCode: string }>
  searchParams: Promise<{ sortBy?: SortOptions; page?: string }>
}) {
  const { countryCode } = await props.params
  const { sortBy, page } = await props.searchParams

  return <StoreTemplate sortBy={sortBy} page={page} countryCode={countryCode} />
}
