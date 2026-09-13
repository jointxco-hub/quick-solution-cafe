import React, { useEffect, useMemo, useState } from 'react'
import Icon from '../components/Icon.jsx'
import {
  getEasyLocateConnectorStatus,
  linkEasyLocateBusiness,
  loadQuickSolutionAdminFulfilmentPoints,
  saveQuickSolutionFulfilmentPoint,
  searchEasyLocateBusinesses,
  unlinkEasyLocateBusiness
} from '../lib/supabaseApi.js'

const SERVICE_OPTIONS = [
  ['print', 'Quick print'],
  ['signage', 'Signs & large format'],
  ['apparel', 'Clothing & merch'],
  ['business-services', 'Business services']
]

const blankPoint = () => ({
  id: null,
  slug: '',
  name: '',
  kind: 'quick_point',
  status: 'active',
  address: { line1: '', area: '', city: '', province: '', postalCode: '' },
  contactPhone: '',
  contactEmail: '',
  easyLocateLink: null,
  latitude: '',
  longitude: '',
  collectionEnabled: true,
  dropoffEnabled: true,
  services: ['print'],
  feeAmount: 0,
  openingHours: { display: '' },
  sortOrder: 100,
  orderCount: 0
})

function clonePoint(point) {
  const source = point || blankPoint()
  return {
    ...blankPoint(),
    ...JSON.parse(JSON.stringify(source)),
    address: { ...blankPoint().address, ...(source.address || {}) },
    openingHours: { display: '', ...(source.openingHours || {}) },
    services: Array.isArray(source.services) ? [...source.services] : [],
    easyLocateLink: source.easyLocateLink ? JSON.parse(JSON.stringify(source.easyLocateLink)) : null
  }
}

function statusLabel(status) {
  if (status === 'active') return 'Live'
  if (status === 'coming_soon') return 'Coming soon'
  return 'Inactive'
}

function kindLabel(kind) {
  return kind === 'cafe' ? 'Café / branch' : 'Quick Point'
}

function areaLabel(point) {
  const address = point?.address || {}
  return [address.area, address.city].filter(Boolean).join(' · ') || 'Location details not added yet'
}

function businessLocation(business) {
  return [business?.locationArea, business?.locationExtension].filter(Boolean).join(' · ') || 'Local business'
}

function businessCategories(business) {
  return Array.isArray(business?.categories) && business.categories.length
    ? business.categories.slice(0, 3).join(' · ')
    : 'Business listing'
}

function EasyLocatePanel({ point, onReload, onNotice, onError }) {
  const [connector, setConnector] = useState({ state: 'loading', configured: false, message: '' })
  const [searchOpen, setSearchOpen] = useState(false)
  const [query, setQuery] = useState('')
  const [results, setResults] = useState([])
  const [searchState, setSearchState] = useState('idle')
  const [actionState, setActionState] = useState('idle')

  const link = point?.easyLocateLink || null
  const business = link?.business || null

  useEffect(() => {
    let mounted = true
    getEasyLocateConnectorStatus()
      .then((data) => {
        if (!mounted) return
        setConnector({ state: 'ready', configured: Boolean(data?.configured), message: data?.message || '' })
      })
      .catch((error) => {
        if (!mounted) return
        setConnector({ state: 'error', configured: false, message: error.message || 'Easy Locate connector could not be checked.' })
      })
    return () => { mounted = false }
  }, [])

  const search = async (event) => {
    event?.preventDefault?.()
    const cleanQuery = query.trim()
    if (cleanQuery.length < 2 || searchState === 'searching') return
    setSearchState('searching')
    onError('')
    try {
      const data = await searchEasyLocateBusinesses(cleanQuery)
      setResults(Array.isArray(data?.businesses) ? data.businesses : [])
      setSearchState('ready')
    } catch (error) {
      setSearchState('error')
      onError(error.message || 'Easy Locate search failed.')
    }
  }

  const connect = async (candidate) => {
    if (!point?.id || !candidate?.slug || actionState === 'working') return
    setActionState('working')
    onError('')
    onNotice('Verifying the Easy Locate listing before linking…')
    try {
      await linkEasyLocateBusiness(point.id, candidate.slug)
      await onReload({ selectId: point.id })
      setSearchOpen(false)
      setResults([])
      setQuery('')
      onNotice(`${candidate.name} verified and linked to this fulfilment point.`)
    } catch (error) {
      onError(error.message || 'Easy Locate link failed.')
    } finally {
      setActionState('idle')
    }
  }

  const unlink = async () => {
    if (!point?.id || !link || actionState === 'working') return
    const confirmed = window.confirm(`Unlink ${business?.name || 'this Easy Locate business'} from ${point.name}? The Quick Point itself will stay in XOS.`)
    if (!confirmed) return
    setActionState('working')
    onError('')
    try {
      await unlinkEasyLocateBusiness(point.id)
      await onReload({ selectId: point.id })
      onNotice('Easy Locate business unlinked. The fulfilment point remains in Quick Solution.')
    } catch (error) {
      onError(error.message || 'Could not unlink Easy Locate.')
    } finally {
      setActionState('idle')
    }
  }

  return (
    <div className="quick-point-form-section easy-locate-link-section qs06-easy-locate">
      <div className="quick-point-form-title">
        <span className="eyebrow">Easy Locate</span>
        <h4>Verified local identity.</h4>
      </div>
      <p>Easy Locate owns the business listing. Quick Solution only stores a verified link, while collection fees, services and fulfilment stay controlled here in XOS.</p>

      {!point?.id ? (
        <div className="easy-locate-verified-card neutral">
          <span className="brand-dot green"/>
          <div><strong>Save this Quick Point first</strong><small>Once XOS gives the location a stable ID, you can connect its Easy Locate listing.</small></div>
        </div>
      ) : link ? (
        <div className="easy-locate-linked-stack">
          <div className="easy-locate-verified-card linked">
            <span className="easy-locate-check"><Icon name="checkCircle" size={20}/></span>
            <div className="easy-locate-business-copy">
              <span className="eyebrow">Verified link</span>
              <strong>{business?.name || link.externalSlug}</strong>
              <small>{businessLocation(business)} · {businessCategories(business)}</small>
              <div className="easy-locate-meta-row">
                {business?.verificationLevel ? <span>{business.verificationLevel}</span> : null}
                {business?.claimed ? <span>Claimed listing</span> : null}
                <span>Verified {link.verifiedAt ? new Date(link.verifiedAt).toLocaleDateString('en-ZA') : 'by XOS'}</span>
              </div>
            </div>
          </div>
          <div className="easy-locate-link-actions">
            <button type="button" onClick={() => window.open(link.canonicalUrl, '_blank', 'noopener,noreferrer')}><Icon name="external" size={15}/> View listing</button>
            <button type="button" onClick={() => setSearchOpen((value) => !value)} disabled={!connector.configured}><Icon name="search" size={15}/> Change link</button>
            <button type="button" className="danger-text" onClick={unlink} disabled={actionState === 'working'}>{actionState === 'working' ? 'Working…' : 'Unlink'}</button>
          </div>
        </div>
      ) : (
        <div className="easy-locate-verified-card neutral">
          <span className="brand-dot green"/>
          <div>
            <strong>Not linked yet</strong>
            <small>Find the real business on Easy Locate instead of pasting an ID manually.</small>
          </div>
          <button type="button" className="button dark" onClick={() => setSearchOpen(true)} disabled={!connector.configured || connector.state === 'loading'}>
            <Icon name="search" size={15}/> Find business
          </button>
        </div>
      )}

      {connector.state === 'loading' ? <div className="easy-locate-connector-note">Checking Easy Locate connector…</div> : null}
      {connector.state !== 'loading' && !connector.configured ? (
        <div className="easy-locate-connector-note warn">
          <Icon name="alertCircle" size={16}/>
          <span><strong>One-time connector setup needed.</strong> Add the Easy Locate publishable key to the XOS Edge Function secrets. No business can be marked verified until this is configured.</span>
        </div>
      ) : null}

      {searchOpen && point?.id ? (
        <div className="easy-locate-search-panel">
          <div className="easy-locate-search-head">
            <div><strong>Find on Easy Locate</strong><small>Only public Easy Locate businesses can be linked.</small></div>
            <button type="button" aria-label="Close Easy Locate search" onClick={() => setSearchOpen(false)}>×</button>
          </div>
          <form className="easy-locate-search-form" onSubmit={search}>
            <div className="easy-locate-search-input"><Icon name="search" size={16}/><input autoFocus value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search business name, service or area…"/></div>
            <button type="submit" className="button dark" disabled={query.trim().length < 2 || searchState === 'searching'}>{searchState === 'searching' ? 'Searching…' : 'Search'}</button>
          </form>
          <div className="easy-locate-results">
            {searchState === 'ready' && results.length === 0 ? <div className="easy-locate-empty">No public Easy Locate businesses matched that search.</div> : null}
            {results.map((candidate) => (
              <article key={`${candidate.id}-${candidate.slug}`} className="easy-locate-result-card">
                <div>
                  <span className="eyebrow">{businessCategories(candidate)}</span>
                  <strong>{candidate.name}</strong>
                  <small>{businessLocation(candidate)}</small>
                  {candidate.description ? <p>{candidate.description}</p> : null}
                </div>
                <button type="button" onClick={() => connect(candidate)} disabled={actionState === 'working'}>{actionState === 'working' ? 'Verifying…' : 'Verify & link'}</button>
              </article>
            ))}
          </div>
        </div>
      ) : null}
    </div>
  )
}

export default function AdminQuickPointsPanel({ onPointsChange }) {
  const [points, setPoints] = useState([])
  const [selectedId, setSelectedId] = useState('')
  const [draft, setDraft] = useState(null)
  const [loadState, setLoadState] = useState('loading')
  const [saveState, setSaveState] = useState('idle')
  const [notice, setNotice] = useState('')
  const [error, setError] = useState('')

  const loadPoints = async ({ selectId } = {}) => {
    setLoadState('loading')
    setError('')
    try {
      const data = await loadQuickSolutionAdminFulfilmentPoints()
      const list = Array.isArray(data?.points) ? data.points : []
      setPoints(list)
      onPointsChange?.(list.filter((point) => point.status === 'active'))
      const nextId = selectId && list.some((point) => point.id === selectId)
        ? selectId
        : (list.some((point) => point.id === selectedId) ? selectedId : list[0]?.id || '')
      setSelectedId(nextId)
      const selected = list.find((point) => point.id === nextId)
      setDraft(selected ? clonePoint(selected) : null)
      setLoadState('ready')
      return list
    } catch (nextError) {
      setLoadState('error')
      setError(nextError.message || 'Could not load Quick Points.')
      throw nextError
    }
  }

  useEffect(() => { loadPoints().catch(() => {}) }, [])

  useEffect(() => {
    if (selectedId === 'new') return
    const selected = points.find((point) => point.id === selectedId)
    if (selected) setDraft(clonePoint(selected))
  }, [selectedId])

  const summary = useMemo(() => ({
    activeQuickPoints: points.filter((point) => point.kind === 'quick_point' && point.status === 'active').length,
    linked: points.filter((point) => Boolean(point.easyLocateLink)).length,
    collection: points.filter((point) => point.status === 'active' && point.collectionEnabled).length,
    dropoff: points.filter((point) => point.status === 'active' && point.dropoffEnabled).length
  }), [points])

  const startNew = () => {
    setSelectedId('new')
    setDraft(blankPoint())
    setNotice('New Quick Point draft. Nothing is live until you save it.')
    setError('')
  }

  const update = (key, value) => setDraft((current) => ({ ...current, [key]: value }))
  const updateAddress = (key, value) => setDraft((current) => ({ ...current, address: { ...(current?.address || {}), [key]: value } }))

  const toggleService = (service) => {
    setDraft((current) => {
      const set = new Set(current?.services || [])
      if (set.has(service)) set.delete(service)
      else set.add(service)
      return { ...current, services: [...set] }
    })
  }

  const save = async () => {
    if (!draft || saveState === 'saving') return
    setSaveState('saving')
    setError('')
    setNotice('Saving fulfilment point to XOS Staging…')
    try {
      const result = await saveQuickSolutionFulfilmentPoint(draft)
      const savedId = result?.point?.id || draft.id
      await loadPoints({ selectId: savedId })
      setNotice(`${result?.point?.name || draft.name} saved. ${result?.point?.status === 'active' ? 'It is now available to the storefront.' : 'It is not currently shown as an active collection point.'}`)
      setSaveState('saved')
      window.setTimeout(() => setSaveState('idle'), 1600)
    } catch (nextError) {
      setError(nextError.message || 'Quick Point save failed.')
      setSaveState('idle')
    }
  }

  const selectedExisting = draft?.id ? points.find((point) => point.id === draft.id) : null
  const isPrimaryCafe = draft?.kind === 'cafe'

  return (
    <section className="quick-points-admin">
      <div className="quick-points-heading">
        <div>
          <span className="eyebrow">QS-06 · Fulfilment + local discovery</span>
          <h2>Quick Points.</h2>
          <p>Run collection and drop-off from XOS, then connect each location to its verified Easy Locate business listing when available.</p>
        </div>
        <div className="quick-points-heading-actions">
          <button type="button" onClick={() => loadPoints().catch(() => {})}><Icon name="refresh" size={16}/> Refresh</button>
          <button className="button dark" type="button" onClick={startNew}><span>+</span> Add Quick Point</button>
        </div>
      </div>

      <div className="quick-points-summary">
        <article><span>Live Quick Points</span><strong>{summary.activeQuickPoints}</strong><small>Partner points visible to customers.</small></article>
        <article><span>Collection enabled</span><strong>{summary.collection}</strong><small>Active locations accepting collections.</small></article>
        <article><span>Drop-off enabled</span><strong>{summary.dropoff}</strong><small>Active locations accepting customer drop-offs.</small></article>
        <article><span>Easy Locate verified</span><strong>{summary.linked}</strong><small>Locations connected to a verified public business.</small></article>
      </div>

      {(notice || error) && <div className={`admin-system-message ${error ? 'error' : ''}`}>{error || notice}</div>}

      <div className="quick-points-layout">
        <aside className="quick-points-list-panel">
          <div className="quick-points-list-title"><strong>Fulfilment points</strong><small>{points.length} configured</small></div>
          {loadState === 'loading' ? <div className="handoff-empty">Loading locations…</div> : null}
          <div className="quick-points-list">
            {points.map((point) => (
              <button key={point.id} type="button" className={selectedId === point.id ? 'active' : ''} onClick={() => setSelectedId(point.id)}>
                <div className="quick-point-list-top">
                  <span><strong>{point.name}</strong><small>{kindLabel(point.kind)} · {areaLabel(point)}</small></span>
                  <i className={`quick-point-live-dot ${point.status}`}/>
                </div>
                <div className="quick-point-list-meta">
                  <span>{statusLabel(point.status)}</span>
                  <span>{point.easyLocateLink ? 'Easy Locate ✓' : `${Number(point.orderCount || 0)} order${Number(point.orderCount || 0) === 1 ? '' : 's'}`}</span>
                </div>
              </button>
            ))}
            {selectedId === 'new' ? <button type="button" className="active new-point-card"><strong>New Quick Point</strong><small>Unsaved draft</small></button> : null}
          </div>
        </aside>

        <section className="quick-point-editor">
          {draft ? (
            <>
              <div className="quick-point-editor-head">
                <div>
                  <span className="eyebrow">{draft.id ? kindLabel(draft.kind) : 'New partner location'}</span>
                  <h3>{draft.name || 'Name this Quick Point'}</h3>
                  {draft.slug ? <small>Stable ID · {draft.slug}</small> : <small>A stable ID will be generated on first save.</small>}
                </div>
                <label className="quick-point-status-field">
                  <span>Status</span>
                  <select value={draft.status} onChange={(event) => update('status', event.target.value)}>
                    <option value="active">Live</option>
                    <option value="coming_soon">Coming soon</option>
                    <option value="inactive">Inactive</option>
                  </select>
                </label>
              </div>

              <div className="quick-point-form-grid">
                <div className="quick-point-form-section">
                  <div className="quick-point-form-title"><span className="eyebrow">Identity</span><h4>What is this location?</h4></div>
                  <div className="admin-two-col">
                    <label className="admin-field"><span>Display name</span><input value={draft.name} onChange={(event) => update('name', event.target.value)} placeholder="e.g. Riverside Salon Quick Point"/></label>
                    <label className="admin-field"><span>Point type</span><select value={draft.kind} disabled={Boolean(draft.id)} onChange={(event) => update('kind', event.target.value)}><option value="quick_point">Quick Point</option><option value="cafe">Café / branch</option></select></label>
                  </div>
                  <div className="admin-two-col">
                    <label className="admin-field"><span>Contact phone</span><input value={draft.contactPhone || ''} onChange={(event) => update('contactPhone', event.target.value)} placeholder="+27…"/></label>
                    <label className="admin-field"><span>Contact email</span><input value={draft.contactEmail || ''} onChange={(event) => update('contactEmail', event.target.value)} placeholder="optional"/></label>
                  </div>
                  <label className="admin-field"><span>Opening hours note</span><input value={draft.openingHours?.display || ''} onChange={(event) => update('openingHours', { ...(draft.openingHours || {}), display: event.target.value })} placeholder="e.g. Mon–Sat 08:00–18:00"/></label>
                </div>

                <div className="quick-point-form-section">
                  <div className="quick-point-form-title"><span className="eyebrow">Customer location</span><h4>Where will people collect?</h4></div>
                  <label className="admin-field"><span>Street / landmark</span><input value={draft.address?.line1 || ''} onChange={(event) => updateAddress('line1', event.target.value)} placeholder="Street, shop or landmark"/></label>
                  <div className="admin-two-col"><label className="admin-field"><span>Area</span><input value={draft.address?.area || ''} onChange={(event) => updateAddress('area', event.target.value)} placeholder="Riverside View"/></label><label className="admin-field"><span>City</span><input value={draft.address?.city || ''} onChange={(event) => updateAddress('city', event.target.value)} placeholder="Johannesburg"/></label></div>
                  <div className="admin-two-col"><label className="admin-field"><span>Province</span><input value={draft.address?.province || ''} onChange={(event) => updateAddress('province', event.target.value)} placeholder="Gauteng"/></label><label className="admin-field"><span>Postal code</span><input value={draft.address?.postalCode || ''} onChange={(event) => updateAddress('postalCode', event.target.value)} placeholder="optional"/></label></div>
                  <div className="admin-two-col"><label className="admin-field"><span>Latitude <small>optional</small></span><input inputMode="decimal" value={draft.latitude ?? ''} onChange={(event) => update('latitude', event.target.value)} placeholder="-25.9"/></label><label className="admin-field"><span>Longitude <small>optional</small></span><input inputMode="decimal" value={draft.longitude ?? ''} onChange={(event) => update('longitude', event.target.value)} placeholder="28.0"/></label></div>
                </div>

                <div className="quick-point-form-section">
                  <div className="quick-point-form-title"><span className="eyebrow">Services</span><h4>What can happen here?</h4></div>
                  <div className="quick-point-toggle-grid">
                    <label className={`channel-card ${draft.collectionEnabled ? 'selected' : ''}`}><input type="checkbox" checked={Boolean(draft.collectionEnabled)} onChange={(event) => update('collectionEnabled', event.target.checked)}/><span><strong>Customer collection</strong><small>Customers can collect completed jobs here.</small></span><i/></label>
                    <label className={`channel-card ${draft.dropoffEnabled ? 'selected' : ''}`}><input type="checkbox" checked={Boolean(draft.dropoffEnabled)} onChange={(event) => update('dropoffEnabled', event.target.checked)}/><span><strong>Customer drop-off</strong><small>Customers can leave items or documents here.</small></span><i/></label>
                  </div>
                  <div className="quick-point-service-grid">{SERVICE_OPTIONS.map(([key, label]) => <label key={key} className={draft.services?.includes(key) ? 'selected' : ''}><input type="checkbox" checked={Boolean(draft.services?.includes(key))} onChange={() => toggleService(key)}/><span>{label}</span><i/></label>)}</div>
                  <div className="admin-two-col"><label className="admin-field"><span>Collection fee (R)</span><input min="0" step="0.01" type="number" value={draft.feeAmount ?? 0} onChange={(event) => update('feeAmount', event.target.value)} /></label><label className="admin-field"><span>Display order</span><input type="number" value={draft.sortOrder ?? 100} onChange={(event) => update('sortOrder', event.target.value)} /></label></div>
                </div>

                <EasyLocatePanel point={draft} onReload={loadPoints} onNotice={setNotice} onError={setError}/>
              </div>

              {isPrimaryCafe ? <div className="quick-point-protection-note"><Icon name="store" size={18}/><span><strong>Primary café protection.</strong> XOS will not let you disable the last active café collection location.</span></div> : null}

              <div className="quick-point-save-bar">
                <div><strong>{draft.id ? 'Update fulfilment point' : 'Create Quick Point'}</strong><span>{draft.status === 'active' ? 'Saving makes this location available to the customer storefront.' : 'This location will stay hidden from active customer collection choices.'}</span></div>
                <button className="button primary-green" type="button" onClick={save} disabled={saveState === 'saving'}>{saveState === 'saving' ? 'Saving…' : saveState === 'saved' ? 'Saved' : 'Save location'}</button>
              </div>

              {selectedExisting && Number(selectedExisting.orderCount || 0) > 0 ? <p className="quick-point-history-note">This location has {selectedExisting.orderCount} historical order{Number(selectedExisting.orderCount) === 1 ? '' : 's'}. Its stable ID and point type are protected so old jobs remain understandable.</p> : null}
            </>
          ) : <div className="handoff-empty large">Choose a fulfilment point or add a new Quick Point.</div>}
        </section>
      </div>
    </section>
  )
}
