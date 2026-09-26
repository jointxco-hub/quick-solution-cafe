import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'
import { loadCounterUi } from './helpers/counter-ui-harness.mjs'
import { products as seedProducts } from '../src/data/products.js'
import { loadCounterCatalogueState } from '../src/lib/counterDraft.js'
import { describeCounterCancelled, isCancelledListAvailable, loadCounterCancelledState } from '../src/lib/counterCancelled.js'

// CAFE-GUEST-01W - the audited cancelled counter orders, read-only. The API is never real: fake loaders stand in for the server. Who may see
// the list, which orders are in it, the order, the cap and what is left out are proven on real PostgreSQL in
// supabase/tests/cafe_guest_01w_cancelled_counter_orders.sql. Here: the tab follows the server's answer, what the screen shows, that rows
// open the existing order detail, and that nothing on it can change anything.

const read = (path) => fs.readFileSync(new URL(path, import.meta.url), 'utf8')
const stripComments = (text) => text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:'"`])\/\/[^\n]*/g, '$1')
const ui = await loadCounterUi()
const h = ui.React.createElement
const html = (element) => ui.renderToStaticMarkup(element)
const serverProducts = seedProducts.filter((product) => product.channels?.pos === true)
const ready = await loadCounterCatalogueState(async () => ({ tenant: { slug: 'quick-solution', name: 'Quick Solution' }, products: serverProducts }))
const text = (markup) => markup.replace(/<[^>]+>/g, ' ').replace(/&amp;/g, '&').replace(/&#x27;/g, "'").replace(/\s+/g, ' ')
const buttonsOf = (markup) => [...markup.matchAll(/<button[^>]*>([\s\S]*?)<\/button>/g)].map((match) => match[1].replace(/<[^>]+>/g, ''))
const httpError = (status, message, code) => Object.assign(new Error(message), { status, payload: code ? { code } : undefined })

const entry = (n, overrides = {}) => ({
  orderId: `ord-${n}`, orderNumber: `QS-260926-W${n}`, createdAt: '2026-09-26T08:05:00+00:00', cancelledAt: '2026-09-26T09:30:00+00:00',
  reason: 'Customer changed their mind', cancelledBy: 'Ada Admin', priorStatus: 'submitted', priorPaymentStatus: 'unpaid', totalAmount: 35, outstandingAtCancel: 35,
  customerName: 'Thandi Nkosi', customerEmail: null, customerPhone: '0751234567',
  items: [{ productKey: 'scan', productName: 'Document Scanning', quantity: 1, configuration: { units: 7 }, lineTotal: 35 }],
  ...overrides
})
const summary = (orders = [entry(1), entry(2, { cancelledBy: null, reason: 'Entered for the wrong customer', priorPaymentStatus: 'failed' })], extra = {}) => ({ count: orders.length, shown: orders.length, limit: 100, orders, ...extra })
const readyState = (data = summary()) => ({ status: 'ready', summary: data })
const screen = (cancelled, extra = {}) => html(h(ui.CounterView, { state: ready, view: 'cancelled', cancelled, ...extra }))

function hostNodes(node, found = []) {
  if (Array.isArray(node)) { node.forEach((child) => hostNodes(child, found)); return found }
  if (!node || typeof node !== 'object' || !('type' in node)) return found
  if (typeof node.type === 'function') return hostNodes(node.type(node.props), found)
  if (typeof node.type === 'string') found.push(node)
  hostNodes(node.props?.children, found)
  return found
}

// ── the loader ──────────────────────────────────────────────────────────
test('the list is read with no argument and every answer has a plain state; nothing throws', async () => {
  const calls = []
  const good = await loadCounterCancelledState(async (...args) => { calls.push(args); return summary() })
  assert.equal(good.status, 'ready')
  assert.deepEqual(calls, [[]], 'no argument: no tenant, channel, actor or date')
  assert.equal((await loadCounterCancelledState(async () => summary([]))).status, 'empty')
  assert.equal((await loadCounterCancelledState(async () => { throw httpError(403, 'Only a Quick Solution admin or owner can view cancelled counter orders.', '42501') })).status, 'denied')
  assert.equal((await loadCounterCancelledState(async () => { throw httpError(401, 'Staff sign-in is required.') })).status, 'signed-out')
  assert.equal((await loadCounterCancelledState(async () => { throw httpError(400, 'Quick Solution counter is not active.', '22023') })).status, 'unavailable')
  assert.equal((await loadCounterCancelledState(async () => { throw new Error('offline') })).status, 'error')
  for (const bad of [null, undefined, {}, { orders: 'x' }, 'text']) assert.equal((await loadCounterCancelledState(async () => bad)).status, 'error')
  assert.equal(isCancelledListAvailable({ status: 'ready' }), true)
  assert.equal(isCancelledListAvailable({ status: 'empty' }), true)
  for (const no of [{ status: 'denied' }, { status: 'loading' }, { status: 'error' }, { status: 'signed-out' }, { status: 'unavailable' }, null, undefined]) assert.equal(isCancelledListAvailable(no), false)
})

test('display fields come from the server as given: reason, who, when, prior state, money; a missing name is never an id', () => {
  const view = describeCounterCancelled(summary(), ready.entries)
  assert.equal(view.count, 2)
  assert.equal(view.truncated, false)
  assert.equal(view.orders[0].orderNumber, 'QS-260926-W1')
  assert.equal(view.orders[0].reason, 'Customer changed their mind')
  assert.equal(view.orders[0].cancelledBy, 'Ada Admin')
  assert.match(view.orders[0].total, /35,00/)
  assert.equal(view.orders[0].wasLabel, 'Was unpaid')
  assert.equal(view.orders[1].cancelledBy, null)
  assert.equal(view.orders[1].wasLabel, 'Payment had failed')
  assert.equal(view.orders[0].items[0].name, 'Document Scanning')
  assert.deepEqual(view.orders.map((order) => order.orderNumber), ['QS-260926-W1', 'QS-260926-W2'], 'the server order is kept: nothing is re-sorted here')
  const capped = describeCounterCancelled(summary([entry(1)], { count: 250, shown: 100 }), ready.entries)
  assert.equal(capped.truncated, true)
  assert.equal(capped.count, 250)
  assert.equal(describeCounterCancelled(null).orders.length, 0)
})

// ── the tab and the screen ──────────────────────────────────────────────
test('the tab is shown only when the server has answered this staff member; a plain member never sees it', () => {
  const tabs = (cancelled) => buttonsOf(html(h(ui.CounterView, { state: ready, view: 'sale', cancelled }))).filter((label) => label !== 'Sign out')
  assert.ok(tabs(readyState()).includes('Cancelled'))
  assert.ok(tabs({ status: 'empty', summary: summary([]) }).includes('Cancelled'), 'an admin with nothing cancelled still has the tab')
  for (const hidden of [{ status: 'denied', message: 'x' }, { status: 'loading' }, { status: 'error', message: 'x' }, { status: 'signed-out', message: 'x' }, undefined]) {
    assert.equal(tabs(hidden).includes('Cancelled'), false, JSON.stringify(hidden))
  }
  assert.deepEqual(tabs(readyState()).slice(0, 4), ['New sale', 'Today’s orders', 'Unpaid', 'Cash-up'], 'the other tabs are unchanged')
})

test('the list shows each cancellation with its reason, who and when, and the total is the server\'s', () => {
  const view = screen(readyState())
  const words = text(view)
  assert.match(words, /Cancelled orders/)
  assert.match(words, /2 orders cancelled/)
  assert.match(words, /QS-260926-W1/)
  assert.match(words, /“Customer changed their mind” · by Ada Admin/)
  assert.match(words, /“Entered for the wrong customer” · by a staff member/)
  assert.match(words, /Was unpaid/)
  assert.match(words, /Payment had failed/)
  assert.match(words, /Document Scanning/)
  assert.match(view, /data-cancelled-order="QS-260926-W1"/)
  assert.match(text(screen(readyState(summary([entry(1)], { count: 250, shown: 100 })))), /Latest 100 of 250 cancelled orders/, 'a capped page says so')
  assert.match(text(screen({ status: 'empty', summary: summary([]) })), /No orders have been cancelled\./)
  assert.match(text(screen({ status: 'loading' })), /Loading cancelled orders…/)
  assert.match(text(screen({ status: 'denied', message: 'Only a Quick Solution admin or owner can view cancelled counter orders.' })), /Not available.*admin or owner/)
  assert.match(text(screen({ status: 'error', message: 'offline' })), /Could not load cancelled orders.*offline/)
  assert.match(text(screen({ status: 'signed-out', message: 'x' })), /Sign in to see cancelled orders/)
})

test('rows open the existing order detail from the cancelled list, and Back says so; the list offers nothing that changes an order', () => {
  const opened = []
  const nodes = hostNodes(h(ui.CounterView, { state: ready, view: 'cancelled', cancelled: readyState(), onOpenOrder: (...args) => opened.push(args) }))
  nodes.filter((node) => node.type === 'button' && node.props.className === 'qsc-order')[1].props.onClick()
  assert.deepEqual(opened, [['ord-2', 'cancelled']])
  const labels = buttonsOf(screen(readyState()))
  assert.deepEqual(labels.filter((label) => !/^QS-|^Refresh$|^New sale|^Today|^Unpaid|^Cash-up|^Cancelled|Sign out/.test(label)), [], 'only rows, Refresh and the tabs')
  const detail = html(h(ui.CounterView, { state: ready, view: 'order', orderOrigin: 'cancelled', orderDetail: { status: 'loading' }, cancelled: readyState() }))
  assert.match(detail, /← Cancelled/)
  assert.doesNotMatch(text(screen(readyState())), /restore|reopen|undo|delete|export|refund|void/i)
})

// ── the page and the wrapper ────────────────────────────────────────────
test('the wrapper sends no argument, and the page asks once when the counter opens, on the tab, on Back, after a cancel and after signing in', () => {
  const api = stripComments(read('../src/lib/supabaseApi.js'))
  const wrapper = api.match(/export async function loadQuickSolutionCancelledCounterOrders\(\) \{[\s\S]*?\n\}/)[0]
  assert.match(wrapper, /return rpc\('list_quick_solution_cancelled_counter_orders', \{\}, \{ accessToken \}\)/)
  const page = stripComments(read('../src/counter/CounterPage.jsx'))
  assert.match(page, /loadCounterCancelledState\(loadQuickSolutionCancelledCounterOrders\)/)
  assert.match(page, /setState\(next\)\s*\n\s*if \(next\.status === 'ready'\) loadCancelled\(\)/, 'asked once when the counter opens, only if it opened')
  assert.match(page, /if \(next === 'cancelled'\) loadCancelled\(\)/)
  assert.match(page, /orderOrigin === 'cancelled'\) \{\s*setView\('cancelled'\)\s*loadCancelled\(\)\s*return/)
  assert.match(page, /if \(next\.phase === CANCEL_PHASES\.SUCCESS\) loadCancelled\(\)/, 'a new cancellation shows up: the server is asked again')
  assert.match(page, /if \(view === 'cancelled'\) \{ await loadCancelled\(\); handled = true \}/)
  assert.match(page, /setCancelled\(\{ status: 'loading' \}\)/)
  assert.doesNotMatch(page, /setCancelled\([^)]*(filter|sort|splice|slice)/, 'the list is never edited locally')
  const imported = page.match(/import \{([^}]*)\} from '\.\.\/lib\/supabaseApi\.js'/)[1].split(',').map((name) => name.trim()).filter(Boolean)
  assert.deepEqual(imported.filter((name) => /^(create|record|cancel|void|refund|update|delete|set)/i.test(name)), ['cancelQuickSolutionCounterOrder', 'createQuickSolutionCounterOrder', 'recordQuickSolutionCounterPayment'], 'still exactly three writes; the list is a read')
})

test('the list module decides nothing about permission and cannot write or export', () => {
  const lib = stripComments(read('../src/lib/counterCancelled.js'))
  const view = stripComments(read('../src/counter/CounterView.jsx'))
  const panel = view.slice(view.indexOf('function CancelledPanel'), view.indexOf('function UnpaidPanel'))
  for (const source of [lib, panel]) {
    assert.doesNotMatch(source, /cafe\.[a-z_.]+|operations\.manage|counter\.operate|tenantRole|isAdmin|isOwner/, 'the front end never names a capability or a role')
    assert.doesNotMatch(source, /\bfetch\s*\(|\brpc\s*\(|supabaseApi|localStorage|sessionStorage|exportCsv|downloadFile|\.csv|mailto:|wa\.me/i)
  }
  assert.doesNotMatch(lib, /\.sort\(|\.filter\(|\.reverse\(/, 'no re-sorting or filtering: the server order and page are shown as they come')
})

test('the SQL contract test and this file are part of npm test and the harness', () => {
  assert.match(JSON.parse(read('../package.json')).scripts.test, /tests\/counter-cancelled\.test\.mjs/)
  assert.match(read('./db-harness.test.mjs'), /'cafe_guest_01w'/)
  const sql = read('../supabase/migrations/20260926290000_cafe_guest_01w_cancelled_counter_orders_rpc.sql').replace(/--[^\n]*/g, '')
  assert.match(sql, /language plpgsql\s*\nstable\s*\nsecurity definer/)
  assert.match(sql, /has_tenant_capability\(v_tenant_id, 'cafe\.operations\.manage'\)/)
  assert.doesNotMatch(sql, /insert into|update commerce|update public|delete from/i)
  assert.doesNotMatch(sql, /grant [^;]*(anon|service_role)/i)
  assert.match(read('../supabase/tests/cafe_guest_01w_cancelled_counter_orders.sql'), /CAFE-GUEST-01W cancelled counter orders RPC contracts passed/)
})
