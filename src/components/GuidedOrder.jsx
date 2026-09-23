import React, { useEffect, useMemo, useState } from 'react'
import Icon from './Icon.jsx'
import PaymentRedirectLoader from './PaymentRedirectLoader.jsx'
import FieldControl from './FieldControl.jsx'
import SupplierVariantConfigurator from './SupplierVariantConfigurator.jsx'
import PhotoDeliverablesField from './PhotoDeliverablesField.jsx'
import DocumentPrintPlan from './DocumentPrintPlan.jsx'
import { calculateProductPrice, formatMoney, getDefaultConfig } from '../lib/pricing.js'
import { deriveVariantAxisValues, resolveDisplayLabel, resolveProductDisplayName } from '../lib/productContent.js'
import { fulfilmentOptions } from '../data/products.js'
import { beginQuickSolutionPayment, createQuickSolutionOrder, createQuickSolutionServiceRequest, getQuickSolutionPaymentStatus, isSupabaseConfigured, uploadQuickSolutionFile } from '../lib/supabaseApi.js'
import { saveQuickSolutionPaymentSession } from '../lib/paymentSession.js'
import { buildQuickSolutionTrackingHref, saveQuickSolutionTrackingSession } from '../lib/trackingSession.js'
import { buildWhatsappUrl } from '../lib/businessInfo.js'

// QS-17D fix: SupplierVariantConfigurator.jsx's axis <select>s (Style/
// Size/Sides/Kit, Frame/Size/Kit) read their displayed value from
// dedicated `config.variantAxis_<axisId>` keys, not from `config.variant`
// itself - so a config that arrives with a real `variant` already set
// (a Quick Preset, or any other future producer of a ready-made variant
// id) but no variantAxis_* keys renders every axis dropdown blank, even
// though pricing (which reads config.variant directly) is already
// correct. This derives those display keys FROM config.variant, once,
// at the moments GuidedOrder (re)builds its config - config.variant
// remains the only pricing-authority value; these are a read-model
// refreshed from it, never an independent, driftable state. Once the
// customer touches an axis dropdown, SupplierVariantConfigurator's own
// chooseAxis() keeps variant and variantAxis_* in sync from then on.
function hydrateVariantAxisConfig(product, config) {
  const axes = product?.pricing?.variantAxes
  if (!Array.isArray(axes) || axes.length === 0) return config
  const derived = deriveVariantAxisValues(product, config.variant)
  if (!derived) return config
  const patch = {}
  for (const axis of axes) patch[`variantAxis_${axis.id}`] = derived[axis.id]
  return { ...config, ...patch }
}

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

function shootLocationLabel(shootLocation) {
  if (shootLocation === 'cafe') return 'At Quick Solution Café'
  if (shootLocation === 'onsite-team') return 'Photo / video team at your location'
  return 'Photographer / videographer at your location'
}

function displayFileName(file) {
  if (Array.isArray(file)) {
    if (!file.length) return 'No files selected yet'
    if (file.length === 1) return file[0]?.name || '1 file selected'
    return `${file.length} files selected`
  }
  const raw = String(file?.originalName || file?.name || '').trim()
  if (!raw) return 'No file selected yet'
  const uuidLike = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}(\.[a-z0-9]+)?$/i
  if (!uuidLike.test(raw)) return raw
  const ext = raw.includes('.') ? raw.split('.').pop().toUpperCase() : ''
  return ext ? `Uploaded ${ext} file` : 'Uploaded file'
}

function LocationSummaryRow({ config }) {
  return (
    <div className="review-location-row">
      <span>Shoot location</span>
      <div className="review-location-value">
        <strong>{shootLocationLabel(config.shootLocation)}</strong>
        {config.shootLocation !== 'cafe' && config.shootAddress ? <small>{config.shootAddress}</small> : null}
      </div>
    </div>
  )
}

function ReviewRows({ product, config, fulfilment, file, selectedPoint, fulfilmentFee = 0, showFulfilment = true, isServiceRequest = false, mode = 'simple' }) {
  const rows = product.fields
    .filter((field) => field.type !== 'file')
    .filter((field) => !(isServiceRequest && field.id === 'shootAddress'))
    .map((field) => (
      isServiceRequest && field.id === 'shootLocation'
        ? { id: field.id, special: true }
        : { id: field.id, label: resolveDisplayLabel({ label: field.shortLabel || field.label, simpleLabel: field.simpleShortLabel }, mode), value: optionLabel(product, field.id, config[field.id]) }
    ))

  const fulfilmentLabel = fulfilment === 'delivery'
    ? 'Delivery'
    : selectedPoint?.name || fulfilmentOptions.find((item) => item.id === fulfilment)?.label

  return (
    <div className="review-list">
      {rows.map((row) => (
        row.special
          ? <LocationSummaryRow key={row.id} config={config}/>
          : <div key={row.id}><span>{row.label}</span><strong>{row.value}</strong></div>
      ))}
      <div><span>File</span><strong>{displayFileName(file)}</strong></div>
      {showFulfilment ? (
        <>
          <div><span>{fulfilment === 'delivery' ? 'Fulfilment' : 'Collection point'}</span><strong>{fulfilmentLabel}</strong></div>
          {selectedPoint && pointArea(selectedPoint) ? <div><span>Area</span><strong>{pointArea(selectedPoint)}</strong></div> : null}
          {selectedPoint ? <div><span>Collection fee</span><strong>{fulfilmentFee > 0 ? formatMoney(fulfilmentFee) : 'Free'}</strong></div> : null}
        </>
      ) : null}
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

export default function GuidedOrder({
  product,
  journey,
  preset = {},
  task,
  mode = 'simple',
  onAdvanced,
  fulfilmentPoints = [],
  initialStepId = null,
  initialFile = null,
  onAddToCart
}) {
  const [config, setConfig] = useState(() => hydrateVariantAxisConfig(product, getDefaultConfig(product, preset)))
  const [file, setFile] = useState(initialFile)
  const [fulfilment, setFulfilment] = useState('cafe')
  const [selectedPointId, setSelectedPointId] = useState('')
  const [deliveryAddress, setDeliveryAddress] = useState('')
  const initialStepIndex = Math.max(
    0,
    initialStepId
      ? journey.steps.findIndex((step) => step.id === initialStepId)
      : 0
  )
  const [stepIndex, setStepIndex] = useState(initialStepIndex)
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
  const [locationError, setLocationError] = useState('')
  const [itemAdded, setItemAdded] = useState(false)

  useEffect(() => {
    setConfig(hydrateVariantAxisConfig(product, getDefaultConfig(product, preset)))
    setFile(initialFile)
    setFulfilment('cafe')
    setSelectedPointId('')
    setDeliveryAddress('')
    const nextStepIndex = initialStepId
      ? journey.steps.findIndex((step) => step.id === initialStepId)
      : 0
    setStepIndex(Math.max(0, nextStepIndex))
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
    setLocationError('')
    setItemAdded(false)
  }, [product, journey, preset, initialStepId, initialFile])

  useEffect(() => {
    if (!complete) return

    const timer = window.setTimeout(() => {
      document.querySelector('.guided-complete')?.scrollIntoView({
        behavior: 'smooth',
        block: 'start'
      })
    }, 60)

    return () => window.clearTimeout(timer)
  }, [complete])

  const result = useMemo(() => calculateProductPrice(product, config), [product, config])
  const isServiceRequest = product?.pricing?.strategy === 'ENQUIRY' || product?.serviceType === 'media'
  const shoppingSteps = isServiceRequest
    ? journey.steps
    : journey.steps.filter((item) => item.type !== 'fulfilment')
  const step = shoppingSteps[stepIndex]
  const progress = ((stepIndex + 1) / shoppingSteps.length) * 100
  const update = (id, value) => {
    setItemAdded(false)
    setConfig((previous) => ({ ...previous, [id]: value }))
  }

  const updateMany = (patch) => {
    setItemAdded(false)
    setConfig((previous) => ({ ...previous, ...patch }))
  }

  const addCurrentItemToCart = () => {
    if (itemAdded) return
    onAddToCart?.({
      product,
      config,
      file,
      files: Array.isArray(file) ? file : (file ? [file] : []),
      total: estimatedOrderTotal,
      summary: result.summary,
      quoteRequired: false
    })
    setItemAdded(true)
  }

  const chooseShootLocation = (value) => {
    setLocationError('')
    setConfig((previous) => ({
      ...previous,
      shootLocation: value,
      // The address belongs to client-location/onsite-team only. Switching
      // back to cafe must not leave a stale address to be submitted as the
      // service location (see submitOrder's serviceLocation.address build).
      shootAddress: value === 'cafe' ? '' : previous.shootAddress
    }))
  }

  const goNext = () => {
    if (product.id === 'a4-print' && step.id === 'quantity' && !config.documentPlanValid) {
      return
    }
    if (step.type === 'location' && config.shootLocation !== 'cafe' && String(config.shootAddress || '').trim().length < 3) {
      setLocationError('Add the area or address where the shoot should happen.')
      return
    }
    setLocationError('')
    setStepIndex((value) => value + 1)
  }

  const cafePoints = fulfilmentPoints.filter((point) => point.kind === 'cafe' && point.collectionEnabled !== false)
  const quickPoints = fulfilmentPoints.filter((point) => point.kind === 'quick_point' && point.collectionEnabled !== false)
  const selectedPoint = fulfilmentPoints.find((point) => point.id === selectedPointId)
  const selectedFulfilmentFee = isServiceRequest || fulfilment === 'delivery' ? 0 : Number(selectedPoint?.feeAmount || 0)
  // ENQUIRY always reports metrics.quoteRequired:true, so this stays
  // 0/"Quote" for it unchanged — PHOTOGRAPHY_SESSION can report a real,
  // server-matching total once every chosen option (session/extra
  // edits/deliverables) is priced, and the customer should see that
  // live estimate instead of a blanket "Quote" for the whole flow.
  const isPricedServiceRequest = isServiceRequest && result.metrics?.quoteRequired === false
  const estimatedOrderTotal = (!isServiceRequest || isPricedServiceRequest) ? Number(result.total || 0) : 0

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

    if (!isServiceRequest && fulfilment === 'delivery' && deliveryAddress.trim().length < 5) {
      setSubmitError('Add the delivery address so we know where the order should go.')
      return
    }

    if (isServiceRequest && !config.preferredDate) {
      setSubmitError('Choose a preferred shoot date. We will confirm availability before the booking is final.')
      return
    }

    if (isServiceRequest && config.shootLocation !== 'cafe' && String(config.shootAddress || '').trim().length < 3) {
      setSubmitError('Add the area or address where the shoot should happen.')
      return
    }

    if (!isSupabaseConfigured()) {
      setSubmitError('This copy is not connected to the Quick Solution staging backend yet. Add the Supabase values to .env.local and restart Vite.')
      return
    }

    setSubmitState('submitting')

    try {
      const backendFulfilment = fulfilment === 'quick-point' ? 'quick_point' : fulfilment
      const requestConfiguration = {
        ...config,
        fileName: file?.name || null,
        clientEstimate: estimatedOrderTotal,
        serviceType: isServiceRequest ? (product.serviceType || 'service') : null
      }

      const response = isServiceRequest
        ? await createQuickSolutionServiceRequest({
            productKey: product.id,
            configuration: requestConfiguration,
            customerName: customerName.trim(),
            customerPhone: customerPhone.trim(),
            customerEmail: customerEmail.trim(),
            serviceLocation: {
              type: config.shootLocation || 'cafe',
              address: String(config.shootAddress || '').trim() || null,
              preferredDate: config.preferredDate || null,
              preferredTime: config.preferredTime || null
            },
            customerNotes: customerNotes.trim(),
            idempotencyKey
          })
        : await createQuickSolutionOrder({
            productKey: product.id,
            configuration: requestConfiguration,
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
      saveQuickSolutionPaymentSession({
        orderId: orderResponse.orderId,
        paymentToken: orderResponse.paymentToken,
        orderNumber: orderResponse.orderNumber,
        amount: orderResponse.totalAmount
      })
      setPaymentState('waiting')
      window.location.assign(result.payment_url)
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
    // ENQUIRY responses never carry quoteRequired:false, so this stays
    // "Quote after review" for that flow unchanged — a priced
    // PHOTOGRAPHY_SESSION booking (every chosen option priced) shows
    // its real, server-confirmed amount instead.
    const isPricedResponse = isServiceRequest && orderResponse?.quoteRequired === false
    const orderNumber = orderResponse?.orderNumber || 'Order created'
    const confirmationPoint = fulfilment === 'delivery' ? null : selectedPoint
    const confirmationArea = confirmationPoint ? pointArea(confirmationPoint) : ''
    const confirmationListingUrl = confirmationPoint?.easyLocateLink?.canonicalUrl || ''
    const confirmationPointKind = fulfilment === 'quick-point' ? 'Quick Point collection' : 'Collect from Quick Solution'
    const whatsappText = encodeURIComponent(`Hi Quick Solution, my order is ${orderNumber}. I need help with the file or next step.`)
    const trackingHref = orderResponse?.trackingToken
      ? buildQuickSolutionTrackingHref(orderNumber, orderResponse.trackingToken)
      : '/track'

    if (paymentState === 'starting') {
      return <PaymentRedirectLoader orderNumber={orderNumber} amount={total}/>
    }

    return (
      <div className="guided-complete">
        <div className="complete-mark"><Icon name="bag" size={28}/></div>
        <span className="eyebrow">{isServiceRequest ? 'Request received' : 'Order received'}</span>
        <h2>{orderNumber}</h2>
        <p>{isServiceRequest ? (isPricedResponse ? 'We saved your booking request at the price shown below. Quick Solution will confirm your schedule and arrange payment separately — nothing is charged yet.' : 'We saved your shoot brief, preferred schedule and location. Quick Solution will review the crew and scope before confirming the quote and booking.') : 'We saved the configuration and the exact pricing snapshot used for this order. Quick Solution can now review the job before production or payment.'}</p>
        <div className="complete-summary"><strong>{resolveProductDisplayName(product, mode)}</strong><span>{isServiceRequest && !isPricedResponse ? 'Quote after review' : formatMoney(total)}</span></div>

        {isServiceRequest && config.shootLocation && (
          <div className="complete-fulfilment-card">
            <span className="complete-fulfilment-icon"><Icon name="camera" size={21}/></span>
            <div>
              <span className="eyebrow">Media service request</span>
              <strong>{shootLocationLabel(config.shootLocation)}</strong>
              {config.shootLocation !== 'cafe' && config.shootAddress ? <small>{config.shootAddress}</small> : null}
              <span>{[config.preferredDate, config.preferredTime].filter(Boolean).join(' · ') || 'Schedule to be confirmed'}</span>
            </div>
          </div>
        )}

        {!isServiceRequest && fulfilment !== 'delivery' && confirmationPoint && (
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

        {!isServiceRequest && fulfilment === 'delivery' && (
          <div className="complete-fulfilment-card">
            <span className="complete-fulfilment-icon"><Icon name="truck" size={21}/></span>
            <div>
              <span className="eyebrow">Local delivery</span>
              <strong>{deliveryAddress}</strong>
              <small>Delivery fee will be confirmed before payment.</small>
            </div>
          </div>
        )}

        {!isServiceRequest && orderResponse?.paymentToken && fulfilment !== 'delivery' && (
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
                  {paymentState === 'starting' ? 'Opening PayFast…' : 'Pay securely with PayFast'}
                </button>
                {(paymentState === 'waiting' || paymentState === 'checking' || paymentState === 'error') && (
                  <button className="button ghost" type="button" disabled={paymentState === 'checking'} onClick={checkPayment}>
                    {paymentState === 'checking' ? 'Checking…' : 'Check payment'}
                  </button>
                )}
              </div>
            )}
            {paymentError ? <p className="qs-payment-error">{paymentError}</p> : null}
          </div>
        )}

        {!isServiceRequest && orderResponse?.paymentToken && fulfilment === 'delivery' && (
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
          {file && uploadError && <a className="button ghost" href={buildWhatsappUrl(whatsappText)} target="_blank" rel="noreferrer">Use WhatsApp instead</a>}
          <a className="button dark" href={trackingHref}><Icon name="search" size={16}/> Track this order</a>
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
          <div className="guided-topline-meta">
            <span>{stepIndex + 1} of {shoppingSteps.length}</span>
            <strong className="guided-mobile-total">
              {result?.metrics?.quoteRequired ? 'Quote' : formatMoney(estimatedOrderTotal)}
            </strong>
          </div>
        </div>
        <div className="progress-track"><span style={{ width: `${progress}%` }}/></div>

        <div className="guided-heading">
          <span className="eyebrow">{task?.kicker || step.eyebrow}</span>
          <h2>{step.title}</h2>
          <p>{step.helper}</p>
        </div>

        {product.id === 'a4-print' && step.id === 'quantity' ? (
          <DocumentPrintPlan
            files={Array.isArray(file) ? file : (file ? [file] : [])}
            config={config}
            onChange={updateMany}
          />
        ) : step.type === 'variant-builder' ? (
          <SupplierVariantConfigurator product={product} config={config} mode={mode} onUpdateConfig={updateMany}/>
        ) : step.type === 'photo-deliverables' ? (
          <PhotoDeliverablesField product={product} config={config} onUpdateConfig={updateMany}/>
        ) : step.fields && (
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
                  onFileChange={(nextFile) => {
                    setFile(nextFile)
                    setItemAdded(false)
                    if (product.id === 'a4-print') {
                      setConfig((previous) => ({
                        ...previous,
                        pages: 0,
                        documentPlanValid: false,
                        documentInstructions: []
                      }))
                    }
                  }}
                  guided
                />
              )
            })}
          </div>
        )}

        {step.type === 'location' && (() => {
          const shootLocationField = product.fields.find((item) => item.id === 'shootLocation')
          const isCafe = config.shootLocation === 'cafe'
          return (
            <div className="guided-fields">
              {shootLocationField && (
                <FieldControl
                  field={shootLocationField}
                  value={config.shootLocation}
                  onChange={chooseShootLocation}
                  guided
                />
              )}
              {isCafe ? (
                <div className="location-reassurance field-full">
                  <Icon name="store" size={18}/>
                  <span>We’ll use the Quick Solution Café location.</span>
                </div>
              ) : (
                <label className="checkout-field field-full">
                  <span>{config.shootLocation === 'onsite-team' ? 'Where should the team go?' : 'Where should we come?'}</span>
                  <input
                    type="text"
                    value={config.shootAddress || ''}
                    onChange={(event) => {
                      update('shootAddress', event.target.value)
                      if (locationError) setLocationError('')
                    }}
                    placeholder="Area, venue or full address"
                  />
                  <small>{config.shootLocation === 'onsite-team' ? 'This is where we will send the photo / video team.' : 'This is where your photographer or videographer will come to.'}</small>
                  {locationError && <span className="field-inline-error" role="alert">{locationError}</span>}
                </label>
              )}
            </div>
          )
        })()}

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
                  <div><span className="eyebrow">Collect from Quick Solution</span><strong>Choose the café or branch.</strong></div>
                  <small>{cafePoints.length} location{cafePoints.length === 1 ? '' : 's'} available</small>
                </div>
                <div className="collection-point-grid">
                  {cafePoints.map((point) => (
                    <CollectionPointCard
                      key={point.id}
                      point={point}
                      selected={selectedPointId === point.id}
                      onSelect={() => setSelectedPointId(point.id)}
                      typeLabel="Quick Solution café"
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
            <ReviewRows
              product={product}
              config={config}
              fulfilment={fulfilment}
              file={file}
              selectedPoint={selectedPoint}
              fulfilmentFee={selectedFulfilmentFee}
              showFulfilment={false}
              isServiceRequest={isServiceRequest}
              mode={mode}
            />

            {isServiceRequest ? (
              <>
                <div className="guest-note"><Icon name="user" size={19}/><span><strong>No account required for a quick request.</strong> We only need a name and one reliable way to contact you.</span></div>
                <div className="checkout-contact">
                  <div className="checkout-contact-heading">
                    <span className="eyebrow">Your details</span>
                    <h3>Who is this request for?</h3>
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
                </div>
                {submitError && <div className="checkout-error" role="alert">{submitError}</div>}
              </>
            ) : (
              <div className="qs-shopping-ready">
                <Icon name="bag" size={19}/>
                <div>
                  <strong>Ready for your basket.</strong>
                  <span>Add this item and keep shopping. Collection, delivery and your contact details are handled once at checkout.</span>
                </div>
              </div>
            )}
          </>
        )}

        <div className="guided-actions">
          <button className="button ghost" type="button" disabled={stepIndex === 0 || submitState === 'submitting' || submitState === 'uploading'} onClick={() => setStepIndex((value) => Math.max(0, value - 1))}>Back</button>
          {stepIndex < shoppingSteps.length - 1 ? (
            <button
              className="button primary-green"
              type="button"
              disabled={product.id === 'a4-print' && step.id === 'quantity' && !config.documentPlanValid}
              onClick={goNext}
            >
              Continue <Icon name="arrowRight" size={17}/>
            </button>
          ) : isServiceRequest ? (
            <button className="button primary-green" type="button" disabled={submitState === 'submitting' || submitState === 'uploading'} onClick={submitOrder}>
              {submitState === 'submitting' ? 'Sending request…' : 'Send media request'}
              {submitState !== 'submitting' && <Icon name="arrowRight" size={17}/>}
            </button>
          ) : (
            <div className="qs-cart-review-actions">
              <button
                className={`button primary-green ${itemAdded ? 'added' : ''}`}
                type="button"
                disabled={itemAdded}
                onClick={addCurrentItemToCart}
              >
                {itemAdded ? 'Added to order' : 'Add to order'} <Icon name={itemAdded ? 'check' : 'bag'} size={17}/>
              </button>
            </div>
          )}
        </div>
      </div>

      <aside className="guided-summary" aria-live="polite">
        <span className="eyebrow inverse">{isServiceRequest && !isPricedServiceRequest ? 'Request type' : 'Estimated total'}</span>
        <div className="guided-price">{isServiceRequest && !isPricedServiceRequest ? 'Quote' : formatMoney(estimatedOrderTotal)}</div>
        <p>{isServiceRequest && !isPricedServiceRequest ? 'We will confirm pricing after reviewing the crew, location and scope.' : result.summary}</p>
        <div className="price-lines compact-lines">
          {result.lines.map((line, index) => (
            <div key={`${line.label}-${index}`}><span>{line.label}</span><strong>{line.text ?? formatMoney(line.value)}</strong></div>
          ))}
        </div>
        <div className="summary-confidence"><span className="brand-dot green"/><span>{isServiceRequest ? (isPricedServiceRequest ? 'This is the approved price for what you have chosen. Payment is not requested here — Quick Solution still confirms your booking before anything is charged.' : 'Your request is saved as a service brief. Pricing is confirmed only after Quick Solution reviews the scope.') : 'The backend recalculates the price before saving the order, so the browser cannot invent its own total.'}</span></div>
        <a className="help-link" href={buildWhatsappUrl()} target="_blank" rel="noreferrer"><Icon name="message" size={17}/> Need help? WhatsApp us</a>
      </aside>
    </div>
  )
}






