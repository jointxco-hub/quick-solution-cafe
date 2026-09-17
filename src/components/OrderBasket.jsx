import React, { useEffect, useMemo, useState } from 'react'
import Icon from './Icon.jsx'
import { formatMoney } from '../lib/pricing.js'

function displayFileName(file, fileMeta) {
  const raw = String(file?.originalName || file?.name || fileMeta?.originalName || fileMeta?.name || '').trim()
  if (!raw) return ''
  const uuidLike = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}(\.[a-z0-9]+)?$/i
  if (!uuidLike.test(raw)) return raw
  const ext = raw.includes('.') ? raw.split('.').pop().toUpperCase() : ''
  return ext ? `Uploaded ${ext} file` : 'Uploaded file'
}

function pointLabel(point) {
  const address = point?.address || {}
  return [address.area || address.city, address.line1].filter(Boolean).join(' · ')
}

export default function OrderBasket({
  items,
  open,
  fulfilmentPoints = [],
  onClose,
  onRemove,
  onContinueShopping
}) {
  const [phase, setPhase] = useState('basket')
  const [fulfilment, setFulfilment] = useState('cafe')
  const [selectedPointId, setSelectedPointId] = useState('')
  const [deliveryAddress, setDeliveryAddress] = useState('')
  const [customerName, setCustomerName] = useState('')
  const [customerPhone, setCustomerPhone] = useState('')
  const [customerEmail, setCustomerEmail] = useState('')
  const [customerNotes, setCustomerNotes] = useState('')

  const total = items.reduce((sum, item) => sum + Number(item.total || 0), 0)
  const cafePoints = useMemo(
    () => fulfilmentPoints.filter((point) => point.kind === 'cafe' && point.collectionEnabled !== false),
    [fulfilmentPoints]
  )
  const quickPoints = useMemo(
    () => fulfilmentPoints.filter((point) => point.kind === 'quick_point' && point.collectionEnabled !== false),
    [fulfilmentPoints]
  )
  const visiblePoints = fulfilment === 'quick-point' ? quickPoints : cafePoints

  useEffect(() => {
    if (!open) setPhase('basket')
  }, [open])

  useEffect(() => {
    if (fulfilment === 'delivery') {
      setSelectedPointId('')
      return
    }
    if (!visiblePoints.some((point) => point.id === selectedPointId)) {
      setSelectedPointId(visiblePoints[0]?.id || '')
    }
  }, [fulfilment, visiblePoints, selectedPointId])

  if (!open) return null

  return (
    <div className="qs-cart-backdrop" role="presentation" onClick={onClose}>
      <aside className="qs-cart-sheet" role="dialog" aria-modal="true" aria-label="Your order" onClick={(event) => event.stopPropagation()}>
        <div className="qs-cart-head">
          <div>
            <span className="eyebrow">{phase === 'basket' ? 'Your order' : 'Checkout'}</span>
            <h2>{phase === 'basket' ? 'Build one order.' : 'Finish once.'}</h2>
          </div>
          <button type="button" className="qs-cart-close" onClick={onClose} aria-label="Close basket">×</button>
        </div>

        {phase === 'basket' ? (
          <>
            <div className="qs-cart-items">
              {items.map((item) => (
                <article className="qs-cart-item" key={item.cartId}>
                  <div>
                    <span className="eyebrow">{item.category}</span>
                    <strong>{item.productName}</strong>
                    <small>{item.summary || 'Configured item'}</small>
                    {displayFileName(item.file, item.fileMeta) ? <small>File: {displayFileName(item.file, item.fileMeta)}</small> : null}
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
              <button className="button dark" type="button" disabled={items.length === 0} onClick={() => setPhase('checkout')}>Checkout</button>
            </div>
          </>
        ) : (
          <div className="qs-basket-checkout">
            <button className="text-button qs-checkout-back" type="button" onClick={() => setPhase('basket')}>← Back to basket</button>

            <section className="qs-checkout-section">
              <div className="qs-checkout-section-head">
                <span className="eyebrow">1 · Get it your way</span>
                <h3>Collection or delivery?</h3>
              </div>
              <div className="qs-checkout-choice-grid">
                <button type="button" className={fulfilment === 'cafe' ? 'selected' : ''} onClick={() => setFulfilment('cafe')}>
                  <Icon name="store" size={18}/><span><strong>Quick Solution Café</strong><small>Collect from a branch</small></span>
                </button>
                <button type="button" className={fulfilment === 'quick-point' ? 'selected' : ''} disabled={!quickPoints.length} onClick={() => setFulfilment('quick-point')}>
                  <Icon name="pin" size={18}/><span><strong>Quick Point</strong><small>{quickPoints.length ? 'Collect nearby' : 'Coming soon'}</small></span>
                </button>
                <button type="button" className={fulfilment === 'delivery' ? 'selected' : ''} onClick={() => setFulfilment('delivery')}>
                  <Icon name="truck" size={18}/><span><strong>Delivery</strong><small>Price confirmed before payment</small></span>
                </button>
              </div>

              {fulfilment !== 'delivery' && visiblePoints.length > 0 ? (
                <div className="qs-checkout-points">
                  {visiblePoints.map((point) => (
                    <button type="button" key={point.id} className={selectedPointId === point.id ? 'selected' : ''} onClick={() => setSelectedPointId(point.id)}>
                      <span><strong>{point.name}</strong><small>{pointLabel(point) || (point.kind === 'cafe' ? 'Quick Solution café' : 'Quick Point')}</small></span>
                      <span className="radio-dot"/>
                    </button>
                  ))}
                </div>
              ) : null}

              {fulfilment === 'delivery' ? (
                <label className="checkout-field">
                  <span>Delivery address</span>
                  <textarea value={deliveryAddress} onChange={(event) => setDeliveryAddress(event.target.value)} placeholder="Street, area and landmark"/>
                </label>
              ) : null}
            </section>

            <section className="qs-checkout-section">
              <div className="qs-checkout-section-head">
                <span className="eyebrow">2 · Your details</span>
                <h3>Who is this order for?</h3>
                <p>Enter this once for the whole basket.</p>
              </div>
              <label className="checkout-field">
                <span>Name</span>
                <input autoComplete="name" value={customerName} onChange={(event) => setCustomerName(event.target.value)} placeholder="Your name"/>
              </label>
              <div className="checkout-two">
                <label className="checkout-field">
                  <span>WhatsApp / phone</span>
                  <input autoComplete="tel" inputMode="tel" value={customerPhone} onChange={(event) => setCustomerPhone(event.target.value)} placeholder="e.g. 075 123 4567"/>
                </label>
                <label className="checkout-field">
                  <span>Email <small>optional if phone is given</small></span>
                  <input autoComplete="email" inputMode="email" value={customerEmail} onChange={(event) => setCustomerEmail(event.target.value)} placeholder="name@example.com"/>
                </label>
              </div>
              <label className="checkout-field">
                <span>Order notes <small>optional</small></span>
                <textarea value={customerNotes} onChange={(event) => setCustomerNotes(event.target.value)} placeholder="Deadline, instructions or anything that applies to the whole order"/>
              </label>
            </section>

            <div className="qs-checkout-total">
              <div><span>{items.length} item{items.length === 1 ? '' : 's'}</span><small>Product total before any delivery fee</small></div>
              <strong>{formatMoney(total)}</strong>
            </div>

            <button className="button dark qs-place-order" type="button" disabled title="Multi-item backend order creation is QS-13.3">
              Place combined order · backend next
            </button>
            <p className="qs-cart-note">This checkout now collects fulfilment and customer details once for the whole basket. The next step connects it to one multi-item XOS order.</p>
          </div>
        )}
      </aside>
    </div>
  )
}
