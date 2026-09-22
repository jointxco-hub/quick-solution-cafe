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

// QS-21.1 — Product Detail's "Related products" row now expands a local
// disclosure preview in place (thumbnail/description/View product/Quick
// configure) instead of navigating immediately on first click (see the
// brief's section 3: clicking straight to another Product Detail page
// felt abrupt). This is the ENTIRE decision behind that toggle - "only
// one expanded at a time" is enforced by construction (setting the
// state to the clicked id always replaces whatever was there), and
// clicking the currently-expanded item's row again collapses it. Pure
// and page/history-agnostic on purpose: ProductHub only ever calls
// setState with this result, never setPage/pushState/replaceState - see
// the brief's section 11 ("expanding/collapsing... no browser history
// change").
export function resolveRelatedDisclosureState(currentExpandedId, itemId) {
  return currentExpandedId === itemId ? null : itemId
}
