// CAFE-GUEST-01S - Today's cash-up, the pure read-only side.
//
// The SERVER is the only source (get_quick_solution_counter_cashup_today): the Cafe tenant, the counter channel, the
// Africa/Johannesburg business day, which payments count and every total are decided there, and the totals are made from the
// very rows returned. Nothing here recalculates money, writes, remembers anything, or offers an action on it. There is no till
// to close, no float, no counted cash: it is a reconciliation view. Money is formatted by the one Rand formatter.

import { classifyCounterError } from './counterDraft.js'
import { describeCounterOrder, formatCounterOrderTime } from './counterOrders.js'
import { counterReceiptMethodLabel, formatCounterReceiptDate } from './counterReceipt.js'
import { formatMoney } from './pricing.js'

const CENT = 0.005

// ── business dates (calendar days of the Cafe; never instants, never a zone) ────────────────────────────
// A business date is a plain 'YYYY-MM-DD'. The server owns what a Cafe day is (Africa/Johannesburg, [local midnight, next local midnight));
// this only walks the calendar, so it uses UTC date arithmetic with no clock and no zone.
export function isBusinessDate(value) {
  if (typeof value !== 'string' || !/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(value)) return false
  const date = new Date(`${value}T00:00:00Z`)
  return !Number.isNaN(date.getTime()) && date.toISOString().slice(0, 10) === value
}

export function addBusinessDays(value, days) {
  if (!isBusinessDate(value)) return null
  const date = new Date(`${value}T00:00:00Z`)
  date.setUTCDate(date.getUTCDate() + days)
  return date.toISOString().slice(0, 10)
}

// "Fri, 25 Sept 2026": the day as a calendar day, the same wherever the browser is.
export function formatBusinessDate(value) {
  if (!isBusinessDate(value)) return ''
  return new Intl.DateTimeFormat('en-ZA', { weekday: 'short', day: '2-digit', month: 'short', year: 'numeric', timeZone: 'UTC' }).format(new Date(`${value}T12:00:00Z`))
}
const num = (value) => (Number.isFinite(Number(value)) ? Number(value) : 0)
const bucket = (value) => ({ count: num(value?.count), amount: num(value?.amount) })

// Runs the injected loader (the API wrapper) and returns the screen state. Never throws. 'empty' means a day with no orders,
// no payments and nothing unpaid; a day with only unpaid orders is a normal 'ready' day with zero takings.
export async function loadCounterCashupState(load) {
  let response
  try {
    response = await load()
  } catch (error) {
    // the server refuses a day that has not happened; that is its own state, not a failure
    if (/cannot be in the future/i.test(String(error?.message || ''))) return { status: 'future', message: String(error.message) }
    return classifyCounterError(error)
  }
  if (!response || typeof response !== 'object' || !response.takings || !Array.isArray(response.payments) || !response.unpaid || !Array.isArray(response.unpaid.orders)) {
    return { status: 'error', message: 'The counter returned an unexpected response.' }
  }
  const idle = num(response.orders?.createdToday) === 0 && response.payments.length === 0 && response.unpaid.orders.length === 0 && num(response.otherMethods?.count) === 0
  return { status: idle ? 'empty' : 'ready', summary: response }
}

// Display fields. `entries` (the counter catalogue) only labels configurations on the unpaid rows.
export function describeCounterCashup(summary, entries = []) {
  const cash = bucket(summary?.takings?.cash)
  const card = bucket(summary?.takings?.card)
  const total = bucket(summary?.takings?.total)
  const rows = (Array.isArray(summary?.payments) ? summary.payments : []).map((payment) => ({
    paymentId: payment?.paymentId ?? null,
    orderId: payment?.orderId ?? null,
    orderNumber: payment?.orderNumber || '—',
    customer: payment?.customerName || 'Walk-in',
    method: payment?.method ?? null,
    methodLabel: counterReceiptMethodLabel(payment?.method),
    amount: formatMoney(num(payment?.amount)),
    time: formatCounterOrderTime(payment?.paidAt),
    orderTotal: formatMoney(num(payment?.orderTotal)),
    // set when the order was made on an earlier day than it was paid: the money still belongs to today
    orderedEarlier: formatCounterReceiptDate(payment?.orderCreatedAt) !== formatCounterReceiptDate(payment?.paidAt),
    orderedOn: formatCounterReceiptDate(payment?.orderCreatedAt)
  }))
  const unpaidOrders = (Array.isArray(summary?.unpaid?.orders) ? summary.unpaid.orders : []).map((order) => ({
    ...describeCounterOrder(order, entries),
    outstanding: formatMoney(num(order?.outstanding))
  }))
  // A guard, not a calculation: the server makes the totals from these rows, so they must agree. If they ever do not, say so.
  const rowSum = (Array.isArray(summary?.payments) ? summary.payments : []).reduce((sum, payment) => sum + num(payment?.amount), 0)
  const consistent = Math.abs(rowSum - total.amount) < CENT && Math.abs(cash.amount + card.amount - total.amount) < CENT && (Array.isArray(summary?.payments) ? summary.payments.length : 0) === total.count
  return {
    businessDate: typeof summary?.businessDate === 'string' ? summary.businessDate : null,
    cash: { count: cash.count, amount: formatMoney(cash.amount) },
    card: { count: card.count, amount: formatMoney(card.amount) },
    total: { count: total.count, amount: formatMoney(total.amount) },
    ordersToday: num(summary?.orders?.createdToday),
    paidOrders: num(summary?.orders?.paidToday),
    unpaid: { count: num(summary?.unpaid?.count), amount: formatMoney(num(summary?.unpaid?.amount)), orders: unpaidOrders },
    other: { count: num(summary?.otherMethods?.count), amount: formatMoney(num(summary?.otherMethods?.amount)) },
    payments: rows,
    consistent
  }
}
