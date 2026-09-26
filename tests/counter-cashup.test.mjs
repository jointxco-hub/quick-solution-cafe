import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'
import { loadCounterUi } from './helpers/counter-ui-harness.mjs'
import { products as seedProducts } from '../src/data/products.js'
import { formatMoney } from '../src/lib/pricing.js'
import { loadCounterCatalogueState } from '../src/lib/counterDraft.js'
import { describeCounterCashup, formatBusinessDate, loadCounterCashupState } from '../src/lib/counterCashup.js'

// CAFE-GUEST-01S - today's cash-up, read-only. The API is never real: a fake `load` stands in for the server and the screens are
// the real components rendered to HTML (tests/helpers/counter-ui-harness.mjs). Which payments count, the business day and every
// total are proven on real PostgreSQL in supabase/tests/cafe_guest_01s_counter_cashup_today.sql; here the UI must show exactly what
// it is given - and offer no way to change it.

const read = (path) => fs.readFileSync(new URL(path, import.meta.url), 'utf8')
const stripComments = (text) => text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:'"`])\/\/[^\n]*/g, '$1')
const ui = await loadCounterUi()
const h = ui.React.createElement
const html = (element) => ui.renderToStaticMarkup(element)
const serverProducts = seedProducts.filter((product) => product.channels?.pos === true)
const ready = await loadCounterCatalogueState(async () => ({ tenant: { slug: 'quick-solution', name: 'Quick Solution' }, products: serverProducts }))
const money = (value) => formatMoney(value).replace(/\s/g, '\\s')
const text = (markup) => markup.replace(/<[^>]+>/g, ' ').replace(/&amp;/g, '&').replace(/\s+/g, ' ')
const httpError = (message, status, code) => Object.assign(new Error(message), { status, payload: code ? { code } : null })

const payment = (n, orderNumber, customer, method, amount, paidAt, orderCreatedAt = paidAt, orderTotal = amount) => ({
  paymentId: 'pay-' + n, orderId: 'ord-' + n, orderNumber, customerName: customer, method, amount, paidAt, orderTotal, orderCreatedAt
})
const unpaidOrder = (n, orderNumber, product, config, total, outstanding = total) => ({
  orderId: 'unp-' + n, orderNumber, createdAt: '2026-09-26T09:00:00Z', status: 'submitted', paymentStatus: 'unpaid', customerName: 'Walk-in', customerEmail: null, customerPhone: null,
  totalAmount: total, outstanding, items: [{ productKey: product, productName: product === 'scan' ? 'Document Scanning' : 'A4 Lamination', quantity: 1, configuration: config, lineTotal: total }]
})
// exactly the shape get_quick_solution_counter_cashup_today returns
const summary = (overrides = {}) => ({
  businessDate: '2026-09-26',
  timezone: 'Africa/Johannesburg',
  orders: { createdToday: 6, paidToday: 3, unpaidToday: 2 },
  takings: { cash: { count: 2, amount: 55 }, card: { count: 1, amount: 72 }, total: { count: 3, amount: 127 } },
  otherMethods: { count: 0, amount: 0 },
  unpaid: { count: 2, amount: 75, orders: [unpaidOrder(1, 'QS-260926-U1', 'scan', { units: 3 }, 15), unpaidOrder(2, 'QS-260926-U2', 'a4-lamination', { units: 4 }, 60)] },
  payments: [
    payment(3, 'QS-260926-P3', 'Sipho', 'card', 72, '2026-09-26T11:30:00Z'),
    payment(2, 'QS-260926-P2', 'Walk-in', 'cash', 20, '2026-09-26T10:00:00Z', '2026-09-25T15:00:00Z'),
    payment(1, 'QS-260926-P1', 'Thandi Nkosi', 'cash', 35, '2026-09-26T09:15:00Z')
  ],
  ...overrides
})
const emptySummary = () => summary({ orders: { createdToday: 0, paidToday: 0, unpaidToday: 0 }, takings: { cash: { count: 0, amount: 0 }, card: { count: 0, amount: 0 }, total: { count: 0, amount: 0 } }, unpaid: { count: 0, amount: 0, orders: [] }, payments: [] })

const cashupScreen = (state, extra = {}) => html(h(ui.CounterView, { state: ready, view: 'cashup', cashup: state, ...extra }))
const readyState = (data = summary()) => ({ status: 'ready', summary: data })
const buttonsOf = (markup) => [...markup.matchAll(/<button[^>]*>([\s\S]*?)<\/button>/g)].map((match) => match[1].replace(/<[^>]+>/g, ''))
const section = (markup) => markup.slice(markup.indexOf('class="qsc-cashup"'))

// ── the tab and the server call ─────────────────────────────────────────
test('the Cash-up tab exists beside New sale and Today’s orders and is the active view when chosen', () => {
  const sale = html(h(ui.CounterView, { state: ready }))
  assert.match(sale, /<button[^>]*>New sale<\/button>/)
  assert.match(sale, /<button[^>]*>Today’s orders<\/button>/)
  assert.match(sale, /<button[^>]*>Cash-up<\/button>/)
  assert.doesNotMatch(sale, /<button[^>]*(hidden|disabled)[^>]*>Cash-up/, 'the tab is visible and usable')
  const view = cashupScreen(readyState())
  assert.match(view, /aria-current="page"[^>]*>Cash-up/)
  assert.match(view, /<h2>Today’s cash-up<\/h2>/)
  assert.match(view, /Counter · Today/)
  assert.match(view, new RegExp(formatBusinessDate('2026-09-26')), 'the day is shown')
  assert.doesNotMatch(view, /data-product-id=/, 'the sale screen is not shown')
})

test('the cash-up loads only from its server RPC: no argument, no local or static source', async () => {
  const api = read('../src/lib/supabaseApi.js')
  assert.match(api.match(/export async function loadQuickSolutionCounterCashupToday\(\) \{[\s\S]*?\n\}/)[0], /return rpc\('get_quick_solution_counter_cashup_today', \{\}, \{ accessToken \}\)/)
  const page = stripComments(read('../src/counter/CounterPage.jsx'))
  assert.match(page, /loadCounterCashupState\(date \? \(\) => loadQuickSolutionCounterCashup\(date\) : loadQuickSolutionCounterCashupToday\)/, 'today by default; a chosen day only sends its calendar date')
  assert.match(page, /const showView = \(next\) => \{[\s\S]*?if \(next === 'cashup'\) \{\s*\n\s*setCashupDate\(null\)\s*\n\s*loadCashup\(null\)/, 'opening the tab always starts on Today')
  assert.match(page, /onRefreshCashup=\{\(\) => loadCashup\(cashupDate\)\}/)
  for (const file of ['../src/counter/CounterPage.jsx', '../src/counter/CounterView.jsx', '../src/lib/counterCashup.js']) {
    assert.doesNotMatch(stripComments(read(file)), /localStorage|sessionStorage|indexedDB|data\/products|catalogStore|orderHistory/i, file)
  }
  const calls = []
  const state = await loadCounterCashupState(async (...args) => { calls.push(args); return summary() })
  assert.deepEqual(calls, [[]])
  assert.equal(state.status, 'ready')
  assert.deepEqual(state.summary, summary(), 'exactly what the server sent')
})

// ── states ──────────────────────────────────────────────────────────────
test('loading, error, denied, unavailable and signed-out states show the server’s word and never figures', async () => {
  assert.match(cashupScreen({ status: 'loading' }), /Loading today’s cash-up…/)
  const fail = (message, extra = {}) => loadCounterCashupState(async () => { throw Object.assign(new Error(message), extra) })
  const network = await fail('Failed to fetch')
  assert.equal(network.status, 'error')
  assert.match(cashupScreen(network), /Could not load the cash-up[\s\S]*Failed to fetch[\s\S]*Try again/)
  const denied = await fail('You do not have access to the Quick Solution counter.', { status: 403, payload: { code: '42501' } })
  assert.match(cashupScreen(denied), /No counter access[\s\S]*You do not have access/)
  assert.match(cashupScreen(await fail('Quick Solution counter is not active.', { status: 400 })), /Counter unavailable/)
  assert.match(cashupScreen(await fail('Staff sign-in is required.')), /Sign in to see the cash-up[\s\S]*Your sale in progress is kept/)
  for (const state of [network, denied]) assert.doesNotMatch(cashupScreen(state), /qsc-takings|Total taken/)
  assert.equal((await loadCounterCashupState(async () => null)).status, 'error')
  assert.equal((await loadCounterCashupState(async () => ({ takings: {} }))).status, 'error')
})

test('a day with no sales is an empty state; a day with only unpaid orders is a normal day with zero takings', async () => {
  const empty = await loadCounterCashupState(async () => emptySummary())
  assert.equal(empty.status, 'empty')
  const markup = cashupScreen(empty)
  assert.match(markup, /No counter sales yet today\./)
  assert.doesNotMatch(markup, /qsc-takings/)
  const onlyUnpaid = await loadCounterCashupState(async () => summary({ orders: { createdToday: 2, paidToday: 0, unpaidToday: 2 }, takings: { cash: { count: 0, amount: 0 }, card: { count: 0, amount: 0 }, total: { count: 0, amount: 0 } }, payments: [] }))
  assert.equal(onlyUnpaid.status, 'ready')
  const view = text(cashupScreen(onlyUnpaid))
  assert.match(view, new RegExp(`Total taken ${money(0)} 0 payments`))
  assert.match(view, /No cash or card payments yet today\./)
  assert.match(view, /Unpaid today/)
})

// ── figures ─────────────────────────────────────────────────────────────
test('Cash, Card and Total taken show the server’s amounts and payment counts', () => {
  const view = text(cashupScreen(readyState()))
  assert.match(view, new RegExp(`Cash ${money(55)} 2 payments`))
  assert.match(view, new RegExp(`Card ${money(72)} 1 payment(?!s)`))
  assert.match(view, new RegExp(`Total taken ${money(127)} 3 payments`))
  const described = describeCounterCashup(summary())
  assert.equal(described.cash.amount, formatMoney(55))
  assert.equal(described.total.amount, formatMoney(127))
  assert.equal(described.consistent, true)
  // money is formatted by the one Rand formatter and nothing is recalculated on the client
  const lib = stripComments(read('../src/lib/counterCashup.js'))
  assert.match(lib, /import \{ formatMoney \} from '\.\/pricing\.js'/)
  assert.doesNotMatch(lib, /toFixed|NumberFormat|toLocale/)
  assert.doesNotMatch(lib.replace(/rowSum[^\n]*\n/g, ''), /\+ card|cash\.amount \+|sum \+/, 'no client-side total is ever shown')
})

test('paid and unpaid order counts, and what is outstanding, are shown apart from the takings', () => {
  const markup = cashupScreen(readyState())
  const view = text(markup)
  assert.match(view, /Orders today 6/)
  assert.match(view, /Orders paid today 3/)
  assert.match(view, /Unpaid orders 2/)
  assert.match(view, new RegExp(`Outstanding today ${money(75)}`))
  // the unpaid figures are in their own, differently styled tiles and are not part of the taken tiles
  const takings = markup.slice(markup.indexOf('aria-label="Taken today"'), markup.indexOf('qsc-cashup-facts'))
  assert.doesNotMatch(takings, new RegExp(money(75)), 'outstanding is not in the takings block')
  assert.equal((markup.match(/qsc-cashup-unpaid/g) || []).length, 2)
  assert.ok(markup.indexOf('Total taken') < markup.indexOf('Outstanding today'), 'takings first, outstanding after')
  assert.match(markup, /Unpaid today <small>not money received<\/small>/)
})

test('the reconciliation list shows each payment: order, customer, method, amount, time, and an order made on an earlier day', () => {
  const markup = cashupScreen(readyState())
  const list = markup.slice(markup.indexOf('Payments taken today'), markup.indexOf('Unpaid today'))
  const view = text(list)
  assert.equal((list.match(/<li /g) || []).length, 3)
  assert.ok(list.indexOf('QS-260926-P3') < list.indexOf('QS-260926-P2') && list.indexOf('QS-260926-P2') < list.indexOf('QS-260926-P1'), 'the server order (newest first) is kept')
  assert.match(view, new RegExp(`QS-260926-P3 13:30 Sipho ${money(72)} Card`))
  assert.match(view, new RegExp(`QS-260926-P2 12:00 Walk-in Ordered 25 Sep\\w* 2026 ${money(20)} Cash`), 'made yesterday, paid today: still today’s money, and it says so')
  assert.match(view, new RegExp(`QS-260926-P1 11:15 Thandi Nkosi ${money(35)} Cash`))
  assert.doesNotMatch(text(list.slice(list.indexOf('QS-260926-P1'))), /Ordered 26/, 'no earlier-day note for an order made today')
  const rows = describeCounterCashup(summary()).payments
  assert.deepEqual(rows.map((row) => [row.orderNumber, row.methodLabel, row.orderedEarlier]), [['QS-260926-P3', 'Card', false], ['QS-260926-P2', 'Cash', true], ['QS-260926-P1', 'Cash', false]])
})

test('other-method payments are shown apart and only when there are some', () => {
  assert.doesNotMatch(cashupScreen(readyState()), /Other payments not included above/)
  const markup = cashupScreen(readyState(summary({ otherMethods: { count: 1, amount: 10 } })))
  assert.match(text(markup), new RegExp(`Other payments not included above: 1 · ${money(10)}`))
})

test('if the totals ever disagree with the listed payments the screen says so instead of hiding it', () => {
  const bad = summary({ takings: { cash: { count: 2, amount: 55 }, card: { count: 1, amount: 72 }, total: { count: 3, amount: 999 } } })
  assert.equal(describeCounterCashup(bad).consistent, false)
  assert.match(cashupScreen(readyState(bad)), /The totals do not match the listed payments\. Refresh before relying on them\./)
  assert.doesNotMatch(cashupScreen(readyState()), /do not match/)
})

// ── drill-through ───────────────────────────────────────────────────────
test('a payment or unpaid row opens the existing order detail, and Back returns to the cash-up', () => {
  const markup = cashupScreen(readyState())
  assert.match(markup, /<button[^>]*aria-label="Open order QS-260926-P1"/)
  assert.match(markup, /<button[^>]*aria-label="Open order QS-260926-U1"/)
  const page = stripComments(read('../src/counter/CounterPage.jsx'))
  assert.match(page, /const openOrder = \(orderId, origin = 'orders'\) => \{[\s\S]*?setOrderOrigin\(origin\)[\s\S]*?loadDetail\(orderId\)/, 'the same order-detail flow as Today’s orders')
  assert.match(page, /if \(orderOrigin === 'cashup'\) \{\s*\n\s*setView\('cashup'\)\s*\n\s*loadCashup\(cashupDate\)/, 'Back returns to the same date')
  const view = stripComments(read('../src/counter/CounterView.jsx'))
  assert.match(view, /onOpenOrder\?\.\(orderId, 'cashup'\)/)
  const detail = html(h(ui.CounterView, { state: ready, view: 'order', orderOrigin: 'cashup', orderDetail: { status: 'loading' } }))
  assert.match(detail, /← Cash-up/)
  assert.match(detail, /aria-current="page"[^>]*>Cash-up/)
  assert.match(html(h(ui.CounterView, { state: ready, view: 'order', orderDetail: { status: 'loading' } })), /← Today’s orders/, 'from Today’s orders nothing changed')
  // no second detail implementation
  assert.equal((view.match(/function OrderDetailPanel/g) || []).length, 1)
})

test('manual refresh reads the server again; while it runs the button is disabled and the figures stay', async () => {
  const answers = [summary(), summary({ takings: { cash: { count: 3, amount: 80 }, card: { count: 1, amount: 72 }, total: { count: 4, amount: 152 } } })]
  let n = 0
  const load = async () => answers[n++]
  const first = await loadCounterCashupState(load)
  const second = await loadCounterCashupState(load)
  assert.equal(describeCounterCashup(first.summary).total.amount, formatMoney(127))
  assert.equal(describeCounterCashup(second.summary).total.amount, formatMoney(152))
  assert.match(cashupScreen(first), /<button[^>]*>Refresh<\/button>/)
  const refreshing = cashupScreen({ ...first, refreshing: true })
  assert.match(refreshing, /<button[^>]*disabled=""[^>]*>Refreshing…<\/button>/)
  assert.match(text(refreshing), new RegExp(`Total taken ${money(127)}`))
})

// ── read-only ───────────────────────────────────────────────────────────
test('there is no close-till, float, expected/counted cash, adjustment, refund, void, payout or payment action', () => {
  const markup = cashupScreen(readyState(summary({ otherMethods: { count: 1, amount: 10 } })))
  const own = section(markup)
  assert.deepEqual(buttonsOf(own).filter((label) => !/^QS-/.test(label)), ['Refresh', '← Previous day', 'Next day →', 'Today'], 'Refresh and the date controls (01U); the rest are Open-order buttons')
  assert.doesNotMatch(own.replace(/<input type="date"[^>]*>/, ''), /<input|<select|<textarea|type="number"/i, 'the only field is the date')
  assert.doesNotMatch(text(own), /Close till|Submit cash-up|Opening float|Float|Expected|Counted|Adjust|Payout|Expense|Refund|Void|Record (Cash|Card) Payment|EFT|Edit/i)
  const source = stripComments(read('../src/lib/counterCashup.js') + read('../src/counter/CounterView.jsx').slice(read('../src/counter/CounterView.jsx').indexOf('function CashupPanel'), read('../src/counter/CounterView.jsx').indexOf('export default function CounterView')))
  assert.doesNotMatch(source, /closeTill|closeShift|submitCashup|openingFloat|\bfloat\b|expectedCash|countedCash|adjust|payout|refund|voidOrder|\beft\b|recordQuickSolution|createQuickSolution/i)
})

test('no new write: one extra read call, the same two writes as before, and a STABLE server function', () => {
  const page = read('../src/counter/CounterPage.jsx')
  const imported = page.match(/import \{([^}]*)\} from '\.\.\/lib\/supabaseApi\.js'/)[1].split(',').map((name) => name.trim()).filter(Boolean)
  assert.deepEqual(imported, ['cancelQuickSolutionCounterOrder', 'createQuickSolutionCounterOrder', 'getAdminSession', 'loadQuickSolutionCancelledCounterOrders', 'loadQuickSolutionCounterCashup', 'loadQuickSolutionCounterCashupToday', 'loadQuickSolutionCounterCatalog', 'loadQuickSolutionCounterOrder', 'loadQuickSolutionCounterOrderCancelCheck', 'loadQuickSolutionCounterOrdersToday', 'loadQuickSolutionUnpaidCounterOrders', 'recordQuickSolutionCounterPayment', 'signInAdmin', 'signOutAdmin'])
  assert.doesNotMatch(stripComments(read('../src/lib/counterCashup.js')), /supabaseApi|\bfetch\s*\(|\brpc\s*\(/)
  const sql = stripComments(read('../supabase/migrations/20260926250000_cafe_guest_01s_counter_cashup_today_rpc.sql').replace(/--[^\n]*/g, ''))
  assert.match(sql, /language plpgsql\s*\nstable\s*\nsecurity definer/)
  assert.doesNotMatch(sql, /insert into|update commerce|update public|delete from/i)
  assert.match(sql, /p\.completed_at >= v_day\.day_start/)
  assert.match(sql, /_qs_counter_business_day\(now\(\)\)/)
  assert.match(sql, /pay\.provider in \('cash', 'card'\)/)
})

test('the new test file and the SQL contract test are part of npm test and the harness', () => {
  assert.match(JSON.parse(read('../package.json')).scripts.test, /tests\/counter-cashup\.test\.mjs/)
  assert.ok(fs.existsSync(new URL('../supabase/tests/cafe_guest_01s_counter_cashup_today.sql', import.meta.url)))
})
