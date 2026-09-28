import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'
import {
  DEFAULT_PAYFAST_MINIMUM_AMOUNT,
  resolveProductPaymentEligibility,
  computeBasketPaymentEligibility,
  buildPayfastShortfallMessage,
  isEftBankDetailsComplete
} from '../src/lib/paymentEligibility.js'
import { buildOrderHandoffMessage } from '../src/lib/whatsappOrderHandoff.js'

const read = (path) => fs.readFileSync(new URL(path, import.meta.url), 'utf8')

// Node's ICU build determines whether en-ZA renders "R100.00" or "R 100,00" -
// this repo's own convention (see tests/counter-receipt.test.mjs's `money`
// helper) is to never hardcode the literal separator, but format through the
// same Intl call the library code uses and, where matching inside a longer
// string, escape whitespace so either rendering passes.
const money = (value) => new Intl.NumberFormat('en-ZA', { style: 'currency', currency: 'ZAR', minimumFractionDigits: 2 }).format(Number(value || 0))
const escapeRegex = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/\s/g, '\\s')

// ── QS Payment Eligibility v1 ───────────────────────────────────────────
// Same testing philosophy as checkout-hardening.test.mjs: the real
// decision logic (whole-basket AND rule, the R50 threshold, the shortfall
// copy, the WhatsApp receipt text) is pulled into pure functions and
// proven here as data-in/data-out. Component wiring (OrderBasket calling
// these functions, the admin editor writing paymentEligibility) is
// checked by reading the source, the same way this repo's other
// wiring-only tests already do.

function item(overrides = {}) {
  return {
    cartId: overrides.cartId || 'x',
    productName: overrides.productName || 'A4 Colour Printing',
    total: 20,
    quoteRequired: false,
    paymentEligibility: { allowPayfast: true, allowEft: true, allowPayAtCounter: true },
    ...overrides
  }
}

// ── R50 threshold ────────────────────────────────────────────────────────
test('R49.99, otherwise fully eligible, does not offer PayFast', () => {
  const result = computeBasketPaymentEligibility([item({ total: 49.99 })])
  assert.equal(result.payfastOffered, false)
  assert.equal(result.allowPayfast, true)
  assert.equal(result.payfastMeetsMinimum, false)
})

test('R50.00 exactly offers PayFast', () => {
  const result = computeBasketPaymentEligibility([item({ total: 50 })])
  assert.equal(result.payfastOffered, true)
  assert.equal(result.payfastMeetsMinimum, true)
})

test('the "Add RXX more" shortfall is the real remaining amount, computed live, not a static string', () => {
  const result = computeBasketPaymentEligibility([item({ total: 37.5 })])
  assert.equal(result.amountShortOfMinimum, 12.5)
  const message = buildPayfastShortfallMessage(result.amountShortOfMinimum, result.payfastMinimumAmount)
  assert.equal(message.headline, `Card payment is available from ${money(50)}.`)
  assert.equal(message.detail, `Add ${money(12.5)} more to unlock secure PayFast checkout.`)
})

test('a custom tenant payfastMinimumAmount is honoured instead of the default', () => {
  const result = computeBasketPaymentEligibility([item({ total: 80 })], { payfastMinimumAmount: 100 })
  assert.equal(result.payfastOffered, false)
  assert.equal(result.amountShortOfMinimum, 20)
})

// ── Whole-basket AND rule ────────────────────────────────────────────────
test('one line disallowing PayFast blocks PayFast for the entire basket, even above R50', () => {
  const result = computeBasketPaymentEligibility([
    item({ total: 100, paymentEligibility: { allowPayfast: true, allowEft: true, allowPayAtCounter: true } }),
    item({ total: 100, paymentEligibility: { allowPayfast: false, allowEft: true, allowPayAtCounter: true } })
  ])
  assert.equal(result.allowPayfast, false)
  assert.equal(result.payfastOffered, false)
})

test('one line disallowing Counter blocks Counter for the entire basket', () => {
  const result = computeBasketPaymentEligibility([
    item({ paymentEligibility: { allowPayfast: true, allowEft: true, allowPayAtCounter: true } }),
    item({ paymentEligibility: { allowPayfast: true, allowEft: true, allowPayAtCounter: false } })
  ])
  assert.equal(result.payAtCounterOffered, false)
})

test('one line disallowing EFT blocks EFT for the entire basket', () => {
  const result = computeBasketPaymentEligibility([
    item({ paymentEligibility: { allowPayfast: true, allowEft: true, allowPayAtCounter: true } }),
    item({ paymentEligibility: { allowPayfast: true, allowEft: false, allowPayAtCounter: true } })
  ])
  assert.equal(result.eftOffered, false)
})

test('a basket that is fully eligible offers PayFast, EFT and Counter together', () => {
  const result = computeBasketPaymentEligibility([item({ total: 100 })], { eftBankDetails: completeBank })
  assert.equal(result.payfastOffered, true)
  assert.equal(result.eftOffered, true)
  assert.equal(result.payAtCounterOffered, true)
})

// ── Conservative defaults / backwards compatibility ─────────────────────
test('a product with no paymentEligibility key at all (every product that predates this slice) still allows PayFast, exactly like today, but not EFT/Counter', () => {
  const resolved = resolveProductPaymentEligibility({ id: 'a4-print' })
  assert.deepEqual(resolved, { allowPayfast: true, allowEft: false, allowPayAtCounter: false })
})

test('a hand-edited/malformed paymentEligibility value falls back to the conservative default per-field, not the whole object', () => {
  const resolved = resolveProductPaymentEligibility({ paymentEligibility: { allowPayfast: 'yes', allowEft: true } })
  assert.deepEqual(resolved, { allowPayfast: true, allowEft: true, allowPayAtCounter: false })
})

// ── Quote-required lines never enter the whole-basket AND rule or the total ──
test('a quote-required line is excluded from the payable total and from the whole-basket rule', () => {
  const result = computeBasketPaymentEligibility([
    item({ total: 100, quoteRequired: false }),
    item({ total: 100000, quoteRequired: true, paymentEligibility: { allowPayfast: false, allowEft: false, allowPayAtCounter: false } })
  ])
  assert.equal(result.payableTotal, 100)
  assert.equal(result.allowPayfast, true)
  assert.equal(result.payfastOffered, true)
})

test('a basket of only quote-required lines offers nothing through this layer - existing quote gates are untouched', () => {
  const result = computeBasketPaymentEligibility([item({ quoteRequired: true })])
  assert.equal(result.hasPayableItems, false)
  assert.equal(result.payfastOffered, false)
  assert.equal(result.eftOffered, false)
  assert.equal(result.payAtCounterOffered, false)
})

// ── EFT bank-details completeness (never blank/placeholder to a customer) ──
const completeBank = { bank: 'Test Bank', accountHolder: 'Test Holder', accountType: 'Test Account', accountNumber: '0000000' }

test('isEftBankDetailsComplete: all four required fields present and non-empty is complete', () => {
  assert.equal(isEftBankDetailsComplete(completeBank), true)
})

test('isEftBankDetailsComplete: missing, empty or unseeded ({}) bank details are all incomplete', () => {
  assert.equal(isEftBankDetailsComplete(null), false)
  assert.equal(isEftBankDetailsComplete({}), false)
  assert.equal(isEftBankDetailsComplete({ ...completeBank, accountNumber: '' }), false)
  assert.equal(isEftBankDetailsComplete({ ...completeBank, accountHolder: '   ' }), false)
  const { bank, ...missingBank } = completeBank
  assert.equal(isEftBankDetailsComplete(missingBank), false)
})

test('computeBasketPaymentEligibility never offers EFT while the tenant\'s bank details are incomplete, even when every line allows EFT', () => {
  const eligible = computeBasketPaymentEligibility([item({ total: 100 })], { eftBankDetails: {} })
  assert.equal(eligible.allowEft, true)
  assert.equal(eligible.eftBankDetailsComplete, false)
  assert.equal(eligible.eftOffered, false)
})

test('computeBasketPaymentEligibility offers EFT once both the product flags and the bank details are complete', () => {
  const eligible = computeBasketPaymentEligibility([item({ total: 100 })], { eftBankDetails: completeBank })
  assert.equal(eligible.eftBankDetailsComplete, true)
  assert.equal(eligible.eftOffered, true)
})

// ── WhatsApp Order Handoff ───────────────────────────────────────────────
test('the WhatsApp receipt contains the order number, one line per item, the total and "Not paid yet"', () => {
  const message = buildOrderHandoffMessage({
    orderNumber: 'QS-260928-1234',
    customerName: 'Jane',
    items: [
      { productName: 'A4 Colour Printing', total: 100, quoteRequired: false },
      { productName: 'A4 Lamination', total: 15, quoteRequired: false }
    ],
    total: 115,
    fulfilmentLabel: 'Quick Solution Café - 13 Kite Cres'
  })
  assert.match(message, /Order: QS-260928-1234/)
  assert.match(message, /Name: Jane/)
  assert.match(message, new RegExp(`A4 Colour Printing — ${escapeRegex(money(100))}`))
  assert.match(message, new RegExp(`A4 Lamination — ${escapeRegex(money(15))}`))
  assert.match(message, new RegExp(`Total: ${escapeRegex(money(115))}`))
  assert.match(message, /Collection: Quick Solution Café - 13 Kite Cres/)
  assert.match(message, /Payment: Not paid yet/)
})

test('the WhatsApp receipt shows "Quote" (not a fabricated price) for a quote-required line', () => {
  const message = buildOrderHandoffMessage({
    orderNumber: 'QS-1', items: [{ productName: 'Signage', quoteRequired: true }], total: 0
  })
  assert.match(message, /Signage — Quote/)
})

// ── Component wiring (source inspection, same style as checkout-hardening.test.mjs) ──
test('OrderBasket only offers PayFast/Counter/EFT through computeBasketPaymentEligibility, never a hand-rolled check', () => {
  const source = read('../src/components/OrderBasket.jsx')
  assert.match(source, /computeBasketPaymentEligibility\(/)
  assert.match(source, /basketEligibility\.payfastOffered/)
  assert.match(source, /basketEligibility\.payAtCounterOffered/)
  assert.match(source, /basketEligibility\.eftOffered/)
})

test('Pay at Counter and EFT both record a pending intent through recordQuickSolutionPaymentIntent, never a completed payment', () => {
  const source = read('../src/components/OrderBasket.jsx')
  assert.match(source, /recordQuickSolutionPaymentIntent\(orderResponse\.orderId, orderResponse\.paymentToken, method\)/)
  assert.doesNotMatch(source, /status.*['"]completed['"]/)
})

test('the WhatsApp handoff link is only built from an order that has already been created (orderResponse), never from a fresh order call', () => {
  const source = read('../src/components/OrderBasket.jsx')
  const handoffBlock = source.slice(source.indexOf('whatsappHandoffHref'), source.indexOf('whatsappHandoffHref') + 400)
  assert.match(handoffBlock, /orderResponse\s*\?/)
  assert.doesNotMatch(handoffBlock, /createQuickSolutionCartOrder/)
})

test('the admin product editor exposes Payment options with friendly labels, writing to paymentEligibility via resolveProductPaymentEligibility', () => {
  const source = read('../src/admin/AdminProductManager.jsx')
  assert.match(source, /Allow secure online payment/)
  assert.match(source, /Allow EFT/)
  assert.match(source, /Allow pay at counter/)
  assert.match(source, /updatePaymentEligibility/)
  assert.match(source, /resolveProductPaymentEligibility\(product\)/)
})

test('App.jsx captures paymentEligibility onto every cart item at both construction points (addToCart and addOfferToCart)', () => {
  const source = read('../src/App.jsx')
  const matches = source.match(/paymentEligibility: resolveProductPaymentEligibility\(product\)/g) || []
  assert.equal(matches.length, 2, 'addToCart and addOfferToCart both set paymentEligibility')
})
