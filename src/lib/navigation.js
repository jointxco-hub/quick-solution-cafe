// QS-18A — pure navigation-intent helpers for the Home/Shop view split.
//
// App.jsx owns the actual React state (page/shopFilter/selectedId/...)
// and is the only thing that ever calls setPage()/setShopFilter()/
// openGuided() etc - these functions only ever COMPUTE where a given
// action should lead, so that decision is unit-testable without
// rendering React. This repo's test suite is plain Node `--test` over
// pure .mjs modules with no jsdom/React-rendering harness (see QS-17C's
// note on FieldControl.jsx for the same reasoning) - extracting the
// decision this way is the smallest way to get real coverage of "which
// outcome goes where" without adding a rendering dependency.

// Home renders first, always - matches heroOutcomes/App.jsx's own
// useState('home') default. Exported so a test can assert the default
// without needing to render <App/>.
export const DEFAULT_PAGE = 'home'

// Top-level browser-path resolution. The storefront's Home/Shop/Product
// state remains the existing lightweight state machine below; this only
// decides which application surface owns an initial browser URL.
export function normalizeAppPathname(pathname = '/') {
  const value = typeof pathname === 'string' && pathname ? pathname : '/'
  const withLeadingSlash = value.startsWith('/') ? value : `/${value}`
  return withLeadingSlash === '/' ? '/' : withLeadingSlash.replace(/\/+$/, '')
}

export function resolveAppRoute({ pathname = '/', hash = '' } = {}) {
  const normalizedPathname = normalizeAppPathname(pathname)

  if (normalizedPathname === '/admin') {
    return { view: 'admin', page: null, pathname: normalizedPathname }
  }
  if (normalizedPathname === '/track' || normalizedPathname.startsWith('/track/')) {
    return { view: 'track', page: null, pathname: normalizedPathname }
  }
  // Retain the original staff bookmark. Tracking keeps precedence, just
  // as it did when App.jsx checked /track before the old hash-based view.
  if (hash === '#admin') {
    return { view: 'admin', page: null, pathname: normalizedPathname }
  }
  if (normalizedPathname === '/') {
    return { view: 'storefront', page: DEFAULT_PAGE, pathname: normalizedPathname }
  }
  if (normalizedPathname === '/shop') {
    return { view: 'storefront', page: 'shop', pathname: normalizedPathname }
  }
  return { view: 'not-found', page: null, pathname: normalizedPathname }
}

// Given one of src/data/products.js's heroOutcomes entries, decides
// where it should navigate. Mirrors exactly the two kinds heroOutcomes
// already declares (see products.js's own comment above that array) -
// never invents a third kind or a new recommendation engine.
//
//   { type: 'shop', shopFilter }              - go to Shop, pre-filtered
//   { type: 'guided', productId, journeyId, preset } - open the guided
//                                                flow directly, bypassing
//                                                Shop's browsing UI
export function resolveHeroOutcomeNavigation(outcome) {
  if (!outcome) return null
  if (outcome.kind === 'shop') {
    return { type: 'shop', shopFilter: outcome.shopCategory || 'All' }
  }
  if (outcome.kind === 'guided') {
    return { type: 'guided', productId: outcome.productId, journeyId: outcome.journeyId, preset: outcome.preset || {} }
  }
  return null
}

// ── QS-21: Shop / Product Detail navigation ───────────────────────────
// page gains a third value, 'product' - a real, dedicated view (Product
// Detail: ProductHub + configuration + related content), not another
// scroll target inside the Shop document. shopFilter/shopMode are
// deliberately never touched by opening a product (see App.jsx's
// openProductDetail()), so "Back" restoring the same category/tab is a
// structural guarantee, not something this needs to compute - there is
// nothing to resolve beyond "page becomes 'shop' again", which is why
// there is no resolveBackToShopState() pure function here: it would be
// an identity function pretending to be a decision.
export const PRODUCT_DETAIL_PAGE = 'product'

// QS-21.1 section 4: whether the desktop sticky/floating Configure
// affordance should render - only on Product Detail itself, and only
// while the real configurator section is not already on screen
// (App.jsx's IntersectionObserver effect owns computing configureInView
// itself; this is just the small, testable DECISION built from it, kept
// out of the JSX condition so it has a name and a test rather than
// being an inline boolean expression).
export function resolveStickyConfigureVisibility(page, configureInView) {
  return page === PRODUCT_DETAIL_PAGE && !configureInView
}

// The floating mobile PDP action belongs only to the gallery portion of
// the page. It disappears as soon as product information enters view and
// cannot reappear over Quick options or the configurator after the media
// region has scrolled away.
export function resolveMobilePdpCtaVisibility({ mediaInView = false, infoInView = false } = {}) {
  return mediaInView && !infoInView
}

// QS-21.5 section 4 — the SAME decision now also gates the MOBILE sticky
// Configure CTA (ProductHub.jsx's .product-hub-sticky-cta), fixing a
// real bug: that element previously had zero state-awareness at all (a
// static always-visible-on-mobile div, unlike the desktop
// .qs21-sticky-configure which was already correctly gated) - so
// "Start guided order" stayed pinned over content even while the
// customer was actively inside the Guided/Full configurator. Reusing
// resolveStickyConfigureVisibility() directly (not a second function)
// for both keeps them mechanically unable to disagree - ProductHub is
// only ever mounted while page is already 'product', so App.jsx passes
// page='product' down for this call unconditionally.

// QS-21.5 section 3 — bottom nav "which destination is current" - a
// small, honest mapping given the app's REAL page state (only
// 'home'/'shop'/'product' exist; there is no dedicated Quick Points
// page, since it is a scroll-anchor within Home, not a page value) and
// the basket being a modal (cartOpen), not a page. Order takes priority
// when the basket is open (it is the thing actually on screen);
// otherwise Shop covers both the catalogue and Product Detail (reached
// only from Shop); Home is the fallback, including for Quick Points'
// current scroll-anchor-only implementation.
export function resolveBottomNavActiveId(page, cartOpen) {
  if (cartOpen) return 'order'
  if (page === 'shop' || page === PRODUCT_DETAIL_PAGE) return 'shop'
  return 'home'
}

// A product's pricing strategy decides whether a minimal Quick Configure
// sheet is SAFE to offer at all - not every product has a config whose
// DEFAULT state is a real, priceable choice, and not every product's
// real "configuration" fits a few curated fields. Deliberately an
// ALLOWLIST, not a blocklist: a strategy this doesn't explicitly know is
// safe defaults to NOT eligible (Product Detail's full flow instead),
// so a future pricing strategy never becomes quick-configurable by
// accident just because nobody remembered to add it here.
//   - PER_AREA / TIERED / CONFIGURABLE: the default config is already a
//     real, safely-priceable choice (confirmed against the real
//     catalogue during the QS-21 audit), and their curated
//     productPage.configPreview fields (productContent.js) are a
//     complete, safe "quick" set.
//   - SUPPLIER_MARGIN (flags/gazebos): excluded even though its default
//     config technically prices - the REAL "configuration" is the
//     variant (a whole style/size/sides/kit axis pick via
//     SupplierVariantConfigurator, not a curated field list; these
//     products' own configPreview only curates 'artwork', since the
//     variant picker already lives elsewhere). Per the QS-21 brief's
//     own allowance ("products that cannot safely support a small
//     quick-config flow may send Configure directly to Product Detail
//     instead") - Product Detail's existing "Quick options" preset
//     cards already cover this product family well.
//   - PER_PAGE (document printing): the default config literally prices
//     as "Page selection needed" (0 pages) until a file is uploaded and
//     read - there is no safe default quantity to quote instantly.
//   - ENQUIRY / PHOTOGRAPHY_SESSION: the real "configuration" is a
//     conversation/session pick, not a few quick fields.
const QUICK_CONFIGURE_SAFE_STRATEGIES = new Set(['PER_AREA', 'TIERED', 'CONFIGURABLE'])

export function resolveQuickConfigureEligibility(product) {
  const strategy = product?.pricing?.strategy
  if (!strategy) return false
  return QUICK_CONFIGURE_SAFE_STRATEGIES.has(strategy)
}

// ── QS-21 / QS-20.1: Offer "Change child" context ─────────────────────
// A small, short-lived, presentation-only marker - never a global
// "pending offer" flag. Built once, at the exact moment "Change" is
// clicked on an Offer line, and handed to App.jsx alongside the
// navigation call that opens Product Detail for that line's product -
// it is never set independently of that navigation, and App.jsx clears
// it on every OTHER navigation (a different product, Back, Home, Shop -
// see openProductDetail()/goBackToShop()/goHome()/goShop() in App.jsx).
// It is consumed exactly once, by the add-to-cart action taken while
// this context is still active, to tag the resulting cart item with the
// same offerId/offerName addOfferToCart() already uses for basket
// grouping - it never touches config, never touches price, never
// reaches the server payload (createQuickSolutionCartOrder only ever
// reads clientItemKey/productKey/configuration off a cart item).
export function buildOfferChangeContext(offer, item) {
  if (!offer?.id || !item?.id || !item?.productId) return null
  return { source: 'offer', offerId: offer.id, offerItemId: item.id, productId: item.productId }
}

// Only ever apply a context's offerId/offerName tag to a cart add for
// the EXACT product the context was built for - if the customer somehow
// adds a different product while a stale context is active (should not
// happen given App.jsx's clearing discipline, but this is the safety
// net), the tag is withheld rather than mis-attributed to the wrong
// offer.
export function resolveOfferContextCartTag(context, productId) {
  if (!context || context.source !== 'offer' || context.productId !== productId) return null
  return { offerId: context.offerId, offerItemId: context.offerItemId }
}

// ── QS-21 final pass: lightweight History API support ─────────────────
// App.jsx owns the actual history.pushState/replaceState/popstate calls
// (see its "history sync" effect and its popstate listener) - these are
// only the pure DECISIONS: what the canonical state object looks like,
// whether a given state change deserves a new back-stack entry, and how
// to safely interpret an incoming popstate event. No React Router, no
// URL/path changes - this only ever manipulates history.state.
export const DEFAULT_SHOP_FILTER = 'All'
export const DEFAULT_SHOP_MODE = 'products'

// The ONLY shape ever pushed/replaced into browser history - deliberately
// tiny, per the brief: never configs, cart, pricing, uploaded files or
// Offer payloads (those all remain ordinary React state, completely
// unaffected by this pass). Also, deliberately, never orderMode/preset/
// taskContext/quickConfigureProduct/productViewContext - keeping those
// OUT of this shape is exactly what makes Guided<->Full toggles, preset
// picks and the Quick Configure overlay never create history entries
// (App.jsx's sync effect only reacts to page/selectedProductId/
// shopFilter/shopMode changing - nothing else it watches can change
// these fields, so nothing else can trigger a push/replace at all).
// selectedProductId is only ever meaningful (non-null) when page is
// 'product' - Home/Shop entries always carry null, never a stale id.
export function buildHistoryState(page, { selectedProductId = null, shopFilter = DEFAULT_SHOP_FILTER, shopMode = DEFAULT_SHOP_MODE } = {}) {
  const safePage = page === 'shop' || page === 'product' ? page : 'home'
  return {
    page: safePage,
    selectedProductId: safePage === 'product' && selectedProductId ? selectedProductId : null,
    shopFilter: shopFilter || DEFAULT_SHOP_FILTER,
    shopMode: shopMode === 'offers' ? 'offers' : DEFAULT_SHOP_MODE
  }
}

// Decides whether moving from one canonical state to another deserves a
// NEW back-stack entry ('push'), should just update the CURRENT entry in
// place ('replace' - e.g. a Shop category/tab click, so Back later lands
// on Shop with the latest filter rather than replaying every click), or
// needs nothing at all ('none' - the two states are identical). A null
// previousState means "no history entry exists yet" - the one-time
// initial-mount case, which is always a replace (see brief section 2:
// "Do NOT immediately push a duplicate entry").
//
//   - page itself changed (Home<->Shop<->Product, including landing on a
//     hero outcome's guided flow) -> push
//   - staying on Product Detail but selectedProductId changed (the
//     context rail switching to a genuinely different product) -> push
//   - anything else that differs (shopFilter, shopMode, or
//     selectedProductId settling while page/selectedProductId above
//     didn't already trigger a push) -> replace
//   - nothing differs -> none
export function resolveHistoryAction(previousState, nextState) {
  if (!previousState) return 'replace'
  if (previousState.page !== nextState.page) return 'push'
  if (nextState.page === 'product' && previousState.selectedProductId !== nextState.selectedProductId) return 'push'
  if (
    previousState.selectedProductId !== nextState.selectedProductId ||
    previousState.shopFilter !== nextState.shopFilter ||
    previousState.shopMode !== nextState.shopMode
  ) return 'replace'
  return 'none'
}

// Safely interprets an incoming popstate event's raw state - a fresh
// page load, a manually-edited/shared URL, or a restored browser session
// can all hand back something missing or malformed. Always returns a
// complete, safe navigation target (via buildHistoryState's own
// defaulting) rather than ever letting App.jsx work with a partial
// object. This does NOT know about the real product catalog, so a
// selectedProductId for a product that no longer exists still passes
// through here - App.jsx checks that separately (it has the catalog)
// before actually restoring page:'product', per the brief's "fall back
// safely" requirement.
export function resolvePopStateNavigation(state) {
  if (!state || typeof state !== 'object') return buildHistoryState('home')
  if (state.page !== 'shop' && state.page !== 'product' && state.page !== 'home') return buildHistoryState('home')
  return buildHistoryState(state.page, {
    selectedProductId: typeof state.selectedProductId === 'string' ? state.selectedProductId : null,
    shopFilter: typeof state.shopFilter === 'string' ? state.shopFilter : DEFAULT_SHOP_FILTER,
    shopMode: state.shopMode === 'offers' ? 'offers' : DEFAULT_SHOP_MODE
  })
}

// QS-20.1 continued: a restored history entry must clear a stale Offer
// "Change" edit context exactly like every other navigation path already
// does (see preserveOrClearOfferContext in App.jsx) - the only new case
// this pass adds is the context surviving a POPSTATE rather than a
// click. Same rule either way: keep it only if the restored page is
// STILL Product Detail for the EXACT product the context was built for;
// clear it for a different product, Shop, Home, or an invalid/missing
// entry - never leaking into an unrelated product view, another Offer,
// or Home. Never touches pricing or the cart.
export function resolveOfferContextAfterHistoryRestore(offerContext, restoredState) {
  if (!offerContext) return null
  if (restoredState?.page !== 'product') return null
  if (restoredState.selectedProductId !== offerContext.productId) return null
  return offerContext
}
