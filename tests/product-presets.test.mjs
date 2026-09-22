import assert from 'node:assert/strict'
import test from 'node:test'
import {
  resolveProductPresets,
  validatePresetConfig,
  resolveStartingPriceEligibility,
  resolveSelectControlState,
  resolveSelectControlChange,
  deriveVariantAxisValues
} from '../src/lib/productContent.js'
import { calculateProductPrice, getVariantQuantityRule, accessoryCompatible, getDefaultConfig } from '../src/lib/pricing.js'
import { products } from '../src/data/products.js'

// Real catalogue data, not synthetic fixtures — this is the direct way
// to prove "flags preset resolves to exact existing variant" / "gazebo
// preset resolves to exact existing variant": if a preset's config.variant
// were ever a typo or an invented id, these tests fail against the real
// pricing.variants catalogue, not a hand-rolled stand-in for it.
const flagsProduct = products.find((product) => product.id === 'flags')
const gazebosProduct = products.find((product) => product.id === 'gazebos')
const vinylProduct = products.find((product) => product.id === 'vinyl-stickers')
const pvcBannerProduct = products.find((product) => product.id === 'pvc-banner')
const businessCardsProduct = products.find((product) => product.id === 'business-cards')
const printedTshirtProduct = products.find((product) => product.id === 'printed-tshirt')

test('sanity: flags and gazebos are present in the local fallback with the expected pricing strategy', () => {
  assert.ok(flagsProduct, 'flags product must exist in src/data/products.js')
  assert.ok(gazebosProduct, 'gazebos product must exist in src/data/products.js')
  assert.equal(flagsProduct.pricing.strategy, 'SUPPLIER_MARGIN')
  assert.equal(gazebosProduct.pricing.strategy, 'SUPPLIER_MARGIN')
})

// ── Fallback data corrections (found and fixed before building presets
// on top of them) — direct tests against the REAL local fallback data,
// not just incidental exercise via preset pricing. Both corrections
// live ONLY in src/data/products.js (a client-side JS object) — neither
// QS-17A nor QS-17B migration touches minQuantity/quantityStep/
// compatibleVariants, confirmed by grep (zero matches for any of those
// three terms in either migration file). This means they can only ever
// affect the client fallback path (used when Supabase cannot be
// reached/is not configured); they do not, and structurally cannot,
// alter any Supabase (staging or production) row or database behavior.

test('fallback correction: every single-sided (-ss-) flag variant carries minQuantity 2 / quantityStep 2, matching the live QS-14 catalogue exactly (was missing before this correction)', () => {
  const singleSidedIds = Object.keys(flagsProduct.pricing.variants).filter((id) => id.includes('-ss-'))
  assert.equal(singleSidedIds.length, 18, 'expected 3 styles × 3 sizes × 2 kit types = 18 single-sided variants')
  for (const id of singleSidedIds) {
    const rule = getVariantQuantityRule(flagsProduct, id)
    assert.deepEqual(rule, { minQuantity: 2, quantityStep: 2 }, `${id} must enforce the real pairs-of-2 rule`)
  }
})

test('fallback correction: double-sided (-ds-) flag variants have NO per-variant override - they fall back to the product default (1/1), exactly as the live catalogue has it', () => {
  const doubleSidedIds = Object.keys(flagsProduct.pricing.variants).filter((id) => id.includes('-ds-'))
  assert.equal(doubleSidedIds.length, 18)
  for (const id of doubleSidedIds) {
    const rule = getVariantQuantityRule(flagsProduct, id)
    assert.deepEqual(rule, { minQuantity: 1, quantityStep: 1 })
  }
})

test('fallback correction: size-restricted gazebo wall/wheely-bag accessories carry compatibleVariants matching the live QS-14 catalogue exactly (was missing before this correction - previously ANY wall fit ANY gazebo size)', () => {
  const accessories = gazebosProduct.pricing.accessories
  // Exact match against the live migration data quoted in the QS-17
  // final-review report - re-verified directly against
  // supabase/migrations/20260921090500_qs14_catalog_data.sql before
  // writing this test, not assumed from memory.
  assert.deepEqual(accessories['wall-2x2-half'].compatibleVariants, ['steel-2x2-full', 'steel-2x2-reprint', 'aluminium-2x2-full', 'aluminium-2x2-reprint'])
  assert.deepEqual(accessories['wall-3x4.5-full'].compatibleVariants, ['aluminium-3x4.5-deluxe-full', 'aluminium-3x4.5-deluxe-reprint'])
  assert.deepEqual(accessories['wall-3x6-full'].compatibleVariants, ['aluminium-3x6-deluxe-full', 'aluminium-3x6-deluxe-reprint'])
  // A 2x2 wall must not fit a 3x3 gazebo - the actual bug this
  // correction fixes, proven via accessoryCompatible() directly.
  assert.equal(accessoryCompatible(accessories['wall-2x2-half'], 'steel-3x3-standard-full'), false)
  assert.equal(accessoryCompatible(accessories['wall-2x2-half'], 'steel-2x2-full'), true)
  // A 6m wall must not fit a 2x2 gazebo.
  assert.equal(accessoryCompatible(accessories['wall-3x6-full'], 'steel-2x2-full'), false)
  assert.equal(accessoryCompatible(accessories['wall-3x6-full'], 'aluminium-3x6-deluxe-full'), true)
})

test('fallback correction: universal gazebo accessories (window/door add-ons, weights) remain uncompatibleVariants-restricted, exactly as the live catalogue has them - the correction only added restrictions where the live data actually has them, never invented new ones', () => {
  const accessories = gazebosProduct.pricing.accessories
  for (const id of ['wall-window', 'wall-door', 'rubber-weight', 'sandbag-set-4']) {
    assert.equal(accessories[id].compatibleVariants, undefined, `${id} must remain universal (no compatibleVariants), matching the live catalogue`)
    assert.equal(accessoryCompatible(accessories[id], 'steel-2x2-full'), true)
    assert.equal(accessoryCompatible(accessories[id], 'aluminium-3x6-deluxe-full'), true)
  }
})

// ── resolveProductPresets() — real catalogue ─────────────────────────

test('resolveProductPresets: flags has exactly 5 curated presets, all structurally+semantically valid', () => {
  const presets = resolveProductPresets(flagsProduct)
  assert.equal(presets.length, 5)
})

test('resolveProductPresets: every flags preset resolves to an exact, existing variant id in pricing.variants', () => {
  const presets = resolveProductPresets(flagsProduct)
  for (const preset of presets) {
    assert.ok(
      Object.prototype.hasOwnProperty.call(flagsProduct.pricing.variants, preset.config.variant),
      `${preset.id} references "${preset.config.variant}", which is not a real flags variant`
    )
  }
})

test('resolveProductPresets: gazebos has exactly 5 curated presets, all structurally+semantically valid', () => {
  const presets = resolveProductPresets(gazebosProduct)
  assert.equal(presets.length, 5)
})

test('resolveProductPresets: every gazebo preset resolves to an exact, existing variant id in pricing.variants', () => {
  const presets = resolveProductPresets(gazebosProduct)
  for (const preset of presets) {
    assert.ok(
      Object.prototype.hasOwnProperty.call(gazebosProduct.pricing.variants, preset.config.variant),
      `${preset.id} references "${preset.config.variant}", which is not a real gazebo variant`
    )
  }
})

test('resolveProductPresets: single-sided flag presets correctly carry quantity 2 (the real pairs-of-2 rule), double-sided presets carry quantity 1', () => {
  const presets = resolveProductPresets(flagsProduct)
  const singleSided = presets.filter((preset) => preset.config.variant.includes('-ss-'))
  const doubleSided = presets.filter((preset) => preset.config.variant.includes('-ds-'))
  assert.ok(singleSided.length > 0 && doubleSided.length > 0, 'expected both single- and double-sided presets in the curated set')
  for (const preset of singleSided) assert.equal(preset.config.quantity, 2)
  for (const preset of doubleSided) assert.equal(preset.config.quantity, 1)
})

// ── Correction: a preset must not assume artwork is ready ─────────────
// A preset configures the PHYSICAL PRODUCT (variant/quantity) - it must
// not silently assert the customer already has print-ready artwork. See
// the full investigation in src/lib/productContent.js above
// validatePresetConfig() for why `artwork: null` (not simply omitting
// the key) is what actually achieves this.

test('resolveProductPresets: every flags preset intentionally leaves artwork unanswered (null), never silently "ready"', () => {
  const presets = resolveProductPresets(flagsProduct)
  assert.equal(presets.length, 5)
  for (const preset of presets) {
    assert.equal(preset.config.artwork, null, `${preset.id} must leave artwork as null, not a pre-chosen answer`)
  }
})

test('resolveProductPresets: every gazebo preset intentionally leaves artwork unanswered (null), never silently "ready"', () => {
  const presets = resolveProductPresets(gazebosProduct)
  assert.equal(presets.length, 5)
  for (const preset of presets) {
    assert.equal(preset.config.artwork, null, `${preset.id} must leave artwork as null, not a pre-chosen answer`)
  }
})

test('resolveProductPresets: products without any presets render normally (empty array, not a crash)', () => {
  assert.deepEqual(resolveProductPresets(vinylProduct), [])
  assert.deepEqual(resolveProductPresets(pvcBannerProduct), [])
  assert.deepEqual(resolveProductPresets(businessCardsProduct), [])
  assert.deepEqual(resolveProductPresets(printedTshirtProduct), [])
  assert.deepEqual(resolveProductPresets(null), [])
  assert.deepEqual(resolveProductPresets({}), [])
})

// ── resolveProductPresets() — malformed/invalid entries ──────────────

const fixtureFlagLike = {
  id: 'test-flag',
  fields: [
    { id: 'variant', type: 'select', required: true, options: [{ id: 'style-a-full' }, { id: 'style-b-full' }] },
    { id: 'quantity', type: 'number', default: 1, min: 1 },
    { id: 'artwork', type: 'select', options: [{ id: 'ready' }, { id: 'check' }] }
  ],
  pricing: {
    strategy: 'SUPPLIER_MARGIN',
    variants: { 'style-a-full': { label: 'Style A', price: 100 }, 'style-b-full': { label: 'Style B', price: 200 } },
    accessories: {
      'universal-add-on': { label: 'Universal', price: 50 },
      'restricted-add-on': { label: 'Restricted', price: 60, compatibleVariants: ['style-a-full'] }
    },
    artwork: { ready: { label: 'Ready', fee: 0 }, check: { label: 'Check', fee: 75 } }
  },
  productPage: {
    presets: [
      { id: 'valid-1', name: 'Valid preset', description: 'A real one', config: { variant: 'style-a-full', quantity: 1, artwork: 'ready' } },
      { id: 'missing-name', config: { variant: 'style-a-full' } },
      { id: 'missing-config', name: 'No config' },
      { name: 'missing-id', config: { variant: 'style-a-full' } },
      { id: 'bad-variant', name: 'Bad variant', config: { variant: 'not-a-real-variant' } },
      { id: 'bad-option', name: 'Bad artwork option', config: { variant: 'style-a-full', artwork: 'not-a-real-option' } },
      { id: 'unknown-field', name: 'Unknown field key', config: { variant: 'style-a-full', totallyMadeUpField: 'x' } },
      { id: 'leaked-pricing-field', name: 'Leaked pricing field', config: { variant: 'style-a-full', referencePrice: 495, marginRate: 0.5 } },
      { id: 'incompatible-accessory', name: 'Incompatible accessory', config: { variant: 'style-b-full', accessories: ['restricted-add-on'] } },
      { id: 'unknown-accessory', name: 'Unknown accessory', config: { variant: 'style-a-full', accessories: ['not-a-real-accessory'] } },
      'not-even-an-object',
      null,
      { id: 'valid-2', name: 'Second valid preset', description: '', config: { variant: 'style-b-full', accessories: ['universal-add-on'] } }
    ]
  }
}

test('resolveProductPresets: keeps only the genuinely valid entries, drops every malformed/invalid one', () => {
  const presets = resolveProductPresets(fixtureFlagLike)
  assert.deepEqual(presets.map((preset) => preset.id).sort(), ['valid-1', 'valid-2'])
})

test('resolveProductPresets: no internal pricing/supplier field survives normalization, even when present on the raw entry', () => {
  const presets = resolveProductPresets(fixtureFlagLike)
  for (const preset of presets) {
    // QS-21.4: shortName/shortDescription are legitimate additive fields
    // (the compact "quick option card" text - see resolveProductPresets'
    // own comment in productContent.js), not internal pricing/supplier
    // data - the real guard below (referencePrice/marginRate) is what
    // this test is actually protecting.
    assert.deepEqual(Object.keys(preset).sort(), ['config', 'description', 'id', 'name', 'shortDescription', 'shortName'])
    assert.equal('referencePrice' in preset.config, false)
    assert.equal('marginRate' in preset.config, false)
    assert.equal('sourceUrl' in preset.config, false)
    assert.equal('supplierCost' in preset.config, false)
  }
  // The one entry that tried to smuggle referencePrice/marginRate INTO
  // config was rejected wholesale (its keys don't match any real field),
  // not silently stripped down to a different-looking preset.
  assert.equal(presets.some((preset) => preset.id === 'leaked-pricing-field'), false)
})

// ── validatePresetConfig() — direct checks ────────────────────────────

test('validatePresetConfig: a config key that is not a real product field is rejected', () => {
  const result = validatePresetConfig(fixtureFlagLike, { config: { variant: 'style-a-full', notARealField: 1 } })
  assert.equal(result.valid, false)
  assert.match(result.errors.join(' '), /notARealField.*not a real field/)
})

test('validatePresetConfig: a selected option id that does not exist on the field is rejected', () => {
  const result = validatePresetConfig(fixtureFlagLike, { config: { variant: 'nope-not-real' } })
  assert.equal(result.valid, false)
})

test('validatePresetConfig: an accessory id that does not exist is rejected', () => {
  const result = validatePresetConfig(fixtureFlagLike, { config: { variant: 'style-a-full', accessories: ['nope'] } })
  assert.equal(result.valid, false)
})

test('validatePresetConfig: an accessory incompatible with the chosen variant is rejected', () => {
  const result = validatePresetConfig(fixtureFlagLike, { config: { variant: 'style-b-full', accessories: ['restricted-add-on'] } })
  assert.equal(result.valid, false)
})

test('validatePresetConfig: the same accessory IS accepted when paired with its compatible variant', () => {
  const result = validatePresetConfig(fixtureFlagLike, { config: { variant: 'style-a-full', accessories: ['restricted-add-on'] } })
  assert.equal(result.valid, true)
})

test('validatePresetConfig: a universal accessory (no compatibleVariants) is accepted with any variant', () => {
  const result = validatePresetConfig(fixtureFlagLike, { config: { variant: 'style-b-full', accessories: ['universal-add-on'] } })
  assert.equal(result.valid, true)
})

test('validatePresetConfig: explicit null on a NON-required select field (artwork) is valid - a preset may intentionally leave an optional choice for the customer to make', () => {
  const result = validatePresetConfig(fixtureFlagLike, { config: { variant: 'style-a-full', artwork: null } })
  assert.equal(result.valid, true)
})

test('validatePresetConfig: explicit null on a REQUIRED field (variant, in this fixture) is rejected - a preset can leave an optional choice open, never a required one', () => {
  const result = validatePresetConfig(fixtureFlagLike, { config: { variant: null, artwork: 'ready' } })
  assert.equal(result.valid, false)
})

test('validatePresetConfig: null is still the ONLY accepted non-option value - any other invalid string on artwork is still rejected', () => {
  const result = validatePresetConfig(fixtureFlagLike, { config: { variant: 'style-a-full', artwork: 'not-a-real-option' } })
  assert.equal(result.valid, false)
})

test('validatePresetConfig: no product or no config is rejected, not a crash', () => {
  assert.equal(validatePresetConfig(null, { config: { variant: 'x' } }).valid, false)
  assert.equal(validatePresetConfig(fixtureFlagLike, null).valid, false)
  assert.equal(validatePresetConfig(fixtureFlagLike, { config: null }).valid, false)
  assert.equal(validatePresetConfig(fixtureFlagLike, { config: [] }).valid, false)
})

// ── "preset values never leak to another product" ────────────────────
// The runtime guarantee (a preset chosen for product A can never end up
// configuring product B) lives in src/App.jsx's React state flow:
// onGuided/onConfigure closures capture `selectedProduct` fresh on every
// render, and openAdvanced/openGuided always FULLY REPLACE the `preset`
// state object (never merge onto a previous one) - see the QS-16
// stale-preset-reset correction (openProductPage resets preset/
// taskContext/guidedStartStep/guidedInitialFile on every product
// switch). That is a React-state-flow guarantee this repo has no
// component-testing framework to assert on directly (confirmed: no
// React Testing Library / jsdom setup exists - see QS-16/QS-17 audits).
// What IS directly testable at the data layer, and is the guard that
// actually matters if that state-flow discipline were ever violated: a
// preset written for one product's field/variant catalogue must be
// REJECTED, not silently accepted, if it were ever checked against a
// DIFFERENT product.
test('validatePresetConfig: a flags preset config is invalid when checked against the gazebos product (and vice versa) - presets are validated per-product, never globally', () => {
  const flagsPresets = resolveProductPresets(flagsProduct)
  const gazebosPresets = resolveProductPresets(gazebosProduct)
  assert.ok(flagsPresets.length > 0 && gazebosPresets.length > 0)

  for (const preset of flagsPresets) {
    assert.equal(validatePresetConfig(gazebosProduct, preset).valid, false, `${preset.id} (a flags preset) must not validate against gazebos`)
  }
  for (const preset of gazebosPresets) {
    assert.equal(validatePresetConfig(flagsProduct, preset).valid, false, `${preset.id} (a gazebos preset) must not validate against flags`)
  }
})

// ── preset price still uses calculateProductPrice() ───────────────────

test('preset price: every flags preset prices successfully through the real calculateProductPrice(), never quote-required or invalid', () => {
  const presets = resolveProductPresets(flagsProduct)
  for (const preset of presets) {
    const result = calculateProductPrice(flagsProduct, preset.config)
    assert.equal(result.metrics.quoteRequired, false, `${preset.id} unexpectedly requires a quote`)
    assert.equal(result.metrics.invalid, undefined, `${preset.id} unexpectedly failed quantity/accessory validation`)
    assert.ok(result.total > 0, `${preset.id} priced at ${result.total}`)
  }
})

test('preset price: every gazebo preset prices successfully through the real calculateProductPrice()', () => {
  const presets = resolveProductPresets(gazebosProduct)
  for (const preset of presets) {
    const result = calculateProductPrice(gazebosProduct, preset.config)
    assert.equal(result.metrics.quoteRequired, false, `${preset.id} unexpectedly requires a quote`)
    assert.equal(result.metrics.invalid, undefined, `${preset.id} unexpectedly failed quantity/accessory validation`)
    assert.ok(result.total > 0, `${preset.id} priced at ${result.total}`)
  }
})

test('preset price: the 2m Telescopic Flag preset prices at exactly variant price × quantity (990 × 2 = 1980), matching the real catalogue rate', () => {
  const preset = resolveProductPresets(flagsProduct).find((entry) => entry.id === 'flag-2m-telescopic-full')
  const result = calculateProductPrice(flagsProduct, preset.config)
  assert.equal(result.total, 1980)
})

test('preset price: the 2×2 Steel Gazebo preset prices at exactly the real catalogue rate (5500)', () => {
  const preset = resolveProductPresets(gazebosProduct).find((entry) => entry.id === 'gazebo-2x2-steel-full')
  const result = calculateProductPrice(gazebosProduct, preset.config)
  assert.equal(result.total, 5500)
})

test('preset price: leaving artwork null prices IDENTICALLY to an explicit "ready" - the safety claim behind the artwork correction, proven directly, not just asserted', () => {
  const withNull = calculateProductPrice(flagsProduct, { variant: 'telescopic-2m-ss-full', quantity: 2, artwork: null })
  const withReady = calculateProductPrice(flagsProduct, { variant: 'telescopic-2m-ss-full', quantity: 2, artwork: 'ready' })
  const withoutKey = calculateProductPrice(flagsProduct, { variant: 'telescopic-2m-ss-full', quantity: 2 })
  assert.equal(withNull.total, withReady.total)
  assert.equal(withNull.total, withoutKey.total)
  assert.equal(withNull.metrics.quoteRequired, false)
})

// ── starting-price eligibility rules unchanged (QS-17 "agreed rules") ─

test('starting-price eligibility: business-cards is the only true one, per the agreed rules', () => {
  assert.deepEqual(resolveStartingPriceEligibility(businessCardsProduct), { mode: 'amount' })
})

test('starting-price eligibility: pvc-banner, printed-tshirt, flags and gazebos are all "none" (no From cue), per the agreed rules', () => {
  assert.deepEqual(resolveStartingPriceEligibility(pvcBannerProduct), { mode: 'none' })
  assert.deepEqual(resolveStartingPriceEligibility(printedTshirtProduct), { mode: 'none' })
  assert.deepEqual(resolveStartingPriceEligibility(flagsProduct), { mode: 'none' })
  assert.deepEqual(resolveStartingPriceEligibility(gazebosProduct), { mode: 'none' })
})

// ── Advanced-mode artwork <select>: explicit neutral state, not a
// silent first-option highlight ──────────────────────────────────────
// FieldControl.jsx's plain <select> (Advanced mode) uses
// resolveSelectControlState()/resolveSelectControlChange() to translate
// null <-> '' only at the DOM boundary. These are the exact pure
// functions the real control calls - not a parallel reimplementation -
// so proving their behavior here proves the control's logic. What is
// NOT covered by these tests: the actual rendered <select> DOM (that
// the placeholder is visible, greyed out via `disabled`, and not
// re-selectable once a real option is chosen). This repo's test suite
// is plain Node `--test` over pure .mjs modules (see package.json's
// "test" script) with no jsdom/React-rendering harness, and adding one
// (jsdom/@testing-library/react) for a single control was judged not
// worth the new dependency - that rendered-DOM behavior was instead
// checked manually (npm run dev, Advanced mode, a flags/gazebos preset
// with artwork left unanswered) as a one-time smoke test, documented in
// the QS-17 report rather than re-run automatically on every change.

test('resolveSelectControlState: value null or undefined (artwork left unanswered by a preset) reports an explicit unanswered/neutral state, mapped to DOM value "" - never a real option id', () => {
  assert.deepEqual(resolveSelectControlState(null), { selectValue: '', isUnanswered: true })
  assert.deepEqual(resolveSelectControlState(undefined), { selectValue: '', isUnanswered: true })
})

test('resolveSelectControlState: a real answered value passes through unchanged and is never reported as unanswered', () => {
  assert.deepEqual(resolveSelectControlState('ready'), { selectValue: 'ready', isUnanswered: false })
  assert.deepEqual(resolveSelectControlState('design'), { selectValue: 'design', isUnanswered: false })
})

test('resolveSelectControlChange: the placeholder\'s own DOM value ("") is translated back to null, never submitted as a real config value', () => {
  assert.equal(resolveSelectControlChange(''), null)
})

test('resolveSelectControlChange: choosing an actual option updates config to that option\'s real id, unchanged', () => {
  assert.equal(resolveSelectControlChange('ready'), 'ready')
  assert.equal(resolveSelectControlChange('check'), 'check')
  assert.equal(resolveSelectControlChange('design'), 'design')
})

test('resolveSelectControlState/resolveSelectControlChange round-trip: null -> DOM "" -> back to null, with no real option ever silently implied as selected in between', () => {
  const { selectValue, isUnanswered } = resolveSelectControlState(null)
  assert.equal(selectValue, '')
  assert.equal(isUnanswered, true)
  assert.equal(resolveSelectControlChange(selectValue), null)
})

// ── QS-17D: deriving Guided axis selections from config.variant ──────
// Root cause: SupplierVariantConfigurator.jsx's axis <select>s read
// config.variantAxis_<axisId>, never config.variant - so a preset
// (which only ever sets {variant, quantity, artwork}) priced correctly
// but left every Guided axis dropdown showing its blank "Choose ..."
// placeholder. deriveVariantAxisValues() is the pure fix: it walks
// product.pricing.variantTemplate against the REAL, KNOWN axis option
// ids (never a naive hyphen split, which would break on gazebo size
// ids like "3x3-standard" that contain their own hyphen) and returns
// the axis breakdown, or null if anything doesn't structurally and
// genuinely resolve to a real product.pricing.variants entry.

test('deriveVariantAxisValues: telescopic-3m-ss-full resolves to all four flag axes correctly', () => {
  assert.deepEqual(deriveVariantAxisValues(flagsProduct, 'telescopic-3m-ss-full'), {
    style: 'telescopic', size: '3m', sides: 'ss', kit: 'full'
  })
})

test('deriveVariantAxisValues: telescopic-3m-ds-full resolves correctly (double-sided, not single-sided)', () => {
  assert.deepEqual(deriveVariantAxisValues(flagsProduct, 'telescopic-3m-ds-full'), {
    style: 'telescopic', size: '3m', sides: 'ds', kit: 'full'
  })
})

test('deriveVariantAxisValues: aluminium-3x3-standard-full resolves to all three gazebo axes correctly, despite "3x3-standard" itself containing a hyphen', () => {
  assert.deepEqual(deriveVariantAxisValues(gazebosProduct, 'aluminium-3x3-standard-full'), {
    frame: 'aluminium', size: '3x3-standard', kit: 'full'
  })
})

test('deriveVariantAxisValues: aluminium-3x3-deluxe-full resolves correctly (deluxe, not standard) - proves the resolver does not just grab the first matching size prefix', () => {
  assert.deepEqual(deriveVariantAxisValues(gazebosProduct, 'aluminium-3x3-deluxe-full'), {
    frame: 'aluminium', size: '3x3-deluxe', kit: 'full'
  })
})

test('deriveVariantAxisValues: variant ids whose axis value contains its own hyphen (3x4.5-deluxe, 3x6-deluxe) still resolve as a single size token, not split apart', () => {
  assert.deepEqual(deriveVariantAxisValues(gazebosProduct, 'aluminium-3x4.5-deluxe-full'), {
    frame: 'aluminium', size: '3x4.5-deluxe', kit: 'full'
  })
  assert.deepEqual(deriveVariantAxisValues(gazebosProduct, 'aluminium-3x6-deluxe-full'), {
    frame: 'aluminium', size: '3x6-deluxe', kit: 'full'
  })
})

test('deriveVariantAxisValues: steel-2x2-full (simplest gazebo variant) resolves correctly', () => {
  assert.deepEqual(deriveVariantAxisValues(gazebosProduct, 'steel-2x2-full'), {
    frame: 'steel', size: '2x2', kit: 'full'
  })
})

test('deriveVariantAxisValues: a malformed/nonexistent variant id returns null, not a partial or guessed result', () => {
  assert.equal(deriveVariantAxisValues(flagsProduct, 'not-a-real-variant'), null)
  assert.equal(deriveVariantAxisValues(flagsProduct, ''), null)
  assert.equal(deriveVariantAxisValues(flagsProduct, null), null)
  assert.equal(deriveVariantAxisValues(flagsProduct, undefined), null)
})

test('deriveVariantAxisValues: a variant id with an unknown/invented axis option is rejected (null), even though it structurally looks plausible', () => {
  // "turbo" is not a real kit option (only full/reprint exist) - the
  // resolver must not accept it just because the first three segments
  // matched real axis options.
  assert.equal(deriveVariantAxisValues(flagsProduct, 'telescopic-3m-ss-turbo'), null)
})

test('deriveVariantAxisValues: a product with no variantAxes/variantTemplate (e.g. vinyl-stickers) safely returns null, never throws', () => {
  assert.equal(deriveVariantAxisValues(vinylProduct, 'anything'), null)
  assert.equal(deriveVariantAxisValues(null, 'anything'), null)
  assert.equal(deriveVariantAxisValues(flagsProduct, {}), null)
})

// hydrateVariantAxisConfig mirrors the small, component-local helper
// GuidedOrder.jsx uses to refresh variantAxis_* display keys from
// config.variant at the moments its config is (re)built (preset load,
// product/journey switch) - reimplemented here, over the same exported
// deriveVariantAxisValues(), so this proves the actual hydration
// behavior without importing a .jsx component into this plain
// Node --test suite (see the "Advanced-mode artwork <select>" section
// above for why this repo's tests stay .jsx-free).
function hydrateVariantAxisConfig(product, config) {
  const axes = product?.pricing?.variantAxes
  if (!Array.isArray(axes) || axes.length === 0) return config
  const derived = deriveVariantAxisValues(product, config.variant)
  if (!derived) return config
  const patch = {}
  for (const axis of axes) patch[`variantAxis_${axis.id}`] = derived[axis.id]
  return { ...config, ...patch }
}

test('hydrateVariantAxisConfig: a preset-loaded flags config (variant only, no axis keys) hydrates to all four visible axis values, matching the QS-17D bug report exactly (3m Telescopic Complete kit)', () => {
  const preset = resolveProductPresets(flagsProduct).find((entry) => entry.id === 'flag-3m-telescopic-full')
  const config = hydrateVariantAxisConfig(flagsProduct, getDefaultConfig(flagsProduct, preset.config))
  assert.equal(config.variantAxis_style, 'telescopic')
  assert.equal(config.variantAxis_size, '3m')
  assert.equal(config.variantAxis_sides, 'ss')
  assert.equal(config.variantAxis_kit, 'full')
  assert.equal(config.quantity, 2)
  assert.equal(config.artwork, null, 'artwork must stay unanswered - hydrating axes must never touch/convert it')
  const result = calculateProductPrice(flagsProduct, config)
  assert.equal(result.total, 2380)
})

test('hydrateVariantAxisConfig: gazebo presets hydrate correctly too (steel-2x2-full, aluminium-3x3-deluxe-full)', () => {
  const preset2x2 = resolveProductPresets(gazebosProduct).find((entry) => entry.id === 'gazebo-2x2-steel-full')
  const config2x2 = hydrateVariantAxisConfig(gazebosProduct, getDefaultConfig(gazebosProduct, preset2x2.config))
  assert.deepEqual(
    { frame: config2x2.variantAxis_frame, size: config2x2.variantAxis_size, kit: config2x2.variantAxis_kit },
    { frame: 'steel', size: '2x2', kit: 'full' }
  )

  const presetDeluxe = resolveProductPresets(gazebosProduct).find((entry) => entry.id === 'gazebo-3x3-aluminium-deluxe-full')
  const configDeluxe = hydrateVariantAxisConfig(gazebosProduct, getDefaultConfig(gazebosProduct, presetDeluxe.config))
  assert.deepEqual(
    { frame: configDeluxe.variantAxis_frame, size: configDeluxe.variantAxis_size, kit: configDeluxe.variantAxis_kit },
    { frame: 'aluminium', size: '3x3-deluxe', kit: 'full' }
  )
})

test('hydrateVariantAxisConfig: switching from a flags preset to "Build your own" gazebos never leaks flags axis keys into the fresh gazebo config', () => {
  const flagsPreset = resolveProductPresets(flagsProduct).find((entry) => entry.id === 'flag-2m-telescopic-full')
  const flagsConfig = hydrateVariantAxisConfig(flagsProduct, getDefaultConfig(flagsProduct, flagsPreset.config))
  assert.ok(flagsConfig.variantAxis_style, 'sanity check: flags config really did hydrate first')

  // "Build your own" / a fresh product switch always rebuilds config
  // from getDefaultConfig(product, {}) - a brand-new object, not a
  // patch on the previous one - so a differently-shaped product (no
  // "style"/"sides" axes at all) cannot inherit stale flags keys.
  const freshGazeboConfig = hydrateVariantAxisConfig(gazebosProduct, getDefaultConfig(gazebosProduct, {}))
  assert.equal(freshGazeboConfig.variantAxis_style, undefined)
  assert.equal(freshGazeboConfig.variantAxis_sides, undefined)
})

test('hydrateVariantAxisConfig: switching from one flags preset to another does not carry over the first preset\'s axis values', () => {
  const preset2m = resolveProductPresets(flagsProduct).find((entry) => entry.id === 'flag-2m-telescopic-full')
  const config2m = hydrateVariantAxisConfig(flagsProduct, getDefaultConfig(flagsProduct, preset2m.config))
  assert.equal(config2m.variantAxis_size, '2m')

  const presetDouble = resolveProductPresets(flagsProduct).find((entry) => entry.id === 'flag-3m-telescopic-double-full')
  // Simulates GuidedOrder's actual reset: config is rebuilt from scratch
  // via getDefaultConfig(product, preset) every time, never patched onto
  // the previous config object - so the stale '2m'/'ss' from the first
  // preset cannot survive into the second preset's hydrated config.
  const configDouble = hydrateVariantAxisConfig(flagsProduct, getDefaultConfig(flagsProduct, presetDouble.config))
  assert.equal(configDouble.variantAxis_size, '3m')
  assert.equal(configDouble.variantAxis_sides, 'ds')
  assert.notEqual(configDouble.variantAxis_size, config2m.variantAxis_size)
})
