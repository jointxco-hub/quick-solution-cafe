// CAFE-GUEST-01P - Today's Counter Orders, the pure read-only side.
//
// The SERVER is the only source of this list (list_quick_solution_counter_orders_today: the Cafe tenant, the
// counter channel and the Africa/Johannesburg business day are all decided there). Nothing here remembers,
// stores or infers an order on the client, reads localStorage, or reconciles a list against an uncertain
// submission. It only turns the server's answer into a screen state and into display fields.

import { classifyCounterError, describeCounterConfiguration } from './counterDraft.js'
import { formatMoney } from './pricing.js'

// The Cafe business zone the server uses for "today"; only used here to show a time of day.
export const COUNTER_ORDERS_TIMEZONE = 'Africa/Johannesburg'

const STATUS_LABELS = { submitted: 'Submitted', accepted: 'Accepted', in_production: 'In production', ready: 'Ready', completed: 'Completed', cancelled: 'Cancelled', draft: 'Draft' }
const PAYMENT_LABELS = { unpaid: 'Unpaid' }
const capitalise = (value) => (typeof value === 'string' && value ? value.charAt(0).toUpperCase() + value.slice(1) : '—')
export const counterStatusLabel = (status) => STATUS_LABELS[status] || capitalise(status)
export const counterPaymentLabel = (paymentStatus) => PAYMENT_LABELS[paymentStatus] || capitalise(paymentStatus)

// Runs the injected loader (the API wrapper) and returns the screen state. Never throws. Errors keep the
// same meaning as for the catalogue (sign-in, denied, unavailable, other).
export async function loadCounterOrdersState(load) {
  let response
  try {
    response = await load()
  } catch (error) {
    return classifyCounterError(error)
  }
  if (!response || !Array.isArray(response.orders)) {
    return { status: 'error', message: 'The counter returned an unexpected response.' }
  }
  const businessDate = typeof response.businessDate === 'string' ? response.businessDate : null
  if (response.orders.length === 0) return { status: 'empty', businessDate, orders: [] }
  return { status: 'ready', businessDate, orders: response.orders }
}

// "14:05" in the Cafe's own zone, from the server's timestamp.
export function formatCounterOrderTime(iso) {
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) return '—'
  return new Intl.DateTimeFormat('en-ZA', { hour: '2-digit', minute: '2-digit', hour12: false, timeZone: COUNTER_ORDERS_TIMEZONE }).format(date)
}

// Display fields for one order row. `entries` (the counter catalogue) only supplies field labels so a
// configuration can be shown as "7 pages"; an item whose product is not in it just shows its name.
export function describeCounterOrder(order, entries = []) {
  const items = (Array.isArray(order?.items) ? order.items : []).map((item) => {
    const entry = entries.find((candidate) => candidate.product.id === item?.productKey)
    let detail = null
    try {
      detail = entry ? describeCounterConfiguration(entry.product, item.configuration) : null
    } catch {
      detail = null
    }
    return { name: item?.productName || item?.productKey || 'Item', detail }
  })
  const total = Number(order?.totalAmount)
  return {
    orderId: order?.orderId ?? null,
    orderNumber: order?.orderNumber || '—',
    time: formatCounterOrderTime(order?.createdAt),
    customer: order?.customerName || 'Walk-in',
    contact: [order?.customerPhone, order?.customerEmail].filter(Boolean).join(' · '),
    items,
    total: Number.isFinite(total) ? formatMoney(total) : '—',
    paymentStatus: order?.paymentStatus ?? null,
    paymentLabel: counterPaymentLabel(order?.paymentStatus),
    statusLabel: counterStatusLabel(order?.status)
  }
}
