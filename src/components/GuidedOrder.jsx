import React, { useEffect, useMemo, useState } from 'react'
import Icon from './Icon.jsx'
import FieldControl from './FieldControl.jsx'
import { calculateProductPrice, formatMoney, getDefaultConfig } from '../lib/pricing.js'
import { fulfilmentOptions } from '../data/products.js'

function optionLabel(product, fieldId, value) {
  const field = product.fields.find((item) => item.id === fieldId)
  if (!field) return value
  if (field.type === 'number') return `${value}${field.suffix ? ` ${field.suffix}` : ''}`
  return field.options?.find((item) => item.id === value)?.label || value
}

function ReviewRows({ product, config, fulfilment, file }) {
  const rows = product.fields
    .filter((field) => field.type !== 'file')
    .map((field) => ({ label: field.shortLabel || field.label, value: optionLabel(product, field.id, config[field.id]) }))

  const fulfilmentLabel = fulfilmentOptions.find((item) => item.id === fulfilment)?.label

  return (
    <div className="review-list">
      {rows.map((row) => <div key={row.label}><span>{row.label}</span><strong>{row.value}</strong></div>)}
      <div><span>File</span><strong>{file?.name || 'Add before checkout'}</strong></div>
      <div><span>Collection</span><strong>{fulfilmentLabel}</strong></div>
    </div>
  )
}

export default function GuidedOrder({ product, journey, preset = {}, task, onAdvanced }) {
  const [config, setConfig] = useState(() => getDefaultConfig(product, preset))
  const [file, setFile] = useState(null)
  const [fulfilment, setFulfilment] = useState('cafe')
  const [stepIndex, setStepIndex] = useState(0)
  const [complete, setComplete] = useState(false)

  useEffect(() => {
    setConfig(getDefaultConfig(product, preset))
    setFile(null)
    setFulfilment('cafe')
    setStepIndex(0)
    setComplete(false)
  }, [product, journey, preset])

  const result = useMemo(() => calculateProductPrice(product, config), [product, config])
  const step = journey.steps[stepIndex]
  const progress = ((stepIndex + 1) / journey.steps.length) * 100
  const update = (id, value) => setConfig((previous) => ({ ...previous, [id]: value }))

  if (complete) {
    return (
      <div className="guided-complete">
        <div className="complete-mark"><Icon name="bag" size={28}/></div>
        <span className="eyebrow">QS-02 prototype</span>
        <h2>Your order is ready for the checkout layer.</h2>
        <p>We have the product, configuration, price snapshot and collection choice. The next phase will persist this as a real quote/order and send it into OPPS.</p>
        <div className="complete-summary"><strong>{product.name}</strong><span>{formatMoney(result.total)}</span></div>
        <button className="button dark" type="button" onClick={() => { setComplete(false); setStepIndex(0) }}>Start again</button>
      </div>
    )
  }

  return (
    <div className="guided-shell">
      <div className="guided-main">
        <div className="guided-topline">
          <button className="text-button" type="button" onClick={onAdvanced}>Switch to Full options</button>
          <span>{stepIndex + 1} of {journey.steps.length}</span>
        </div>
        <div className="progress-track"><span style={{ width: `${progress}%` }}/></div>

        <div className="guided-heading">
          <span className="eyebrow">{task?.kicker || step.eyebrow}</span>
          <h2>{step.title}</h2>
          <p>{step.helper}</p>
        </div>

        {step.fields && (
          <div className="guided-fields">
            {step.fields.map((fieldId) => {
              const field = product.fields.find((item) => item.id === fieldId)
              if (!field) return null
              return (
                <FieldControl
                  key={field.id}
                  field={field}
                  value={config[field.id]}
                  onChange={(value) => update(field.id, value)}
                  file={file}
                  onFileChange={setFile}
                  guided
                />
              )
            })}
          </div>
        )}

        {step.type === 'fulfilment' && (
          <div className="fulfilment-grid">
            {fulfilmentOptions.map((item) => (
              <button key={item.id} className={`fulfilment-option ${fulfilment === item.id ? 'selected' : ''}`} type="button" onClick={() => setFulfilment(item.id)}>
                <span className="fulfilment-icon"><Icon name={item.icon} size={23}/></span>
                <span><strong>{item.label}</strong><small>{item.helper}</small></span>
                <span className="radio-dot"/>
              </button>
            ))}
          </div>
        )}

        {step.type === 'review' && (
          <>
            <ReviewRows product={product} config={config} fulfilment={fulfilment} file={file}/>
            <div className="guest-note"><Icon name="user" size={19}/><span><strong>No account required for a quick order.</strong> You can save your details after ordering if you want easier reorders next time.</span></div>
          </>
        )}

        <div className="guided-actions">
          <button className="button ghost" type="button" disabled={stepIndex === 0} onClick={() => setStepIndex((value) => Math.max(0, value - 1))}>Back</button>
          {stepIndex < journey.steps.length - 1 ? (
            <button className="button primary-green" type="button" onClick={() => setStepIndex((value) => value + 1)}>Continue <Icon name="arrowRight" size={17}/></button>
          ) : (
            <button className="button primary-green" type="button" onClick={() => setComplete(true)}>Create order <Icon name="arrowRight" size={17}/></button>
          )}
        </div>
      </div>

      <aside className="guided-summary" aria-live="polite">
        <span className="eyebrow inverse">Estimated total</span>
        <div className="guided-price">{formatMoney(result.total)}</div>
        <p>{result.summary}</p>
        <div className="price-lines compact-lines">
          {result.lines.map((line, index) => (
            <div key={`${line.label}-${index}`}><span>{line.label}</span><strong>{line.text ?? formatMoney(line.value)}</strong></div>
          ))}
        </div>
        <div className="summary-confidence"><span className="brand-dot green"/><span>We confirm unusual files or production details before printing.</span></div>
        <a className="help-link" href="https://wa.me/27754534646" target="_blank" rel="noreferrer"><Icon name="message" size={17}/> Need help? WhatsApp us</a>
      </aside>
    </div>
  )
}
