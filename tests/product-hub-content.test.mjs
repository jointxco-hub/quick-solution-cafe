import assert from 'node:assert/strict'
import test from 'node:test'
import {
  resolveProductMedia,
  resolveProductPageContent,
  resolveConfigPreviewFields,
  resolveArtworkGuidance,
  deriveRelatedProducts,
  resolveStartingPriceEligibility,
  resolveHubAvailability,
  buildShareLinks,
  LEGACY_IMAGE_FALLBACK
} from '../src/lib/productContent.js'
import { WHATSAPP_NUMBER } from '../src/lib/businessInfo.js'

// Fixture mirrors the real vinyl-stickers product shape added in this
// same change (src/data/products.js) — customer-facing fields only,
// same as the real catalogue row. No referencePrice/marginRate/
// sourceName/sourceUrl anywhere, matching what the public catalogue RPC
// actually returns.
const vinylProduct = {
  id: 'vinyl-stickers',
  name: 'Vinyl Stickers & Labels',
  shortName: 'Stickers',
  category: 'Labels & Packaging',
  description: 'Custom vinyl stickers and labels for bottles, packaging, windows and product branding.',
  plainDescription: 'Choose the print area, artwork help and whether you need print only or print + cut.',
  channels: { storefront: true, guided: true, pos: true, quote: true },
  guidedJourneyId: 'sticker-guided',
  pricing: { strategy: 'PER_AREA', baseRate: 350, minimumBillableArea: 1, unit: 'm²' },
  fields: [
    { id: 'width', type: 'number', label: 'How wide is the total print area?', default: 1 },
    { id: 'height', type: 'number', label: 'How high is the total print area?', default: 1 },
    {
      id: 'material', type: 'select', label: 'Which vinyl should we use?', default: 'standard',
      options: [{ id: 'standard', label: 'White adhesive vinyl', helper: 'Everyday vinyl.', multiplier: 1 }]
    },
    {
      id: 'finishing', type: 'segmented', label: 'Do you need the stickers cut?', default: 'print-only',
      options: [
        { id: 'print-only', label: 'Print only', helper: 'Supplied as printed vinyl.', fee: 0 },
        { id: 'print-cut', label: 'Print + cut', helper: 'We cut it for you.', fee: 100 }
      ]
    },
    {
      id: 'artwork', type: 'select', label: 'What is happening with the design?', default: 'ready',
      options: [
        { id: 'ready', label: 'My artwork is ready', fee: 0 },
        { id: 'design', label: 'I need help with the design', fee: 250 }
      ]
    },
    { id: 'file', type: 'file', label: 'Artwork file', help: 'PDF, PNG or high-resolution JPG works best.' }
  ],
  media: {
    hero: '/qs11/product-vinyl-labels-clean.webp',
    gallery: ['/qs11/product-vinyl-labels-clean.webp', '/qs11/product-vinyl.webp', '', null]
  },
  productPage: {
    headline: 'Custom vinyl stickers and labels for bottles, packaging, windows and branding',
    intro: 'Choose the print area, artwork help and whether you need print only or print + cut.',
    useCases: [{ label: 'Bottles' }, { label: 'Packaging' }, {}, { label: '' }],
    highlights: [{ label: 'White self-adhesive vinyl' }, { label: 'Print only or print + cut' }],
    configPreview: ['finishing', 'artwork'],
    showStartingPrice: true
  }
}

// A generic, uncurated product: has a full, real-shaped pricing object
// (so it is NOT missing pricing data) but no productPage.showStartingPrice
// opt-in at all. Used to prove a product does not get a "From R..." cue
// merely because pricing.calculateProductPrice() would happily compute
// one for it.
const uncuratedProduct = {
  id: 'pvc-banner',
  name: 'PVC Banner',
  category: 'Signs & Large Format',
  pricing: { strategy: 'PER_AREA', baseRate: 350, minimumBillableArea: 1, unit: 'm²' },
  fields: [
    { id: 'width', type: 'number', default: 1 },
    { id: 'height', type: 'number', default: 1 }
  ]
}

// ── resolveProductMedia ───────────────────────────────────────────────

test('resolveProductMedia: prefers product.media.hero when present', () => {
  const media = resolveProductMedia(vinylProduct)
  assert.equal(media.hero, '/qs11/product-vinyl-labels-clean.webp')
})

test('resolveProductMedia: falls back to product.image when media.hero is absent', () => {
  const product = { id: 'x', image: '/qs11/fallback.webp' }
  assert.equal(resolveProductMedia(product).hero, '/qs11/fallback.webp')
})

test('resolveProductMedia: falls back to the legacy map when neither media.hero nor image is set', () => {
  const product = { id: 'vinyl-stickers' }
  assert.equal(resolveProductMedia(product).hero, LEGACY_IMAGE_FALLBACK['vinyl-stickers'])
})

test('resolveProductMedia: resolves to null (caller renders ProductScene) when nothing matches', () => {
  const product = { id: 'no-photo-yet-product' }
  assert.equal(resolveProductMedia(product).hero, null)
})

test('resolveProductMedia: gallery drops empty/null entries and defaults to an empty array', () => {
  const media = resolveProductMedia(vinylProduct)
  assert.deepEqual(media.gallery, ['/qs11/product-vinyl-labels-clean.webp', '/qs11/product-vinyl.webp'])
  assert.deepEqual(resolveProductMedia({ id: 'x' }).gallery, [])
})

// ── resolveProductPageContent ────────────────────────────────────────

test('resolveProductPageContent: uses the explicit productPage block when present', () => {
  const content = resolveProductPageContent(vinylProduct)
  assert.equal(content.headline, vinylProduct.productPage.headline)
  assert.equal(content.intro, vinylProduct.productPage.intro)
})

test('resolveProductPageContent: falls back to name/plainDescription/description when productPage is absent', () => {
  const content = resolveProductPageContent({ name: 'A4 Printing', plainDescription: 'Print your pages.', description: 'Long form.' })
  assert.equal(content.headline, 'A4 Printing')
  assert.equal(content.intro, 'Print your pages.')
})

test('resolveProductPageContent: falls back to description when plainDescription is also absent', () => {
  const content = resolveProductPageContent({ name: 'A4 Printing', description: 'Long form.' })
  assert.equal(content.intro, 'Long form.')
})

test('resolveProductPageContent: filters out useCases/highlights entries with no label, never crashes on a malformed entry', () => {
  const content = resolveProductPageContent(vinylProduct)
  assert.deepEqual(content.useCases, [{ label: 'Bottles' }, { label: 'Packaging' }])
})

test('resolveProductPageContent: a product with no productPage at all yields empty useCases/highlights, not an error', () => {
  const content = resolveProductPageContent({ name: 'X' })
  assert.deepEqual(content.useCases, [])
  assert.deepEqual(content.highlights, [])
})

// ── resolveConfigPreviewFields ───────────────────────────────────────

test('resolveConfigPreviewFields: uses the curated productPage.configPreview field ids, in order, when present', () => {
  const preview = resolveConfigPreviewFields(vinylProduct)
  assert.deepEqual(preview.map((field) => field.id), ['finishing', 'artwork'])
})

test('resolveConfigPreviewFields: falls back to select/segmented multi-option fields when no curated list exists', () => {
  const product = { ...vinylProduct, productPage: undefined }
  const preview = resolveConfigPreviewFields(product)
  // width/height (number) and file are excluded; material has only 1
  // option so it is excluded too; finishing/artwork qualify.
  assert.deepEqual(preview.map((field) => field.id).sort(), ['artwork', 'finishing'])
})

test('resolveConfigPreviewFields: never surfaces fee/multiplier - only id/label/helper survive on options', () => {
  const preview = resolveConfigPreviewFields(vinylProduct)
  const finishing = preview.find((field) => field.id === 'finishing')
  for (const option of finishing.options) {
    assert.deepEqual(Object.keys(option).sort(), ['helper', 'id', 'label'])
    assert.equal('fee' in option, false)
    assert.equal('multiplier' in option, false)
  }
})

test('resolveConfigPreviewFields: a product with no fields at all yields an empty array', () => {
  assert.deepEqual(resolveConfigPreviewFields({}), [])
})

// ── resolveArtworkGuidance ────────────────────────────────────────────

test('resolveArtworkGuidance: reuses the existing file field help text verbatim, invents nothing', () => {
  const guidance = resolveArtworkGuidance(vinylProduct)
  assert.equal(guidance.help, 'PDF, PNG or high-resolution JPG works best.')
  assert.equal(guidance.label, 'Artwork file')
})

test('resolveArtworkGuidance: empty guidance (not a crash) when the product has no file field', () => {
  const guidance = resolveArtworkGuidance({ fields: [] })
  assert.equal(guidance.help, '')
})

// ── deriveRelatedProducts ─────────────────────────────────────────────

const catalog = [
  vinylProduct,
  { id: 'pvc-banner', name: 'PVC Banner', shortName: 'Banner', category: 'Signs & Large Format', pricing: { strategy: 'PER_AREA' } },
  { id: 'window-decals', name: 'Window Decals', shortName: 'Decals', category: 'Labels & Packaging', pricing: { strategy: 'PER_AREA', baseRate: 999 } },
  { id: 'product-labels', name: 'Product Labels', shortName: 'Labels', category: 'Labels & Packaging' },
  { id: 'a4-print', name: 'Document Printing', shortName: 'Documents', category: 'Quick Print' }
]

test('deriveRelatedProducts: only returns same-category products, excluding the product itself', () => {
  const related = deriveRelatedProducts(vinylProduct, catalog)
  assert.deepEqual(related.map((item) => item.id).sort(), ['product-labels', 'window-decals'])
})

test('deriveRelatedProducts: respects the limit', () => {
  const related = deriveRelatedProducts(vinylProduct, catalog, 1)
  assert.equal(related.length, 1)
})

test('deriveRelatedProducts: returns a lean shape with no pricing fields at all, even though the source catalog items carry pricing', () => {
  const related = deriveRelatedProducts(vinylProduct, catalog)
  for (const item of related) {
    assert.deepEqual(Object.keys(item).sort(), ['category', 'id', 'name', 'shortName'])
    assert.equal('pricing' in item, false)
  }
})

test('deriveRelatedProducts: no product or empty catalog yields an empty array, not a crash', () => {
  assert.deepEqual(deriveRelatedProducts(null, catalog), [])
  assert.deepEqual(deriveRelatedProducts(vinylProduct, []), [])
  assert.deepEqual(deriveRelatedProducts(vinylProduct, undefined), [])
})

// ── buildShareLinks ───────────────────────────────────────────────────

test('buildShareLinks: builds deterministic product/configure URLs from the given origin and product id', () => {
  const links = buildShareLinks(vinylProduct, { origin: 'https://example.com/' })
  assert.equal(links.productPageUrl, 'https://example.com/products/vinyl-stickers')
  assert.equal(links.configureUrl, 'https://example.com/configure/vinyl-stickers')
})

test('buildShareLinks: WhatsApp link uses the real business number from src/lib/businessInfo.js (QS-21.5) - the same one every other WhatsApp link in this app now imports, not an invented one', () => {
  const links = buildShareLinks(vinylProduct)
  assert.match(links.whatsappUrl, new RegExp(`^https://wa\\.me/${WHATSAPP_NUMBER}\\?text=`))
})

test('buildShareLinks: WhatsApp message mentions the product name and is URL-encoded', () => {
  const links = buildShareLinks(vinylProduct)
  assert.match(links.whatsappUrl, /Vinyl%20Stickers/)
})

test('buildShareLinks: no product yields empty-string links, not a crash', () => {
  assert.deepEqual(buildShareLinks(null), { productPageUrl: '', configureUrl: '', whatsappUrl: '' })
})

// ── resolveStartingPriceEligibility ──────────────────────────────────
// Correction: a "From R..." cue must be opt-in (productPage.
// showStartingPrice === true), never shown merely because a product has
// a pricing object - its default configuration is not necessarily its
// cheapest valid one.

test('resolveStartingPriceEligibility: a curated product (showStartingPrice: true) is eligible for an amount cue', () => {
  assert.deepEqual(resolveStartingPriceEligibility(vinylProduct), { mode: 'amount' })
})

test('resolveStartingPriceEligibility: an UNCURATED product with a full, real pricing object gets NO cue at all - having pricing.strategy/fields/baseRate is not enough on its own', () => {
  assert.deepEqual(resolveStartingPriceEligibility(uncuratedProduct), { mode: 'none' })
})

test('resolveStartingPriceEligibility: a product with productPage present but showStartingPrice absent/false still gets no amount cue', () => {
  assert.deepEqual(resolveStartingPriceEligibility({ ...uncuratedProduct, productPage: { headline: 'X' } }), { mode: 'none' })
  assert.deepEqual(resolveStartingPriceEligibility({ ...uncuratedProduct, productPage: { showStartingPrice: false } }), { mode: 'none' })
})

test('resolveStartingPriceEligibility: ENQUIRY strategy always yields a quote cue, regardless of showStartingPrice', () => {
  const enquiry = { id: 'custom-job', pricing: { strategy: 'ENQUIRY' } }
  assert.deepEqual(resolveStartingPriceEligibility(enquiry), { mode: 'quote' })
  assert.deepEqual(resolveStartingPriceEligibility({ ...enquiry, productPage: { showStartingPrice: true } }), { mode: 'quote' })
  assert.deepEqual(resolveStartingPriceEligibility({ ...enquiry, productPage: { showStartingPrice: false } }), { mode: 'quote' })
})

test('resolveStartingPriceEligibility: no product yields no cue, not a crash', () => {
  assert.deepEqual(resolveStartingPriceEligibility(null), { mode: 'none' })
  assert.deepEqual(resolveStartingPriceEligibility(undefined), { mode: 'none' })
})

// ── resolveHubAvailability ────────────────────────────────────────────
// Correction: a Guided/Advanced CTA must only be considered available
// when a REAL callable handler was actually passed in, not merely
// because the product's own metadata (channels.guided/guidedJourneyId)
// looks right - App.jsx can and does pass onGuided=null when no
// matching local guided journey exists for a product.

test('resolveHubAvailability: hasGuided is false when onGuided is not a function, even with perfect metadata', () => {
  const { hasGuided } = resolveHubAvailability(vinylProduct, { onGuided: null, onConfigure: () => {} })
  assert.equal(hasGuided, false)
})

test('resolveHubAvailability: hasGuided is true only with a real handler AND channels.guided !== false AND a guidedJourneyId', () => {
  const { hasGuided } = resolveHubAvailability(vinylProduct, { onGuided: () => {}, onConfigure: () => {} })
  assert.equal(hasGuided, true)
})

test('resolveHubAvailability: hasGuided is false when channels.guided is explicitly false, even with a real handler', () => {
  const product = { ...vinylProduct, channels: { guided: false } }
  const { hasGuided } = resolveHubAvailability(product, { onGuided: () => {}, onConfigure: () => {} })
  assert.equal(hasGuided, false)
})

test('resolveHubAvailability: hasGuided is false when guidedJourneyId is missing, even with a real handler', () => {
  const product = { ...vinylProduct, guidedJourneyId: undefined }
  const { hasGuided } = resolveHubAvailability(product, { onGuided: () => {}, onConfigure: () => {} })
  assert.equal(hasGuided, false)
})

test('resolveHubAvailability: hasAdvanced is false when onConfigure is not a function', () => {
  const { hasAdvanced } = resolveHubAvailability(vinylProduct, { onGuided: () => {}, onConfigure: undefined })
  assert.equal(hasAdvanced, false)
})

test('resolveHubAvailability: hasAdvanced is false when channels.advanced is explicitly false, even with a real handler', () => {
  const product = { ...vinylProduct, channels: { advanced: false } }
  const { hasAdvanced } = resolveHubAvailability(product, { onGuided: () => {}, onConfigure: () => {} })
  assert.equal(hasAdvanced, false)
})

test('resolveHubAvailability: hasAdvanced is true with a real handler and no explicit channels.advanced: false', () => {
  const { hasAdvanced } = resolveHubAvailability(vinylProduct, { onGuided: () => {}, onConfigure: () => {} })
  assert.equal(hasAdvanced, true)
})

test('resolveHubAvailability: no product yields both false, not a crash', () => {
  assert.deepEqual(resolveHubAvailability(null, { onGuided: () => {}, onConfigure: () => {} }), { hasGuided: false, hasAdvanced: false })
})
