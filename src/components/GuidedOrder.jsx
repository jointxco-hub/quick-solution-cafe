import React, { useEffect, useMemo, useState } from 'react'
import Icon from './Icon.jsx'
import FieldControl from './FieldControl.jsx'
import { calculateProductPrice, formatMoney, getDefaultConfig } from '../lib/pricing.js'
import { fulfilmentOptions } from '../data/products.js'
import { beginQuickSolutionPayment, createQuickSolutionOrder, getQuickSolutionPaymentStatus, isSupabaseConfigured, uploadQuickSolutionFile } from '../lib/supabaseApi.js'

function optionLabel(product, fieldId, value) {
  const field = product.fields.find((item) => item.id === fieldId)
  if (!field) return value
  if (field.type === 'number') return `${value}${field.suffix ? ` ${field.suffix}` : ''}`
  return field.options?.find((item) => item.id === value)?.label || value
}

function pointArea(point) {
  const business = point?.easyLocateLink?.business || {}
  const address = point?.address || {}
  return [business.locationArea || address.area || address.city, business.locationExtension || address.line1].filter(Boolean).join(' · ')
}

function pointCategory(point) {
  const categories = point?.easyLocateLink?.business?.categories
  return Array.isArray(categories) && categories.length ? categories.slice(0, 2).join(' · ') : null
}

function ReviewRows({ product, config, fulfilment, file, selectedPoint, fulfilmentFee = 0 }) {
  const rows = product.fields
    .filter((field) => field.type !== 'file')
    .map((field) => ({ label: field.shortLabel || field.label, value: optionLabel(product, field.id, config[field.id]) }))

  const fulfilmentLabel = fulfilment === 'delivery'
    ? 'Delivery'
    : selectedPoint?.name || fulfilmentOptions.find((item) => item.id === fulfilment)?.label

  return (
    <div className="review-list">
      {rows.map((row) => <div key={row.label}><span>{row.label}</span><strong>{row.value}</strong></div>)}
      <div><span>File</span><strong>{file?.name || 'No file selected yet'}</strong></div>
      <div><span>{fulfilment === 'delivery' ? 'Fulfilment' : 'Collection point'}</span><strong>{fulfilmentLabel}</strong></div>
      {selectedPoint && pointArea(selectedPoint) ? <div><span>Area</span><strong>{pointArea(selectedPoint)}</strong></div> : null}
      {selectedPoint ? <div><span>Collection fee</span><strong>{fulfilmentFee > 0 ? formatMoney(fulfilmentFee) : 'Free'}</strong></div> : null}
    </div>
  )
}

function CollectionPointCard({ point, selected, onSelect, typeLabel }) {
  const business = point?.easyLocateLink?.business || null
  const verified = point?.easyLocateLink?.status === 'verified'
  const area = pointArea(point)
  const category = pointCategory(point)
  const fee = Number(point?.feeAmount || 0)
  const listingUrl = point?.easyLocateLink?.canonicalUrl || ''

  return (
    <article className={`collection-point-card ${selected ? 'selected' : ''}`}>
      <button type="button" className="collection-point-choice" onClick={onSelect}>
        <span className="collection-point-marker"><Icon name={point.kind === 'cafe' ? 'store' : 'pin'} size={20}/></span>
        <span className="collection-point-copy">
          <span className="collection-point-kicker">{verified ? 'Easy Locate verified' : typeLabel}</span>
          <strong>{point.name}</strong>
          <small>{[area, category].filter(Boolean).join(' · ') || typeLabel}</small>
          <span className="collection-point-meta">
            <span>{fee > 0 ? `+ ${formatMoney(fee)} collection` : 'Free collection'}</span>
            {verified ? <span>Verified local business</span> : null}
          </span>
        </span>
        <span className="radio-dot"/>
      </button>
      {listingUrl ? <a className="collection-point-link" href={listingUrl} target="_blank" rel="noreferrer">View on Easy Locate <Icon name="external" size={14}/></a> : null}
    </article>
  )
}

function makeIdempotencyKey() {
  if (globalThis.crypto?.randomUUID) return `qsc-${globalThis.crypto.randomUUID()}`
  return `qsc-${Date.now()}-${Math.random().toString(36).slice(2)}`
}

export default function GuidedOrder({ product, journey, preset = {}, task, onAdvanced, fulfilmentPoints = [] }) {
  const [config, setConfig] = useState(() => getDefaultConfig(product, preset))
  const [file, setFile] = useState(null)
  const [fulfilment, setFulfilment] = useState('cafe')
  const [selectedPointId, setSelectedPointId] = useState('')
  const [deliveryAddress, setDeliveryAddress] = useState('')
  const [stepIndex, setStepIndex] = useState(0)
  const [complete, setComplete] = useState(false)
  const [customerName, setCustomerName] = useState('')
  const [customerPhone, setCustomerPhone] = useState('')
  const [customerEmail, setCustomerEmail] = useState('')
  const [customerNotes, setCustomerNotes] = useState('')
  const [idempotencyKey, setIdempotencyKey] = useState(makeIdempotencyKey)
  const [submitState, setSubmitState] = useState('idle')
  const [submitError, setSubmitError] = useState('')
  const [orderResponse, setOrderResponse] = useState(null)
  const [uploadedFile, setUploadedFile] = useState(null)
  const [uploadError, setUploadError] = useState('')
  const [paymentState, setPaymentState] = useState('idle')
  const [paymentError, setPaymentError] = useState('')

  useEffect(() => {
    setConfig(getDefaultConfig(product, preset))
    setFile(null)
    setFulfilment('cafe')
    setSelectedPointId('')
    setDeliveryAddress('')
    setStepIndex(0)
    setComplete(false)
    setCustomerName('')
    setCustomerPhone('')
    setCustomerEmail('')
    setCustomerNotes('')
    setIdempotencyKey(makeIdempotencyKey())
    setSubmitState('idle')
    setSubmitError('')
    setOrderResponse(null)
    setUploadedFile(null)
    setUploadError('')
    setPaymentState('idle')
    setPaymentError('')
  }, [product, journey, preset])

  const result = useMemo(() => calculateProductPrice(product, config), [product, config])
  const step = journey.steps[stepIndex]
  const progress = ((stepIndex + 1) / journey.steps.length) * 100
  const update = (id, value) => setConfig((previous) => ({ ...previous, [id]: value }))

  const cafePoints = fulfilmentPoints.filter((point) => point.kind === 'cafe' && point.collectionEnabled !== false)
  const quickPoints = fulfilmentPoints.filter((point) => point.kind === 'quick_point' && point.collectionEnabled !== false)
  const selectedPoint = fulfilmentPoints.find((point) => point.id === selectedPointId)
  const selectedFulfilmentFee = fulfilment === 'delivery' ? 0 : Number(selectedPoint?.feeAmount || 0)
  const estimatedOrderTotal = Number(result.total || 0) + selectedFulfilmentFee

  useEffect(() => {
    if (fulfilment === 'cafe' && cafePoints.length && !cafePoints.some((point) => point.id === selectedPointId)) {
      setSelectedPointId(cafePoints[0].id)
    }
    if (fulfilment === 'quick-point' && quickPoints.length && !quickPoints.some((point) => point.id === selectedPointId)) {
      setSelectedPointId(quickPoints[0].id)
    }
  }, [fulfilment, fulfilmentPoints, selectedPointId])

  const chooseFulfilment = (id) => {
    if (id === 'quick-point' && quickPoints.length === 0) return
    setFulfilment(id)
    setSubmitError('')
    if (id === 'cafe') setSelectedPointId(cafePoints[0]?.id || '')
    if (id === 'quick-point' && !quickPoints.some((point) => point.id === selectedPointId)) {
      setSelectedPointId(quickPoints[0]?.id || '')
    }
  }

  const resetOrder = () => {
    setComplete(false)
    setStepIndex(0)
    setSubmitState('idle')
    setSubmitError('')
    setOrderResponse(null)
    setUploadedFile(null)
    setUploadError('')
    setPaymentState('idle')
    setPaymentError('')
    setIdempotencyKey(makeIdempotencyKey())
  }

  const submitOrder = async () => {
    setSubmitError('')

    if (customerName.trim().length < 2) {
      setSubmitError('Please add the name we should use for this order.')
      return
    }

    if (!customerPhone.trim() && !customerEmail.trim()) {
      setSubmitError('Add a WhatsApp/phone number or email so we can contact you about the order.')
      return
    }

    if (fulfilment === 'quick-point' && !selectedPointId) {
      setSubmitError('Choose a Quick Point for collection.')
      return
    }

    if (fulfilment === 'delivery' && deliveryAddress.trim().length < 5) {
      setSubmitError('Add the delivery address so we know where the order should go.')
      return
    }

    if (!isSupabaseConfigured()) {
      setSubmitError('This copy is not connected to the Quick Solution staging backend yet. Add the Supabase values to .env.local and restart Vite.')
      return
    }

    setSubmitState('submitting')

    try {
      const backendFulfilment = fulfilment === 'quick-point' ? 'quick_point' : fulfilment
      const response = await createQuickSolutionOrder({
        productKey: product.id,
        configuration: {
          ...config,
          fileName: file?.name || null,
          clientEstimate: estimatedOrderTotal
        },
        customerName: customerName.trim(),
        customerPhone: customerPhone.trim(),
        customerEmail: customerEmail.trim(),
        fulfilmentType: backendFulfilment,
        fulfilmentPointId: fulfilment === 'delivery'
          ? null
          : (selectedPointId || cafePoints[0]?.id || null),
        deliveryAddress: fulfilment === 'delivery' ? { address_line: deliveryAddress.trim() } : null,
        customerNotes: customerNotes.trim(),
        idempotencyKey
      })

      setOrderResponse(response)

      if (file) {
        setSubmitState('uploading')
        try {
          const upload = await uploadQuickSolutionFile({
            orderId: response.orderId,
            orderItemId: response.orderItemId,
            uploadToken: response.uploadToken,
            file
          })
          setUploadedFile(upload?.file || null)
          setUploadError('')
        } catch (nextUploadError) {
          setUploadError(nextUploadError?.message || 'The order was saved, but the file upload did not finish.')
        }
      }

      setSubmitState('success')
      setComplete(true)
    } catch (error) {
      setSubmitState('error')
      setSubmitError(error?.message || 'We could not create the order. Please try again.')
    }
  }

  const startPayment = async () => {
    if (!orderResponse?.orderId || !orderResponse?.paymentToken) {
      setPaymentError('This order does not have an active payment session yet.')
      return
    }

    setPaymentState('starting')
    setPaymentError('')
    try {
      const result = await beginQuickSolutionPayment(orderResponse.orderId, orderResponse.paymentToken)
      if (result?.alreadyPaid || result?.paymentStatus === 'paid') {
        setPaymentState('paid')
        return
      }
      if (!result?.payment_url) throw new Error('PayFast did not return a payment link.')
      window.open(result.payment_url, '_blank', 'noopener,noreferrer')
      setPaymentState('waiting')
    } catch (error) {
      setPaymentState('error')
      setPaymentError(error?.message || 'Could not open PayFast.')
    }
  }

  const checkPayment = async () => {
    if (!orderResponse?.orderId || !orderResponse?.paymentToken) return
    setPaymentState('checking')
    setPaymentError('')
    try {
      const result = await getQuickSolutionPaymentStatus(orderResponse.orderId, orderResponse.paymentToken)
      setPaymentState(result?.paid ? 'paid' : 'waiting')
      if (!result?.paid) setPaymentError('PayFast has not confirmed this payment yet.')
    } catch (error) {
      setPaymentState('error')
      setPaymentError(error?.message || 'Could not check the payment yet.')
    }
  }
  if (complete) {
    const total = Number(orderResponse?.totalAmount ?? estimatedOrderTotal)
    const orderNumber = orderResponse?.orderNumber || 'Order created'
    const confirmationPoint = fulfilment === 'delivery' ? null : selectedPoint
    const confirmationArea = confirmationPoint ? pointArea(confirmationPoint) : ''
    const confirmationListingUrl = confirmationPoint?.easyLocateLink?.canonicalUrl || ''
    const confirmationPointKind = fulfilment === 'quick-point' ? 'Quick Point collection' : 'Collect from Quick Solution'
    const whatsappText = encodeURIComponent(`Hi Quick Solution, my order is ${orderNumber}. I need help with the file or next step.`)

    return (
      <div className="guided-complete">
        <div className="complete-mark"><Icon name="bag" size={28}/></div>
        <span className="eyebrow">Order received</span>
        <h2>{orderNumber}</h2>
        <p>We saved the configuration and the exact pricing snapshot used for this order. Quick Solution can now review the job before production or payment.</p>
        <div className="complete-summary"><strong>{product.name}</strong><span>{formatMoney(total)}</span></div>

        {fulfilment !== 'delivery' && confirmationPoint && (
          <div className="complete-fulfilment-card">
            <span className="complete-fulfilment-icon"><Icon name={confirmationPoint.kind === 'cafe' ? 'store' : 'pin'} size={21}/></span>
            <div>
              <span className="eyebrow">{confirmationPointKind}</span>
              <strong>{confirmationPoint.name}</strong>
              {confirmationArea ? <small>{confirmationArea}</small> : null}
              <span>{selectedFulfilmentFee > 0 ? `${formatMoney(selectedFulfilmentFee)} collection fee` : 'Free collection'}</span>
            </div>
            {confirmationListingUrl ? <a href={confirmationListingUrl} target="_blank" rel="noreferrer">View on Easy Locate <Icon name="external" size={14}/></a> : null}
          </div>
        )}

        {fulfilment === 'delivery' && (
          <div className="complete-fulfilment-card">
            <span className="complete-fulfilment-icon"><Icon name="truck" size={21}/></span>
            <div>
              <span className="eyebrow">Local delivery</span>
              <strong>{deliveryAddress}</strong>
              <small>Delivery fee will be confirmed before payment.</small>
            </div>
          </div>
        )}

        {orderResponse?.paymentToken && fulfilment !== 'delivery' && (
          <div className={`qs-payment-card ${paymentState === 'paid' ? 'paid' : paymentState === 'waiting' ? 'pending' : ''}`}>
            <div className="qs-payment-card-head">
              <div>
                <span className="eyebrow">Payment</span>
                <strong>{paymentState === 'paid' ? 'Payment confirmed' : `Pay ${formatMoney(total)} securely`}</strong>
                <small>{paymentState === 'paid' ? 'PayFast confirmed this order as paid.' : 'Your order already exists. Payment updates the same order — it does not create a duplicate.'}</small>
              </div>
              <span className={`qs-payment-status ${paymentState === 'paid' ? 'paid' : paymentState === 'waiting' ? 'waiting' : ''}`}>
                {paymentState === 'paid' ? 'Paid' : paymentState === 'waiting' || paymentState === 'checking' ? 'Awaiting confirmation' : 'Unpaid'}
              </span>
            </div>
            {paymentState !== 'paid' && (
              <div className="qs-payment-actions">
                <button className="button primary-green" type="button" disabled={paymentState === 'starting'} onClick={startPayment}>
                  {paymentState === 'starting' ? 'Opening PayFastâ€¦' : 'Pay securely with PayFast'}
                </button>
                {(paymentState === 'waiting' || paymentState === 'checking' || paymentState === 'error') && (
                  <button className="button ghost" type="button" disabled={paymentState === 'checking'} onClick={checkPayment}>
                    {paymentState === 'checking' ? 'Checkingâ€¦' : 'Check payment'}
                  </button>
                )}
              </div>
            )}
            {paymentError ? <p className="qs-payment-error">{paymentError}</p> : null}
          </div>
        )}

        {orderResponse?.paymentToken && fulfilment === 'delivery' && (
          <div className="qs-payment-card pending">
            <div className="qs-payment-card-head">
              <div>
                <span className="eyebrow">Payment</span>
                <strong>Delivery price first.</strong>
                <small>Quick Solution must confirm the delivery fee before PayFast opens, so you cannot be charged the wrong total.</small>
              </div>
              <span className="qs-payment-status waiting">Waiting for delivery price</span>
            </div>
          </div>
        )}
        {file && uploadedFile && (
          <div className="secure-file-note success">
            <strong>{file.name} uploaded securely.</strong>
            <span>The file is linked to this exact order item in private Joint X storage. Staff access is tenant-scoped.</span>
          </div>
        )}
        {file && uploadError && (
          <div className="secure-file-note error">
            <strong>Your order is safe, but the file still needs attention.</strong>
            <span>{uploadError}</span>
          </div>
        )}
        {!file && (
          <div className="secure-file-note neutral">
            <strong>No file was attached.</strong>
            <span>If this job needs artwork or a document, Quick Solution can request it before production.</span>
          </div>
        )}
        <div className="complete-actions">
          {file && uploadError && <button className="button primary-green" type="button" onClick={async () => {
            setUploadError('')
            try {
              const upload = await uploadQuickSolutionFile({ orderId: orderResponse.orderId, orderItemId: orderResponse.orderItemId, uploadToken: orderResponse.uploadToken, file })
              setUploadedFile(upload?.file || null)
            } catch (nextUploadError) {
              setUploadError(nextUploadError?.message || 'File upload failed again.')
            }
          }}>Retry secure upload</button>}
          {file && uploadError && <a className="button ghost" href={`https://wa.me/27754534646?text=${whatsappText}`} target="_blank" rel="noreferrer">Use WhatsApp instead</a>}
          <button className="button ghost" type="button" onClick={resetOrder}>Start another order</button>
        </div>
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
          <>
            <div className="fulfilment-grid">
              {fulfilmentOptions.map((item) => {
                const unavailable = item.id === 'quick-point' && quickPoints.length === 0
                return (
                  <button
                    key={item.id}
                    className={`fulfilment-option ${fulfilment === item.id ? 'selected' : ''} ${unavailable ? 'disabled-option' : ''}`}
                    type="button"
                    disabled={unavailable}
                    onClick={() => chooseFulfilment(item.id)}
                  >
                    <span className="fulfilment-icon"><Icon name={item.icon} size={23}/></span>
                    <span>
                      <strong>{item.label}</strong>
                      <small>{unavailable ? 'Quick Points are being onboarded.' : item.helper}</small>
                    </span>
                    <span className="radio-dot"/>
                  </button>
                )
              })}
            </div>

            {fulfilment === 'cafe' && cafePoints.length > 0 && (
              <div className="collection-point-picker">
                <div className="collection-point-picker-head">
                  <div><span className="eyebrow">Collect from Quick Solution</span><strong>Choose the cafÃ© or branch.</strong></div>
                  <small>{cafePoints.length} location{cafePoints.length === 1 ? '' : 's'} available</small>
                </div>
                <div className="collection-point-grid">
                  {cafePoints.map((point) => (
                    <CollectionPointCard
                      key={point.id}
                      point={point}
                      selected={selectedPointId === point.id}
                      onSelect={() => setSelectedPointId(point.id)}
                      typeLabel="Quick Solution cafÃ©"
                    />
                  ))}
                </div>
              </div>
            )}

            {fulfilment === 'quick-point' && quickPoints.length > 0 && (
              <div className="collection-point-picker">
                <div className="collection-point-picker-head">
                  <div><span className="eyebrow">Nearby Quick Points</span><strong>Choose the local business that suits you.</strong></div>
                  <small>Business identity powered by Easy Locate</small>
                </div>
                <div className="collection-point-grid">
                  {quickPoints.map((point) => (
                    <CollectionPointCard
                      key={point.id}
                      point={point}
                      selected={selectedPointId === point.id}
                      onSelect={() => setSelectedPointId(point.id)}
                      typeLabel="Quick Point"
                    />
                  ))}
                </div>
              </div>
            )}

            {fulfilment === 'delivery' && (
              <label className="checkout-field">
                <span>Delivery address</span>
                <textarea value={deliveryAddress} onChange={(event) => setDeliveryAddress(event.target.value)} placeholder="Street / area / landmark"/>
                <small>Delivery pricing is confirmed before payment in this phase.</small>
              </label>
            )}
          </>
        )}

        {step.type === 'review' && (
          <>
            <ReviewRows product={product} config={config} fulfilment={fulfilment} file={file} selectedPoint={selectedPoint} fulfilmentFee={selectedFulfilmentFee}/>
            <div className="guest-note"><Icon name="user" size={19}/><span><strong>No account required for a quick order.</strong> We only need a name and one reliable way to contact you.</span></div>

            <div className="checkout-contact">
              <div className="checkout-contact-heading">
                <span className="eyebrow">Your details</span>
                <h3>Who is this order for?</h3>
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
                <span>Anything we should know? <small>optional</small></span>
                <textarea value={customerNotes} onChange={(event) => setCustomerNotes(event.target.value)} placeholder="Deadline, special instructions, or context"/>
              </label>
              {file && <p className="file-stage-message secure"><strong>{file.name}</strong> will be uploaded to private Joint X storage after the order number is created. Maximum file size: 20MB.</p>}
            </div>

            {submitError && <div className="checkout-error" role="alert">{submitError}</div>}
          </>
        )}

        <div className="guided-actions">
          <button className="button ghost" type="button" disabled={stepIndex === 0 || submitState === 'submitting' || submitState === 'uploading'} onClick={() => setStepIndex((value) => Math.max(0, value - 1))}>Back</button>
          {stepIndex < journey.steps.length - 1 ? (
            <button className="button primary-green" type="button" onClick={() => setStepIndex((value) => value + 1)}>Continue <Icon name="arrowRight" size={17}/></button>
          ) : (
            <button className="button primary-green" type="button" disabled={submitState === 'submitting' || submitState === 'uploading'} onClick={submitOrder}>
              {submitState === 'submitting' ? 'Creating orderâ€¦' : submitState === 'uploading' ? 'Uploading file securelyâ€¦' : `Create order · ${formatMoney(estimatedOrderTotal)}`}
              {submitState !== 'submitting' && submitState !== 'uploading' && <Icon name="arrowRight" size={17}/>}
            </button>
          )}
        </div>
      </div>

      <aside className="guided-summary" aria-live="polite">
        <span className="eyebrow inverse">Estimated total</span>
        <div className="guided-price">{formatMoney(estimatedOrderTotal)}</div>
        <p>{result.summary}</p>
        <div className="price-lines compact-lines">
          {result.lines.map((line, index) => (
            <div key={`${line.label}-${index}`}><span>{line.label}</span><strong>{line.text ?? formatMoney(line.value)}</strong></div>
          ))}
          {fulfilment !== 'delivery' && selectedPoint ? <div><span>{selectedPoint.name} collection</span><strong>{selectedFulfilmentFee > 0 ? formatMoney(selectedFulfilmentFee) : 'Free'}</strong></div> : null}
          {fulfilment === 'delivery' ? <div><span>Delivery</span><strong>Confirmed before payment</strong></div> : null}
        </div>
        <div className="summary-confidence"><span className="brand-dot green"/><span>The backend recalculates the price before saving the order, so the browser cannot invent its own total.</span></div>
        <a className="help-link" href="https://wa.me/27754534646" target="_blank" rel="noreferrer"><Icon name="message" size={17}/> Need help? WhatsApp us</a>
      </aside>
    </div>
  )
}






