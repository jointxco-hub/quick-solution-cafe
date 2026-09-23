import React from 'react'
import { getVariantQuantityRule, accessoryCompatible, filterCompatibleAccessories } from '../lib/pricing.js'
import { resolveDisplayLabel } from '../lib/productContent.js'
import { resolveVisualAxisOption } from '../lib/configuratorVisuals.js'

// Decomposed style/size/sides/kit configurator for SUPPLIER_MARGIN
// products (Flags, Gazebos) instead of one long combined dropdown.
// Reads product.pricing.variantAxes/variantTemplate (customer-safe
// metadata, no reference cost/margin) to render one select per axis,
// composes the real variant id from the selections, and exposes
// compatible accessories for the chosen variant. Falls back to
// rendering nothing usable if a product has no variantAxes — callers
// should keep the plain 'variant' select field as a fallback in that
// case (see GuidedOrder.jsx).

function axisValue(config, axisId) {
  return config[`variantAxis_${axisId}`] || ''
}

function composeVariantId(product, config) {
  const template = product.pricing.variantTemplate
  const axes = product.pricing.variantAxes || []
  if (!template) return ''
  let id = template
  for (const axis of axes) {
    const value = axisValue(config, axis.id)
    if (!value) return ''
    id = id.replace(`{${axis.id}}`, value)
  }
  return id
}

function optionAvailable(option, config) {
  if (!option.availableWhen) return true
  return Object.entries(option.availableWhen).every(([axisId, allowed]) =>
    allowed.includes(axisValue(config, axisId))
  )
}

export default function SupplierVariantConfigurator({ product, config, mode = 'simple', onUpdateConfig }) {
  const axes = product.pricing?.variantAxes || []
  const variantId = composeVariantId(product, config)
  const variant = variantId ? product.pricing.variants?.[variantId] : null
  const allAxesChosen = axes.every((axis) => axisValue(config, axis.id))

  const chooseAxis = (axisId, value) => {
    const patch = { [`variantAxis_${axisId}`]: value }
    // Changing an earlier axis can invalidate a later axis's current
    // choice (e.g. switching Gazebo frame from Aluminium to Steel while
    // "3m x 4.5m" was selected) — clear any later axis whose current
    // value is no longer available under the new combination.
    const axisIndex = axes.findIndex((axis) => axis.id === axisId)
    for (let i = axisIndex + 1; i < axes.length; i++) {
      const laterAxis = axes[i]
      const currentValue = axisValue(config, laterAxis.id)
      if (!currentValue) continue
      const nextConfig = { ...config, ...patch }
      const option = laterAxis.options.find((item) => item.id === currentValue)
      if (option && !optionAvailable(option, nextConfig)) {
        patch[`variantAxis_${laterAxis.id}`] = ''
      }
    }
    patch.variant = composeVariantId(product, { ...config, ...patch })
    // Reset quantity to the new variant's minimum whenever the variant
    // changes, so a stale quantity from a different pairs-of-2 rule
    // never silently carries over.
    if (patch.variant) {
      const { minQuantity } = getVariantQuantityRule(product, patch.variant)
      patch.quantity = minQuantity
    }
    // Drop any currently-selected accessory that's no longer compatible
    // with the new variant (e.g. a 2x2 wall selected, then the size
    // changed to 3x3) — the accessory list below already hides it, but
    // without this it would stay silently selected in config, invisible
    // to the customer, and only get caught (correctly, but as a late
    // surprise) by the server's own compatibility check at checkout.
    const currentAccessories = Array.isArray(config.accessories) ? config.accessories : []
    if (currentAccessories.length) {
      patch.accessories = filterCompatibleAccessories(product, currentAccessories, patch.variant)
    }
    onUpdateConfig(patch)
  }

  const quantityRule = variantId ? getVariantQuantityRule(product, variantId) : { minQuantity: 1, quantityStep: 1 }
  const quantity = Math.max(Number(config.quantity || quantityRule.minQuantity), quantityRule.minQuantity)

  const accessories = Object.entries(product.pricing?.accessories || {}).filter(([, accessory]) =>
    variantId ? accessoryCompatible(accessory, variantId) : false
  )
  const selectedAccessories = Array.isArray(config.accessories) ? config.accessories : []

  const toggleAccessory = (accessoryId) => {
    const next = selectedAccessories.includes(accessoryId)
      ? selectedAccessories.filter((id) => id !== accessoryId)
      : [...selectedAccessories, accessoryId]
    onUpdateConfig({ accessories: next })
  }

  return (
    <div className="guided-fields qs14-variant-builder">
      {axes.map((axis) => {
        const options = axis.options.filter((option) => optionAvailable(option, config))
        // QS-18: resolveDisplayLabel(axis, mode) shows the friendlier
        // simpleLabel (e.g. "Do you need the stand too?") in Simple mode
        // where one exists, falling back to today's existing axis.label
        // ("Kit") otherwise - same for each option. Never changes which
        // axis.id/option.id is stored in config.
        const visuals = options.map((option) => ({ option, visual: resolveVisualAxisOption(product, axis.id, option) }))
        const visualMode = visuals.length > 1 && visuals.every(({ visual }) => visual?.image)

        if (visualMode) {
          return (
            <fieldset className="field field-full qs217-visual-axis" key={axis.id}>
              <legend>{product.id === 'flags' && axis.id === 'style' ? 'Choose the flag shape' : resolveDisplayLabel(axis, mode)}</legend>
              <div className="qs217-visual-axis-grid">
                {visuals.map(({ option, visual }) => (
                  <button
                    key={option.id}
                    type="button"
                    className={`qs217-visual-option ${axisValue(config, axis.id) === option.id ? 'selected' : ''}`}
                    onClick={() => chooseAxis(axis.id, option.id)}
                  >
                    <span className="qs217-visual-option-media"><img src={visual.image} alt=""/></span>
                    <span className="qs217-visual-option-copy">
                      <strong>{visual.label}</strong>
                      {visual.helper ? <small>{visual.helper}</small> : null}
                    </span>
                  </button>
                ))}
              </div>
            </fieldset>
          )
        }

        return (
          <label className="field" key={axis.id}>
            <span>{resolveDisplayLabel(axis, mode)}</span>
            <select value={axisValue(config, axis.id)} onChange={(event) => chooseAxis(axis.id, event.target.value)}>
              <option value="" disabled>Choose {axis.label.toLowerCase()}</option>
              {options.map((option) => <option key={option.id} value={option.id}>{resolveDisplayLabel(option, mode)}</option>)}
            </select>
          </label>
        )
      })}

      {allAxesChosen && !variant && (
        <div className="field-full qs14-variant-unavailable">
          <small>That combination isn't available. Try a different size, sides or kit.</small>
        </div>
      )}

      {variant && (
        <label className="field">
          <span>How many?</span>
          <div className="input-with-suffix">
            <input
              type="number"
              min={quantityRule.minQuantity}
              step={quantityRule.quantityStep}
              value={quantity}
              onChange={(event) => onUpdateConfig({ quantity: Number(event.target.value) })}
              inputMode="numeric"
            />
          </div>
          {quantityRule.quantityStep > 1 && (
            <small>Must be ordered in multiples of {quantityRule.quantityStep} (minimum {quantityRule.minQuantity}).</small>
          )}
        </label>
      )}

      {variant && accessories.length > 0 && (
        <fieldset className="field field-full qs14-accessories">
          <legend>Add any accessories</legend>
          <div className="qs14-accessory-grid">
            {accessories.map(([id, accessory]) => (
              <label className="qs14-accessory-option" key={id}>
                <input
                  type="checkbox"
                  checked={selectedAccessories.includes(id)}
                  onChange={() => toggleAccessory(id)}
                />
                <span>{accessory.label}</span>
              </label>
            ))}
          </div>
        </fieldset>
      )}
    </div>
  )
}
