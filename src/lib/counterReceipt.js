// CAFE-GUEST-01R - the paid counter receipt, a PURE read-only view of the server's order detail.
//
// Nothing here writes, calls the API or decides that an order is paid. It is handed the detail that
// get_quick_solution_counter_order returned and either refuses ("not receiptable") or turns it into the
// receipt data the screen and the printer show. A receipt exists only for an order the SERVER reports as fully
// paid: paymentStatus 'paid', nothing outstanding, and completed payment rows that add up to what was paid.
//
// The sale reference is the existing order number: there is no separate receipt-number convention in this repo, and
// none is invented here. There is no VAT or tax registration in the business details either, so no tax lines are
// printed and the document is titled "Payment receipt" only.
//
// Money is formatted by the one Rand formatter (pricing.js formatMoney); dates and times are in the Café's own zone.

import { BUSINESS_ADDRESS_LINES, BUSINESS_CAFE_NAME, WHATSAPP_DISPLAY } from './businessInfo.js'
import { describeCounterConfiguration } from './counterDraft.js'
import { COUNTER_ORDERS_TIMEZONE, formatCounterOrderTime } from './counterOrders.js'
import { formatMoney } from './pricing.js'

// The wording of a payment method as recorded by the server. Cash and Card are the counter methods; a gateway
// payment from the storefront can appear on the same order's ledger, so it is named without pretending otherwise.
const METHOD_LABELS = Object.freeze({ cash: 'Cash', card: 'Card', payfast: 'PayFast (online)' })
export const counterReceiptMethodLabel = (method) => METHOD_LABELS[method] || (typeof method === 'string' && method ? method.charAt(0).toUpperCase() + method.slice(1) : 'Payment')

const CENT = 0.005

const isNumber = (value) => value !== null && value !== undefined && value !== '' && Number.isFinite(Number(value))

// "26 Sep 2026" in the Café's zone.
export function formatCounterReceiptDate(iso) {
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) return '—'
  return new Intl.DateTimeFormat('en-ZA', { day: '2-digit', month: 'short', year: 'numeric', timeZone: COUNTER_ORDERS_TIMEZONE }).format(date)
}

// Why an order has no paid receipt, or null when it has one. The server's detail is the only input.
export function counterReceiptBlock(order) {
  if (!order || typeof order !== 'object') return 'no_order'
  if (order.paymentStatus !== 'paid') return 'not_paid'
  if (!isNumber(order.totalAmount) || !isNumber(order.amountPaid) || !isNumber(order.outstanding)) return 'incomplete'
  if (Number(order.outstanding) > CENT) return 'outstanding'
  if (Number(order.amountPaid) + CENT < Number(order.totalAmount)) return 'not_fully_paid'
  const payments = Array.isArray(order.payments) ? order.payments : []
  if (payments.length === 0 || payments.some((payment) => !isNumber(payment?.amount) || Number(payment.amount) <= 0)) return 'no_payment'
  const recorded = payments.reduce((sum, payment) => sum + Number(payment.amount), 0)
  if (Math.abs(recorded - Number(order.amountPaid)) > CENT) return 'payments_inconsistent'
  return null
}

export const isCounterReceiptAvailable = (order) => counterReceiptBlock(order) === null

// A short unit line for an item whose product is not in the counter catalogue any more: only what the recorded
// configuration itself says, never a guess.
function fallbackDetail(item) {
  const config = item?.configuration
  if (!config || typeof config !== 'object') return null
  if (Number.isInteger(config.pages) && Number.isInteger(config.copies)) return `${config.pages} page${config.pages === 1 ? '' : 's'} × ${config.copies} cop${config.copies === 1 ? 'y' : 'ies'}`
  if (Number.isInteger(config.units)) return `${config.units} unit${config.units === 1 ? '' : 's'}`
  return null
}

// The receipt, or null. `entries` (the counter catalogue) only supplies field labels for the configuration line.
export function buildCounterReceipt(order, entries = []) {
  if (counterReceiptBlock(order) !== null) return null
  const items = (Array.isArray(order.items) ? order.items : []).map((item) => {
    const entry = entries.find((candidate) => candidate.product.id === item?.productKey)
    let detail = null
    try {
      detail = entry ? describeCounterConfiguration(entry.product, item.configuration) : null
    } catch {
      detail = null
    }
    const quantity = isNumber(item?.quantity) ? Number(item.quantity) : 1
    return {
      name: item?.productName || item?.productKey || 'Item',
      detail: detail || fallbackDetail(item),
      quantity,
      lineTotal: formatMoney(Number(item?.lineTotal))
    }
  })
  const payments = order.payments.map((payment) => ({
    method: payment.method,
    methodLabel: counterReceiptMethodLabel(payment.method),
    amount: formatMoney(Number(payment.amount)),
    date: formatCounterReceiptDate(payment.paidAt),
    time: formatCounterOrderTime(payment.paidAt),
    paidAt: payment.paidAt
  }))
  const last = payments[payments.length - 1]
  const fee = Number(order.fulfilmentFee)
  return {
    business: { name: BUSINESS_CAFE_NAME, addressLines: [...BUSINESS_ADDRESS_LINES], phone: WHATSAPP_DISPLAY },
    title: 'Payment receipt',
    reference: order.orderNumber,
    orderDate: formatCounterReceiptDate(order.createdAt),
    orderTime: formatCounterOrderTime(order.createdAt),
    paidDate: last.date,
    paidTime: last.time,
    customer: order.customerName || 'Walk-in',
    contact: [order.customerPhone, order.customerEmail].filter(Boolean),
    items,
    subtotal: isNumber(order.subtotal) ? formatMoney(Number(order.subtotal)) : null,
    fulfilmentFee: Number.isFinite(fee) && fee > CENT ? formatMoney(fee) : null,
    total: formatMoney(Number(order.totalAmount)),
    amountPaid: formatMoney(Number(order.amountPaid)),
    outstanding: formatMoney(Math.max(Number(order.outstanding), 0)),
    payments,
    // one method line for the common single-payment receipt; several methods are joined, never assumed to be one
    methodSummary: [...new Set(payments.map((payment) => payment.methodLabel))].join(' + ')
  }
}
