// CAFE-GUEST-01W - the audited cancelled counter orders, the pure read-only side.
//
// The SERVER is the only source (list_quick_solution_cancelled_counter_orders): which orders were cancelled through the audited
// cancel, who did it, when and why, the newest-first order and the 100-row page are all decided there, and only an admin or owner is
// answered at all. Nothing here recalculates, re-sorts, filters, remembers or writes. A staff member who is not allowed simply gets a
// "denied" state, which the screen uses to keep the tab out of sight. Money is formatted by the one Rand formatter.

import { classifyCounterError } from './counterDraft.js'
import { describeCounterOrder, formatCounterOrderTime } from './counterOrders.js'
import { formatCounterReceiptDate } from './counterReceipt.js'
import { formatMoney } from './pricing.js'

const num = (value) => (Number.isFinite(Number(value)) ? Number(value) : 0)

// Runs the injected loader (the API wrapper) and returns the screen state. Never throws.
export async function loadCounterCancelledState(load) {
  let response
  try {
    response = await load()
  } catch (error) {
    return classifyCounterError(error)
  }
  if (!response || typeof response !== 'object' || !Array.isArray(response.orders)) {
    return { status: 'error', message: 'The counter returned an unexpected response.' }
  }
  return { status: response.orders.length === 0 ? 'empty' : 'ready', summary: response }
}

// The tab is shown only once the server has said this staff member may see the list (an empty list counts: an admin with nothing cancelled).
export const isCancelledListAvailable = (state) => state?.status === 'ready' || state?.status === 'empty'

const PRIOR_PAYMENT = Object.freeze({ unpaid: 'Was unpaid', failed: 'Payment had failed' })

// Display fields. `entries` (the counter catalogue) only labels configurations.
export function describeCounterCancelled(summary, entries = []) {
  const orders = (Array.isArray(summary?.orders) ? summary.orders : []).map((order) => {
    const base = describeCounterOrder(order, entries)
    return {
      orderId: base.orderId,
      orderNumber: base.orderNumber,
      cancelledDate: formatCounterReceiptDate(order?.cancelledAt),
      cancelledTime: formatCounterOrderTime(order?.cancelledAt),
      cancelledBy: typeof order?.cancelledBy === 'string' && order.cancelledBy.trim() ? order.cancelledBy.trim() : null,
      reason: typeof order?.reason === 'string' ? order.reason : '',
      customer: base.customer,
      contact: base.contact,
      items: base.items,
      total: formatMoney(num(order?.totalAmount)),
      wasLabel: PRIOR_PAYMENT[order?.priorPaymentStatus] || 'Was not paid',
      orderedDate: formatCounterReceiptDate(order?.createdAt)
    }
  })
  const count = num(summary?.count)
  const shown = num(summary?.shown)
  return {
    count,
    shown,
    // the server caps the page; say so instead of implying the list is complete
    truncated: count > shown,
    orders
  }
}
