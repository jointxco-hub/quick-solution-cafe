import React from 'react'
import { areaSupplierRate } from '../lib/areaSupplierPricing.js'

export function AreaSupplierEditor({ product, onChange }) {
  const model = product.pricingDefinition?.areaSupplier
  if (!model) return null
  let rate = null
  try { rate = areaSupplierRate(model) } catch { /* Invalid drafts cannot be saved. */ }
  const update = (patch) => onChange({ ...product, pricingDefinition: { ...product.pricingDefinition, areaSupplier: { ...model, ...patch } } })
  return <div className="admin-section-block">
    <span className="eyebrow">Private supplier model · print supply only</span>
    <h3>Contravision cost & margin</h3>
    <p>Customer rate = supplier cost basis ÷ (1 − gross margin). Application and Car Contravision remain separately quoted.</p>
    <div className="admin-two-col">
      <label className="admin-field"><span>Supplier cost per m² (R)</span><input type="number" min="0.01" step="0.01" value={model.supplierCost ?? ''} onChange={e => update({ supplierCost: e.target.value === '' ? null : Number(e.target.value) })}/></label>
      <label className="admin-field"><span>Gross margin (%)</span><input type="number" min="0" max="99.99" step="0.01" value={model.marginRate == null ? '' : model.marginRate * 100} onChange={e => update({ marginRate: e.target.value === '' ? null : Number(e.target.value) / 100 })}/></label>
      <label className="admin-field"><span>Supplier VAT basis</span><select value={model.vatBasis} onChange={e => update({ vatBasis: e.target.value })}><option value="none">Supplier does not charge VAT</option><option value="incl_vat">Supplier price includes VAT</option><option value="excl_vat">Add supplier VAT to the cost</option></select></label>
      <label className="admin-field"><span>Supplier VAT (%)</span><input disabled={model.vatBasis !== 'excl_vat'} type="number" min="0" max="100" step="0.01" value={model.vatRate * 100} onChange={e => update({ vatRate: e.target.value === '' ? null : Number(e.target.value) / 100 })}/></label>
    </div>
    <label className="admin-field"><span>Merchant / supplier reference (private)</span><input value={model.sourceName || ''} onChange={e => update({ sourceName: e.target.value })}/></label>
    <strong>{rate == null ? 'Complete valid cost and margin settings before saving.' : `Customer print rate: R${rate.toFixed(2)} / m²`}</strong>
    <p>The server recalculates the selling rate on save. Minimum billable area and artwork fees are controlled below.</p>
  </div>
}

export function QuoteRequestEditor({ product, onChange }) {
  const operations = product.pricingDefinition?.quoteOperations || {}
  const updateOperations = (patch) => onChange({ ...product, pricingDefinition: { ...product.pricingDefinition, quoteOperations: { ...operations, ...patch } } })
  const updateField = (index, patch) => onChange({ ...product, fields: product.fields.map((field, i) => i === index ? { ...field, ...patch } : field) })
  return <div className="admin-section-block">
    <span className="eyebrow">Quote configuration</span><h3>Request options & merchant notes</h3>
    <p>These products need a confirmed quote before payment. Edit the customer choices and private sourcing notes here; live supplier pricing can be added once matching rates are confirmed.</p>
    <div className="admin-two-col">
      <label className="admin-field"><span>Merchant / supplier reference (private)</span><input value={operations.sourceName || ''} onChange={e => updateOperations({ sourceName: e.target.value })}/></label>
      <label className="admin-field"><span>Lead time / collection arrangements (private)</span><input value={operations.leadTime || ''} onChange={e => updateOperations({ leadTime: e.target.value })}/></label>
    </div>
    <label className="admin-field"><span>Supplier notes (private)</span><textarea rows="3" value={operations.notes || ''} onChange={e => updateOperations({ notes: e.target.value })}/></label>
    {product.fields.map((field, index) => field.type === 'file' ? null : <div className="admin-request-field" key={field.id}>
      <label className="admin-field"><span>Customer field label · {field.id}</span><input value={field.label || ''} onChange={e => updateField(index, { label: e.target.value })}/></label>
      {field.options?.length ? <>
        {field.options.map((option, optionIndex) => <label className="admin-field" key={option.id}><span>Choice · {option.id}</span><input value={option.label} onChange={e => updateField(index, { options: field.options.map((item, i) => i === optionIndex ? { ...item, label: e.target.value } : item) })}/></label>)}
        <label className="admin-field"><span>Default choice</span><select value={field.default} onChange={e => updateField(index, { default: e.target.value })}>{field.options.map(option => <option value={option.id} key={option.id}>{option.label}</option>)}</select></label>
      </> : field.type === 'number' ? <div className="admin-two-col">{['default', 'min', 'max', 'step'].map(key => <label className="admin-field" key={key}><span>{key}</span><input type="number" step="any" value={field[key] ?? ''} onChange={e => updateField(index, { [key]: e.target.value === '' ? '' : Number(e.target.value) })}/></label>)}</div> : <label className="admin-field"><span>Customer prompt / placeholder</span><input value={field.placeholder || ''} onChange={e => updateField(index, { placeholder: e.target.value })}/></label>}
    </div>)}
  </div>
}

export function CataloguePhotoEditor({ product, onChange }) {
  return <div className="admin-section-block">
    <span className="eyebrow">Product photo</span>
    {product.media?.hero && <img className="admin-catalogue-photo" src={product.media.hero} alt={`${product.name} preview`}/>}
    <label className="admin-field"><span>Photo URL or site image path</span><input value={product.media?.hero || ''} placeholder="/qs-catalogue/product-v1.webp" onChange={e => onChange({ ...product, media: { ...product.media, hero: e.target.value } })}/></label>
    <p>Use an existing site image path or a public HTTPS image URL.</p>
  </div>
}
