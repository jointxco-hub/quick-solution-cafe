import React, { useEffect, useMemo, useState } from 'react'
import Icon from '../components/Icon.jsx'
import { cloneCatalog, exportCatalog } from '../lib/catalogStore.js'
import {
  getAdminSession,
  loadQuickSolutionAdminCatalog,
  saveQuickSolutionProduct,
  signInAdmin,
  signOutAdmin
} from '../lib/supabaseApi.js'

const modifierKeys = ['rate', 'fee', 'multiplier', 'total', 'unitFee']

function deepCopy(value) {
  return JSON.parse(JSON.stringify(value))
}

function PricingEditor({ product, onChange }) {
  const updatePricing = (key, value) => {
    onChange({ ...product, pricing: { ...product.pricing, [key]: Math.max(0, Number(value)) } })
  }

  const updateOption = (fieldIndex, optionIndex, key, value) => {
    const next = deepCopy(product)
    next.fields[fieldIndex].options[optionIndex][key] = Math.max(0, Number(value))
    onChange(next)
  }

  return (
    <div className="admin-section-block">
      <div className="admin-section-title">
        <div><span className="eyebrow">Pricing rules</span><h3>{product.pricing.strategy}</h3></div>
        <span className="schema-tag">{product.pricingVersion}</span>
      </div>

      {Object.entries(product.pricing).filter(([key, value]) => key !== 'strategy' && typeof value === 'number').map(([key, value]) => (
        <label className="admin-field" key={key}>
          <span>{key}</span>
          <input min="0" type="number" step="0.01" value={value} onChange={(event) => updatePricing(key, event.target.value)}/>
        </label>
      ))}

      <div className="admin-rate-list">
        {product.fields.map((field, fieldIndex) => {
          const editableOptions = field.options
            ?.map((option, optionIndex) => ({ option, optionIndex, keys: modifierKeys.filter((key) => typeof option[key] === 'number') }))
            .filter((item) => item.keys.length) || []
          if (!editableOptions.length) return null
          return (
            <div className="rate-group" key={field.id}>
              <strong>{field.shortLabel || field.label}</strong>
              {editableOptions.map(({ option, optionIndex, keys }) => (
                <div className="rate-row" key={option.id}>
                  <span>{option.label}</span>
                  <div className="rate-inputs">
                    {keys.map((key) => (
                      <label key={key}>
                        <small>{key}</small>
                        <input min="0" type="number" step="0.01" value={option[key]} onChange={(event) => updateOption(fieldIndex, optionIndex, key, event.target.value)}/>
                      </label>
                    ))}
                  </div>
                </div>
              ))}
            </div>
          )
        })}
      </div>
    </div>
  )
}

function AdminSignIn({ onSignedIn }) {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [state, setState] = useState('idle')
  const [error, setError] = useState('')

  const submit = async (event) => {
    event.preventDefault()
    setError('')
    setState('loading')
    try {
      const session = await signInAdmin(email, password)
      await onSignedIn(session)
      setState('idle')
    } catch (nextError) {
      setError(nextError.message || 'Could not sign in.')
      setState('idle')
    }
  }

  return (
    <div className="admin-auth-page">
      <div className="admin-auth-card">
        <a className="brand" href="#top"><img className="brand-mark-image" src="/jointx-mark.png" alt=""/><span><strong>Quick Solution</strong><small>XOS Product Admin</small></span></a>
        <span className="eyebrow">Secure staff access</span>
        <h1>Product & pricing control.</h1>
        <p>Use your XOS / OPPS staff account. Customer ordering remains available without an account; catalogue changes are staff-only.</p>
        <form onSubmit={submit} className="admin-auth-form">
          <label className="admin-field"><span>Email</span><input autoComplete="username" type="email" required value={email} onChange={(event) => setEmail(event.target.value)} placeholder="staff@jointx.co.za"/></label>
          <label className="admin-field"><span>Password</span><input autoComplete="current-password" type="password" required value={password} onChange={(event) => setPassword(event.target.value)} placeholder="Your XOS password"/></label>
          {error && <div className="admin-auth-error" role="alert">{error}</div>}
          <button className="button dark admin-auth-submit" type="submit" disabled={state === 'loading'}>{state === 'loading' ? 'Signing in…' : 'Sign in securely'}</button>
        </form>
        <a className="text-button admin-back-storefront" href="#top">← Back to storefront</a>
      </div>
    </div>
  )
}

export default function AdminProductManager({ initialProducts, onCatalogChange }) {
  const [session, setSession] = useState(() => getAdminSession())
  const [draft, setDraft] = useState(() => cloneCatalog(initialProducts))
  const [selectedId, setSelectedId] = useState(initialProducts[0]?.id)
  const [dirtyIds, setDirtyIds] = useState(() => new Set())
  const [loadState, setLoadState] = useState(session ? 'loading' : 'signed-out')
  const [saveState, setSaveState] = useState('idle')
  const [notice, setNotice] = useState('')
  const [error, setError] = useState('')

  const activeCount = useMemo(() => draft.filter((item) => item.active !== false).length, [draft])
  const selectedIndex = draft.findIndex((product) => product.id === selectedId)
  const product = draft[selectedIndex] || draft[0]
  const hasChanges = dirtyIds.size > 0

  const adoptCatalog = (products) => {
    const next = cloneCatalog(products || [])
    setDraft(next)
    setSelectedId((current) => next.some((item) => item.id === current) ? current : next[0]?.id)
    setDirtyIds(new Set())
    onCatalogChange?.(cloneCatalog(next))
  }

  const loadLiveAdmin = async () => {
    setLoadState('loading')
    setError('')
    try {
      const data = await loadQuickSolutionAdminCatalog()
      adoptCatalog(data?.products || [])
      setLoadState('ready')
      setNotice('Live catalogue loaded from XOS Staging.')
      return data
    } catch (nextError) {
      setError(nextError.message || 'Could not load Product Admin.')
      setLoadState('error')
      if (nextError.status === 401) {
        await signOutAdmin()
        setSession(null)
      }
      throw nextError
    }
  }

  useEffect(() => {
    if (!session) return
    loadLiveAdmin().catch(() => {})
  }, [])

  useEffect(() => {
    if (!session && !hasChanges && initialProducts?.length) {
      setDraft(cloneCatalog(initialProducts))
    }
  }, [initialProducts, session, hasChanges])

  const onSignedIn = async (nextSession) => {
    setSession(nextSession)
    await loadLiveAdmin()
  }

  const replaceSelected = (nextProduct) => {
    setDraft((current) => current.map((item) => item.id === nextProduct.id ? nextProduct : item))
    setDirtyIds((current) => new Set(current).add(nextProduct.id))
    setNotice('')
    setError('')
  }

  const updateTop = (key, value) => replaceSelected({ ...product, [key]: value })
  const updateChannel = (key, value) => replaceSelected({ ...product, channels: { ...product.channels, [key]: value } })

  const save = async () => {
    if (!hasChanges || saveState === 'saving') return
    setSaveState('saving')
    setError('')
    setNotice('Saving to XOS Staging…')
    try {
      const ids = [...dirtyIds]
      for (const id of ids) {
        const changed = draft.find((item) => item.id === id)
        if (changed) await saveQuickSolutionProduct(changed)
      }
      const data = await loadQuickSolutionAdminCatalog()
      adoptCatalog(data?.products || [])
      setNotice(`${ids.length} product${ids.length === 1 ? '' : 's'} saved. New pricing version${ids.length === 1 ? '' : 's'} created.`)
      setSaveState('saved')
      window.setTimeout(() => setSaveState('idle'), 1800)
    } catch (nextError) {
      setError(nextError.message || 'Catalogue save failed.')
      setSaveState('idle')
    }
  }

  const reload = async () => {
    if (hasChanges && !window.confirm('Discard your unsaved changes and reload the live catalogue?')) return
    await loadLiveAdmin().catch(() => {})
  }

  const logout = async () => {
    await signOutAdmin()
    setSession(null)
    setLoadState('signed-out')
    setDirtyIds(new Set())
  }

  if (!session) return <AdminSignIn onSignedIn={onSignedIn}/>

  if (loadState === 'loading' && draft.length === 0) {
    return <div className="admin-loading"><span className="brand-dot green"/><strong>Loading live Product Admin…</strong></div>
  }

  return (
    <div className="admin-app">
      <header className="admin-header">
        <a className="brand" href="#top"><img className="brand-mark-image" src="/jointx-mark.png" alt=""/><span><strong>Quick Solution</strong><small>XOS Product Admin</small></span></a>
        <div className="admin-header-actions">
          <span>{activeCount} live products</span>
          <span className="admin-live-badge"><i/> XOS Staging</span>
          <a className="button ghost" href="#top">View storefront</a>
          <button className="button dark" type="button" onClick={save} disabled={!hasChanges || saveState === 'saving'}>{saveState === 'saving' ? 'Saving…' : saveState === 'saved' ? 'Saved' : 'Save catalogue'}</button>
        </div>
      </header>

      <main className="admin-shell">
        <section className="admin-intro">
          <div>
            <span className="eyebrow">QS-03.1 · Location 001</span>
            <h1>Product & pricing control.</h1>
            <p>This is now the live Quick Solution catalogue. Saving publishes product configuration and a new pricing version to XOS Staging; existing orders keep their original pricing snapshot.</p>
          </div>
          <div className="admin-intro-actions">
            <button type="button" onClick={() => exportCatalog(draft)}><Icon name="upload" size={18}/> Export JSON</button>
            <button type="button" onClick={reload}>Reload live data</button>
            <button type="button" onClick={logout}>Sign out</button>
          </div>
        </section>

        {(notice || error) && <div className={`admin-system-message ${error ? 'error' : ''}`}>{error || notice}</div>}

        <div className="admin-layout">
          <aside className="admin-products">
            <div className="admin-products-title"><strong>Products</strong><small>{draft.length} configured</small></div>
            {draft.map((item) => (
              <button key={item.id} type="button" className={selectedId === item.id ? 'active' : ''} onClick={() => setSelectedId(item.id)}>
                <span><strong>{item.name}</strong><small>{item.category}</small></span>
                <span className={`status-dot ${item.active === false ? 'off' : ''}`}/>
              </button>
            ))}
          </aside>

          {product && (
            <section className="admin-editor">
              <div className="admin-editor-heading">
                <div><span className="eyebrow">Product</span><h2>{product.name}</h2></div>
                <label className="switch-row"><span>Live</span><input type="checkbox" checked={product.active !== false} onChange={(event) => updateTop('active', event.target.checked)}/><i/></label>
              </div>

              <div className="admin-section-block">
                <span className="eyebrow">Customer-facing details</span>
                <div className="admin-two-col">
                  <label className="admin-field"><span>Product name</span><input value={product.name} onChange={(event) => updateTop('name', event.target.value)}/></label>
                  <label className="admin-field"><span>Category</span><input value={product.category} onChange={(event) => updateTop('category', event.target.value)}/></label>
                </div>
                <label className="admin-field"><span>Plain-language description</span><textarea rows="3" value={product.plainDescription} onChange={(event) => updateTop('plainDescription', event.target.value)}/></label>
              </div>

              <div className="admin-section-block">
                <span className="eyebrow">Where this product appears</span>
                <div className="channel-grid">
                  {[
                    ['storefront', 'Customer storefront', 'Visible in the service catalogue.'],
                    ['guided', 'Guided ordering', 'Simple step-by-step experience.'],
                    ['pos', 'Counter POS', 'Available for staff-assisted sales.'],
                    ['quote', 'Quotes', 'Can be added to a formal quote.']
                  ].map(([key, label, helper]) => (
                    <label className={`channel-card ${product.channels?.[key] ? 'selected' : ''}`} key={key}>
                      <input type="checkbox" checked={Boolean(product.channels?.[key])} onChange={(event) => updateChannel(key, event.target.checked)}/>
                      <span><strong>{label}</strong><small>{helper}</small></span>
                      <i/>
                    </label>
                  ))}
                </div>
              </div>

              <PricingEditor product={product} onChange={replaceSelected}/>

              <div className="admin-save-bar">
                <div>
                  <strong>{hasChanges ? `${dirtyIds.size} product${dirtyIds.size === 1 ? '' : 's'} with unsaved changes` : 'Live catalogue is in sync'}</strong>
                  <span>{hasChanges ? 'Saving creates a new pricing version while preserving every historical order snapshot.' : `Signed in as ${session?.user?.email || 'XOS staff'}.`}</span>
                </div>
                <button className="button primary-green" type="button" onClick={save} disabled={!hasChanges || saveState === 'saving'}>{saveState === 'saving' ? 'Saving…' : 'Save changes'}</button>
              </div>
            </section>
          )}
        </div>
      </main>
    </div>
  )
}
