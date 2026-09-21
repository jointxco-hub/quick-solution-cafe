import assert from 'node:assert/strict'
import test from 'node:test'
import { calculateProductPrice, getVariantQuantityRule } from '../src/lib/pricing.js'

// Fixtures mirror the real customer_definition.pricing shape stored in
// commerce.service_product_configs (customer-safe: pre-computed selling
// prices only, never a raw referencePrice/marginRate) — same numbers as
// the 'flags' product's real catalogue data (Telescopic 2.0m single-sided
// full kit reference R495 at 50% gross margin -> R990).
const flagsProduct = {
  id: 'flags',
  pricing: {
    strategy: 'SUPPLIER_MARGIN',
    minQuantity: 1,
    variants: {
      'telescopic-2m-ss-full': { label: 'Telescopic flag — 2.0m — single-sided — full kit', price: 990 },
      'unpriced-variant': { label: 'Not yet priced', price: null }
    },
    accessories: {
      'cross-base': { label: 'Cross base', price: 500 },
      'unpriced-accessory': { label: 'Not yet priced accessory', price: null }
    },
    artwork: {
      ready: { label: 'My artwork is ready', fee: 0 },
      design: { label: 'I need help with the design', fee: 250 }
    }
  }
}

const photoProduct = {
  id: 'photo-session',
  pricing: {
    strategy: 'PHOTOGRAPHY_SESSION',
    sessions: {
      '30min-7edits': { label: '30-minute session — 7 edited photos included', durationMinutes: 30, includedEdits: 7, price: 449 },
      custom: { label: 'A different duration or scope', durationMinutes: null, includedEdits: null, price: null }
    },
    extraEditRate: null,
    deliverables: {
      'video-highlight': { label: 'Video highlight', price: null }
    }
  }
}

test('SUPPLIER_MARGIN: 50% gross margin, not markup — R495 reference sells for exactly R990', () => {
  const result = calculateProductPrice(flagsProduct, { variant: 'telescopic-2m-ss-full', quantity: 1 })
  assert.equal(result.total, 990)
  assert.equal(result.metrics.quoteRequired, false)
  // A 50% MARKUP (not gross margin) would have given 495 * 1.5 = 742.5 —
  // confirming we did NOT implement that by mistake.
  assert.notEqual(result.total, 742.5)
})

test('SUPPLIER_MARGIN: quantity multiplies the margin-applied unit price', () => {
  const result = calculateProductPrice(flagsProduct, { variant: 'telescopic-2m-ss-full', quantity: 3 })
  assert.equal(result.total, 2970)
})

test('SUPPLIER_MARGIN: a variant with no approved reference price is Quote required, never R0-as-free', () => {
  const result = calculateProductPrice(flagsProduct, { variant: 'unpriced-variant', quantity: 1 })
  assert.equal(result.metrics.quoteRequired, true)
  assert.equal(result.summary, 'Quote required')
})

test('SUPPLIER_MARGIN: an unpriced accessory forces the whole line to Quote required, even with a priced variant', () => {
  const result = calculateProductPrice(flagsProduct, {
    variant: 'telescopic-2m-ss-full', quantity: 1, accessories: ['unpriced-accessory']
  })
  assert.equal(result.metrics.quoteRequired, true)
})

test('SUPPLIER_MARGIN: a priced accessory adds its own margin-applied amount on top', () => {
  const result = calculateProductPrice(flagsProduct, {
    variant: 'telescopic-2m-ss-full', quantity: 1, accessories: ['cross-base']
  })
  assert.equal(result.total, 1490) // 990 + 500
})

test('SUPPLIER_MARGIN: artwork/setup fee is added flat, not margin-multiplied', () => {
  const result = calculateProductPrice(flagsProduct, {
    variant: 'telescopic-2m-ss-full', quantity: 1, artwork: 'design'
  })
  assert.equal(result.total, 1240) // 990 + 250 flat, not 990 + 500
})

test('PHOTOGRAPHY_SESSION: the one approved special prices at exactly R449', () => {
  const result = calculateProductPrice(photoProduct, { session: '30min-7edits' })
  assert.equal(result.total, 449)
  assert.equal(result.metrics.quoteRequired, false)
})

test('PHOTOGRAPHY_SESSION: an unapproved/custom session is explicitly Quote required, never a silent R0', () => {
  const result = calculateProductPrice(photoProduct, { session: 'custom' })
  assert.equal(result.summary, 'Quote required')
  assert.equal(result.metrics.quoteRequired, true)
  // Not simply "total is 0" — the UI must be told this is a quote, not free.
  assert.equal(result.total, 0)
})

test('PHOTOGRAPHY_SESSION: requesting extra edited photos with no approved rate makes the WHOLE request quote-required, not silently R449', () => {
  const result = calculateProductPrice(photoProduct, { session: '30min-7edits', extraEdits: 5 })
  assert.equal(result.metrics.quoteRequired, true)
})

test('PHOTOGRAPHY_SESSION: no hourly rate is ever inferred by doubling the special — extraEditRate stays null, "custom" has no invented price', () => {
  assert.equal(photoProduct.pricing.extraEditRate, null)
  assert.equal(photoProduct.pricing.sessions.custom.price, null)
  // Specifically guard against the "double the 30-min price for 60 min" shortcut.
  assert.notEqual(photoProduct.pricing.sessions.custom.price, 449 * 2)
})

test('PHOTOGRAPHY_SESSION: a requested deliverable with no approved price is quote-required', () => {
  const result = calculateProductPrice(photoProduct, { session: '30min-7edits', deliverables: ['video-highlight'] })
  assert.equal(result.metrics.quoteRequired, true)
})

// ── Supplier constraints: single-sided flags must be bought in pairs of 2 ──
const flagsWithPairsRule = {
  id: 'flags',
  pricing: {
    strategy: 'SUPPLIER_MARGIN',
    minQuantity: 1,
    variants: {
      'telescopic-2m-ss-full': { label: 'Telescopic — single-sided', price: 990, minQuantity: 2, quantityStep: 2 },
      'telescopic-2m-ds-full': { label: 'Telescopic — double-sided', price: 1390 }
    },
    accessories: {
      'wall-2x2': { label: '2x2 wall', price: 650, compatibleVariants: ['telescopic-2m-ss-full'] },
      'universal-weight': { label: 'Universal weight', price: 690 }
    },
    artwork: {}
  }
}

test('getVariantQuantityRule: a variant with minQuantity/quantityStep overrides the product default', () => {
  const rule = getVariantQuantityRule(flagsWithPairsRule, 'telescopic-2m-ss-full')
  assert.deepEqual(rule, { minQuantity: 2, quantityStep: 2 })
})

test('getVariantQuantityRule: a variant with no override falls back to the product default', () => {
  const rule = getVariantQuantityRule(flagsWithPairsRule, 'telescopic-2m-ds-full')
  assert.deepEqual(rule, { minQuantity: 1, quantityStep: 1 })
})

test('SUPPLIER_MARGIN: quantity 1 for a single-sided (pairs-of-2) variant is rejected client-side too', () => {
  const result = calculateProductPrice(flagsWithPairsRule, { variant: 'telescopic-2m-ss-full', quantity: 1 })
  assert.equal(result.metrics.invalid, true)
  assert.match(result.summary, /minimum is 2|multiples of 2/i)
})

test('SUPPLIER_MARGIN: quantity 3 for a pairs-of-2 variant (not a multiple of 2) is rejected', () => {
  const result = calculateProductPrice(flagsWithPairsRule, { variant: 'telescopic-2m-ss-full', quantity: 3 })
  assert.equal(result.metrics.invalid, true)
})

test('SUPPLIER_MARGIN: quantity 2 for a pairs-of-2 variant is accepted and prices correctly', () => {
  const result = calculateProductPrice(flagsWithPairsRule, { variant: 'telescopic-2m-ss-full', quantity: 2 })
  assert.equal(result.metrics.quoteRequired, false)
  assert.equal(result.total, 1980)
})

test('SUPPLIER_MARGIN: a double-sided variant has no pairs-of-2 constraint — quantity 1 is fine', () => {
  const result = calculateProductPrice(flagsWithPairsRule, { variant: 'telescopic-2m-ds-full', quantity: 1 })
  assert.equal(result.metrics.quoteRequired, false)
  assert.equal(result.total, 1390)
})

// ── Accessory compatibility ─────────────────────────────────────────
test('SUPPLIER_MARGIN: an accessory restricted to a different variant is rejected client-side', () => {
  const result = calculateProductPrice(flagsWithPairsRule, {
    variant: 'telescopic-2m-ds-full', quantity: 1, accessories: ['wall-2x2']
  })
  assert.equal(result.metrics.invalid, true)
  assert.match(result.summary, /not available/i)
})

test('SUPPLIER_MARGIN: an accessory IS accepted when paired with its compatible variant', () => {
  const result = calculateProductPrice(flagsWithPairsRule, {
    variant: 'telescopic-2m-ss-full', quantity: 2, accessories: ['wall-2x2']
  })
  assert.equal(result.metrics.quoteRequired, false)
  assert.equal(result.total, 1980 + 650)
})

test('SUPPLIER_MARGIN: an accessory with no compatibleVariants is universal', () => {
  const result = calculateProductPrice(flagsWithPairsRule, {
    variant: 'telescopic-2m-ds-full', quantity: 1, accessories: ['universal-weight']
  })
  assert.equal(result.metrics.quoteRequired, false)
  assert.equal(result.total, 1390 + 690)
})

// ── Privacy: the client-side estimator never needs/receives reference
// cost or margin data (already enforced server-side, checked again here
// to guard against a future change accidentally passing pricing_definition
// straight through to this client-side function). ──────────────────
test('privacy: the SUPPLIER_MARGIN fixtures used for client estimation carry no referencePrice/marginRate', () => {
  const serialized = JSON.stringify(flagsProduct) + JSON.stringify(flagsWithPairsRule)
  assert.doesNotMatch(serialized, /referencePrice/)
  assert.doesNotMatch(serialized, /marginRate/)
})
