import React, { useEffect, useRef, useState } from 'react'
import Header from './Header.jsx'
import { customerClient, readRecoverableOrders } from '../lib/customerApi.js'
import { parseGuestTrackingLink } from '../lib/customerClient.js'
import { beginQuickSolutionPayment } from '../lib/supabaseApi.js'
import { saveQuickSolutionPaymentSession } from '../lib/paymentSession.js'
import { resolvePayfastInitOutcome } from '../lib/payfastInit.js'
import { buildWhatsappUrl } from '../lib/businessInfo.js'
import '../styles/customer-account.css'

const money = value => new Intl.NumberFormat('en-ZA', { style: 'currency', currency: 'ZAR' }).format(Number(value || 0))
const date = value => value ? new Date(value).toLocaleDateString('en-ZA') : ''

export default function CustomerAccount() {
  const api = customerClient()
  const [signedIn, setSignedIn] = useState(Boolean(api.read()?.access_token))
  const [email, setEmail] = useState('')
  const [state, setState] = useState('loading')
  const [message, setMessage] = useState('')
  const [orders, setOrders] = useState([])
  const [offset, setOffset] = useState(0)
  const [hasMore, setHasMore] = useState(false)
  const [selected, setSelected] = useState(null)
  const [detail, setDetail] = useState(null)
  const [busy, setBusy] = useState(false)
  const [paying, setPaying] = useState(false)
  const [guestLink, setGuestLink] = useState('')
  const actionLock = useRef(false)
  const mounted = useRef(true)
  const requestVersion = useRef(0)
  const recent = readRecoverableOrders()

  const load = async (page = 0) => {
    const version = ++requestVersion.current
    setState('loading'); setMessage('')
    try {
      if (!await api.session()) { if (mounted.current) { setSignedIn(false); setState('idle') }; return }
      const result = await api.rpc('qs_customer_orders', { p_offset: page })
      if (!mounted.current || version !== requestVersion.current) return
      setEmail(result.email); setOrders(result.orders || []); setOffset(page); setHasMore(result.hasMore); setSignedIn(true); setState('ready')
    } catch (error) {
      if (!mounted.current || version !== requestVersion.current) return
      if (!api.read()) setSignedIn(false)
      setState('error'); setMessage(error.message)
    }
  }
  const openOrder = async id => {
    const version = ++requestVersion.current
    setSelected(id); setDetail(null); setState('loading'); setMessage('')
    try {
      const result = await api.rpc('qs_customer_order', { p_order_id: id })
      if (mounted.current && version === requestVersion.current) { setDetail(result); setState('ready') }
    } catch (error) { if (mounted.current && version === requestVersion.current) { setState('error'); setMessage(error.message) } }
  }
  useEffect(() => {
    mounted.current = true
    try { api.consumeRedirect(); load() } catch (error) { setState('error'); setMessage(error.message) }
    return () => { mounted.current = false; requestVersion.current += 1 }
  }, [])
  useEffect(() => {
    if (!signedIn || !selected || paying) return
    // Refresh on return from another tab; preserve current data during the check.
    const refresh = async () => {
      if (document.visibilityState !== 'visible' || actionLock.current) return
      const id = selected
      const version = requestVersion.current
      try {
        const result = await api.rpc('qs_customer_order', { p_order_id: id })
        if (mounted.current && version === requestVersion.current) setDetail(result)
      } catch { /* Explicit Refresh displays recoverable errors. */ }
    }
    window.addEventListener('focus', refresh)
    document.addEventListener('visibilitychange', refresh)
    return () => { window.removeEventListener('focus', refresh); document.removeEventListener('visibilitychange', refresh) }
  }, [signedIn, selected, paying])

  const sendLink = async event => {
    event.preventDefault()
    if (actionLock.current) return
    actionLock.current = true; setBusy(true); setMessage('')
    try { await api.sendLink(email); setState('sent'); setMessage('Check your email and open the sign-in link. You can close this page and return from your email.') }
    catch (error) { setState('error'); setMessage(error.status === 429 ? 'Please wait a minute before requesting another link.' : error.message) }
    finally { actionLock.current = false; setBusy(false) }
  }
  const signOut = async () => {
    if (actionLock.current) return
    actionLock.current = true; setBusy(true)
    try { await api.signOut(); setMessage('Signed out.') }
    catch { setMessage('Signed out on this device. The server could not be reached.') }
    finally {
      requestVersion.current += 1; setSignedIn(false); setOrders([]); setDetail(null); setSelected(null); setEmail(''); setState('idle'); setBusy(false); actionLock.current = false
    }
  }
  const linkOrder = async item => {
    if (actionLock.current) return
    actionLock.current = true; setBusy(true); setMessage('')
    try { await api.rpc('qs_customer_link_order', { p_order_id: item.orderId, p_token: item.token }); await load(0); setMessage(`${item.orderNumber} saved to your account.`) }
    catch (error) { setMessage(error.message) }
    finally { actionLock.current = false; setBusy(false) }
  }
  const pay = async () => {
    if (actionLock.current || !detail?.payment?.canPay) return
    actionLock.current = true; setPaying(true); setMessage('')
    try {
      const session = await api.rpc('qs_customer_payment_session', { p_order_id: selected })
      saveQuickSolutionPaymentSession(session)
      const outcome = resolvePayfastInitOutcome(await beginQuickSolutionPayment(selected, session.paymentToken))
      if (outcome.type === 'paid') { await openOrder(selected); actionLock.current = false; setPaying(false); return }
      if (outcome.type === 'error') throw new Error(outcome.message)
      window.location.assign(outcome.url)
    } catch (error) { actionLock.current = false; setPaying(false); setMessage(error.message); await openOrder(selected); setMessage(error.message) }
  }
  const saveGuestLink = async event => {
    event.preventDefault()
    if (actionLock.current) return
    const link = parseGuestTrackingLink(guestLink)
    if (!link) { setMessage('Paste the complete secure tracking link supplied with your order.'); return }
    actionLock.current = true; setBusy(true); setMessage('')
    try {
      await api.rpc('qs_customer_link_tracking', { p_order_number: link.orderNumber, p_tracking_token: link.trackingToken })
      setGuestLink(''); await load(0); setMessage(`${link.orderNumber} saved to your account.`)
    } catch (error) { setMessage(error.message) }
    finally { actionLock.current = false; setBusy(false) }
  }
  return <><Header/><main className="customer-account">
    <a href="/shop">← Continue shopping</a>
    <div className="account-heading"><h1>My orders</h1>{signedIn && <button type="button" className="button primary-light" onClick={signOut} disabled={busy || paying}>Sign out</button>}</div>
    {message && <p role={state === 'error' ? 'alert' : 'status'} className="account-notice">{message}</p>}
    {!signedIn ? <section className="account-card">
      <h2>Sign in with your email</h2><p>Find your saved orders, track progress and pay when you’re ready.</p>
      <form onSubmit={sendLink}><label>Email address<input required type="email" autoComplete="email" value={email} onChange={event => setEmail(event.target.value)} disabled={busy}/></label>
        <button className="button dark" disabled={busy}>{busy ? 'Sending…' : state === 'sent' ? 'Send another link' : 'Email me a sign-in link'}</button></form>
      <p>You can still <a href="/shop">order as a guest</a> or <a href="/track">track an order</a>.</p>
    </section> : <>
      <p className="account-email">{email}</p>
      {selected ? <>
        <button type="button" className="button primary-light" disabled={paying} onClick={() => { setSelected(null); setDetail(null); load(offset) }}>← All orders</button>
        <button type="button" className="button primary-light" disabled={state === 'loading' || paying} onClick={() => openOrder(selected)}>Refresh order</button>
        {detail && <section className="account-card">
          <h2>{detail.tracking?.order?.orderNumber}</h2>
          <p>{detail.tracking?.stage?.label}</p><p>{detail.tracking?.stage?.detail}</p>
          <ul>{detail.tracking?.order?.items?.map(item => <li key={item.id}>{item.name} · {item.quantity} × · {money(item.lineTotal)}</li>)}</ul>
          <h3>Payment</h3>
          <div className="account-totals"><span>Total</span><strong>{money(detail.payment.total)}</strong><span>Received</span><strong>{money(detail.payment.received)}</strong><span>Outstanding</span><strong>{detail.payment.balanceDue === null ? 'Being reviewed' : money(detail.payment.balanceDue)}</strong></div>
          {detail.payment.receipts?.length > 0 && <details><summary>Received payments</summary><ul>{detail.payment.receipts.map(receipt => <li key={receipt.id}>{money(receipt.amount)} · {receipt.method} · {date(receipt.receivedAt)}</li>)}</ul></details>}
          {detail.payment.canPay ? <button type="button" className="button dark" onClick={pay} disabled={paying}>{paying ? 'Opening PayFast…' : `Pay ${money(detail.payment.balanceDue)} securely`}</button>
            : detail.payment.balanceDue !== 0 && <p>{detail.payment.reviewRequired ? 'We’re reviewing the payment record. Please contact the Café before paying again.' : 'Online payment is not available for this order. Contact the Café for payment options.'}</p>}
          <a className="button primary-light" href={buildWhatsappUrl(encodeURIComponent(`Hi Quick Solution, please help with order ${detail.tracking?.order?.orderNumber || ''}.`))}>Get help with this order</a>
        </section>}
      </> : <>
        <button type="button" className="button primary-light" disabled={state === 'loading' || busy} onClick={() => load(offset)}>Refresh orders</button>
        {state === 'ready' && orders.length === 0 && <section className="account-card"><h2>No saved orders yet</h2><p>Orders placed while signed in will appear here. Previous guest orders need their secure link and the same email.</p><a href="/shop">Browse products</a></section>}
        <div className="account-orders">{orders.map(order => <button type="button" key={order.id} className="account-order account-card" onClick={() => openOrder(order.id)} disabled={busy}><strong>{order.orderNumber}</strong><span>{order.itemName}</span><span>{date(order.submittedAt)} · {order.status.replaceAll('_', ' ')}</span><span>{money(order.totalAmount)} · {order.paymentStatus === 'paid' ? 'Paid' : 'Payment pending'}</span><span>View order →</span></button>)}</div>
        {(offset > 0 || hasMore) && <div className="account-pages"><button type="button" disabled={offset === 0 || state === 'loading'} onClick={() => load(Math.max(0, offset - 20))}>Previous</button><button type="button" disabled={!hasMore || state === 'loading'} onClick={() => load(offset + 20)}>Next</button></div>}
        {recent.filter(item => !orders.some(order => order.id === item.orderId)).length > 0 && <section className="account-card"><h2>Guest orders on this device</h2><p>Save an order placed using this email. Other guest orders can still be tracked using their original links.</p>{recent.filter(item => !orders.some(order => order.id === item.orderId)).map(item => <p key={item.orderId}>{item.orderNumber} <button type="button" disabled={busy} onClick={() => linkOrder(item)}>Save to my account</button></p>)}</section>}
        <section className="account-card"><h2>Save a previous guest order</h2><p>Use the secure tracking link and sign in with the email used for that order. For phone-only orders or an expired link, contact the Café.</p><form onSubmit={saveGuestLink}><label>Secure tracking link<input type="url" required value={guestLink} onChange={event => setGuestLink(event.target.value)} disabled={busy} placeholder="Paste your order tracking link"/></label><button className="button primary-light" disabled={busy}>Save to My orders</button></form>
          <div className="account-recovery-help">
            <h3>Lost your order link?</h3>
            <p>Ask us to help find your order.</p>
            <a className="button dark" target="_blank" rel="noopener noreferrer" href={buildWhatsappUrl(encodeURIComponent(`Hi Quick Solution Café, I’ve lost my order link. Please help me find it.\n\nMy name: \nEmail or phone used for the order: ${email}\nApproximate order date: `))}>Request order link on WhatsApp</a>
            <p className="account-email">Opens WhatsApp with a message ready for you to complete and send.</p>
          </div>
        </section>
      </>}
    </>}
    {state === 'loading' && <p role="status">Loading your orders…</p>}
  </main></>
}
