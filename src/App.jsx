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
import { loadCart, saveCart } from './lib/cartStore.js'
import { guidedJourneys, heroOutcomes, offers as defaultOffers, products as defaultProducts } from './data/products.js'
import { loadCatalog } from './lib/catalogStore.js'
import { isSupabaseConfigured, loadQuickSolutionCatalog } from './lib/supabaseApi.js'
import { resolveProductDisplayName, SHOP_CATEGORIES, filterProductsByShopCategory } from './lib/productContent.js'
import { loadLanguageMode, saveLanguageMode, hasSeenLanguageModePrompt, markLanguageModePromptSeen } from './lib/languageMode.js'
import { DEFAULT_PAGE, resolveHeroOutcomeNavigation } from './lib/navigation.js'
import { resolveActiveOffers, resolveOffersForCategory, resolveOfferDisplayName } from './lib/offers.js'

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
  const [page, setPage] = useState(DEFAULT_PAGE)
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
  const configureRef = useRef(null)
  const productHubRef = useRef(null)
  const shopRef = useRef(null)
  const quickPointsRef = useRef(null)

  useEffect(() => {
    const onHash = () => setView(window.location.hash === '#admin' ? 'admin' : 'storefront')
    window.addEventListener('hashchange', onHash)
    return () => window.removeEventListener('hashchange', onHash)
  }, [])

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

  const scrollToConfigure = () => window.setTimeout(() => configureRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 40)
  const scrollToProductHub = () => window.setTimeout(() => productHubRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 40)
  const scrollToShop = () => window.setTimeout(() => shopRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 40)
  const scrollToQuickPoints = () => window.setTimeout(() => quickPointsRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 40)

  // QS-18A: Shop/Product Hub/the configurator only exist in the Shop
  // page's render tree now (see the JSX below) - every existing entry
  // point that ends up showing one of them (openAdvanced/openGuided/
  // continueFromAdvanced/openProductPage) must switch page to 'shop'
  // first, or the matching scrollIntoView() would silently find nothing
  // to scroll to. goHome()/goShop() are the two direct nav actions the
  // header exposes.
  const goHome = () => {
    setPage('home')
    setCartOpen(false)
    window.setTimeout(() => window.scrollTo({ top: 0, behavior: 'smooth' }), 40)
  }

  const goShop = () => {
    setPage('shop')
    scrollToShop()
  }

  const goToQuickPoints = () => {
    setPage('shop')
    scrollToQuickPoints()
  }

  // Header's bag-button ("Start order") - same target it already had
  // (#configure, for whatever selectedProduct currently is), just now
  // needs page switched to 'shop' first since #configure only exists in
  // that branch.
  const goToConfigure = () => {
    setPage('shop')
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

  const addToCart = ({ product, config, file, files, total = 0, summary = '', quoteRequired = false }) => {
    const cartId = globalThis.crypto?.randomUUID?.() || `cart-${Date.now()}-${Math.random().toString(36).slice(2)}`
    const normalizedFiles = Array.isArray(files)
      ? files
      : Array.isArray(file)
        ? file
        : file
          ? [file]
          : []
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
      quoteRequired: Boolean(quoteRequired)
    }])
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
    scrollToShop()
  }

  const openAdvanced = (product, nextPreset = {}) => {
    setPage('shop')
    setSelectedId(product.id)
    setPreset(nextPreset)
    setOrderMode('advanced')
    setTaskContext(null)
    scrollToConfigure()
  }

  const openGuided = (product, nextJourneyId, nextPreset = {}, task = null) => {
    setPage('shop')
    setSelectedId(product.id)
    setPreset(nextPreset)
    setJourneyId(nextJourneyId || product.guidedJourneyId)
    setGuidedStartStep(null)
    setGuidedInitialFile(null)
    setOrderMode('guided')
    setTaskContext(task)
    scrollToConfigure()
  }

  const continueFromAdvanced = (product, config, file) => {
    setPage('shop')
    setSelectedId(product.id)
    setPreset(config)
    setJourneyId(product.guidedJourneyId)
    setTaskContext(null)
    setGuidedInitialFile(file || null)
    setGuidedStartStep('fulfilment')
    setOrderMode('guided')
    scrollToConfigure()
  }

  const openPreferred = (product, nextPreset = {}) => {
    if (product.channels?.guided !== false && product.guidedJourneyId) {
      openGuided(product, product.guidedJourneyId, nextPreset)
      return
    }
    openAdvanced(product, nextPreset)
  }

  // QS-16: a normal visual product-card click opens the Product Hub
  // (sales/context layer) rather than dropping straight into a
  // configurator. Reuses the same selectedId state everything else
  // already reads from - the Hub's own Configure/Guided CTAs then call
  // openAdvanced/openGuided/openPreferred (unchanged) exactly as a card
  // click used to.
  //
  // Resets preset/taskContext/guidedStartStep/guidedInitialFile exactly
  // like openAdvanced/openGuided already do - #configure is ALWAYS
  // rendered for whatever selectedProduct currently is (not only after
  // an explicit Configure/Guided click), and GuidedOrder/ProductConfigurator
  // are keyed on `${selectedProduct.id}-...-${JSON.stringify(preset)}`,
  // so switching products without clearing preset would remount a fresh
  // configurator for the NEW product but seed it from the OLD product's
  // leftover config (getDefaultConfig merges {...defaults, ...preset} -
  // any matching field id, e.g. a shared 'width'/'artwork' field, would
  // leak a stale value in). Reproducible before this fix: configure
  // product A, click a related product on the new Hub (or any product
  // card) without first clicking that Hub's own Configure/Guided button,
  // then scroll to #configure - it would show product B pre-filled with
  // product A's answers.
  const openProductPage = (product) => {
    setPage('shop')
    setSelectedId(product.id)
    setPreset({})
    setTaskContext(null)
    setGuidedStartStep(null)
    setGuidedInitialFile(null)
    scrollToProductHub()
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
        {/* QS-18A: Home = outcome-first landing only. Shop/Product Hub/
            configurator never render here - they only exist in the Shop
            branch below, reached via an outcome action, the header's
            Shop link, or Send documents (all of which switch page to
            'shop' before scrolling - see openGuided/openAdvanced/
            openProductPage/goShop above). */}
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

        <HelpCta/>
        </>
        )}

        {/* QS-18A: Shop = browsing + Product Hub + the configurator, all
            reused exactly as QS-16/QS-17/QS-18 already built them - only
            now gated to page === 'shop' instead of always stacked below
            Home. */}
        {page === 'shop' && (
        <>
        <section id="shop" ref={shopRef} className="shell section services-section">
          <div className="section-heading">
            <div><span className="eyebrow">Shop</span><h2>See what we can make.</h2></div>
            <p>{shopMode === 'offers'
              ? 'Ready-made setups built from real products - choose one, or customise it first.'
              : 'Browse visually, then configure. Every product starts in Guided mode, with Full options available when you already know the exact specs.'}</p>
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
                    onCustomiseLine={(line) => {
                      const product = catalog.find((item) => item.id === line.productId)
                      if (product) openAdvanced(product, line.config)
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
              <div className="product-grid">{filteredShopProducts.map((product) => <ProductCard key={product.id} product={product} mode={languageMode} active={selectedProduct?.id === product.id} onConfigure={openProductPage}/>)}</div>
              {filteredShopProducts.length === 0 && (
                <p className="qs18-shop-empty">Nothing in this category yet — try “All” or WhatsApp us and we will help directly.</p>
              )}
            </>
          )}
        </section>

        {selectedProduct && (
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
              onSelectRelated={openProductPage}
            />
          </div>
        )}

        <ComingSoonRail liveProductIds={customerProducts.map((product) => product.id)} />

        {selectedProduct && (
          <section id="configure" ref={configureRef} className="configurator-section">
            <div className="shell">
              <div className="qs10-config-intro">
                <div>
                  <span className="eyebrow">Ready to order? · {resolveProductDisplayName(selectedProduct, languageMode)}</span>
                  <h2>Configure your order.</h2>
                </div>
                <p>Start with Guided mode for the simplest route. Switch to Full options only when you already know the exact production specs.</p>
                <button type="button" className="qs16-view-product-link" onClick={scrollToProductHub}>
                  <Icon name="arrowUpRight" size={15}/> View product
                </button>
              </div>
              <div className="configure-toolbar">
                <div className="configure-switcher" role="tablist" aria-label="Choose a product to configure">
                  {customerProducts.map((product) => (
                    <button
                      role="tab"
                      aria-selected={selectedProduct.id === product.id}
                      key={product.id}
                      className={selectedProduct.id === product.id ? 'active' : ''}
                      onClick={() => openPreferred(product)}
                      type="button"
                    >{product.shortName}</button>
                  ))}
                </div>
                {selectedProduct.channels?.guided !== false && selectedProduct.guidedJourneyId && selectedProduct.channels?.advanced !== false && (
                  <div className="mode-choice">
                    <div className="mode-choice-copy">
                      <span>Order mode</span>
                      <strong>{orderMode === 'guided' ? 'Guided is recommended' : 'Full options gives precise control'}</strong>
                    </div>
                    <div className="mode-toggle" aria-label="Ordering mode">
                      <button type="button" className={orderMode === 'guided' ? 'active' : ''} onClick={() => openGuided(selectedProduct, selectedProduct.guidedJourneyId, preset, taskContext)}>
                        <span>Guided</span><small>Recommended</small>
                      </button>
                      <button type="button" className={`${orderMode === 'advanced' ? 'active' : ''} full-options-button`} onClick={() => { setOrderMode('advanced'); setTaskContext(null) }}>
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
        )}

        <section id="quick-points" ref={quickPointsRef} className="shell section quick-point-section">
          <div className="quick-copy">
            <span className="eyebrow">Joint X Quick Points</span>
            <h2>Order online.<br/>Collect locally.</h2>
            <p>Upload from home, configure your order, and collect when it is ready. Quick Points extend Joint X convenience through trusted local businesses.</p>
            <a className="button dark" href="#top">Explore nearby points <Icon name="arrowRight" size={17}/></a>
          </div>
          <div className="location-card">
            <div className="location-map">
              <div className="map-pin"><Icon name="pin" size={30}/></div>
              <strong>Nearby collection</strong>
              <span>Powered by Easy Locate</span>
            </div>
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
        </section>

        <section className="promise-band">
          <div className="shell promise-grid">
            <div><Icon name="clock"/><strong>Order before you arrive</strong><span>Less waiting and fewer back-and-forth messages.</span></div>
            <div><Icon name="truck"/><strong>Collect where it suits you</strong><span>Café, Quick Point, delivery or courier.</span></div>
            <div><Icon name="store"/><strong>One price source</strong><span>Website, POS, quote and invoice use the same rules.</span></div>
          </div>
        </section>
        </>
        )}
      </main>
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

