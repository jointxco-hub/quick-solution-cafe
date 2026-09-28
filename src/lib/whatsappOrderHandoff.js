// Quick Solution Payment Eligibility v1 - WhatsApp Order Handoff.
// Pure message builder (see paymentEligibility.js's header comment for why
// this repo pulls decisions like this out into their own testable module).
// This is NOT a payment method - the order must already be created/saved
// before this is ever called (callers pass the real, already-created
// order response); this module never creates, mutates or duplicates an
// order, and never touches cart/localStorage.

function money(value) {
  return new Intl.NumberFormat('en-ZA', {
    style: 'currency',
    currency: 'ZAR',
    minimumFractionDigits: 2
  }).format(Number(value || 0))
}

// One line per item: "Product — Rxx.xx" (or "— Quote" for a quote-required
// line, matching how the basket itself displays it - the receipt never
// invents a price the order does not actually have). Real cart entries are
// each exactly one unit by construction (App.jsx's addToCart/addOfferToCart
// push one entry per unit rather than storing a quantity field), so there
// is no "× qty" to show - identical items are already separate lines.
function describeLine(item) {
  const name = item?.productName || item?.name || 'Item'
  const pricePart = item?.quoteRequired ? 'Quote' : money(item?.total)
  return `• ${name} — ${pricePart}`
}

// Builds the exact receipt-style message from the brief - order number,
// customer name if available, one line per item, the overall total,
// the collection/delivery choice, current payment status (always "Not
// paid yet" - this handoff is never a payment confirmation), and a short
// request for help. Returns a plain string; callers encodeURIComponent it
// themselves before handing it to buildWhatsappUrl, matching that
// function's existing "caller pre-encodes" contract.
export function buildOrderHandoffMessage({
  orderNumber,
  customerName = '',
  items = [],
  total = 0,
  fulfilmentLabel = ''
}) {
  const lines = [
    'Hi Quick Solution, I’d like help completing this order:',
    '',
    `Order: ${orderNumber || 'Unknown'}`
  ]

  if (customerName.trim()) lines.push(`Name: ${customerName.trim()}`)
  lines.push('')

  for (const item of items) lines.push(describeLine(item))

  lines.push('')
  lines.push(`Total: ${money(total)}`)
  if (fulfilmentLabel) lines.push(`Collection: ${fulfilmentLabel}`)
  lines.push('Payment: Not paid yet')
  lines.push('')
  lines.push('Please help me complete this order.')

  return lines.join('\n')
}
