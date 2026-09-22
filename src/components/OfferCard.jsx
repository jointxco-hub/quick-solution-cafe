import React, { useMemo, useState } from 'react'
import Icon from './Icon.jsx'
import { formatMoney } from '../lib/pricing.js'
import { composeVariantSummary, resolveDisplayLabel } from '../lib/productContent.js'
import { calculateOfferPrice, resolveOfferCartLines, resolveOfferDisplayName, resolveOfferDisplayDescription, resolveOfferPriceDisplay } from '../lib/offers.js'

// QS-20 — one Offer/Combo card. Mirrors ProductHub's existing "Quick
// options" preset card pattern (same Choose this / Customise language,
// same card language QS-19 already established) rather than inventing
// a new visual vocabulary. Customisation is intentionally simple and
// deterministic (per the QS-20 brief - no drag/drop builder): the
// customer can drop any item explicitly marked optional and change any
// item's repeat quantity; changing WHICH preset/variant a line uses is
// out of scope for this pass - see the QS-20 report.
function lineDisplaySummary(line, products, mode) {
  const product = (products || []).find((item) => item.id === line.productId)
  const variantId = line.config?.variant
  const composed = product && variantId ? composeVariantSummary(product, variantId, mode) : null
  return composed || line.summary
}

export default function OfferCard({ offer, products, mode = 'simple', onChooseThis, onCustomiseLine }) {
  const [expanded, setExpanded] = useState(false)
  const [excludedItemIds, setExcludedItemIds] = useState([])
  const [quantityOverrides, setQuantityOverrides] = useState({})

  const baseResult = useMemo(() => calculateOfferPrice(offer, products), [offer, products])
  const customizedResult = useMemo(
    () => resolveOfferCartLines(offer, products, { excludedItemIds, quantityOverrides }),
    [offer, products, excludedItemIds, quantityOverrides]
  )

  const name = resolveOfferDisplayName(offer, mode)
  const description = resolveOfferDisplayDescription(offer, mode)
  // QS-20 final review: never "From R…" - see resolveOfferPriceDisplay()/
  // offers.js for why (the collapsed card's total is the CURRENT, fixed
  // default composition's real price, not a minimum).
  const priceDisplay = resolveOfferPriceDisplay(offer, baseResult)

  const toggleOptional = (itemId) => {
    setExcludedItemIds((current) => current.includes(itemId) ? current.filter((id) => id !== itemId) : [...current, itemId])
  }

  const changeQuantity = (itemId, nextQuantity) => {
    setQuantityOverrides((current) => ({ ...current, [itemId]: Math.max(Number(nextQuantity) || 1, 1) }))
  }

  return (
    <div className="qs20-offer-card">
      <strong>{name}</strong>
      {description && <p className="qs20-offer-description">{description}</p>}

      <ul className="qs20-offer-items">
        {baseResult.lines.map((line) => (
          <li key={line.id || line.productId}>
            <Icon name="checkCircle" size={15}/>
            <span>{resolveDisplayLabel({ label: line.productName }, mode)}{line.quantity > 1 ? ` × ${line.quantity}` : ''}</span>
          </li>
        ))}
      </ul>

      <p className="qs20-offer-price">
        {priceDisplay.quoteRequired ? priceDisplay.priceText : <strong>{priceDisplay.priceText}</strong>}
      </p>
      {priceDisplay.note && <small className="qs20-offer-price-note">{priceDisplay.note}</small>}

      <div className="qs20-offer-actions">
        <button type="button" className="button dark" onClick={() => onChooseThis(baseResult)}>
          Choose this
        </button>
        <button type="button" className="button ghost" onClick={() => setExpanded((value) => !value)}>
          {expanded ? 'Hide options' : 'Customise'}
        </button>
      </div>

      {expanded && (
        <div className="qs20-offer-customise">
          {/* QS-20 final review fix: iterate baseResult.lines (EVERY
              item, always) rather than customizedResult.lines (only
              currently-included ones) - the earlier version made an
              excluded optional item's whole row, checkbox included,
              disappear the moment it was unchecked, with no way to
              re-include it. Every item now always has a row; an
              excluded optional item shows unchecked + "Removed" but
              its checkbox stays available. */}
          {baseResult.lines.map((line) => {
            const item = (offer.items || []).find((entry) => entry.id === line.id)
            const isOptional = Boolean(item?.optional)
            const isExcluded = isOptional && excludedItemIds.includes(line.id)
            const liveQuantity = quantityOverrides[line.id] ?? line.quantity
            const liveLineTotal = line.quoteRequired ? null : line.unitTotal * liveQuantity
            return (
              <div key={line.id || line.productId} className={`qs20-offer-customise-row${isExcluded ? ' qs20-offer-row-excluded' : ''}`}>
                <div className="qs20-offer-customise-info">
                  {isOptional && (
                    <label className="qs20-offer-optional-toggle">
                      <input type="checkbox" checked={!isExcluded} onChange={() => toggleOptional(line.id)}/>
                      <span/>
                    </label>
                  )}
                  <div>
                    <strong>{line.productName}{isOptional && <span className="qs20-offer-optional-tag"> · optional</span>}</strong>
                    <small>{lineDisplaySummary(line, products, mode)}</small>
                  </div>
                </div>
                <div className="qs20-offer-customise-controls">
                  <div className="qs20-offer-qty-stepper">
                    <button type="button" onClick={() => changeQuantity(line.id, liveQuantity - 1)} disabled={isExcluded || liveQuantity <= 1} aria-label={`Fewer ${line.productName}`}>−</button>
                    <span>{liveQuantity}</span>
                    <button type="button" onClick={() => changeQuantity(line.id, liveQuantity + 1)} disabled={isExcluded} aria-label={`More ${line.productName}`}>+</button>
                  </div>
                  <strong>{isExcluded ? 'Removed' : (line.quoteRequired ? 'Quote' : formatMoney(liveLineTotal))}</strong>
                  {onCustomiseLine && !isExcluded && (
                    <button type="button" className="qs20-offer-change-line" onClick={() => onCustomiseLine(line, item)}>
                      Change
                    </button>
                  )}
                </div>
              </div>
            )
          })}
          <div className="qs20-offer-customise-total">
            <span>{customizedResult.quoteRequired ? 'Some items need a quote' : 'Customised total'}</span>
            <strong>{customizedResult.quoteRequired ? 'Quote required' : formatMoney(customizedResult.total)}</strong>
          </div>
          <button type="button" className="button dark qs20-offer-add-customised" onClick={() => onChooseThis(customizedResult)}>
            Add to order
          </button>
        </div>
      )}
    </div>
  )
}
