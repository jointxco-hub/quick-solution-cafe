// QS-21 — "relevant Offers" for Product Detail (see the brief's section
// 11: "no recommendation engine required, a small deterministic mapping
// is acceptable"). An Offer is related to a product exactly when that
// product is one of the Offer's own real items - the same relationship
// calculateOfferPrice()/resolveOfferItem() (src/lib/offers.js) already
// resolve, just read in the other direction (given a product, which
// active Offers include it). Reuses existing Offer data - never a
// second mapping table, never a new schema.
export function deriveRelatedOffers(product, offers, limit = 3) {
  if (!product?.id) return []
  return (Array.isArray(offers) ? offers : [])
    .filter((offer) => Array.isArray(offer?.items) && offer.items.some((item) => item?.productId === product.id))
    .slice(0, Math.max(0, limit))
}
