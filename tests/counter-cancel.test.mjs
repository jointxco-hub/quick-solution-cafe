import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'
import { loadCounterUi } from './helpers/counter-ui-harness.mjs'
import { products as seedProducts } from '../src/data/products.js'
import { loadCounterCatalogueState } from '../src/lib/counterDraft.js'
import { initialPayment, PAYMENT_PHASES } from '../src/lib/counterPayment.js'
import {
  CANCEL_PHASES,
  COUNTER_CANCEL_REASON_MAX,
  abortCancel,
  beginCancel,
  beginCancelSubmit,
  checkCancelReason,
  describeCancelBlock,
  describeCancelOffer,
  initialCancel,
  isCancelLocked,
  loadCounterCancelCheckState,
  resetCancel,
  resumeCancelAfterSignIn,
  setCancelReason,
  submitCancel
} from '../src/lib/counterCancel.js'

// CAFE-GUEST-01V - an admin or owner cancels a never-paid counter order. The API is never real: fake functions stand in for the server.
// Who may cancel, which orders can be cancelled and what is written (status + audit row) are proven on real PostgreSQL in
// supabase/tests/cafe_guest_01v_cancel_unpaid_counter_order.sql. Here: the offer only follows the server's check, the reason and the
// confirmation, one call per attempt, safe retries, and that the screen names no capability and writes nothing itself.

const read = (path) => fs.readFileSync(new URL(path, import.meta.url), 'utf8')
const stripComments = (text) => text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:'"`])\/\/[^\n]*/g, '$1')
const ui = await loadCounterUi()
const h = ui.React.createElement
const html = (element) => ui.renderToStaticMarkup(element)
const serverProducts = seedProducts.filter((product) => product.channels?.pos === true)
const ready = await loadCounterCatalogueState(async () => ({ tenant: { slug: 'quick-solution', name: 'Quick Solution' }, products: serverProducts }))
const text = (markup) => markup.replace(/<[^>]+>/g, ' ').replace(/&amp;/g, '&').replace(/&#x27;/g, "'").replace(/\s+/g, ' ')
const buttonsOf = (markup) => [...markup.matchAll(/<button[^>]*>([\s\S]*?)<\/button>/g)].map((match) => match[1].replace(/<[^>]+>/g, ''))

const order = (overrides = {}) => ({
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
const checkOf = (overrides = {}) => ({ status: 'ready', orderId: 'b1f0c0de-0000-4000-8000-0000000000aa', permitted: true, cancellable: true, block: null, ...overrides })
const screen = (props = {}, o = order()) => html(h(ui.CounterView, { state: ready, view: 'order', orderDetail: { status: 'ready', order: o, orderId: o.orderId }, payment: initialPayment(), ...props }))

function hostNodes(node, found = []) {
  if (Array.isArray(node)) { node.forEach((child) => hostNodes(child, found)); return found }
  if (!node || typeof node !== 'object' || !('type' in node)) return found
  if (typeof node.type === 'function') return hostNodes(node.type(node.props), found)
  if (typeof node.type === 'string') found.push(node)
  hostNodes(node.props?.children, found)
  return found
}
const labelOf = (node) => [node.props.children].flat(Infinity).filter((child) => typeof child === 'string').join('')
const nodesOf = (props, o = order()) => hostNodes(h(ui.CounterView, { state: ready, view: 'order', orderDetail: { status: 'ready', order: o, orderId: o.orderId }, payment: initialPayment(), ...props }))

const confirming = (reason = '') => setCancelReason(beginCancel(initialCancel(), checkOf(), order()), reason)
const httpError = (status, message, code) => Object.assign(new Error(message), { status, payload: code ? { code } : undefined })

// ── the reason ──────────────────────────────────────────────────────────
test('the reason is trimmed and must be 3 to 300 characters with no control characters', () => {
  assert.deepEqual(checkCancelReason('  Customer left  '), { ok: true, reason: 'Customer left', message: null })
  assert.equal(checkCancelReason('abc').ok, true)
  assert.equal(checkCancelReason('x'.repeat(COUNTER_CANCEL_REASON_MAX)).ok, true)
  for (const bad of [null, undefined, '', '  ', 'ab', ' ab ', 'x'.repeat(COUNTER_CANCEL_REASON_MAX + 1), 'line one\nline two', 'tab\tchar', 'nul\u0000x', 'del\u007fx']) {
    const checked = checkCancelReason(bad)
    assert.equal(checked.ok, false, JSON.stringify(bad))
    assert.ok(checked.message, 'a bad reason says why')
  }
  assert.equal(COUNTER_CANCEL_REASON_MAX, 300)
})

// ── the offer follows the server's check ────────────────────────────────
test('the cancel action is offered only when the server says the caller may AND the order can be cancelled', () => {
  assert.deepEqual(describeCancelOffer(checkOf(), order()), { offer: true, note: null })
  // a plain counter member: permitted false -> nothing at all, not even a hint
  assert.deepEqual(describeCancelOffer(checkOf({ permitted: false }), order()), { offer: false, note: null })
  assert.deepEqual(describeCancelOffer(checkOf({ permitted: false, cancellable: false, block: 'has_payment' }), order()), { offer: false, note: null })
  // permitted but the order cannot be cancelled: no action, a plain reason
  for (const [block, words] of Object.entries({
    has_payment: /has a payment/, payment_in_progress: /still in progress/, sent_to_production: /sent to production/, in_progress: /being worked on/,
    nothing_outstanding: /nothing outstanding/, not_cancellable: /cannot be cancelled/, not_payable_state: /cannot be cancelled/
  })) {
    const offer = describeCancelOffer(checkOf({ cancellable: false, block }), order())
    assert.equal(offer.offer, false, block)
    assert.match(offer.note, words, block)
  }
  assert.equal(describeCancelBlock('something new'), 'This order cannot be cancelled.')
  assert.equal(describeCancelBlock(null), null)
  // already cancelled, no check, a failed or missing check: no action
  assert.deepEqual(describeCancelOffer(checkOf(), order({ status: 'cancelled' })), { offer: false, note: null })
  for (const bad of [null, undefined, { status: 'none' }, { status: 'unavailable', message: 'x' }, { status: 'loading' }]) assert.deepEqual(describeCancelOffer(bad, order()), { offer: false, note: null })
  assert.deepEqual(describeCancelOffer(checkOf(), null), { offer: false, note: null })
})

test('the check is a read that never throws: any failure simply offers nothing', async () => {
  const calls = []
  const good = await loadCounterCancelCheckState(async (...args) => { calls.push(args); return { orderId: 'o1', permitted: true, cancellable: false, block: 'has_payment' } }, 'o1')
  assert.deepEqual(good, { status: 'ready', orderId: 'o1', permitted: true, cancellable: false, block: 'has_payment' })
  assert.deepEqual(calls, [['o1']], 'only the order id is sent')
  assert.equal((await loadCounterCancelCheckState(async () => ({ orderId: 'o1', permitted: 'yes', cancellable: true }), 'o1')).status, 'unavailable')
  assert.equal((await loadCounterCancelCheckState(async () => null, 'o1')).status, 'unavailable')
  assert.equal((await loadCounterCancelCheckState(async () => { throw httpError(403, 'You do not have access to the Quick Solution counter.', '42501') }, 'o1')).status, 'unavailable')
  assert.equal((await loadCounterCancelCheckState(async () => { throw new Error('offline') }, 'o1')).status, 'unavailable')
})

// ── the attempt ─────────────────────────────────────────────────────────
test('an attempt begins only from idle and only when it is offered; a bad reason stays on the confirmation', () => {
  const idle = initialCancel()
  assert.equal(beginCancel(idle, checkOf({ permitted: false }), order()), idle, 'a plain member cannot start one')
  assert.equal(beginCancel(idle, checkOf({ cancellable: false, block: 'has_payment' }), order()), idle)
  assert.equal(beginCancel(idle, checkOf(), order({ status: 'cancelled' })), idle)
  assert.equal(beginCancel(idle, null, order()), idle)
  const started = beginCancel(idle, checkOf(), order())
  assert.equal(started.phase, CANCEL_PHASES.CONFIRMING)
  assert.equal(started.attempt.orderId, order().orderId)
  assert.equal(beginCancel(started, checkOf(), order()), started, 'a second start changes nothing')
  // typing changes only the reason, only while confirming
  assert.equal(setCancelReason(started, 'Left').reason, 'Left')
  assert.equal(setCancelReason(idle, 'x'), idle)
  // a bad reason is not sent
  const blank = beginCancelSubmit(setCancelReason(started, '  '))
  assert.equal(blank.phase, CANCEL_PHASES.CONFIRMING)
  assert.match(blank.error, /at least 3/)
  assert.equal(blank.attempt.submissions, 0)
  // Keep order drops it, but only while nothing was sent
  assert.equal(abortCancel(started).phase, CANCEL_PHASES.IDLE)
  const sending = beginCancelSubmit(confirming('Customer left'))
  assert.equal(abortCancel(sending), sending)
  assert.equal(isCancelLocked(sending), true)
})

test('confirm sends ONE call with only the order id and the trimmed reason; a second click cannot start another', async () => {
  const sending = beginCancelSubmit(confirming('   Customer left   '))
  assert.equal(sending.phase, CANCEL_PHASES.SUBMITTING)
  assert.equal(sending.attempt.reason, 'Customer left')
  assert.equal(beginCancelSubmit(sending), sending, 'already submitting: unchanged, so no second call')
  const calls = []
  const done = await submitCancel(sending, async (payload) => { calls.push(payload); return { ok: true, replayed: false, orderId: order().orderId, orderNumber: 'QS-260926-AB12', status: 'cancelled', cancelledAt: '2026-09-26T12:00:00Z', reason: 'Customer left' } })
  assert.deepEqual(calls, [{ orderId: order().orderId, reason: 'Customer left' }], 'no status, tenant, actor or time')
  assert.equal(done.phase, CANCEL_PHASES.SUCCESS)
  assert.deepEqual(done.result, { orderNumber: 'QS-260926-AB12', reason: 'Customer left', replayed: false })
  assert.equal(await submitCancel(done, async () => { throw new Error('must not be called') }), done, 'nothing is sent from a finished attempt')
  assert.equal(resetCancel(done).phase, CANCEL_PHASES.IDLE)
  // a replay from the server is reported as such
  const replay = await submitCancel(beginCancelSubmit(confirming('Customer left')), async () => ({ ok: true, replayed: true, orderNumber: 'QS-1', status: 'cancelled', reason: 'Customer left' }))
  assert.equal(replay.result.replayed, true)
})

test('every server answer has a plain outcome: refused, not allowed, signed out, and result unknown with a safe retry of the SAME reason', async () => {
  const attempt = () => beginCancelSubmit(confirming('Customer left'))
  const refused = await submitCancel(attempt(), async () => { throw httpError(400, 'This order has a payment and cannot be cancelled.', '22023') })
  assert.equal(refused.phase, CANCEL_PHASES.REJECTED)
  assert.match(refused.error, /has a payment/)
  assert.equal(resetCancel(refused).phase, CANCEL_PHASES.IDLE)
  const already = await submitCancel(attempt(), async () => { throw httpError(400, 'This order is already cancelled.', '22023') })
  assert.equal(already.phase, CANCEL_PHASES.REJECTED)
  const denied = await submitCancel(attempt(), async () => { throw httpError(403, 'Only a Quick Solution admin or owner can cancel a counter order.', '42501') })
  assert.equal(denied.phase, CANCEL_PHASES.DENIED)
  assert.equal(resetCancel(denied).phase, CANCEL_PHASES.IDLE)
  // signed out: the reason is kept and the confirmation comes back after signing in
  const out = await submitCancel(attempt(), async () => { throw httpError(401, 'Staff sign-in is required.') })
  assert.equal(out.phase, CANCEL_PHASES.SIGNED_OUT)
  const back = resumeCancelAfterSignIn(out)
  assert.equal(back.phase, CANCEL_PHASES.CONFIRMING)
  assert.equal(back.reason, 'Customer left')
  assert.equal(resumeCancelAfterSignIn(back), back)
  // unknown: locked, and the retry sends the same reason
  const unknown = await submitCancel(attempt(), async () => { throw new Error('Failed to fetch') })
  assert.equal(unknown.phase, CANCEL_PHASES.UNKNOWN)
  assert.equal(isCancelLocked(unknown), true)
  assert.equal(abortCancel(unknown), unknown, 'an unknown result cannot be dropped')
  assert.equal(resetCancel(unknown), unknown)
  const retry = beginCancelSubmit(unknown)
  assert.equal(retry.phase, CANCEL_PHASES.SUBMITTING)
  assert.equal(retry.attempt.reason, 'Customer left')
  assert.equal(retry.attempt.submissions, 2)
  const seen = []
  await submitCancel(retry, async (payload) => { seen.push(payload); return { ok: true, replayed: true, orderNumber: 'QS-1', status: 'cancelled', reason: 'Customer left' } })
  assert.deepEqual(seen, [{ orderId: order().orderId, reason: 'Customer left' }])
  // a malformed answer and a timeout are unknown, never a success
  assert.equal((await submitCancel(attempt(), async () => ({ ok: true }))).phase, CANCEL_PHASES.UNKNOWN)
  assert.equal((await submitCancel(attempt(), async () => null)).phase, CANCEL_PHASES.UNKNOWN)
  assert.equal((await submitCancel(attempt(), () => new Promise(() => {}), 10)).phase, CANCEL_PHASES.UNKNOWN)
})

// ── the screen ──────────────────────────────────────────────────────────
test('an admin sees Cancel order on an unpaid order; a plain member, a blocked order and a paid order do not', () => {
  const admin = screen({ cancelCheck: checkOf() })
  assert.ok(buttonsOf(admin).includes('Cancel order'))
  assert.ok(buttonsOf(admin).includes('Record Cash Payment'), 'payment is untouched')
  assert.equal(buttonsOf(screen({ cancelCheck: checkOf({ permitted: false }) })).includes('Cancel order'), false, 'a plain member never sees it')
  assert.doesNotMatch(text(screen({ cancelCheck: checkOf({ permitted: false }) })), /cancel/i, 'not even a hint for a member')
  const blocked = screen({ cancelCheck: checkOf({ cancellable: false, block: 'sent_to_production' }) })
  assert.equal(buttonsOf(blocked).includes('Cancel order'), false)
  assert.match(text(blocked), /already been sent to production and cannot be cancelled here/)
  for (const none of [undefined, { status: 'none' }, { status: 'unavailable', message: 'x' }, { status: 'loading' }]) assert.equal(buttonsOf(screen({ cancelCheck: none })).includes('Cancel order'), false)
  const paid = order({ paymentStatus: 'paid', amountPaid: 35, outstanding: 0, paymentAllowed: false, payments: [{ paymentId: 'p1', method: 'cash', amount: 35, paidAt: '2026-09-26T11:30:00+00:00' }] })
  assert.equal(buttonsOf(screen({ cancelCheck: checkOf() }, paid)).includes('Cancel order'), false, 'a paid order can never be cancelled here')
})

test('the confirmation asks for a reason, hides the payment buttons, and Keep order / Cancel this order are the only ways forward', () => {
  const view = screen({ cancelCheck: checkOf(), cancel: confirming('') })
  assert.match(text(view), /Cancel order QS-260926-AB12\?/)
  assert.match(text(view), /Nothing has been paid on this order/)
  assert.match(text(view), /Your name, the time and the reason are recorded/)
  assert.match(view, /<textarea[^>]*maxLength="300"|<textarea[^>]*maxlength="300"/i)
  assert.deepEqual(buttonsOf(view).filter((label) => /cancel|keep|record/i.test(label)), ['Keep order', 'Cancel this order'], 'no payment buttons while cancelling')
  assert.match(text(screen({ cancelCheck: checkOf(), cancel: beginCancelSubmit(setCancelReason(beginCancel(initialCancel(), checkOf(), order()), 'x')) })), /at least 3/, 'a short reason shows its message')
  const busy = screen({ cancelCheck: checkOf(), cancel: beginCancelSubmit(confirming('Customer left')) })
  assert.match(busy, /Cancelling…/)
  assert.match(busy, /aria-busy="true"/)
  assert.equal([...busy.matchAll(/<button[^>]*disabled[^>]*>/g)].length >= 2, true, 'both buttons are disabled while it runs')
})

test('the buttons call the page handlers: start, reason, keep, confirm, reload', () => {
  const calls = []
  const handlers = { onStartCancel: () => calls.push('start'), onCancelReason: (value) => calls.push(`reason:${value}`), onAbortCancel: () => calls.push('abort'), onConfirmCancel: () => calls.push('confirm'), onResetCancel: () => calls.push('reset') }
  const idle = nodesOf({ cancelCheck: checkOf(), ...handlers })
  idle.find((node) => node.type === 'button' && labelOf(node) === 'Cancel order').props.onClick()
  const form = nodesOf({ cancelCheck: checkOf(), cancel: confirming('abc'), ...handlers })
  form.find((node) => node.type === 'textarea').props.onChange({ target: { value: 'Left without paying' } })
  form.find((node) => node.type === 'button' && labelOf(node) === 'Keep order').props.onClick()
  form.find((node) => node.type === 'button' && labelOf(node) === 'Cancel this order').props.onClick()
  const problem = nodesOf({ cancelCheck: checkOf(), cancel: { ...confirming('abc'), phase: CANCEL_PHASES.REJECTED, error: 'This order is already cancelled.' }, ...handlers })
  problem.find((node) => node.type === 'button' && labelOf(node) === 'Reload order').props.onClick()
  assert.deepEqual(calls, ['start', 'reason:Left without paying', 'abort', 'confirm', 'reset'])
})

test('every outcome is shown plainly; a cancelled order says so, owes nothing and cannot be paid', () => {
  const sent = beginCancelSubmit(confirming('Customer left'))
  const unknown = screen({ cancelCheck: checkOf(), cancel: { ...sent, phase: CANCEL_PHASES.UNKNOWN, error: 'The cancellation may already have been recorded. Retry safely to confirm the result.' } })
  assert.match(text(unknown), /Result not confirmed/)
  assert.ok(buttonsOf(unknown).includes('Retry safely'))
  const refused = screen({ cancelCheck: checkOf(), cancel: { ...sent, phase: CANCEL_PHASES.REJECTED, error: 'This order has a payment and cannot be cancelled.' } })
  assert.match(text(refused), /Order not cancelled.*has a payment and cannot be cancelled/)
  const denied = screen({ cancelCheck: checkOf(), cancel: { ...sent, phase: CANCEL_PHASES.DENIED, error: 'Only a Quick Solution admin or owner can cancel a counter order.' } })
  assert.match(text(denied), /Not allowed.*admin or owner/)
  const signedOut = screen({ cancelCheck: checkOf(), cancel: { ...sent, phase: CANCEL_PHASES.SIGNED_OUT, error: 'Your staff session has ended. Sign in again to finish cancelling this order.' } })
  assert.match(text(signedOut), /Sign in to finish cancelling/)
  const success = screen({ cancelCheck: checkOf(), cancel: { ...sent, phase: CANCEL_PHASES.SUCCESS, result: { orderNumber: 'QS-260926-AB12', reason: 'Customer left', replayed: false } } }, order({ status: 'cancelled' }))
  assert.match(text(success), /Order cancelled QS-260926-AB12 was cancelled\. Reason: Customer left/)
  // the reloaded, cancelled order
  const cancelled = screen({ cancelCheck: { status: 'none' } }, order({ status: 'cancelled' }))
  assert.match(text(cancelled), /Cancelled/)
  assert.match(text(cancelled), /This order is cancelled\. Nothing is owed and it cannot be paid\./)
  assert.match(screen({ cancelCheck: { status: 'none' } }, order({ status: 'cancelled' })), /qsc-state-cancelled/)
  assert.doesNotMatch(screen({ cancelCheck: { status: 'none' } }, order({ status: 'cancelled' })), /qsc-state-unpaid/, 'the badge is not Unpaid')
  assert.match(text(cancelled), /Outstanding R\s?0,00/)
  const labels = buttonsOf(cancelled)
  assert.equal(labels.some((label) => /Record|Cancel order|View receipt/.test(label)), false, 'no payment, cancel or receipt action on a cancelled order')
})

test('paying is unchanged: a payment in progress hides the cancel action and the payment confirmation still works', () => {
  const paying = { ...initialPayment(), phase: PAYMENT_PHASES.CONFIRMING, attempt: { orderId: order().orderId, orderNumber: 'QS-260926-AB12', method: 'cash', amountLabel: 'R 35,00', idempotencyKey: 'k'.repeat(12), submissions: 0 } }
  const view = screen({ cancelCheck: checkOf(), payment: paying })
  assert.equal(buttonsOf(view).includes('Cancel order'), false, 'no cancelling while a payment is being confirmed')
  assert.match(text(view), /Record R\s?35,00 as Cash\?/)
})

// ── the page and the wrapper ────────────────────────────────────────────
test('the API wrapper sends only the order id and the reason; the check sends only the order id', () => {
  const api = stripComments(read('../src/lib/supabaseApi.js'))
  const cancel = api.match(/export async function cancelQuickSolutionCounterOrder\(\{ orderId, reason \}\) \{[\s\S]*?\n\}/)[0]
  assert.match(cancel, /rpc\('cancel_quick_solution_counter_order', \{ p_order_id: orderId, p_reason: reason \}, \{ accessToken \}\)/)
  assert.doesNotMatch(cancel, /tenant|status|actor|channel|userId|timestamp|Date/i)
  const check = api.match(/export async function loadQuickSolutionCounterOrderCancelCheck\(orderId\) \{[\s\S]*?\n\}/)[0]
  assert.match(check, /rpc\('get_quick_solution_counter_order_cancel_check', \{ p_order_id: orderId \}, \{ accessToken \}\)/)
})

test('the page makes one cancel call per confirmation, reloads the order after every answer, and never removes anything locally', () => {
  const page = stripComments(read('../src/counter/CounterPage.jsx'))
  assert.equal((page.match(/cancelQuickSolutionCounterOrder/g) || []).length, 2, 'imported once, used once')
  assert.equal((page.match(/submitCancel\(/g) || []).length, 1)
  assert.match(page, /if \(cancelInFlight\.current\) return/)
  assert.match(page, /cancelInFlight\.current = true[\s\S]*?finally \{\s*cancelInFlight\.current = false/)
  assert.match(page, /submitCancel\(started, cancelQuickSolutionCounterOrder\)/)
  assert.match(page, /\[CANCEL_PHASES\.SUCCESS, CANCEL_PHASES\.REJECTED, CANCEL_PHASES\.DENIED\]\.includes\(next\.phase\)\) loadDetail\(orderId\)/)
  assert.match(page, /loadCounterCancelCheckState\(loadQuickSolutionCounterOrderCancelCheck, orderId\)/)
  assert.match(page, /next\.order\.status !== 'cancelled' && next\.order\.paymentStatus !== 'paid'/, 'the check is only asked for an order that could still be cancelled')
  assert.match(page, /setCancels\(\{\}\)/, 'the whole page reload clears the attempts')
  assert.match(page, /cancel\.phase === CANCEL_PHASES\.SIGNED_OUT\) \{ setCancel\(\(current\) => resumeCancelAfterSignIn\(current\)\)/)
  assert.doesNotMatch(page, /\.filter\(\(order\)|\.splice\(|\.\.\.current, orders/, 'no list is edited locally: the server is asked again on Back')
  const imported = page.match(/import \{([^}]*)\} from '\.\.\/lib\/supabaseApi\.js'/)[1].split(',').map((name) => name.trim()).filter(Boolean)
  const writes = imported.filter((name) => /^(create|record|cancel|void|refund|update|delete|set)/i.test(name))
  assert.deepEqual(writes, ['cancelQuickSolutionCounterOrder', 'createQuickSolutionCounterOrder', 'recordQuickSolutionCounterPayment'], 'exactly three write calls: create, pay, cancel')
})

test('the screen decides nothing about permission and offers no void, refund, delete, reopen or bulk action', () => {
  const view = stripComments(read('../src/counter/CounterView.jsx'))
  const lib = stripComments(read('../src/lib/counterCancel.js'))
  const page = stripComments(read('../src/counter/CounterPage.jsx'))
  for (const source of [view, lib, page]) {
    assert.doesNotMatch(source, /cafe\.[a-z_.]+|operations\.manage|counter\.operate|tenantRole|is_app_admin|isAdmin|isOwner/, 'the front end never names a capability or a role')
  }
  assert.doesNotMatch(lib + view.slice(view.indexOf('function CancelArea'), view.indexOf('function OrderDetailPanel')), /refund|voidOrder|\bdelete\b|reopen|restore|undo|bulk|selectAll|exportCsv|downloadFile|\.csv|fetch\s*\(|\brpc\s*\(/i)
  assert.doesNotMatch(lib, /localStorage|sessionStorage|Date\.now|new Date/, 'no clock, no local record: the server records who and when')
  assert.equal((view.match(/Cancel this order/g) || []).length, 1, 'one confirm button')
})

test('the SQL contract test and this file are part of npm test and the harness', () => {
  const pkg = JSON.parse(read('../package.json'))
  assert.match(pkg.scripts.test, /tests\/counter-cancel\.test\.mjs/)
  assert.match(read('./db-harness.test.mjs'), /'cafe_guest_01v'/)
  const sql = read('../supabase/migrations/20260926280000_cafe_guest_01v_cancel_unpaid_counter_order.sql').replace(/--[^\n]*/g, '')
  assert.match(sql, /has_tenant_capability\(v_tenant_id, 'cafe\.operations\.manage'\)/)
  assert.match(sql, /grant execute on function public\.cancel_quick_solution_counter_order\(uuid, text\)\s*to authenticated;/)
  assert.doesNotMatch(sql, /grant [^;]*(anon|service_role)/i)
  assert.match(sql, /before update or delete on commerce\.service_order_cancellations/)
  assert.match(sql, /before truncate on commerce\.service_order_cancellations/)
  assert.match(read('../supabase/tests/cafe_guest_01v_cancel_unpaid_counter_order.sql'), /CAFE-GUEST-01V cancel unpaid counter order contracts passed/)
})
