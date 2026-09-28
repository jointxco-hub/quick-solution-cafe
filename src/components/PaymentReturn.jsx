import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import Header from './Header.jsx'
import Icon from './Icon.jsx'
import PaymentRedirectLoader from './PaymentRedirectLoader.jsx'
import { beginQuickSolutionPayment, getQuickSolutionPaymentStatus } from '../lib/supabaseApi.js'
import {
  clearQuickSolutionPaymentSession,
  readQuickSolutionPaymentSession
} from '../lib/paymentSession.js'
import { buildQuickSolutionTrackingHref, readQuickSolutionTrackingSession } from '../lib/trackingSession.js'
import { buildWhatsappUrl } from '../lib/businessInfo.js'
import { canStartPayfastRedirect, resolvePayfastInitOutcome } from '../lib/payfastInit.js'

function money(value) {
  return new Intl.NumberFormat('en-ZA', {
    style: 'currency',
    currency: 'ZAR',
    minimumFractionDigits: 2
  }).format(Number(value || 0))
}

export default function PaymentReturn() {
  const params = useMemo(() => new URLSearchParams(window.location.search), [])
  const orderId = params.get('order') || ''
  const mode = params.get('qs_payment') || 'return'
  const session = useMemo(() => readQuickSolutionPaymentSession(orderId), [orderId])
  const trackingSession = useMemo(() => readQuickSolutionTrackingSession(orderId), [orderId])

  const [state, setState] = useState(mode === 'cancel' ? 'cancelled' : 'checking')
  const [status, setStatus] = useState(null)
  const [message, setMessage] = useState('')
  const [attempt, setAttempt] = useState(0)
  const [payAgainState, setPayAgainState] = useState('idle')
  const [payAgainError, setPayAgainError] = useState('')
  const payAgainInFlight = useRef(false)

  // Explicit action, never automatic: this order's saved payment session is
  // read fresh (the same session readQuickSolutionPaymentSession already
  // gave this page), and re-uses the exact same beginQuickSolutionPayment
  // call the basket/guided checkout use - it never touches the storefront
  // cart in any way, so there is no path from "pay again" back into an
  // editable basket.
  const payAgain = async () => {
    if (!session?.paymentToken || !orderId) return
    if (payAgainInFlight.current || !canStartPayfastRedirect(payAgainState)) return
    payAgainInFlight.current = true
    setPayAgainError('')
    setPayAgainState('starting')
    try {
      const result = await beginQuickSolutionPayment(orderId, session.paymentToken)
      const outcome = resolvePayfastInitOutcome(result)
      if (outcome.type === 'paid') {
        setPayAgainState('paid')
        setState('paid')
        return
      }
      if (outcome.type === 'error') throw new Error(outcome.message)
      setPayAgainState('redirecting')
      window.location.assign(outcome.url)
    } catch (error) {
      payAgainInFlight.current = false
      setPayAgainState('error')
      setPayAgainError(error?.message || 'Could not open PayFast.')
    }
  }

  const check = useCallback(async ({ quiet = false } = {}) => {
    if (!session?.paymentToken || !orderId) {
      setState('unknown')
      setMessage('We could not restore this browser payment session. The order can still be reconciled by PayFast in the background.')
      return false
    }

    if (!quiet) {
      setState('checking')
      setMessage('')
    }

    try {
      const result = await getQuickSolutionPaymentStatus(orderId, session.paymentToken)
      setStatus(result)
      if (result?.paid) {
        setState('paid')
        clearQuickSolutionPaymentSession(orderId)
        return true
      }
      setState(mode === 'cancel' ? 'cancelled' : 'pending')
      return false
    } catch (error) {
      setState('pending')
      setMessage(error?.message || 'Payment confirmation is taking a little longer than expected.')
      return false
    }
  }, [mode, orderId, session])

  useEffect(() => {
    if (mode === 'cancel') {
      check()
      return
    }

    let cancelled = false
    let timer = null
    let tries = 0

    const poll = async () => {
      if (cancelled) return
      tries += 1
      setAttempt(tries)
      const paid = await check({ quiet: tries > 1 })
      if (!paid && tries < 12 && !cancelled) {
        timer = window.setTimeout(poll, 2000)
      }
    }

    poll()
    return () => {
      cancelled = true
      if (timer) window.clearTimeout(timer)
    }
  }, [check, mode])

  const orderNumber = session?.orderNumber || status?.orderNumber || 'Your Quick Solution order'
  const amount = session?.amount || status?.amount || 0
  const trackingHref = trackingSession?.trackingToken
    ? buildQuickSolutionTrackingHref(trackingSession.orderNumber || orderNumber, trackingSession.trackingToken)
    : '/track'

  const content = {
    paid: {
      eyebrow: 'Payment confirmed',
      title: 'You’re paid up.',
      copy: 'PayFast confirmed the payment and Quick Solution has updated this order.',
      icon: 'checkCircle'
    },
    cancelled: {
      eyebrow: 'Payment not completed',
      title: 'Your order is still saved.',
      copy: 'No problem. The order remains in Quick Solution and you can pay again when you are ready.',
      icon: 'xCircle'
    },
    pending: {
      eyebrow: 'Confirming payment',
      title: 'We’re waiting for PayFast.',
      copy: 'Your order is safe. Payment confirmation can take a few seconds after returning from PayFast.',
      icon: 'refresh'
    },
    checking: {
      eyebrow: 'Checking payment',
      title: 'Confirming with PayFast…',
      copy: `Checking your payment${attempt > 1 ? ` · attempt ${attempt}` : ''}.`,
      icon: 'refresh'
    },
    unknown: {
      eyebrow: 'Order saved',
      title: 'We can’t verify this browser session.',
      copy: 'PayFast can still confirm the transaction directly to Quick Solution. Staff will see the payment once it reconciles.',
      icon: 'bag'
    }
  }[state] || {
    eyebrow: 'Payment',
    title: 'Checking your order.',
    copy: '',
    icon: 'refresh'
  }

  if (payAgainState === 'starting' || payAgainState === 'redirecting') {
    return <PaymentRedirectLoader orderNumber={orderNumber} amount={amount}/>
  }

  return (
    <div className="qs-payment-return-page">
      <Header
        onGoHome={() => { window.location.href = '/' }}
        onGoShop={() => { window.location.href = '/shop' }}
        onGoQuickPoints={() => { window.location.href = '/#quick-points' }}
      />
      <main className="qs-payment-return-shell">
        <section className={`qs-payment-return-card ${state}`}>
          <div className="qs-payment-return-icon"><Icon name={content.icon} size={26}/></div>
          <span className="eyebrow">{content.eyebrow}</span>
          <h1>{content.title}</h1>
          <p>{content.copy}</p>

          <div className="qs-payment-return-order">
            <div>
              <small>Order</small>
              <strong>{orderNumber}</strong>
            </div>
            {amount > 0 && (
              <div>
                <small>Amount</small>
                <strong>{money(amount)}</strong>
              </div>
            )}
            <div>
              <small>Status</small>
              <strong>{state === 'paid' ? 'Paid' : state === 'cancelled' ? 'Unpaid' : 'Checking'}</strong>
            </div>
          </div>

          {message ? <p className="qs-payment-return-note">{message}</p> : null}
          {payAgainError ? <p className="qs-payment-return-note">{payAgainError}</p> : null}

          <div className="qs-payment-return-actions">
            {(state === 'cancelled' || state === 'pending') && session?.paymentToken && (
              <button className="button primary-green" type="button" disabled={!canStartPayfastRedirect(payAgainState)} onClick={payAgain}>
                Pay again
              </button>
            )}
            {state !== 'paid' && (
              <button className="button ghost" type="button" onClick={() => check()}>
                Check payment again
              </button>
            )}
            <a className="button primary-green" href={trackingHref}><Icon name="search" size={16}/> Track this order</a>
            <a className="button ghost" href="/">Back to Quick Solution</a>
            <a className="button ghost" href={buildWhatsappUrl()} target="_blank" rel="noreferrer">
              Need help? WhatsApp us
            </a>
          </div>

          <small className="qs-payment-return-trust">
            The browser return page never marks an order paid by itself. Only the validated PayFast notification can do that.
          </small>
        </section>
      </main>
    </div>
  )
}
