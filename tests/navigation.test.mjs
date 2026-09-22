import assert from 'node:assert/strict'
import test from 'node:test'
import { DEFAULT_PAGE, resolveHeroOutcomeNavigation } from '../src/lib/navigation.js'
import { heroOutcomes } from '../src/data/products.js'
import { SHOP_CATEGORIES } from '../src/lib/productContent.js'

// ── QS-18A: Home/Shop view split ──────────────────────────────────────
// App.jsx itself is not unit-tested (no jsdom/React-rendering harness in
// this repo - see QS-17C/QS-18's notes on FieldControl.jsx for the same
// constraint), so these tests exercise the one piece of real DECISION
// LOGIC the Home/Shop split introduced - resolveHeroOutcomeNavigation() -
// against the REAL heroOutcomes data, not a synthetic fixture. The
// interactive behavior this decision feeds (App.jsx's goHome()/goShop()/
// goToQuickPoints()/openGuided() actually calling setPage/
// scrollIntoView, the JSX literally not rendering #shop/#configure/
// #product/#quick-points on Home, ProofGallery's "Explore collection
// options" switching to Shop then scrolling to Quick Points instead of
// a dead #quick-points anchor) was verified with a live dev server +
// Playwright: page load -> {hasShop:false, hasConfigure:false,
// hasProductHub:false, hasQuickPoints:false} on Home; clicking each of
// the 6 hero outcomes (post QS-18A correction: only "Print something"
// still bypasses Shop), the header's Shop/Home/Quick Points buttons,
// Send documents, the bag-button and ProofGallery's collection-options
// button all landed on the correct heading/filter/section with zero
// console errors, at 360/390/1440px.

test('DEFAULT_PAGE is "home" - Home renders first, matching App.jsx\'s useState(DEFAULT_PAGE)', () => {
  assert.equal(DEFAULT_PAGE, 'home')
})

test('resolveHeroOutcomeNavigation: a "shop" outcome resolves to a real SHOP_CATEGORIES bucket, never an invented one', () => {
  for (const outcome of heroOutcomes.filter((item) => item.kind === 'shop')) {
    const nav = resolveHeroOutcomeNavigation(outcome)
    assert.equal(nav.type, 'shop')
    assert.ok(SHOP_CATEGORIES.includes(nav.shopFilter), `"${outcome.id}" resolved to "${nav.shopFilter}", not a real Shop bucket`)
  }
})

test('resolveHeroOutcomeNavigation: "Get my business ready" / "Promote my business" / "Prepare for an event" / "Clothing & merch" / "Photo & video" all map to their exact agreed Shop filters', () => {
  const byId = Object.fromEntries(heroOutcomes.map((outcome) => [outcome.id, outcome]))
  // QS-18A correction: "Get my business ready" and "Clothing & merch"
  // moved from a single guided product to Shop - each outcome can be
  // satisfied by more than one product, so the customer picks rather
  // than the outcome silently collapsing into one.
  assert.equal(resolveHeroOutcomeNavigation(byId['business-ready']).shopFilter, 'Business')
  assert.equal(resolveHeroOutcomeNavigation(byId.promote).shopFilter, 'Signs & Advertising')
  assert.equal(resolveHeroOutcomeNavigation(byId.event).shopFilter, 'Events')
  assert.equal(resolveHeroOutcomeNavigation(byId.apparel).shopFilter, 'Apparel')
  assert.equal(resolveHeroOutcomeNavigation(byId.media).shopFilter, 'Photo & Video')
})

test('resolveHeroOutcomeNavigation: a "guided" outcome resolves to type "guided" with a real productId/journeyId - never routed through Shop\'s filter state', () => {
  for (const outcome of heroOutcomes.filter((item) => item.kind === 'guided')) {
    const nav = resolveHeroOutcomeNavigation(outcome)
    assert.equal(nav.type, 'guided')
    assert.equal(nav.productId, outcome.productId)
    assert.equal(nav.journeyId, outcome.journeyId)
    assert.equal(nav.shopFilter, undefined)
  }
})

test('resolveHeroOutcomeNavigation: "Print something" specifically bypasses Shop - resolves straight to the document guided flow', () => {
  const printOutcome = heroOutcomes.find((outcome) => outcome.id === 'print')
  assert.ok(printOutcome, 'heroOutcomes must still define the "print" entry')
  const nav = resolveHeroOutcomeNavigation(printOutcome)
  assert.deepEqual(nav, { type: 'guided', productId: 'a4-print', journeyId: 'document-guided', preset: {} })
})

test('resolveHeroOutcomeNavigation: "Print something" is the ONLY hero outcome that still bypasses Shop into a guided flow - every other outcome routes through Shop\'s filter', () => {
  const guidedOutcomes = heroOutcomes.filter((outcome) => resolveHeroOutcomeNavigation(outcome).type === 'guided')
  assert.deepEqual(guidedOutcomes.map((outcome) => outcome.id), ['print'])
})

test('resolveHeroOutcomeNavigation: an outcome missing/with an unknown "kind" resolves to null rather than guessing a destination', () => {
  assert.equal(resolveHeroOutcomeNavigation({ id: 'bogus' }), null)
  assert.equal(resolveHeroOutcomeNavigation({ id: 'bogus', kind: 'teleport' }), null)
  assert.equal(resolveHeroOutcomeNavigation(null), null)
  assert.equal(resolveHeroOutcomeNavigation(undefined), null)
})

test('resolveHeroOutcomeNavigation: a "shop" outcome with no shopCategory falls back to "All", never an undefined filter', () => {
  const nav = resolveHeroOutcomeNavigation({ kind: 'shop' })
  assert.equal(nav.shopFilter, 'All')
})
