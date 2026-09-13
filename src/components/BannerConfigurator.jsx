import React from 'react'
import { useMemo, useState } from 'react'
import { calculateBannerPrice, formatMoney } from '../lib/pricing.js'

const defaults = {
  width: 2,
  height: 1,
  material: 'standard',
  finishing: 'hem-eyelets',
  artwork: 'ready',
  turnaround: 'standard'
}

function Select({ label, value, onChange, items }) {
  return (
    <label className="field">
      <span>{label}</span>
      <select value={value} onChange={(e) => onChange(e.target.value)}>
        {items.map((item) => <option key={item.id} value={item.id}>{item.label}</option>)}
      </select>
    </label>
  )
}

export default function BannerConfigurator({ product }) {
  const [config, setConfig] = useState(defaults)
  const result = useMemo(() => calculateBannerPrice(product, config), [product, config])
  const set = (key, value) => setConfig((prev) => ({ ...prev, [key]: value }))

  return (
    <div className="configurator-grid">
      <div className="config-panel">
        <span className="eyebrow">Live configurator · same engine for web + POS</span>
        <h2>Build your PVC banner</h2>
        <p className="section-copy">Enter the finished size, then choose material, finishing, artwork support and turnaround.</p>

        <div className="dimension-grid">
          <label className="field">
            <span>Width (metres)</span>
            <input type="number" min="0.1" step="0.1" value={config.width} onChange={(e) => set('width', e.target.value)} />
          </label>
          <label className="field">
            <span>Height (metres)</span>
            <input type="number" min="0.1" step="0.1" value={config.height} onChange={(e) => set('height', e.target.value)} />
          </label>
        </div>

        <Select label="Material" value={config.material} onChange={(v) => set('material', v)} items={product.options.material} />
        <Select label="Finishing" value={config.finishing} onChange={(v) => set('finishing', v)} items={product.options.finishing} />
        <Select label="Artwork" value={config.artwork} onChange={(v) => set('artwork', v)} items={product.options.artwork} />
        <Select label="Turnaround" value={config.turnaround} onChange={(v) => set('turnaround', v)} items={product.options.turnaround} />
      </div>

      <aside className="price-card">
        <span className="eyebrow inverse">Instant price</span>
        <div className="price">{formatMoney(result.total)}</div>
        <p>{result.rawArea.toFixed(2)}m² actual · {result.billableArea.toFixed(2)}m² billable</p>

        <div className="price-lines">
          <div><span>Print + material</span><strong>{formatMoney(result.printBase)}</strong></div>
          <div><span>Finishing + artwork</span><strong>{formatMoney(result.serviceFees)}</strong></div>
          <div><span>Turnaround</span><strong>{result.turnaround.label}</strong></div>
        </div>

        <button className="primary-light">Continue to artwork</button>
        <button className="secondary-dark">Save as quote</button>
        <small className="price-note">Demo pricing only. Production rates will be managed from XOS Admin and snapshotted onto each order.</small>
      </aside>
    </div>
  )
}
