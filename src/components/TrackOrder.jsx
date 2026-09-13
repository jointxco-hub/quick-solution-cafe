import React, { useCallback, useEffect, useMemo, useState } from 'react'
import Header from './Header.jsx'
import Icon from './Icon.jsx'
import { getQuickSolutionTracking } from '../lib/supabaseApi.js'

function money(value) {
  return new Intl.NumberFormat('en-ZA', {
    style: 'currency',
    currency: 'ZAR',
    minimumFractionDigits: 2,
    maximumFractionDigits: 2
  }).format(Number(value || 0))
}

function relativeDateTime(value) {
  if (!value) return '—'
  try {
    const date = new Date(value)
    const now = new Date()
    const startToday = new Date(now.getFullYear(), now.getMonth(), now.getDate())
    const startDate = new Date(date.getFullYear(), date.getMonth(), date.getDate())
    const diff = Math.round((startToday - startDate) / 86400000)
    const time = new Intl.DateTimeFormat('en-ZA', {
      hour: '2-digit',
      minute: '2-digit',
      hour12: false
    }).format(date)

    if (diff === 0) return `Today ${time}`
    if (diff === 1) return `Yesterday ${time}`
    if (date.getFullYear() === now.getFullYear()) {
      return new Intl.DateTimeFormat('en-ZA', { day: 'numeric', month: 'short' }).format(date)
    }
    return new Intl.DateTimeFormat('en-ZA', { day: 'numeric', month: 'short', year: 'numeric' }).format(date)
  } catch {
    return value
  }
}

function fullDateTime(value) {
  if (!value) return '—'
  try {
    return new Intl.DateTimeFormat('en-ZA', {
      dateStyle: 'medium',
      timeStyle: 'short'
    }).format(new Date(value))
  } catch {
    return value
  }
}

function addressLabel(address) {
  if (!address || typeof address !== 'object') return ''
  return [
    address.address_line,
    address.line1,
    address.street,
    address.area,
    address.city,
    address.province,
    address.postal_code
  ].filter(Boolean).join(' · ')
}

function humanValue(value) {
  return String(value || '').replace(/_/g, ' ').replace(/\b\w/g, (char) => char.toUpperCase())
}

function statusTone(key) {
  if (key === 'completed') return 'good'
  if (key === 'ready') return 'good'
  if (key === 'cancelled') return 'bad'
  if (key === 'on_the_way') return 'purple'
  return 'neutral'
}

export default function TrackOrder() {
  const params = useMemo(() => new URLSearchParams(window.location.search), [])
  const initialOrder = (params.get('order') || '').trim().toUpperCase()
  const secureToken = (params.get('token') || '').trim()

  const [orderNumber, setOrderNumber] = useState(initialOrder)
  const [contact, setContact] = useState('')
  const [tracking, setTracking] = useState(null)
  const [state, setState] = useState(initialOrder && secureToken ? 'loading' : 'idle')
  const [error, setError] = useState('')
  const [copied, setCopied] = useState(false)

  const lookup = useCallback(async ({ useToken = false, quiet = false } = {}) => {
    const nextOrder = orderNumber.trim().toUpperCase()
    if (!nextOrder) {
      setError('Enter your Quick Solution order number.')
      return
    }

    if (!useToken && !secureToken && !contact.trim()) {
      setError('Enter the email or WhatsApp number used for this order.')
      return
    }

    if (!quiet) {
      setState('loading')
      setError('')
    }

    try {
      const result = await getQuickSolutionTracking({
        orderNumber: nextOrder,
        trackingToken: useToken || secureToken ? secureToken : null,
        contact: useToken || secureToken ? null : contact.trim()
      })

      if (!result?.order?.orderNumber) {
        setTracking(null)
        setState('error')
        setError('We could not verify that order. Check the order number and contact details, then try again.')
        return
      }

      setTracking(result)
      setState('ready')
      setError('')
    } catch (nextError) {
      setTracking(null)
      setState('error')
      setError(nextError?.message || 'We could not load this order right now.')
    }
  }, [contact, orderNumber, secureToken])

  useEffect(() => {
    if (initialOrder && secureToken) {
      lookup({ useToken: true })
    }
  }, [initialOrder, secureToken, lookup])

  const refresh = () => lookup({ useToken: Boolean(secureToken), quiet: false })

  const copyLink = async () => {
    if (!secureToken || !tracking?.order?.orderNumber) return
    try {
      await navigator.clipboard.writeText(window.location.href)
      setCopied(true)
      window.setTimeout(() => setCopied(false), 1800)
    } catch {
      setCopied(false)
    }
  }

  const timeline = Array.isArray(tracking?.stage?.timeline) ? tracking.stage.timeline : []
  const currentIndex = Number(tracking?.stage?.index || 0)
  const isCancelled = tracking?.stage?.key === 'cancelled'
  const fulfilmentAddress = addressLabel(tracking?.fulfilment?.address)
  const items = Array.isArray(tracking?.order?.items) ? tracking.order.items : []
  const attention = Array.isArray(tracking?.attentionItems) ? tracking.attentionItems : []
  const production = tracking?.production || {}
  const delivery = tracking?.delivery || {}
  const whatsappText = encodeURIComponent(
    `Hi Quick Solution, I need help with ${tracking?.order?.orderNumber || orderNumber || 'my order'}.`
  )

  return (
    <div className="qs-track-page">
      <Header/>
      <main className="qs-track-shell">
        <section className="qs-track-intro">
          <span className="eyebrow">Quick Solution order tracking</span>
          <h1>Know where your job is.</h1>
          <p>
            No account needed. Use your secure tracking link, or enter the order number
            and the same email or WhatsApp number used at checkout. Local 0-number and +27 formats both work.
          </p>
        </section>

        {!tracking && (
          <section className="qs-track-search-card">
            <div className="qs-track-search-heading">
              <div className="qs-track-search-icon"><Icon name="search" size={22}/></div>
              <div>
                <span className="eyebrow">Find an order</span>
                <h2>Track your Quick Solution job.</h2>
              </div>
            </div>

            <form onSubmit={(event) => { event.preventDefault(); lookup({ useToken: Boolean(secureToken) }) }}>
              <label>
                <span>Order number</span>
                <input
                  value={orderNumber}
                  onChange={(event) => setOrderNumber(event.target.value.toUpperCase())}
                  placeholder="e.g. QS-260913-78A5"
                  autoCapitalize="characters"
                  autoComplete="off"
                />
              </label>

              {!secureToken && (
                <label>
                  <span>Email or WhatsApp number</span>
                  <input
                    value={contact}
                    onChange={(event) => setContact(event.target.value)}
                    placeholder="e.g. 067 123 4567, +27 67 123 4567, or email"
                    autoComplete="email"
                  />
                </label>
              )}

              <button className="button primary-green" type="submit" disabled={state === 'loading'}>
                <Icon name="search" size={16}/>
                {state === 'loading' ? 'Checking…' : 'Track order'}
              </button>
            </form>

            {error ? <div className="qs-track-error"><Icon name="alertCircle" size={17}/><span>{error}</span></div> : null}

            <small className="qs-track-privacy">
              For privacy, Quick Solution does not reveal order details unless the secure link
              or matching checkout contact is provided.
            </small>
          </section>
        )}

        {tracking && (
          <section className="qs-track-result">
            <div className="qs-track-status-card">
              <div className="qs-track-status-top">
                <div>
                  <span className="eyebrow">Order {tracking.order.orderNumber}</span>
                  <h2>{tracking.stage.label}</h2>
                  <p>{tracking.stage.detail}</p>
                </div>
                <span className={`qs-track-status-pill ${statusTone(tracking.stage.key)}`}>
                  {tracking.stage.key === 'cancelled' ? 'Cancelled' : humanValue(tracking.stage.key)}
                </span>
              </div>

              {!isCancelled && (
                <div className="qs-track-progress">
                  <div className="qs-track-progress-line">
                    <span style={{ width: `${timeline.length > 1 ? (currentIndex / (timeline.length - 1)) * 100 : 0}%` }}/>
                  </div>
                  <div className="qs-track-progress-steps">
                    {timeline.map((step, index) => {
                      const reached = index <= currentIndex
                      const current = index === currentIndex
                      return (
                        <div className={`qs-track-step ${reached ? 'reached' : ''} ${current ? 'current' : ''}`} key={step.key}>
                          <span className="qs-track-step-dot">{reached ? <Icon name="checkCircle" size={16}/> : index + 1}</span>
                          <strong>{step.label}</strong>
                        </div>
                      )
                    })}
                  </div>
                </div>
              )}

              <div className="qs-track-updated">
                <span>Last updated</span>
                <strong title={fullDateTime(tracking.order.lastUpdated)}>{relativeDateTime(tracking.order.lastUpdated)}</strong>
                <button type="button" onClick={refresh}><Icon name="refresh" size={15}/> Refresh</button>
              </div>
            </div>

            <div className="qs-track-grid">
              <article className="qs-track-card">
                <span className="eyebrow">Payment</span>
                <div className="qs-track-card-title">
                  <strong>{tracking.order.paymentStatus === 'paid' ? 'Paid' : 'Payment pending'}</strong>
                  <span>{money(tracking.order.totalAmount)}</span>
                </div>
                <p>
                  {tracking.order.paymentStatus === 'paid'
                    ? 'Payment has been confirmed for this order.'
                    : 'The order is saved, but payment may still be required before production release.'}
                </p>
              </article>

              <article className="qs-track-card">
                <span className="eyebrow">How you’ll get it</span>
                <div className="qs-track-card-title">
                  <strong>{tracking.fulfilment.name || humanValue(tracking.fulfilment.type)}</strong>
                  <Icon name={tracking.fulfilment.type === 'delivery' ? 'truck' : 'pin'} size={19}/>
                </div>
                {fulfilmentAddress ? <p>{fulfilmentAddress}</p> : null}
                {Number(tracking.fulfilment.feeAmount || 0) > 0
                  ? <small>Fulfilment fee {money(tracking.fulfilment.feeAmount)}</small>
                  : <small>Free collection</small>}
                {tracking.fulfilment.easyLocateUrl ? (
                  <a href={tracking.fulfilment.easyLocateUrl} target="_blank" rel="noreferrer">
                    View collection point on Easy Locate <Icon name="external" size={14}/>
                  </a>
                ) : null}
              </article>
            </div>

            <article className="qs-track-card qs-track-items-card">
              <div className="qs-track-card-heading">
                <div>
                  <span className="eyebrow">Order</span>
                  <h3>What we’re handling.</h3>
                </div>
                <span>{items.length} line{items.length === 1 ? '' : 's'}</span>
              </div>
              <div className="qs-track-items">
                {items.map((item) => (
                  <div key={item.id || item.name}>
                    <div>
                      <strong>{item.name}</strong>
                      <small>Quantity {item.quantity || 1}</small>
                    </div>
                    <span>{money(item.lineTotal)}</span>
                  </div>
                ))}
              </div>
            </article>

            {(production.clientUpdate || production.detailStage || production.method) && (
              <article className="qs-track-update-card">
                <div className="qs-track-update-icon"><Icon name="layers" size={20}/></div>
                <div>
                  <span className="eyebrow">Production update</span>
                  <strong>{humanValue(production.detailStage || production.method || 'In progress')}</strong>
                  {production.method && production.detailStage ? <small>{humanValue(production.method)}</small> : null}
                  <p>{production.clientUpdate || `Your order is currently at ${humanValue(production.detailStage).toLowerCase()}.`}</p>
                </div>
              </article>
            )}

            {(delivery.courier || delivery.trackingNumber || delivery.pepCode || delivery.note) && (
              <article className="qs-track-update-card delivery">
                <div className="qs-track-update-icon"><Icon name="truck" size={20}/></div>
                <div>
                  <span className="eyebrow">Delivery</span>
                  <strong>{delivery.courier ? humanValue(delivery.courier) : 'Delivery update'}</strong>
                  {delivery.trackingNumber ? <p>Tracking: <b>{delivery.trackingNumber}</b></p> : null}
                  {delivery.pepCode ? <p>Collection / courier code: <b>{delivery.pepCode}</b></p> : null}
                  {delivery.note ? <p>{delivery.note}</p> : null}
                </div>
              </article>
            )}

            {tracking.message ? (
              <article className="qs-track-team-message">
                <Icon name="message" size={19}/>
                <div><span>Update from Quick Solution</span><p>{tracking.message}</p></div>
              </article>
            ) : null}

            {attention.length > 0 ? (
              <article className="qs-track-attention">
                <Icon name="alertCircle" size={19}/>
                <div>
                  <strong>We need something from you.</strong>
                  {attention.map((item, index) => <p key={index}>{String(item)}</p>)}
                </div>
              </article>
            ) : null}

            <div className="qs-track-actions">
              {secureToken ? (
                <button className="button dark" type="button" onClick={copyLink}>
                  <Icon name={copied ? 'checkCircle' : 'copy'} size={16}/>
                  {copied ? 'Tracking link copied' : 'Copy secure tracking link'}
                </button>
              ) : null}
              <a className="button ghost" href={`https://wa.me/27754534646?text=${whatsappText}`} target="_blank" rel="noreferrer">
                <Icon name="message" size={16}/> Need help?
              </a>
              <button className="button ghost" type="button" onClick={() => {
                setTracking(null)
                setOrderNumber('')
                setContact('')
                setError('')
                window.history.replaceState({}, '', '/track')
              }}>
                Track another order
              </button>
            </div>

            <small className="qs-track-trust">
              Quick Solution shows customer-safe progress only. Internal production notes, finance records and private files stay inside XOS / OPPS.
            </small>
          </section>
        )}
      </main>
    </div>
  )
}
