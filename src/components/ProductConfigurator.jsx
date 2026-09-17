import React, { useEffect, useMemo, useState } from 'react'
import { calculateProductPrice, formatMoney, getDefaultConfig } from '../lib/pricing.js'
import Icon from './Icon.jsx'
import FieldControl from './FieldControl.jsx'

export default function ProductConfigurator({
  product,
  preset = {},
  onSnapshot,
  onGuided,
  onContinue,
  onAddToCart
}) {
  const [config, setConfig] = useState(() => getDefaultConfig(product, preset))
  const [file, setFile] = useState(null)
  const [itemAdded, setItemAdded] = useState(false)

  useEffect(() => {
    setConfig(getDefaultConfig(product, preset))
    setFile(null)
    setItemAdded(false)
  }, [product, preset])

  const result = useMemo(() => calculateProductPrice(product, config), [product, config])

  useEffect(() => {
    onSnapshot?.(result.snapshot)
  }, [result.snapshot, onSnapshot])

  const update = (id, value) => {
    setItemAdded(false)
    setConfig((previous) => ({ ...previous, [id]: value }))
  }

  const addCurrentItemToCart = () => {
    if (itemAdded) return
    onAddToCart?.({
      product,
      config,
      file,
      files: Array.isArray(file) ? file : (file ? [file] : []),
      total: result.total,
      summary: result.summary,
      quoteRequired: product?.pricing?.strategy === 'ENQUIRY'
    })
    setItemAdded(true)
  }

  return (
    <div className="configurator-grid">
      <div className="config-panel">
        <div className="config-intro">
          <div>
            <span className="eyebrow">Full options</span>
            <h2>{product.name}</h2>
            <p className="section-copy">{product.plainDescription}</p>
          </div>
          <span className="pricing-pill">Live price</span>
        </div>

        <div className="plain-language-note">
          <Icon name="help" size={19}/>
          <div><strong>Want the simpler version?</strong><span>Use guided ordering and answer one question at a time.</span></div>
          {onGuided && <button className="inline-guide-button" type="button" onClick={onGuided}>Guide me</button>}
        </div>

        <div className="field-grid">
          {product.fields.map((field) => (
            <FieldControl
              key={field.id}
              field={field}
              value={config[field.id]}
              onChange={(value) => update(field.id, value)}
              file={file}
              onFileChange={(nextFile) => { setFile(nextFile); setItemAdded(false) }}
            />
          ))}
        </div>
      </div>

      <aside className="price-card" aria-live="polite">
        <span className="eyebrow inverse">Estimated total</span>
        <div className="price">{formatMoney(result.total)}</div>
        <p>{result.summary}</p>

        <div className="price-lines">
          {result.lines.map((line, index) => (
            <div key={`${line.label}-${index}`}>
              <span>{line.label}</span>
              <strong>{line.text ?? formatMoney(line.value)}</strong>
            </div>
          ))}
        </div>

        <div className="order-confidence">
          <strong>{product.name}</strong>
          <span>Configuration and pricing are captured together so the counter, quote and production job can use the same details.</span>
        </div>

        <button
          className={`primary-light ${itemAdded ? 'added' : ''}`}
          type="button"
          disabled={itemAdded}
          onClick={addCurrentItemToCart}
        >
          {itemAdded ? 'Added to order' : 'Add to order'}
        </button>
        <p className="qs-shop-first-note">Add this item to your order. You will choose collection or delivery and enter your details once at checkout.</p>
        <button
          className="secondary-dark"
          type="button"
          disabled
          title="Quote saving will be added in the next phase."
        >
          Save as quote · coming soon
        </button>
        <a className="help-link" href="https://wa.me/27754534646" target="_blank" rel="noreferrer">
          <Icon name="message" size={17}/> Need help? WhatsApp us
        </a>
        <small className="price-note">QS-02 prototype rates. Pricing rules are versioned and the calculation is snapshotted for each future order.</small>
      </aside>
    </div>
  )
}
