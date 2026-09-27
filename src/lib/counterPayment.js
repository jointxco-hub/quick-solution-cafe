// CAFE-GUEST-01Q - the pure side of opening a counter order and recording ONE full Cash or Card payment.
//
// The SERVER is the only authority: it says what is owed (the freshly loaded detail), it decides the amount that
// is recorded, and it flips the order to paid together with the ledger row. Nothing here computes an amount,
// chooses one, or sets a payment status; an unpaid order becomes paid on this screen only after the server says
// so, and then the order is loaded again.
//
// PAYMENT ATTEMPT (one per order): the idempotency key is made when the staff member CONFIRMS a method and is
// bound to that order and method. Confirm clicked twice, a retry after an unknown result, and a retry after signing
// back in all send the SAME key. While the result is unknown the attempt is locked: no other method, no new key,
// no cancel - only "Retry safely". A new key exists only for a new, explicit attempt (after cancelling an
// unconfirmed one, or after the server refused the last one). The key is never shown.

import { classifyCounterError, describeCounterConfiguration } from './counterDraft.js'
import { classifyCounterSubmitError, createSaleAttemptKey } from './counterSale.js'
import { counterPaymentLabel, counterStatusLabel, formatCounterOrderTime } from './counterOrders.js'
import { isCounterReceiptAvailable } from './counterReceipt.js'
import { formatMoney } from './pricing.js'

// Exactly the two methods this release records. Anything else does not exist on this screen.
export const COUNTER_PAYMENT_METHODS = Object.freeze([
  Object.freeze({ id: 'cash', label: 'Cash' }),
  Object.freeze({ id: 'card', label: 'Card' })
])
export const counterPaymentMethodLabel = (id) => COUNTER_PAYMENT_METHODS.find((method) => method.id === id)?.label || null

export const PAYMENT_PHASES = Object.freeze({
  IDLE: 'idle',
  CONFIRMING: 'confirming',
  SUBMITTING: 'submitting',
  SUCCESS: 'success',
  ALREADY_PAID: 'already-paid',
  REJECTED: 'rejected',
  UNKNOWN: 'unknown',
  CONFLICT: 'conflict',
  SIGNED_OUT: 'signed-out',
  DENIED: 'denied'
})

export const COUNTER_PAYMENT_UNKNOWN_MESSAGE = 'The payment may already have been recorded. Retry safely to confirm the result.'

// ── the order detail (a fresh server read) ───────────────────────────────

export async function loadCounterOrderDetailState(load, orderId) {
  let response
  try {
    response = await load(orderId)
  } catch (error) {
    if (/order was not found/i.test(String(error?.message || ''))) return { status: 'not-found', message: 'This order could not be found.' }
    return classifyCounterError(error)
  }
  if (!response || typeof response !== 'object' || typeof response.orderNumber !== 'string' || !Array.isArray(response.items)) {
    return { status: 'error', message: 'The counter returned an unexpected response.' }
  }
  return { status: 'ready', order: response }
}

const money = (value) => (Number.isFinite(Number(value)) ? formatMoney(Number(value)) : '—')

// Display fields for the detail screen. `entries` (the counter catalogue) only supplies field labels.
export function describeCounterOrderDetail(order, entries = []) {
  // CAFE-GUEST-01V: a cancelled order owes nothing, whatever its stored payment status still says.
  const cancelled = order?.status === 'cancelled'
  const items = (Array.isArray(order?.items) ? order.items : []).map((item) => {
    const entry = entries.find((candidate) => candidate.product.id === item?.productKey)
    let detail = null
    try {
      detail = entry ? describeCounterConfiguration(entry.product, item.configuration) : null
    } catch {
      detail = null
    }
    return { name: item?.productName || item?.productKey || 'Item', detail, lineTotal: money(item?.lineTotal) }
  })
  return {
    orderId: order?.orderId ?? null,
    orderNumber: order?.orderNumber || '—',
    time: formatCounterOrderTime(order?.createdAt),
    customer: order?.customerName || 'Walk-in',
    contact: [order?.customerPhone, order?.customerEmail].filter(Boolean).join(' · '),
    statusLabel: counterStatusLabel(order?.status),
    cancelled,
    paymentStatus: cancelled ? 'cancelled' : order?.paymentStatus ?? null,
    paymentLabel: cancelled ? 'Cancelled' : counterPaymentLabel(order?.paymentStatus),
    total: money(order?.totalAmount),
    amountPaid: money(order?.amountPaid),
    outstanding: cancelled ? money(0) : money(order?.outstanding),
    outstandingAmount: cancelled ? 0 : Number(order?.outstanding),
    // the SERVER decides whether a payment may be recorded; this is only that answer
    canPay: !cancelled && order?.paymentAllowed === true && Number(order?.outstanding) > 0 && order?.paymentStatus === 'unpaid',
    // a paid receipt exists only when the SERVER's detail is fully paid (see counterReceipt.js)
    receiptReady: isCounterReceiptAvailable(order),
    items,
    payments: (Array.isArray(order?.payments) ? order.payments : []).map((payment) => ({
      method: counterPaymentMethodLabel(payment?.method) || String(payment?.method || ''),
      amount: money(payment?.amount),
      time: formatCounterOrderTime(payment?.paidAt)
    }))
  }
}

// ── the payment attempt ──────────────────────────────────────────────────

export function initialPayment() {
  return { phase: PAYMENT_PHASES.IDLE, attempt: null, result: null, error: null }
}

// Idle -> confirming, for one of the two methods, only when the freshly loaded detail says a payment is allowed.
// The amount shown is the outstanding the server just reported; the key is made now.
export function beginPayment(payment, detail, methodId, makeKey = createSaleAttemptKey) {
  if (payment.phase !== PAYMENT_PHASES.IDLE) return payment
  if (!counterPaymentMethodLabel(methodId)) return payment
  const view = describeCounterOrderDetail(detail)
  if (!view.canPay || !view.orderId) return payment
  return {
    phase: PAYMENT_PHASES.CONFIRMING,
    attempt: {
      orderId: view.orderId,
      orderNumber: view.orderNumber,
      method: methodId,
      amountLabel: view.outstanding,
      idempotencyKey: makeKey(),
      submissions: 0
    },
    result: null,
    error: null
  }
}

// Confirming -> idle again (nothing was sent, so the key is simply dropped). Not possible once a request may exist.
export function cancelPayment(payment) {
  if (payment.phase !== PAYMENT_PHASES.CONFIRMING) return payment
  return initialPayment()
}

// A refused or conflicting attempt is finished: start over (a fresh key only when a new attempt is begun).
export function resetPayment(payment) {
  if (![PAYMENT_PHASES.REJECTED, PAYMENT_PHASES.CONFLICT, PAYMENT_PHASES.DENIED, PAYMENT_PHASES.ALREADY_PAID, PAYMENT_PHASES.SUCCESS].includes(payment.phase)) return payment
  return initialPayment()
}

// Confirming, unknown or signed-out -> submitting. A payment that is already submitting (or anything else) is
// returned unchanged, so a second click cannot start a second call.
export function beginPaymentSubmit(payment) {
  if (![PAYMENT_PHASES.CONFIRMING, PAYMENT_PHASES.UNKNOWN, PAYMENT_PHASES.SIGNED_OUT].includes(payment.phase) || !payment.attempt) return payment
  return { ...payment, phase: PAYMENT_PHASES.SUBMITTING, error: null, attempt: { ...payment.attempt, submissions: payment.attempt.submissions + 1 } }
}

export const COUNTER_PAYMENT_TIMEOUT_MS = 30000

function withTimeout(promise, ms) {
  let timer
  const timeout = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('The payment request timed out.')), ms) })
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer))
}

// Calls `record` exactly once with the frozen attempt and returns the next payment state. Never throws. The
// payload is only the order, the method and the key: no amount, no status, no tenant, no actor.
export async function submitPayment(payment, record, timeoutMs = COUNTER_PAYMENT_TIMEOUT_MS) {
  if (payment.phase !== PAYMENT_PHASES.SUBMITTING || !payment.attempt) return payment
  const { orderId, method, idempotencyKey } = payment.attempt
  let response
  try {
    response = await withTimeout(Promise.resolve().then(() => record({ orderId, method, idempotencyKey })), timeoutMs)
  } catch (error) {
    const failure = classifyCounterSubmitError(error)
    if (failure.kind === 'unknown') return { ...payment, phase: PAYMENT_PHASES.UNKNOWN, error: COUNTER_PAYMENT_UNKNOWN_MESSAGE, result: null }
    if (failure.kind === 'signed-out') return { ...payment, phase: PAYMENT_PHASES.SIGNED_OUT, error: 'Your staff session has ended. Sign in again to continue with this payment.', result: null }
    return { ...payment, phase: failure.kind, error: failure.message, result: null }
  }
  if (response && response.ok === false && response.reason === 'already_paid') {
    return { ...payment, phase: PAYMENT_PHASES.ALREADY_PAID, error: null, result: { orderNumber: response.orderNumber ?? payment.attempt.orderNumber } }
  }
  const amount = Number(response?.amount)
  if (!response || response.ok !== true || !Number.isFinite(amount) || typeof response.method !== 'string') {
    return { ...payment, phase: PAYMENT_PHASES.UNKNOWN, error: COUNTER_PAYMENT_UNKNOWN_MESSAGE, result: null }
  }
  return {
    ...payment,
    phase: PAYMENT_PHASES.SUCCESS,
    error: null,
    result: {
      orderNumber: response.orderNumber ?? payment.attempt.orderNumber,
      method: response.method,
      methodLabel: counterPaymentMethodLabel(response.method) || response.method,
      amount,
      amountLabel: formatMoney(amount),
      time: response.paidAt ? formatCounterOrderTime(response.paidAt) : null,
      replayed: response.replayed === true
    }
  }
}

export function resumePaymentAfterSignIn(payment) {
  if (payment.phase !== PAYMENT_PHASES.SIGNED_OUT || !payment.attempt) return payment
  return { ...payment, phase: PAYMENT_PHASES.CONFIRMING, error: null }
}

// While a request may exist or its result is unknown, the attempt cannot be changed, cancelled or replaced.
export function isPaymentLocked(payment) {
  return [PAYMENT_PHASES.SUBMITTING, PAYMENT_PHASES.UNKNOWN].includes(payment.phase)
}
