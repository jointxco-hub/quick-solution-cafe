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
//
// QS-21.1: resolveProductPriceCue() below is the one exception that
// actually calls into pricing.js - it does not reimplement pricing, it
// just centralizes the exact same calculateProductPrice()/
// getDefaultConfig() call ProductHub's hero already made inline, so a
// second caller (the sticky Configure affordance) never has to
// duplicate it.
import { calculateProductPrice, getDefaultConfig } from './pricing.js'
import { WHATSAPP_NUMBER } from './businessInfo.js'

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
  flags: '/qs21/flags-hero-single.webp',
  // QS-21.1: flags/gazebos now both set product.media.hero directly
  // (src/data/products.js) with real photography, which resolveProductMedia()
  // reads BEFORE this map - these two legacy entries are dead in normal
  // operation and kept only as a last-resort safety net if media.hero
  // were ever cleared.
  gazebos: '/qs21/gazebo-hero-kit.webp',
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
  const liveGallery = Array.isArray(product?.media?.gallery)
    ? product.media.gallery.filter((src) => typeof src === 'string' && src.length > 0)
    : []
  const gallery = liveGallery.length > 0 ? liveGallery : (LEGACY_GALLERY_FALLBACK[product?.id] || [])
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
// QS-17: a generic upper bound on how many options the FALLBACK
// heuristic (below) will show as a "preview" pill row. vinyl-stickers/
// pvc-banner/business-cards-style fields comfortably have 2-4 options;
// flags/gazebos' single "variant" field has 36/16 options (every style×
// size×sides×kit combination) - showing all of them as pills would be
// exactly the "wall of specs" the config preview section exists to
// avoid. A product with a huge option field should either get curated
// via productPage.configPreview (see flags/gazebos, which explicitly
// pick 'artwork' instead) or simply not show a fallback preview for
// that field - never silently dump 36 pills onto the page.
const PREVIEW_FALLBACK_MAX_OPTIONS = 6

// "Configuration preview" — explains the important choices before the
// customer enters the full configurator. Prefers an explicit, curated
// productPage.configPreview (array of field ids) when present; falls
// back to a generic heuristic (multi-option select/segmented fields,
// capped at PREVIEW_FALLBACK_MAX_OPTIONS) so any product — including
// ones with no curated content yet — gets a reasonable preview. Strips
// fee/multiplier from every option: this section explains choices, it
// is not a second pricing calculator, and must never surface
// pricing_definition-adjacent data even the customer-safe fee/multiplier
// already on fields[].options[].
export function resolveConfigPreviewFields(product) {
  const fields = Array.isArray(product?.fields) ? product.fields : []
  const page = product?.productPage || {}
  const curatedIds = Array.isArray(page.configPreview) ? page.configPreview : null

  const source = curatedIds
    ? curatedIds.map((id) => fields.find((field) => field?.id === id)).filter(Boolean)
    : fields.filter((field) => PREVIEW_FIELD_TYPES.has(field?.type)
        && Array.isArray(field.options)
        && field.options.length > 1
        && field.options.length <= PREVIEW_FALLBACK_MAX_OPTIONS)

  // QS-21.4: shortLabel is preferred over the full field label here -
  // label is the full conversational question asked inside the real
  // configurator ("What is happening with the design?"), shortLabel is
  // the same compact word GuidedOrder's own review step already prefers
  // for the exact same "this needs to fit on one line" reason (see
  // ReviewRows in GuidedOrder.jsx: `field.shortLabel || field.label`).
  // This preview was the one place still reading it the other way
  // around - options now get the same treatment, via a NEW
  // option.shortLabel field (additive only - option.label/fee/id, which
  // pricing.js and the real dropdown both still read, are untouched).
  return source.map((field) => ({
    id: field.id,
    label: field.shortLabel || field.label || field.id,
    options: (field.options || []).map((option) => ({
      id: option.id,
      label: option.shortLabel || option.label || option.id,
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

// QS-21.1: the SAME "From R..." / "Get a quote" cue ProductHub's hero
// already computed inline, lifted here so the new sticky/floating
// Configure affordance (App.jsx) can show the identical price without a
// second pricing computation living outside pricing.js. Still only ever
// calls calculateProductPrice()/getDefaultConfig() - never re-derives or
// caches a number itself. Returns null when resolveStartingPriceEligibility
// says there is nothing to show (mode: 'none') or the calculation throws.
export function resolveProductPriceCue(product) {
  const eligibility = resolveStartingPriceEligibility(product)
  if (eligibility.mode === 'quote') return { quoteRequired: true }
  if (eligibility.mode === 'amount') {
    try {
      const result = calculateProductPrice(product, getDefaultConfig(product, {}))
      return { quoteRequired: false, total: result.total }
    } catch {
      return null
    }
  }
  return null
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

// ── QS-17: Product Presets ───────────────────────────────────────────
// A preset is a saved, valid CONFIGURATION of an existing product - not
// a new product, not a new price, not a separate checkout item type.
// Conceptually: Product -> ProductPreset -> (future QS-18) Offer/Bundle.
// Every helper below only ever reads/returns customer-safe label/content
// and configuration VALUES the product's own fields/pricing already
// accept - never referencePrice/supplierCost/marginRate/sourceUrl/
// supplier ids (those stay staff-only in pricing_definition, same rule
// as everywhere else in this file). The actual price for a preset, when
// shown, MUST still come from calculateProductPrice()/pricing.js at
// render time - nothing here computes or stores one.
//
// ── Correction: a preset must not assume artwork is ready ────────────
// A Quick Preset configures the PHYSICAL PRODUCT (variant/quantity/
// relevant options) - it must not silently assert the customer already
// has print-ready artwork. Investigated before changing anything:
// simply OMITTING `artwork` from a preset's config does NOT achieve
// this - getDefaultConfig() (pricing.js) does
// `{...fieldDefaults, ...preset}`, and the artwork field itself has
// `default: 'ready'`, so an absent key still resolves to 'ready' via
// the field's own default (this applies to every entry into the
// configurator, not just presets - the field default was never
// preset-specific to begin with). The fix that actually works: an
// EXPLICIT `artwork: null` in the preset's config, which DOES override
// the field default (the key is present, so the spread copies null over
// it) and is JSON-safe (unlike `undefined`, which cannot round-trip
// through jsonb). Verified against FieldControl.jsx: in Guided mode the
// artwork field renders as ChoiceButtons (`value === item.id`), so
// `null` correctly shows no option pre-selected - the flow genuinely
// asks the question. In Advanced mode specifically, the plain
// `<select value={value}>` has one disclosed, purely cosmetic quirk:
// with no option matching `null`, the browser's native behavior visibly
// highlights the first option ("My artwork is ready") even though
// nothing has actually been chosen yet - functionally harmless (price
// is identical either way: a null/unset artwork contributes fee 0,
// exactly like an explicit 'ready' does, and the field is not
// `required`, so nothing blocks submission) and resolved the moment the
// customer touches the dropdown. This is the smallest safe adjustment
// available - no second state system, no change to the field
// definition or getDefaultConfig() itself, and it works because null
// (present key, explicit value) and an absent key are genuinely
// different things to a spread - only the former overrides a field
// default. validatePresetConfig() below accepts null on this basis, but
// ONLY for fields that are not `required` (see its "leavesOptionalChoiceOpen"
// check) - a preset can leave an optional choice open, never a required one.

// ── Advanced-mode <select> boundary: null <-> '' ─────────────────────
// Follow-up to the correction above: a plain `<select value={null}>`
// has no way to represent "nothing chosen" (the DOM only knows ''),
// so without an explicit placeholder the browser silently highlights
// the first real option - visually implying it was chosen when it
// wasn't (the "disclosed, purely cosmetic quirk" noted above). Fixed
// in FieldControl.jsx by giving the control its own non-submittable
// placeholder option (value '', disabled) whenever the field's actual
// value is null/undefined. The null <-> '' translation is extracted
// here, as two tiny pure functions, so FieldControl.jsx can use the
// exact same logic the tests below exercise - this repo's test suite
// is plain Node `--test` over pure .mjs modules (see package.json), with
// no jsdom/React-rendering harness, so a real <select>'s rendered DOM
// state isn't something these tests can observe directly. Pulling the
// boundary mapping out into pure functions is the smallest way to get
// genuine regression coverage of the actual logic FieldControl.jsx
// runs (not a parallel reimplementation of it) without adding a
// rendering dependency (jsdom/@testing-library/react) for one control.
// The rendered-DOM behavior itself (placeholder text visible, greyed
// out, not re-selectable, disappears once a real option is chosen) is
// covered by manual smoke test only - see the QS-17 report.
//
// The actual product CONFIG value is never '' - only null (unanswered)
// or a real option id. '' exists solely as the DOM's stand-in for null,
// translated back to null the instant it leaves the control.
export function resolveSelectControlState(value) {
  const isUnanswered = value === null || value === undefined
  return { selectValue: isUnanswered ? '' : value, isUnanswered }
}

export function resolveSelectControlChange(rawDomValue) {
  return rawDomValue === '' ? null : rawDomValue
}

// ── QS-17D: deriving Guided axis selections from config.variant ──────
// Root cause of the bug this fixes: for SUPPLIER_MARGIN products (Flags,
// Gazebos), GuidedOrder.jsx renders SupplierVariantConfigurator.jsx,
// whose axis <select>s read their displayed value from dedicated
// `config.variantAxis_<axisId>` keys (e.g. `variantAxis_style`) - NOT
// from `config.variant` itself. Those keys only ever get written by the
// user interacting with the axis dropdowns (SupplierVariantConfigurator's
// own chooseAxis()); nothing ever backfills them from an incoming
// `config.variant`. A preset's config only ever sets {variant, quantity,
// artwork} (see the Product Presets section above - a preset composes a
// real variant id, it does not know or store per-axis breakdowns), so
// getDefaultConfig(product, preset) produces a config where `variant` is
// correctly the preset's chosen id, but every `variantAxis_*` key is
// simply absent. calculateProductPrice()/priceSupplierMargin() (pricing.js)
// reads `config.variant` directly and prices correctly - that is why the
// price and summary were already right - but SupplierVariantConfigurator
// never looks at `config.variant` for its own display, so every axis
// <select> renders its empty "Choose ..." placeholder regardless.
//
// Fix: derive the axis breakdown FROM config.variant (the single
// pricing-authority field) and use that purely to HYDRATE the display
// keys at the moments state is (re)built - preset load, product/journey
// switch (see GuidedOrder.jsx's config initialization) - never as a
// second, independently-maintained state system. Once the customer
// touches an axis dropdown, SupplierVariantConfigurator's existing
// chooseAxis() already keeps variantAxis_* and variant in sync by
// recomposing the variant id on every change - this only had to cover
// the "config arrived with a variant but no axis keys yet" gap.
//
// Structurally safe by construction, not a naive hyphen split: some
// axis option ids themselves contain hyphens (gazebo size options
// "3x3-standard", "3x3-deluxe", "3x4.5-deluxe", "3x6-deluxe"), so
// `variantId.split('-')` cannot be trusted to align with axis
// boundaries. Instead this walks product.pricing.variantTemplate
// (e.g. "{frame}-{size}-{kit}") left to right, and at each `{axisId}`
// placeholder tries that axis's REAL, KNOWN option ids (longest first,
// to prefer "3x3-standard" over a hypothetical shorter clash) against
// the remaining string, backtracking if a locally-plausible match makes
// a later axis unresolvable. The result is only ever returned if it
// recomposes back to the exact given variantId AND that id is a real,
// existing key in product.pricing.variants - a plausible-looking but
// nonexistent or malformed combination always yields null.
function matchVariantTemplate(template, variantId, axesById) {
  const tokenPattern = /\{([a-zA-Z0-9_]+)\}/g
  const tokens = []
  let lastIndex = 0
  let match
  while ((match = tokenPattern.exec(template))) {
    tokens.push({ axisId: match[1], literalBefore: template.slice(lastIndex, match.index) })
    lastIndex = tokenPattern.lastIndex
  }
  const trailingLiteral = template.slice(lastIndex)
  if (!tokens.length) return null

  function resolve(tokenIndex, remaining, acc) {
    if (tokenIndex === tokens.length) {
      return remaining === trailingLiteral ? acc : null
    }
    const { axisId, literalBefore } = tokens[tokenIndex]
    if (!remaining.startsWith(literalBefore)) return null
    const afterLiteral = remaining.slice(literalBefore.length)
    const axis = axesById.get(axisId)
    if (!axis || !Array.isArray(axis.options)) return null

    const candidateIds = axis.options
      .map((axisOption) => axisOption?.id)
      .filter((id) => typeof id === 'string' && id.length > 0)
      .sort((a, b) => b.length - a.length)

    for (const id of candidateIds) {
      if (!afterLiteral.startsWith(id)) continue
      const next = resolve(tokenIndex + 1, afterLiteral.slice(id.length), { ...acc, [axisId]: id })
      if (next) return next
    }
    return null
  }

  return resolve(0, variantId, {})
}

// Derives { [axisId]: optionId, ... } from a real variant id, using
// product.pricing.variantAxes/variantTemplate - or null if the product
// has no axis metadata, the variantId isn't a string, it doesn't
// structurally match the template, or it doesn't name a real entry in
// product.pricing.variants. Pure and read-only: never mutates config,
// never computes a price, never invents a variant.
export function deriveVariantAxisValues(product, variantId) {
  const axes = product?.pricing?.variantAxes
  const template = product?.pricing?.variantTemplate
  if (!Array.isArray(axes) || axes.length === 0 || !template) return null
  if (typeof variantId !== 'string' || !variantId) return null
  if (!product.pricing.variants || !product.pricing.variants[variantId]) return null

  const axesById = new Map(axes.filter((axis) => axis?.id).map((axis) => [axis.id, axis]))
  const result = matchVariantTemplate(template, variantId, axesById)
  if (!result) return null

  // Every axis the product declares must be present in the result - a
  // partial match is not safe to hydrate from.
  for (const axis of axes) {
    if (!(axis.id in result)) return null
  }

  return result
}

// Validates a preset's config against the product's REAL field/option/
// accessory catalog - semantic validity, not just shape. Mirrors the
// same client-side-validation-before-trusting-the-server convention
// pricing.js already uses (accessoryCompatible()/
// filterCompatibleAccessories()) - this does NOT replace server-side
// validation (commerce.qs_calculate_price re-validates independently
// and is the actual authority; an invalid variant/accessory id raises a
// hard exception there), it exists so a preset can never silently
// reference a field/option/variant/accessory that does not really exist
// on this product. Deliberately a flat, single-pass check over exactly
// what this catalogue's shape needs - not a general JSON-schema engine.
export function validatePresetConfig(product, preset) {
  const config = preset?.config
  if (!product || !config || typeof config !== 'object' || Array.isArray(config)) {
    return { valid: false, errors: ['Preset has no usable config'] }
  }

  const errors = []
  const fields = Array.isArray(product.fields) ? product.fields : []
  const fieldsById = new Map(fields.filter((field) => field?.id).map((field) => [field.id, field]))

  for (const key of Object.keys(config)) {
    // accessories is a dedicated SUPPLIER_MARGIN concept (product.pricing.accessories),
    // not a fields[] entry on any product - validated separately below.
    if (key === 'accessories') continue

    const field = fieldsById.get(key)
    if (!field) {
      errors.push(`"${key}" is not a real field on this product`)
      continue
    }

    const value = config[key]
    if (Array.isArray(field.options) && field.options.length > 0) {
      // Correction: explicit null on a NON-required select/segmented
      // field is a valid, intentional "let the customer choose" signal -
      // see the artwork-preset correction below. Only null is accepted
      // this way (not any arbitrary invalid string) and only when the
      // field itself isn't required - a preset can leave an optional
      // choice open, it can never leave a REQUIRED one unanswered.
      const leavesOptionalChoiceOpen = value === null && field.required !== true
      if (!leavesOptionalChoiceOpen) {
        const validOptionIds = new Set(field.options.map((option) => option?.id))
        if (!validOptionIds.has(value)) errors.push(`"${value}" is not a valid option for "${key}"`)
      }
    } else if (field.type === 'number') {
      const numeric = Number(value)
      if (!Number.isFinite(numeric)) {
        errors.push(`"${key}" must be a number`)
      } else {
        if (field.min != null && numeric < field.min) errors.push(`"${key}" is below the minimum of ${field.min}`)
        if (field.max != null && numeric > field.max) errors.push(`"${key}" is above the maximum of ${field.max}`)
      }
    }
  }

  if (config.accessories !== undefined) {
    if (!Array.isArray(config.accessories)) {
      errors.push('"accessories" must be an array when present')
    } else {
      const accessories = product.pricing?.accessories || {}
      for (const id of config.accessories) {
        const accessory = accessories[id]
        if (!accessory) {
          errors.push(`"${id}" is not a real accessory on this product`)
          continue
        }
        const compatibleVariants = accessory.compatibleVariants
        if (Array.isArray(compatibleVariants) && compatibleVariants.length > 0
          && config.variant && !compatibleVariants.includes(config.variant)) {
          errors.push(`"${id}" is not compatible with "${config.variant}"`)
        }
      }
    }
  }

  return { valid: errors.length === 0, errors }
}

// Returns only the customer-facing preset entries that are BOTH
// structurally safe (right shape; only id/name/description/config are
// ever read off a preset entry - anything else on a malformed entry,
// e.g. an accidentally-included referencePrice, is never copied out)
// AND semantically valid against this product's real field/option/
// accessory catalog (via validatePresetConfig() above). A malformed OR
// semantically-invalid preset - wrong shape, or one that references a
// field/variant/accessory id that does not exist on THIS product - is
// silently dropped here rather than ever reaching the UI as a broken
// card or a "Choose this" that quietly fails downstream.
export function resolveProductPresets(product) {
  const presets = Array.isArray(product?.productPage?.presets) ? product.productPage.presets : []
  return presets
    .filter((preset) => preset
      && typeof preset.id === 'string' && preset.id.length > 0
      && typeof preset.name === 'string' && preset.name.length > 0
      && preset.config && typeof preset.config === 'object' && !Array.isArray(preset.config))
    .map((preset) => ({
      id: preset.id,
      name: preset.name,
      // QS-21.4: shortName/shortDescription are optional, additive
      // fields for the "quick option" card specifically (see
      // ProductHub.jsx) - a curated, short form so that card can show
      // ONE support line instead of stacking name + full variant spec +
      // a full sentence description. Falls back to the existing
      // name/description for any preset that has not been given a short
      // form yet, so nothing regresses to blank.
      shortName: typeof preset.shortName === 'string' && preset.shortName ? preset.shortName : preset.name,
      description: typeof preset.description === 'string' ? preset.description : '',
      shortDescription: typeof preset.shortDescription === 'string' && preset.shortDescription
        ? preset.shortDescription
        : (typeof preset.description === 'string' ? preset.description : ''),
      config: { ...preset.config }
    }))
    .filter((preset) => validatePresetConfig(product, preset).valid)
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
// WhatsApp number defaults to the real business number (QS-21.5,
// src/lib/businessInfo.js) - the one shared source every other WhatsApp
// link in the app now also imports, rather than each file hardcoding
// its own copy (which is exactly how this number drifted before).
export function buildShareLinks(product, { origin = '', whatsappNumber = WHATSAPP_NUMBER } = {}) {
  if (!product) return { productPageUrl: '', configureUrl: '', whatsappUrl: '' }
  const base = origin.replace(/\/$/, '')
  const message = `Hi Quick Solution, I'm interested in ${product.name}.`
  return {
    productPageUrl: `${base}/products/${product.id}`,
    configureUrl: `${base}/configure/${product.id}`,
    whatsappUrl: `https://wa.me/${whatsappNumber}?text=${encodeURIComponent(message)}`
  }
}

// ── QS-18: Simple / Pro language mode ─────────────────────────────────
// A presentation-only mode - it never changes product ids, config keys,
// variant ids or prices, only which STRING is shown for a piece of
// customer-facing copy that already carries both variants. The data
// shape is deliberately minimal and reuses whatever field name a piece
// of content already uses for its default text (`label` on fields/
// options/axes, `name` on products) plus a sibling `simple*` field
// holding the friendlier alternative - nothing is renamed, so a product/
// field/option that hasn't been given a simple variant yet keeps
// rendering exactly as it always has (falls back to its one existing
// string in both modes). "Pro" is always the fallback/default value -
// so any call site that is not explicitly wired to a mode still shows
// today's existing text unchanged, never something new or unreviewed.
//
// Only a small, deliberately incomplete set of high-friction terms carry
// a simple variant right now (see the QS-18 comments on the flags/
// gazebos variantAxes and the artwork fields in src/data/products.js) -
// this does not rewrite the whole catalogue, per the QS-18 brief's own
// "do not rewrite every product if unnecessary".
export function resolveDisplayLabel(value, mode) {
  if (value == null) return ''
  if (typeof value === 'string') return value
  const pro = value.label ?? value.name ?? ''
  if (mode !== 'simple') return pro
  return value.simpleLabel ?? value.simpleName ?? pro
}

// Thin, product-specific wrapper: a product's display name uses `name`/
// `simpleName` (matching the field name every other part of this app
// already uses for a product's name), not `label`/`simpleLabel` -
// resolveDisplayLabel already recognizes both shapes, this just avoids
// every call site having to remember which pair applies to a product.
export function resolveProductDisplayName(product, mode) {
  return resolveDisplayLabel({ label: product?.name, simpleLabel: product?.simpleName }, mode) || product?.name || ''
}

// Composes a short, mode-aware spec line for a real variant from the
// SAME product.pricing.variantAxes metadata deriveVariantAxisValues()
// (QS-17D) already reads - e.g. "Telescopic — 3.0m — Double-sided — Full
// kit" (Pro) vs "Telescopic — 3.0m — Printed on both sides — Complete
// kit" (Simple) for telescopic-3m-ds-full. Generic and read-only: never
// invents a variant, never stores anything, works for any current or
// future product that has variantAxes - not flags/gazebos-specific
// logic. Returns null wherever deriveVariantAxisValues would (no axis
// metadata, malformed/nonexistent variant), so a caller can safely fall
// back to the variant's own plain label.
export function composeVariantSummary(product, variantId, mode) {
  const axes = product?.pricing?.variantAxes
  const derived = deriveVariantAxisValues(product, variantId)
  if (!Array.isArray(axes) || !derived) return null

  const parts = axes.map((axis) => {
    const optionId = derived[axis.id]
    const option = Array.isArray(axis.options) ? axis.options.find((item) => item?.id === optionId) : null
    return option ? resolveDisplayLabel(option, mode) : optionId
  })
  return parts.filter(Boolean).join(' — ')
}

// ── QS-18: Shop category filter ───────────────────────────────────────
// A small, presentation-only grouping ON TOP OF each product's existing
// `category` (never a second catalogue/source of truth) - maps this
// catalogue's 7 existing detailed categories onto the 7 broader,
// customer-facing Shop filter buckets the QS-18 brief asks for. Every
// current product's category is covered; a product whose category is
// not in this map simply has no bucket (still shown under "All").
export const SHOP_CATEGORIES = ['All', 'Print & Documents', 'Business', 'Signs & Advertising', 'Apparel', 'Events', 'Photo & Video']

const CATEGORY_TO_SHOP_BUCKET = {
  'Quick Print': 'Print & Documents',
  'Labels & Packaging': 'Print & Documents',
  'Signs & Large Format': 'Signs & Advertising',
  'Business Essentials': 'Business',
  'Clothing & Merch': 'Apparel',
  'Flags & Events': 'Events',
  'Photo & Video': 'Photo & Video'
}

export function resolveShopCategory(product) {
  return CATEGORY_TO_SHOP_BUCKET[product?.category] || null
}

export function filterProductsByShopCategory(products, filter) {
  const list = Array.isArray(products) ? products : []
  if (!filter || filter === 'All') return list
  return list.filter((product) => resolveShopCategory(product) === filter)
}
export const LEGACY_GALLERY_FALLBACK = {
  flags: [
    '/qs21/flags-lineup-sizes.webp',
    '/qs21/flags-shark-fin-pair.webp',
    '/qs21/flags-hero-single-alt.webp'
  ]
}
