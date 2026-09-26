import React, { useCallback, useEffect, useRef, useState } from 'react'
import CounterView from './CounterView.jsx'
import {
  cancelQuickSolutionCounterOrder,
  createQuickSolutionCounterOrder,
  getAdminSession,
  loadQuickSolutionCancelledCounterOrders,
  loadQuickSolutionCounterCashup,
  loadQuickSolutionCounterCashupToday,
  loadQuickSolutionCounterCatalog,
  loadQuickSolutionCounterOrder,
  loadQuickSolutionCounterOrderCancelCheck,
  loadQuickSolutionCounterOrdersToday,
  loadQuickSolutionUnpaidCounterOrders,
  recordQuickSolutionCounterPayment,
  signInAdmin,
  signOutAdmin
} from '../lib/supabaseApi.js'
import { loadCounterCatalogueState, selectCounterProduct, setCounterDraftValue } from '../lib/counterDraft.js'
import { isBusinessDate, loadCounterCashupState } from '../lib/counterCashup.js'
import { loadCounterOrdersState } from '../lib/counterOrders.js'
import { loadCounterUnpaidState } from '../lib/counterUnpaid.js'
import { loadCounterCancelledState } from '../lib/counterCancelled.js'
import {
  CANCEL_PHASES,
  abortCancel,
  beginCancel,
  beginCancelSubmit,
  initialCancel,
  loadCounterCancelCheckState,
  resetCancel,
  resumeCancelAfterSignIn,
  setCancelReason,
  submitCancel
} from '../lib/counterCancel.js'
import {
  PAYMENT_PHASES,
  beginPayment,
  beginPaymentSubmit,
  cancelPayment,
  initialPayment,
  loadCounterOrderDetailState,
  resetPayment,
  resumePaymentAfterSignIn,
  submitPayment
} from '../lib/counterPayment.js'
import {
  EMPTY_COUNTER_CUSTOMER,
  SALE_PHASES,
  backToEdit,
  beginSubmit,
  initialSale,
  isSaleLocked,
  resumeAfterSignIn,
  reviewSale,
  startNewSale,
  submitSale
} from '../lib/counterSale.js'
import '../styles/qs-counter.css'

// /counter, the staff Counter. Its ONLY product source is the server's counter catalogue
// (loadQuickSolutionCounterCatalog); the server's answer - including a denial - is what the screen shows.
// Being signed in here is not authorization and nothing on this screen widens access.
//
// CAFE-GUEST-01O: for the four products the first write workflow supports (see
// counterSubmissionReadiness.js) staff can create ONE unpaid order through
// createQuickSolutionCounterOrder, once per confirmation. The sale state machine in counterSale.js owns
// the idempotency key and the phases; this component only wires it to React and to the API.
//
// CAFE-GUEST-01P: a second, read-only view lists today's counter orders from the server
// (loadQuickSolutionCounterOrdersToday). It is fetched each time it is opened and on Refresh; nothing is
// kept or inferred locally. Switching views never touches the sale in progress.
//
// CAFE-GUEST-01W: a fifth, read-only view lists the audited cancellations (loadQuickSolutionCancelledCounterOrders). The list is asked for once when the
// counter opens; only an admin or owner is answered, so the tab appears only for them (a plain member gets "denied" and never sees it). Rows open the same
// order detail, and Back reloads the list from the server.
//
// CAFE-GUEST-01V: an admin or owner can cancel a never-paid counter order from its detail. The screen asks the server (loadQuickSolutionCounterOrderCancelCheck)
// whether this caller may and whether the order can be cancelled, offers the action only when both are true, asks for a reason and a confirmation
// (cancelQuickSolutionCounterOrder), and reads the order again after every answer. The server decides who, when and why it is recorded.
//
// CAFE-GUEST-01U: the cash-up opens on TODAY (loadQuickSolutionCounterCashupToday) and can move to another Cafe business date
// (loadQuickSolutionCounterCashup(date)); only the calendar date is sent, the server decides the day and refuses a future one. Going Back
// from an order opened out of the cash-up returns to the same date.
//
// CAFE-GUEST-01T: a fourth, read-only view lists EVERY counter order that still owes money, oldest first
// (loadQuickSolutionUnpaidCounterOrders). Rows open the same order detail and the existing payment; going Back reloads the list from the
// server, so a settled order leaves it because the server stopped returning it, never because it was removed locally.
//
// CAFE-GUEST-01S: a third, read-only view shows today's cash-up from the server (loadQuickSolutionCounterCashupToday); its
// payment and unpaid rows open the same order detail, and Back returns to where the order was opened from.
//
// CAFE-GUEST-01Q: a row opens ONE order, read fresh from the server (loadQuickSolutionCounterOrder), and staff can
// record a full Cash or Card payment for it (recordQuickSolutionCounterPayment). The amount is the server's; a
// payment attempt per order keeps ONE idempotency key (counterPayment.js) and, once its result is unknown, stays
// locked to that key. The order is loaded again after every outcome that may have changed it.
export default function CounterPage() {
  const [state, setState] = useState(() => (getAdminSession() ? { status: 'loading' } : { status: 'signed-out' }))
  const [selectedId, setSelectedId] = useState(null)
  const [draft, setDraft] = useState(null)
  const [customer, setCustomer] = useState(EMPTY_COUNTER_CUSTOMER)
  const [sale, setSale] = useState(initialSale)
  const [signInError, setSignInError] = useState('')
  const [signInBusy, setSignInBusy] = useState(false)
  const [view, setView] = useState('sale')
  const [orders, setOrders] = useState({ status: 'loading' })
  const [cashup, setCashup] = useState({ status: 'loading' })
  const [unpaid, setUnpaid] = useState({ status: 'loading' })
  const [cancelled, setCancelled] = useState({ status: 'loading' })
  const [cashupDate, setCashupDate] = useState(null)
  const [todayDate, setTodayDate] = useState(null)
  const cashupRequest = useRef(0)
  const [orderOrigin, setOrderOrigin] = useState('orders')
  const [openOrderId, setOpenOrderId] = useState(null)
  const [orderDetail, setOrderDetail] = useState({ status: 'loading' })
  const [payments, setPayments] = useState({})
  const [cancelCheck, setCancelCheck] = useState({ status: 'none' })
  const [cancels, setCancels] = useState({})
  const alive = useRef(true)
  const inFlight = useRef(false)
  const paymentInFlight = useRef(false)
  const cancelInFlight = useRef(false)
  const detailRequest = useRef(0)

  const reset = () => {
    setSelectedId(null)
    setDraft(null)
    setCustomer(EMPTY_COUNTER_CUSTOMER)
    setSale(startNewSale())
  }

  const loadCancelled = useCallback(async () => {
    setCancelled((current) => (current.summary ? { ...current, refreshing: true } : { status: 'loading' }))
    const next = await loadCounterCancelledState(loadQuickSolutionCancelledCounterOrders)
    if (alive.current) setCancelled(next)
  }, [])

  const load = useCallback(async () => {
    setState({ status: 'loading' })
    const next = await loadCounterCatalogueState(loadQuickSolutionCounterCatalog)
    if (!alive.current) return
    setSelectedId(null)
    setDraft(null)
    setCustomer(EMPTY_COUNTER_CUSTOMER)
    setSale(startNewSale())
    setView('sale')
    setOrders({ status: 'loading' })
    setCashup({ status: 'loading' })
    setCashupDate(null)
    setTodayDate(null)
    setUnpaid({ status: 'loading' })
    setCancelled({ status: 'loading' })
    setOpenOrderId(null)
    setOrderDetail({ status: 'loading' })
    setPayments({})
    setCancelCheck({ status: 'none' })
    setCancels({})
    setState(next)
    if (next.status === 'ready') loadCancelled()
  }, [loadCancelled])

  const loadOrders = useCallback(async () => {
    setOrders((current) => (current.orders?.length ? { ...current, refreshing: true } : { status: 'loading' }))
    const next = await loadCounterOrdersState(loadQuickSolutionCounterOrdersToday)
    if (alive.current) setOrders(next)
  }, [])

  // date === null is today. Only a calendar date is ever sent; a stale answer for a date that is no longer selected is dropped.
  const loadCashup = useCallback(async (date = null) => {
    const request = ++cashupRequest.current
    setCashup((current) => (current.summary && (current.date || null) === date ? { ...current, refreshing: true } : { status: 'loading', date }))
    const next = await loadCounterCashupState(date ? () => loadQuickSolutionCounterCashup(date) : loadQuickSolutionCounterCashupToday)
    if (!alive.current || request !== cashupRequest.current) return
    const today = !date && next.summary && typeof next.summary.businessDate === 'string' ? next.summary.businessDate : null
    if (today) setTodayDate(today)
    setCashup({ ...next, date })
  }, [])

  // Choose a Cafe day: null is Today. A future day is not sent to the server at all; it shows a plain state.
  const selectCashupDate = (value) => {
    if (value === null || value === todayDate) {
      setCashupDate(null)
      loadCashup(null)
      return
    }
    if (!isBusinessDate(value)) return
    setCashupDate(value)
    if (todayDate && value > todayDate) {
      cashupRequest.current += 1
      setCashup({ status: 'future', date: value })
      return
    }
    loadCashup(value)
  }

  const loadUnpaid = useCallback(async () => {
    setUnpaid((current) => (current.summary ? { ...current, refreshing: true } : { status: 'loading' }))
    const next = await loadCounterUnpaidState(loadQuickSolutionUnpaidCounterOrders)
    if (alive.current) setUnpaid(next)
  }, [])

  const showView = (next) => {
    setView(next)
    if (next === 'orders') loadOrders()
    if (next === 'cashup') {
      setCashupDate(null)
      loadCashup(null)
    }
    if (next === 'unpaid') loadUnpaid()
    if (next === 'cancelled') loadCancelled()
  }

  useEffect(() => {
    alive.current = true
    if (getAdminSession()) load()
    return () => { alive.current = false }
  }, [load])

  // The order is always read from the server: the row in the list is never the source of what is owed.
  const loadDetail = useCallback(async (orderId) => {
    const request = ++detailRequest.current
    setOrderDetail((current) => (current.orderId === orderId && current.order ? { ...current, refreshing: true } : { status: 'loading', orderId }))
    const next = await loadCounterOrderDetailState(loadQuickSolutionCounterOrder, orderId)
    if (!alive.current || request !== detailRequest.current) return
    setOrderDetail({ ...next, orderId })
    // The cancel offer comes from the server too, and only for an order that could still be cancelled; anything else offers nothing.
    if (next.status === 'ready' && next.order.status !== 'cancelled' && next.order.paymentStatus !== 'paid') {
      const check = await loadCounterCancelCheckState(loadQuickSolutionCounterOrderCancelCheck, orderId)
      if (alive.current && request === detailRequest.current) setCancelCheck({ ...check, orderId })
    } else {
      setCancelCheck({ status: 'none', orderId })
    }
  }, [])

  const openOrder = (orderId, origin = 'orders') => {
    if (!orderId) return
    setCancelCheck({ status: 'none', orderId })
    setOrderOrigin(origin)
    setOpenOrderId(orderId)
    setView('order')
    loadDetail(orderId)
  }

  // The receipt is the server's paid order detail, loaded again when it is opened; printing is the browser's own.
  const openReceipt = () => {
    if (!openOrderId) return
    setView('receipt')
    loadDetail(openOrderId)
  }

  const backToOrders = () => {
    if (orderOrigin === 'cashup') {
      setView('cashup')
      loadCashup(cashupDate)
      return
    }
    if (orderOrigin === 'unpaid') {
      setView('unpaid')
      loadUnpaid()
      return
    }
    if (orderOrigin === 'cancelled') {
      setView('cancelled')
      loadCancelled()
      return
    }
    setView('orders')
    loadOrders()
  }

  const payment = payments[openOrderId] || initialPayment()
  const setPayment = (update) => setPayments((current) => ({ ...current, [openOrderId]: update(current[openOrderId] || initialPayment()) }))

  const choosePayment = (methodId) => {
    if (orderDetail.status === 'ready') setPayment((current) => beginPayment(current, orderDetail.order, methodId))
  }

  // The one payment call per confirmation. The button is disabled while it runs, but correctness does not depend on
  // that: beginPaymentSubmit refuses an attempt that is already submitting, and the server pays an order once.
  const confirmPayment = async () => {
    if (paymentInFlight.current) return
    const orderId = openOrderId
    const started = beginPaymentSubmit(payment)
    if (started === payment) return
    paymentInFlight.current = true
    setPayments((current) => ({ ...current, [orderId]: started }))
    try {
      const next = await submitPayment(started, recordQuickSolutionCounterPayment)
      if (!alive.current) return
      setPayments((current) => ({ ...current, [orderId]: next }))
      // whatever the server answered, the order may have changed: read it again (not when the result is unknown)
      if ([PAYMENT_PHASES.SUCCESS, PAYMENT_PHASES.ALREADY_PAID, PAYMENT_PHASES.REJECTED, PAYMENT_PHASES.DENIED].includes(next.phase)) loadDetail(orderId)
    } finally {
      paymentInFlight.current = false
    }
  }

  const resetOrderPayment = () => {
    setPayment((current) => resetPayment(current))
    if (openOrderId) loadDetail(openOrderId)
  }

  const cancel = cancels[openOrderId] || initialCancel()
  const setCancel = (update) => setCancels((current) => ({ ...current, [openOrderId]: update(current[openOrderId] || initialCancel()) }))

  const startCancel = () => {
    if (orderDetail.status === 'ready') setCancel((current) => beginCancel(current, cancelCheck, orderDetail.order))
  }

  // The one cancel call per confirmation: the button is disabled while it runs, but beginCancelSubmit also refuses an attempt that is
  // already submitting, and the server cancels an order once (the same admin and reason get the original result back).
  const confirmCancel = async () => {
    if (cancelInFlight.current) return
    const orderId = openOrderId
    const started = beginCancelSubmit(cancel)
    if (started === cancel || started.phase !== CANCEL_PHASES.SUBMITTING) {
      if (started !== cancel) setCancels((current) => ({ ...current, [orderId]: started }))
      return
    }
    cancelInFlight.current = true
    setCancels((current) => ({ ...current, [orderId]: started }))
    try {
      const next = await submitCancel(started, cancelQuickSolutionCounterOrder)
      if (!alive.current) return
      setCancels((current) => ({ ...current, [orderId]: next }))
      if ([CANCEL_PHASES.SUCCESS, CANCEL_PHASES.REJECTED, CANCEL_PHASES.DENIED].includes(next.phase)) loadDetail(orderId)
      if (next.phase === CANCEL_PHASES.SUCCESS) loadCancelled()
    } finally {
      cancelInFlight.current = false
    }
  }

  const resetOrderCancel = () => {
    setCancel((current) => resetCancel(current))
    if (openOrderId) loadDetail(openOrderId)
  }

  const selectedEntry = () => (state.entries || []).find((item) => item.product.id === selectedId)

  const select = (productId) => {
    if (isSaleLocked(sale)) return
    const entry = (state.entries || []).find((item) => item.product.id === productId)
    if (!entry) return
    setSale((current) => backToEdit(current))
    setSelectedId(productId)
    setDraft((current) => selectCounterProduct(current, entry.product))
    // On a phone the options sit below the product list, so bring them into view.
    window.requestAnimationFrame?.(() => {
      if (window.matchMedia?.('(max-width: 899px)').matches) document.querySelector('.qsc-work')?.scrollIntoView?.({ block: 'start', behavior: 'smooth' })
    })
  }

  const change = (fieldId, value) => {
    const entry = selectedEntry()
    if (entry) setDraft((current) => setCounterDraftValue(current, entry.product, fieldId, value))
  }

  const changeCustomer = (field, value) => setCustomer((current) => ({ ...current, [field]: value }))

  const review = () => {
    const entry = selectedEntry()
    if (entry) setSale((current) => reviewSale(current, { entry, draft, customer }))
  }

  // The one create call. The button is disabled while it runs, but correctness does not depend on that:
  // beginSubmit refuses a sale that is already submitting, and the server returns the one order for a
  // repeated key.
  const submit = async () => {
    if (inFlight.current) return
    const started = beginSubmit(sale)
    if (started === sale) return
    inFlight.current = true
    setSale(started)
    try {
      const next = await submitSale(started, createQuickSolutionCounterOrder)
      if (alive.current) setSale(next)
    } finally {
      inFlight.current = false
    }
  }

  const signIn = async (email, password) => {
    setSignInError('')
    setSignInBusy(true)
    try {
      await signInAdmin(email, password)
      setSignInBusy(false)
      let handled = false
      if (sale.phase === SALE_PHASES.SIGNED_OUT) { setSale((current) => resumeAfterSignIn(current)); handled = true }
      if (view === 'order' && payment.phase === PAYMENT_PHASES.SIGNED_OUT) { setPayment((current) => resumePaymentAfterSignIn(current)); handled = true }
      if (view === 'order' && cancel.phase === CANCEL_PHASES.SIGNED_OUT) { setCancel((current) => resumeCancelAfterSignIn(current)); handled = true }
      if (view === 'order' && orderDetail.status === 'signed-out') { await loadDetail(openOrderId); handled = true }
      if (view === 'orders') { await loadOrders(); handled = true }
      if (view === 'cashup') { await loadCashup(cashupDate); handled = true }
      if (view === 'unpaid') { await loadUnpaid(); handled = true }
      if (view === 'cancelled') { await loadCancelled(); handled = true }
      if (!handled) await load()
    } catch (error) {
      setSignInBusy(false)
      setSignInError(error?.message || 'Could not sign in.')
    }
  }

  const signOut = async () => {
    await signOutAdmin()
    reset()
    setState({ status: 'signed-out' })
  }

  return (
    <CounterView
      state={state}
      selectedId={selectedId}
      draft={draft}
      customer={customer}
      sale={sale}
      onSelect={select}
      onChange={change}
      onCustomerChange={changeCustomer}
      onReview={review}
      onBackToEdit={() => setSale((current) => backToEdit(current))}
      onSubmit={submit}
      onNewSale={reset}
      onRetry={load}
      onSignIn={signIn}
      signInError={signInError}
      signInBusy={signInBusy}
      onSignOut={signOut}
      view={view}
      onView={showView}
      orders={orders}
      onRefreshOrders={loadOrders}
      orderDetail={orderDetail}
      payment={payment}
      onOpenOrder={openOrder}
      onBackToOrders={backToOrders}
      onChoosePayment={choosePayment}
      onCancelPayment={() => setPayment((current) => cancelPayment(current))}
      onConfirmPayment={confirmPayment}
      onResetPayment={resetOrderPayment}
      onReloadOrder={() => openOrderId && loadDetail(openOrderId)}
      onOpenReceipt={openReceipt}
      cancelCheck={cancelCheck}
      cancel={cancel}
      onStartCancel={startCancel}
      onCancelReason={(text) => setCancel((current) => setCancelReason(current, text))}
      onAbortCancel={() => setCancel((current) => abortCancel(current))}
      onConfirmCancel={confirmCancel}
      onResetCancel={resetOrderCancel}
      cashup={{ ...cashup, todayDate, date: cashup.date ?? cashupDate }}
      onRefreshCashup={() => loadCashup(cashupDate)}
      onSelectCashupDate={selectCashupDate}
      unpaid={unpaid}
      onRefreshUnpaid={loadUnpaid}
      cancelled={cancelled}
      onRefreshCancelled={loadCancelled}
      orderOrigin={orderOrigin}
      onCloseReceipt={() => setView('order')}
      onPrintReceipt={() => window.print()}
    />
  )
}
