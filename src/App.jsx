import React, { useEffect, useMemo, useRef, useState } from 'react'
import Icon from './components/Icon.jsx'
import Header from './components/Header.jsx'
import ProductCard from './components/ProductCard.jsx'
import ProductHub from './components/ProductHub.jsx'
import ProductConfigurator from './components/ProductConfigurator.jsx'
import GuidedOrder from './components/GuidedOrder.jsx'
import PaymentReturn from './components/PaymentReturn.jsx'
import TrackOrder from './components/TrackOrder.jsx'
import QuickTaskCard from './components/QuickTaskCard.jsx'
import SubtleStoryRail from './components/SubtleStoryRail.jsx'
import ProofGallery from './components/ProofGallery.jsx'
import ComingSoonRail from './components/ComingSoonRail.jsx'
import AdminProductManager from './admin/AdminProductManager.jsx'
import OrderBasket from './components/OrderBasket.jsx'
import { loadCart, saveCart } from './lib/cartStore.js'
import { categories, guidedJourneys, products as defaultProducts, quickTasks } from './data/products.js'
import { loadCatalog } from './lib/catalogStore.js'
import { isSupabaseConfigured, loadQuickSolutionCatalog } from './lib/supabaseApi.js'

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
  const configureRef = useRef(null)
  const productHubRef = useRef(null)

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

  const scrollToConfigure = () => window.setTimeout(() => configureRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 40)
  const scrollToProductHub = () => window.setTimeout(() => productHubRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 40)

  useEffect(() => {
    saveCart(cart)
  }, [cart])

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

  const removeCartItem = (cartId) => setCart((items) => items.filter((item) => item.cartId !== cartId))
  const continueShopping = () => {
    setCartOpen(false)
    window.setTimeout(() => document.querySelector('#services')?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 40)
  }

  const openAdvanced = (product, nextPreset = {}) => {
    setSelectedId(product.id)
    setPreset(nextPreset)
    setOrderMode('advanced')
    setTaskContext(null)
    scrollToConfigure()
  }

  const openGuided = (product, nextJourneyId, nextPreset = {}, task = null) => {
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
    setSelectedId(product.id)
    setPreset({})
    setTaskContext(null)
    setGuidedStartStep(null)
    setGuidedInitialFile(null)
    scrollToProductHub()
  }

  const selectTask = (task) => {
    if (task.action === 'help') {
      window.open('https://wa.me/27754534646?text=Hi%20Quick%20Solution%2C%20I%20need%20help%20with%20a%20service.', '_blank', 'noopener,noreferrer')
      return
    }
    const product = catalog.find((item) => item.id === task.productId)
    if (product) openGuided(product, task.journeyId, task.preset, task)
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
      <Header />
      <main>
        <section className="hero shell">
          <div className="hero-copy">
            <span className="eyebrow">Joint X Quick Solution Café · Location 001</span>
            <h1>Printing, branding<br/>& <em>everyday solutions.</em></h1>
            <p>From documents and stickers to apparel, signage, photo, video and business essentials — quick, clean and local. Tell us what you are trying to make and we will guide the technical details.</p>

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
                      <span><strong>{product.name}</strong><small>{product.category} · guided start</small></span>
                      <Icon name="arrowRight" size={17}/>
                    </button>
                  ))}
                </div>
              )}
            </form>

            <div className="hero-actions">
              <a className="button dark" href="#start">Start an order <Icon name="arrowRight" size={17}/></a>
              <a className="button ghost" href="#services">Browse products</a>
            </div>
            <div className="trust-row"><span className="brand-dot green"></span><span>No account needed for quick orders</span><span className="divider"></span><span>Clear pricing</span><span className="divider"></span><span>Human help when needed</span></div>
          </div>

          <div className="hero-visual" aria-label="How Quick Solution works">
            <div className="brand-orbs"><span></span><span></span><span></span></div>
            <div className="workflow-card">
              <div className="workflow-icon"><Icon name="upload" size={22}/></div>
              <span>1 · Tell us</span>
              <strong>Say what you need done.</strong>
            </div>
            <div className="workflow-card offset">
              <div className="workflow-icon"><Icon name="store" size={22}/></div>
              <span>2 · We guide you</span>
              <strong>Only the questions that matter.</strong>
            </div>
            <div className="workflow-card">
              <div className="workflow-icon"><Icon name="pin" size={22}/></div>
              <span>3 · Get it your way</span>
              <strong>Collect nearby or deliver.</strong>
            </div>
            <small className="visual-caption">Simple for everyday jobs. Full control when you need it.</small>
          </div>
        </section>

        <section className="category-strip" aria-label="Service categories">
          <div className="shell category-scroll">{categories.map((category) => <span key={category}>{category}</span>)}</div>
        </section>

        <SubtleStoryRail />

        <section id="start" className="shell section start-section">
          <div className="section-heading accessible-heading">
            <div><span className="eyebrow">Guided ordering · recommended</span><h2>What do you need today?</h2></div>
            <p>You do not need to know printing terms. Choose the outcome that sounds closest and we will only ask the questions that matter.</p>
          </div>
          <div className="task-grid six-tasks">{quickTasks.map((task) => <QuickTaskCard key={task.id} task={task} onSelect={selectTask}/>)}</div>
        </section>

        <section id="services" className="shell section services-section">
          <div className="section-heading">
            <div><span className="eyebrow">Browse products</span><h2>See what we can make.</h2></div>
            <p>Browse visually, then configure. Every product starts in Guided mode, with Full options available when you already know the exact specs.</p>
          </div>
          <div className="product-grid">{customerProducts.map((product) => <ProductCard key={product.id} product={product} active={selectedProduct?.id === product.id} onConfigure={openProductPage}/>)}</div>
        </section>

        {selectedProduct && (
          <div ref={productHubRef} className="qs16-product-hub-anchor">
            <ProductHub
              product={selectedProduct}
              catalog={customerProducts}
              onConfigure={() => openAdvanced(selectedProduct)}
              onGuided={selectedJourney ? () => openGuided(selectedProduct, selectedJourney.id) : null}
              onSelectRelated={openProductPage}
            />
          </div>
        )}

        <ComingSoonRail liveProductIds={customerProducts.map((product) => product.id)} />

        <ProofGallery />

        {selectedProduct && (
          <section id="configure" ref={configureRef} className="configurator-section">
            <div className="shell">
              <div className="qs10-config-intro">
                <div>
                  <span className="eyebrow">Ready to order? · {selectedProduct.name}</span>
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
                  onGuided={selectedJourney ? () => openGuided(selectedProduct, selectedJourney.id, preset) : null}
                  onContinue={({ config, file }) => continueFromAdvanced(selectedProduct, config, file)}
                  onAddToCart={addToCart}
                />
              )}
            </div>
          </section>
        )}

        <section id="quick-points" className="shell section quick-point-section">
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

