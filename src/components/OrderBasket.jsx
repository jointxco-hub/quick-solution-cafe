import React, { useEffect, useMemo, useState } from 'react'
import Icon from './Icon.jsx'
import { formatMoney } from '../lib/pricing.js'
import { beginQuickSolutionPayment, createQuickSolutionCartOrder, uploadQuickSolutionFile } from '../lib/supabaseApi.js'
import { saveQuickSolutionPaymentSession } from '../lib/paymentSession.js'
import { buildQuickSolutionTrackingHref, saveQuickSolutionTrackingSession } from '../lib/trackingSession.js'

function displayFileName(file, fileMeta) {
  const raw = String(file?.originalName || file?.name || fileMeta?.originalName || fileMeta?.name || '').trim()
  if (!raw) return ''
  const uuidLike = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}(\.[a-z0-9]+)?$/i
  if (!uuidLike.test(raw)) return raw
  const ext = raw.includes('.') ? raw.split('.').pop().toUpperCase() : ''
  return ext ? `Uploaded ${ext} file` : 'Uploaded file'
}

function itemFiles(item) {
  if (Array.isArray(item?.files) && item.files.length) return item.files
  if (item?.file) return [item.file]
  return []
}

function itemFileMetas(item) {
  if (Array.isArray(item?.filesMeta) && item.filesMeta.length) return item.filesMeta
  if (item?.fileMeta) return [item.fileMeta]
  return []
}

function pointLabel(point) {
  const address = point?.address || {}
  return [address.area || address.city, address.line1].filter(Boolean).join(' · ')
}

// QS-20: presentation only - groups consecutive cart items that share
// an offerId under that offer's name, e.g. "Event Starter" showing its
// 3×3 Gazebo / Flags / Banner lines together instead of as three
// unrelated rows. The cart itself (and the order payload built from it
// in submitCombinedOrder) is unchanged: every item is still submitted
// as its own independent {productKey, configuration} line - this only
// changes how the basket is DISPLAYED. An item with no offerId gets its
// own single-item "group" so ungrouped items render exactly as before.
function groupCartItemsByOffer(items) {
  const groups = []
  for (const item of items) {
    const last = groups[groups.length - 1]
    if (item.offerId && last?.offerId === item.offerId) {
      last.items.push(item)
    } else {
      groups.push({ offerId: item.offerId || null, offerName: item.offerName || null, items: [item] })
    }
  }
  return groups
}

export default function OrderBasket({
  items,
  open,
  fulfilmentPoints = [],
  onClose,
  onRemove,
  onContinueShopping,
  onOrderCreated
}) {
  const [phase, setPhase] = useState('basket')
  const [fulfilment, setFulfilment] = useState('cafe')
  const [selectedPointId, setSelectedPointId] = useState('')
  const [deliveryAddress, setDeliveryAddress] = useState('')
  const [customerName, setCustomerName] = useState('')
  const [customerPhone, setCustomerPhone] = useState('')
  const [customerEmail, setCustomerEmail] = useState('')
  const [customerNotes, setCustomerNotes] = useState('')
  const [submitState, setSubmitState] = useState('idle')
  const [submitError, setSubmitError] = useState('')
  const [orderResponse, setOrderResponse] = useState(null)
  const [uploadResults, setUploadResults] = useState([])
  const [paymentState, setPaymentState] = useState('idle')
  const [paymentError, setPaymentError] = useState('')
  const [idempotencyKey] = useState(() => globalThis.crypto?.randomUUID?.() || `qsc-cart-${Date.now()}-${Math.random().toString(36).slice(2)}`)

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

  const submitCombinedOrder = async () => {
    setSubmitError('')
    if (!items.length) {
      setSubmitError('Add at least one item to your order.')
      return
    }
    if (customerName.trim().length < 2) {
      setSubmitError('Please add the name we should use for this order.')
      return
    }
    if (!customerPhone.trim() && !customerEmail.trim()) {
      setSubmitError('Add a WhatsApp/phone number or email so we can contact you.')
      return
    }
    if (fulfilment === 'quick-point' && !selectedPointId) {
      setSubmitError('Choose a Quick Point.')
      return
    }
    if (fulfilment !== 'delivery' && !selectedPointId && visiblePoints.length) {
      setSubmitError('Choose a collection point.')
      return
    }
    if (fulfilment === 'delivery' && deliveryAddress.trim().length < 5) {
      setSubmitError('Add the delivery address.')
      return
    }

    setSubmitState('submitting')
    try {
      const response = await createQuickSolutionCartOrder({
        items: items.map((item) => ({
          clientItemKey: item.cartId,
          productKey: item.productId,
          configuration: item.config || {}
        })),
        customerName: customerName.trim(),
        customerPhone: customerPhone.trim(),
        customerEmail: customerEmail.trim(),
        fulfilmentType: fulfilment === 'quick-point' ? 'quick_point' : fulfilment,
        fulfilmentPointId: fulfilment === 'delivery' ? null : selectedPointId,
        deliveryAddress: fulfilment === 'delivery' ? { address_line: deliveryAddress.trim() } : null,
        customerNotes: customerNotes.trim(),
        idempotencyKey
      })

      const backendItems = Array.isArray(response?.items) ? response.items : []
      const results = []

      for (const item of items) {
        const files = itemFiles(item)
        if (!files.length) continue
        const backendItem = backendItems.find((candidate) => candidate.clientItemKey === item.cartId)
        if (!backendItem?.orderItemId) {
          for (const file of files) {
            results.push({ cartId: item.cartId, ok: false, name: displayFileName(file), error: 'Order item mapping was not returned.' })
          }
          continue
        }

        for (const file of files) {
          try {
            await uploadQuickSolutionFile({
              orderId: response.orderId,
              orderItemId: backendItem.orderItemId,
              uploadToken: response.uploadToken,
              file
            })
            results.push({ cartId: item.cartId, ok: true, name: displayFileName(file) })
          } catch (error) {
            results.push({ cartId: item.cartId, ok: false, name: displayFileName(file), error: error?.message || 'Upload failed.' })
          }
        }
      }

      setUploadResults(results)
      setOrderResponse(response)
      if (response?.orderId && response?.orderNumber && response?.trackingToken) {
        saveQuickSolutionTrackingSession({
          orderId: response.orderId,
          orderNumber: response.orderNumber,
          trackingToken: response.trackingToken,
          trackingTokenExpiresAt: response.trackingTokenExpiresAt
        })
      }
      if (response?.orderId && response?.paymentToken) {
        saveQuickSolutionPaymentSession({
          orderId: response.orderId,
          paymentToken: response.paymentToken,
          orderNumber: response.orderNumber,
          amount: response.totalAmount
        })
      }
      setSubmitState('success')
      setPhase('success')
      onOrderCreated?.(response)
    } catch (error) {
      setSubmitState('error')
      setSubmitError(error?.message || 'We could not create the combined order.')
    }
  }

  const startCombinedPayment = async () => {
    if (!orderResponse?.orderId || !orderResponse?.paymentToken) return
    setPaymentError('')
    setPaymentState('starting')
    try {
      const result = await beginQuickSolutionPayment(orderResponse.orderId, orderResponse.paymentToken)
      if (result?.alreadyPaid || result?.paymentStatus === 'paid') {
        setPaymentState('paid')
        return
      }
      if (!result?.payment_url) throw new Error('PayFast did not return a payment link.')
      window.location.assign(result.payment_url)
    } catch (error) {
      setPaymentState('error')
      setPaymentError(error?.message || 'Could not open PayFast.')
    }
  }

  if (!open) return null

  if (phase === 'success' && orderResponse) {
    const failedUploads = uploadResults.filter((item) => !item.ok)
    const trackingHref = orderResponse.trackingToken
      ? buildQuickSolutionTrackingHref(orderResponse.orderNumber, orderResponse.trackingToken)
      : '/track'
    return (
      <div className="qs-cart-backdrop" role="presentation">
        <aside className="qs-cart-sheet" role="dialog" aria-modal="true" aria-label="Order created">
          <div className="qs-cart-head">
            <div><span className="eyebrow">Order received</span><h2>{orderResponse.orderNumber}</h2></div>
            <button type="button" className="qs-cart-close" onClick={onClose} aria-label="Close basket">×</button>
          </div>
          <div className="qs-cart-success">
            <div className="complete-mark"><Icon name="bag" size={26}/></div>
            <h3>One order. {orderResponse.items?.length || 0} items.</h3>
            <p>Quick Solution saved your basket as one XOS order with separate production items.</p>
            <div className="qs-checkout-total">
              <div><span>Total</span><small>{orderResponse.deliveryFeeStatus === 'pending_confirmation' ? 'Delivery fee still to be confirmed' : 'Order total'}</small></div>
              <strong>{formatMoney(orderResponse.totalAmount)}</strong>
            </div>
            {uploadResults.length ? (
              <div className="qs-upload-results">
                {uploadResults.map((item) => <div key={item.cartId} className={item.ok ? 'ok' : 'error'}><span>{item.ok ? '✓' : '!'}</span><div><strong>{item.name}</strong><small>{item.ok ? 'Uploaded to the matching order item' : item.error}</small></div></div>)}
              </div>
            ) : null}
            {failedUploads.length ? <p className="checkout-error">{failedUploads.length} file upload{failedUploads.length === 1 ? '' : 's'} still need attention. The order itself is already safe.</p> : null}
            <div className="qs-cart-success-actions">
              {orderResponse.paymentToken && orderResponse.deliveryFeeStatus !== 'pending_confirmation' && paymentState !== 'paid' ? (
                <button className="button primary-green" type="button" disabled={paymentState === 'starting'} onClick={startCombinedPayment}>
                  {paymentState === 'starting' ? 'Opening PayFast…' : `Pay ${formatMoney(orderResponse.totalAmount)} securely`}
                </button>
              ) : null}
              {orderResponse.deliveryFeeStatus === 'pending_confirmation' ? <div className="secure-file-note neutral"><strong>Delivery price first.</strong><span>We will confirm the delivery fee before payment opens.</span></div> : null}
              {paymentState === 'paid' ? <div className="secure-file-note success"><strong>Payment confirmed.</strong></div> : null}
              {paymentError ? <p className="checkout-error">{paymentError}</p> : null}
              <a className="button dark" href={trackingHref}><Icon name="search" size={16}/> Track this order</a>
              <button className="button ghost" type="button" onClick={onClose}>Done</button>
            </div>
          </div>
        </aside>
      </div>
    )
  }

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
              {groupCartItemsByOffer(items).map((group, groupIndex) => (
                <div key={group.offerId ? `offer-${group.offerId}-${groupIndex}` : group.items[0].cartId} className={group.offerId ? 'qs20-cart-offer-group' : undefined}>
                  {group.offerId && (
                    <div className="qs20-cart-offer-group-label">
                      <Icon name="checkCircle" size={13}/> {group.offerName}
                    </div>
                  )}
                  {group.items.map((item) => (
                    <article className="qs-cart-item" key={item.cartId}>
                      <div>
                        <span className="eyebrow">{item.category}</span>
                        <strong>{item.productName}</strong>
                        <small>{item.summary || 'Configured item'}</small>
                        {(() => {
                          const liveFiles = itemFiles(item)
                          const metaFiles = itemFileMetas(item)
                          const count = liveFiles.length || metaFiles.length
                          if (!count) return null
                          if (count === 1) return <small>File: {displayFileName(liveFiles[0], metaFiles[0])}</small>
                          return <small>{count} files attached</small>
                        })()}
                      </div>
                      <div className="qs-cart-item-side">
                        <strong>{item.quoteRequired ? 'Quote' : formatMoney(item.total)}</strong>
                        <button type="button" onClick={() => onRemove(item.cartId)}>Remove</button>
                      </div>
                    </article>
                  ))}
                </div>
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

            {submitError ? <div className="checkout-error" role="alert">{submitError}</div> : null}
            <button className="button dark qs-place-order" type="button" disabled={submitState === 'submitting'} onClick={submitCombinedOrder}>
              {submitState === 'submitting' ? 'Creating one combined order…' : `Place combined order · ${formatMoney(total)}`}
            </button>
            <p className="qs-cart-note">Your basket is submitted as one XOS order with separate order items. Server pricing is recalculated before anything is saved.</p>
          </div>
        )}
      </aside>
    </div>
  )
}
