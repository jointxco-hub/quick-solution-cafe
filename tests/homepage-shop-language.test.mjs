import assert from 'node:assert/strict'
import test from 'node:test'
import {
  resolveDisplayLabel,
  resolveProductDisplayName,
  composeVariantSummary,
  SHOP_CATEGORIES,
  resolveShopCategory,
  filterProductsByShopCategory
} from '../src/lib/productContent.js'
import { products, heroOutcomes } from '../src/data/products.js'
import { loadLanguageMode, saveLanguageMode, hasSeenLanguageModePrompt, markLanguageModePromptSeen } from '../src/lib/languageMode.js'

const flagsProduct = products.find((product) => product.id === 'flags')
const gazebosProduct = products.find((product) => product.id === 'gazebos')
const pvcBannerProduct = products.find((product) => product.id === 'pvc-banner')
const vinylProduct = products.find((product) => product.id === 'vinyl-stickers')

// ── QS-18: resolveDisplayLabel / resolveProductDisplayName ───────────
// Presentation-only: these never touch product ids, config, prices or
// variant ids - they only pick which STRING to show. 'label'/'name' is
// always the existing/default text (shown in Pro mode and at any call
// site that never passes a mode at all); 'simpleLabel'/'simpleName' is
// the new, opt-in override shown only in Simple mode.

test('resolveDisplayLabel: returns simpleLabel in Simple mode when one exists', () => {
  assert.equal(resolveDisplayLabel({ label: 'Full kit', simpleLabel: 'Complete kit' }, 'simple'), 'Complete kit')
})

test('resolveDisplayLabel: returns label (not simpleLabel) in Pro mode, even when a simpleLabel exists', () => {
  assert.equal(resolveDisplayLabel({ label: 'Full kit', simpleLabel: 'Complete kit' }, 'pro'), 'Full kit')
})

test('resolveDisplayLabel: falls back to label in Simple mode when no simpleLabel exists - never invents one', () => {
  assert.equal(resolveDisplayLabel({ label: 'Style' }, 'simple'), 'Style')
})

test('resolveDisplayLabel: a plain string value passes through unchanged in both modes', () => {
  assert.equal(resolveDisplayLabel('Telescopic', 'simple'), 'Telescopic')
  assert.equal(resolveDisplayLabel('Telescopic', 'pro'), 'Telescopic')
})

test('resolveDisplayLabel: null/undefined value is handled safely, never throws', () => {
  assert.equal(resolveDisplayLabel(null, 'simple'), '')
  assert.equal(resolveDisplayLabel(undefined, 'pro'), '')
})

test('resolveDisplayLabel: also recognizes the name/simpleName shape (products/presets), not just label/simpleLabel', () => {
  assert.equal(resolveDisplayLabel({ name: 'PVC Banner', simpleName: 'Outdoor advertising banner' }, 'simple'), 'Outdoor advertising banner')
  assert.equal(resolveDisplayLabel({ name: 'PVC Banner', simpleName: 'Outdoor advertising banner' }, 'pro'), 'PVC Banner')
})

test('resolveProductDisplayName: pvc-banner resolves to its real simpleName in Simple mode and its real name in Pro mode', () => {
  assert.equal(resolveProductDisplayName(pvcBannerProduct, 'simple'), 'Outdoor advertising banner')
  assert.equal(resolveProductDisplayName(pvcBannerProduct, 'pro'), 'PVC Banner')
})

test('resolveProductDisplayName: a product with no simpleName renders identically in both modes (no rewrite forced)', () => {
  assert.equal(resolveProductDisplayName(vinylProduct, 'simple'), vinylProduct.name)
  assert.equal(resolveProductDisplayName(vinylProduct, 'pro'), vinylProduct.name)
})

test('resolveProductDisplayName: no product is handled safely, never throws', () => {
  assert.equal(resolveProductDisplayName(null, 'simple'), '')
  assert.equal(resolveProductDisplayName(undefined, 'pro'), '')
})

// ── QS-18: composeVariantSummary ──────────────────────────────────────
// Built directly on top of QS-17D's deriveVariantAxisValues() - proves
// the exact worked example from the QS-18 brief against the REAL flags
// catalogue, not a synthetic fixture: same variant, same axes, only the
// language changes between modes.

test('composeVariantSummary: telescopic-3m-ds-full composes the exact Simple vs Pro wording from the QS-18 brief\'s own example', () => {
  const pro = composeVariantSummary(flagsProduct, 'telescopic-3m-ds-full', 'pro')
  const simple = composeVariantSummary(flagsProduct, 'telescopic-3m-ds-full', 'simple')
  assert.equal(pro, 'Telescopic — 3.0m — Double-sided — Full kit (print + system + ground spike + carry bag)')
  assert.equal(simple, 'Telescopic — 3.0m — Printed on both sides — Complete kit (print + system + ground spike + carry bag)')
})

test('composeVariantSummary: single-sided flag variants say "Single-sided"/"Printed on one side" (not double-sided), still keeping the pairs-of-2 spec visible', () => {
  const pro = composeVariantSummary(flagsProduct, 'telescopic-2m-ss-full', 'pro')
  const simple = composeVariantSummary(flagsProduct, 'telescopic-2m-ss-full', 'simple')
  assert.ok(pro.includes('Single-sided (must be ordered in pairs of 2)'), pro)
  assert.ok(simple.includes('Printed on one side (ordered in pairs of 2)'), simple)
})

test('composeVariantSummary: gazebo variants resolve their 3-axis (frame/size/kit) template correctly in both modes, including the deluxe/standard distinction', () => {
  const pro = composeVariantSummary(gazebosProduct, 'aluminium-3x3-deluxe-full', 'pro')
  const simple = composeVariantSummary(gazebosProduct, 'aluminium-3x3-deluxe-full', 'simple')
  assert.equal(pro, 'Aluminium — 3m × 3m deluxe — Full kit (print + system + carry bag + toolkit)')
  assert.equal(simple, 'Aluminium — 3m × 3m deluxe — Complete kit (print + system + carry bag + toolkit)')
})

test('composeVariantSummary: gazebo reprint uses the "Replacement gazebo roof print" Simple wording, "Replacement canopy print only" Pro wording', () => {
  const pro = composeVariantSummary(gazebosProduct, 'steel-3x3-standard-reprint', 'pro')
  const simple = composeVariantSummary(gazebosProduct, 'steel-3x3-standard-reprint', 'simple')
  assert.ok(pro.endsWith('Replacement canopy print only'), pro)
  assert.ok(simple.endsWith('Replacement gazebo roof print'), simple)
})

test('composeVariantSummary: a malformed/nonexistent variant id returns null (same guarantee as deriveVariantAxisValues), never a partial line', () => {
  assert.equal(composeVariantSummary(flagsProduct, 'not-a-real-variant', 'simple'), null)
  assert.equal(composeVariantSummary(flagsProduct, null, 'simple'), null)
})

test('composeVariantSummary: a product with no variantAxes (e.g. vinyl-stickers) returns null, never throws', () => {
  assert.equal(composeVariantSummary(vinylProduct, 'anything', 'simple'), null)
})

// ── QS-18: Shop category filter ───────────────────────────────────────

test('SHOP_CATEGORIES: exactly the 7 buckets from the QS-18 brief, "All" first', () => {
  assert.deepEqual(SHOP_CATEGORIES, ['All', 'Print & Documents', 'Business', 'Signs & Advertising', 'Apparel', 'Events', 'Photo & Video'])
})

test('resolveShopCategory: every current catalogue product maps to exactly one real Shop bucket - none fall through to null', () => {
  for (const product of products) {
    const bucket = resolveShopCategory(product)
    assert.ok(bucket, `${product.id} (category "${product.category}") did not resolve to a Shop bucket`)
    assert.ok(SHOP_CATEGORIES.includes(bucket), `${product.id} resolved to "${bucket}", which is not a real Shop bucket`)
  }
})

test('resolveShopCategory: spot-checks the exact mapping for a representative product per bucket', () => {
  assert.equal(resolveShopCategory(products.find((product) => product.id === 'a4-print')), 'Print & Documents')
  assert.equal(resolveShopCategory(products.find((product) => product.id === 'business-cards')), 'Business')
  assert.equal(resolveShopCategory(pvcBannerProduct), 'Signs & Advertising')
  assert.equal(resolveShopCategory(products.find((product) => product.id === 'printed-tshirt')), 'Apparel')
  assert.equal(resolveShopCategory(flagsProduct), 'Events')
  assert.equal(resolveShopCategory(gazebosProduct), 'Events')
  assert.equal(resolveShopCategory(products.find((product) => product.id === 'media-services')), 'Photo & Video')
})

test('filterProductsByShopCategory: "All" (or no filter) returns every product, unfiltered', () => {
  assert.equal(filterProductsByShopCategory(products, 'All').length, products.length)
  assert.equal(filterProductsByShopCategory(products, undefined).length, products.length)
})

test('filterProductsByShopCategory: a specific bucket returns only products mapping to it', () => {
  const events = filterProductsByShopCategory(products, 'Events')
  assert.deepEqual(events.map((product) => product.id).sort(), ['flags', 'gazebos'])
})

test('filterProductsByShopCategory: an empty/malformed product list is handled safely, never throws', () => {
  assert.deepEqual(filterProductsByShopCategory(null, 'All'), [])
  assert.deepEqual(filterProductsByShopCategory(undefined, 'Events'), [])
})

// ── QS-18: hero outcome actions ───────────────────────────────────────

test('heroOutcomes: every "guided" outcome names a real, existing product id in the catalogue', () => {
  const guidedOutcomes = heroOutcomes.filter((outcome) => outcome.kind === 'guided')
  assert.ok(guidedOutcomes.length > 0)
  for (const outcome of guidedOutcomes) {
    const product = products.find((item) => item.id === outcome.productId)
    assert.ok(product, `heroOutcomes entry "${outcome.id}" names a nonexistent productId "${outcome.productId}"`)
  }
})

test('heroOutcomes: every "shop" outcome names a real SHOP_CATEGORIES bucket', () => {
  const shopOutcomes = heroOutcomes.filter((outcome) => outcome.kind === 'shop')
  assert.ok(shopOutcomes.length > 0)
  for (const outcome of shopOutcomes) {
    assert.ok(SHOP_CATEGORIES.includes(outcome.shopCategory), `heroOutcomes entry "${outcome.id}" names "${outcome.shopCategory}", which is not a real Shop bucket`)
  }
})

test('heroOutcomes: exactly 6 outcomes, matching the QS-18 brief\'s compact action count, each with a unique id', () => {
  assert.equal(heroOutcomes.length, 6)
  assert.equal(new Set(heroOutcomes.map((outcome) => outcome.id)).size, 6)
})

// ── QS-18: language mode persistence (src/lib/languageMode.js) ───────
// No `window` exists in this plain Node --test environment - these
// functions must degrade to safe defaults rather than throwing, exactly
// as they already do for SSR (same convention as cartStore.js).

test('loadLanguageMode: defaults to "simple" when window/localStorage is unavailable', () => {
  assert.equal(loadLanguageMode(), 'simple')
})

test('hasSeenLanguageModePrompt: defaults to true (never shows the prompt) when window/localStorage is unavailable - fails safe, not naggy', () => {
  assert.equal(hasSeenLanguageModePrompt(), true)
})

test('saveLanguageMode / markLanguageModePromptSeen: no-ops without throwing when window/localStorage is unavailable', () => {
  assert.doesNotThrow(() => saveLanguageMode('pro'))
  assert.doesNotThrow(() => markLanguageModePromptSeen())
})
