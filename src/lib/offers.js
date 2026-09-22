// QS-20 — Offer / Combo layer.
//
// Canonical hierarchy: Product -> ProductPreset -> Offer -> Quote/Order.
// An Offer is a curated LIST OF REFERENCES to real products (and,
// preferably, real presets) - never a second product, never a stored
// selling price, never a second pricing engine. Every line's price
// comes from calculateProductPrice()/pricing.js, exactly the same
// function ProductHub/GuidedOrder/ProductConfigurator already call -
// this module only RESOLVES which product/config a line means and
// AGGREGATES the per-line results. Nothing here computes a price
// itself.
//
// Offer item quantity vs. a preset/config's OWN internal quantity are
// deliberately kept separate concepts:
//   - config.quantity (or .copies, or a TIERED "quantity" option id) is
//     whatever the PRODUCT's own pricing strategy already means by it -
//     e.g. a flags preset's quantity:2 already encodes "sold in pairs".
//   - offer item.quantity is a REPEAT COUNT for that exact resolved
//     line - "how many separate order lines of this exact
//     product+config". It is never merged into config, because the
//     cart/order payload (createQuickSolutionCartOrder) has no
//     per-line quantity field at all - each cart entry is already one
//     full product+configuration pair, and the server independently
//     recalculates each one. Repeating the line N times is the only
//     representation that stays truthfully verifiable by the server -
//     see resolveOfferCartLines() below.
import { calculateProductPrice, getDefaultConfig, formatMoney } from './pricing.js'
import { resolveProductPresets, resolveDisplayLabel } from './productContent.js'

// Resolves one offer item to a real {product, config[, preset]} - or
// {error} if the item references anything that does not really exist.
// Preset lookup reuses resolveProductPresets()/validatePresetConfig()
// (productContent.js) exactly as ProductHub's "Quick options" already
// does - a presetId is only ever accepted if it resolves to a
// structurally-safe AND semantically-valid preset on THAT product, the
// same guarantee QS-17 already established.
export function resolveOfferItem(item, products) {
  if (!item || typeof item !== 'object' || Array.isArray(item)) {
    return { error: 'Offer item is not an object' }
  }
  if (typeof item.productId !== 'string' || !item.productId) {
    return { error: 'Offer item has no productId' }
  }

  const product = (Array.isArray(products) ? products : []).find((candidate) => candidate?.id === item.productId)
  if (!product) {
    return { error: `Unknown product "${item.productId}"` }
  }
  // QS-20 final review: a product that exists in the catalogue but is
  // not currently active/orderable (product.active === false) must
  // fail the same way a genuinely unknown product does - an Offer must
  // never resolve a line against a product that isn't actually
  // available to order. This is a fail-safe, not an auto-omit: even an
  // item marked optional:true is NOT silently dropped here if its
  // product becomes unavailable - resolveOfferItem has no opinion on
  // optionality (that's a presentation/customisation concern - see
  // resolveOfferCartLines), it only ever reports "resolvable" or
  // "not resolvable". calculateOfferPrice/validateOffer then correctly
  // mark the WHOLE offer invalid rather than silently continuing with
  // a partial, misleading composition.
  if (product.active === false) {
    return { error: `Product "${item.productId}" is not currently available` }
  }

  if (item.presetId != null) {
    const preset = resolveProductPresets(product).find((candidate) => candidate.id === item.presetId)
    if (!preset) {
      return { error: `Unknown or invalid preset "${item.presetId}" on "${item.productId}"` }
    }
    return { product, config: preset.config, preset }
  }

  if (item.config != null) {
    if (typeof item.config !== 'object' || Array.isArray(item.config)) {
      return { error: `Offer item config for "${item.productId}" is not an object` }
    }
    return { product, config: { ...item.config } }
  }

  // Neither presetId nor config given - the product's own field
  // defaults are the only safe fallback (same defaults Advanced mode
  // starts from for this product), never an invented configuration.
  return { product, config: getDefaultConfig(product, {}) }
}

// The aggregator. Resolves every item, prices each ONCE through the
// real pricing engine, multiplies by that item's repeat quantity, and
// sums. quoteRequired propagates: if any line can't produce a firm
// total (quoteRequired OR an invalid quantity/accessory combination),
// the whole offer total becomes unavailable rather than silently
// under-totaling. A structurally broken item (unknown product/preset/
// malformed config) marks the offer invalid the same way - an Offer
// that references something that doesn't exist is never priced as if
// that line were free.
export function calculateOfferPrice(offer, products) {
  const items = Array.isArray(offer?.items) ? offer.items : []
  const lines = []
  let total = 0
  let quoteRequired = false
  let valid = items.length > 0

  for (const item of items) {
    const resolved = resolveOfferItem(item, products)
    if (resolved.error) {
      valid = false
      lines.push({ id: item?.id ?? null, error: resolved.error, quoteRequired: false, lineTotal: null })
      continue
    }

    const quantity = Math.max(Number(item.quantity ?? 1), 1)
    const price = calculateProductPrice(resolved.product, resolved.config)
    // No internal/supplier field is ever read here - only total,
    // summary and metrics.quoteRequired/invalid, the exact same
    // customer-safe shape every other caller of calculateProductPrice
    // already relies on (see pricing.js's own comment on why
    // referencePrice/marginRate never reach the client at all).
    const lineQuoteRequired = Boolean(price.metrics?.quoteRequired) || Boolean(price.metrics?.invalid)
    if (lineQuoteRequired) quoteRequired = true
    const lineTotal = lineQuoteRequired ? null : price.total * quantity
    if (lineTotal != null) total += lineTotal

    lines.push({
      id: item.id ?? null,
      productId: resolved.product.id,
      productName: resolved.product.name,
      presetId: item.presetId ?? null,
      presetName: resolved.preset?.name ?? null,
      optional: Boolean(item.optional),
      quantity,
      unitTotal: price.total,
      lineTotal,
      summary: price.summary,
      quoteRequired: lineQuoteRequired,
      config: resolved.config
    })
  }

  const offerQuoteRequired = !valid || quoteRequired
  return {
    valid,
    quoteRequired: offerQuoteRequired,
    total: offerQuoteRequired ? null : total,
    lines
  }
}

// Structural + semantic validity check for an offer definition itself -
// mirrors validatePresetConfig()'s role for presets. Used to keep a
// malformed/stale offer (references a removed product, a typo'd preset
// id, etc.) from ever reaching the UI, the same "silently drop, never
// show a broken card" convention resolveProductPresets() already
// established.
export function validateOffer(offer, products) {
  if (!offer || typeof offer !== 'object' || Array.isArray(offer)) {
    return { valid: false, errors: ['Offer is not an object'] }
  }
  if (typeof offer.id !== 'string' || !offer.id) {
    return { valid: false, errors: ['Offer must have an id'] }
  }
  if (typeof offer.name !== 'string' || !offer.name) {
    return { valid: false, errors: ['Offer must have a name'] }
  }
  if (!Array.isArray(offer.items) || offer.items.length === 0) {
    return { valid: false, errors: ['Offer must have at least one item'] }
  }

  const result = calculateOfferPrice(offer, products)
  const errors = result.lines.filter((line) => line.error).map((line) => line.error)
  return { valid: errors.length === 0, errors }
}

// Returns only the offers that are both marked active and structurally/
// semantically valid against the REAL current catalogue - same
// filtering discipline as resolveProductPresets(). A products array
// with a removed/renamed product silently drops any offer that
// referenced it rather than ever rendering a broken card.
export function resolveActiveOffers(offers, products) {
  return (Array.isArray(offers) ? offers : [])
    .filter((offer) => offer?.active !== false)
    .filter((offer) => validateOffer(offer, products).valid)
}

export function resolveOffersForCategory(offers, category) {
  const list = Array.isArray(offers) ? offers : []
  if (!category || category === 'All') return list
  return list.filter((offer) => offer.category === category)
}

// QS-18 Simple/Pro, applied to Offers the same way as everywhere else -
// presentation only, never the underlying items/config/ids.
export function resolveOfferDisplayName(offer, mode) {
  return resolveDisplayLabel({ label: offer?.name, simpleLabel: offer?.simpleName }, mode) || offer?.name || ''
}

export function resolveOfferDisplayDescription(offer, mode) {
  return resolveDisplayLabel({ label: offer?.description, simpleLabel: offer?.simpleDescription }, mode) || offer?.description || ''
}

// Customisation, kept deterministic per the QS-20 brief (no drag/drop
// builder): a customer can drop any item explicitly marked
// `optional: true` and can change any item's repeat quantity - both
// expressed as a plain overrides object, never a parallel state system.
// Reuses calculateOfferPrice() by constructing the ADJUSTED items list
// and pricing THAT - there is still only one aggregator, customisation
// never computes its own total.
export function resolveOfferCartLines(offer, products, customization = {}) {
  const excluded = new Set(customization.excludedItemIds || [])
  const quantityOverrides = customization.quantityOverrides || {}
  const items = (Array.isArray(offer?.items) ? offer.items : [])
    .filter((item) => !(item.optional && item.id != null && excluded.has(item.id)))
    .map((item) => {
      const override = item.id != null ? quantityOverrides[item.id] : null
      const quantity = override != null ? Math.max(Number(override), 1) : (item.quantity ?? 1)
      return { ...item, quantity }
    })
  return calculateOfferPrice({ ...offer, items }, products)
}

// ── QS-20 final review: total-display wording ──────────────────────────
// The collapsed offer card previously always said "From R…", which
// claims a minimum/floor price - wrong for an offer with optional
// items, whose REAL minimum (every optional item removed) is genuinely
// lower than the default-composition total shown here (e.g. Event
// Starter: R12,090 with its optional PVC Banner included, R11,280
// without). Computing the true cheapest combination would mean
// searching every optional-item on/off permutation - explicitly out of
// scope ("do not add generic cheapest-offer-search logic"). So instead:
// show the CURRENT, fixed default composition's real total plainly (no
// "From"), and when the offer has any optional item, add a plain-
// language note that the total includes items the customer can remove -
// never implying R12,090 is a floor. Extracted as a pure function (not
// inline JSX) so this wording decision is unit-testable without a
// rendering harness - the same reasoning QS-17C's FieldControl.jsx
// select-boundary extraction already established for this repo.
export function resolveOfferPriceDisplay(offer, result) {
  if (result?.quoteRequired) {
    return { priceText: 'Quote required', note: null, quoteRequired: true }
  }
  const hasOptionalItems = (offer?.items || []).some((item) => item?.optional)
  return {
    priceText: formatMoney(result?.total),
    note: hasOptionalItems ? 'Includes optional items below — customise to remove them and lower the total.' : null,
    quoteRequired: false
  }
}
