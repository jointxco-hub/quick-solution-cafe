import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'
import { loadCounterUi } from './helpers/counter-ui-harness.mjs'
import { products as seedProducts } from '../src/data/products.js'
import { formatMoney } from '../src/lib/pricing.js'
import { loadCounterCatalogueState } from '../src/lib/counterDraft.js'
import { addBusinessDays, describeCounterCashup, formatBusinessDate, isBusinessDate, loadCounterCashupState } from '../src/lib/counterCashup.js'

// CAFE-GUEST-01U - the cash-up for a chosen Cafe business date, read-only. The API is never real: fake loaders stand in for the server.
// The date bar is exercised for real by walking the rendered React tree and invoking the handlers it carries (no DOM needed); the screens
// are the real components rendered to HTML (tests/helpers/counter-ui-harness.mjs). What a business day is, which payments belong to it and
// what "unpaid" means for it are proven on real PostgreSQL in supabase/tests/cafe_guest_01u_dated_counter_cashup.sql.

const read = (path) => fs.readFileSync(new URL(path, import.meta.url), 'utf8')
const stripComments = (text) => text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:'"`])\/\/[^\n]*/g, '$1')
const ui = await loadCounterUi()
const h = ui.React.createElement
const html = (element) => ui.renderToStaticMarkup(element)
const serverProducts = seedProducts.filter((product) => product.channels?.pos === true)
const ready = await loadCounterCatalogueState(async () => ({ tenant: { slug: 'quick-solution', name: 'Quick Solution' }, products: serverProducts }))
const money = (value) => formatMoney(value).replace(/\s/g, '\\s')
const text = (markup) => markup.replace(/<[^>]+>/g, ' ').replace(/&amp;/g, '&').replace(/\s+/g, ' ')
const buttonsOf = (markup) => [...markup.matchAll(/<button[^>]*>([\s\S]*?)<\/button>/g)].map((match) => match[1].replace(/<[^>]+>/g, ''))

const TODAY = '2026-09-26'
const zero = { count: 0, amount: 0 }
const summary = (date, overrides = {}) => ({
  businessDate: date, timezone: 'Africa/Johannesburg',
  orders: { createdToday: 4, paidToday: 2, unpaidToday: 1 },
  takings: { cash: { count: 1, amount: 35 }, card: { count: 1, amount: 72 }, total: { count: 2, amount: 107 } },
  otherMethods: zero,
  unpaid: { count: 1, amount: 60, orders: [{ orderId: 'u1', orderNumber: 'QS-U1', createdAt: '2026-09-25T08:00:00Z', status: 'submitted', paymentStatus: 'unpaid', customerName: 'Sipho', customerEmail: null, customerPhone: null, totalAmount: 60, outstanding: 60, items: [{ productKey: 'a3-lamination', productName: 'A3 Lamination', quantity: 1, configuration: { units: 2 }, lineTotal: 60 }] }] },
  payments: [
    { paymentId: 'p2', orderId: 'o2', orderNumber: 'QS-P2', customerName: 'Walk-in', method: 'card', amount: 72, paidAt: '2026-09-25T11:00:00Z', orderTotal: 72, orderCreatedAt: '2026-09-25T09:00:00Z' },
    { paymentId: 'p1', orderId: 'o1', orderNumber: 'QS-P1', customerName: 'Thandi Nkosi', method: 'cash', amount: 35, paidAt: '2026-09-25T08:30:00Z', orderTotal: 35, orderCreatedAt: '2026-09-22T09:00:00Z' }
  ],
  ...overrides
})
const cashupProps = (state, extra = {}) => ({ state: ready, view: 'cashup', ...extra, cashup: { todayDate: TODAY, ...state } })
const screen = (state, extra = {}) => html(h(ui.CounterView, cashupProps(state, extra)))
const readyOn = (date, data = summary(date)) => ({ status: 'ready', summary: data, date: date === TODAY ? null : date })

// Walk the element tree the way React would render it, calling function components, and return the host elements (with their handlers).
function hostNodes(node, found = []) {
  if (Array.isArray(node)) { node.forEach((child) => hostNodes(child, found)); return found }
  if (!node || typeof node !== 'object' || !('type' in node)) return found
  if (typeof node.type === 'function') return hostNodes(node.type(node.props), found)
  if (typeof node.type === 'string') found.push(node)
  hostNodes(node.props?.children, found)
  return found
}
const labelOf = (node) => [node.props.children].flat(Infinity).filter((child) => typeof child === 'string').join('')
function dateBar(state, handlers = {}) {
  const nodes = hostNodes(h(ui.CounterView, cashupProps(state, handlers)))
  return {
    button: (label) => nodes.find((node) => node.type === 'button' && labelOf(node) === label),
    input: nodes.find((node) => node.type === 'input' && node.props.type === 'date'),
    buttons: nodes.filter((node) => node.type === 'button').map(labelOf)
  }
}

// ── the date helpers: calendar days, no zone, no clock ──────────────────
test('business dates are plain calendar days and step correctly over month, year and leap-day boundaries', () => {
  assert.equal(addBusinessDays('2026-09-26', -1), '2026-09-25')
  assert.equal(addBusinessDays('2026-03-01', -1), '2026-02-28')
  assert.equal(addBusinessDays('2026-01-01', -1), '2025-12-31')
  assert.equal(addBusinessDays('2026-12-31', 1), '2027-01-01')
  assert.equal(addBusinessDays('2028-03-01', -1), '2028-02-29')
  assert.equal(addBusinessDays('2028-02-28', 1), '2028-02-29')
  assert.equal(addBusinessDays('2026-10-31', 1), '2026-11-01')
  assert.equal(addBusinessDays('nonsense', 1), null)
  for (const good of ['2026-09-26', '2028-02-29', '2000-01-01']) assert.equal(isBusinessDate(good), true, good)
  for (const bad of ['2026-02-30', '2027-02-29', '2026-13-01', '2026-00-10', '26-01-01', '2026-1-1', '', ' 2026-01-01', '2026-01-01T00:00:00Z', null, undefined, 20260101]) assert.equal(isBusinessDate(bad), false, String(bad))
  assert.match(formatBusinessDate('2026-09-25'), /^Fri,? 25 Sept? 2026$/)
  assert.equal(formatBusinessDate('bad'), '')
  const lib = stripComments(read('../src/lib/counterCashup.js'))
  assert.doesNotMatch(lib.slice(lib.indexOf('export function isBusinessDate'), lib.indexOf('export async function loadCounterCashupState')), /Date\.now|new Date\(\)|getTimezoneOffset|toLocal|Africa/, 'no clock, no browser zone')
})

// ── Today is the default ────────────────────────────────────────────────
test('Today is the default: the cash-up opens on today’s figures and the page always resets to Today when the tab is opened', () => {
  const markup = screen(readyOn(TODAY))
  assert.match(text(markup), /Today’s cash-up/)
  assert.match(text(markup), /Counter · Today/)
  assert.match(text(markup), new RegExp(formatBusinessDate(TODAY)))
  assert.match(text(markup), /Orders today 4/)
  assert.match(text(markup), /Outstanding today/)
  assert.doesNotMatch(text(markup), /not a record of what was unpaid/)
  const page = stripComments(read('../src/counter/CounterPage.jsx'))
  assert.match(page, /const \[cashupDate, setCashupDate\] = useState\(null\)/)
  assert.match(page, /if \(next === 'cashup'\) \{\s*\n\s*setCashupDate\(null\)\s*\n\s*loadCashup\(null\)/)
  assert.match(page, /const loader = |loadCounterCashupState\(date \? \(\) => loadQuickSolutionCounterCashup\(date\) : loadQuickSolutionCounterCashupToday\)/)
  // at Today: Next day and Today are disabled, Previous day works
  const bar = dateBar(readyOn(TODAY))
  assert.deepEqual(bar.buttons.filter((label) => ['← Previous day', 'Next day →', 'Today'].includes(label)), ['← Previous day', 'Next day →', 'Today'])
  assert.equal(bar.button('Next day →').props.disabled, true)
  assert.equal(bar.button('Today').props.disabled, true)
  assert.equal(bar.button('← Previous day').props.disabled, false)
})

// ── the date bar works ──────────────────────────────────────────────────
test('Previous day, Next day, the date field and Today each ask for the right calendar date', () => {
  const calls = []
  const on = (state) => dateBar(state, { onSelectCashupDate: (value) => calls.push(value) })
  let bar = on(readyOn(TODAY))
  bar.button('← Previous day').props.onClick()
  assert.deepEqual(calls.splice(0), ['2026-09-25'])
  bar = on(readyOn('2026-09-24'))
  bar.button('← Previous day').props.onClick()
  bar.button('Next day →').props.onClick()
  bar.button('Today').props.onClick()
  bar.input.props.onChange({ target: { value: '2026-09-20' } })
  assert.deepEqual(calls.splice(0), ['2026-09-23', '2026-09-25', null, '2026-09-20'])
  assert.equal(bar.button('Today').props.disabled, false)
  assert.equal(bar.button('Next day →').props.disabled, false)
  assert.equal(bar.input.props.value, '2026-09-24')
  assert.equal(bar.input.props.max, TODAY, 'the date field cannot pick a future day')
  // stepping from the 1st of a month or year
  bar = on(readyOn('2026-03-01'))
  bar.button('← Previous day').props.onClick()
  bar = on(readyOn('2026-01-01'))
  bar.button('← Previous day').props.onClick()
  assert.deepEqual(calls.splice(0), ['2026-02-28', '2025-12-31'])
  // before today is known nothing can step
  assert.equal(dateBar({ status: 'loading', todayDate: null }, {}).button('← Previous day').props.disabled, true)
  assert.doesNotMatch(screen(readyOn('2026-09-24')), /<input(?![^>]*type="date")/, 'the date field is the only input')
})

test('the selected date is what is sent to the server: only a calendar date, and Today uses today’s own call', async () => {
  const api = read('../src/lib/supabaseApi.js')
  assert.match(api.match(/export async function loadQuickSolutionCounterCashup\(businessDate\) \{[\s\S]*?\n\}/)[0], /return rpc\('get_quick_solution_counter_cashup', \{ p_business_date: businessDate \}, \{ accessToken \}\)/)
  const sent = []
  const load = (date) => async () => { sent.push(date); return summary(date) }
  const state = await loadCounterCashupState(load('2026-09-25'))
  assert.deepEqual(sent, ['2026-09-25'])
  assert.equal(state.status, 'ready')
  assert.equal(describeCounterCashup(state.summary).businessDate, '2026-09-25')
  const page = stripComments(read('../src/counter/CounterPage.jsx'))
  const select = page.slice(page.indexOf('const selectCashupDate'), page.indexOf('const showView'))
  assert.match(select, /if \(value === null \|\| value === todayDate\) \{\s*\n\s*setCashupDate\(null\)\s*\n\s*loadCashup\(null\)/, 'Today (or today’s own date) is the today call')
  assert.match(select, /if \(!isBusinessDate\(value\)\) return/, 'only a valid calendar date goes on')
  assert.match(select, /loadCashup\(value\)/)
  for (const forbidden of ['timezone', 'tenant', 'channel', 'start', 'end', 'limit']) assert.doesNotMatch(api.match(/export async function loadQuickSolutionCounterCashup\(businessDate\) \{[\s\S]*?\n\}/)[0].replace('loadQuickSolutionCounterCashup', ''), new RegExp(forbidden, 'i'), forbidden)
  // a slow answer for a date that is no longer selected is dropped
  const load2 = page.slice(page.indexOf('const loadCashup'), page.indexOf('// Choose a Cafe day'))
  assert.match(load2, /const request = \+\+cashupRequest\.current/)
  assert.match(load2, /request !== cashupRequest\.current\) return/)
})

test('Cash, Card and the total follow the selected day, and the day is obvious in the header', () => {
  const past = summary('2026-09-25')
  const other = summary('2026-09-24', { takings: { cash: { count: 3, amount: 200 }, card: { count: 0, amount: 0 }, total: { count: 3, amount: 200 } } })
  const a = text(screen(readyOn('2026-09-25', past)))
  const b = text(screen(readyOn('2026-09-24', other)))
  assert.match(a, new RegExp(`Cash ${money(35)} 1 payment Card ${money(72)} 1 payment Total taken ${money(107)} 2 payments`))
  assert.match(b, new RegExp(`Cash ${money(200)} 3 payments Card ${money(0)} 0 payments Total taken ${money(200)} 3 payments`))
  assert.match(a, new RegExp(`Cash-up ${formatBusinessDate('2026-09-25')}`))
  assert.match(b, new RegExp(`Cash-up ${formatBusinessDate('2026-09-24')}`))
  assert.match(a, /Counter · Earlier day/)
  assert.doesNotMatch(a, /Today’s cash-up/)
})

test('an earlier day says what its figures mean: takings by payment day, and unpaid means unpaid NOW', () => {
  const view = text(screen(readyOn('2026-09-25')))
  assert.match(view, /Orders made that day 4/)
  assert.match(view, /Orders paid that day 2/)
  assert.match(view, /Unpaid now 1/)
  assert.match(view, new RegExp(`Outstanding now ${money(60)}`))
  assert.match(view, /Payments taken that day/)
  assert.match(view, /Made that day, still unpaid now not money received/)
  assert.match(view, /Takings are the payments completed on this day\. Unpaid shows this day’s orders that are still unpaid now; it is not a record of what was unpaid when the day ended\./)
  assert.match(view, /QS-P1[\s\S]*Ordered 22 Sept 2026/, 'an order made earlier and paid on this day shows when it was made')
  assert.doesNotMatch(view, /Outstanding today|Orders today|Payments taken today/)
})

// ── states ──────────────────────────────────────────────────────────────
test('loading, error, empty and future states for a chosen day keep the date bar and show the server’s word', async () => {
  assert.match(text(screen({ status: 'loading', date: '2026-09-25' })), /Loading the cash-up…/)
  assert.ok(dateBar({ status: 'loading', date: '2026-09-25' }).input, 'the bar stays while it loads')
  const fail = (message, extra = {}) => loadCounterCashupState(async () => { throw Object.assign(new Error(message), extra) })
  const network = await fail('Failed to fetch')
  assert.match(text(screen({ ...network, date: '2026-09-25' })), /Could not load the cash-up Failed to fetch Try again/)
  const empty = await loadCounterCashupState(async () => summary('2026-09-20', { orders: { createdToday: 0, paidToday: 0, unpaidToday: 0 }, takings: { cash: zero, card: zero, total: zero }, unpaid: { count: 0, amount: 0, orders: [] }, payments: [] }))
  assert.equal(empty.status, 'empty')
  assert.match(text(screen({ ...empty, date: '2026-09-20' })), /No counter sales on this day\./)
  assert.doesNotMatch(screen({ ...empty, date: '2026-09-20' }), /qsc-takings/)
  assert.match(text(screen({ status: 'ready', summary: summary('2026-09-25', { unpaid: { count: 0, amount: 0, orders: [] }, orders: { createdToday: 2, paidToday: 2, unpaidToday: 0 } }), date: '2026-09-25' })), /None of that day’s orders are unpaid now\./)
})

test('a future day is never shown as data: the field caps at today, the page does not ask, and a server refusal is a plain state', async () => {
  const future = screen({ status: 'future', date: '2026-09-30' })
  assert.match(text(future), /That day has not happened yet, so there is nothing to show\. Choose today or an earlier day\./)
  assert.doesNotMatch(future, /qsc-takings|Total taken/)
  assert.equal(dateBar({ status: 'future', date: '2026-09-30' }).input.props.max, TODAY)
  const page = stripComments(read('../src/counter/CounterPage.jsx'))
  const select = page.slice(page.indexOf('const selectCashupDate'), page.indexOf('const showView'))
  assert.match(select, /if \(todayDate && value > todayDate\) \{[\s\S]*?setCashup\(\{ status: 'future', date: value \}\)\s*\n\s*return\s*\n\s*\}\s*\n\s*loadCashup\(value\)/, 'a future date returns before any server call')
  const refused = await loadCounterCashupState(async () => { throw Object.assign(new Error('Cash-up date cannot be in the future.'), { status: 400, payload: { code: '22023' } }) })
  assert.equal(refused.status, 'future')
  assert.match(text(screen({ ...refused, date: '2026-09-30' })), /has not happened yet/)
  const invalid = await loadCounterCashupState(async () => { throw Object.assign(new Error('Business date is not valid.'), { status: 400 }) })
  assert.equal(invalid.status, 'error')
})

// ── drill-through and read-only ─────────────────────────────────────────
test('historical payment and unpaid rows open the existing order detail, and Back returns to the same day', () => {
  const opened = []
  const nodes = hostNodes(h(ui.CounterView, cashupProps(readyOn('2026-09-25'), { onOpenOrder: (...args) => opened.push(args) })))
  const rows = nodes.filter((node) => node.type === 'button' && /^Open order/.test(node.props['aria-label'] || ''))
  assert.deepEqual(rows.map((node) => node.props['aria-label']), ['Open order QS-P2', 'Open order QS-P1', 'Open order QS-U1'])
  rows.forEach((node) => node.props.onClick())
  assert.deepEqual(opened, [['o2', 'cashup'], ['o1', 'cashup'], ['u1', 'cashup']])
  const page = stripComments(read('../src/counter/CounterPage.jsx'))
  assert.match(page, /if \(orderOrigin === 'cashup'\) \{\s*\n\s*setView\('cashup'\)\s*\n\s*loadCashup\(cashupDate\)/)
  const view = stripComments(read('../src/counter/CounterView.jsx'))
  assert.equal((view.match(/function OrderDetailPanel/g) || []).length, 1, 'no second order-detail implementation')
})

test('the date bar adds no write, no close-till, no counted cash, no export and no chart', () => {
  const view = stripComments(read('../src/counter/CounterView.jsx'))
  const panel = view.slice(view.indexOf('function CashupDateBar'), view.indexOf('function UnpaidPanel'))
  assert.ok(panel.length > 500)
  assert.doesNotMatch(panel + stripComments(read('../src/lib/counterCashup.js')), /closeTill|closeShift|submitCashup|openingFloat|\bfloat\b|expectedCash|countedCash|variance|adjust|payout|refund|voidOrder|exportCsv|downloadFile|createObjectURL|.csv|<svg|chart|recordQuickSolution|createQuickSolution/i)
  assert.doesNotMatch(text(screen(readyOn('2026-09-25'))), /Close till|Opening float|Counted|Expected|Variance|Adjust|Export|Download|Refund|Void/i)
  const page = read('../src/counter/CounterPage.jsx')
  const imported = page.match(/import \{([^}]*)\} from '\.\.\/lib\/supabaseApi\.js'/)[1].split(',').map((name) => name.trim()).filter(Boolean)
  assert.deepEqual(imported, ['cancelQuickSolutionCounterOrder', 'createQuickSolutionCounterOrder', 'getAdminSession', 'loadQuickSolutionCancelledCounterOrders', 'loadQuickSolutionCounterCashup', 'loadQuickSolutionCounterCashupToday', 'loadQuickSolutionCounterCatalog', 'loadQuickSolutionCounterOrder', 'loadQuickSolutionCounterOrderCancelCheck', 'loadQuickSolutionCounterOrdersToday', 'loadQuickSolutionUnpaidCounterOrders', 'recordQuickSolutionCounterPayment', 'signInAdmin', 'signOutAdmin'], 'one more READ; the same two writes')
  assert.equal((stripComments(page).match(/recordQuickSolutionCounterPayment/g) || []).length, 2)
  assert.doesNotMatch(stripComments(read('../src/lib/counterCashup.js')), /supabaseApi|\bfetch\s*\(|\brpc\s*\(|localStorage/)
})

test('the server contract this relies on is present: one shared, read-only implementation, and the SQL test is in the harness and npm test', () => {
  const sql = read('../supabase/migrations/20260926270000_cafe_guest_01u_dated_counter_cashup.sql').replace(/--[^\n]*/g, '')
  assert.match(sql, /create or replace function public\.get_quick_solution_counter_cashup\(p_business_date date\)/)
  assert.match(sql, /language plpgsql\s*\nstable\s*\nsecurity definer/)
  assert.equal((sql.match(/_qs_counter_cashup\(v_tenant_id/g) || []).length, 2, 'today and the dated function both call the one implementation')
  assert.doesNotMatch(sql.slice(sql.indexOf('create or replace function public.get_quick_solution_counter_cashup_today')), /insert into|update commerce|update public|delete from/i)
  assert.match(JSON.parse(read('../package.json')).scripts.test, /tests\/counter-cashup-date\.test\.mjs/)
  assert.ok(fs.existsSync(new URL('../supabase/tests/cafe_guest_01u_dated_counter_cashup.sql', import.meta.url)))
})
