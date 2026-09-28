// Quick Solution Payment Eligibility v1 - the whole decision layer pulled
// out as pure functions, the same way lib/navigation.js and lib/payfastInit.js
// are: this repo's test suite is plain Node --test with no DOM/rendering
// harness, so "R49.99 blocks PayFast", "one disallowing line blocks the
// whole basket" etc. are proven here as data-in/data-out, not by rendering
// OrderBasket and simulating clicks.
//
// This is a UX-layer decision only - which methods to even OFFER the
// customer. It never replaces, weakens or is trusted instead of the
// existing server-side gates (quote-required checkout, PHOTOGRAPHY_SESSION,
// the real PayFast R50 threshold enforced server-side, qs_begin_payfast_
// payment's own checks). A method being "offered" here still has to pass
// its own real server RPC before anything happens.

// Conservative default per the brief: PayFast stays on for every product
// that does not explicitly say otherwise, because that is the EXISTING,
// already-live behavior this slice must not silently change for any
// current product. EFT and Pay at Counter are brand new capabilities that
// do not exist anywhere today - defaulting them to false means adding this
// whole feature changes nothing for any product until staff deliberately
// opt one in via the admin editor.
export const DEFAULT_PAYMENT_ELIGIBILITY = Object.freeze({
  allowPayfast: true,
  allowEft: false,
  allowPayAtCounter: false
})

export const DEFAULT_PAYFAST_MINIMUM_AMOUNT = 50

// A product's customer_definition may have no paymentEligibility key at all
// (every product that predates this slice), a partial object, or malformed
// values (hand-edited JSON) - this always returns a complete, safe object,
// falling back to the conservative default for anything not a real boolean.
export function resolveProductPaymentEligibility(product) {
  const raw = product?.paymentEligibility
  const bool = (value, fallback) => (typeof value === 'boolean' ? value : fallback)
  return {
    allowPayfast: bool(raw?.allowPayfast, DEFAULT_PAYMENT_ELIGIBILITY.allowPayfast),
    allowEft: bool(raw?.allowEft, DEFAULT_PAYMENT_ELIGIBILITY.allowEft),
    allowPayAtCounter: bool(raw?.allowPayAtCounter, DEFAULT_PAYMENT_ELIGIBILITY.allowPayAtCounter)
  }
}

// A cart item only ever "allows" a method if it is itself payable at all.
// A quote-required line (ENQUIRY, PHOTOGRAPHY_SESSION, or anything else the
// server itself refuses to price/charge through this path) is never part
// of the whole-basket AND rule and never contributes to the R50 total -
// there is no price to gate a payment method against, and the existing
// quote flow is untouched by this slice.
function isPayableItem(item) {
  return !item?.quoteRequired
}

// v1 whole-basket rule, exactly as specified: a method is offered only if
// EVERY payable line in the basket allows it. One disallowing line removes
// that method for the entire basket - no split payment, no per-line
// routing. A basket with zero payable lines (everything quote-required)
// offers nothing - there is nothing to pay for through this layer.
export function computeBasketPaymentEligibility(items, { payfastMinimumAmount = DEFAULT_PAYFAST_MINIMUM_AMOUNT } = {}) {
  const payableItems = (items || []).filter(isPayableItem)
  const payableTotal = payableItems.reduce((sum, item) => sum + Number(item.total || 0), 0)
  const hasPayableItems = payableItems.length > 0

  const allowPayfast = hasPayableItems && payableItems.every((item) => resolveProductPaymentEligibility(item).allowPayfast)
  const allowEft = hasPayableItems && payableItems.every((item) => resolveProductPaymentEligibility(item).allowEft)
  const allowPayAtCounter = hasPayableItems && payableItems.every((item) => resolveProductPaymentEligibility(item).allowPayAtCounter)

  const payfastMeetsMinimum = payableTotal >= payfastMinimumAmount
  const payfastOffered = allowPayfast && payfastMeetsMinimum
  const amountShortOfMinimum = payfastMeetsMinimum ? 0 : Math.round((payfastMinimumAmount - payableTotal) * 100) / 100

  return {
    payableTotal,
    hasPayableItems,
    allowPayfast,
    allowEft,
    allowPayAtCounter,
    payfastMinimumAmount,
    payfastMeetsMinimum,
    payfastOffered,
    eftOffered: allowEft,
    payAtCounterOffered: allowPayAtCounter,
    amountShortOfMinimum
  }
}

function money(value) {
  return new Intl.NumberFormat('en-ZA', {
    style: 'currency',
    currency: 'ZAR',
    minimumFractionDigits: 2
  }).format(Number(value || 0))
}

// The exact two-line copy the brief specifies, with RXX computed live from
// the real shortfall rather than ever being a static string.
export function buildPayfastShortfallMessage(amountShortOfMinimum, payfastMinimumAmount = DEFAULT_PAYFAST_MINIMUM_AMOUNT) {
  return {
    headline: `Card payment is available from ${money(payfastMinimumAmount)}.`,
    detail: `Add ${money(amountShortOfMinimum)} more to unlock secure PayFast checkout.`
  }
}
