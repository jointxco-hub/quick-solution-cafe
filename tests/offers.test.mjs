import assert from 'node:assert/strict'
import test from 'node:test'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import {
  resolveOfferItem,
  calculateOfferPrice,
  validateOffer,
  resolveActiveOffers,
  resolveOffersForCategory,
  resolveOfferDisplayName,
  resolveOfferDisplayDescription,
  resolveOfferCartLines,
  resolveOfferPriceDisplay
} from '../src/lib/offers.js'
import { calculateProductPrice, getDefaultConfig, formatMoney } from '../src/lib/pricing.js'
import { products, offers } from '../src/data/products.js'

const offersSourcePath = fileURLToPath(new URL('../src/lib/offers.js', import.meta.url))
const readOffersSource = () => readFileSync(offersSourcePath, 'utf8')

// Real catalogue data throughout - not a synthetic fixture - so a
// typo'd product/preset id in the actual curated offer set fails these
// tests directly, the same discipline QS-17's preset tests already
// established for resolveProductPresets().
const businessCards = products.find((product) => product.id === 'business-cards')
const pvcBanner = products.find((product) => product.id === 'pvc-banner')
const vinylStickers = products.find((product) => product.id === 'vinyl-stickers')
const flags = products.find((product) => product.id === 'flags')
const gazebos = products.find((product) => product.id === 'gazebos')
const mediaServices = products.find((product) => product.id === 'media-services')

const businessStarter = offers.find((offer) => offer.id === 'business-starter')
const promotionPack = offers.find((offer) => offer.id === 'promotion-pack')
const eventStarter = offers.find((offer) => offer.id === 'event-starter')

test('sanity: the curated QS-20 offer set exists with the expected ids', () => {
  assert.ok(businessStarter, 'business-starter must exist')
  assert.ok(promotionPack, 'promotion-pack must exist')
  assert.ok(eventStarter, 'event-starter must exist')
})

// ── QS-20 final review: flags/gazebos production rollout confirmed ─────
// Business decision: production now carries the QS-14 supplier-pricing
// foundation, flags/gazebos' base catalogue rows, server-authoritative
// supplier pricing and QS-17B's Product Hub + presets - the old
// "not yet published" fallback state is stale. Flipped to active:true
// in src/data/products.js; these tests pin that decision so it can't
// silently regress.

test('flags/gazebos fallback is now active - the QS-17 "production does not carry these rows" assumption is confirmed stale and reversed', () => {
  assert.equal(flags.active, true)
  assert.equal(gazebos.active, true)
})

test('flags/gazebos pricing/variants are byte-for-byte unchanged by the active-flag flip - only the availability flag moved, per instruction ("do not change any pricing/variants")', () => {
  assert.equal(flags.pricing.strategy, 'SUPPLIER_MARGIN')
  assert.equal(flags.pricing.variants['telescopic-3m-ss-full'].price, 1190)
  assert.equal(gazebos.pricing.strategy, 'SUPPLIER_MARGIN')
  assert.equal(gazebos.pricing.variants['aluminium-3x3-deluxe-full'].price, 8900)
})

// ── resolveOfferItem ───────────────────────────────────────────────────

test('resolveOfferItem: resolves a plain product+config item correctly', () => {
  const item = { productId: 'business-cards', config: { quantity: '250', stock: 'thick', finish: 'matt', artwork: 'ready' }, quantity: 1 }
  const resolved = resolveOfferItem(item, products)
  assert.equal(resolved.product.id, 'business-cards')
  assert.deepEqual(resolved.config, item.config)
  assert.equal(resolved.error, undefined)
})

test('resolveOfferItem: resolves a presetId to the exact real preset config, never a copy that drifts from it', () => {
  const item = { productId: 'flags', presetId: 'flag-3m-telescopic-full', quantity: 1 }
  const resolved = resolveOfferItem(item, products)
  assert.equal(resolved.product.id, 'flags')
  assert.equal(resolved.preset.id, 'flag-3m-telescopic-full')
  assert.deepEqual(resolved.config, { variant: 'telescopic-3m-ss-full', quantity: 2, artwork: null })
})

test('resolveOfferItem: an item with neither presetId nor config falls back to the product\'s own field defaults, never an invented configuration', () => {
  const item = { productId: 'business-cards', quantity: 1 }
  const resolved = resolveOfferItem(item, products)
  assert.deepEqual(resolved.config, getDefaultConfig(businessCards, {}))
})

test('resolveOfferItem: an unknown product is rejected safely, never silently priced', () => {
  const resolved = resolveOfferItem({ productId: 'not-a-real-product', quantity: 1 }, products)
  assert.equal(resolved.product, undefined)
  assert.match(resolved.error, /Unknown product/)
})

test('resolveOfferItem: an unknown or invalid preset id is rejected safely', () => {
  const resolved = resolveOfferItem({ productId: 'flags', presetId: 'not-a-real-preset', quantity: 1 }, products)
  assert.match(resolved.error, /Unknown or invalid preset/)
})

test('resolveOfferItem: a preset id that is real on a DIFFERENT product than the one named is rejected - presets are resolved per-product, never globally', () => {
  const resolved = resolveOfferItem({ productId: 'gazebos', presetId: 'flag-3m-telescopic-full', quantity: 1 }, products)
  assert.match(resolved.error, /Unknown or invalid preset/)
})

test('resolveOfferItem: a malformed item (null, non-object, missing productId) is rejected safely, never throws', () => {
  assert.match(resolveOfferItem(null, products).error, /not an object/)
  assert.match(resolveOfferItem('flags', products).error, /not an object/)
  assert.match(resolveOfferItem({}, products).error, /no productId/)
  assert.match(resolveOfferItem({ productId: 'business-cards', config: 'not-an-object' }, products).error, /config .* is not an object/)
})

// ── calculateOfferPrice: totals match the real pricing engine exactly ──

test('calculateOfferPrice: business-starter total equals the exact sum of calculateProductPrice() on each real line - no independent price table', () => {
  const result = calculateOfferPrice(businessStarter, products)
  const cardsItem = businessStarter.items.find((item) => item.id === 'cards')
  const bannerItem = businessStarter.items.find((item) => item.id === 'shop-banner')
  const expectedTotal = calculateProductPrice(businessCards, cardsItem.config).total + calculateProductPrice(pvcBanner, bannerItem.config).total
  assert.equal(result.valid, true)
  assert.equal(result.quoteRequired, false)
  assert.equal(result.total, expectedTotal)
  assert.equal(result.total, 815)
})

test('calculateOfferPrice: promotion-pack total equals the exact sum of its two real lines', () => {
  const result = calculateOfferPrice(promotionPack, products)
  const bannerItem = promotionPack.items.find((item) => item.id === 'promo-banner')
  const stickersItem = promotionPack.items.find((item) => item.id === 'window-stickers')
  const expectedTotal = calculateProductPrice(pvcBanner, bannerItem.config).total + calculateProductPrice(vinylStickers, stickersItem.config).total
  assert.equal(result.total, expectedTotal)
  assert.equal(result.total, 1260)
})

test('calculateOfferPrice: event-starter (gazebo preset + flag preset + banner) totals the exact sum of each real preset/config price - pinned at R12,090 (current default composition, every item included)', () => {
  const result = calculateOfferPrice(eventStarter, products)
  const gazeboTotal = calculateProductPrice(gazebos, { variant: 'aluminium-3x3-deluxe-full', quantity: 1, artwork: null }).total
  const flagTotal = calculateProductPrice(flags, { variant: 'telescopic-3m-ss-full', quantity: 2, artwork: null }).total
  const bannerItem = eventStarter.items.find((item) => item.id === 'event-banner')
  assert.equal(bannerItem.optional, true, 'the banner line must still be the optional one this whole scenario depends on')
  const bannerTotal = calculateProductPrice(pvcBanner, bannerItem.config).total
  assert.equal(result.total, gazeboTotal + flagTotal + bannerTotal)
  assert.equal(result.total, 12090)
  assert.equal(result.quoteRequired, false)
})

test('calculateOfferPrice: event-starter with its required products made unavailable fails safely (quoteRequired, total null) instead of silently dropping the unavailable line', () => {
  const catalogWithInactiveGazebos = products.map((product) => product.id === 'gazebos' ? { ...product, active: false } : product)
  const result = calculateOfferPrice(eventStarter, catalogWithInactiveGazebos)
  assert.equal(result.valid, false)
  assert.equal(result.quoteRequired, true)
  assert.equal(result.total, null)
  assert.ok(result.lines.find((line) => line.id === 'gazebo').error, 'the now-unavailable required line must report an error, not silently vanish')
})

test('calculateOfferPrice: child quantity multiplies the line total correctly (a repeat count of the resolved line, not merged into config)', () => {
  const offer = { id: 'x', name: 'X', items: [{ id: 'banner', productId: 'pvc-banner', config: { width: 1, height: 1, material: 'standard', finishing: 'none', artwork: 'ready', turnaround: 'standard' }, quantity: 3 }] }
  const singleUnit = calculateProductPrice(pvcBanner, offer.items[0].config).total
  const result = calculateOfferPrice(offer, products)
  assert.equal(result.lines[0].unitTotal, singleUnit)
  assert.equal(result.lines[0].lineTotal, singleUnit * 3)
  assert.equal(result.total, singleUnit * 3)
})

test('calculateOfferPrice: quoteRequired propagates from a single child item (ENQUIRY strategy) to the whole offer, total becomes unavailable rather than under-totaling', () => {
  const offer = {
    id: 'mixed', name: 'Mixed',
    items: [
      { id: 'cards', productId: 'business-cards', config: { quantity: '100', stock: 'standard', finish: 'standard', artwork: 'ready' }, quantity: 1 },
      { id: 'shoot', productId: 'media-services', config: {}, quantity: 1 }
    ]
  }
  const result = calculateOfferPrice(offer, products)
  assert.equal(result.quoteRequired, true)
  assert.equal(result.total, null)
  assert.equal(result.lines[0].quoteRequired, false)
  assert.equal(result.lines[0].lineTotal, 180)
  assert.equal(result.lines[1].quoteRequired, true)
  assert.equal(result.lines[1].lineTotal, null)
})

test('calculateOfferPrice: a missing product/preset marks the offer invalid and quoteRequired, and never contributes a silent 0 to the total', () => {
  const offer = { id: 'broken', name: 'Broken', items: [{ id: 'a', productId: 'not-real', quantity: 1 }, { id: 'b', productId: 'business-cards', config: { quantity: '100', stock: 'standard', finish: 'standard', artwork: 'ready' }, quantity: 1 }] }
  const result = calculateOfferPrice(offer, products)
  assert.equal(result.valid, false)
  assert.equal(result.quoteRequired, true)
  assert.equal(result.total, null)
  assert.ok(result.lines[0].error)
  assert.equal(result.lines[1].lineTotal, 180, 'the other, valid line still resolves independently for debugging/UI purposes')
})

test('calculateOfferPrice: an empty items array is invalid, not priced as a free R0 offer', () => {
  const result = calculateOfferPrice({ id: 'empty', name: 'Empty', items: [] }, products)
  assert.equal(result.valid, false)
  assert.equal(result.quoteRequired, true)
  assert.equal(result.total, null)
})

test('calculateOfferPrice: no internal/supplier pricing field is ever exposed on a line - only total/summary/quoteRequired-shaped customer-safe data', () => {
  const result = calculateOfferPrice(eventStarter, products)
  const serialized = JSON.stringify(result)
  assert.ok(!/referencePrice/i.test(serialized))
  assert.ok(!/marginRate/i.test(serialized))
  assert.ok(!/supplierCost/i.test(serialized))
  assert.ok(!/sourceUrl/i.test(serialized))
})

// ── validateOffer / resolveActiveOffers ────────────────────────────────

test('validateOffer: rejects malformed offer shapes (no id, no name, no items) safely', () => {
  assert.equal(validateOffer(null, products).valid, false)
  assert.equal(validateOffer({}, products).valid, false)
  assert.equal(validateOffer({ id: 'x' }, products).valid, false)
  assert.equal(validateOffer({ id: 'x', name: 'X' }, products).valid, false)
  assert.equal(validateOffer({ id: 'x', name: 'X', items: [] }, products).valid, false)
})

test('validateOffer: the real curated offers (business-starter, promotion-pack, event-starter) are all structurally and semantically valid', () => {
  assert.equal(validateOffer(businessStarter, products).valid, true)
  assert.equal(validateOffer(promotionPack, products).valid, true)
  assert.equal(validateOffer(eventStarter, products).valid, true)
})

test('resolveActiveOffers: all three curated offers (business-starter, promotion-pack, event-starter) are now active and resolve - flags/gazebos are live', () => {
  const active = resolveActiveOffers(offers, products)
  assert.ok(active.some((offer) => offer.id === 'business-starter'))
  assert.ok(active.some((offer) => offer.id === 'promotion-pack'))
  assert.ok(active.some((offer) => offer.id === 'event-starter'), 'event-starter must now be active - flags/gazebos production rollout is confirmed')
  assert.equal(active.length, 3, 'exactly three curated offers in v1 - no fourth "Market Setup" per explicit instruction')
})

test('resolveActiveOffers: an offer whose required product later becomes unavailable again fails/disables safely rather than staying silently active', () => {
  const catalogWithInactiveFlags = products.map((product) => product.id === 'flags' ? { ...product, active: false } : product)
  const active = resolveActiveOffers(offers, catalogWithInactiveFlags)
  assert.ok(!active.some((offer) => offer.id === 'event-starter'), 'event-starter needs flags - must be excluded the moment flags is unavailable again')
  assert.ok(active.some((offer) => offer.id === 'business-starter'), 'unrelated offers are unaffected')
})

test('resolveActiveOffers: an offer referencing a product no longer in the given catalogue is silently dropped, never shown broken', () => {
  const shrunkCatalog = products.filter((product) => product.id !== 'pvc-banner')
  const active = resolveActiveOffers(offers, shrunkCatalog)
  assert.ok(!active.some((offer) => offer.id === 'business-starter'), 'business-starter needs pvc-banner')
  assert.ok(!active.some((offer) => offer.id === 'promotion-pack'), 'promotion-pack needs pvc-banner')
})

test('resolveOffersForCategory: filters by the exact SHOP_CATEGORIES vocabulary an offer\'s category uses', () => {
  const active = resolveActiveOffers(offers, products)
  assert.deepEqual(resolveOffersForCategory(active, 'Business').map((offer) => offer.id), ['business-starter'])
  assert.deepEqual(resolveOffersForCategory(active, 'Signs & Advertising').map((offer) => offer.id), ['promotion-pack'])
  assert.deepEqual(resolveOffersForCategory(active, 'Events').map((offer) => offer.id), ['event-starter'], 'event-starter is now active, so Events surfaces it')
  assert.equal(resolveOffersForCategory(active, 'All').length, active.length)
})

// ── Simple/Pro presentation never touches pricing ───────────────────────

test('resolveOfferDisplayName/Description: Simple and Pro modes never change calculateOfferPrice()\'s totals or line configs - presentation only', () => {
  const simpleResult = calculateOfferPrice(businessStarter, products)
  const proResult = calculateOfferPrice(businessStarter, products)
  assert.deepEqual(simpleResult, proResult)

  const simpleName = resolveOfferDisplayName(businessStarter, 'simple')
  const proName = resolveOfferDisplayName(businessStarter, 'pro')
  // These offers have no simpleName/simpleDescription override yet (no
  // high-friction term identified for them, matching QS-18's own "do
  // not rewrite everything" restraint) - both modes fall back to the
  // same existing text, proving the fallback never breaks rather than
  // asserting a cosmetic difference that doesn't exist yet.
  assert.equal(simpleName, businessStarter.name)
  assert.equal(proName, businessStarter.name)
  assert.equal(resolveOfferDisplayDescription(businessStarter, 'simple'), businessStarter.description)
})

test('resolveOfferDisplayName: falls back to the offer\'s real name/description when no simpleName/simpleDescription is set, never blank', () => {
  const offer = { id: 'x', name: 'X Pack', description: 'A description.', items: [] }
  assert.equal(resolveOfferDisplayName(offer, 'simple'), 'X Pack')
  assert.equal(resolveOfferDisplayDescription(offer, 'pro'), 'A description.')
})

// ── resolveOfferCartLines: customisation (optional removal + quantity) ──

test('resolveOfferCartLines: with no customization, matches calculateOfferPrice() exactly', () => {
  const plain = calculateOfferPrice(eventStarter, products)
  const customized = resolveOfferCartLines(eventStarter, products, {})
  assert.deepEqual(customized, plain)
})

test('resolveOfferCartLines: excluding the optional PVC Banner drops event-starter from R12,090 to exactly R11,280 - the QS-20 final review\'s own pinned example', () => {
  const withBanner = calculateOfferPrice(eventStarter, products)
  const withoutBanner = resolveOfferCartLines(eventStarter, products, { excludedItemIds: ['event-banner'] })
  assert.equal(withBanner.total, 12090)
  assert.equal(withoutBanner.lines.length, 2)
  assert.ok(!withoutBanner.lines.some((line) => line.id === 'event-banner'))
  assert.equal(withoutBanner.total, 11280)
})

test('resolveOfferCartLines: a NON-optional item cannot be excluded even if its id is passed - only items explicitly marked optional:true can be dropped', () => {
  const result = resolveOfferCartLines(eventStarter, products, { excludedItemIds: ['gazebo'] })
  assert.equal(result.lines.length, 3, 'the required gazebo line must still be present')
})

test('resolveOfferCartLines: a quantity override changes that line\'s total and the offer total, independent of other lines', () => {
  const result = resolveOfferCartLines(businessStarter, products, { quantityOverrides: { 'shop-banner': 2 } })
  const bannerLine = result.lines.find((line) => line.id === 'shop-banner')
  const cardsLine = result.lines.find((line) => line.id === 'cards')
  assert.equal(bannerLine.quantity, 2)
  assert.equal(bannerLine.lineTotal, 635 * 2)
  assert.equal(cardsLine.lineTotal, 180, 'unrelated line is unaffected')
  assert.equal(result.total, 180 + 635 * 2)
})

// ── QS-20 final review: total-display wording (never "From") ───────────

test('resolveOfferPriceDisplay: a fixed-composition offer with an optional item shows the CURRENT total plainly, never "From" - and adds a note that it includes removable items', () => {
  const result = calculateOfferPrice(eventStarter, products)
  const display = resolveOfferPriceDisplay(eventStarter, result)
  assert.equal(display.priceText, formatMoney(12090), 'price text is exactly the formatted current total - no prefix, no suffix')
  assert.ok(!display.priceText.toLowerCase().includes('from'), `price text must not say "From": "${display.priceText}"`)
  assert.equal(display.quoteRequired, false)
  assert.ok(display.note, 'an offer with an optional item must explain the total includes removable items')
  assert.match(display.note.toLowerCase(), /optional/)
})

test('resolveOfferPriceDisplay: an offer with NO optional items shows the total with no note at all - nothing to explain', () => {
  const result = calculateOfferPrice(businessStarter, products)
  const display = resolveOfferPriceDisplay(businessStarter, result)
  assert.ok(!display.priceText.toLowerCase().includes('from'))
  assert.equal(display.note, null)
})

test('resolveOfferPriceDisplay: quoteRequired offers show "Quote required", never a "From R0" or similar placeholder number', () => {
  const offer = { id: 'q', name: 'Q', items: [{ id: 'a', productId: 'media-services', config: {}, quantity: 1 }] }
  const result = calculateOfferPrice(offer, products)
  const display = resolveOfferPriceDisplay(offer, result)
  assert.equal(display.priceText, 'Quote required')
  assert.equal(display.quoteRequired, true)
  assert.equal(display.note, null)
})

// ── QS-20 final review: repeat quantity expands into separate cart lines ─
// (the actual cart-line construction is App.jsx's addOfferToCart(), not
// unit-tested here - no rendering harness in this repo, see QS-17C's
// precedent - but its correctness depends entirely on each line
// carrying its own per-UNIT config/unitTotal, which these two functions
// guarantee and which was additionally verified live via Playwright:
// bumping a line to quantity 2 in the UI and adding to cart produced
// TWO separate R810 cart entries, not one R1620 entry with a single-
// unit config - see the QS-20 report.)

test('calculateOfferPrice/resolveOfferCartLines: every line always carries BOTH its true per-unit total (unitTotal) and its own resolved per-unit config - the two pieces addOfferToCart() needs to build N independently-verifiable cart entries, never one line with a mismatched total/config pair', () => {
  const result = resolveOfferCartLines(businessStarter, products, { quantityOverrides: { 'shop-banner': 3 } })
  const bannerLine = result.lines.find((line) => line.id === 'shop-banner')
  assert.equal(bannerLine.quantity, 3)
  assert.equal(bannerLine.unitTotal, 635, 'unitTotal is always the single-unit price, regardless of repeat count')
  assert.deepEqual(bannerLine.config, { width: 1.5, height: 1, material: 'standard', finishing: 'hem-eyelets', artwork: 'ready', turnaround: 'standard' }, 'config is always the single-unit configuration - never quantity-mutated')
  assert.equal(bannerLine.lineTotal, 635 * 3, 'lineTotal (display/aggregate only) is unitTotal x quantity - never stored back into config')
})

// ── No duplicate pricing logic ──────────────────────────────────────────

test('offers.js never reimplements pricing - every real total in this file traces back to calculateProductPrice(), confirmed by construction (the module only imports calculateProductPrice/getDefaultConfig from pricing.js, never redefines a price)', () => {
  const offersSource = readOffersSource()
  assert.ok(offersSource.includes("from './pricing.js'"), 'offers.js must import its pricing from pricing.js')
  assert.ok(!/function\s+price[A-Z]/.test(offersSource), 'offers.js must not define its own priceXxx()-style strategy function - that would be a second pricing engine')
})

// ── Single-product flows remain unchanged ───────────────────────────────

test('single-product flow unaffected: calculateProductPrice() called directly (the existing GuidedOrder/ProductConfigurator path) is identical with or without offers.js involved', () => {
  const direct = calculateProductPrice(businessCards, getDefaultConfig(businessCards, {}))
  assert.equal(direct.total, 180)
  assert.equal(direct.metrics.quoteRequired, undefined, 'TIERED strategy never sets quoteRequired - unchanged from before QS-20')
})
