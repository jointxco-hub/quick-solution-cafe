import React from 'react'

// Customer-facing deliverables picker for PHOTOGRAPHY_SESSION products.
// Reads product.pricing.deliverables (the customer-safe mirror — label
// + price only, admin-managed) rather than a hardcoded list, so a
// deliverable an admin adds shows up here without any code change, and
// one they remove disappears the same way. A deliverable with no price
// yet still shows, marked "Quote required" — selecting it is exactly
// what should push the whole request to quote-required (handled by
// pricing.js), never silently free.
export default function PhotoDeliverablesField({ product, config, onUpdateConfig }) {
  const deliverables = Object.entries(product.pricing?.deliverables || {})
  const selected = Array.isArray(config.deliverables) ? config.deliverables : []

  const toggle = (id) => {
    const next = selected.includes(id)
      ? selected.filter((item) => item !== id)
      : [...selected, id]
    onUpdateConfig({ deliverables: next })
  }

  if (!deliverables.length) {
    return (
      <div className="guided-fields">
        <p className="field-full qs14-empty-note">No extra deliverables are available to add right now — WhatsApp us if you need something specific.</p>
      </div>
    )
  }

  return (
    <div className="guided-fields">
      <fieldset className="field field-full qs14-accessories">
        <legend>Anything extra to deliver?</legend>
        <div className="qs14-accessory-grid">
          {deliverables.map(([id, deliverable]) => (
            <label className="qs14-accessory-option" key={id}>
              <input
                type="checkbox"
                checked={selected.includes(id)}
                onChange={() => toggle(id)}
              />
              <span>
                {deliverable.label}
                {deliverable.price != null ? ` — R${Number(deliverable.price).toFixed(2)}` : ' — Quote required'}
              </span>
            </label>
          ))}
        </div>
      </fieldset>
    </div>
  )
}
