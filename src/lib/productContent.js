// QS-16 — pure, Supabase-free content-normalization helpers for the
// generic Product Hub (src/components/ProductHub.jsx).
//
// Every function here reads ONLY customer-facing fields already present
// on a product object — the same shape whether it came from the local
// src/data/products.js fallback or the live commerce.service_product_configs
// customer_definition (returned by the get_quick_solution_catalog RPC).
//
// None of these ever read or reconstruct pricing_definition-shaped data
// (referencePrice, marginRate, sourceName, sourceUrl, vatBasis) — that is
// staff-only and is never sent to the client at all (confirmed: the
// public RPC only returns customer_definition). For an actual price,
// call calculateProductPrice()/getDefaultConfig() from ./pricing.js
// directly — pricing.js remains the single frontend pricing authority
// and nothing here duplicates or reimplements it.

// The pre-QS-16 hardcoded image map, moved here from ProductCard.jsx
// (was a local const in that file) so ProductCard.jsx and ProductHub.jsx
// share ONE copy instead of maintaining two — this is the "existing
// legacy map fallback" step in resolveProductMedia()'s lookup order
// below, kept only as a last resort for products that have neither
// product.media.hero nor product.image set yet.
export const LEGACY_IMAGE_FALLBACK = {
  'pvc-banner': '/qs11/product-pvc-banner-clean.webp',
  'vinyl-stickers': '/qs11/product-vinyl-labels-clean.webp',
  'a4-print': '/qs11/product-document-printing-clean.webp',
  'business-cards': '/qs11/product-business-cards-clean.webp',
  'printed-tshirt': '/qs11/product-tshirt-clean.webp',
  'media-services': '/qs12/product-photography-video.webp',
  // Flags has no dedicated product photography yet — falls back to the
  // existing generic ProductScene illustration rather than reusing an
  // unrelated image.
  gazebos: '/qs11/event-gazebo.webp',
  'photo-session': '/qs12/product-photography-video.webp'
}

// Lookup order for a product's hero image:
//   product.media?.hero  -> new, optional, backward-compatible field
//   product.image        -> already present on the live Supabase
//                            customer_definition row (e.g. vinyl-stickers),
//                            though not on the local products.js fallback
//   legacyImageMap[id]    -> ProductCard.jsx's existing hardcoded map,
//                            kept only as a last-resort fallback so no
//                            existing product silently loses its image
//   null                  -> caller renders ProductScene instead
export function resolveProductMedia(product, legacyImageMap = LEGACY_IMAGE_FALLBACK) {
  const hero = product?.media?.hero || product?.image || legacyImageMap[product?.id] || null
  const gallery = Array.isArray(product?.media?.gallery)
    ? product.media.gallery.filter((src) => typeof src === 'string' && src.length > 0)
    : []
  return { hero, gallery }
}

// Normalizes the optional product.productPage block, with safe fallbacks
// to existing fields so the hub never looks broken for a product that
// has not been given curated hub content yet (every field here already
// has a home on the product object today).
export function resolveProductPageContent(product) {
  const page = product?.productPage || {}
  return {
    headline: page.headline || product?.name || '',
    intro: page.intro || product?.plainDescription || product?.description || '',
    useCases: Array.isArray(page.useCases)
      ? page.useCases.filter((item) => item && typeof item.label === 'string' && item.label.length > 0)
      : [],
    highlights: Array.isArray(page.highlights)
      ? page.highlights.filter((item) => item && typeof item.label === 'string' && item.label.length > 0)
      : []
  }
}

const PREVIEW_FIELD_TYPES = new Set(['select', 'segmented'])

// "Configuration preview" — explains the important choices before the
// customer enters the full configurator. Prefers an explicit, curated
// productPage.configPreview (array of field ids) when present; falls
// back to a generic heuristic (multi-option select/segmented fields)
// so any product — including ones with no curated content yet — gets a
// reasonable preview. Strips fee/multiplier from every option: this
// section explains choices, it is not a second pricing calculator, and
// must never surface pricing_definition-adjacent data even the
// customer-safe fee/multiplier already on fields[].options[].
export function resolveConfigPreviewFields(product) {
  const fields = Array.isArray(product?.fields) ? product.fields : []
  const page = product?.productPage || {}
  const curatedIds = Array.isArray(page.configPreview) ? page.configPreview : null

  const source = curatedIds
    ? curatedIds.map((id) => fields.find((field) => field?.id === id)).filter(Boolean)
    : fields.filter((field) => PREVIEW_FIELD_TYPES.has(field?.type) && Array.isArray(field.options) && field.options.length > 1)

  return source.map((field) => ({
    id: field.id,
    label: field.label || field.shortLabel || field.id,
    options: (field.options || []).map((option) => ({
      id: option.id,
      label: option.label || option.id,
      helper: option.helper || ''
    }))
  }))
}

// Artwork guidance for the "what file should I send" section — reused
// directly from the existing file-type field's own help text (set on
// the vinyl-stickers 'file' field: "PDF, PNG or high-resolution JPG
// works best"). Never invents accepted formats/specs beyond what the
// catalogue already states.
export function resolveArtworkGuidance(product) {
  const fileField = (Array.isArray(product?.fields) ? product.fields : []).find((field) => field?.type === 'file')
  return {
    label: fileField?.label || 'Artwork file',
    help: fileField?.help || ''
  }
}

// Related products: same category, excluding the product itself. Lean,
// display-only shape — no pricing fields at all (a related-product card
// resolves its own image via resolveProductMedia() and its own price
// via pricing.js at render time, not baked into this pure function).
export function deriveRelatedProducts(product, catalog = [], limit = 3) {
  if (!product) return []
  return (Array.isArray(catalog) ? catalog : [])
    .filter((item) => item && item.id !== product.id && item.category === product.category)
    .slice(0, Math.max(0, limit))
    .map((item) => ({ id: item.id, name: item.name, shortName: item.shortName || item.name, category: item.category }))
}

// Correction: whether ProductHub should show a monetary "From R..."
// starting-price cue at all. Deliberately does NOT compute or return a
// price itself — this only answers "is showing one appropriate for this
// product", it never invents a number (calculateProductPrice()/
// pricing.js remains the only source of an actual amount).
//
// A product's DEFAULT configuration (getDefaultConfig(product, {})) is
// not necessarily its cheapest valid one — showing "From <default
// price>" for every product that merely has a pricing object risks
// understating or overstating the real starting price. So this requires
// an EXPLICIT curator opt-in (productPage.showStartingPrice === true) -
// only set once someone has actually confirmed the default configuration
// IS the genuine starting price - rather than defaulting to "on" for any
// product with a pricing strategy.
//
// ENQUIRY-strategy products are always eligible for a "Get a quote" cue
// regardless of this flag: that's a call to action, not a price claim,
// so there's nothing to mis-state.
export function resolveStartingPriceEligibility(product) {
  if (!product) return { mode: 'none' }
  if (product.pricing?.strategy === 'ENQUIRY') return { mode: 'quote' }
  if (product.productPage?.showStartingPrice === true) return { mode: 'amount' }
  return { mode: 'none' }
}

// Correction: whether the Hub's Guided/Advanced CTAs should render as
// active. Product metadata (channels.guided / guidedJourneyId) is
// necessary but not sufficient — App.jsx can and does pass
// onGuided=null when no matching local guided journey actually exists
// for a product (see selectedJourney in App.jsx), and a button that
// looks live but has no handler behind it is a dead end, not a CTA.
// Both the hero actions and the mobile sticky CTA read from this same
// function so they can never disagree with each other.
export function resolveHubAvailability(product, { onGuided, onConfigure } = {}) {
  if (!product) return { hasGuided: false, hasAdvanced: false }
  return {
    hasGuided: typeof onGuided === 'function'
      && product?.channels?.guided !== false
      && Boolean(product?.guidedJourneyId),
    hasAdvanced: typeof onConfigure === 'function'
      && product?.channels?.advanced !== false
  }
}

// Share Kit link placeholders. Deliberately simple: this app has no
// client-side router (confirmed — react-router-dom is not a dependency),
// so productPageUrl/configureUrl are not yet real navigable routes; they
// are copy-paste-ready placeholders that leave room for real routing
// later without forcing that architecture decision now — kept here so
// the URL-building shape exists for tests/future use even though
// ProductHub itself no longer exposes them as working copy actions (see
// the correction in ProductHub.jsx: those two Share Kit buttons are now
// disabled/"coming soon" rather than copying a non-navigable URL). The
// WhatsApp number/format matches the one already used everywhere else in
// this app (App.jsx, GuidedOrder.jsx, ProductConfigurator.jsx,
// TrackOrder.jsx, PaymentReturn.jsx, ComingSoonRail.jsx) rather than
// inventing a new one, and stays fully functional.
export function buildShareLinks(product, { origin = '', whatsappNumber = '27754534646' } = {}) {
  if (!product) return { productPageUrl: '', configureUrl: '', whatsappUrl: '' }
  const base = origin.replace(/\/$/, '')
  const message = `Hi Quick Solution, I'm interested in ${product.name}.`
  return {
    productPageUrl: `${base}/products/${product.id}`,
    configureUrl: `${base}/configure/${product.id}`,
    whatsappUrl: `https://wa.me/${whatsappNumber}?text=${encodeURIComponent(message)}`
  }
}
