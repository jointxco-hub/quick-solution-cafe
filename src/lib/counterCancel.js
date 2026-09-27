// CAFE-GUEST-01V - the pure side of cancelling ONE unpaid counter order (admin / owner only).
//
// The SERVER is the only authority. It decides who may cancel (admin and owner accounts only, decided by the server), whether this order can be cancelled (never paid,
// nothing pending, not sent to production, not already cancelled) and it writes the status and the audit row (who, when, why) together.
// This screen only offers the action when the server's check says BOTH "you may" and "it can be cancelled", asks for a reason and a
// confirmation, and then shows what the server answered. Nothing here decides permission, edits a status or names a capability.
//
// One attempt per order: the reason is frozen when the staff member confirms. Confirm clicked twice cannot start a second call; a retry
// after an unknown result sends the SAME reason (the server returns the original cancellation for the same admin and reason, and
// writes nothing new). A refused attempt is finished; a new one starts with a fresh confirmation.

import { classifyCounterError } from './counterDraft.js'
import { classifyCounterSubmitError } from './counterSale.js'

export const COUNTER_CANCEL_REASON_MIN = 3
export const COUNTER_CANCEL_REASON_MAX = 300

export const CANCEL_PHASES = Object.freeze({
  IDLE: 'idle',
  CONFIRMING: 'confirming',
  SUBMITTING: 'submitting',
  SUCCESS: 'success',
  REJECTED: 'rejected',
  UNKNOWN: 'unknown',
  SIGNED_OUT: 'signed-out',
  DENIED: 'denied'
})

export const COUNTER_CANCEL_UNKNOWN_MESSAGE = 'The cancellation may already have been recorded. Retry safely to confirm the result.'

// Plain words for why an order cannot be cancelled (the server's `block` code). Anything unknown gets the general sentence.
const BLOCK_WORDS = Object.freeze({
  already_cancelled: 'This order is already cancelled.',
  has_payment: 'This order has a payment, so it cannot be cancelled.',
  payment_in_progress: 'A payment for this order is still in progress, so it cannot be cancelled.',
  sent_to_production: 'This order has already been sent to production and cannot be cancelled here.',
  in_progress: 'This order is already being worked on and cannot be cancelled here.',
  nothing_outstanding: 'This order has nothing outstanding to cancel.',
  not_cancellable: 'This order cannot be cancelled.',
  not_payable_state: 'This order cannot be cancelled.'
})

export const describeCancelBlock = (block) => (block ? BLOCK_WORDS[block] || 'This order cannot be cancelled.' : null)

// ── the server's check (whether to offer the action at all) ──────────────

// Never throws. Any failure simply means "do not offer it": the server still enforces everything on the real call.
export async function loadCounterCancelCheckState(load, orderId) {
  let response
  try {
    response = await load(orderId)
  } catch (error) {
    return { status: 'unavailable', message: classifyCounterError(error).message }
  }
  if (!response || typeof response !== 'object' || typeof response.permitted !== 'boolean' || typeof response.cancellable !== 'boolean') {
    return { status: 'unavailable', message: 'The counter returned an unexpected response.' }
  }
  return {
    status: 'ready',
    orderId,
    permitted: response.permitted,
    cancellable: response.cancellable,
    block: typeof response.block === 'string' ? response.block : null
  }
}

// What the detail screen shows for this order: the action, a plain reason it is unavailable, or nothing (a plain member sees nothing).
export function describeCancelOffer(check, order) {
  if (!check || check.status !== 'ready' || !check.permitted) return { offer: false, note: null }
  if (!order || order.status === 'cancelled' || order.paymentStatus === 'paid') return { offer: false, note: null }
  if (check.cancellable) return { offer: true, note: null }
  return { offer: false, note: describeCancelBlock(check.block) }
}

// ── the reason ───────────────────────────────────────────────────────────

export function checkCancelReason(text) {
  const reason = String(text ?? '').trim()
  // eslint-disable-next-line no-control-regex
  if (/[\u0000-\u001f\u007f-\u009f]/.test(reason)) return { ok: false, reason, message: 'The reason cannot contain line breaks or special characters.' }
  if (reason.length < COUNTER_CANCEL_REASON_MIN) return { ok: false, reason, message: 'Say why the order is being cancelled (at least 3 characters).' }
  if (reason.length > COUNTER_CANCEL_REASON_MAX) return { ok: false, reason, message: `Keep the reason to ${COUNTER_CANCEL_REASON_MAX} characters or fewer.` }
  return { ok: true, reason, message: null }
}

// ── the cancel attempt ───────────────────────────────────────────────────

export function initialCancel() {
  return { phase: CANCEL_PHASES.IDLE, reason: '', attempt: null, result: null, error: null }
}

// Idle -> confirming, only when the server's check says this caller may cancel this order and it can be cancelled.
export function beginCancel(cancel, check, order) {
  if (cancel.phase !== CANCEL_PHASES.IDLE) return cancel
  if (!describeCancelOffer(check, order).offer || !order?.orderId) return cancel
  return { phase: CANCEL_PHASES.CONFIRMING, reason: '', attempt: { orderId: order.orderId, orderNumber: order.orderNumber ?? null, reason: null, submissions: 0 }, result: null, error: null }
}

export function setCancelReason(cancel, text) {
  if (cancel.phase !== CANCEL_PHASES.CONFIRMING) return cancel
  return { ...cancel, reason: String(text ?? ''), error: null }
}

// Confirming -> idle (nothing was sent). Not possible once a request may exist.
export function abortCancel(cancel) {
  if (cancel.phase !== CANCEL_PHASES.CONFIRMING) return cancel
  return initialCancel()
}

// A finished attempt (refused, denied, done) starts over.
export function resetCancel(cancel) {
  if (![CANCEL_PHASES.REJECTED, CANCEL_PHASES.DENIED, CANCEL_PHASES.SUCCESS].includes(cancel.phase)) return cancel
  return initialCancel()
}

// Confirming (with a valid reason), unknown or signed-out -> submitting. Anything else, including an attempt that is already
// submitting, is returned unchanged, so a second click cannot start a second call. A bad reason stays on the confirmation with a message.
export function beginCancelSubmit(cancel) {
  if (![CANCEL_PHASES.CONFIRMING, CANCEL_PHASES.UNKNOWN, CANCEL_PHASES.SIGNED_OUT].includes(cancel.phase) || !cancel.attempt) return cancel
  let reason = cancel.attempt.reason
  if (cancel.phase === CANCEL_PHASES.CONFIRMING) {
    const checked = checkCancelReason(cancel.reason)
    if (!checked.ok) return { ...cancel, error: checked.message }
    reason = checked.reason
  }
  return { ...cancel, phase: CANCEL_PHASES.SUBMITTING, error: null, attempt: { ...cancel.attempt, reason, submissions: cancel.attempt.submissions + 1 } }
}

export const COUNTER_CANCEL_TIMEOUT_MS = 30000

function withTimeout(promise, ms) {
  let timer
  const timeout = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('The cancellation request timed out.')), ms) })
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer))
}

// Calls `cancelOrder` exactly once with the frozen attempt and returns the next state. Never throws. The payload is only the order and
// the reason: no status, tenant, actor or time.
export async function submitCancel(cancel, cancelOrder, timeoutMs = COUNTER_CANCEL_TIMEOUT_MS) {
  if (cancel.phase !== CANCEL_PHASES.SUBMITTING || !cancel.attempt) return cancel
  const { orderId, reason } = cancel.attempt
  let response
  try {
    response = await withTimeout(Promise.resolve().then(() => cancelOrder({ orderId, reason })), timeoutMs)
  } catch (error) {
    const failure = classifyCounterSubmitError(error)
    if (failure.kind === 'unknown') return { ...cancel, phase: CANCEL_PHASES.UNKNOWN, error: COUNTER_CANCEL_UNKNOWN_MESSAGE, result: null }
    if (failure.kind === 'signed-out') return { ...cancel, phase: CANCEL_PHASES.SIGNED_OUT, error: 'Your staff session has ended. Sign in again to finish cancelling this order.', result: null }
    if (failure.kind === 'denied') return { ...cancel, phase: CANCEL_PHASES.DENIED, error: failure.message, result: null }
    return { ...cancel, phase: CANCEL_PHASES.REJECTED, error: failure.message, result: null }
  }
  if (!response || response.ok !== true || response.status !== 'cancelled') {
    return { ...cancel, phase: CANCEL_PHASES.UNKNOWN, error: COUNTER_CANCEL_UNKNOWN_MESSAGE, result: null }
  }
  return {
    ...cancel,
    phase: CANCEL_PHASES.SUCCESS,
    error: null,
    result: { orderNumber: response.orderNumber ?? cancel.attempt.orderNumber, reason: response.reason ?? reason, replayed: response.replayed === true }
  }
}

export function resumeCancelAfterSignIn(cancel) {
  if (cancel.phase !== CANCEL_PHASES.SIGNED_OUT || !cancel.attempt) return cancel
  return { ...cancel, phase: CANCEL_PHASES.CONFIRMING, error: null }
}

// While a request may exist or its result is unknown, the attempt cannot be changed or dropped.
export const isCancelLocked = (cancel) => [CANCEL_PHASES.SUBMITTING, CANCEL_PHASES.UNKNOWN].includes(cancel.phase)
