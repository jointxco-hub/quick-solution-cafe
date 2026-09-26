// CAFE-GUEST-01O - the sale-attempt state machine behind the Counter's create-unpaid-order flow.
//
// Pure functions (plus one async function that calls an INJECTED create function once). No React, no
// API import, no pricing. A "sale" is ONE product, ONE item, unpaid; there is no cart.
//
// Phases:
//   editing     the draft is being built; nothing frozen
//   confirming  the request is frozen (product, configuration, customer, idempotency key) and shown
//   submitting  the create call is in flight
//   success     the server created the order (or returned the original for the same key)
//   rejected    the server refused this request (validation etc). Nothing was created: edit and retry
//   unknown     the result is UNKNOWN (network, timeout, 5xx, unreadable answer). The order may exist
//   conflict    the key was already used for a DIFFERENT request. Never auto-retried
//   signed-out  the session was missing/expired. Nothing was created; sign in, then retry
//   denied      the server refused access. Nothing was created
//
// IDEMPOTENCY: one key per sale attempt. It is generated when the request is frozen for confirmation and
// is bound to that exact request. Clicking Create again, retrying after an unknown result, or retrying
// after signing back in all send the SAME key and the SAME frozen request, so the server returns the one
// order. A different request (different product, configuration or customer) freezes with a NEW key, but
// only from a state where the previous request is known not to have created an order (editing after a
// confirmation or a rejection). After an unknown result the request is locked - no edit, no new key -
// because a fresh key there could create a second order. Only Start new sale leaves that state, and the
// staff member is told the first order may exist. The key is never shown.

import { buildCounterPreview, COUNTER_WALK_IN_LABEL } from './counterDraft.js'
import { isCounterSubmissionEnabled } from './counterSubmissionReadiness.js'

export const SALE_PHASES = Object.freeze({
  EDITING: 'editing',
  CONFIRMING: 'confirming',
  SUBMITTING: 'submitting',
  SUCCESS: 'success',
  REJECTED: 'rejected',
  UNKNOWN: 'unknown',
  CONFLICT: 'conflict',
  SIGNED_OUT: 'signed-out',
  DENIED: 'denied'
})

export const EMPTY_COUNTER_CUSTOMER = Object.freeze({ name: '', email: '', phone: '' })

export const COUNTER_UNKNOWN_RESULT_MESSAGE =
  'We could not confirm whether the order was created. Retrying is safe: it sends the same request, so it cannot create a second order.'

export function initialSale() {
  return { phase: SALE_PHASES.EDITING, attempt: null, result: null, error: null }
}

export function startNewSale() {
  return initialSale()
}

// One key per sale attempt: the same UUID source the storefront basket uses.
export function createSaleAttemptKey() {
  return globalThis.crypto?.randomUUID?.() || `qsc-counter-${Date.now()}-${Math.random().toString(36).slice(2)}`
}

// ── customer (optional) ──────────────────────────────────────────────────

// Basic UX validation only; the server decides. Blank means nothing: the value is null and the server
// records Walk-in. This function does not invent the Walk-in name.
export function validateCounterCustomer(customer) {
  const name = String(customer?.name ?? '').trim()
  const email = String(customer?.email ?? '').trim()
  const phone = String(customer?.phone ?? '').trim()
  const errors = {}
  if (name && (name.length < 2 || name.length > 160)) errors.name = 'Enter at least 2 characters, or leave the name blank for Walk-in.'
  if (email && !/^[^\s@]+@[^\s@]+$/.test(email)) errors.email = 'Enter a valid email address, or leave it blank.'
  if (phone && phone.replace(/[^0-9+]/g, '').length < 7) errors.phone = 'Enter a valid phone number, or leave it blank.'
  return {
    ok: Object.keys(errors).length === 0,
    errors,
    value: { name: name || null, email: email || null, phone: phone || null }
  }
}

// ── freezing the request ─────────────────────────────────────────────────

const sameRequest = (a, b) => JSON.stringify([a.productKey, a.configuration, a.customerName, a.customerEmail, a.customerPhone]) ===
  JSON.stringify([b.productKey, b.configuration, b.customerName, b.customerEmail, b.customerPhone])

// Editing -> confirming. Freezes the configuration ALREADY built by the draft (for the A4 print that is
// the counter print adapter's output, unchanged) together with the customer, and attaches the sale
// attempt's key: the previous key when the frozen request is identical, a new one otherwise. Returns the
// sale unchanged if the product is not write-enabled, the configuration is invalid, or the customer is.
export function reviewSale(sale, { entry, draft, customer }, makeKey = createSaleAttemptKey) {
  if (sale.phase !== SALE_PHASES.EDITING) return sale
  if (!isCounterSubmissionEnabled(entry)) return sale
  const preview = buildCounterPreview(entry, draft)
  const checked = validateCounterCustomer(customer)
  if (!preview.valid || !checked.ok) return sale

  const request = {
    productKey: entry.product.id,
    configuration: JSON.parse(JSON.stringify(preview.configuration)),
    customerName: checked.value.name,
    customerEmail: checked.value.email,
    customerPhone: checked.value.phone
  }
  const keep = sale.attempt && sameRequest(sale.attempt.request, request)
  return {
    phase: SALE_PHASES.CONFIRMING,
    attempt: {
      request: { idempotencyKey: keep ? sale.attempt.request.idempotencyKey : makeKey(), ...request },
      summary: {
        productName: preview.productName,
        rows: preview.rows,
        unitSummary: preview.unitSummary,
        estimateTotal: preview.estimate ? preview.estimate.total : null,
        customerLabel: checked.value.name || COUNTER_WALK_IN_LABEL
      },
      submissions: 0
    },
    result: null,
    error: null
  }
}

// Confirmation / rejection -> editing. Not available once the result may be unknown, in flight, done, or
// refused for access, so a request that may have created an order can never be edited under a new key.
export function backToEdit(sale) {
  if (sale.phase !== SALE_PHASES.CONFIRMING && sale.phase !== SALE_PHASES.REJECTED) return sale
  return { ...sale, phase: SALE_PHASES.EDITING, error: null }
}

// ── submission ───────────────────────────────────────────────────────────

// Confirming, unknown or signed-out (after signing back in) -> submitting. Anything else, including a
// sale that is already submitting, is returned unchanged, so a second click cannot start a second call.
export function beginSubmit(sale) {
  const allowed = [SALE_PHASES.CONFIRMING, SALE_PHASES.UNKNOWN, SALE_PHASES.SIGNED_OUT]
  if (!allowed.includes(sale.phase) || !sale.attempt) return sale
  return {
    ...sale,
    phase: SALE_PHASES.SUBMITTING,
    error: null,
    attempt: { ...sale.attempt, submissions: sale.attempt.submissions + 1 }
  }
}

// Reads the failure. The server's own wording is kept for anything the server refused; a failure with no
// server answer (network, timeout, 5xx) is UNKNOWN, never a rejection.
export function classifyCounterSubmitError(error) {
  const message = typeof error?.message === 'string' ? error.message : ''
  const status = Number(error?.status)
  const code = String(error?.payload?.code || '')
  if (/sign-in is required|refresh/i.test(message) || status === 401) {
    return { kind: SALE_PHASES.SIGNED_OUT, message: 'Your staff session has ended. Sign in again to continue with this sale.' }
  }
  if (status === 409 || code === '23505' || /idempotency key was already used/i.test(message)) {
    return { kind: SALE_PHASES.CONFLICT, message: message || 'This sale attempt conflicts with an earlier one.' }
  }
  if (status === 403 || code === '42501' || /do not have access/i.test(message)) {
    return { kind: SALE_PHASES.DENIED, message: message || 'You do not have access to the Quick Solution counter.' }
  }
  if (Number.isFinite(status) && status >= 400 && status < 500) {
    return { kind: SALE_PHASES.REJECTED, message: message || 'The server rejected this order.' }
  }
  return { kind: SALE_PHASES.UNKNOWN, message: COUNTER_UNKNOWN_RESULT_MESSAGE }
}

function readCreatedOrder(response) {
  if (!response || typeof response !== 'object' || response.ok !== true) return null
  if (typeof response.orderNumber !== 'string' || !response.orderNumber) return null
  const total = Number(response.totalAmount)
  if (!Number.isFinite(total)) return null
  return {
    orderNumber: response.orderNumber,
    status: response.status ?? null,
    paymentStatus: response.paymentStatus ?? null,
    productName: response.productName ?? null,
    customerName: response.customerName ?? null,
    customerEmail: response.customerEmail ?? null,
    customerPhone: response.customerPhone ?? null,
    totalAmount: total,
    replayed: response.replayed === true
  }
}

// A request that never answers must not leave the screen 'submitting' for ever. After this long the
// result is UNKNOWN (the request may still complete on the server), and a retry is safe: same key.
export const COUNTER_SUBMIT_TIMEOUT_MS = 30000

function withTimeout(promise, ms) {
  let timer
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error('The order request timed out.')), ms)
  })
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer))
}

// Calls `create` exactly once with the frozen request and returns the next sale. Never throws. The
// payload is only what the counter is allowed to send: the key, product key, configuration and optional
// customer. Tenant, channel, actor, price, total and payment are the server's.
export async function submitSale(sale, create, timeoutMs = COUNTER_SUBMIT_TIMEOUT_MS) {
  if (sale.phase !== SALE_PHASES.SUBMITTING || !sale.attempt) return sale
  const { idempotencyKey, productKey, configuration, customerName, customerEmail, customerPhone } = sale.attempt.request
  let response
  try {
    response = await withTimeout(Promise.resolve().then(() => create({ idempotencyKey, productKey, configuration, customerName, customerEmail, customerPhone })), timeoutMs)
  } catch (error) {
    const failure = classifyCounterSubmitError(error)
    return { ...sale, phase: failure.kind, error: failure.message, result: null }
  }
  const order = readCreatedOrder(response)
  if (!order) return { ...sale, phase: SALE_PHASES.UNKNOWN, error: COUNTER_UNKNOWN_RESULT_MESSAGE, result: null }
  return { ...sale, phase: SALE_PHASES.SUCCESS, error: null, result: order }
}

// After signing back in during a sale: back to the same confirmation, same request, same key.
export function resumeAfterSignIn(sale) {
  if (sale.phase !== SALE_PHASES.SIGNED_OUT || !sale.attempt) return sale
  return { ...sale, phase: SALE_PHASES.CONFIRMING, error: null }
}

// The phases in which the product list and the form must not change what is being sold.
export function isSaleLocked(sale) {
  return ![SALE_PHASES.EDITING, SALE_PHASES.CONFIRMING, SALE_PHASES.REJECTED].includes(sale.phase)
}
