// CAFE-GUEST-01T - unpaid counter orders across days, the pure read-only side.
//
// The SERVER is the only source (list_quick_solution_unpaid_counter_orders): which orders still owe money (by the completed
// ledger, not just a status string), their age in Cafe business days (Africa/Johannesburg) and the oldest-first order are all
// decided there. Nothing here recalculates, re-sorts, filters, remembers or writes; an order leaves this list only when the server
// stops returning it (after it is paid through the existing order detail). Money is formatted by the one Rand formatter.

import { classifyCounterError } from './counterDraft.js'
import { counterStatusLabel, describeCounterOrder, formatCounterOrderTime } from './counterOrders.js'
import { formatCounterReceiptDate } from './counterReceipt.js'
import { formatMoney } from './pricing.js'

const num = (value) => (Number.isFinite(Number(value)) ? Number(value) : 0)

// "Today", "1 day old", "3 days old": plain, not alarming. The age is the server's business-day difference.
export function counterAgeLabel(ageDays) {
  const days = Math.max(0, Math.trunc(num(ageDays)))
  if (days === 0) return 'Today'
  return days === 1 ? '1 day old' : `${days} days old`
}

// Runs the injected loader (the API wrapper) and returns the screen state. Never throws.
export async function loadCounterUnpaidState(load) {
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

// Display fields. `entries` (the counter catalogue) only labels configurations.
export function describeCounterUnpaid(summary, entries = []) {
  const orders = (Array.isArray(summary?.orders) ? summary.orders : []).map((order) => {
    const base = describeCounterOrder(order, entries)
    const paid = num(order?.amountPaid)
    return {
      orderId: base.orderId,
      orderNumber: base.orderNumber,
      ageDays: num(order?.ageDays),
      ageLabel: counterAgeLabel(order?.ageDays),
      createdDate: formatCounterReceiptDate(order?.createdAt),
      createdTime: formatCounterOrderTime(order?.createdAt),
      customer: base.customer,
      contact: base.contact,
      items: base.items,
      total: formatMoney(num(order?.totalAmount)),
      // only when something was already received against it: the remainder is what is outstanding
      amountPaid: paid > 0 ? formatMoney(paid) : null,
      outstanding: formatMoney(num(order?.outstanding)),
      statusLabel: counterStatusLabel(order?.status)
    }
  })
  return {
    count: num(summary?.count),
    outstandingTotal: formatMoney(num(summary?.outstandingTotal)),
    orders
  }
}
