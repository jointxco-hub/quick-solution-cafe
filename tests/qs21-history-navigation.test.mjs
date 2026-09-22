import assert from 'node:assert/strict'
import test from 'node:test'
import {
  buildHistoryState,
  resolveHistoryAction,
  resolvePopStateNavigation,
  resolveOfferContextAfterHistoryRestore
} from '../src/lib/navigation.js'

// ── QS-21 final pass: lightweight History API support ──────────────────
// App.jsx itself is not unit-tested (no jsdom/React-rendering harness -
// see navigation.test.mjs's own note), so these exercise the pure
// DECISION logic App.jsx's history-sync effect and popstate listener
// apply. DOM-level behavior (actual pushState/replaceState/popstate
// call counts, real browser Back/Forward, scroll position, "no reload
// required") was verified with a live dev server + Playwright at
// 1440/390px - see the QS-21 final-pass report.

test('buildHistoryState: the canonical shape has exactly 4 fields - never configs, cart, pricing, files, Offer payloads, orderMode or Quick Configure state', () => {
  const state = buildHistoryState('product', { selectedProductId: 'pvc-banner', shopFilter: 'Signs & Advertising', shopMode: 'products' })
  assert.deepEqual(Object.keys(state).sort(), ['page', 'selectedProductId', 'shopFilter', 'shopMode'])
})

test('buildHistoryState: selectedProductId is only ever kept for page "product" - Home/Shop always carry null, never a stale id', () => {
  assert.equal(buildHistoryState('home', { selectedProductId: 'pvc-banner' }).selectedProductId, null)
  assert.equal(buildHistoryState('shop', { selectedProductId: 'pvc-banner' }).selectedProductId, null)
  assert.equal(buildHistoryState('product', { selectedProductId: 'pvc-banner' }).selectedProductId, 'pvc-banner')
})

test('buildHistoryState: an unknown/missing page value safely defaults to "home", not a crash or an invented 4th page', () => {
  assert.equal(buildHistoryState('bogus').page, 'home')
  assert.equal(buildHistoryState(undefined).page, 'home')
})

test('buildHistoryState: missing shopFilter/shopMode default to "All"/"products", never undefined', () => {
  const state = buildHistoryState('shop', {})
  assert.equal(state.shopFilter, 'All')
  assert.equal(state.shopMode, 'products')
})

test('resolveHistoryAction: a null previousState (first mount) always resolves to "replace" - the one-time initial entry, never a duplicate push', () => {
  assert.equal(resolveHistoryAction(null, buildHistoryState('home')), 'replace')
})

test('resolveHistoryAction: Home -> Shop is a "push" (page changed) - matches "Home -> Shop adds one entry"', () => {
  const action = resolveHistoryAction(buildHistoryState('home'), buildHistoryState('shop', { shopFilter: 'All', shopMode: 'products' }))
  assert.equal(action, 'push')
})

test('resolveHistoryAction: Shop -> Product is a "push" (page changed) - matches "Shop -> Product adds one entry"', () => {
  const shop = buildHistoryState('shop', { shopFilter: 'Signs & Advertising', shopMode: 'products' })
  const product = buildHistoryState('product', { selectedProductId: 'pvc-banner', shopFilter: 'Signs & Advertising', shopMode: 'products' })
  assert.equal(resolveHistoryAction(shop, product), 'push')
})

test('resolveHistoryAction: switching to a DIFFERENT product while already on Product Detail is also a "push" - a genuinely new product view', () => {
  const productA = buildHistoryState('product', { selectedProductId: 'pvc-banner' })
  const productB = buildHistoryState('product', { selectedProductId: 'vinyl-stickers' })
  assert.equal(resolveHistoryAction(productA, productB), 'push')
})

test('resolveHistoryAction: a Shop category/tab click (filter or mode changes, page/product do not) is a "replace" - never spams the back stack, matches "Shop filter/Offers tab preserved through Back"', () => {
  const before = buildHistoryState('shop', { shopFilter: 'All', shopMode: 'products' })
  const afterFilter = buildHistoryState('shop', { shopFilter: 'Business', shopMode: 'products' })
  const afterMode = buildHistoryState('shop', { shopFilter: 'Business', shopMode: 'offers' })
  assert.equal(resolveHistoryAction(before, afterFilter), 'replace')
  assert.equal(resolveHistoryAction(afterFilter, afterMode), 'replace')
})

test('resolveHistoryAction: an identical canonical state resolves to "none" - covers Guided<->Full options, preset/config picks and Quick Configure open/close, none of which are ever part of this shape at all', () => {
  const state = buildHistoryState('product', { selectedProductId: 'pvc-banner', shopFilter: 'Signs & Advertising', shopMode: 'products' })
  const sameStateDespiteUnrelatedAppChanges = buildHistoryState('product', { selectedProductId: 'pvc-banner', shopFilter: 'Signs & Advertising', shopMode: 'products' })
  assert.equal(resolveHistoryAction(state, sameStateDespiteUnrelatedAppChanges), 'none')
})

test('resolvePopStateNavigation: missing/malformed state (null, undefined, wrong type, unknown page) all fall back safely to Home', () => {
  assert.deepEqual(resolvePopStateNavigation(null), buildHistoryState('home'))
  assert.deepEqual(resolvePopStateNavigation(undefined), buildHistoryState('home'))
  assert.deepEqual(resolvePopStateNavigation('not-an-object'), buildHistoryState('home'))
  assert.deepEqual(resolvePopStateNavigation(42), buildHistoryState('home'))
  assert.deepEqual(resolvePopStateNavigation({ page: 'teleport' }), buildHistoryState('home'))
  assert.deepEqual(resolvePopStateNavigation({}), buildHistoryState('home'))
})

test('resolvePopStateNavigation: a well-formed real entry round-trips exactly', () => {
  const original = buildHistoryState('product', { selectedProductId: 'gazebos', shopFilter: 'Events', shopMode: 'offers' })
  assert.deepEqual(resolvePopStateNavigation(original), original)
})

test('resolvePopStateNavigation: a malformed selectedProductId/shopFilter/shopMode on an otherwise-real entry is defaulted, not thrown', () => {
  const resolved = resolvePopStateNavigation({ page: 'product', selectedProductId: 42, shopFilter: null, shopMode: 'bogus' })
  assert.equal(resolved.page, 'product')
  assert.equal(resolved.selectedProductId, null)
  assert.equal(resolved.shopFilter, 'All')
  assert.equal(resolved.shopMode, 'products')
})

test('resolveOfferContextAfterHistoryRestore: no context stays null', () => {
  assert.equal(resolveOfferContextAfterHistoryRestore(null, buildHistoryState('product', { selectedProductId: 'pvc-banner' })), null)
})

test('resolveOfferContextAfterHistoryRestore: a context survives a restore that is STILL Product Detail for the exact same product', () => {
  const context = { source: 'offer', offerId: 'business-starter', offerItemId: 'line-1', productId: 'pvc-banner' }
  const restored = buildHistoryState('product', { selectedProductId: 'pvc-banner' })
  assert.deepEqual(resolveOfferContextAfterHistoryRestore(context, restored), context)
})

test('resolveOfferContextAfterHistoryRestore: clears when the restore lands on a DIFFERENT product, Shop, or Home - never leaks into an unrelated view or another Offer', () => {
  const context = { source: 'offer', offerId: 'business-starter', offerItemId: 'line-1', productId: 'pvc-banner' }
  assert.equal(resolveOfferContextAfterHistoryRestore(context, buildHistoryState('product', { selectedProductId: 'vinyl-stickers' })), null)
  assert.equal(resolveOfferContextAfterHistoryRestore(context, buildHistoryState('shop', { shopMode: 'offers' })), null)
  assert.equal(resolveOfferContextAfterHistoryRestore(context, buildHistoryState('home')), null)
})

test('resolveOfferContextAfterHistoryRestore: an invalid/missing restored state also clears rather than assuming the context still applies', () => {
  const context = { source: 'offer', offerId: 'business-starter', offerItemId: 'line-1', productId: 'pvc-banner' }
  assert.equal(resolveOfferContextAfterHistoryRestore(context, null), null)
  assert.equal(resolveOfferContextAfterHistoryRestore(context, undefined), null)
})
