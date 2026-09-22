import React, { useEffect, useMemo, useRef, useState } from 'react'
import Icon from './components/Icon.jsx'
import Header from './components/Header.jsx'
import ProductCard from './components/ProductCard.jsx'
import ProductHub from './components/ProductHub.jsx'
import ProductConfigurator from './components/ProductConfigurator.jsx'
import GuidedOrder from './components/GuidedOrder.jsx'
import PaymentReturn from './components/PaymentReturn.jsx'
import TrackOrder from './components/TrackOrder.jsx'
import ProofGallery from './components/ProofGallery.jsx'
import ComingSoonRail from './components/ComingSoonRail.jsx'
import WorkedWithStrip from './components/WorkedWithStrip.jsx'
import HelpCta from './components/HelpCta.jsx'
import LanguageModePrompt from './components/LanguageModePrompt.jsx'
import AdminProductManager from './admin/AdminProductManager.jsx'
import OrderBasket from './components/OrderBasket.jsx'
import OfferCard from './components/OfferCard.jsx'
import QuickConfigureSheet from './components/QuickConfigureSheet.jsx'
import { loadCart, saveCart } from './lib/cartStore.js'
import { guidedJourneys, heroOutcomes, offers as defaultOffers, products as defaultProducts } from './data/products.js'
import { loadCatalog } from './lib/catalogStore.js'
import { isSupabaseConfigured, loadQuickSolutionCatalog } from './lib/supabaseApi.js'
import { resolveProductDisplayName, resolveProductPriceCue, SHOP_CATEGORIES, filterProductsByShopCategory } from './lib/productContent.js'
import { formatMoney } from './lib/pricing.js'
import { loadLanguageMode, saveLanguageMode, hasSeenLanguageModePrompt, markLanguageModePromptSeen } from './lib/languageMode.js'
import {
  DEFAULT_PAGE,
  resolveHeroOutcomeNavigation,
  resolveQuickConfigureEligibility,
  buildOfferChangeContext,
  resolveOfferContextCartTag,
  buildHistoryState,
  resolveHistoryAction,
  resolvePopStateNavigation,
  resolveOfferContextAfterHistoryRestore,
  resolveStickyConfigureVisibility
} from './lib/navigation.js'
import { resolveActiveOffers, resolveOffersForCategory, resolveOfferDisplayName } from './lib/offers.js'
import { deriveRelatedOffers } from './lib/relatedContent.js'

export default function App() {
  const [catalog, setCatalog] = useState(() => loadCatalog(defaultProducts))
  const [fulfilmentPoints, setFulfilmentPoints] = useState([])
  const [catalogSource, setCatalogSource] = useState('local')
  const [selectedId, setSelectedId] = useState('a4-print')
  const [preset, setPreset] = useState({})
  const [guidedStartStep, setGuidedStartStep] = useState(null)
  const [guidedInitialFile, setGuidedInitialFile] = useState(null)
  const [query, setQuery] = useState('')
  const [cart, setCart] = useState(() => loadCart())
  const [cartOpen, setCartOpen] = useState(false)
  const [cartNotice, setCartNotice] = useState('')
  const [orderMode, setOrderMode] = useState('guided')
  const [journeyId, setJourneyId] = useState('document-guided')
  const [taskContext, setTaskContext] = useState(null)
  const [view, setView] = useState(() => window.location.hash === '#admin' ? 'admin' : 'storefront')
  // QS-18A: page splits the storefront into Home (outcome-first, short)
  // and Shop (browsing + Product Hub + configurator) - the smallest
  // top-level addition to the existing state-machine/anchor-scroll
  // architecture, no router. 'view' above already means something else
  // (admin vs storefront), so this is deliberately a separate state
  // rather than overloading it. Home always renders first (DEFAULT_PAGE,
  // src/lib/navigation.js).
  //
  // QS-21: page gains a third value, 'product' - a real, dedicated
  // Product Detail view (ProductHub + configuration + related content).
  // The Shop grid does not exist in that page's render tree at all, not
  // merely scrolled away - this is the actual navigation/context fix
  // this pass is for (see the QS-21 report's transition-map audit).
  const [page, setPage] = useState(DEFAULT_PAGE)
  // QS-21: which product's Quick Configure sheet is open, if any (a
  // small overlay, not a page transition - see QuickConfigureSheet.jsx).
  const [quickConfigureProduct, setQuickConfigureProduct] = useState(null)
  // QS-21.1 section 4: whether the configurator section is currently
  // in the viewport - drives the desktop sticky/floating Configure
  // affordance (shown only while false, i.e. the customer is still
  // above it). Starts false: on a fresh Product Detail landing the
  // configurator is below the fold, so the affordance should be visible
  // immediately rather than waiting for the first observer callback.
  const [configureInView, setConfigureInView] = useState(false)
  // QS-20.1: a small, short-lived, presentation-only marker - see
  // buildOfferChangeContext()/resolveOfferContextCartTag()
  // (src/lib/navigation.js) for its full lifecycle contract. Set only
  // by an Offer's "Change" action; consumed (and cleared) by the next
  // successful add-to-cart for that same product; cleared by any other
  // navigation (a different product, Back, Home, Shop). Never read by
  // pricing, never sent to the server.
  const [productViewContext, setProductViewContext] = useState(null)
  // QS-18: languageMode is presentation-only (see src/lib/languageMode.js
  // and resolveDisplayLabel()/productContent.js) - it never touches
  // product ids, config, pricing or the backend payload. shopFilter
  // drives the Shop section's category chips; a hero outcome action can
  // set it before scrolling there (see selectHeroOutcome below).
  const [languageMode, setLanguageMode] = useState(() => loadLanguageMode())
  const [showLanguagePrompt, setShowLanguagePrompt] = useState(() => !hasSeenLanguageModePrompt())
  const [shopFilter, setShopFilter] = useState('All')
  // QS-20: Shop gains a lightweight Products|Offers toggle - reuses the
  // exact same shopFilter category chips for both (offer.category uses
  // the same SHOP_CATEGORIES vocabulary as a product's), no second
  // filter UI. Defaults to 'products'; a hero outcome with a matching
  // active offer switches to 'offers' before landing on Shop (see
  // selectHeroOutcome below) so "Get my business ready" etc. surface
  // the relevant combo first, per the QS-20 brief.
  const [shopMode, setShopMode] = useState('products')
  // QS-21: productHubRef now anchors the TOP of the Product Detail page
  // (opening a product scrolls/lands there); configureRef anchors the
  // configuration section WITHIN that same product's page - a within-
  // page hop is fine (the brief's own "configuration should belong to
  // that product context"), the fix was removing the Shop catalogue
  // from around it, not removing scrolling entirely. quickPointsRef now
  // anchors the restored Quick Points band on Home (QS-21 section 8).
  const configureRef = useRef(null)
  const productHubRef = useRef(null)
  const shopRef = useRef(null)
  const quickPointsRef = useRef(null)
  // QS-21 final pass: History API support. historyMountedRef guards the
  // one-time replaceState-not-pushState initial entry (brief section 2);
  // lastHistoryStateRef holds the canonical state object the browser's
  // CURRENT history entry actually reflects - resolveHistoryAction()
  // diffs against it to decide push/replace/none. Both are refs, not
  // state, deliberately: writing them must never itself trigger a
  // render or re-run either effect below.
  const historyMountedRef = useRef(false)
  const lastHistoryStateRef = useRef(null)

  useEffect(() => {
    const onHash = () => setView(window.location.hash === '#admin' ? 'admin' : 'storefront')
    window.addEventListener('hashchange', onHash)
    return () => window.removeEventListener('hashchange', onHash)
  }, [])

  // QS-21 final pass: the ONE central place that ever calls
  // history.pushState/replaceState (see buildHistoryState()/
  // resolveHistoryAction(), src/lib/navigation.js, for the actual
  // decisions) - no other function in this file touches history
  // directly. It only watches the small navigation shape itself
  // (page/selectedId/shopFilter/shopMode), so switching Guided<->Full
  // options, picking a preset, changing taskContext, or opening/closing
  // Quick Configure can never reach this effect at all - none of those
  // are in its dependency array, which is what makes them correctly
  // create zero history entries (brief sections 5/6) without any
  // special-casing here.
  useEffect(() => {
    const nextState = buildHistoryState(page, { selectedProductId: selectedId, shopFilter, shopMode })
    if (!historyMountedRef.current) {
      historyMountedRef.current = true
      window.history.replaceState(nextState, '')
      lastHistoryStateRef.current = nextState
      return
    }
    const action = resolveHistoryAction(lastHistoryStateRef.current, nextState)
    if (action === 'push') window.history.pushState(nextState, '')
    else if (action === 'replace') window.history.replaceState(nextState, '')
    lastHistoryStateRef.current = nextState
  }, [page, selectedId, shopFilter, shopMode])

  // QS-21 final pass: the one popstate listener (brief section 4).
  // Restores page/selectedProductId/shopFilter/shopMode from the event,
  // falling back safely to Home when the entry is missing/malformed
  // (resolvePopStateNavigation) or points at a product that no longer
  // exists in the current catalog (checked here, since the pure
  // resolver has no catalog access) - then always replaceState()s the
  // CURRENT entry to match exactly what was actually restored, so a
  // once-invalid entry self-heals instead of re-falling-back on every
  // future visit. Never calls pushState here - a popstate is the
  // browser moving its OWN stack pointer; adding a new entry in
  // response would fight that, not follow it. Also, per section 6/7:
  // always closes Quick Configure (it is an overlay, never a route) and
  // clears a stale Offer "Change" context unless the restored state is
  // still Product Detail for that exact product.
  useEffect(() => {
    const onPopState = (event) => {
      const resolved = resolvePopStateNavigation(event.state)
      const productStillExists = resolved.page !== 'product' || catalog.some((product) => product.id === resolved.selectedProductId)
      const finalState = productStillExists
        ? resolved
        : buildHistoryState('shop', { shopFilter: resolved.shopFilter, shopMode: resolved.shopMode })

      window.history.replaceState(finalState, '')
      lastHistoryStateRef.current = finalState

      setPage(finalState.page)
      setSelectedId((current) => (finalState.page === 'product' && finalState.selectedProductId ? finalState.selectedProductId : current))
      setShopFilter(finalState.shopFilter)
      setShopMode(finalState.shopMode)
      setQuickConfigureProduct(null)
      setProductViewContext((current) => resolveOfferContextAfterHistoryRestore(current, finalState))

      window.setTimeout(() => {
        if (finalState.page === 'shop') shopRef.current?.scrollIntoView({ block: 'start' })
        else window.scrollTo({ top: 0 })
      }, 40)
    }
    window.addEventListener('popstate', onPopState)
    return () => window.removeEventListener('popstate', onPopState)
  }, [catalog])

  // QS-21.1 section 4: drives the desktop sticky/floating Configure
  // affordance - true exactly while the real configurator section is
  // at least partially on screen, so the affordance can hide itself
  // once it would be redundant. Only observes while page is 'product'
  // (configureRef is null otherwise); re-attaches on selectedId changes
  // since switching product via the context rail keeps page:'product'
  // but the observed section's content changes under the same node.
  useEffect(() => {
    if (page !== 'product' || !configureRef.current) {
      setConfigureInView(false)
      return
    }
    const node = configureRef.current
    const observer = new IntersectionObserver(
      ([entry]) => setConfigureInView(entry.isIntersecting),
      { rootMargin: '-76px 0px 0px 0px', threshold: 0 }
    )
    observer.observe(node)
    return () => observer.disconnect()
  }, [page, selectedId])

  useEffect(() => {
    if (!isSupabaseConfigured()) return

    let cancelled = false
    loadQuickSolutionCatalog()
      .then((data) => {
        if (cancelled) return
        if (Array.isArray(data?.products) && data.products.length > 0) {
          setCatalog(data.products)
          setCatalogSource('supabase')
        }
        if (Array.isArray(data?.fulfilmentPoints)) {
          setFulfilmentPoints(data.fulfilmentPoints)
        }
      })
      .catch((error) => {
        console.warn('Quick Solution catalog fallback:', error)
        if (!cancelled) setCatalogSource('local')
      })

    return () => { cancelled = true }
  }, [])

  const customerProducts = useMemo(() => catalog.filter((product) => product.active !== false && product.channels?.storefront !== false), [catalog])
  const selectedProduct = catalog.find((product) => product.id === selectedId) || customerProducts[0] || catalog[0]
  const selectedJourney = guidedJourneys.find((journey) => journey.id === journeyId && journey.productId === selectedProduct?.id)
    || guidedJourneys.find((journey) => journey.productId === selectedProduct?.id)

  const searchMatches = useMemo(() => {
    const term = query.trim().toLowerCase()
    if (!term) return []
    return customerProducts.filter((product) => [product.name, product.category, product.description, ...(product.keywords || [])].join(' ').toLowerCase().includes(term)).slice(0, 4)
  }, [query, customerProducts])

  const filteredShopProducts = useMemo(
    () => filterProductsByShopCategory(customerProducts, shopFilter),
    [customerProducts, shopFilter]
  )

  // QS-20: offers resolve against the FULL catalog (not customerProducts)
  // because an offer's line can legitimately reference a product that
  // is not yet active at the storefront level (e.g. Event Starter's
  // flags/gazebos lines) - the OFFER's own active flag is what gates
  // customer visibility (resolveActiveOffers), independent of each
  // referenced product's own storefront/active flag. Purely local for
  // this phase - no Supabase-sourced offers table yet (see QS-20
  // report's "no unnecessary database tables before proving the model").
  const activeOffers = useMemo(() => resolveActiveOffers(defaultOffers, catalog), [catalog])
  const filteredOffers = useMemo(
    () => resolveOffersForCategory(activeOffers, shopFilter),
    [activeOffers, shopFilter]
  )

  // QS-21: relevant Offers (this product is one of the offer's own real
  // items) for Product Detail's "Related Offers" section - pure,
  // deterministic, reuse-only lookup (deriveRelatedOffers, see
  // src/lib/relatedContent.js). ProductHub already derives and renders
  // its own "related products" internally (same-category, existing
  // QS-16 behaviour) - this is only the Offers half, not a duplicate.
  // No recommendation engine.
  const relatedOffers = useMemo(
    () => deriveRelatedOffers(selectedProduct, activeOffers, 3),
    [selectedProduct, activeOffers]
  )

  // QS-21.1 section 4: the sticky Configure affordance's price line -
  // the exact same cue ProductHub's own hero shows (resolveProductPriceCue,
  // src/lib/productContent.js), never a second pricing computation.
  const productDetailPriceCue = useMemo(() => resolveProductPriceCue(selectedProduct), [selectedProduct])

  const scrollToConfigure = () => window.setTimeout(() => configureRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 40)
  const scrollToProductHub = () => window.setTimeout(() => productHubRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 40)
  const scrollToShop = () => window.setTimeout(() => shopRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 40)
  const scrollToQuickPoints = () => window.setTimeout(() => quickPointsRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 40)

  // QS-21: Home/Shop/Product Detail are three distinct render trees now
  // (see the JSX below) - goHome()/goShop() are the two direct nav
  // actions the header exposes; opening a product is openProductDetail()
  // further down, near the rest of the product-navigation functions.
  const goHome = () => {
    setPage('home')
    setCartOpen(false)
    setProductViewContext(null)
    window.setTimeout(() => window.scrollTo({ top: 0, behavior: 'smooth' }), 40)
  }

  const goShop = () => {
    setPage('shop')
    setProductViewContext(null)
    scrollToShop()
  }

  // QS-21: Quick Points moved from Shop to Home (section 8) - this now
  // scrolls within Home instead of switching to Shop first.
  const goToQuickPoints = () => {
    setPage('home')
    scrollToQuickPoints()
  }

  // Header's bag-button ("Start order") - same target it already had
  // (#configure, for whatever selectedProduct currently is), just now
  // needs page switched to 'product' first since the configuration
  // section only exists within Product Detail.
  const goToConfigure = () => {
    setPage('product')
    scrollToConfigure()
  }

  useEffect(() => {
    saveCart(cart)
  }, [cart])

  const chooseLanguageMode = (mode) => {
    setLanguageMode(mode)
    saveLanguageMode(mode)
    markLanguageModePromptSeen()
    setShowLanguagePrompt(false)
  }

  const dismissLanguagePrompt = () => {
    markLanguageModePromptSeen()
    setShowLanguagePrompt(false)
  }

  // QS-20.1: if productViewContext is active AND still points at THIS
  // exact product (see resolveOfferContextCartTag()/navigation.js), tag
  // the new cart item with the same offerId/offerName addOfferToCart()
  // already uses for basket grouping - restoring Offer identity for a
  // line the customer edited via "Change". Consumed exactly once: the
  // context is cleared the moment it's used, so a second, unrelated add
  // for the same product never inherits a stale tag.
  const addToCart = ({ product, config, file, files, total = 0, summary = '', quoteRequired = false }) => {
    const cartId = globalThis.crypto?.randomUUID?.() || `cart-${Date.now()}-${Math.random().toString(36).slice(2)}`
    const normalizedFiles = Array.isArray(files)
      ? files
      : Array.isArray(file)
        ? file
        : file
          ? [file]
          : []
    const contextTag = resolveOfferContextCartTag(productViewContext, product.id)
    const offerName = contextTag ? resolveOfferDisplayName(defaultOffers.find((offer) => offer.id === contextTag.offerId), languageMode) : null
    setCart((items) => [...items, {
      cartId,
      productId: product.id,
      productName: product.name,
      category: product.category,
      config,
      files: normalizedFiles,
      file: normalizedFiles[0] || null,
      total: Number(total || 0),
      summary,
      quoteRequired: Boolean(quoteRequired),
      ...(contextTag ? { offerId: contextTag.offerId, offerName } : {})
    }])
    if (contextTag) setProductViewContext(null)
    setCartNotice(`${product.name} added to your order`)
    window.setTimeout(() => setCartNotice(''), 2200)
  }

  // QS-20: "Offer expands into its real child product lines for pricing/
  // order fulfilment" (per the brief) - each of the offer's resolved
  // lines becomes an ordinary cart entry, exactly the same shape
  // addToCart() already produces (createQuickSolutionCartOrder only
  // ever sends {clientItemKey, productKey, configuration} per item - it
  // has no concept of "offer" at all, so nothing on the backend needs
  // to change). offerId/offerName are extra, backend-ignored fields
  // used only so OrderBasket can show the lines grouped under the
  // offer's name for customer presentation - they never reach the RPC
  // payload (see supabaseApi.js's createQuickSolutionCartOrder, which
  // only reads clientItemKey/productKey/configuration off each item).
  // QS-20 final review: a line's `quantity` is a REPEAT COUNT (see
  // offers.js's header comment) - the cart/order payload
  // (createQuickSolutionCartOrder) has no per-item quantity field at
  // all, so the ONLY representation the server can independently
  // re-verify is genuinely separate cart entries, each with the
  // per-UNIT config and per-unit total. A single entry carrying
  // config (1 unit) but total (N units) would show the customer one
  // total while the server - which only ever recalculates from
  // `configuration` - would charge for one unit: a real pricing
  // integrity bug, caught and fixed here before this ever reached
  // checkout.
  const addOfferToCart = (offer, result) => {
    const validLines = (result?.lines || []).filter((line) => !line.error)
    if (!validLines.length) return
    const offerName = resolveOfferDisplayName(offer, languageMode)
    const newItems = []
    for (const line of validLines) {
      const product = catalog.find((item) => item.id === line.productId)
      const repeatCount = Math.max(Number(line.quantity) || 1, 1)
      for (let unit = 0; unit < repeatCount; unit++) {
        newItems.push({
          cartId: globalThis.crypto?.randomUUID?.() || `cart-${Date.now()}-${Math.random().toString(36).slice(2)}`,
          productId: line.productId,
          productName: line.productName,
          category: product?.category || '',
          config: line.config,
          files: [],
          file: null,
          total: Number(line.unitTotal || 0),
          summary: line.summary,
          quoteRequired: Boolean(line.quoteRequired),
          offerId: offer.id,
          offerName
        })
      }
    }
    setCart((items) => [...items, ...newItems])
    setCartNotice(`${offerName} added to your order — ${newItems.length} item${newItems.length === 1 ? '' : 's'}`)
    window.setTimeout(() => setCartNotice(''), 2600)
  }

  const removeCartItem = (cartId) => setCart((items) => items.filter((item) => item.cartId !== cartId))
  const continueShopping = () => {
    setCartOpen(false)
    setPage('shop')
    setProductViewContext(null)
    scrollToShop()
  }

  // QS-21: productViewContext is preserved ONLY when this call targets
  // the SAME product the context was built for (e.g. toggling Guided /
  // Full options back and forth while editing an Offer's line) - it is
  // cleared the moment a DIFFERENT product is targeted, which is the
  // normal case for every call site except OfferCard's "Change" handler
  // (the only one that ever passes a real offerContext argument).
  const preserveOrClearOfferContext = (product, offerContext) => (current) => {
    if (offerContext) return offerContext
    if (current && current.productId === product.id) return current
    return null
  }

  const openAdvanced = (product, nextPreset = {}, offerContext = null) => {
    setPage('product')
    setSelectedId(product.id)
    setPreset(nextPreset)
    setOrderMode('advanced')
    setTaskContext(null)
    setProductViewContext(preserveOrClearOfferContext(product, offerContext))
    scrollToConfigure()
  }

  const openGuided = (product, nextJourneyId, nextPreset = {}, task = null, offerContext = null) => {
    setPage('product')
    setSelectedId(product.id)
    setPreset(nextPreset)
    setJourneyId(nextJourneyId || product.guidedJourneyId)
    setGuidedStartStep(null)
    setGuidedInitialFile(null)
    setOrderMode('guided')
    setTaskContext(task)
    setProductViewContext(preserveOrClearOfferContext(product, offerContext))
    scrollToConfigure()
  }

  const continueFromAdvanced = (product, config, file) => {
    setPage('product')
    setSelectedId(product.id)
    setPreset(config)
    setJourneyId(product.guidedJourneyId)
    setTaskContext(null)
    setGuidedInitialFile(file || null)
    setGuidedStartStep('fulfilment')
    setOrderMode('guided')
    setProductViewContext(preserveOrClearOfferContext(product, null))
    scrollToConfigure()
  }

  const openPreferred = (product, nextPreset = {}) => {
    if (product.channels?.guided !== false && product.guidedJourneyId) {
      openGuided(product, product.guidedJourneyId, nextPreset)
      return
    }
    openAdvanced(product, nextPreset)
  }

  // QS-21.1 section 10: the Guided/Full options TOGGLE inside the
  // already-open configurator must never scroll - the customer is
  // already looking at it. openGuided()/openAdvanced() are for genuine
  // entry points (a hero CTA, a preset, Offer "Change", search - all of
  // which reasonably land the customer here from somewhere ABOVE it)
  // and always scroll by design; this is deliberately a separate,
  // lighter path that only ever flips orderMode for the product already
  // open, never touches page/selectedId/preset/journeyId and never
  // calls scrollToConfigure(). Fixes a real bug: the Guided tab used to
  // call openGuided() directly, which scrolled the page on every single
  // Guided<->Full toggle even though the configurator was already on
  // screen.
  const switchOrderMode = (nextMode) => {
    if (nextMode === 'guided' && selectedJourney) {
      setOrderMode('guided')
      setGuidedStartStep(null)
      setGuidedInitialFile(null)
      return
    }
    setOrderMode('advanced')
    setTaskContext(null)
  }

  // QS-16/QS-21: a normal visual product-card click (or a related-
  // product click) opens Product Detail - now a real, dedicated page
  // (page:'product'), not a scroll target inside a long Shop document.
  // Reuses the same selectedId state everything else already reads
  // from - Product Detail's own Configure/Guided CTAs then call
  // openAdvanced/openGuided/openPreferred (unchanged) exactly as before.
  //
  // Resets preset/taskContext/guidedStartStep/guidedInitialFile exactly
  // like openAdvanced/openGuided already do, and always clears
  // productViewContext (QS-20.1) - opening a product FRESH (as opposed
  // to toggling Guided/Full options on the one already open) is always
  // a genuine "leave whatever I was editing" moment. GuidedOrder/
  // ProductConfigurator are keyed on
  // `${selectedProduct.id}-...-${JSON.stringify(preset)}`, so switching
  // products without clearing preset would remount a fresh configurator
  // for the NEW product but seed it from the OLD product's leftover
  // config (getDefaultConfig merges {...defaults, ...preset} - any
  // matching field id, e.g. a shared 'width'/'artwork' field, would
  // leak a stale value in). Reproducible before this fix (QS-16):
  // configure product A, click a related product without first clicking
  // that product's own Configure/Guided button - it would show product
  // B pre-filled with product A's answers.
  const openProductDetail = (product) => {
    setPage('product')
    setSelectedId(product.id)
    setPreset({})
    setTaskContext(null)
    setGuidedStartStep(null)
    setGuidedInitialFile(null)
    setProductViewContext(null)
    window.setTimeout(() => window.scrollTo({ top: 0, behavior: 'smooth' }), 40)
  }

  const goBackToShop = () => {
    setPage('shop')
    setProductViewContext(null)
    window.setTimeout(() => window.scrollTo({ top: 0, behavior: 'smooth' }), 40)
  }

  // QS-21: Quick Configure is a small overlay, not a page transition -
  // resolveQuickConfigureEligibility() (src/lib/navigation.js) decides
  // whether it is safe for this product at all (see that function's own
  // comment for exactly which real products/strategies this affects);
  // when it is not, Configure sends the customer straight to Product
  // Detail's configuration step instead, per the QS-21 brief's own
  // allowance for that fallback.
  const openQuickConfigure = (product) => {
    if (resolveQuickConfigureEligibility(product)) {
      setQuickConfigureProduct(product)
      return
    }
    openPreferred(product)
  }

  const closeQuickConfigure = () => setQuickConfigureProduct(null)

  // "Full options" inside the Quick Configure sheet - hands over
  // whatever the customer already chose there as the starting preset,
  // then opens the real Advanced configurator on Product Detail.
  const openFullOptionsFromQuickConfigure = (product, config) => {
    closeQuickConfigure()
    openAdvanced(product, config)
  }

  // QS-18/QS-18A hero outcome actions: resolveHeroOutcomeNavigation()
  // (pure, src/lib/navigation.js) decides WHERE an outcome leads; this
  // just applies it. 'guided' reuses openGuided() exactly like App.jsx's
  // other guided entry points already do (no new routing mechanism,
  // and openGuided() already switches to the Shop page itself); 'shop'
  // sets the existing Shop section's category filter, switches to the
  // Shop page and scrolls there, letting the customer pick between more
  // than one matching product themselves rather than this guessing for
  // them.
  const selectHeroOutcome = (outcome) => {
    const nav = resolveHeroOutcomeNavigation(outcome)
    if (!nav) return
    if (nav.type === 'shop') {
      setShopFilter(nav.shopFilter)
      // QS-20: land on the Offers tab, not Products, when this outcome's
      // category actually has a ready-made offer - "Get my business
      // ready" should surface Business Starter first, not send the
      // customer straight to browsing individual products. Falls back
      // to Products when a category has no offers yet (e.g. Photo &
      // Video today), so the tab is never shown empty by default.
      const matchingOffers = resolveOffersForCategory(activeOffers, nav.shopFilter)
      setShopMode(matchingOffers.length > 0 ? 'offers' : 'products')
      setPage('shop')
      scrollToShop()
      return
    }
    const product = catalog.find((item) => item.id === nav.productId)
    if (product) openGuided(product, nav.journeyId, nav.preset)
  }

  // QS-18: document printing must be reachable immediately from anywhere
  // (header action) - opens the SAME existing Guided document flow the
  // "Print something" hero outcome already uses, never a second upload
  // implementation.
  const openDocumentPrinting = () => {
    const product = catalog.find((item) => item.id === 'a4-print')
    if (product) openGuided(product, 'document-guided', {})
  }

  const submitSearch = (event) => {
    event.preventDefault()
    const product = searchMatches[0]
    if (!product) return
    if (product.channels?.guided !== false && product.guidedJourneyId) openGuided(product, product.guidedJourneyId)
    else openAdvanced(product)
  }

  if (window.location.pathname === '/track') {
    return <TrackOrder/>
  }

  const paymentMode = new URLSearchParams(window.location.search).get('qs_payment')
  if (paymentMode === 'return' || paymentMode === 'cancel') {
    return <PaymentReturn/>
  }

  if (view === 'admin') {
    return <AdminProductManager initialProducts={catalog} defaultProducts={defaultProducts} onCatalogChange={setCatalog} onFulfilmentPointsChange={setFulfilmentPoints}/>
  }

  return (
    <div id="top">
      <Header
        mode={languageMode}
        onModeChange={chooseLanguageMode}
        onSendDocuments={openDocumentPrinting}
        onGoHome={goHome}
        onGoShop={goShop}
        onGoQuickPoints={goToQuickPoints}
        onStartOrder={goToConfigure}
      />
      {showLanguagePrompt && <LanguageModePrompt onChoose={chooseLanguageMode} onDismiss={dismissLanguagePrompt}/>}
      <main>
        {/* QS-21: Home = outcome-first landing only. Shop (catalogue) and
            Product Detail (ProductHub + configuration) are separate page
            values below, reached via an outcome action, the header's
            Shop link, Send documents, or opening a product - see
            openGuided/openAdvanced/openProductDetail/goShop above. */}
        {page === 'home' && (
        <>
        <section className="hero shell qs18-hero">
          <div className="hero-copy">
            <span className="eyebrow">Joint X Quick Solution Café · Location 001</span>
            <h1>Printing, branding<br/>&amp; <em>everyday solutions.</em></h1>

            <form className="search-wrap" onSubmit={submitSearch}>
              <div className="search-box">
                <Icon name="search" size={20}/>
                <input
                  value={query}
                  onChange={(event) => setQuery(event.target.value)}
                  aria-label="Tell Quick Solution what you need"
                  placeholder="Try “print my CV”, “banner”, “headshot”, “video shoot”..."
                />
                <button type="submit">Guide me</button>
              </div>
              {searchMatches.length > 0 && (
                <div className="search-results">
                  {searchMatches.map((product) => (
                    <button type="button" key={product.id} onClick={() => product.channels?.guided !== false && product.guidedJourneyId ? openGuided(product, product.guidedJourneyId) : openAdvanced(product)}>
                      <span><strong>{resolveProductDisplayName(product, languageMode)}</strong><small>{product.category} · guided start</small></span>
                      <Icon name="arrowRight" size={17}/>
                    </button>
                  ))}
                </div>
              )}
            </form>

            <div className="trust-row"><span className="brand-dot green"></span><span>No account needed for quick orders</span><span className="divider"></span><span>Clear pricing</span><span className="divider"></span><span>Human help when needed</span></div>
          </div>

          <div className="qs18-outcome-panel" aria-label="What do you need done today?">
            <h2>What do you need done today?</h2>
            {/* QS-19: horizontal swipe rail on mobile, vertical list on
                desktop - pure CSS (qs19-home-polish.css), same DOM/data
                either way. qs18-outcome-arrow wraps the chevron in a
                circular badge for stronger tap affordance. */}
            <div className="qs18-outcome-grid">
              {heroOutcomes.map((outcome) => (
                <button type="button" key={outcome.id} className="qs18-outcome-card" onClick={() => selectHeroOutcome(outcome)}>
                  <span className="qs18-outcome-icon"><Icon name={outcome.icon} size={20}/></span>
                  <span className="qs18-outcome-copy">
                    <strong>{outcome.label}</strong>
                    <small>{outcome.helper}</small>
                  </span>
                  <span className="qs18-outcome-arrow"><Icon name="arrowRight" size={15}/></span>
                </button>
              ))}
            </div>
          </div>
        </section>

        <WorkedWithStrip/>

        <ProofGallery onExploreCollection={goToQuickPoints}/>

        {/* QS-21 section 8: Quick Points restored to Home as a compact
            credibility/utility band (not the old full-page section) -
            answers "why use Quick Solution", using only real, existing
            functionality (the same three claims the former standalone
            promise-band already made, truthfully, plus one about
            Simple/Pro guided ordering) and the real nearby-collection
            listing data already fetched into fulfilmentPoints. Shop no
            longer carries this section at all - it stays a lean
            catalogue (section 7). */}
        <section id="quick-points" ref={quickPointsRef} className="shell section qs21-quickpoints-band">
          <div className="section-heading">
            <div><span className="eyebrow">Why Quick Solution</span><h2>Built for how you actually order.</h2></div>
          </div>
          <div className="qs21-quickpoints-benefits">
            <div><Icon name="upload"/><strong>Upload from your phone</strong><span>No app, no account - send a file or photo straight from wherever you are.</span></div>
            <div><Icon name="clock"/><strong>Order before you arrive</strong><span>Less waiting and fewer back-and-forth messages.</span></div>
            <div><Icon name="truck"/><strong>Collect where it suits you</strong><span>Café, Quick Point, delivery or courier.</span></div>
            <div><Icon name="store"/><strong>One price source</strong><span>Website, POS, quote and invoice use the same rules.</span></div>
          </div>
          <div className="qs21-quickpoints-locations">
            <div className="quick-copy">
              <strong>Nearby collection</strong>
              <span>Powered by Easy Locate</span>
            </div>
            {/* QS-21.4 section 3: same subtle Quick Points/Easy Locate map
                background as Product Detail's Collection/delivery block
                (qs21-4-polish.css) - reinforces "local, mapped" here too,
                applied to the actual card (not the surrounding heading
                text) so it reads as the card's own surface. */}
            <div className="location-card qs21-map-surface">
              {(fulfilmentPoints.length ? fulfilmentPoints : [
                { id: 'demo-cafe', name: 'Quick Solution Café', kind: 'cafe', services: ['Full service location'] },
                { id: 'demo-point', name: 'Partner Quick Point', kind: 'quick_point', services: ['Collection point'], demo: true }
              ]).slice(0, 4).map((point) => {
                const business = point.easyLocateLink?.business || {}
                const area = [business.locationArea || point.address?.area || point.address?.city, business.locationExtension || point.address?.line1].filter(Boolean).join(' · ')
                const categories = Array.isArray(business.categories) ? business.categories.slice(0, 2).join(' · ') : ''
                const listingUrl = point.easyLocateLink?.canonicalUrl
                return (
                  <div className="location-row qs07-location-row" key={point.id}>
                    <div>
                      <strong>{point.name}</strong>
                      <span>{[area, categories || (point.kind === 'cafe' ? 'Full service location' : 'Collection point')].filter(Boolean).join(' · ')}</span>
                    </div>
                    <div className="location-row-actions">
                      <span>{point.demo ? 'Coming soon' : point.kind === 'cafe' ? 'Quick Solution café' : point.easyLocateLink ? 'Easy Locate verified' : 'Quick Point'}</span>
                      {listingUrl ? <a href={listingUrl} target="_blank" rel="noreferrer">View listing <Icon name="external" size={13}/></a> : null}
                    </div>
                  </div>
                )
              })}
            </div>
          </div>
        </section>

        <HelpCta/>
        </>
        )}

        {/* QS-21: Shop is now a lean catalogue only - grid/offers/filters
            and the "coming soon" teaser. ProductHub, the configurator,
            Quick Points and the promise-band claims all moved out (Quick
            Points + those claims are now on Home, section 8 above;
            ProductHub + configuration are now their own page:'product'
            tree below) - Shop no longer scrolls into a configurator
            living in the same document. */}
        {page === 'shop' && (
        <>
        <section id="shop" ref={shopRef} className="shell section services-section">
          <div className="section-heading">
            <div><span className="eyebrow">Shop</span><h2>See what we can make.</h2></div>
            <p>{shopMode === 'offers'
              ? 'Ready-made setups built from real products - choose one, or customise it first.'
              : 'Browse visually, then open a product for the full details, or jump straight to Configure.'}</p>
          </div>

          {/* QS-20: Quick (ready-made Offers) vs Build your own (browse
              individual Products) - both read/filter the SAME
              shopFilter category chips below, just render a different
              grid. No new router, no second filter UI. */}
          <div className="qs20-shop-mode-toggle" role="tablist" aria-label="Products or Offers">
            <button type="button" role="tab" aria-selected={shopMode === 'products'} className={shopMode === 'products' ? 'active' : ''} onClick={() => setShopMode('products')}>
              Build your own
            </button>
            <button type="button" role="tab" aria-selected={shopMode === 'offers'} className={shopMode === 'offers' ? 'active' : ''} onClick={() => setShopMode('offers')}>
              Quick — ready-made setups
            </button>
          </div>

          <div className="qs18-shop-filters" role="tablist" aria-label="Filter by category">
            {SHOP_CATEGORIES.map((category) => (
              <button
                key={category}
                type="button"
                role="tab"
                aria-selected={shopFilter === category}
                className={shopFilter === category ? 'active' : ''}
                onClick={() => setShopFilter(category)}
              >{category}</button>
            ))}
          </div>

          {shopMode === 'offers' ? (
            <>
              <div className="qs20-offer-grid">
                {filteredOffers.map((offer) => (
                  <OfferCard
                    key={offer.id}
                    offer={offer}
                    products={catalog}
                    mode={languageMode}
                    onChooseThis={(result) => addOfferToCart(offer, result)}
                    onCustomiseLine={(line, item) => {
                      const product = catalog.find((entry) => entry.id === line.productId)
                      if (product) openAdvanced(product, line.config, buildOfferChangeContext(offer, item))
                    }}
                  />
                ))}
              </div>
              {filteredOffers.length === 0 && (
                <p className="qs20-offer-empty">No ready-made setups in this category yet — try “All”, switch to “Build your own”, or WhatsApp us and we will help directly.</p>
              )}
            </>
          ) : (
            <>
              <div className="product-grid">
                {filteredShopProducts.map((product) => (
                  <ProductCard
                    key={product.id}
                    product={product}
                    mode={languageMode}
                    active={selectedProduct?.id === product.id}
                    onViewProduct={openProductDetail}
                    onQuickConfigure={resolveQuickConfigureEligibility(product) ? openQuickConfigure : undefined}
                  />
                ))}
              </div>
              {filteredShopProducts.length === 0 && (
                <p className="qs18-shop-empty">Nothing in this category yet — try “All” or WhatsApp us and we will help directly.</p>
              )}
            </>
          )}
        </section>

        <ComingSoonRail liveProductIds={customerProducts.map((product) => product.id)} />
        </>
        )}

        {/* QS-21: Product Detail - a real, dedicated page (ProductHub +
            configuration + related content), reached only via
            openProductDetail()/openPreferred() (never a scroll target
            inside Shop). The context rail below is the "customer must
            always know which product they are configuring" requirement
            (brief section 4/5) - it is the same product-switcher Shop's
            old configure-toolbar used to bury inline, now the page's own
            top-level orientation device, restyled with restraint (see
            qs21-navigation.css's .qs21-context-rail). */}
        {page === 'product' && selectedProduct && (
        <>
        {/* QS-21.1 section 4: desktop-only (hidden on mobile via CSS -
            ProductHub already has its own mobile sticky CTA, see
            qs16.css's .product-hub-sticky-cta - showing both would be
            redundant on a small screen). Visible only while the real
            configurator is NOT already in view (configureInView, driven
            by the IntersectionObserver effect above) - never obscures
            content, never adds a history entry, changes no pricing. */}
        {resolveStickyConfigureVisibility(page, configureInView) && (
          <button type="button" className="qs21-sticky-configure" onClick={scrollToConfigure}>
            <span className="qs21-sticky-configure-copy">
              <small>Configure</small>
              <strong>
                {productDetailPriceCue == null
                  ? resolveProductDisplayName(selectedProduct, languageMode)
                  : productDetailPriceCue.quoteRequired ? 'Quote required' : `From ${formatMoney(productDetailPriceCue.total)}`}
              </strong>
            </span>
            <span className="qs21-sticky-configure-action"><Icon name="arrowRight" size={15}/> Configure order</span>
          </button>
        )}
        <section className="shell qs21-product-detail-nav">
          <button type="button" className="qs21-back-to-shop" onClick={goBackToShop}>
            <Icon name="arrowLeft" size={15}/> Back to Shop
          </button>
          <div className="qs21-context-rail" role="tablist" aria-label="Choose a product to configure">
            {customerProducts.map((product) => (
              <button
                role="tab"
                aria-selected={selectedProduct.id === product.id}
                key={product.id}
                className={`qs21-context-tab ${selectedProduct.id === product.id ? 'active' : ''}`}
                onClick={() => openPreferred(product)}
                type="button"
              >{product.shortName}</button>
            ))}
          </div>
        </section>

        <div ref={productHubRef} className="qs16-product-hub-anchor">
          {/* QS-17: onConfigure/onGuided now optionally forward a
              preset config (from the Presets section's "Choose
              this"/"Customise") straight into the EXISTING
              openAdvanced/openGuided nextPreset argument - the same
              mechanism QS-16 already used for related-product/
              continue-from-advanced handoffs. No new state. */}
          <ProductHub
            product={selectedProduct}
            catalog={customerProducts}
            mode={languageMode}
            onConfigure={(presetConfig) => openAdvanced(selectedProduct, presetConfig || {})}
            onGuided={selectedJourney ? (presetConfig) => openGuided(selectedProduct, selectedJourney.id, presetConfig || {}) : null}
            onSelectRelated={openProductDetail}
            onQuickConfigure={openQuickConfigure}
          />
        </div>

        {/* QS-21.3: the separate full 4-card trust strip that used to sit
            here was removed - ProductHub's own compact trust row
            (.product-hub-trust-compact, in the PDP info column) already
            makes the exact same 4 verified-true claims once per page;
            this was a straight duplicate a few hundred pixels below it. */}

        <section id="configure" ref={configureRef} className="configurator-section">
          <div className="shell">
            {/* QS-21.3 section 2/5: shortened - "Start with Guided mode
                for the simplest route..." repeated what the mode-toggle's
                own labels below already say ("Guided is recommended" /
                "Full options gives precise control"). Product context
                (which product, a way back to it) is the only thing this
                intro needs to convey that isn't shown anywhere else on
                this page. */}
            <div className="qs10-config-intro">
              <div>
                <span className="eyebrow">Ready to order? · {resolveProductDisplayName(selectedProduct, languageMode)}</span>
                <h2>Configure your order.</h2>
              </div>
              <button type="button" className="qs16-view-product-link" onClick={scrollToProductHub}>
                <Icon name="arrowUpRight" size={15}/> View product
              </button>
            </div>
            <div className="configure-toolbar">
              {selectedProduct.channels?.guided !== false && selectedProduct.guidedJourneyId && selectedProduct.channels?.advanced !== false && (
                <div className="mode-choice">
                  <div className="mode-choice-copy">
                    <span>Order mode</span>
                    <strong>{orderMode === 'guided' ? 'Guided is recommended' : 'Full options gives precise control'}</strong>
                  </div>
                  <div className="mode-toggle" aria-label="Ordering mode">
                    <button type="button" className={orderMode === 'guided' ? 'active' : ''} onClick={() => switchOrderMode('guided')}>
                      <span>Guided</span><small>Recommended</small>
                    </button>
                    <button type="button" className={`${orderMode === 'advanced' ? 'active' : ''} full-options-button`} onClick={() => switchOrderMode('advanced')}>
                      <span>Full options</span><small>Exact specs</small>
                    </button>
                  </div>
                </div>
              )}
            </div>

            {orderMode === 'guided' && selectedJourney ? (
              <GuidedOrder
                key={`${selectedProduct.id}-${selectedJourney.id}-${JSON.stringify(preset)}`}
                product={selectedProduct}
                journey={selectedJourney}
                preset={preset}
                task={taskContext}
                mode={languageMode}
                fulfilmentPoints={fulfilmentPoints}
                initialStepId={guidedStartStep}
                initialFile={guidedInitialFile}
                onAdvanced={() => setOrderMode('advanced')}
                onAddToCart={addToCart}
              />
            ) : (
              <ProductConfigurator
                key={`${selectedProduct.id}-${JSON.stringify(preset)}`}
                product={selectedProduct}
                preset={preset}
                mode={languageMode}
                onGuided={selectedJourney ? () => openGuided(selectedProduct, selectedJourney.id, preset) : null}
                onContinue={({ config, file }) => continueFromAdvanced(selectedProduct, config, file)}
                onAddToCart={addToCart}
              />
            )}
          </div>
        </section>

        {relatedOffers.length > 0 && (
          <section className="shell section qs21-related-offers">
            <div className="section-heading">
              <div><span className="eyebrow">Also useful</span><h2>Ready-made setups that include this.</h2></div>
            </div>
            <div className="qs20-offer-grid">
              {relatedOffers.map((offer) => (
                <OfferCard
                  key={offer.id}
                  offer={offer}
                  products={catalog}
                  mode={languageMode}
                  onChooseThis={(result) => addOfferToCart(offer, result)}
                  onCustomiseLine={(line, item) => {
                    const product = catalog.find((entry) => entry.id === line.productId)
                    if (product) openAdvanced(product, line.config, buildOfferChangeContext(offer, item))
                  }}
                />
              ))}
            </div>
          </section>
        )}
        </>
        )}
      </main>
      {quickConfigureProduct && (
        <QuickConfigureSheet
          product={quickConfigureProduct}
          mode={languageMode}
          onClose={closeQuickConfigure}
          onAddToCart={addToCart}
          onFullOptions={(config) => openFullOptionsFromQuickConfigure(quickConfigureProduct, config)}
        />
      )}
      <OrderBasket
        items={cart}
        open={cartOpen}
        fulfilmentPoints={fulfilmentPoints}
        onClose={() => setCartOpen(false)}
        onRemove={removeCartItem}
        onContinueShopping={continueShopping}
        onOrderCreated={() => setCart([])}
      />
      {cartNotice ? <div className="qs-cart-toast" role="status"><Icon name="bag" size={16}/><span>{cartNotice}</span></div> : null}
      {cart.length > 0 && !cartOpen ? (
        <button className="qs-cart-floating" type="button" onClick={() => setCartOpen(true)}>
          <span><strong>{cart.length} item{cart.length === 1 ? '' : 's'}</strong><small>View order</small></span>
          <Icon name="bag" size={18}/>
        </button>
      ) : null}
      <footer className="shell footer"><strong>Joint X Quick Solution Café</strong><span>Location 001 · Built on XOS · {catalogSource === 'supabase' ? 'Live staging catalogue' : 'Local fallback'} · <a href="#admin">Product Admin</a></span></footer>
    </div>
  )
}

