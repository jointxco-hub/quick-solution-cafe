import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'
import { loadCounterUi } from './helpers/counter-ui-harness.mjs'
import { products as seedProducts } from '../src/data/products.js'
import { buildA4CounterPrintConfig } from '../src/lib/counterPrintConfig.js'
import { formatMoney } from '../src/lib/pricing.js'
import { createCounterDraft, loadCounterCatalogueState, setCounterDraftValue } from '../src/lib/counterDraft.js'
import {
  COUNTER_FIRST_WRITE_PRODUCT_KEYS,
  COUNTER_NOT_READY_MESSAGE,
  COUNTER_SUBMISSION,
  isCounterSubmissionEnabled,
  resolveCounterSubmission
} from '../src/lib/counterSubmissionReadiness.js'
import {
  COUNTER_UNKNOWN_RESULT_MESSAGE,
  SALE_PHASES,
  backToEdit,
  beginSubmit,
  classifyCounterSubmitError,
  createSaleAttemptKey,
  initialSale,
  isSaleLocked,
  resumeAfterSignIn,
  reviewSale,
  startNewSale,
  submitSale,
  validateCounterCustomer
} from '../src/lib/counterSale.js'

// CAFE-GUEST-01O - the first writable Counter flow: one unpaid order for Scan, A4 Lamination, A3 Lamination
// and the physical A4 print. The API is never real: a fake `create` records what would be sent, and the
// screen states are the real components rendered to HTML (tests/helpers/counter-ui-harness.mjs).

const read = (path) => fs.readFileSync(new URL(path, import.meta.url), 'utf8')
const stripComments = (text) => text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:'"`])\/\/[^\n]*/g, '$1')
const ui = await loadCounterUi()
const h = ui.React.createElement
const html = (element) => ui.renderToStaticMarkup(element)

const byId = new Map(seedProducts.map((product) => [product.id, product]))
const serverProducts = seedProducts.filter((product) => product.channels?.pos === true)
const ready = await loadCounterCatalogueState(async () => ({ tenant: { slug: 'quick-solution', name: 'Quick Solution' }, products: serverProducts }))
const entry = (id) => ready.entries.find((item) => item.product.id === id)

const draftFor = (id, values = {}) => {
  let draft = createCounterDraft(byId.get(id))
  for (const [key, value] of Object.entries(values)) draft = setCounterDraftValue(draft, byId.get(id), key, value)
  return draft
}
const counter = () => { let n = 0; return () => `key-${String(++n).padStart(8, '0')}` }
const PRINT = { pages: '12', copies: '3', printMode: 'bw', sides: 'single', finish: 'none' }
const INPUTS = {
  scan: { units: '7' },
  'a4-lamination': { units: '4' },
  'a3-lamination': { units: '2' },
  'a4-print': PRINT
}
const confirm = (id = 'scan', customer = {}, makeKey = counter(), sale = initialSale(), values = INPUTS[id]) =>
  reviewSale(sale, { entry: entry(id), draft: draftFor(id, values), customer }, makeKey)

function fakeCreate({ total = 35, fail = null } = {}) {
  const calls = []
  const create = async (payload) => {
    calls.push(JSON.parse(JSON.stringify(payload)))
    if (fail) throw fail
    return {
      ok: true, replayed: false, orderId: 'order-uuid', orderNumber: 'QS-2026-0001', status: 'submitted', paymentStatus: 'unpaid', channel: 'counter',
      createdAt: '2026-09-26T10:00:00Z', customerName: payload.customerName || 'Walk-in', customerEmail: payload.customerEmail, customerPhone: payload.customerPhone,
      productKey: payload.productKey, productName: byId.get(payload.productKey).name, configuration: payload.configuration,
      lineTotal: total, subtotal: total, fulfilmentFee: 0, totalAmount: total
    }
  }
  return { create, calls }
}
const submit = (sale, create, timeout) => submitSale(beginSubmit(sale), create, timeout)
const keysDeep = (value, found = new Set()) => {
  if (Array.isArray(value)) value.forEach((item) => keysDeep(item, found))
  else if (value && typeof value === 'object') for (const [key, child] of Object.entries(value)) { found.add(key); keysDeep(child, found) }
  return found
}
const httpError = (message, status, code) => Object.assign(new Error(message), { status, payload: code ? { code } : null })

function saleScreen(sale, extra = {}) {
  return html(h(ui.CounterView, { state: ready, selectedId: sale.attempt?.request.productKey || null, sale, ...extra }))
}
const buttonsOf = (markup) => [...markup.matchAll(/<button[^>]*>([\s\S]*?)<\/button>/g)].map((match) => match[1].replace(/<[^>]+>/g, ''))
const saleSection = (markup) => markup.slice(markup.indexOf('class="qsc-sale'))

// ── submission readiness ────────────────────────────────────────────────
test('exactly Scan, A4 Lamination, A3 Lamination and A4 Print are writable; nothing else is', () => {
  assert.deepEqual([...COUNTER_FIRST_WRITE_PRODUCT_KEYS], ['scan', 'a4-lamination', 'a3-lamination', 'a4-print'])
  assert.equal(Object.isFrozen(COUNTER_FIRST_WRITE_PRODUCT_KEYS), true)
  const writable = ready.entries.filter((item) => isCounterSubmissionEnabled(item)).map((item) => item.product.id)
  assert.deepEqual(writable.sort(), [...COUNTER_FIRST_WRITE_PRODUCT_KEYS].sort())
})

test('every other ordinary order product stays visible and previewable but has no write action', () => {
  const others = ready.entries.filter((item) => item.action === 'order' && !COUNTER_FIRST_WRITE_PRODUCT_KEYS.includes(item.product.id))
  assert.deepEqual(others.map((item) => item.product.id).sort(), ['business-cards', 'flags', 'gazebos', 'printed-tshirt', 'pvc-banner', 'vinyl-stickers'])
  for (const item of others) {
    assert.deepEqual(resolveCounterSubmission(item), { status: COUNTER_SUBMISSION.NOT_READY, message: 'Counter ordering for this product is not ready yet.' })
    const markup = html(h(ui.CounterView, { state: ready, selectedId: item.product.id, draft: createCounterDraft(item.product) }))
    assert.match(markup, new RegExp(`data-product-id="${item.product.id}"`), 'still in the catalogue')
    assert.match(markup, /Order preview/, 'still previewable')
    assert.match(markup, /Counter ordering for this product is not ready yet\./)
    assert.doesNotMatch(markup, /Review order|Create unpaid order|Customer <small>/)
    assert.deepEqual(buttonsOf(markup).filter((text) => /review|create|submit/i.test(text)), [])
    const sale = initialSale()
    assert.equal(reviewSale(sale, { entry: item, draft: createCounterDraft(item.product), customer: {} }), sale, 'cannot even freeze a request')
  }
  assert.equal(COUNTER_NOT_READY_MESSAGE, 'Counter ordering for this product is not ready yet.')
})

test('request products stay request-only, whatever their key', () => {
  for (const id of ['media-services', 'photo-session']) {
    assert.equal(resolveCounterSubmission(entry(id)).status, COUNTER_SUBMISSION.REQUEST)
    const markup = html(h(ui.CounterView, { state: ready, selectedId: id, draft: createCounterDraft(byId.get(id)) }))
    assert.match(markup, /Request workflow coming next/)
    assert.doesNotMatch(markup, /Review order|Create unpaid order|not ready yet/)
  }
  // a request-style product is never writable even if it were named in the list
  const disguised = { product: { ...byId.get('scan'), pricing: { strategy: 'ENQUIRY' } }, action: 'request' }
  assert.equal(isCounterSubmissionEnabled(disguised), false)
})

test('the readiness rule is a rollout boundary, not authorization: the server still decides every call', async () => {
  const source = read('../src/lib/counterSubmissionReadiness.js')
  assert.match(source, /server counter-sellable\s+!=\s+currently supported by the first Counter UI write workflow/)
  assert.match(source, /provides NO authorization/)
  const code = stripComments(source)
  assert.doesNotMatch(code, /supabaseApi|capabilit|auth|session|tenant|has_tenant|cafe\./i)
  // a writable product whose server call is refused is refused: the rule changes nothing about that
  const denied = fakeCreate({ fail: httpError('You do not have access to the Quick Solution counter.', 403, '42501') })
  const next = await submit(confirm('scan'), denied.create)
  assert.equal(next.phase, SALE_PHASES.DENIED)
  assert.equal(denied.calls.length, 1)
  // product keys are checked in this one module only
  for (const file of ['../src/counter/CounterPage.jsx', '../src/counter/CounterView.jsx', '../src/lib/counterSale.js', '../src/lib/counterDraft.js']) {
    assert.doesNotMatch(stripComments(read(file)), /['"](scan|a4-lamination|a3-lamination)['"]|COUNTER_FIRST_WRITE_PRODUCT_KEYS/, file)
  }
})

// ── customer ────────────────────────────────────────────────────────────
test('blank customer details are sent as nulls: the server, not the UI, records Walk-in', async () => {
  for (const customer of [{}, { name: '', email: '', phone: '' }, { name: '   ', email: ' ', phone: '\t' }, undefined]) {
    const sale = confirm('scan', customer)
    assert.deepEqual([sale.attempt.request.customerName, sale.attempt.request.customerEmail, sale.attempt.request.customerPhone], [null, null, null])
    const { create, calls } = fakeCreate()
    await submit(sale, create)
    assert.deepEqual([calls[0].customerName, calls[0].customerEmail, calls[0].customerPhone], [null, null, null])
  }
  assert.equal(sale0().attempt.summary.customerLabel, 'Walk-in')
  assert.doesNotMatch(stripComments(read('../src/lib/counterSale.js')), /['"]Walk-in['"]/, 'no second Walk-in rule: the label is the display constant only')
})
function sale0() { return confirm('scan') }

test('supplied name, email and phone are passed on trimmed and otherwise unchanged', async () => {
  const sale = confirm('a4-lamination', { name: '  Thandi Nkosi ', email: ' Thandi@Example.com ', phone: ' 075 123 4567 ' })
  const { create, calls } = fakeCreate()
  await submit(sale, create)
  assert.deepEqual([calls[0].customerName, calls[0].customerEmail, calls[0].customerPhone], ['Thandi Nkosi', 'Thandi@Example.com', '075 123 4567'])
  assert.equal(sale.attempt.summary.customerLabel, 'Thandi Nkosi')
  const partial = confirm('scan', { phone: '0751234567' })
  assert.deepEqual([partial.attempt.request.customerName, partial.attempt.request.customerEmail, partial.attempt.request.customerPhone], [null, null, '0751234567'])
})

test('basic customer checks stop obviously bad input before confirmation; nothing is ever required', () => {
  assert.equal(validateCounterCustomer({}).ok, true)
  assert.equal(validateCounterCustomer({ name: 'A' }).ok, false)
  assert.equal(validateCounterCustomer({ name: 'x'.repeat(161) }).ok, false)
  assert.equal(validateCounterCustomer({ email: 'nope' }).ok, false)
  assert.equal(validateCounterCustomer({ email: 'a@b' }).ok, true)
  assert.equal(validateCounterCustomer({ phone: '123' }).ok, false)
  assert.equal(validateCounterCustomer({ phone: '+27 75 123 4567' }).ok, true)
  const sale = initialSale()
  assert.equal(confirm('scan', { email: 'bad' }, counter(), sale), sale, 'an invalid customer does not freeze a request')
  const markup = html(h(ui.CounterView, { state: ready, selectedId: 'scan', draft: draftFor('scan', { units: '3' }), customer: { name: '', email: 'bad', phone: '' } }))
  assert.match(markup, /Enter a valid email address, or leave it blank\./)
  assert.match(markup, /<button[^>]*disabled=""[^>]*>Review order/)
  assert.match(markup, /placeholder="Walk-in"/)
})

test('no customer account, search or linking exists in this flow', () => {
  for (const file of ['../src/counter/CounterPage.jsx', '../src/counter/CounterView.jsx', '../src/lib/counterSale.js']) {
    assert.doesNotMatch(stripComments(read(file)), /customerId|clientId|accountId|linkCustomer|linkClient|searchCustomer|searchClient|lookup|createCustomer|xlab/i, file)
  }
})

// ── payload ─────────────────────────────────────────────────────────────
for (const [id, expected] of [['scan', { units: 7 }], ['a4-lamination', { units: 4 }], ['a3-lamination', { units: 2 }], ['a4-print', buildA4CounterPrintConfig({ pages: 12, copies: 3, printMode: 'bw', sides: 'single', finish: 'none' })]]) {
  test(`${id}: one create call with only the key, product, configuration and customer - and never a server-owned field`, async () => {
    const { create, calls } = fakeCreate()
    const sale = confirm(id, { name: 'Sipho' })
    const done = await submit(sale, create)
    assert.equal(done.phase, SALE_PHASES.SUCCESS)
    assert.equal(calls.length, 1, 'exactly one create call')
    assert.deepEqual(Object.keys(calls[0]).sort(), ['configuration', 'customerEmail', 'customerName', 'customerPhone', 'idempotencyKey', 'productKey'])
    assert.equal(calls[0].productKey, id)
    assert.deepEqual(calls[0].configuration, expected)
    assert.match(calls[0].idempotencyKey, /^key-\d{8}$/)
    assert.equal(Array.isArray(calls[0].configuration), false, 'one item, not a list')
    for (const key of keysDeep(calls[0])) {
      assert.doesNotMatch(key, /tenant|channel|created|actor|price|total|amount|payment|paid|method|status|quantity|items|file|upload/i, key)
    }
  })
}

test('A4 print: the adapter output is submitted unchanged, with no fake file data and no quantity', async () => {
  const draft = draftFor('a4-print', PRINT)
  const sale = reviewSale(initialSale(), { entry: entry('a4-print'), draft, customer: {} }, counter())
  const adapter = buildA4CounterPrintConfig({ pages: 12, copies: 3, printMode: 'bw', sides: 'single', finish: 'none' })
  assert.deepEqual(sale.attempt.request.configuration, adapter)
  const { create, calls } = fakeCreate()
  await submit(sale, create)
  assert.deepEqual(calls[0].configuration, adapter)
  assert.deepEqual([...keysDeep(calls[0].configuration)].sort(), ['copies', 'documentInstructions', 'documentPlanValid', 'finish', 'pages', 'printMode', 'selection', 'sides', 'sourcePages'])
  assert.equal('quantity' in calls[0].configuration, false)
  assert.equal(calls[0].configuration.documentInstructions.length, 1)
  // the sale layer never rebuilds the shape at submit time
  assert.doesNotMatch(stripComments(read('../src/lib/counterSale.js')), /buildA4CounterPrintConfig|documentInstructions|documentPlanValid|sourcePages/)
})

test('the frozen request is a copy: editing the draft afterwards cannot change what is sent', async () => {
  let draft = draftFor('scan', { units: '5' })
  const sale = reviewSale(initialSale(), { entry: entry('scan'), draft, customer: {} }, counter())
  draft = setCounterDraftValue(draft, byId.get('scan'), 'units', '99')
  const { create, calls } = fakeCreate()
  await submit(sale, create)
  assert.deepEqual(calls[0].configuration, { units: 5 })
})

// ── idempotency ─────────────────────────────────────────────────────────
test('one key per sale attempt, made at confirmation, never shown', () => {
  const makeKey = counter()
  const sale = confirm('scan', {}, makeKey)
  assert.equal(sale.attempt.request.idempotencyKey, 'key-00000001')
  assert.equal(makeKey(), 'key-00000002', 'confirming used exactly one key')
  const key = createSaleAttemptKey()
  assert.ok(key.length >= 8 && key.length <= 128, 'within the server bounds')
  assert.notEqual(key, createSaleAttemptKey())
  for (const state of [sale, beginSubmit(sale)]) assert.doesNotMatch(saleScreen(state), /key-0000|idempotency/i)
  assert.doesNotMatch(html(h(ui.CounterView, { state: ready, selectedId: 'scan', draft: draftFor('scan', { units: '2' }) })), /idempotency/i)
})

test('a repeated Create click or retry sends the same key: only the phase guard and the server keep it to one order', async () => {
  const { create, calls } = fakeCreate()
  const confirming = confirm('scan')
  const first = beginSubmit(confirming)
  assert.equal(first.phase, SALE_PHASES.SUBMITTING)
  assert.equal(beginSubmit(first), first, 'a second click while submitting starts nothing')
  assert.equal(beginSubmit(initialSale()).phase, SALE_PHASES.EDITING, 'nothing to submit before confirmation')
  const done = await submitSale(first, create)
  assert.equal(done.phase, SALE_PHASES.SUCCESS)
  assert.equal(await submitSale(done, create), done, 'a finished sale is never submitted again')
  assert.equal(calls.length, 1)
  assert.equal(beginSubmit(done), done)
})

test('an unknown network result keeps the draft and the SAME key, and retrying sends exactly the same request', async () => {
  const makeKey = counter()
  const confirming = confirm('a4-print', { name: 'Lerato' }, makeKey)
  const failing = fakeCreate({ fail: new TypeError('Failed to fetch') })
  const unknown = await submit(confirming, failing.create)
  assert.equal(unknown.phase, SALE_PHASES.UNKNOWN)
  assert.equal(unknown.error, COUNTER_UNKNOWN_RESULT_MESSAGE)
  assert.equal(unknown.attempt.request.idempotencyKey, confirming.attempt.request.idempotencyKey)
  assert.deepEqual(unknown.attempt.request, confirming.attempt.request, 'draft intact')
  const ok = fakeCreate()
  const retried = await submit(unknown, ok.create)
  assert.equal(retried.phase, SALE_PHASES.SUCCESS)
  assert.deepEqual(ok.calls[0], failing.calls[0], 'byte-for-byte the same request')
  assert.equal(retried.attempt.submissions, 2)
  assert.equal(makeKey(), 'key-00000002', 'no new key was made')
  // other uncertain outcomes are unknown too, never rejections
  for (const failure of [httpError('Bad gateway', 502), httpError('Service unavailable', 503), new Error('boom'), new TypeError('NetworkError when attempting to fetch resource.')]) {
    assert.equal((await submit(confirming, fakeCreate({ fail: failure }).create)).phase, SALE_PHASES.UNKNOWN, failure.message)
  }
  assert.equal((await submit(confirming, async () => ({ ok: true }))).phase, SALE_PHASES.UNKNOWN, 'an unreadable success is unknown')
  assert.equal((await submit(confirming, async () => null)).phase, SALE_PHASES.UNKNOWN)
  const timed = await submitSale(beginSubmit(confirming), () => new Promise(() => {}), 15)
  assert.equal(timed.phase, SALE_PHASES.UNKNOWN, 'a request that never answers becomes unknown, not stuck')
})

test('while the result is unknown the request is locked: no edit, no new key, no other product', async () => {
  const unknown = await submit(confirm('scan'), fakeCreate({ fail: new TypeError('Failed to fetch') }).create)
  assert.equal(isSaleLocked(unknown), true)
  assert.equal(backToEdit(unknown), unknown)
  assert.equal(reviewSale(unknown, { entry: entry('scan'), draft: draftFor('scan', { units: '9' }), customer: {} }, counter()), unknown)
  const markup = saleScreen(unknown)
  assert.match(markup, /data-product-id="scan"[^>]*disabled=""|disabled=""[^>]*data-product-id="scan"/, 'the product list is locked')
  assert.match(markup, /Retry safely/)
  assert.match(markup, /Start new sale/)
  assert.doesNotMatch(saleScreen(unknown), /Back to edit|Edit order/)
})

test('success then Start new sale produces a different key for the next sale', async () => {
  const makeKey = counter()
  const first = confirm('scan', {}, makeKey)
  const done = await submit(first, fakeCreate().create)
  assert.equal(done.phase, SALE_PHASES.SUCCESS)
  const fresh = startNewSale()
  assert.deepEqual(fresh, initialSale())
  assert.equal(fresh.attempt, null)
  const second = reviewSale(fresh, { entry: entry('scan'), draft: draftFor('scan', INPUTS.scan), customer: {} }, makeKey)
  assert.notEqual(second.attempt.request.idempotencyKey, first.attempt.request.idempotencyKey, 'same request, new sale: new key')
})

test('a materially different request before submission gets a new key; the identical request keeps its own', () => {
  const makeKey = counter()
  const at = (id, values, customer = {}, sale) => reviewSale(sale, { entry: entry(id), draft: draftFor(id, values), customer }, makeKey)
  const a = at('scan', { units: '7' }, {}, initialSale())
  assert.equal(a.attempt.request.idempotencyKey, 'key-00000001')
  const back = backToEdit(a)
  assert.equal(back.phase, SALE_PHASES.EDITING)
  assert.equal(at('scan', { units: '7' }, {}, back).attempt.request.idempotencyKey, 'key-00000001', 'nothing changed: same key')
  assert.equal(at('scan', { units: '8' }, {}, back).attempt.request.idempotencyKey, 'key-00000002', 'configuration changed')
  assert.equal(at('a4-lamination', { units: '7' }, {}, back).attempt.request.idempotencyKey, 'key-00000003', 'product changed')
  assert.equal(at('scan', { units: '7' }, { name: 'Zed Zed' }, back).attempt.request.idempotencyKey, 'key-00000004', 'customer changed')
})

test('a server rejection keeps the draft; the staff can fix it, and only a changed request gets a new key', async () => {
  const makeKey = counter()
  const confirming = confirm('scan', {}, makeKey)
  const rejected = await submit(confirming, fakeCreate({ fail: httpError('Units are outside the supported range.', 400, '22023') }).create)
  assert.equal(rejected.phase, SALE_PHASES.REJECTED)
  assert.equal(rejected.error, 'Units are outside the supported range.', 'the server message is shown as sent')
  assert.match(saleScreen(rejected), /Units are outside the supported range\.[\s\S]*Nothing was created[\s\S]*Edit order/)
  const editing = backToEdit(rejected)
  assert.equal(editing.phase, SALE_PHASES.EDITING)
  assert.equal(reviewSale(editing, { entry: entry('scan'), draft: draftFor('scan', INPUTS.scan), customer: {} }, makeKey).attempt.request.idempotencyKey, confirming.attempt.request.idempotencyKey)
  assert.notEqual(reviewSale(editing, { entry: entry('scan'), draft: draftFor('scan', { units: '3' }), customer: {} }, makeKey).attempt.request.idempotencyKey, confirming.attempt.request.idempotencyKey)
})

test('an idempotency conflict is never retried with a new key: it needs a new sale', async () => {
  const { create, calls } = fakeCreate({ fail: httpError('This idempotency key was already used for a different order request.', 409, '23505') })
  const conflict = await submit(confirm('scan'), create)
  assert.equal(conflict.phase, SALE_PHASES.CONFLICT)
  assert.equal(calls.length, 1, 'no automatic retry')
  assert.equal(beginSubmit(conflict), conflict, 'cannot be submitted again')
  assert.equal(backToEdit(conflict), conflict)
  assert.equal(isSaleLocked(conflict), true)
  const markup = saleScreen(conflict)
  assert.match(markup, /already used for a different order request/)
  assert.match(markup, /Start new sale/)
  assert.doesNotMatch(markup, /Retry safely|Create unpaid order/)
  assert.equal(classifyCounterSubmitError({ message: 'duplicate key', payload: { code: '23505' } }).kind, SALE_PHASES.CONFLICT)
})

// ── access and session ──────────────────────────────────────────────────
test('a lost session is not retried silently: sign in, then resume the same request with the same key', async () => {
  const makeKey = counter()
  const confirming = confirm('scan', {}, makeKey)
  for (const failure of [new Error('Staff sign-in is required.'), httpError('JWT expired', 401), httpError('Invalid Refresh Token: Already Used', 400)]) {
    const attempt = fakeCreate({ fail: failure })
    const out = await submit(confirming, attempt.create)
    assert.equal(out.phase, SALE_PHASES.SIGNED_OUT, failure.message)
    assert.equal(attempt.calls.length, 1)
  }
  const out = await submit(confirming, fakeCreate({ fail: new Error('Staff sign-in is required.') }).create)
  const markup = saleScreen(out, { signInError: '' })
  assert.match(markup, /Sign in to continue this sale/)
  assert.match(markup, /Nothing was created/)
  const resumed = resumeAfterSignIn(out)
  assert.equal(resumed.phase, SALE_PHASES.CONFIRMING)
  const { create, calls } = fakeCreate()
  const done = await submit(resumed, create)
  assert.equal(done.phase, SALE_PHASES.SUCCESS)
  assert.equal(calls[0].idempotencyKey, confirming.attempt.request.idempotencyKey)
  assert.equal(resumeAfterSignIn(confirming), confirming, 'only a signed-out sale resumes')
})

test('an access refusal shows the server message and offers nothing but a new sale', async () => {
  const denied = await submit(confirm('scan'), fakeCreate({ fail: httpError('You do not have access to the Quick Solution counter.', 403, '42501') }).create)
  assert.equal(denied.phase, SALE_PHASES.DENIED)
  const markup = saleScreen(denied)
  assert.match(markup, /You do not have access to the Quick Solution counter\./)
  assert.match(markup, /Start new sale/)
  assert.doesNotMatch(markup, /Retry safely|Create unpaid order/)
  assert.equal(beginSubmit(denied), denied)
})

// ── screen states ───────────────────────────────────────────────────────
test('preview state offers Review order for a writable product and nothing is created yet', () => {
  const markup = html(h(ui.CounterView, { state: ready, selectedId: 'a4-print', draft: draftFor('a4-print', PRINT) }))
  assert.match(markup, /<button[^>]*>Review order<\/button>/)
  assert.doesNotMatch(markup, /<button[^>]*disabled=""[^>]*>Review order/)
  assert.doesNotMatch(markup, /Create unpaid order/)
  const incomplete = html(h(ui.CounterView, { state: ready, selectedId: 'a4-print', draft: draftFor('a4-print', {}) }))
  assert.match(incomplete, /<button[^>]*disabled=""[^>]*>Review order/, 'no confirmation for an incomplete order')
})

test('confirmation state: product, configuration, customer, an estimate labelled as such, unpaid, no payment method', () => {
  const sale = confirm('a4-print', { name: 'Lerato' })
  const markup = saleScreen(sale)
  const panel = saleSection(markup)
  assert.match(panel, /Confirm order/)
  assert.match(panel, /Document Printing/)
  assert.match(panel, /12 pages × 3 copies|<dt>Pages to print<\/dt><dd>12<\/dd>/)
  assert.match(panel, /<dt>Customer<\/dt><dd>Lerato<\/dd>/)
  assert.match(panel, /Estimated total/)
  assert.match(panel, /Estimate only\. The server calculates the final amount/)
  assert.match(panel, /<dt>Payment<\/dt><dd>Unpaid<\/dd>/)
  assert.match(panel, /No payment method is recorded yet/)
  assert.match(panel, /<button[^>]*>Create unpaid order<\/button>/)
  assert.match(panel, /<button[^>]*>Back to edit<\/button>/)
  assert.deepEqual(buttonsOf(panel), ['Back to edit', 'Create unpaid order'])
  assert.match(saleScreen(confirm('scan')), /<dt>Customer<\/dt><dd>Walk-in<\/dd>/)
  assert.doesNotMatch(markup, /Pay now|Checkout|Complete sale|Receipt|Tender/i)
})

test('submitting state disables the actions and says so', () => {
  const panel = saleSection(saleScreen(beginSubmit(confirm('scan'))))
  assert.match(panel, /aria-busy="true"/)
  assert.match(panel, /<button[^>]*disabled=""[^>]*>Creating order…<\/button>/)
  assert.match(panel, /<button[^>]*disabled=""[^>]*>Back to edit<\/button>/)
  assert.doesNotMatch(panel, /<button(?![^>]*disabled)[^>]*>Create unpaid order/)
})

test('success state shows the server order, the server total and unpaid, offers Start new sale and nothing else', async () => {
  const done = await submit(confirm('a3-lamination', { name: 'Anele', phone: '0821234567' }), fakeCreate({ total: 61 }).create)
  const panel = saleSection(saleScreen(done))
  assert.match(panel, /Order created/)
  assert.match(panel, /QS-2026-0001/)
  assert.match(panel, /A3 Lamination/)
  assert.match(panel, /Anele · 0821234567/)
  assert.match(panel, /<dt>Status<\/dt><dd>Submitted<\/dd>/)
  assert.match(panel, /<dt>Payment<\/dt><dd>Unpaid<\/dd>/)
  assert.match(panel, /Final total \(from the server\)/)
  assert.match(panel, new RegExp(formatMoney(61).replace(/\s/g, '\\s')))
  assert.match(panel, /No payment has been taken/)
  assert.deepEqual(buttonsOf(panel), ['Start new sale'])
  assert.doesNotMatch(panel, /receipt|pay now|handoff|production|print/i)
  assert.doesNotMatch(panel, /key-0000|order-uuid/, 'neither the key nor the internal id is shown')
})

test('a replayed answer says it is the original order', async () => {
  const create = async (payload) => ({ ...(await fakeCreate().create(payload)), replayed: true })
  const done = await submit(confirm('scan'), create)
  assert.match(saleScreen(done), /already been created\. This is the original order/)
})

// ── estimate vs the server's price ──────────────────────────────────────
test('the server total is authoritative: it may differ from the estimate without corrupting anything', async () => {
  const sale = confirm('scan')
  const estimate = sale.attempt.summary.estimateTotal
  assert.equal(estimate, 7 * byId.get('scan').pricing.unitPrice)
  const done = await submit(sale, fakeCreate({ total: estimate + 12.5 }).create)
  assert.equal(done.result.totalAmount, estimate + 12.5)
  assert.equal(done.attempt.summary.estimateTotal, estimate, 'the historical estimate is kept, not overwritten')
  const panel = saleSection(saleScreen(done))
  assert.match(panel, new RegExp(formatMoney(estimate + 12.5).replace(/\s/g, '\\s')))
  assert.match(panel, /The earlier estimate was[\s\S]*The server’s total is the amount for this order/)
  assert.doesNotMatch(panel, /Matches the earlier estimate/)
  const same = saleSection(saleScreen(await submit(sale, fakeCreate({ total: estimate }).create)))
  assert.match(same, /Matches the earlier estimate/)
  assert.doesNotMatch(same, /The earlier estimate was/)
  assert.doesNotMatch(read('../src/lib/counterSale.js'), /total\s*[-=!]==?\s*estimate|estimate\s*[-=!]==?\s*total/, 'a mismatch is not an error')
})

test('the estimate is labelled as an estimate everywhere it appears', () => {
  const preview = html(h(ui.CounterView, { state: ready, selectedId: 'scan', draft: draftFor('scan', { units: '2' }) }))
  assert.match(preview, /Estimated total[\s\S]*Estimate only/)
  assert.match(saleScreen(confirm('scan')), /Estimated total[\s\S]*Estimate only/)
})

// ── writes ──────────────────────────────────────────────────────────────
test('the whole flow makes one create call per submission and no other write', async () => {
  const { create, calls } = fakeCreate()
  let sale = confirm('scan')
  sale = await submit(sale, create)
  assert.equal(calls.length, 1)
  assert.equal(sale.phase, SALE_PHASES.SUCCESS)
  assert.equal(Object.keys(calls[0]).includes('items'), false)
  const page = read('../src/counter/CounterPage.jsx')
  assert.equal((stripComments(page).match(/createQuickSolutionCounterOrder/g) || []).length, 2, 'imported once, used once')
  assert.match(page, /submitSale\(started, createQuickSolutionCounterOrder\)/)
  assert.match(page, /const started = beginSubmit\(sale\)\s*\n\s*if \(started === sale\) return/)
  assert.match(page, /if \(inFlight\.current\) return/)
  const api = read('../src/lib/supabaseApi.js')
  const counterUsers = []
  const walk = (dir) => {
    for (const item of fs.readdirSync(dir, { withFileTypes: true })) {
      const next = new URL(`${item.name}${item.isDirectory() ? '/' : ''}`, dir)
      if (item.isDirectory()) walk(next)
      else if (/\.jsx?$/.test(item.name) && /createQuickSolution\w+|admin_\w+|save\w*Product|sendQuickSolutionOrderToOpps|beginQuickSolutionPayment/.test(fs.readFileSync(next, 'utf8')) && next.pathname.includes('/counter/')) counterUsers.push(item.name)
    }
  }
  walk(new URL('../src/', import.meta.url))
  assert.deepEqual(counterUsers, ['CounterPage.jsx'])
  assert.doesNotMatch(stripComments(page), /beginQuickSolutionPayment|sendQuickSolutionOrderToOpps|saveQuickSolution|createQuickSolutionServiceRequest|createQuickSolutionCartOrder|adminIssue/)
  assert.match(api, /export async function createQuickSolutionCounterOrder/)
})

test('the page: selecting is ignored while a sale is locked, Start new sale resets everything, sign-in resumes the same sale', () => {
  const page = stripComments(read('../src/counter/CounterPage.jsx'))
  assert.match(page, /const select = \(productId\) => \{\s*\n\s*if \(isSaleLocked\(sale\)\) return/)
  assert.match(page, /onNewSale=\{reset\}/)
  assert.match(page, /setSale\(startNewSale\(\)\)/)
  assert.match(page, /if \(sale\.phase === SALE_PHASES\.SIGNED_OUT\) \{ setSale\(\(current\) => resumeAfterSignIn\(current\)\); handled = true \}/)
  assert.match(page, /setCustomer\(EMPTY_COUNTER_CUSTOMER\)/)
})

test('the new test file is part of npm test', () => {
  assert.match(JSON.parse(read('../package.json')).scripts.test, /tests\/counter-sale\.test\.mjs/)
})
