import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'
import { loadCounterUi } from './helpers/counter-ui-harness.mjs'
import { products as seedProducts } from '../src/data/products.js'
import { formatMoney } from '../src/lib/pricing.js'
import { loadCounterCatalogueState } from '../src/lib/counterDraft.js'
import { PAYMENT_PHASES, beginPayment, beginPaymentSubmit, initialPayment, submitPayment } from '../src/lib/counterPayment.js'
import { counterAgeLabel, describeCounterUnpaid, loadCounterUnpaidState } from '../src/lib/counterUnpaid.js'

// CAFE-GUEST-01T - unpaid counter orders across days, read-only. The API is never real: a fake `load` stands in for the server and
// the screens are the real components rendered to HTML (tests/helpers/counter-ui-harness.mjs). What still owes money, the age in
// Cafe business days and the oldest-first order are proven on real PostgreSQL in supabase/tests/cafe_guest_01t_unpaid_counter_orders.sql;
// here the UI must show exactly what it is given and offer no way to change it.

const read = (path) => fs.readFileSync(new URL(path, import.meta.url), 'utf8')
const stripComments = (text) => text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:'"`])\/\/[^\n]*/g, '$1')
const ui = await loadCounterUi()
const h = ui.React.createElement
const html = (element) => ui.renderToStaticMarkup(element)
const serverProducts = seedProducts.filter((product) => product.channels?.pos === true)
const ready = await loadCounterCatalogueState(async () => ({ tenant: { slug: 'quick-solution', name: 'Quick Solution' }, products: serverProducts }))
const money = (value) => formatMoney(value).replace(/\s/g, '\\s')
const text = (markup) => markup.replace(/<[^>]+>/g, ' ').replace(/&amp;/g, '&').replace(/\s+/g, ' ')

const order = (n, number, ageDays, createdAt, product, config, total, extra = {}) => ({
  orderId: 'ord-' + n, orderNumber: number, createdAt, orderDate: '2026-09-26', ageDays, status: 'submitted', paymentStatus: 'unpaid',
  customerName: 'Walk-in', customerEmail: null, customerPhone: null, totalAmount: total, amountPaid: 0, outstanding: total,
  items: [{ productKey: product, productName: product === 'scan' ? 'Document Scanning' : product === 'a4-lamination' ? 'A4 Lamination' : 'A3 Lamination', quantity: 1, configuration: config, lineTotal: total }], ...extra
})
// exactly the shape list_quick_solution_unpaid_counter_orders returns, oldest first
const summary = (overrides = {}) => {
  const orders = [
    order(3, 'QS-260923-OLD3', 3, '2026-09-23T08:10:00Z', 'a3-lamination', { units: 2 }, 60, { customerName: 'Sipho', customerPhone: '0821234567' }),
    order(2, 'QS-260925-YDAY', 1, '2026-09-25T21:59:59Z', 'a4-lamination', { units: 3 }, 45, { amountPaid: 15, outstanding: 30, totalAmount: 45 }),
    order(1, 'QS-260926-TODY', 0, '2026-09-26T09:30:00Z', 'scan', { units: 7 }, 35, { customerName: 'Thandi Nkosi' })
  ]
  return { businessDate: '2026-09-26', timezone: 'Africa/Johannesburg', count: 3, outstandingTotal: 125, orders, ...overrides }
}
const unpaidScreen = (state, extra = {}) => html(h(ui.CounterView, { state: ready, view: 'unpaid', unpaid: state, ...extra }))
const readyState = (data = summary()) => ({ status: 'ready', summary: data })
const buttonsOf = (markup) => [...markup.matchAll(/<button[^>]*>([\s\S]*?)<\/button>/g)].map((match) => match[1].replace(/<[^>]+>/g, ''))
const section = (markup) => markup.slice(markup.indexOf('class="qsc-unpaid"'))
const httpError = (message, status, code) => Object.assign(new Error(message), { status, payload: code ? { code } : null })

// ── tab and server call ─────────────────────────────────────────────────
test('the Unpaid tab sits between Today’s orders and Cash-up, and is the active view when chosen', () => {
  const sale = html(h(ui.CounterView, { state: ready }))
  const labels = buttonsOf(sale).filter((label) => ['New sale', 'Today’s orders', 'Unpaid', 'Cash-up'].includes(label))
  assert.deepEqual(labels, ['New sale', 'Today’s orders', 'Unpaid', 'Cash-up'])
  assert.doesNotMatch(sale, /<button[^>]*(hidden|disabled)[^>]*>Unpaid/)
  const view = unpaidScreen(readyState())
  assert.match(view, /aria-current="page"[^>]*>Unpaid/)
  assert.match(view, /<h2>Unpaid orders<\/h2>/)
  assert.doesNotMatch(view, /data-product-id=/)
})

test('the list comes only from the server RPC: no argument, no local source, no client sorting or filtering', async () => {
  const api = read('../src/lib/supabaseApi.js')
  assert.match(api.match(/export async function loadQuickSolutionUnpaidCounterOrders\(\) \{[\s\S]*?\n\}/)[0], /return rpc\('list_quick_solution_unpaid_counter_orders', \{\}, \{ accessToken \}\)/)
  const page = stripComments(read('../src/counter/CounterPage.jsx'))
  assert.match(page, /loadCounterUnpaidState\(loadQuickSolutionUnpaidCounterOrders\)/)
  assert.match(page, /const showView = \(next\) => \{[\s\S]*?if \(next === 'unpaid'\) loadUnpaid\(\)/)
  assert.match(page, /onRefreshUnpaid=\{loadUnpaid\}/)
  for (const file of ['../src/counter/CounterPage.jsx', '../src/counter/CounterView.jsx', '../src/lib/counterUnpaid.js']) {
    assert.doesNotMatch(stripComments(read(file)), /localStorage|sessionStorage|indexedDB|data\/products|catalogStore|orderHistory/i, file)
  }
  assert.doesNotMatch(stripComments(read('../src/lib/counterUnpaid.js')), /\.sort\(|\.reverse\(|\.filter\(|\.splice\(|\.slice\(/, 'the server decides which orders and in what order')
  const calls = []
  const state = await loadCounterUnpaidState(async (...args) => { calls.push(args); return summary() })
  assert.deepEqual(calls, [[]])
  assert.equal(state.status, 'ready')
  assert.deepEqual(state.summary, summary(), 'exactly what the server sent')
})

// ── states ──────────────────────────────────────────────────────────────
test('loading, error, denied, unavailable and signed-out states show the server’s word and never a list', async () => {
  assert.match(unpaidScreen({ status: 'loading' }), /Loading unpaid orders…/)
  const fail = (message, extra = {}) => loadCounterUnpaidState(async () => { throw Object.assign(new Error(message), extra) })
  const network = await fail('Failed to fetch')
  assert.equal(network.status, 'error')
  assert.match(unpaidScreen(network), /Could not load unpaid orders[\s\S]*Failed to fetch[\s\S]*Try again/)
  const denied = await fail('You do not have access to the Quick Solution counter.', { status: 403, payload: { code: '42501' } })
  assert.match(unpaidScreen(denied), /No counter access[\s\S]*You do not have access/)
  assert.match(unpaidScreen(await fail('Quick Solution counter is not active.', { status: 400 })), /Counter unavailable/)
  assert.match(unpaidScreen(await fail('Staff sign-in is required.')), /Sign in to see unpaid orders[\s\S]*Your sale in progress is kept/)
  for (const state of [network, denied]) assert.doesNotMatch(unpaidScreen(state), /qsc-order-list|QS-\d/)
  assert.equal((await loadCounterUnpaidState(async () => null)).status, 'error')
  assert.equal((await loadCounterUnpaidState(async () => ({ orders: 'no' }))).status, 'error')
})

test('empty state: nothing unpaid is a good day, not an error', async () => {
  const state = await loadCounterUnpaidState(async () => ({ businessDate: '2026-09-26', count: 0, outstandingTotal: 0, orders: [] }))
  assert.equal(state.status, 'empty')
  const markup = unpaidScreen(state)
  assert.match(markup, /No unpaid counter orders\. Everything is settled\./)
  assert.doesNotMatch(markup, /qsc-order-list/)
})

// ── rows, age, amounts ──────────────────────────────────────────────────
test('today’s and older unpaid orders are listed in the server’s order, each with number, customer, product, created date and time, outstanding and status', () => {
  const markup = unpaidScreen(readyState())
  const list = section(markup)
  assert.equal((list.match(/<li /g) || []).length, 3)
  assert.ok(list.indexOf('QS-260923-OLD3') < list.indexOf('QS-260925-YDAY') && list.indexOf('QS-260925-YDAY') < list.indexOf('QS-260926-TODY'), 'oldest first, as the server sent it')
  const view = text(list)
  assert.match(view, new RegExp(`QS-260923-OLD3 3 days old A3 Lamination · 2 sheets Sipho · 0821234567 23 Sept 2026 10:10 ${money(60)} Unpaid Submitted`))
  assert.match(view, new RegExp(`QS-260926-TODY Today Document Scanning · 7 pages Thandi Nkosi 26 Sept 2026 11:30 ${money(35)} Unpaid Submitted`))
})

test('age is the server’s business-day count, worded plainly: Today, 1 day old, N days old', () => {
  assert.equal(counterAgeLabel(0), 'Today')
  assert.equal(counterAgeLabel(1), '1 day old')
  assert.equal(counterAgeLabel(3), '3 days old')
  assert.equal(counterAgeLabel(12), '12 days old')
  assert.equal(counterAgeLabel(undefined), 'Today')
  assert.equal(counterAgeLabel(-2), 'Today')
  const markup = unpaidScreen(readyState())
  assert.match(markup, /qsc-age qsc-age-older">3 days old</)
  assert.match(markup, /qsc-age qsc-age-older">1 day old</)
  assert.match(markup, /qsc-age">Today</)
  // an order made a minute before local midnight is "1 day old" when the server says so: the client never computes an age itself
  const lib = stripComments(read('../src/lib/counterUnpaid.js'))
  assert.doesNotMatch(lib, /Date\.now|new Date|getTime|86400|24 \* 60|Intl\.|differenceIn|\bdays? ago\b/i)
  assert.equal(describeCounterUnpaid(summary()).orders[1].ageLabel, '1 day old')
  assert.equal(describeCounterUnpaid(summary()).orders[1].createdTime, '23:59', 'the created time is the Café’s own: 21:59 UTC is 23:59 local')
  // no alarming or collections wording anywhere on the screen or in its code
  const words = /overdue|debt|collect|remind|chase|arrears|delinquen|default|owing|late payment|final notice/i
  assert.doesNotMatch(text(markup), words)
  assert.doesNotMatch(stripComments(read('../src/lib/counterUnpaid.js')), words)
})

test('outstanding is shown per order and in total, and money already received against an order is shown apart', () => {
  const markup = unpaidScreen(readyState())
  const view = text(markup)
  assert.match(view, new RegExp(`3 orders outstanding · ${money(125)}`))
  assert.match(view, new RegExp(`QS-260925-YDAY 1 day old A4 Lamination · 3 sheets Walk-in 25 Sept 2026 23:59 ${money(30)} Unpaid ${money(15)} received`), 'a part-covered order shows the remainder as outstanding and what was received')
  assert.doesNotMatch(text(section(markup).slice(section(markup).indexOf('QS-260926-TODY'))), /received/, 'nothing received, nothing said')
  const described = describeCounterUnpaid(summary())
  assert.equal(described.count, 3)
  assert.equal(described.outstandingTotal, formatMoney(125))
  assert.deepEqual(described.orders.map((row) => [row.outstanding, row.amountPaid]), [[formatMoney(60), null], [formatMoney(30), formatMoney(15)], [formatMoney(35), null]])
  const lib = stripComments(read('../src/lib/counterUnpaid.js'))
  assert.match(lib, /import \{ formatMoney \} from '\.\/pricing\.js'/)
  assert.doesNotMatch(lib, /toFixed|NumberFormat|toLocale|\breduce\(/, 'no money is calculated or hand-formatted here')
  assert.match(text(unpaidScreen(readyState(summary({ count: 1, orders: [summary().orders[2]] })))), /1 order outstanding/)
})

// ── existing detail and payment ─────────────────────────────────────────
test('a row opens the existing order detail, and Back returns to the list, reloaded from the server', () => {
  const markup = unpaidScreen(readyState())
  assert.match(markup, /<button[^>]*aria-label="Open order QS-260926-TODY"/)
  const page = stripComments(read('../src/counter/CounterPage.jsx'))
  assert.match(page, /const openOrder = \(orderId, origin = 'orders'\) => \{[\s\S]*?setOrderOrigin\(origin\)[\s\S]*?loadDetail\(orderId\)/, 'the same flow as Today’s orders and the cash-up')
  assert.match(page, /if \(orderOrigin === 'unpaid'\) \{\s*\n\s*setView\('unpaid'\)\s*\n\s*loadUnpaid\(\)\s*\n\s*return/)
  const view = stripComments(read('../src/counter/CounterView.jsx'))
  assert.match(view, /onOpenOrder\?\.\(order\.orderId, 'unpaid'\)/)
  const detail = html(h(ui.CounterView, { state: ready, view: 'order', orderOrigin: 'unpaid', orderDetail: { status: 'loading' } }))
  assert.match(detail, /← Unpaid/)
  assert.match(detail, /aria-current="page"[^>]*>Unpaid/)
  assert.match(html(h(ui.CounterView, { state: ready, view: 'order', orderDetail: { status: 'loading' } })), /← Today’s orders/, 'from Today’s orders nothing changed')
})

test('a settled order leaves the list only because the server stops returning it - never by a local removal', async () => {
  // a tiny server: an unpaid order, the real payment state machine, and the list read from the server's own state
  const server = { orders: [{ ...summary().orders[2] }], payments: [] }
  const list = async () => ({ businessDate: '2026-09-26', count: server.orders.length, outstandingTotal: server.orders.reduce((sum, o) => sum + o.outstanding, 0), orders: server.orders.map((o) => ({ ...o })) })
  const before = await loadCounterUnpaidState(list)
  assert.equal(before.status, 'ready')
  const detail = { orderId: 'ord-1', orderNumber: 'QS-260926-TODY', paymentStatus: 'unpaid', totalAmount: 35, amountPaid: 0, outstanding: 35, paymentAllowed: true, items: [], payments: [] }
  const confirming = beginPayment(initialPayment(), detail, 'cash', () => 'unpaid-key-00000001')
  const done = await submitPayment(beginPaymentSubmit(confirming), async (payload) => {
    server.orders = server.orders.filter((o) => o.orderId !== payload.orderId)          // the SERVER settles it
    server.payments.push(payload)
    return { ok: true, replayed: false, orderNumber: 'QS-260926-TODY', method: payload.method, amount: 35, paidAt: '2026-09-26T12:00:00Z' }
  })
  assert.equal(done.phase, PAYMENT_PHASES.SUCCESS)
  assert.equal(server.payments.length, 1)
  assert.equal(before.summary.orders.length, 1, 'the list already in hand is not edited by the payment')
  assert.match(unpaidScreen(before), /QS-260926-TODY/, 'until it is read again it is still shown')
  const after = await loadCounterUnpaidState(list)
  assert.equal(after.status, 'empty')
  assert.doesNotMatch(unpaidScreen(after), /QS-260926-TODY/)
  const page = stripComments(read('../src/counter/CounterPage.jsx'))
  assert.equal((page.match(/setUnpaid\(/g) || []).length, 3, 'set only from the loading markers (reset and load) and the server answer: no removal code')
  assert.doesNotMatch(page, /setUnpaid\(\(current\) => \(\{[^}]*orders\.filter/)
  const confirmBody = page.slice(page.indexOf('const confirmPayment'), page.indexOf('const resetOrderPayment'))
  assert.doesNotMatch(confirmBody, /setUnpaid|loadUnpaid/, 'paying does not touch this list')
})

test('manual refresh reads the server again; while it runs the button is disabled and the rows stay', async () => {
  const answers = [summary(), summary({ count: 2, outstandingTotal: 65, orders: summary().orders.slice(1) })]
  let n = 0
  const load = async () => answers[n++]
  const first = await loadCounterUnpaidState(load)
  const second = await loadCounterUnpaidState(load)
  assert.equal(describeCounterUnpaid(first.summary).count, 3)
  assert.equal(describeCounterUnpaid(second.summary).count, 2)
  assert.match(unpaidScreen(first), /<button[^>]*>Refresh<\/button>/)
  const refreshing = unpaidScreen({ ...first, refreshing: true })
  assert.match(refreshing, /<button[^>]*disabled=""[^>]*>Refreshing…<\/button>/)
  assert.match(refreshing, /QS-260923-OLD3/)
  assert.doesNotMatch(stripComments(read('../src/counter/CounterPage.jsx')), /setInterval|setTimeout|visibilitychange/, 'no polling')
})

// ── read-only ───────────────────────────────────────────────────────────
test('the Unpaid screen has no payment, edit, void, refund, reminder or collection action of its own', () => {
  const markup = unpaidScreen(readyState())
  const own = section(markup)
  assert.deepEqual(buttonsOf(own).filter((label) => !/^QS-/.test(label)), ['Refresh'])
  assert.equal((own.match(/<button/g) || []).length, 4, 'Refresh and one Open-order button per row')
  assert.doesNotMatch(own, /<input|<select|<textarea|type="number"/i)
  assert.doesNotMatch(text(own), /Record (Cash|Card) Payment|Pay|Edit|Void|Refund|Cancel|Send|Remind|Call|WhatsApp|Close till/i)
  const view = stripComments(read('../src/counter/CounterView.jsx'))
  const panel = view.slice(view.indexOf('function UnpaidPanel'), view.indexOf('function CashupPanel') > view.indexOf('function UnpaidPanel') ? view.indexOf('function CashupPanel') : view.indexOf('export default function CounterView'))
  assert.doesNotMatch(panel + stripComments(read('../src/lib/counterUnpaid.js')), /recordQuickSolution|createQuickSolution|beginPayment|submitPayment|refund|voidOrder|remind|whatsapp|mailto:|wa\.me/i)
})

test('there is one payment implementation and no new write: the same two write calls, one more read', () => {
  const page = read('../src/counter/CounterPage.jsx')
  const imported = page.match(/import \{([^}]*)\} from '\.\.\/lib\/supabaseApi\.js'/)[1].split(',').map((name) => name.trim()).filter(Boolean)
  assert.deepEqual(imported, ['cancelQuickSolutionCounterOrder', 'createQuickSolutionCounterOrder', 'getAdminSession', 'loadQuickSolutionCancelledCounterOrders', 'loadQuickSolutionCounterCashup', 'loadQuickSolutionCounterCashupToday', 'loadQuickSolutionCounterCatalog', 'loadQuickSolutionCounterOrder', 'loadQuickSolutionCounterOrderCancelCheck', 'loadQuickSolutionCounterOrdersToday', 'loadQuickSolutionUnpaidCounterOrders', 'recordQuickSolutionCounterPayment', 'signInAdmin', 'signOutAdmin'])
  assert.equal((stripComments(page).match(/recordQuickSolutionCounterPayment/g) || []).length, 2, 'the payment call: imported once, used once')
  const view = stripComments(read('../src/counter/CounterView.jsx'))
  assert.equal((view.match(/Record \{method\.label\} Payment/g) || []).length, 1, 'the Cash/Card buttons exist once, in the order detail')
  assert.doesNotMatch(stripComments(read('../src/lib/counterUnpaid.js')), /supabaseApi|\bfetch\s*\(|\brpc\s*\(/)
  const sql = read('../supabase/migrations/20260926260000_cafe_guest_01t_unpaid_counter_orders_rpc.sql').replace(/--[^\n]*/g, '')
  assert.match(sql, /language plpgsql\s*\nstable\s*\nsecurity definer/)
  assert.doesNotMatch(sql, /insert into|update commerce|update public|delete from/i)
  assert.match(sql, /o\.outstanding > 0/)
  assert.match(sql, /order by o\.created_at, o\.id/)
  assert.match(sql, /_qs_counter_business_day\(so\.created_at\)/)
})

test('the new test file and the SQL contract test are part of npm test and the harness', () => {
  assert.match(JSON.parse(read('../package.json')).scripts.test, /tests\/counter-unpaid\.test\.mjs/)
  assert.ok(fs.existsSync(new URL('../supabase/tests/cafe_guest_01t_unpaid_counter_orders.sql', import.meta.url)))
})
