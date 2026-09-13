import React, { useMemo, useState } from 'react'
import Icon from '../components/Icon.jsx'
import { cloneCatalog, exportCatalog, resetCatalog, saveCatalog } from '../lib/catalogStore.js'

const modifierKeys = ['rate', 'fee', 'multiplier', 'total', 'unitFee']

function deepCopy(value) {
  return JSON.parse(JSON.stringify(value))
}

function PricingEditor({ product, onChange }) {
  const updatePricing = (key, value) => {
    onChange({ ...product, pricing: { ...product.pricing, [key]: Number(value) } })
  }

  const updateOption = (fieldIndex, optionIndex, key, value) => {
    const next = deepCopy(product)
    next.fields[fieldIndex].options[optionIndex][key] = Number(value)
    onChange(next)
  }

  return (
    <div className="admin-section-block">
      <div className="admin-section-title"><div><span className="eyebrow">Pricing rules</span><h3>{product.pricing.strategy}</h3></div><span className="schema-tag">{product.pricingVersion}</span></div>

      {Object.entries(product.pricing).filter(([key, value]) => key !== 'strategy' && typeof value === 'number').map(([key, value]) => (
        <label className="admin-field" key={key}><span>{key}</span><input type="number" step="0.01" value={value} onChange={(event) => updatePricing(key, event.target.value)}/></label>
      ))}

      <div className="admin-rate-list">
        {product.fields.map((field, fieldIndex) => {
          const editableOptions = field.options?.map((option, optionIndex) => ({ option, optionIndex, keys: modifierKeys.filter((key) => typeof option[key] === 'number') })).filter((item) => item.keys.length) || []
          if (!editableOptions.length) return null
          return (
            <div className="rate-group" key={field.id}>
              <strong>{field.shortLabel || field.label}</strong>
              {editableOptions.map(({ option, optionIndex, keys }) => (
                <div className="rate-row" key={option.id}>
                  <span>{option.label}</span>
                  <div className="rate-inputs">
                    {keys.map((key) => <label key={key}><small>{key}</small><input type="number" step="0.01" value={option[key]} onChange={(event) => updateOption(fieldIndex, optionIndex, key, event.target.value)}/></label>)}
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

export default function AdminProductManager({ initialProducts, defaultProducts, onCatalogChange }) {
  const [draft, setDraft] = useState(() => cloneCatalog(initialProducts))
  const [selectedId, setSelectedId] = useState(draft[0]?.id)
  const [saved, setSaved] = useState(false)
  const selectedIndex = draft.findIndex((product) => product.id === selectedId)
  const product = draft[selectedIndex] || draft[0]
  const activeCount = useMemo(() => draft.filter((item) => item.active !== false).length, [draft])

  const replaceSelected = (nextProduct) => {
    setDraft((current) => current.map((item) => item.id === nextProduct.id ? nextProduct : item))
    setSaved(false)
  }

  const updateTop = (key, value) => replaceSelected({ ...product, [key]: value })
  const updateChannel = (key, value) => replaceSelected({ ...product, channels: { ...product.channels, [key]: value } })

  const save = () => {
    saveCatalog(draft)
    onCatalogChange?.(cloneCatalog(draft))
    setSaved(true)
  }

  const reset = () => {
    resetCatalog()
    const next = cloneCatalog(defaultProducts)
    setDraft(next)
    setSelectedId(next[0]?.id)
    onCatalogChange?.(next)
    setSaved(false)
  }

  return (
    <div className="admin-app">
      <header className="admin-header">
        <a className="brand" href="#top"><img className="brand-mark-image" src="/jointx-mark.png" alt=""/><span><strong>Quick Solution</strong><small>XOS Product Admin</small></span></a>
        <div className="admin-header-actions"><span>{activeCount} live products</span><a className="button ghost" href="#top">View storefront</a><button className="button dark" type="button" onClick={save}>{saved ? 'Saved' : 'Save catalogue'}</button></div>
      </header>

      <main className="admin-shell">
        <section className="admin-intro">
          <div><span className="eyebrow">QS-02 · Location 001</span><h1>Product & pricing control.</h1><p>The same catalogue is designed to power customer ordering, guided journeys, counter POS and quotes. This prototype saves locally until Supabase is connected.</p></div>
          <div className="admin-intro-actions"><button type="button" onClick={() => exportCatalog(draft)}><Icon name="upload" size={18}/> Export JSON</button><button type="button" onClick={reset}>Reset demo data</button></div>
        </section>

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
              <div className="admin-editor-heading"><div><span className="eyebrow">Product</span><h2>{product.name}</h2></div><label className="switch-row"><span>Live</span><input type="checkbox" checked={product.active !== false} onChange={(event) => updateTop('active', event.target.checked)}/><i/></label></div>

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

              <div className="admin-save-bar"><div><strong>{saved ? 'Catalogue saved locally.' : 'Unsaved catalogue changes'}</strong><span>Supabase persistence and role controls come in the next backend phase.</span></div><button className="button primary-green" type="button" onClick={save}>Save changes</button></div>
            </section>
          )}
        </div>
      </main>
    </div>
  )
}
