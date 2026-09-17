import React from 'react'
import Icon from './Icon.jsx'
import { formatMoney } from '../lib/pricing.js'

export default function OrderBasket({ items, open, onClose, onRemove, onContinueShopping }) {
  const total = items.reduce((sum, item) => sum + Number(item.total || 0), 0)

  return (
    <>
      {items.length > 0 && (
        <button className="qs-cart-bar" type="button" onClick={() => open ? onClose() : null}>
          <span><strong>{items.length} item{items.length === 1 ? '' : 's'}</strong><small>{formatMoney(total)}</small></span>
          <span>View order <Icon name="arrowRight" size={16}/></span>
        </button>
      )}

      {open && (
        <div className="qs-cart-backdrop" role="presentation" onClick={onClose}>
          <aside className="qs-cart-sheet" role="dialog" aria-modal="true" aria-label="Your order" onClick={(event) => event.stopPropagation()}>
            <div className="qs-cart-head">
              <div><span className="eyebrow">Your order</span><h2>Build one order.</h2></div>
              <button type="button" className="qs-cart-close" onClick={onClose} aria-label="Close basket">×</button>
            </div>

            <div className="qs-cart-items">
              {items.map((item) => (
                <article className="qs-cart-item" key={item.cartId}>
                  <div>
                    <span className="eyebrow">{item.category}</span>
                    <strong>{item.productName}</strong>
                    <small>{item.summary || 'Configured item'}</small>
                    {item.file?.name || item.fileMeta?.name ? <small>File: {item.file?.name || item.fileMeta?.name}</small> : null}
                  </div>
                  <div className="qs-cart-item-side">
                    <strong>{item.quoteRequired ? 'Quote' : formatMoney(item.total)}</strong>
                    <button type="button" onClick={() => onRemove(item.cartId)}>Remove</button>
                  </div>
                </article>
              ))}
            </div>

            <div className="qs-cart-total">
              <span>Current basket</span>
              <strong>{formatMoney(total)}</strong>
            </div>

            <div className="qs-cart-actions">
              <button className="button ghost" type="button" onClick={onContinueShopping}>Continue shopping</button>
              <button className="button dark" type="button" disabled title="Multi-item checkout is the next QS-13 step">Checkout basket · next step</button>
            </div>
            <p className="qs-cart-note">QS-13.1 saves configured items into one basket. Multi-item backend checkout and file upload are added next.</p>
          </aside>
        </div>
      )}
    </>
  )
}
