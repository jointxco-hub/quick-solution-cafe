import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'
import { loadCounterUi, setApiMock } from './helpers/counter-ui-harness.mjs'
import { products as seedProducts } from '../src/data/products.js'
import { resolveAppRoute } from '../src/lib/navigation.js'
import { resolveCounterGroup, COUNTER_GROUPS } from '../src/lib/counterCatalogue.js'
import { buildA4CounterPrintConfig } from '../src/lib/counterPrintConfig.js'
import { calculateProductPrice, formatMoney } from '../src/lib/pricing.js'
import {
  buildCounterConfiguration,
  buildCounterPreview,
  classifyCounterError,
  counterFields,
  createCounterDraft,
  groupCounterEntries,
  loadCounterCatalogueState,
  selectCounterProduct,
  setCounterDraftValue
} from '../src/lib/counterDraft.js'

// CAFE-GUEST-01N - the read-only staff Counter screen. The real components are rendered to HTML in plain
// Node (tests/helpers/counter-ui-harness.mjs) with only the API module mocked at the UI boundary; no test
// touches Supabase, and none can, because the mock has no create-order export.

const read = (path) => fs.readFileSync(new URL(path, import.meta.url), 'utf8')
const stripComments = (text) => text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:'"`])\/\/[^\n]*/g, '$1')
const ui = await loadCounterUi()
const html = (element) => ui.renderToStaticMarkup(element)
const h = ui.React.createElement

const byId = new Map(seedProducts.map((product) => [product.id, product]))
// What the server's counter catalogue returns TODAY: the pos products, including the storefront-off Scan,
// A4 Lamination and A3 Lamination, and NOT the retired generic 'lamination'.
const serverProducts = seedProducts.filter((product) => product.channels?.pos === true)
const serverResponse = { tenant: { slug: 'quick-solution', name: 'Quick Solution' }, products: serverProducts }
const ready = await loadCounterCatalogueState(async () => serverResponse)
const entry = (id) => ready.entries.find((item) => item.product.id === id)

function screen({ state = ready, productId = null, values = {} } = {}) {
  let draft = null
  if (productId) {
    const found = state.entries.find((item) => item.product.id === productId)
    draft = createCounterDraft(found.product)
    for (const [key, value] of Object.entries(values)) draft = setCounterDraftValue(draft, found.product, key, value)
  }
  return html(h(ui.CounterView, { state, selectedId: productId, draft }))
}
const estimateText = (id, count) => formatMoney(count * byId.get(id).pricing.unitPrice)
const tileIds = (markup) => [...markup.matchAll(/data-product-id="([^"]+)"/g)].map((match) => match[1])
const keysDeep = (value, found = new Set()) => {
  if (Array.isArray(value)) value.forEach((item) => keysDeep(item, found))
  else if (value && typeof value === 'object') for (const [key, child] of Object.entries(value)) { found.add(key); keysDeep(child, found) }
  return found
}

const counterSources = ['../src/counter/CounterPage.jsx', '../src/counter/CounterView.jsx', '../src/lib/counterDraft.js']

// ── route ───────────────────────────────────────────────────────────────
test('/counter is a route and resolving it grants nothing', () => {
  assert.deepEqual(resolveAppRoute({ pathname: '/counter' }), { view: 'counter', page: null, pathname: '/counter' })
  assert.equal(resolveAppRoute({ pathname: '/counter/' }).view, 'counter')
  assert.equal('authorized' in resolveAppRoute({ pathname: '/counter' }), false)
  assert.equal(resolveAppRoute({ pathname: '/counter/extra' }).view, 'not-found')
  assert.equal(resolveAppRoute({ pathname: '/admin' }).view, 'admin')
  assert.equal(resolveAppRoute({ pathname: '/track' }).view, 'track')
  assert.equal(resolveAppRoute({ pathname: '/' }).view, 'storefront')
  const app = read('../src/App.jsx')
  // since CAFE-GUEST-01X the page is lazy-loaded (the boundary itself is proven in counter-lazy.test.mjs)
  assert.match(app, /const CounterPage = lazy\(\(\) => import\('\.\/counter\/CounterPage\.jsx'\)\)/)
  assert.match(app, /if \(view === 'counter'\) \{\s*return \(\s*<Suspense[\s\S]*?<CounterPage\/>/)
})

test('no navigation entry was added: the route is reached directly, with no fake staff-aware menu', () => {
  for (const file of ['../src/components/Header.jsx', '../src/components/Footer.jsx', '../src/components/MobileBottomNav.jsx']) {
    assert.doesNotMatch(read(file), /\/counter|Counter/, file)
  }
  const nav = stripComments(read('../src/lib/navigation.js'))
  assert.equal((nav.match(/counter/gi) || []).length, 2, 'only the route line mentions the counter')
})

// ── catalogue loading: the RPC, never the static list ───────────────────
test('the screen loads through loadQuickSolutionCounterCatalog and never reads the static product array', () => {
  const page = read('../src/counter/CounterPage.jsx')
  assert.match(page, /loadCounterCatalogueState\(loadQuickSolutionCounterCatalog\)/)
  for (const file of counterSources) {
    const text = stripComments(read(file))
    assert.doesNotMatch(text, /data\/products|catalogStore|loadCatalog\b|loadQuickSolutionCatalog\b|loadQuickSolutionAdminCatalog|localStorage/, file)
  }
})

test('only products the server returned appear: a product the seed has but the server did not send is absent, and one the seed lacks is present', async () => {
  const calls = []
  const invented = { id: 'server-only', name: 'Server Only Item', category: 'Quick Print', description: 'Sent by the server.', channels: { pos: true }, pricing: { strategy: 'PER_UNIT', unitPrice: 2, minUnits: 1, maxUnits: 9 }, fields: [{ id: 'units', type: 'number', label: 'How many?', min: 1, step: 1 }] }
  const state = await loadCounterCatalogueState(async (...args) => { calls.push(args); return { tenant: null, products: [invented, byId.get('scan')] } })
  assert.deepEqual(calls, [[]], 'called once, with no argument (no tenant, no channel)')
  assert.deepEqual(state.entries.map((item) => item.product.id), ['server-only', 'scan'])
  const markup = screen({ state })
  assert.deepEqual(tileIds(markup), ['server-only', 'scan'], 'the server order is kept')
  assert.match(markup, /Server Only Item/)
  assert.doesNotMatch(markup, /A4 Lamination|Business Cards/)
})

test('a product without channels.pos === true is not shown even if a server sent it (visibility comes from the existing helper)', async () => {
  const state = await loadCounterCatalogueState(async () => ({ products: [{ ...byId.get('scan'), channels: { pos: false } }, { ...byId.get('scan'), id: 'x', channels: {} }] }))
  assert.equal(state.status, 'empty')
})

// ── states ──────────────────────────────────────────────────────────────
test('loading state', () => {
  const markup = screen({ state: { status: 'loading' } })
  assert.match(markup, /Loading the counter/)
  assert.doesNotMatch(markup, /qsc-tile/)
})

test('CounterPage starts in the loading state with a session and shows sign-in without one, both without calling the API', () => {
  const calls = []
  setApiMock({ session: { access_token: 'x' }, load: async () => { calls.push('load'); return serverResponse }, signIn: async () => calls.push('signIn'), signOut: async () => calls.push('signOut') })
  assert.match(html(h(ui.CounterPage)), /Loading the counter/)
  setApiMock({ session: null, load: async () => { calls.push('load') }, signIn: async () => {}, signOut: async () => {} })
  const signedOut = html(h(ui.CounterPage))
  assert.match(signedOut, /Sign in to use the counter/)
  assert.doesNotMatch(signedOut, /qsc-tile/)
  assert.deepEqual(calls, [], 'server rendering runs no effects, so nothing was requested')
})

test('the server denial is the gate: the permission error state shows the server message and no products', async () => {
  const denied = await loadCounterCatalogueState(async () => { throw Object.assign(new Error('You do not have access to the Quick Solution counter.'), { status: 403, payload: { code: '42501' } }) })
  assert.equal(denied.status, 'denied')
  const markup = screen({ state: denied })
  assert.match(markup, /No counter access/)
  assert.match(markup, /You do not have access to the Quick Solution counter\./)
  assert.doesNotMatch(markup, /qsc-tile|data-product-id/, 'no static or stale products after a denial')
  assert.equal(denied.entries, undefined)
})

test('every other server answer maps to a clean state, none of which falls back to local products', async () => {
  const fail = (message, extra = {}) => loadCounterCatalogueState(async () => { throw Object.assign(new Error(message), extra) })
  const signedOut = await fail('Staff sign-in is required.')
  assert.equal(signedOut.status, 'signed-out')
  assert.match(screen({ state: signedOut }), /Sign in to use the counter/)
  assert.equal((await fail('Session expired', { status: 401 })).status, 'signed-out')
  const inactive = await fail('Quick Solution counter is not active.', { status: 400, payload: { code: '22023' } })
  assert.equal(inactive.status, 'unavailable')
  assert.match(screen({ state: inactive }), /Counter unavailable[\s\S]*Quick Solution counter is not active\./)
  const network = await fail('Failed to fetch')
  assert.equal(network.status, 'error')
  const markup = screen({ state: network })
  assert.match(markup, /Could not load the counter/)
  assert.match(markup, /Try again/)
  for (const state of [signedOut, inactive, network]) assert.doesNotMatch(screen({ state }), /qsc-tile/)
  assert.equal((await loadCounterCatalogueState(async () => null)).status, 'error')
  assert.equal((await loadCounterCatalogueState(async () => ({ products: 'nope' }))).status, 'error')
  assert.deepEqual(classifyCounterError(undefined), { status: 'error', message: 'The counter could not be loaded.' })
})

test('empty catalogue state', async () => {
  const empty = await loadCounterCatalogueState(async () => ({ tenant: { slug: 'quick-solution', name: 'Quick Solution' }, products: [] }))
  assert.equal(empty.status, 'empty')
  const markup = screen({ state: empty })
  assert.match(markup, /No counter products yet/)
  assert.doesNotMatch(markup, /qsc-tile/)
})

// ── products, groups ────────────────────────────────────────────────────
test('the server-returned products render, including the storefront-off Scan, A4 Lamination and A3 Lamination', () => {
  const markup = screen()
  assert.deepEqual(tileIds(markup).sort(), serverProducts.map((product) => product.id).sort())
  for (const id of ['scan', 'a4-lamination', 'a3-lamination']) {
    assert.equal(byId.get(id).channels.storefront, false, `${id} is storefront-off`)
    assert.match(markup, new RegExp(`data-product-id="${id}"`))
    assert.match(markup, new RegExp(byId.get(id).name))
  }
})

test('the retired generic Lamination does not appear: the server did not return it and nothing else supplies it', () => {
  assert.equal(byId.has('lamination'), false)
  const markup = screen()
  assert.doesNotMatch(markup, /data-product-id="lamination"/)
  assert.deepEqual(tileIds(markup).filter((id) => /lamin/i.test(id)).sort(), ['a3-lamination', 'a4-lamination'])
})

test('Quick Services and Production & Branding grouping comes from counterCatalogue.js, in that order', () => {
  const sections = groupCounterEntries(ready.entries)
  assert.deepEqual(sections.map((section) => section.group), [COUNTER_GROUPS.QUICK_SERVICES, COUNTER_GROUPS.PRODUCTION_AND_BRANDING])
  for (const section of sections) for (const item of section.entries) assert.equal(resolveCounterGroup(item.product), section.group)
  const quick = sections[0].entries.map((item) => item.product.id)
  for (const id of ['a4-print', 'scan', 'a4-lamination', 'a3-lamination']) assert.ok(quick.includes(id), `${id} is a Quick Service`)
  const markup = screen()
  assert.ok(markup.indexOf('Quick Services') < markup.indexOf('Production &amp; Branding'))
  const quickSection = markup.slice(markup.indexOf('aria-label="Quick Services"'), markup.indexOf('aria-label="Production &amp; Branding"'))
  assert.match(quickSection, /data-product-id="scan"/)
  assert.doesNotMatch(quickSection, /data-product-id="business-cards"/)
  // no manual classification in the UI code
  for (const file of ['../src/counter/CounterPage.jsx', '../src/counter/CounterView.jsx', '../src/lib/counterDraft.js']) {
    assert.doesNotMatch(stripComments(read(file)), /Quick Services|Production & Branding|Quick Print|Signs & Large Format|Business Essentials|\.category\b/, file)
  }
  assert.deepEqual(groupCounterEntries([]), [])
})

// ── selection and drafts ────────────────────────────────────────────────
test('selecting a product marks exactly that tile and shows its options and preview', () => {
  const markup = screen({ productId: 'a4-lamination' })
  assert.equal((markup.match(/aria-pressed="true"/g) || []).length, 1)
  assert.match(markup, /aria-pressed="true"[^>]*data-product-id="a4-lamination"/)
  assert.match(markup, /<h2>A4 Lamination<\/h2>[\s\S]*Order preview/)
  assert.match(screen(), /Choose a product/)
  assert.doesNotMatch(screen(), /Order preview/)
})

test('switching products clears the draft; re-selecting the same product keeps it', () => {
  const scan = byId.get('scan')
  let draft = selectCounterProduct(null, scan)
  draft = setCounterDraftValue(draft, scan, 'units', '12')
  assert.equal(selectCounterProduct(draft, scan), draft, 'same product keeps the draft')
  const lamination = byId.get('a4-lamination')
  const switched = selectCounterProduct(draft, lamination)
  assert.equal(switched.productId, 'a4-lamination')
  assert.deepEqual(switched.values, { units: '' }, 'the Scan count did not carry over')
  const print = selectCounterProduct(switched, byId.get('a4-print'))
  assert.equal(print.values.pages, '')
  assert.equal('units' in print.values, false)
  assert.deepEqual(Object.keys(draft).sort(), ['productId', 'values'], 'a draft is one product plus its values')
  // a value for another product, or an unknown field, is ignored
  assert.equal(setCounterDraftValue(draft, lamination, 'units', '99'), draft)
  assert.equal(setCounterDraftValue(draft, scan, 'nope', '1'), draft)
})

// ── PER_UNIT products ───────────────────────────────────────────────────
for (const id of ['scan', 'a4-lamination', 'a3-lamination']) {
  test(`${id}: one units field, configuration is exactly { units }, estimate = units x the server price`, () => {
    const product = byId.get(id)
    assert.deepEqual(counterFields(product).map((field) => field.id), ['units'])
    const markup = screen({ productId: id, values: { units: '7' } })
    assert.equal((markup.match(/type="number"/g) || []).length, 1, 'one units field (the optional customer inputs are text)')
    assert.match(markup, /value="7"/)
    const built = buildCounterConfiguration(product, { units: '7' })
    assert.deepEqual(built, { ok: true, errors: [], configuration: { units: 7 } })
    assert.match(markup, new RegExp(`Estimated total[\\s\\S]*${estimateText(id, 7).replace(/\s/g, '\\s')}`))
    assert.match(markup, /Estimate only/)
    assert.deepEqual([...keysDeep(built.configuration)], ['units'])
  })

  test(`${id}: invalid counts give a clear message and no total`, () => {
    const product = byId.get(id)
    const max = product.pricing.maxUnits
    for (const [units, message] of [['', 'Units are required.'], ['0', 'Units are outside the supported range.'], [String(max + 1), 'Units are outside the supported range.'], ['1.5', 'Units must be a whole number.'], ['abc', 'Units must be a whole number.']]) {
      const preview = buildCounterPreview(entry(id), { productId: id, values: { units } })
      assert.equal(preview.valid, false, units)
      assert.equal(preview.errors[0].message, message, units)
      assert.equal(preview.estimate, null)
      assert.equal(preview.configuration, null)
    }
    const markup = screen({ productId: id, values: { units: '0' } })
    assert.match(markup, /Units are outside the supported range\./)
    assert.doesNotMatch(markup, /Estimated total/)
    assert.equal(buildCounterPreview(entry(id), { productId: id, values: { units: String(max) } }).valid, true)
  })
}

// ── physical A4 print ───────────────────────────────────────────────────
test('A4 physical print: the fields are pages, copies, mode, sides and finish - with no upload control', () => {
  const product = byId.get('a4-print')
  assert.deepEqual(counterFields(product).map((field) => field.id), ['pages', 'copies', 'printMode', 'sides', 'finish'])
  assert.ok(product.fields.some((field) => field.type === 'file'), 'the storefront product does have an upload field')
  const markup = screen({ productId: 'a4-print' })
  assert.doesNotMatch(markup, /type="file"|Upload|Send us your documents|Choose file/i)
  for (const label of ['A4 pages to print', 'How many copies do you need?', 'Black &amp; white', 'One side', 'Nothing else']) assert.match(markup, new RegExp(label))
  const fresh = createCounterDraft(product)
  assert.equal(fresh.values.pages, '', 'no fake page count')
  assert.equal(buildCounterPreview(entry('a4-print'), fresh).errors[0].message, 'Enter how many pages to print.')
})

test('A4 physical print goes through the counter print adapter: the configuration is exactly its output', () => {
  const product = byId.get('a4-print')
  const built = buildCounterConfiguration(product, { pages: '12', copies: '3', printMode: 'bw', sides: 'single', finish: 'none' })
  assert.equal(built.ok, true)
  assert.deepEqual(built.configuration, buildA4CounterPrintConfig({ pages: 12, copies: 3, printMode: 'bw', sides: 'single', finish: 'none' }))
  assert.deepEqual(built.configuration, {
    pages: 12, copies: 3, printMode: 'bw', sides: 'single', finish: 'none',
    documentInstructions: [{ selection: 'all', sourcePages: 12 }], documentPlanValid: true
  })
  assert.equal(built.configuration.documentInstructions.length, 1)
  const draft = createCounterDraft(product)
  assert.equal(buildCounterConfiguration(product, draft.values).ok, false)
  const defaults = buildCounterConfiguration(product, { ...draft.values, pages: '4' })
  assert.deepEqual(defaults.configuration, buildA4CounterPrintConfig({ pages: 4 }), 'copies, mode, sides and finish default exactly as the adapter defaults them')
  // the UI code hands over to the adapter; it does not rebuild the shape
  const draftCode = stripComments(read('../src/lib/counterDraft.js'))
  assert.match(draftCode, /buildA4CounterPrintConfig\(input\)/)
  assert.doesNotMatch(draftCode, /documentInstructions|documentPlanValid|sourcePages/)
})

test('A4 physical print: no fake file data and never configuration.quantity', () => {
  const product = byId.get('a4-print')
  const config = buildCounterConfiguration(product, { pages: '12', copies: '3', printMode: 'colour', sides: 'double', finish: 'staple' }).configuration
  const keys = [...keysDeep(config)]
  assert.deepEqual(keys.sort(), ['copies', 'documentInstructions', 'documentPlanValid', 'finish', 'pages', 'printMode', 'selection', 'sides', 'sourcePages'])
  for (const key of keys) assert.doesNotMatch(key, /file|name|mime|key|source$|quantity|upload/i, key)
  assert.equal('quantity' in config, false)
  for (const id of ['scan', 'a4-lamination', 'a3-lamination']) {
    assert.equal('quantity' in buildCounterConfiguration(byId.get(id), { units: '2' }).configuration, false)
  }
  // strictness: nothing is silently corrected on the way through
  for (const values of [{ pages: '0' }, { pages: '1001' }, { pages: '2.5' }, { pages: '3', copies: '0' }, { pages: '3', copies: '501' }, { pages: '3', copies: 'x' }, { pages: '3', printMode: 'sepia' }, { pages: '3', sides: 'triple' }, { pages: '3', finish: 'bind' }]) {
    assert.equal(buildCounterConfiguration(product, { copies: '1', printMode: 'bw', sides: 'single', finish: 'none', ...values }).ok, false, JSON.stringify(values))
  }
})

test('A4 physical print: the preview shows the job and an estimate taken from the existing pricing mirror', () => {
  const product = byId.get('a4-print')
  const values = { pages: '12', copies: '3', printMode: 'bw', sides: 'single', finish: 'none' }
  const preview = buildCounterPreview(entry('a4-print'), { productId: 'a4-print', values })
  assert.equal(preview.valid, true)
  assert.equal(preview.unitSummary, '12 pages × 3 copies')
  assert.equal(preview.estimate.total, calculateProductPrice(product, preview.configuration).total)
  assert.ok(preview.estimate.total > 0)
  const markup = screen({ productId: 'a4-print', values })
  assert.match(markup, /12 pages × 3 copies/)
  assert.match(markup, new RegExp(formatMoney(preview.estimate.total).replace(/\s/g, '\\s')))
  assert.match(markup, /Black &amp; white/)
  const invalid = screen({ productId: 'a4-print', values: { ...values, pages: '' } })
  assert.match(invalid, /Enter how many pages to print\./)
  assert.doesNotMatch(invalid, /Estimated total/)
})

// ── other products render from their established fields ─────────────────
test('other order products render their established fields, without file fields, and validate locally', () => {
  for (const id of ['pvc-banner', 'business-cards', 'printed-tshirt', 'flags']) {
    const product = byId.get(id)
    const shown = counterFields(product).map((field) => field.id)
    assert.equal(shown.includes('file'), false, id)
    assert.ok(shown.length >= 2, id)
    const markup = screen({ productId: id })
    assert.doesNotMatch(markup, /type="file"/)
    for (const field of counterFields(product)) assert.match(markup, new RegExp(field.label.replace(/[?()]/g, '.').replace(/&/g, '&amp;').slice(0, 20).replace(/'/g, '.')), `${id}.${field.id}`)
  }
  const banner = byId.get('pvc-banner')
  assert.equal(buildCounterConfiguration(banner, createCounterDraft(banner).values).ok, true, 'the established defaults are a valid job')
  for (const values of [{ width: '' }, { height: '0' }, { width: 'abc' }]) {
    assert.equal(buildCounterConfiguration(banner, { ...createCounterDraft(banner).values, ...values }).ok, false, JSON.stringify(values))
  }
  const good = buildCounterConfiguration(banner, { ...createCounterDraft(banner).values, width: '2', height: '1' })
  assert.equal(good.ok, true)
  assert.equal(good.configuration.width, 2)
  assert.equal(estimateOf('pvc-banner', good.configuration) > 0, true)
  const cards = byId.get('business-cards')
  const cardConfig = buildCounterConfiguration(cards, createCounterDraft(cards).values)
  assert.equal(cardConfig.ok, true, 'a tiered product keeps its legitimate quantity option')
  assert.ok('quantity' in cardConfig.configuration)
})
function estimateOf(id, configuration) {
  return calculateProductPrice(byId.get(id), configuration).total
}

test('a supplier product with an unpriced choice shows the configuration but invents no total', () => {
  const supplier = {
    id: 'sup', name: 'Supplier Thing', category: 'Flags & Events', channels: { pos: true }, pricingVersion: 'v',
    pricing: { strategy: 'SUPPLIER_MARGIN', variants: { a: { label: 'Option A', price: null } } },
    fields: [{ id: 'variant', type: 'select', label: 'Which one?', options: [{ id: 'a', label: 'Option A' }], default: 'a' }, { id: 'quantity', type: 'number', label: 'How many?', min: 1, default: 1, required: true }]
  }
  const preview = buildCounterPreview({ product: supplier, action: 'order', group: resolveCounterGroup(supplier) }, createCounterDraft(supplier))
  assert.equal(preview.valid, true)
  assert.equal(preview.estimate, null)
  const state = { status: 'ready', entries: [{ product: supplier, action: 'order', group: resolveCounterGroup(supplier), visible: true }] }
  const markup = screen({ state, productId: 'sup' })
  assert.match(markup, /No estimate for this configuration/)
  assert.doesNotMatch(markup, /Estimated total/)
})

// ── request products ────────────────────────────────────────────────────
test('request products are visually distinguished, have no form and no working action', () => {
  for (const id of ['media-services', 'photo-session']) {
    assert.equal(entry(id).action, 'request')
    const markup = screen({ productId: id })
    assert.match(markup, new RegExp(`qsc-tile[^"]*is-request[^"]*"[^>]*data-product-id="${id}"`))
    const panel = markup.slice(markup.indexOf('aria-label="Configure"'))
    assert.match(panel, /Request workflow coming next/)
    assert.match(panel, /Request preview/)
    assert.doesNotMatch(panel, /<input|<select|<textarea|type="submit"/)
    assert.doesNotMatch(panel, /Estimated total|Create|Submit/)
    const preview = buildCounterPreview(entry(id), createCounterDraft(byId.get(id)))
    assert.deepEqual([preview.action, preview.configuration, preview.estimate, preview.valid], ['request', null, null, false])
  }
  const markup = screen()
  assert.equal((markup.match(/qsc-badge-request/g) || []).length, 2)
  assert.equal((markup.match(/qsc-badge-order/g) || []).length, ready.entries.length - 2)
})

// ── preview shape ───────────────────────────────────────────────────────
test('the preview is for a Walk-in customer until details are typed, names no order number, and never invents an id', () => {
  const preview = buildCounterPreview(entry('scan'), { productId: 'scan', values: { units: '3' } })
  assert.deepEqual(Object.keys(preview).sort(), ['action', 'configuration', 'customer', 'errors', 'estimate', 'productId', 'productName', 'rows', 'unitSummary', 'valid'])
  assert.equal(preview.customer, 'Walk-in')
  assert.deepEqual(preview.rows, [{ label: 'Pages to scan', value: '3 pages' }])
  const markup = screen({ productId: 'scan', values: { units: '3' } })
  assert.match(markup, /<dt>Customer<\/dt><dd>Walk-in<\/dd>/)
  assert.match(markup, /Nothing is created until you confirm/)
  assert.match(screen({ productId: 'business-cards' }), /Preview only\. Nothing has been created\./)
  assert.doesNotMatch(markup, /order (no|number)[.:]?\s*#|QS-\d|uuid|orderId/i)
  assert.match(markup, /Order preview/)
})

// ── read-only, no payment, no cart ──────────────────────────────────────
test('the only write the Counter can make is the one create call from the page: no fetch, no other RPC, no request submission', () => {
  const users = []
  const walk = (dir) => {
    for (const item of fs.readdirSync(dir, { withFileTypes: true })) {
      const next = new URL(`${item.name}${item.isDirectory() ? '/' : ''}`, dir)
      if (item.isDirectory()) walk(next)
      else if (/\.(jsx?|css)$/.test(item.name)) users.push({ name: item.name, text: fs.readFileSync(next, 'utf8') })
    }
  }
  walk(new URL('../src/', import.meta.url))
  assert.deepEqual(users.filter((file) => /createQuickSolutionCounterOrder|create_quick_solution_counter_order/.test(file.text)).map((file) => file.name), ['CounterPage.jsx', 'supabaseApi.js'])
  for (const file of [...counterSources, '../src/counter/CounterPage.jsx', '../src/lib/counterSale.js', '../src/lib/counterSubmissionReadiness.js']) {
    assert.doesNotMatch(stripComments(read(file)), /\bfetch\s*\(|\brpc\s*\(|XMLHttpRequest|sendBeacon|localStorage|sessionStorage|create_quick_solution|createQuickSolutionServiceRequest|createQuickSolutionCartOrder|createQuickSolutionOrder\b/i, file)
  }
  for (const file of ['../src/counter/CounterView.jsx', '../src/lib/counterDraft.js']) {
    assert.doesNotMatch(stripComments(read(file)), /createQuickSolution|idempotency/i, `${file} neither calls the API nor knows the key`)
  }
  // the only API calls the page can make are the ones the mock exposes
  // since 01Q there are exactly two writes: the create call (01O) and the full-payment call
  const imported = read('../src/counter/CounterPage.jsx').match(/import \{([^}]*)\} from '\.\.\/lib\/supabaseApi\.js'/)[1].split(',').map((name) => name.trim()).filter(Boolean)
  assert.deepEqual(imported, ['cancelQuickSolutionCounterOrder', 'createQuickSolutionCounterOrder', 'getAdminSession', 'loadQuickSolutionCancelledCounterOrders', 'loadQuickSolutionCounterCashup', 'loadQuickSolutionCounterCashupToday', 'loadQuickSolutionCounterCatalog', 'loadQuickSolutionCounterOrder', 'loadQuickSolutionCounterOrderCancelCheck', 'loadQuickSolutionCounterOrdersToday', 'loadQuickSolutionUnpaidCounterOrders', 'recordQuickSolutionCounterPayment', 'signInAdmin', 'signOutAdmin'])
})

test('the Counter names no capability and decides no authorization itself', () => {
  for (const file of [...counterSources, '../src/lib/navigation.js']) {
    assert.doesNotMatch(read(file), /cafe\.counter|cafe\.operations|has_tenant_capability|is_app_admin|is_opps_staff|tenant_id|tenantSlug/i, file)
  }
})

test('the sale screens have no payment controls: payment is recorded only from an opened order (01Q), and only as Cash or Card', () => {
  const words = /\beft\b|tender|change due|checkout|invoice|deposit|refund|\bpay now\b|partial|overpay/i
  for (const file of ['../src/counter/CounterPage.jsx', '../src/counter/CounterView.jsx', '../src/lib/counterDraft.js', '../src/lib/counterSale.js', '../src/lib/counterPayment.js', '../src/styles/qs-counter.css']) {
    assert.doesNotMatch(stripComments(read(file)), words, file)
  }
  // the sale flow itself never names a payment method
  for (const file of ['../src/lib/counterDraft.js', '../src/lib/counterSale.js', '../src/lib/counterSubmissionReadiness.js']) {
    assert.doesNotMatch(stripComments(read(file)), /\bcash\b|\bcard\b/i, file)
  }
  const markup = screen({ productId: 'a4-print', values: { pages: '5' } })
  const buttons = [...markup.matchAll(/<button[^>]*>([\s\S]*?)<\/button>/g)].map((match) => match[1].replace(/<[^>]+>/g, ''))
  const productNames = ready.entries.map((item) => item.product.name)
  const optionLabels = counterFields(byId.get('a4-print')).flatMap((field) => (field.options || []).map((option) => option.label.replace(/&/g, '&amp;')))
  for (const text of buttons) {
    assert.ok(productNames.some((name) => text.startsWith(name.replace(/&/g, '&amp;'))) || optionLabels.includes(text) || ['Sign out', 'Review order', 'New sale', 'Today’s orders', 'Unpaid', 'Cash-up'].includes(text), `unexpected button: ${text}`)
  }
})

test('there is no cart and no multi-item behaviour: one draft, one product, no add-another', () => {
  for (const file of ['../src/counter/CounterPage.jsx', '../src/counter/CounterView.jsx', '../src/lib/counterDraft.js']) {
    assert.doesNotMatch(stripComments(read(file)), /cart|basket|addItem|addToOrder|lineItems|items\.push/i, file)
  }
  const markup = screen({ productId: 'scan', values: { units: '4' } })
  assert.doesNotMatch(markup, /Add to order|Add another|Add item|Basket|Cart/i)
  const draft = selectCounterProduct(selectCounterProduct(null, byId.get('scan')), byId.get('a3-lamination'))
  assert.equal(draft.productId, 'a3-lamination')
  assert.equal(Array.isArray(draft), false)
  assert.equal((markup.match(/aria-pressed="true"/g) || []).length, 1)
})

// ── layout and touch ────────────────────────────────────────────────────
test('mobile and tablet layout: one column by default, two from 900px, 56px targets, viewport set', () => {
  const css = read('../src/styles/qs-counter.css')
  assert.match(css, /@media \(min-width:900px\)/)
  assert.match(css, /@media \(max-width:520px\)/)
  assert.match(css, /\.qsc-fields \.field input[^{]*\{[^}]*min-height:56px/)
  assert.match(css, /\.qsc-fields \.segment\{[^}]*min-height:56px/)
  assert.match(css, /\.qsc-tile\{[^}]*min-height:84px/)
  assert.match(read('../index.html'), /width=device-width, initial-scale=1\.0/)
  assert.match(read('../src/counter/CounterPage.jsx'), /import '\.\.\/styles\/qs-counter\.css'/)
})

test('the new test file is part of npm test', () => {
  assert.match(JSON.parse(read('../package.json')).scripts.test, /tests\/counter-ui\.test\.mjs/)
})
