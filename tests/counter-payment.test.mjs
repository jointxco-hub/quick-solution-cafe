import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'
import { loadCounterUi } from './helpers/counter-ui-harness.mjs'
import { products as seedProducts } from '../src/data/products.js'
import { formatMoney } from '../src/lib/pricing.js'
import { loadCounterCatalogueState } from '../src/lib/counterDraft.js'
import { describeCounterOrder, loadCounterOrdersState } from '../src/lib/counterOrders.js'
import {
  COUNTER_PAYMENT_METHODS,
  COUNTER_PAYMENT_UNKNOWN_MESSAGE,
  PAYMENT_PHASES,
  beginPayment,
  beginPaymentSubmit,
  cancelPayment,
  describeCounterOrderDetail,
  initialPayment,
  isPaymentLocked,
  loadCounterOrderDetailState,
  resetPayment,
  resumePaymentAfterSignIn,
  submitPayment
} from '../src/lib/counterPayment.js'

// CAFE-GUEST-01Q - opening a counter order and recording ONE full Cash or Card payment. The API is never real: fake
// `load` / `record` functions stand in for the server, and the screens are the real components rendered to HTML
// (tests/helpers/counter-ui-harness.mjs). What the server does with a payment - the amount, the ledger, the single
// payment per order, concurrency - is proven on real PostgreSQL in supabase/tests/cafe_guest_01q_*.sql.

const read = (path) => fs.readFileSync(new URL(path, import.meta.url), 'utf8')
const stripComments = (text) => text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:'"`])\/\/[^\n]*/g, '$1')
const ui = await loadCounterUi()
const h = ui.React.createElement
const html = (element) => ui.renderToStaticMarkup(element)
const serverProducts = seedProducts.filter((product) => product.channels?.pos === true)
const ready = await loadCounterCatalogueState(async () => ({ tenant: { slug: 'quick-solution', name: 'Quick Solution' }, products: serverProducts }))
const money = (value) => formatMoney(value).replace(/\s/g, '\\s')
const httpError = (message, status, code) => Object.assign(new Error(message), { status, payload: code ? { code } : null })
const keyMaker = () => { let n = 0; return () => `pay-key-${String(++n).padStart(8, '0')}` }

// an order detail exactly as get_quick_solution_counter_order returns it
const detailOrder = (overrides = {}) => ({
  orderId: 'b1f0c0de-0000-4000-8000-0000000000aa',
  orderNumber: 'QS-260926-AB12',
  createdAt: '2026-09-26T11:05:00+00:00',
  status: 'submitted',
  paymentStatus: 'unpaid',
  customerName: 'Thandi Nkosi',
  customerEmail: null,
  customerPhone: '0751234567',
  subtotal: 35,
  fulfilmentFee: 0,
  totalAmount: 35,
  amountPaid: 0,
  outstanding: 35,
  paymentAllowed: true,
  items: [{ productKey: 'scan', productName: 'Document Scanning', quantity: 1, configuration: { units: 7 }, lineTotal: 35 }],
  payments: [],
  ...overrides
})
const paidOrder = (method = 'cash') => detailOrder({ paymentStatus: 'paid', amountPaid: 35, outstanding: 0, paymentAllowed: false, payments: [{ paymentId: 'p1', method, amount: 35, paidAt: '2026-09-26T11:30:00+00:00' }] })

function detailScreen(order, payment = initialPayment(), extra = {}) {
  return html(h(ui.CounterView, { state: ready, view: 'order', orderDetail: { status: 'ready', order, orderId: order?.orderId }, payment, ...extra }))
}
const buttonsOf = (markup) => [...markup.matchAll(/<button[^>]*>([\s\S]*?)<\/button>/g)].map((match) => match[1].replace(/<[^>]+>/g, ''))
const detailSection = (markup) => markup.slice(markup.indexOf('class="qsc-detail"'))
const confirming = (method = 'cash', order = detailOrder(), makeKey = keyMaker()) => beginPayment(initialPayment(), order, method, makeKey)
const fakeRecord = ({ fail = null, replay = false, amount = 35, method = null } = {}) => {
  const calls = []
  const record = async (payload) => {
    calls.push(JSON.parse(JSON.stringify(payload)))
    if (fail) throw fail
    return { ok: true, replayed: replay, alreadyPaid: false, orderId: payload.orderId, orderNumber: 'QS-260926-AB12', paymentId: 'pay-1', method: method || payload.method, amount, paidAt: '2026-09-26T12:15:00+00:00', paymentStatus: 'paid', totalAmount: amount, amountPaid: amount, outstanding: 0 }
  }
  return { record, calls }
}
const submit = (payment, record, timeout) => submitPayment(beginPaymentSubmit(payment), record, timeout)

// ── opening an order ────────────────────────────────────────────────────
test('a row opens the order, and the order is read from the server by id only - never taken from the list row', async () => {
  const list = html(h(ui.CounterView, { state: ready, view: 'orders', orders: { status: 'ready', businessDate: '2026-09-26', orders: [detailOrder()] } }))
  assert.match(list, /<button[^>]*class="qsc-order"[^>]*aria-label="Open order QS-260926-AB12"/)
  const page = stripComments(read('../src/counter/CounterPage.jsx'))
  assert.match(page, /onOpenOrder=\{openOrder\}/)
  assert.match(page, /const openOrder = \(orderId, origin = 'orders'\) => \{[\s\S]*?setView\('order'\)[\s\S]*?loadDetail\(orderId\)/)
  assert.match(page, /loadCounterOrderDetailState\(loadQuickSolutionCounterOrder, orderId\)/)
  // what the wrapper sends: the order id and nothing else
  const api = read('../src/lib/supabaseApi.js')
  assert.match(api.match(/export async function loadQuickSolutionCounterOrder\(orderId\) \{[\s\S]*?\n\}/)[0], /return rpc\('get_quick_solution_counter_order', \{ p_order_id: orderId \}, \{ accessToken \}\)/)
  const calls = []
  const state = await loadCounterOrderDetailState(async (...args) => { calls.push(args); return detailOrder() }, 'the-id')
  assert.deepEqual(calls, [['the-id']])
  assert.equal(state.status, 'ready')
  // the list row is not a payment source: without the server's detail (paymentAllowed, outstanding) nothing can start
  const listRow = { orderId: 'x', orderNumber: 'QS-1', paymentStatus: 'unpaid', totalAmount: 35, items: [] }
  const idle = initialPayment()
  assert.equal(beginPayment(idle, listRow, 'cash', keyMaker()), idle, 'a list row has no paymentAllowed / outstanding, so it cannot start a payment')
  for (const file of ['../src/counter/CounterPage.jsx', '../src/lib/counterPayment.js']) {
    assert.doesNotMatch(stripComments(read(file)), /localStorage|sessionStorage|indexedDB/i, file)
  }
})

test('detail states: loading, not found, denied, signed-out and error come from the server’s answer', async () => {
  const fail = (message, extra = {}) => loadCounterOrderDetailState(async () => { throw Object.assign(new Error(message), extra) }, 'id')
  const render = (state) => html(h(ui.CounterView, { state: ready, view: 'order', orderDetail: state }))
  assert.match(render({ status: 'loading' }), /Loading the order…/)
  const notFound = await fail('Counter order was not found.', { status: 400, payload: { code: '22023' } })
  assert.equal(notFound.status, 'not-found')
  assert.match(render(notFound), /Order not found/)
  const denied = await fail('You do not have access to the Quick Solution counter.', { status: 403, payload: { code: '42501' } })
  assert.match(render(denied), /No counter access[\s\S]*You do not have access/)
  const signedOut = await fail('Staff sign-in is required.')
  assert.match(render(signedOut), /Sign in to see this order/)
  const failed = await fail('Failed to fetch')
  assert.match(render(failed), /Could not load the order[\s\S]*Try again/)
  for (const state of [notFound, denied, signedOut, failed]) assert.doesNotMatch(render(state), /Record (Cash|Card) Payment/)
  assert.equal((await loadCounterOrderDetailState(async () => null, 'id')).status, 'error')
})

test('the detail shows number, time, customer, items with configuration, server total, amount paid, outstanding, status and payment status', () => {
  const markup = detailSection(detailScreen(detailOrder({ amountPaid: 5, outstanding: 30 })))
  assert.match(markup, /QS-260926-AB12/)
  assert.match(markup, /13:05/, 'the Café’s time zone')
  assert.match(markup, /Thandi Nkosi<small>0751234567<\/small>/)
  assert.match(markup, /Document Scanning<small>7 pages<\/small>/)
  assert.match(markup, new RegExp(`<dt>Total</dt><dd>${money(35)}`))
  assert.match(markup, new RegExp(`<dt>Paid</dt><dd>${money(5)}`))
  assert.match(markup, new RegExp(`Outstanding</dt><dd>${money(30)}`))
  assert.match(markup, /<dt>Status<\/dt><dd>Submitted<\/dd>/)
  assert.match(markup, /qsc-state qsc-state-unpaid">Unpaid</)
  assert.match(markup, /Today’s orders/)
})

// ── payment actions ─────────────────────────────────────────────────────
test('an unpaid, payable order offers exactly Record Cash Payment and Record Card Payment - nothing else', () => {
  assert.deepEqual(COUNTER_PAYMENT_METHODS.map((method) => method.id), ['cash', 'card'])
  assert.equal(Object.isFrozen(COUNTER_PAYMENT_METHODS), true)
  const markup = detailSection(detailScreen(detailOrder()))
  assert.deepEqual(buttonsOf(markup).filter((text) => /record/i.test(text)), ['Record Cash Payment', 'Record Card Payment'])
  assert.deepEqual(buttonsOf(markup), ['← Today’s orders', 'Record Cash Payment', 'Record Card Payment'])
  assert.doesNotMatch(markup, /EFT|bank transfer|PayFast|Pay now|Pay<|Receipt|Refund|Partial/i)
  assert.doesNotMatch(markup, /<input|<select|<textarea|type="number"/i, 'no amount, no card field, nothing to type')
})

test('only cash and card can begin a payment; EFT, other spellings and unknown methods cannot', () => {
  const idle = initialPayment()
  for (const method of ['eft', 'EFT', 'Cash', 'CARD', 'bank', 'payfast', '', null, undefined, 'cash ']) {
    assert.equal(beginPayment(idle, detailOrder(), method, keyMaker()), idle, String(method))
  }
  assert.equal(beginPayment(idle, detailOrder(), 'cash', keyMaker()).phase, PAYMENT_PHASES.CONFIRMING)
  assert.equal(beginPayment(idle, detailOrder(), 'card', keyMaker()).phase, PAYMENT_PHASES.CONFIRMING)
})

test('a paid order, an order the server says cannot take a payment, and an order with nothing outstanding have no payment buttons', () => {
  const paid = detailSection(detailScreen(paidOrder('cash')))
  assert.deepEqual(buttonsOf(paid), ['← Today’s orders', 'View receipt'], 'a fully paid order can show its receipt and nothing else')
  assert.match(paid, /This order is paid\./)
  assert.match(paid, /Cash · <!-- -->|Cash · /)
  assert.match(paid, /qsc-state qsc-state-paid">Paid</)
  assert.match(paid, new RegExp(`Outstanding</dt><dd>${money(0)}`))
  const blocked = detailSection(detailScreen(detailOrder({ paymentAllowed: false })))
  assert.doesNotMatch(blocked, /Record (Cash|Card) Payment/)
  assert.match(blocked, /A payment cannot be recorded for this order here\./)
  const nothing = detailOrder({ outstanding: 0 })
  assert.equal(describeCounterOrderDetail(nothing).canPay, false)
  assert.equal(beginPayment(initialPayment(), nothing, 'cash', keyMaker()).phase, PAYMENT_PHASES.IDLE)
  assert.equal(beginPayment(initialPayment(), paidOrder(), 'card', keyMaker()).phase, PAYMENT_PHASES.IDLE)
  assert.equal(beginPayment(initialPayment(), detailOrder({ paymentStatus: 'pending' }), 'card', keyMaker()).phase, PAYMENT_PHASES.IDLE)
})

// ── confirmation ────────────────────────────────────────────────────────
test('confirmation shows the SERVER’s outstanding, the order number and the method; the amount cannot be changed', () => {
  const order = detailOrder({ totalAmount: 40, subtotal: 40, amountPaid: 2.5, outstanding: 37.5 })
  for (const [method, label] of [['cash', 'Cash'], ['card', 'Card']]) {
    const payment = confirming(method, order)
    assert.equal(payment.phase, PAYMENT_PHASES.CONFIRMING)
    assert.equal(payment.attempt.amountLabel, formatMoney(37.5), 'the outstanding, not the total')
    const markup = detailSection(detailScreen(order, payment))
    assert.match(markup, new RegExp(`<h3>Record ${money(37.5)} as ${label}\\?</h3>`))
    assert.match(markup, /<dt>Order<\/dt><dd>QS-260926-AB12<\/dd>/)
    assert.match(markup, new RegExp(`<dt>Method</dt><dd>${label}</dd>`))
    assert.match(markup, new RegExp(`<dt>Amount</dt><dd>${money(37.5)}</dd>`))
    assert.deepEqual(buttonsOf(markup.slice(markup.indexOf('qsc-confirm-pay'))), ['Back', `Confirm ${method} payment`])
    assert.doesNotMatch(markup.slice(markup.indexOf('qsc-confirm-pay')), /<input|<select|Record (Cash|Card) Payment/)
  }
  assert.match(detailSection(detailScreen(order, confirming('card', order))), /Card details are never entered here/)
  assert.match(detailSection(detailScreen(order, confirming('cash', order))), /whole amount was received in cash/)
})

// ── idempotency ─────────────────────────────────────────────────────────
test('one key per payment attempt, made when the method is chosen, never shown, bound to the order and method', async () => {
  const makeKey = keyMaker()
  const payment = beginPayment(initialPayment(), detailOrder(), 'cash', makeKey)
  assert.equal(payment.attempt.idempotencyKey, 'pay-key-00000001')
  assert.equal(makeKey(), 'pay-key-00000002', 'exactly one key was made')
  assert.equal(payment.attempt.method, 'cash')
  assert.equal(payment.attempt.orderId, detailOrder().orderId)
  assert.doesNotMatch(detailScreen(detailOrder(), payment), /pay-key-/)
  const { record, calls } = fakeRecord()
  const done = await submit(payment, record)
  assert.equal(done.phase, PAYMENT_PHASES.SUCCESS)
  assert.deepEqual(Object.keys(calls[0]).sort(), ['idempotencyKey', 'method', 'orderId'], 'the payload is the order, the method and the key - no amount, status, tenant or actor')
  assert.deepEqual(calls[0], { orderId: detailOrder().orderId, method: 'cash', idempotencyKey: 'pay-key-00000001' })
  assert.equal(calls.length, 1)
  assert.equal(beginPaymentSubmit(done), done, 'a finished payment is not submitted again')
  // the wrapper sends the same three things under their server names
  const api = read('../src/lib/supabaseApi.js')
  assert.match(api.match(/export async function recordQuickSolutionCounterPayment\([^)]*\) \{[\s\S]*?\n\}/)[0], /return rpc\('record_quick_solution_counter_payment', \{ p_order_id: orderId, p_method: method, p_idempotency_key: idempotencyKey \}, \{ accessToken \}\)/)
})

test('Confirm clicked twice sends one request; the second click while submitting starts nothing', async () => {
  const first = beginPaymentSubmit(confirming('card'))
  assert.equal(first.phase, PAYMENT_PHASES.SUBMITTING)
  assert.equal(beginPaymentSubmit(first), first)
  assert.equal(beginPaymentSubmit(initialPayment()).phase, PAYMENT_PHASES.IDLE)
  const markup = detailSection(detailScreen(detailOrder(), first))
  assert.match(markup, /aria-busy="true"/)
  assert.match(markup, /<button[^>]*disabled=""[^>]*>Recording…<\/button>/)
  assert.match(markup, /<button[^>]*disabled=""[^>]*>Back<\/button>/)
  const page = stripComments(read('../src/counter/CounterPage.jsx'))
  assert.match(page, /if \(paymentInFlight\.current\) return/)
  assert.match(page, /const started = beginPaymentSubmit\(payment\)\s*\n\s*if \(started === payment\) return/)
})

test('an unknown result locks the attempt: same key, same request, no other method, no cancel, and Retry safely only', async () => {
  const makeKey = keyMaker()
  const payment = beginPayment(initialPayment(), detailOrder(), 'card', makeKey)
  const failing = fakeRecord({ fail: new TypeError('Failed to fetch') })
  const unknown = await submit(payment, failing.record)
  assert.equal(unknown.phase, PAYMENT_PHASES.UNKNOWN)
  assert.equal(unknown.error, COUNTER_PAYMENT_UNKNOWN_MESSAGE)
  assert.equal(COUNTER_PAYMENT_UNKNOWN_MESSAGE, 'The payment may already have been recorded. Retry safely to confirm the result.')
  assert.equal(isPaymentLocked(unknown), true)
  assert.equal(unknown.attempt.idempotencyKey, 'pay-key-00000001')
  // locked: no other method, no cancel, no reset, no new attempt
  assert.equal(beginPayment(unknown, detailOrder(), 'cash', makeKey), unknown)
  assert.equal(cancelPayment(unknown), unknown)
  assert.equal(resetPayment(unknown), unknown)
  const markup = detailSection(detailScreen(detailOrder(), unknown))
  assert.deepEqual(buttonsOf(markup), ['← Today’s orders', 'Retry safely'])
  assert.doesNotMatch(markup, /Record (Cash|Card) Payment|Paid<\/strong>|Take payment again/i)
  assert.match(markup, /The payment may already have been recorded\. Retry safely to confirm the result\./)
  // the retry is exactly the same request, and the server returns the original payment
  const ok = fakeRecord({ replay: true })
  const retried = await submit(unknown, ok.record)
  assert.equal(retried.phase, PAYMENT_PHASES.SUCCESS)
  assert.deepEqual(ok.calls[0], failing.calls[0])
  assert.equal(retried.attempt.submissions, 2)
  assert.equal(makeKey(), 'pay-key-00000002', 'no new key was made')
  assert.equal(retried.result.replayed, true)
  assert.match(detailSection(detailScreen(detailOrder(), retried)), /original payment, not a new one/)
  // every other uncertain outcome is unknown too
  for (const failure of [httpError('Bad gateway', 502), httpError('Unavailable', 503), new Error('boom')]) {
    assert.equal((await submit(payment, fakeRecord({ fail: failure }).record)).phase, PAYMENT_PHASES.UNKNOWN, failure.message)
  }
  assert.equal((await submit(payment, async () => ({ ok: true }))).phase, PAYMENT_PHASES.UNKNOWN, 'an unreadable success is unknown, never Paid')
  assert.equal((await submit(payment, async () => null)).phase, PAYMENT_PHASES.UNKNOWN)
  const timed = await submitPayment(beginPaymentSubmit(payment), () => new Promise(() => {}), 15)
  assert.equal(timed.phase, PAYMENT_PHASES.UNKNOWN, 'a request that never answers becomes unknown, not stuck')
})

test('only an explicit new attempt gets a new key: cancelling before confirming, or a refused attempt', async () => {
  const makeKey = keyMaker()
  const first = beginPayment(initialPayment(), detailOrder(), 'cash', makeKey)
  const cancelled = cancelPayment(first)
  assert.equal(cancelled.phase, PAYMENT_PHASES.IDLE)
  const second = beginPayment(cancelled, detailOrder(), 'card', makeKey)
  assert.equal(second.attempt.idempotencyKey, 'pay-key-00000002')
  const rejected = await submit(second, fakeRecord({ fail: httpError('This order cannot take a payment.', 400, '22023') }).record)
  assert.equal(rejected.phase, PAYMENT_PHASES.REJECTED)
  assert.equal(rejected.error, 'This order cannot take a payment.')
  assert.match(detailSection(detailScreen(detailOrder(), rejected)), /This order cannot take a payment\.[\s\S]*Reload order/)
  const again = beginPayment(resetPayment(rejected), detailOrder(), 'card', makeKey)
  assert.equal(again.attempt.idempotencyKey, 'pay-key-00000003')
})

test('a conflict is never retried with a new key', async () => {
  const { record, calls } = fakeRecord({ fail: httpError('This payment key was already used for a different payment request.', 409, '23505') })
  const conflict = await submit(confirming('cash'), record)
  assert.equal(conflict.phase, PAYMENT_PHASES.CONFLICT)
  assert.equal(calls.length, 1, 'no automatic retry')
  assert.equal(beginPaymentSubmit(conflict), conflict)
  const markup = detailSection(detailScreen(detailOrder(), conflict))
  assert.match(markup, /already used for a different payment request/)
  assert.deepEqual(buttonsOf(markup), ['← Today’s orders', 'Reload order'])
})

test('a lost session is not retried silently: sign in, then confirm the same attempt with the same key', async () => {
  const makeKey = keyMaker()
  const payment = beginPayment(initialPayment(), detailOrder(), 'cash', makeKey)
  for (const failure of [new Error('Staff sign-in is required.'), httpError('JWT expired', 401)]) {
    const attempt = fakeRecord({ fail: failure })
    const out = await submit(payment, attempt.record)
    assert.equal(out.phase, PAYMENT_PHASES.SIGNED_OUT, failure.message)
    assert.equal(attempt.calls.length, 1)
  }
  const out = await submit(payment, fakeRecord({ fail: new Error('Staff sign-in is required.') }).record)
  assert.match(detailSection(detailScreen(detailOrder(), out)), /Sign in to continue this payment[\s\S]*Nothing was recorded/)
  const resumed = resumePaymentAfterSignIn(out)
  assert.equal(resumed.phase, PAYMENT_PHASES.CONFIRMING)
  const { record, calls } = fakeRecord()
  await submit(resumed, record)
  assert.equal(calls[0].idempotencyKey, 'pay-key-00000001')
  assert.equal(resumePaymentAfterSignIn(payment), payment)
})

test('an access refusal shows the server message and offers only a reload', async () => {
  const denied = await submit(confirming('cash'), fakeRecord({ fail: httpError('You do not have access to the Quick Solution counter.', 403, '42501') }).record)
  assert.equal(denied.phase, PAYMENT_PHASES.DENIED)
  const markup = detailSection(detailScreen(detailOrder(), denied))
  assert.match(markup, /You do not have access to the Quick Solution counter\./)
  assert.deepEqual(buttonsOf(markup), ['← Today’s orders', 'Reload order'])
})

// ── outcomes ────────────────────────────────────────────────────────────
test('success shows the server’s Paid result - method, recorded amount and time - never a locally made one', async () => {
  const done = await submit(confirming('cash'), fakeRecord({ amount: 35.5 }).record)
  assert.equal(done.phase, PAYMENT_PHASES.SUCCESS)
  assert.deepEqual([done.result.method, done.result.amount, done.result.amountLabel], ['cash', 35.5, formatMoney(35.5)])
  const markup = detailSection(detailScreen(detailOrder(), done))
  assert.match(markup, new RegExp(`<strong>Paid</strong><span>Cash · ${money(35.5)} · 14:15</span>`))
  assert.deepEqual(buttonsOf(markup), ['← Today’s orders'], 'no payment button after success')
  // the recorded amount is the server’s even if it differs from what was on the confirmation
  assert.notEqual(done.attempt.amountLabel, done.result.amountLabel)
  // and nothing in the client marks an order paid: only the server's detail says so
  assert.doesNotMatch(stripComments(read('../src/lib/counterPayment.js') + read('../src/counter/CounterPage.jsx')), /paymentStatus\s*[:=]\s*'paid'|payment_status/)
})

test('the order is loaded again after every outcome that may have changed it - not after an unknown result', () => {
  const page = stripComments(read('../src/counter/CounterPage.jsx'))
  const body = page.slice(page.indexOf('const confirmPayment'), page.indexOf('const resetOrderPayment'))
  assert.match(body, /\[PAYMENT_PHASES\.SUCCESS, PAYMENT_PHASES\.ALREADY_PAID, PAYMENT_PHASES\.REJECTED, PAYMENT_PHASES\.DENIED\]\.includes\(next\.phase\)\) loadDetail\(orderId\)/)
  assert.doesNotMatch(body, /UNKNOWN/)
})

test('an already-paid answer is authoritative: Paid is shown, the order is reloaded, and no other method is offered', async () => {
  const other = async () => ({ ok: false, reason: 'already_paid', orderId: detailOrder().orderId, orderNumber: 'QS-260926-AB12', paymentStatus: 'paid' })
  const state = await submit(confirming('card'), other)
  assert.equal(state.phase, PAYMENT_PHASES.ALREADY_PAID)
  const stale = detailSection(detailScreen(detailOrder(), state))
  assert.match(stale, /Already paid/)
  assert.doesNotMatch(stale, /Record (Cash|Card) Payment|Confirm/)
  // after the reload the server’s detail says paid and there is nothing to record
  const reloaded = detailSection(detailScreen(paidOrder('cash'), state))
  assert.doesNotMatch(reloaded, /Record (Cash|Card) Payment/)
  assert.match(reloaded, /qsc-state-paid">Paid</)
  assert.equal(resetPayment(state).phase, PAYMENT_PHASES.IDLE)
})

// ── Today's list ────────────────────────────────────────────────────────
test('Today’s Orders reports Paid on its next server refresh; the page refreshes it every time it is opened', async () => {
  const server = [detailOrder()]
  const list = async () => ({ businessDate: '2026-09-26', orders: server.map((order) => ({ ...order })) })
  const before = await loadCounterOrdersState(list)
  assert.equal(describeCounterOrder(before.orders[0], ready.entries).paymentLabel, 'Unpaid')
  const done = await submit(confirming('cash'), async (payload) => { server[0] = paidOrder(payload.method); return (await fakeRecord().record(payload)) })
  assert.equal(done.phase, PAYMENT_PHASES.SUCCESS)
  assert.equal(describeCounterOrder(before.orders[0], ready.entries).paymentLabel, 'Unpaid', 'the earlier list is not edited locally')
  const after = await loadCounterOrdersState(list)
  const row = describeCounterOrder(after.orders[0], ready.entries)
  assert.deepEqual([row.paymentLabel, row.paymentStatus], ['Paid', 'paid'])
  assert.match(html(h(ui.CounterView, { state: ready, view: 'orders', orders: after })), /qsc-state qsc-state-paid">Paid</)
  const page = stripComments(read('../src/counter/CounterPage.jsx'))
  assert.match(page, /const backToOrders = \(\) => \{[\s\S]*?setView\('orders'\)\s*\n\s*loadOrders\(\)/)
})

// ── scope ───────────────────────────────────────────────────────────────
test('there is no receipt, no card data, no customer write and no other write RPC', () => {
  const view = stripComments(read('../src/counter/CounterView.jsx'))
  const lib = stripComments(read('../src/lib/counterPayment.js'))
  const page = stripComments(read('../src/counter/CounterPage.jsx'))
  for (const source of [view, lib, page]) {
    assert.doesNotMatch(source, /cvv|card ?number|cardnumber|expiry|cardholder|terminalToken|\bpan\b/i)
    assert.doesNotMatch(source, /createCustomer|linkCustomer|updateCustomer|customerId|clientId|accountId/i)
    assert.doesNotMatch(source, /refund|partial|overpay|amountTendered|changeDue|\beft\b/i)
  }
  assert.doesNotMatch(lib, /\bfetch\s*\(|\brpc\s*\(|supabaseApi|localStorage/)
  assert.doesNotMatch(page, /beginQuickSolutionPayment|getQuickSolutionPaymentStatus|sendQuickSolutionOrderToOpps|saveQuickSolution|createQuickSolutionServiceRequest|createQuickSolutionCartOrder|adminIssue|createQuickSolutionOrder\b/)
  assert.equal((page.match(/recordQuickSolutionCounterPayment/g) || []).length, 2, 'imported once, used once')
  const users = []
  const walk = (dir) => {
    for (const item of fs.readdirSync(dir, { withFileTypes: true })) {
      const next = new URL(`${item.name}${item.isDirectory() ? '/' : ''}`, dir)
      if (item.isDirectory()) walk(next)
      else if (/\.jsx?$/.test(item.name) && /recordQuickSolutionCounterPayment|record_quick_solution_counter_payment/.test(fs.readFileSync(next, 'utf8'))) users.push(item.name)
    }
  }
  walk(new URL('../src/', import.meta.url))
  assert.deepEqual(users.sort(), ['CounterPage.jsx', 'supabaseApi.js'])
})

test('the amount is never the client’s: no amount state, input or argument exists on the payment path', () => {
  const lib = stripComments(read('../src/lib/counterPayment.js'))
  assert.doesNotMatch(lib.slice(lib.indexOf('export async function submitPayment'), lib.indexOf('export function resumePaymentAfterSignIn')).split('record(')[1].split(')')[0], /amount|total|price/i)
  assert.doesNotMatch(stripComments(read('../src/counter/CounterView.jsx')), /type="number"[^>]*amount|amountInput|setAmount|tendered/i)
})

test('the new test file and the SQL contract tests are part of npm test and the harness', () => {
  assert.match(JSON.parse(read('../package.json')).scripts.test, /tests\/counter-payment\.test\.mjs/)
  for (const name of ['cafe_guest_01q_counter_order_payment.sql', 'cafe_guest_01q_counter_payment_concurrency.sql']) assert.ok(fs.existsSync(new URL(`../supabase/tests/${name}`, import.meta.url)), name)
})
