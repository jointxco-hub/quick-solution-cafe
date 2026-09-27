// CAFE-GUEST-01O - which counter products the FIRST writable Counter UI may create an order for.
//
//   server counter-sellable  !=  currently supported by the first Counter UI write workflow
//
// The server's counter catalogue says which products staff may SEE and start (channels.pos, lifecycle).
// This module says something narrower and different: for which of those products this UI has a proven
// no-file counter contract, so that a "Create unpaid order" action may be offered. It is a deliberate
// rollout boundary, not a security rule: it provides NO authorization, and the create RPC re-checks
// everything (access, module, product eligibility, pricing) on every call regardless of what is decided
// here. Adding a product to the list is a product decision that follows an audit of its counter
// configuration and artwork contract - it is never inferred from resolveCounterAction() returning 'order'.
//
// Everything else stays visible and previewable; only the write action is withheld.

import { COUNTER_ACTIONS, resolveCounterAction } from './counterCatalogue.js'

// The four flows already proven end to end through the create RPC (CAFE-GUEST-01M):
// Scan, A4 Lamination, A3 Lamination (one { units } each) and the physical A4 print.
export const COUNTER_FIRST_WRITE_PRODUCT_KEYS = Object.freeze(['scan', 'a4-lamination', 'a3-lamination', 'a4-print'])

export const COUNTER_SUBMISSION = Object.freeze({
  WRITABLE: 'writable',
  NOT_READY: 'not-ready',
  REQUEST: 'request'
})

export const COUNTER_NOT_READY_MESSAGE = 'Counter ordering for this product is not ready yet.'

// { status, message } for one resolved counter entry ({ product, action }). A request product is never
// writable here, whatever its key. Anything not in the list above is 'not-ready'.
export function resolveCounterSubmission(entry) {
  const key = entry?.product?.id
  if (!entry?.product) return { status: COUNTER_SUBMISSION.NOT_READY, message: COUNTER_NOT_READY_MESSAGE }
  const action = entry.action || resolveCounterAction(entry.product)
  if (action === COUNTER_ACTIONS.REQUEST) return { status: COUNTER_SUBMISSION.REQUEST, message: '' }
  if (typeof key === 'string' && COUNTER_FIRST_WRITE_PRODUCT_KEYS.includes(key)) {
    return { status: COUNTER_SUBMISSION.WRITABLE, message: '' }
  }
  return { status: COUNTER_SUBMISSION.NOT_READY, message: COUNTER_NOT_READY_MESSAGE }
}

export function isCounterSubmissionEnabled(entry) {
  return resolveCounterSubmission(entry).status === COUNTER_SUBMISSION.WRITABLE
}
