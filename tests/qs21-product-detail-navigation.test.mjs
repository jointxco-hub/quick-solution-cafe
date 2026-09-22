import assert from 'node:assert/strict'
import test from 'node:test'
import {
  PRODUCT_DETAIL_PAGE,
  resolveQuickConfigureEligibility,
  buildOfferChangeContext,
  resolveOfferContextCartTag
} from '../src/lib/navigation.js'
import { deriveRelatedOffers } from '../src/lib/relatedContent.js'
import { products, offers } from '../src/data/products.js'

// ── QS-21: Shop / Product Detail navigation, Quick Configure eligibility,
// and the QS-20.1 Offer-context lifecycle. App.jsx itself is not unit-
// tested (no jsdom/React-rendering harness - see navigation.test.mjs's
// own note), so these exercise the pure decision logic against the REAL
// catalogue/offers data. The pages/transitions this feeds (Shop card ->
// Product Detail, Configure -> Quick Configure sheet or Product Detail
// fallback, Back -> same Shop category, Quick Configure's "Full options"
// handoff, the context rail's active state) were verified with a live
// dev server + Playwright - see the QS-21 report.

test('PRODUCT_DETAIL_PAGE is "product" - matches App.jsx\'s third page value', () => {
  assert.equal(PRODUCT_DETAIL_PAGE, 'product')
})

test('resolveQuickConfigureEligibility: PER_AREA/TIERED/CONFIGURABLE real products are eligible', () => {
  const byId = Object.fromEntries(products.map((product) => [product.id, product]))
  assert.equal(resolveQuickConfigureEligibility(byId['pvc-banner']), true) // PER_AREA
  assert.equal(resolveQuickConfigureEligibility(byId['vinyl-stickers']), true) // PER_AREA
  assert.equal(resolveQuickConfigureEligibility(byId['business-cards']), true) // TIERED
  assert.equal(resolveQuickConfigureEligibility(byId['printed-tshirt']), true) // CONFIGURABLE
})

test('resolveQuickConfigureEligibility: SUPPLIER_MARGIN (flags/gazebos) is NOT eligible - their real configuration is a variant pick, not a curated field list', () => {
  const byId = Object.fromEntries(products.map((product) => [product.id, product]))
  assert.equal(resolveQuickConfigureEligibility(byId.flags), false)
  assert.equal(resolveQuickConfigureEligibility(byId.gazebos), false)
})

test('resolveQuickConfigureEligibility: PER_PAGE (document printing), ENQUIRY and PHOTOGRAPHY_SESSION products are NOT eligible', () => {
  const byId = Object.fromEntries(products.map((product) => [product.id, product]))
  assert.equal(resolveQuickConfigureEligibility(byId['a4-print']), false)
  assert.equal(resolveQuickConfigureEligibility(byId['media-services']), false)
  assert.equal(resolveQuickConfigureEligibility(byId['photo-session']), false)
})

test('resolveQuickConfigureEligibility: a product with no/unknown pricing strategy defaults to NOT eligible (allowlist, not a blocklist)', () => {
  assert.equal(resolveQuickConfigureEligibility({ pricing: {} }), false)
  assert.equal(resolveQuickConfigureEligibility({ pricing: { strategy: 'SOME_FUTURE_STRATEGY' } }), false)
  assert.equal(resolveQuickConfigureEligibility(null), false)
  assert.equal(resolveQuickConfigureEligibility(undefined), false)
})

test('buildOfferChangeContext: builds a well-formed context from a real offer + its own item', () => {
  const offer = offers.find((entry) => entry.id === 'business-starter')
  const item = offer.items[0]
  const context = buildOfferChangeContext(offer, item)
  assert.deepEqual(context, { source: 'offer', offerId: offer.id, offerItemId: item.id, productId: item.productId })
})

test('buildOfferChangeContext: missing offer id, item id or item productId all return null rather than a half-built context', () => {
  const offer = offers.find((entry) => entry.id === 'business-starter')
  const item = offer.items[0]
  assert.equal(buildOfferChangeContext(null, item), null)
  assert.equal(buildOfferChangeContext(offer, null), null)
  assert.equal(buildOfferChangeContext(offer, { id: item.id }), null)
  assert.equal(buildOfferChangeContext({ id: null }, item), null)
})

test('resolveOfferContextCartTag: a context tags an add-to-cart for the EXACT product it was built for', () => {
  const offer = offers.find((entry) => entry.id === 'business-starter')
  const item = offer.items[0]
  const context = buildOfferChangeContext(offer, item)
  const tag = resolveOfferContextCartTag(context, item.productId)
  assert.deepEqual(tag, { offerId: offer.id, offerItemId: item.id })
})

test('resolveOfferContextCartTag: withholds the tag for a different product, a non-offer context, or no context at all - never mis-attributed', () => {
  const offer = offers.find((entry) => entry.id === 'business-starter')
  const item = offer.items[0]
  const context = buildOfferChangeContext(offer, item)
  assert.equal(resolveOfferContextCartTag(context, 'some-other-product'), null)
  assert.equal(resolveOfferContextCartTag({ source: 'other', productId: item.productId }, item.productId), null)
  assert.equal(resolveOfferContextCartTag(null, item.productId), null)
})

test('deriveRelatedOffers: an offer is related to a product iff that product is one of the offer\'s own real items', () => {
  const gazebos = products.find((product) => product.id === 'gazebos')
  const related = deriveRelatedOffers(gazebos, offers)
  assert.deepEqual(related.map((offer) => offer.id), ['event-starter'])
})

test('deriveRelatedOffers: a product with no matching offer returns an empty list, not a fallback guess', () => {
  const photoSession = products.find((product) => product.id === 'photo-session')
  assert.deepEqual(deriveRelatedOffers(photoSession, offers), [])
})

test('deriveRelatedOffers: respects the limit argument and handles missing product/offers input safely', () => {
  const pvcBanner = products.find((product) => product.id === 'pvc-banner')
  // pvc-banner is a real item of business-starter, promotion-pack AND event-starter
  const related = deriveRelatedOffers(pvcBanner, offers, 2)
  assert.equal(related.length, 2)
  assert.deepEqual(deriveRelatedOffers(null, offers), [])
  assert.deepEqual(deriveRelatedOffers(pvcBanner, null), [])
})
