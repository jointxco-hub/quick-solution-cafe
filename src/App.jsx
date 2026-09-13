import React, { useEffect, useMemo, useRef, useState } from 'react'
import Icon from './components/Icon.jsx'
import Header from './components/Header.jsx'
import ProductCard from './components/ProductCard.jsx'
import ProductConfigurator from './components/ProductConfigurator.jsx'
import GuidedOrder from './components/GuidedOrder.jsx'
import QuickTaskCard from './components/QuickTaskCard.jsx'
import SubtleStoryRail from './components/SubtleStoryRail.jsx'
import AdminProductManager from './admin/AdminProductManager.jsx'
import { categories, guidedJourneys, products as defaultProducts, quickTasks } from './data/products.js'
import { loadCatalog } from './lib/catalogStore.js'
import { isSupabaseConfigured, loadQuickSolutionCatalog } from './lib/supabaseApi.js'

export default function App() {
  const [catalog, setCatalog] = useState(() => loadCatalog(defaultProducts))
  const [fulfilmentPoints, setFulfilmentPoints] = useState([])
  const [catalogSource, setCatalogSource] = useState('local')
  const [selectedId, setSelectedId] = useState('a4-print')
  const [preset, setPreset] = useState({})
  const [query, setQuery] = useState('')
  const [orderMode, setOrderMode] = useState('guided')
  const [journeyId, setJourneyId] = useState('document-guided')
  const [taskContext, setTaskContext] = useState(null)
  const [view, setView] = useState(() => window.location.hash === '#admin' ? 'admin' : 'storefront')
  const configureRef = useRef(null)

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
    setOrderMode('guided')
    setTaskContext(task)
    scrollToConfigure()
  }

  const openPreferred = (product, nextPreset = {}) => {
    if (product.channels?.guided !== false && product.guidedJourneyId) {
      openGuided(product, product.guidedJourneyId, nextPreset)
      return
    }
    openAdvanced(product, nextPreset)
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

  if (view === 'admin') {
    return <AdminProductManager initialProducts={catalog} defaultProducts={defaultProducts} onCatalogChange={setCatalog}/>
  }

  return (
    <div id="top">
      <Header />
      <main>
        <section className="hero shell">
          <div className="hero-copy">
            <span className="eyebrow">Joint X Quick Solution Café · Location 001</span>
            <h1>Need it done?<br/><em>Quick Solution.</em></h1>
            <p>Print documents, make signs, brand clothing and handle everyday business tasks online or in-store. Tell us the outcome — we will guide the technical details.</p>

            <form className="search-wrap" onSubmit={submitSearch}>
              <div className="search-box">
                <Icon name="search" size={20}/>
                <input
                  value={query}
                  onChange={(event) => setQuery(event.target.value)}
                  aria-label="Tell Quick Solution what you need"
                  placeholder="Try “print my CV”, “homework”, “banner”..."
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
              <a className="button dark" href="#start">Show me where to start <Icon name="arrowRight" size={17}/></a>
              <a className="button ghost" href="#quick-points">Find a Quick Point</a>
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
            <div><span className="eyebrow">A simpler way to start</span><h2>What are you trying to do?</h2></div>
            <p>You do not need to know printing terms. Choose the task that sounds closest and answer one question at a time.</p>
          </div>
          <div className="task-grid six-tasks">{quickTasks.map((task) => <QuickTaskCard key={task.id} task={task} onSelect={selectTask}/>)}</div>
        </section>

        <section id="services" className="shell section services-section">
          <div className="section-heading">
            <div><span className="eyebrow">Or browse services</span><h2>I know what I need.</h2></div>
            <p>Choose the service and we will start in Guided mode. If you already know the exact technical specs, Full options is always one tap away.</p>
          </div>
          <div className="product-grid">{customerProducts.map((product) => <ProductCard key={product.id} product={product} active={selectedProduct?.id === product.id} onConfigure={openPreferred}/>)}</div>
        </section>

        {selectedProduct && (
          <section id="configure" ref={configureRef} className="configurator-section">
            <div className="shell">
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
                {selectedProduct.channels?.guided !== false && selectedProduct.guidedJourneyId && (
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
                  onAdvanced={() => setOrderMode('advanced')}
                />
              ) : (
                <ProductConfigurator key={`${selectedProduct.id}-${JSON.stringify(preset)}`} product={selectedProduct} preset={preset} onGuided={selectedJourney ? () => setOrderMode('guided') : null}/>
              )}
            </div>
          </section>
        )}

        <section id="quick-points" className="shell section quick-point-section">
          <div className="quick-copy">
            <span className="eyebrow">Joint X Quick Points</span>
            <h2>Start online.<br/>Collect around the corner.</h2>
            <p>Trusted local businesses can become collection and drop-off points, extending Joint X convenience without requiring a full branch in every neighbourhood.</p>
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
              { id: 'demo-point', name: 'Partner Quick Point', kind: 'quick_point', services: ['Print + apparel collection'], demo: true }
            ]).slice(0, 3).map((point) => (
              <div className="location-row" key={point.id}>
                <div><strong>{point.name}</strong><span>{Array.isArray(point.services) ? point.services.slice(0, 2).join(' · ') : 'Collection point'}</span></div>
                <span>{point.demo ? 'Coming soon' : point.kind === 'cafe' ? 'Location 001' : 'Quick Point'}</span>
              </div>
            ))}
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
      <footer className="shell footer"><strong>Joint X Quick Solution Café</strong><span>Location 001 · Built on XOS · {catalogSource === 'supabase' ? 'Live staging catalogue' : 'Local fallback'} · <a href="#admin">Product Admin</a></span></footer>
    </div>
  )
}
