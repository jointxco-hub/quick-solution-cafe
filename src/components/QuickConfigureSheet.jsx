import React, { useMemo, useState } from 'react'
import Icon from './Icon.jsx'
import FieldControl from './FieldControl.jsx'
import { calculateProductPrice, formatMoney, getDefaultConfig } from '../lib/pricing.js'
import { resolveConfigPreviewFields, resolveProductDisplayName } from '../lib/productContent.js'

// QS-21 — Quick Configure: desktop contained panel, mobile bottom sheet
// (same DOM, CSS-only layout switch - see qs21-navigation.css). Reuses
// the EXACT fields ProductHub's own "Choices you will make" section
// already curates (resolveConfigPreviewFields()) and the EXACT
// FieldControl/calculateProductPrice() the full configurator uses - no
// second configuration engine, no second pricing. Only rendered when
// resolveQuickConfigureEligibility(product) is true (src/lib/navigation.js) -
// App.jsx is responsible for that gate; this component assumes it.
export default function QuickConfigureSheet({ product, mode = 'simple', onClose, onAddToCart, onFullOptions }) {
  const [config, setConfig] = useState(() => getDefaultConfig(product, {}))

  const previewFieldIds = useMemo(() => resolveConfigPreviewFields(product).map((field) => field.id), [product])
  const fields = useMemo(
    () => previewFieldIds.map((id) => (product.fields || []).find((field) => field?.id === id)).filter(Boolean),
    [previewFieldIds, product]
  )
  const result = useMemo(() => calculateProductPrice(product, config), [product, config])
  const quoteRequired = Boolean(result.metrics?.quoteRequired || result.metrics?.invalid)

  const update = (id, value) => setConfig((current) => ({ ...current, [id]: value }))

  const addToOrder = () => {
    onAddToCart({
      product,
      config,
      total: result.total,
      summary: result.summary,
      quoteRequired
    })
    onClose()
  }

  return (
    <div className="qs21-quickconfig-backdrop" role="presentation" onClick={onClose}>
      <aside
        className="qs21-quickconfig-sheet"
        role="dialog"
        aria-modal="true"
        aria-label={`Quick configure ${product.name}`}
        onClick={(event) => event.stopPropagation()}
      >
        <div className="qs21-quickconfig-head">
          <div>
            <span className="eyebrow">{product.category}</span>
            <h3>{resolveProductDisplayName(product, mode)}</h3>
          </div>
          <button type="button" className="qs21-quickconfig-close" onClick={onClose} aria-label="Close">×</button>
        </div>

        {fields.length > 0 ? (
          <div className="qs21-quickconfig-fields guided-fields">
            {fields.map((field) => (
              <FieldControl
                key={field.id}
                field={field}
                value={config[field.id]}
                onChange={(value) => update(field.id, value)}
                guided
              />
            ))}
          </div>
        ) : (
          <p className="qs21-quickconfig-empty">This product does not have quick choices yet — use Full options below.</p>
        )}

        <div className="qs21-quickconfig-footer">
          <div className="qs21-quickconfig-price">
            <span>{quoteRequired ? 'Quote required' : 'Estimated total'}</span>
            {!quoteRequired && <strong>{formatMoney(result.total)}</strong>}
          </div>
          <div className="qs21-quickconfig-actions">
            <button type="button" className="button ghost" onClick={() => onFullOptions(config)}>
              Full options
            </button>
            <button type="button" className="button dark" onClick={addToOrder} disabled={quoteRequired}>
              Add to order
            </button>
          </div>
        </div>
      </aside>
    </div>
  )
}
