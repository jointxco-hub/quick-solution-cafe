import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'
import { loadCounterUi } from './helpers/counter-ui-harness.mjs'
import { products as seedProducts } from '../src/data/products.js'
import { formatMoney } from '../src/lib/pricing.js'
import { createCounterDraft, loadCounterCatalogueState, setCounterDraftValue } from '../src/lib/counterDraft.js'
import {
  COUNTER_ORDERS_TIMEZONE,
  counterPaymentLabel,
  counterStatusLabel,
  describeCounterOrder,
  formatCounterOrderTime,
  loadCounterOrdersState
} from '../src/lib/counterOrders.js'
import { SALE_PHASES, beginSubmit, initialSale, reviewSale, submitSale } from '../src/lib/counterSale.js'

// CAFE-GUEST-01P - Today's Counter Orders, read-only. The API is never real: a fake `list` stands in for the
// server, and the screens are the real components rendered to HTML (tests/helpers/counter-ui-harness.mjs).
// Which orders belong to "today", the counter channel and the Cafe tenant is proven on real PostgreSQL in
// supabase/tests/cafe_guest_01p_counter_orders_today_rpc.sql; here the UI must show exactly what it is given.

const read = (path) => fs.readFileSync(new URL(path, import.meta.url), 'utf8')
const stripComments = (text) => text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:'"`])\/\/[^\n]*/g, '$1')
const ui = await loadCounterUi()
const h = ui.React.createElement
const html = (element) => ui.renderToStaticMarkup(element)

const byId = new Map(seedProducts.map((product) => [product.id, product]))
const serverProducts = seedProducts.filter((product) => product.channels?.pos === true)
const ready = await loadCounterCatalogueState(async () => ({ tenant: { slug: 'quick-solution', name: 'Quick Solution' }, products: serverProducts }))

// An order exactly as the server RPC returns it.
const serverOrder = (overrides = {}) => ({
  orderId: 'b1f0c0de-0000-4000-8000-000000000001',
  orderNumber: 'QS-260926-AB12',
  createdAt: '2026-09-26T11:05:00+00:00',
  status: 'submitted',
  paymentStatus: 'unpaid',
  customerName: 'Walk-in',
  customerEmail: null,
  customerPhone: null,
  totalAmount: 35,
  items: [{ productKey: 'scan', productName: 'Document Scanning', quantity: 1, configuration: { units: 7 }, lineTotal: 35 }],
  ...overrides
})
const listResponse = (orders) => ({ businessDate: '2026-09-26', timezone: 'Africa/Johannesburg', orders })

function ordersScreen(orders, extra = {}) {
  return html(h(ui.CounterView, { state: ready, view: 'orders', orders, sale: initialSale(), ...extra }))
}
const buttonsOf = (markup) => [...markup.matchAll(/<button[^>]*>([\s\S]*?)<\/button>/g)].map((match) => match[1].replace(/<[^>]+>/g, ''))
const listSection = (markup) => markup.slice(markup.indexOf('class="qsc-order-list'), markup.indexOf('</ul>', markup.indexOf('class="qsc-order-list')))
const httpError = (message, status, code) => Object.assign(new Error(message), { status, payload: code ? { code } : null })

// ── the read call ───────────────────────────────────────────────────────
test('the client wrapper sends no argument: no tenant, channel, creator or date can be supplied', () => {
  const api = read('../src/lib/supabaseApi.js')
  const wrapper = api.match(/export async function loadQuickSolutionCounterOrdersToday\(\) \{[\s\S]*?\n\}/)[0]
  assert.match(wrapper, /return rpc\('list_quick_solution_counter_orders_today', \{\}, \{ accessToken \}\)/)
  assert.doesNotMatch(wrapper.replace(/loadQuickSolutionCounterOrdersToday|list_quick_solution_counter_orders_today/g, ''), /tenant|channel|created|date|day|limit|filter|storefront/i)
})

test('the orders come from that one server call and are never remembered or invented on the client', async () => {
  const page = stripComments(read('../src/counter/CounterPage.jsx'))
  assert.match(page, /loadCounterOrdersState\(loadQuickSolutionCounterOrdersToday\)/)
  for (const file of ['../src/counter/CounterPage.jsx', '../src/counter/CounterView.jsx', '../src/lib/counterOrders.js']) {
    assert.doesNotMatch(stripComments(read(file)), /localStorage|sessionStorage|indexedDB|data\/products|catalogStore|orderHistory|cachedOrders|idempotency|created_by|source_metadata/i, file)
  }
  // the sale flow never writes to the list: a created order only shows up after the server is asked again
  const submitBody = page.slice(page.indexOf('const submit = async'), page.indexOf('const signIn = async'))
  assert.ok(submitBody.length > 100)
  assert.doesNotMatch(submitBody, /setOrders|loadOrders/)
  assert.equal((page.match(/setOrders\(/g) || []).length, 3, 'set only from loading markers and the server answer')
  const calls = []
  const state = await loadCounterOrdersState(async (...args) => { calls.push(args); return listResponse([serverOrder()]) })
  assert.deepEqual(calls, [[]], 'one call, no argument')
  assert.equal(state.status, 'ready')
  assert.deepEqual(state.orders, [serverOrder()], 'exactly what the server sent, in the server order')
})

// ── states ──────────────────────────────────────────────────────────────
test('the Today section exists next to New sale, and New sale is the default view', () => {
  const sale = html(h(ui.CounterView, { state: ready }))
  assert.match(sale, /New sale/)
  assert.match(sale, /Today’s orders/)
  assert.match(sale, /aria-current="page"[^>]*>New sale/)
  assert.match(sale, /data-product-id="scan"/, 'the sale view is untouched')
  const orders = ordersScreen({ status: 'ready', businessDate: '2026-09-26', orders: [serverOrder()] })
  assert.match(orders, /<h2>Today’s orders<\/h2>/)
  assert.match(orders, /aria-current="page"[^>]*>Today’s orders/)
  assert.doesNotMatch(orders, /data-product-id=/, 'the product list is not shown in the orders view')
  assert.match(orders, /Counter · 2026-09-26/)
})

test('loading state', () => {
  const markup = ordersScreen({ status: 'loading' })
  assert.match(markup, /Loading today’s orders…/)
  assert.doesNotMatch(markup, /qsc-order-list/)
  assert.match(markup, /<button[^>]*disabled=""[^>]*>Refreshing…<\/button>/)
})

test('error, denied, unavailable and signed-out states show the server’s word and never a local list', async () => {
  const fail = (message, extra = {}) => loadCounterOrdersState(async () => { throw Object.assign(new Error(message), extra) })
  const network = await fail('Failed to fetch')
  assert.equal(network.status, 'error')
  const errorMarkup = ordersScreen(network)
  assert.match(errorMarkup, /Could not load today’s orders/)
  assert.match(errorMarkup, /Failed to fetch/)
  assert.match(errorMarkup, /<button[^>]*>Try again<\/button>/)
  const denied = await fail('You do not have access to the Quick Solution counter.', { status: 403, payload: { code: '42501' } })
  assert.equal(denied.status, 'denied')
  assert.match(ordersScreen(denied), /No counter access[\s\S]*You do not have access to the Quick Solution counter\./)
  const inactive = await fail('Quick Solution counter is not active.', { status: 400, payload: { code: '22023' } })
  assert.equal(inactive.status, 'unavailable')
  assert.match(ordersScreen(inactive), /Counter unavailable[\s\S]*not active/)
  const signedOut = await fail('Staff sign-in is required.')
  assert.equal(signedOut.status, 'signed-out')
  assert.match(ordersScreen(signedOut), /Sign in to see today’s orders[\s\S]*Your sale in progress is kept/)
  for (const state of [network, denied, inactive, signedOut]) assert.doesNotMatch(ordersScreen(state), /qsc-order-list|QS-\d/)
  assert.equal((await loadCounterOrdersState(async () => null)).status, 'error')
  assert.equal((await loadCounterOrdersState(async () => ({ orders: 'nope' }))).status, 'error')
})

test('empty state', async () => {
  const state = await loadCounterOrdersState(async () => listResponse([]))
  assert.equal(state.status, 'empty')
  const markup = ordersScreen(state)
  assert.match(markup, /No counter orders yet today\./)
  assert.doesNotMatch(markup, /qsc-order-list/)
})

// ── rows ────────────────────────────────────────────────────────────────
test('an order row shows number, time, customer, product, total and payment status', () => {
  const orders = [
    serverOrder({ customerName: 'Thandi Nkosi', customerPhone: '0751234567', customerEmail: 'thandi@example.com' }),
    serverOrder({ orderId: 'b1f0c0de-0000-4000-8000-000000000002', orderNumber: 'QS-260926-CD34', createdAt: '2026-09-26T09:30:00+00:00', totalAmount: 72,
      items: [{ productKey: 'a4-print', productName: 'Document Printing', quantity: 1, configuration: { pages: 12, copies: 3, printMode: 'bw', sides: 'single', finish: 'none', documentInstructions: [{ selection: 'all', sourcePages: 12 }], documentPlanValid: true }, lineTotal: 72 }] })
  ]
  const markup = ordersScreen({ status: 'ready', businessDate: '2026-09-26', orders })
  const list = listSection(markup)
  assert.equal((list.match(/<li /g) || []).length, 2)
  assert.ok(list.indexOf('QS-260926-AB12') < list.indexOf('QS-260926-CD34'), 'the server order is kept (newest first)')
  const first = list.slice(0, list.indexOf('QS-260926-CD34'))
  assert.match(first, /QS-260926-AB12/)
  assert.match(first, /13:05/, 'the time is shown in the Cafe’s zone (UTC+2)')
  assert.match(first, /Document Scanning<small> · 7 pages<\/small>/)
  assert.match(first, /Thandi Nkosi · 0751234567 · thandi@example\.com/)
  assert.match(first, new RegExp(formatMoney(35).replace(/\s/g, '\\s')))
  assert.match(first, /qsc-state qsc-state-unpaid">Unpaid</)
  assert.match(first, /Submitted/)
  const second = list.slice(list.indexOf('QS-260926-CD34'))
  assert.match(second, /11:30/)
  assert.match(second, /Document Printing<small> · 12 pages × 3 copies<\/small>/)
  assert.match(second, />Walk-in</)
  assert.match(second, new RegExp(formatMoney(72).replace(/\s/g, '\\s')))
})

test('an unpaid order says Unpaid, and only what the server reported is labelled', () => {
  assert.equal(counterPaymentLabel('unpaid'), 'Unpaid')
  assert.equal(counterStatusLabel('submitted'), 'Submitted')
  assert.equal(describeCounterOrder(serverOrder()).paymentLabel, 'Unpaid')
  assert.doesNotMatch(listSection(ordersScreen({ status: 'ready', orders: [serverOrder()] })), /Paid|Pay /)
  assert.equal(describeCounterOrder(serverOrder({ paymentStatus: 'refunded' })).paymentLabel, 'Refunded', 'anything else is shown as reported')
})

test('times are the Cafe business zone, not UTC or the browser', () => {
  assert.equal(COUNTER_ORDERS_TIMEZONE, 'Africa/Johannesburg')
  assert.equal(formatCounterOrderTime('2026-09-26T21:59:00Z'), '23:59')
  assert.equal(formatCounterOrderTime('2026-09-26T22:00:00Z'), '00:00', 'UTC 22:00 is local midnight')
  assert.equal(formatCounterOrderTime('2026-09-26T23:30:00Z'), '01:30')
  assert.equal(formatCounterOrderTime('nonsense'), '—')
})

test('the row shape already handles more than one item and an item of an unknown product', () => {
  const two = serverOrder({ items: [
    { productKey: 'scan', productName: 'Document Scanning', quantity: 1, configuration: { units: 2 }, lineTotal: 10 },
    { productKey: 'retired-thing', productName: 'Retired Thing', quantity: 1, configuration: {}, lineTotal: 5 }
  ] })
  const row = describeCounterOrder(two, ready.entries)
  assert.deepEqual(row.items, [{ name: 'Document Scanning', detail: '2 pages' }, { name: 'Retired Thing', detail: null }])
  const markup = listSection(ordersScreen({ status: 'ready', orders: [two] }))
  assert.match(markup, /Document Scanning[\s\S]*Retired Thing/)
  assert.match(listSection(ordersScreen({ status: 'ready', orders: [serverOrder({ items: [] })] })), /No items/)
})

// ── the server decides what belongs in the list ─────────────────────────
test('the UI cannot ask for a storefront order or another day: it shows what the server returns, unfiltered', async () => {
  const calls = []
  const state = await loadCounterOrdersState(async (...args) => { calls.push(args); return listResponse([serverOrder({ orderNumber: 'QS-COUNTER-1' })]) })
  assert.deepEqual(calls, [[]])
  assert.deepEqual(state.orders.map((order) => order.orderNumber), ['QS-COUNTER-1'])
  assert.doesNotMatch(stripComments(read('../src/lib/counterOrders.js')), /\.sort\(|channel|storefront|orders\.filter/i, 'no client-side filtering, sorting or channel rule')
})

// ── read-only ───────────────────────────────────────────────────────────
test('rows only OPEN an order (01Q): no payment, edit, void, duplicate, receipt, resend or production control is on the list', () => {
  const markup = ordersScreen({ status: 'ready', businessDate: '2026-09-26', orders: [serverOrder(), serverOrder({ orderNumber: 'QS-2' })] })
  const list = listSection(markup)
  assert.doesNotMatch(list, /<a |<input|<select|<textarea|onclick/i)
  assert.equal((list.match(/<button/g) || []).length, 2, 'one open button per row, nothing else')
  assert.match(list, /aria-label="Open order QS-260926-AB12"/)
  assert.deepEqual(buttonsOf(markup).filter((text) => !/^QS-/.test(text)), ['Sign out', 'New sale', 'Today’s orders', 'Unpaid', 'Cash-up', 'Refresh'])
  const source = stripComments(read('../src/counter/CounterView.jsx') + read('../src/lib/counterOrders.js'))
  assert.doesNotMatch(source, /\bvoid\b|duplicate|resend|reprint|cancelOrder|editOrder|markPaid|handoff|startProduction|sendToProduction/i)
  assert.doesNotMatch(list, /Pay now|Record|Void|Edit|Duplicate|Receipt|Resend|Cancel order|Cash|Card/i)
})

test('there is no write and no polling: the list is read on open and on Refresh only', () => {
  const page = stripComments(read('../src/counter/CounterPage.jsx'))
  assert.doesNotMatch(page + stripComments(read('../src/counter/CounterView.jsx')) + stripComments(read('../src/lib/counterOrders.js')), /setInterval|setTimeout|requestPolling|EventSource|WebSocket|visibilitychange|addEventListener/)
  assert.match(page, /const showView = \(next\) => \{\s*\n\s*setView\(next\)\s*\n\s*if \(next === 'orders'\) loadOrders\(\)/)
  assert.match(page, /onRefreshOrders=\{loadOrders\}/)
  assert.equal((page.match(/createQuickSolutionCounterOrder/g) || []).length, 2, 'the one create call is unchanged')
  assert.doesNotMatch(stripComments(read('../src/lib/counterOrders.js')), /createQuickSolution|fetch\(|rpc\(/)
})

test('manual refresh asks the server again and shows the new answer; while it runs the button is disabled and the rows stay', async () => {
  const answers = [listResponse([serverOrder()]), listResponse([serverOrder({ orderNumber: 'QS-260926-NEW1', createdAt: '2026-09-26T12:00:00+00:00' }), serverOrder()])]
  let n = 0
  const list = async () => answers[n++]
  const first = await loadCounterOrdersState(list)
  const second = await loadCounterOrdersState(list)
  assert.equal(first.orders.length, 1)
  assert.equal(second.orders.length, 2)
  assert.equal(second.orders[0].orderNumber, 'QS-260926-NEW1')
  const idle = ordersScreen(first)
  assert.match(idle, /<button[^>]*>Refresh<\/button>/)
  assert.doesNotMatch(idle, /<button[^>]*disabled=""[^>]*>Refresh/)
  const refreshing = ordersScreen({ ...first, refreshing: true })
  assert.match(refreshing, /<button[^>]*disabled=""[^>]*>Refreshing…<\/button>/)
  assert.match(refreshing, /QS-260926-AB12/, 'the rows stay visible while refreshing')
})

// ── how a created order gets in ─────────────────────────────────────────
test('an order created through the 01O flow appears only by asking the server again', async () => {
  const server = []
  const create = async (payload) => {
    const order = serverOrder({ orderId: `id-${server.length + 1}`, orderNumber: `QS-260926-N${server.length + 1}`, customerName: payload.customerName || 'Walk-in', totalAmount: 35,
      items: [{ productKey: payload.productKey, productName: byId.get(payload.productKey).name, quantity: 1, configuration: payload.configuration, lineTotal: 35 }] })
    server.unshift(order)
    return { ok: true, replayed: false, orderNumber: order.orderNumber, status: 'submitted', paymentStatus: 'unpaid', customerName: order.customerName, productName: order.items[0].productName, totalAmount: 35 }
  }
  const list = async () => listResponse(server)
  const before = await loadCounterOrdersState(list)
  assert.equal(before.status, 'empty')
  let draft = createCounterDraft(byId.get('scan'))
  draft = setCounterDraftValue(draft, byId.get('scan'), 'units', '7')
  const confirming = reviewSale(initialSale(), { entry: ready.entries.find((entry) => entry.product.id === 'scan'), draft, customer: { name: 'Thandi Nkosi' } }, () => 'key-00000001')
  const done = await submitSale(beginSubmit(confirming), create)
  assert.equal(done.phase, SALE_PHASES.SUCCESS)
  assert.equal(before.orders.length, 0, 'nothing was added locally by the sale')
  const after = await loadCounterOrdersState(list)
  assert.equal(after.status, 'ready')
  const row = describeCounterOrder(after.orders[0], ready.entries)
  assert.equal(row.orderNumber, done.result.orderNumber)
  assert.equal(row.customer, 'Thandi Nkosi')
  assert.equal(row.paymentLabel, 'Unpaid')
  assert.deepEqual(row.items, [{ name: 'Document Scanning', detail: '7 pages' }])
  assert.match(listSection(ordersScreen(after, {})), new RegExp(done.result.orderNumber))
})

// ── unknown-result interaction ──────────────────────────────────────────
test('an unconfirmed sale is neither cleared nor reconciled by the list: staff look, then retry safely', async () => {
  const confirming = reviewSale(initialSale(), { entry: ready.entries.find((entry) => entry.product.id === 'scan'), draft: setCounterDraftValue(createCounterDraft(byId.get('scan')), byId.get('scan'), 'units', '3'), customer: {} }, () => 'key-00000009')
  const unknown = await submitSale(beginSubmit(confirming), async () => { throw new TypeError('Failed to fetch') })
  assert.equal(unknown.phase, SALE_PHASES.UNKNOWN)
  // the list even contains an order that looks like it: the sale is still unknown, with the same key
  const withLookalike = await loadCounterOrdersState(async () => listResponse([serverOrder({ items: [{ productKey: 'scan', productName: 'Document Scanning', quantity: 1, configuration: { units: 3 }, lineTotal: 15 }] })]))
  assert.equal(withLookalike.status, 'ready')
  assert.equal(unknown.phase, SALE_PHASES.UNKNOWN)
  assert.equal(unknown.attempt.request.idempotencyKey, 'key-00000009')
  // the screen points the staff at the list and at the safe retry; the tab carries a marker
  const orders = ordersScreen(withLookalike, { sale: unknown })
  assert.match(orders, /A sale is waiting on an unconfirmed result[\s\S]*retry safely[\s\S]*cannot create a second order/)
  assert.match(orders, /class="qsc-dot"/)
  assert.doesNotMatch(ordersScreen(withLookalike), /waiting on an unconfirmed/)
  // and the sale view still offers the retry
  assert.match(html(h(ui.CounterView, { state: ready, sale: unknown, selectedId: 'scan' })), /Retry safely/)
  // nothing links the two: no automatic reconciliation
  assert.doesNotMatch(read('../src/lib/counterSale.js'), /counterOrders|listToday|Orders/)
  assert.doesNotMatch(stripComments(read('../src/lib/counterOrders.js')), /counterSale|attempt|idempotency|SALE_PHASES/)
  const page = stripComments(read('../src/counter/CounterPage.jsx'))
  const loadOrdersBody = page.slice(page.indexOf('const loadOrders = useCallback'), page.indexOf('const showView'))
  assert.doesNotMatch(loadOrdersBody, /setSale|sale\./, 'loading the list never touches the sale')
})

test('New sale stays usable from the list, and switching views keeps the sale', () => {
  const orders = ordersScreen({ status: 'ready', orders: [serverOrder()] })
  assert.match(orders, /<button[^>]*>New sale<\/button>/)
  const page = stripComments(read('../src/counter/CounterPage.jsx'))
  const showView = page.slice(page.indexOf('const showView'), page.indexOf('const selectedEntry'))
  assert.doesNotMatch(showView, /setSale|setDraft|setCustomer|setSelectedId/, 'changing view resets nothing')
  assert.match(page, /const \[view, setView\] = useState\('sale'\)/)
  assert.match(page, /setView\('sale'\)/)
})

test('the SQL contract test and this file are part of the harness and npm test', () => {
  const sql = read('../supabase/tests/cafe_guest_01p_counter_orders_today_rpc.sql')
  assert.match(sql, /^\\set ON_ERROR_STOP on\s*\n\s*begin;/m)
  assert.match(sql, /\brollback;\s*\nselect 'CAFE-GUEST-01P/)
  assert.doesNotMatch(sql, /^\s*commit\s*;/im)
  assert.match(JSON.parse(read('../package.json')).scripts.test, /tests\/counter-orders\.test\.mjs/)
})
