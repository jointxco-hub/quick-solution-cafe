import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'
import {
  COUNTER_ACTIONS,
  COUNTER_GROUPS,
  COUNTER_CATEGORY_GROUPS,
  isCounterProduct,
  resolveCounterAction,
  resolveCounterGroup,
  resolveCounterProduct,
  resolveCounterCatalogue
} from '../src/lib/counterCatalogue.js'
import { products } from '../src/data/products.js'

// CAFE-GUEST-01F - the pure counter catalogue contract. These tests pin what
// the repository does TODAY; the matrix is not a permanent business decision.

const moduleUrl = new URL('../src/lib/counterCatalogue.js', import.meta.url)
const source = fs.readFileSync(moduleUrl, 'utf8')
const code = source.replace(/\/\/[^\n]*/g, '')
const byId = new Map(products.map((product) => [product.id, product]))

// ── isCounterProduct: only the boolean true passes ─────────────────────
test('isCounterProduct: only channels.pos === true is visible (mirrors the CAFE-GUEST-01C fail-closed rule)', () => {
  const cases = [
    [{ channels: { pos: true } }, true, 'pos true'],
    [{ channels: { pos: false } }, false, 'pos false'],
    [{ channels: {} }, false, 'pos missing'],
    [{ channels: { pos: null } }, false, 'pos null'],
    [{ channels: { pos: 'true' } }, false, 'pos string "true"'],
    [{ channels: { pos: 'false' } }, false, 'pos string "false"'],
    [{ channels: { pos: 1 } }, false, 'pos number 1'],
    [{ channels: { pos: 0 } }, false, 'pos number 0'],
    [{ channels: { pos: {} } }, false, 'pos object'],
    [{ channels: { pos: [] } }, false, 'pos array'],
    [{ channels: { pos: [true] } }, false, 'pos array containing true'],
    [{ channels: { pos: new Boolean(true) } }, false, 'boxed Boolean'],
    [{ channels: null }, false, 'channels null'],
    [{ channels: 'pos' }, false, 'channels string'],
    [{ channels: [] }, false, 'channels array'],
    [{}, false, 'no channels'],
    [null, false, 'null product'],
    [undefined, false, 'undefined product']
  ]
  for (const [product, expected, description] of cases) {
    assert.equal(isCounterProduct(product), expected, description)
  }
})

test('isCounterProduct: visibility only - storefront, category, strategy and quote never matter', () => {
  const counterOnly = { channels: { storefront: false, pos: true }, category: 'Nothing Known', pricing: { strategy: 'ENQUIRY' } }
  assert.equal(isCounterProduct(counterOnly), true, 'a counter-only product is visible')
  for (const storefront of [true, false, undefined, 'false']) {
    assert.equal(isCounterProduct({ channels: { storefront, pos: true } }), true)
    assert.equal(isCounterProduct({ channels: { storefront } }), false)
  }
  assert.equal(isCounterProduct({ channels: { pos: true, quote: false, guided: false, advanced: false }, active: false }), true)
})

// ── resolveCounterAction ───────────────────────────────────────────────
test('resolveCounterAction: ENQUIRY and PHOTOGRAPHY_SESSION are requests; ordinary strategies are orders', () => {
  const action = (strategy, extra = {}) => resolveCounterAction({ pricing: { strategy }, ...extra })
  assert.equal(action('ENQUIRY'), COUNTER_ACTIONS.REQUEST)
  assert.equal(action('PHOTOGRAPHY_SESSION'), COUNTER_ACTIONS.REQUEST)
  for (const strategy of ['PER_PAGE', 'PER_AREA', 'TIERED', 'CONFIGURABLE', 'SUPPLIER_MARGIN']) {
    assert.equal(action(strategy), COUNTER_ACTIONS.ORDER, strategy)
  }
})

test('resolveCounterAction: the existing storefront serviceType rule is preserved', () => {
  assert.equal(resolveCounterAction({ pricing: { strategy: 'PER_PAGE' }, serviceType: 'media' }), COUNTER_ACTIONS.REQUEST)
  assert.equal(resolveCounterAction({ serviceType: 'media' }), COUNTER_ACTIONS.REQUEST)
  assert.equal(resolveCounterAction({ pricing: { strategy: 'PER_PAGE' }, serviceType: 'service' }), COUNTER_ACTIONS.ORDER)
  assert.equal(resolveCounterAction({ pricing: { strategy: 'PER_PAGE' }, serviceType: 'Media' }), COUNTER_ACTIONS.ORDER, 'serviceType is matched exactly, as the storefront does')

  // The storefront expression itself must still be the rule this mirrors.
  const guided = fs.readFileSync(new URL('../src/components/GuidedOrder.jsx', import.meta.url), 'utf8')
  assert.match(guided, /product\?\.pricing\?\.strategy === 'ENQUIRY' \|\| product\?\.serviceType === 'media'/)
})

test('resolveCounterAction: strategy is case-insensitive like the server; unknown or missing strategy starts as an order', () => {
  assert.equal(resolveCounterAction({ pricing: { strategy: 'enquiry' } }), COUNTER_ACTIONS.REQUEST)
  assert.equal(resolveCounterAction({ pricing: { strategy: 'photography_session' } }), COUNTER_ACTIONS.REQUEST)
  assert.equal(resolveCounterAction({ pricing: { strategy: 'per_page' } }), COUNTER_ACTIONS.ORDER)
  for (const product of [{ pricing: { strategy: 'SOMETHING_NEW' } }, { pricing: {} }, { pricing: null }, {}, null, undefined, { pricing: { strategy: 7 } }]) {
    assert.equal(resolveCounterAction(product), COUNTER_ACTIONS.ORDER, JSON.stringify(product))
  }
})

test('resolveCounterAction: quoteRequired is a runtime pricing outcome and is not encoded here', () => {
  assert.equal(resolveCounterAction({ pricing: { strategy: 'SUPPLIER_MARGIN', quoteRequired: true } }), COUNTER_ACTIONS.ORDER)
  assert.equal(resolveCounterAction({ pricing: { strategy: 'PER_PAGE' }, quoteRequired: true }), COUNTER_ACTIONS.ORDER)
  assert.doesNotMatch(code, /quoteRequired/, 'the module never reads quoteRequired')
  assert.equal(resolveCounterAction({ channels: { pos: false }, pricing: { strategy: 'ENQUIRY' } }), COUNTER_ACTIONS.REQUEST, 'action does not depend on visibility')
})

// ── resolveCounterGroup ────────────────────────────────────────────────
test('resolveCounterGroup: Quick Print is a quick service; every other current category is production and branding', () => {
  assert.equal(resolveCounterGroup({ category: 'Quick Print' }), COUNTER_GROUPS.QUICK_SERVICES)
  for (const category of [
    'Signs & Large Format', 'Labels & Packaging', 'Business Essentials',
    'Clothing & Merch', 'Flags & Events', 'Photo & Video'
  ]) {
    assert.equal(resolveCounterGroup({ category }), COUNTER_GROUPS.PRODUCTION_AND_BRANDING, category)
  }
})

test('resolveCounterGroup: an unknown, missing, or non-string category falls back to Production & Branding', () => {
  const fallback = COUNTER_GROUPS.PRODUCTION_AND_BRANDING
  for (const product of [
    { category: 'Scanning' }, { category: '' }, { category: 'quick print' }, { category: ' Quick Print ' },
    { category: 'toString' }, { category: '__proto__' }, { category: 42 }, { category: null }, { category: ['Quick Print'] },
    {}, null, undefined
  ]) {
    assert.equal(resolveCounterGroup(product), fallback, JSON.stringify(product))
  }
})

test('resolveCounterGroup: presentation only - the group never changes visibility or action', () => {
  for (const category of Object.keys(COUNTER_CATEGORY_GROUPS).concat(['Unknown'])) {
    const entry = resolveCounterProduct({ channels: { pos: true }, pricing: { strategy: 'PER_PAGE' }, category })
    assert.equal(entry.visible, true, category)
    assert.equal(entry.action, COUNTER_ACTIONS.ORDER, category)
  }
  assert.deepEqual(Object.keys(COUNTER_GROUPS).sort(), ['PRODUCTION_AND_BRANDING', 'QUICK_SERVICES'])
})

// ── the real nine products ─────────────────────────────────────────────
const expectedMatrix = {
  'a4-print': { visible: true, action: 'order', group: 'Quick Services' },
  'pvc-banner': { visible: true, action: 'order', group: 'Production & Branding' },
  'vinyl-stickers': { visible: true, action: 'order', group: 'Production & Branding' },
  'business-cards': { visible: true, action: 'order', group: 'Production & Branding' },
  'printed-tshirt': { visible: true, action: 'order', group: 'Production & Branding' },
  flags: { visible: true, action: 'order', group: 'Production & Branding' },
  gazebos: { visible: true, action: 'order', group: 'Production & Branding' },
  // Photo & Video is not a quick service, and there is no third group.
  'media-services': { visible: true, action: 'request', group: 'Production & Branding' },
  'photo-session': { visible: true, action: 'request', group: 'Production & Branding' },
  // CAFE-GUEST-01H: the generic PER_UNIT strategy gives 'order' with no special case;
  // its category 'Quick Print' is already mapped to Quick Services.
  scan: { visible: true, action: 'order', group: 'Quick Services' },
  // CAFE-GUEST-01J: same reasoning as Scan - generic PER_UNIT gives 'order', 'Quick Print' is Quick Services.
  'a4-lamination': { visible: true, action: 'order', group: 'Quick Services' },
  'a3-lamination': { visible: true, action: 'order', group: 'Quick Services' }
}

test('real catalogue: the twelve repository products resolve to the pinned contract (current behaviour, not a business decision)', () => {
  assert.deepEqual([...byId.keys()].sort(), Object.keys(expectedMatrix).sort())
  for (const [id, expected] of Object.entries(expectedMatrix)) {
    const { visible, action, group } = resolveCounterProduct(byId.get(id))
    assert.deepEqual({ visible, action, group }, expected, id)
  }
})

test('real catalogue: every category in use is explicitly mapped, so a new category forces a decision', () => {
  for (const product of products) {
    assert.ok(Object.prototype.hasOwnProperty.call(COUNTER_CATEGORY_GROUPS, product.category), `${product.id}: ${product.category} is not mapped`)
  }
})

test('real catalogue: action agrees with the storefront rule for every product, and only PHOTOGRAPHY_SESSION-only products differ by design', () => {
  const storefrontIsRequest = (product) => product?.pricing?.strategy === 'ENQUIRY' || product?.serviceType === 'media'
  for (const product of products) {
    assert.equal(resolveCounterAction(product) === COUNTER_ACTIONS.REQUEST, storefrontIsRequest(product), product.id)
  }
  const bareSession = { pricing: { strategy: 'PHOTOGRAPHY_SESSION' } }
  assert.equal(storefrontIsRequest(bareSession), false)
  assert.equal(resolveCounterAction(bareSession), COUNTER_ACTIONS.REQUEST, 'explicit, matching what the server accepts for service requests')
})

test('real catalogue: resolveCounterCatalogue keeps input order, keeps the same product references, and does not mutate', () => {
  const frozen = products.map((product) => Object.freeze(product))
  const before = JSON.stringify(products)
  const list = resolveCounterCatalogue(frozen)
  assert.deepEqual(list.map((entry) => entry.product.id), products.map((product) => product.id))
  list.forEach((entry, index) => assert.equal(entry.product, frozen[index], 'same reference, not a copy'))
  assert.equal(JSON.stringify(products), before)

  const hidden = [{ id: 'a', channels: { pos: true } }, { id: 'b', channels: { pos: 'true' } }, { id: 'c' }, { id: 'd', channels: { pos: true } }]
  assert.deepEqual(resolveCounterCatalogue(hidden).map((entry) => entry.product.id), ['a', 'd'])
  for (const value of [null, undefined, {}, 'products']) assert.deepEqual(resolveCounterCatalogue(value), [])
})

test('resolveCounterProduct: normalized record shape', () => {
  const product = byId.get('a4-print')
  const entry = resolveCounterProduct(product)
  assert.deepEqual(Object.keys(entry), ['product', 'visible', 'action', 'group'])
  assert.equal(entry.product, product)
  assert.deepEqual(resolveCounterProduct(null), { product: null, visible: false, action: 'order', group: 'Production & Branding' })
})

// ── input contract: an already server-safe catalogue is assumed ────────
test('input contract: visibility is only channels.pos - published/active/available state is not this helper\'s concern', () => {
  const states = [
    { active: false }, { active: true }, { status: 'draft' }, { status: 'archived' },
    { availability: 'unavailable' }, { availability: 'out_of_stock' }, { published: false }, { tenantId: 'other' }
  ]
  for (const state of states) {
    assert.equal(isCounterProduct({ ...state, channels: { pos: true } }), true, JSON.stringify(state))
    assert.equal(isCounterProduct({ ...state, channels: { pos: false } }), false, JSON.stringify(state))
    assert.equal(resolveCounterCatalogue([{ ...state, channels: { pos: true } }]).length, 1, 'no active/published filtering in the pure helper')
  }
  // The known repository drift is reported, never compensated for: this
  // client default is active:false, while the qs14 data says active:true.
  assert.equal(byId.get('photo-session').active, false)
  assert.equal(isCounterProduct(byId.get('photo-session')), true)

  for (const term of ['active', 'status', 'availab', 'publish', 'tenant', 'capabilit', 'authoriz', 'permission', 'role']) {
    assert.ok(!code.toLowerCase().includes(term), `module code must not mention "${term}"`)
  }
  const documented = source.replace(/^\s*\/\/ ?/gm, '').replace(/\s+/g, ' ')
  assert.match(documented, /INPUT CONTRACT: every function here assumes it is handed an ALREADY server-safe catalogue/)
  assert.match(documented, /answers ONLY "is channels\.pos exactly true\?"/)
})

// ── the same contract from the database's customer_definition ──────────
function databaseCustomerDefinitions() {
  const found = new Map()
  const seed = fs.readFileSync(new URL('../supabase/seed.sql', import.meta.url), 'utf8')
  for (const match of seed.matchAll(/select t\.id, p\.id, '([\w-]+)',\s*'(\{[\s\S]*?\})'::jsonb,/g)) {
    found.set(match[1], JSON.parse(match[2].replace(/''/g, "'")))
  }
  const qs14 = fs.readFileSync(new URL('../supabase/migrations/20260921090500_qs14_catalog_data.sql', import.meta.url), 'utf8')
  for (const match of qs14.matchAll(/select\s+t\.id,\s+p\.id,\s+'([\w-]+)',\s+\$cd\$([\s\S]*?)\$cd\$/g)) {
    found.set(match[1], JSON.parse(match[2]))
  }
  return found
}

test('database customer_definition rows (seed + qs14 data) resolve exactly like the client defaults', () => {
  const definitions = databaseCustomerDefinitions()
  assert.ok(definitions.size >= 7, `expected the seven parseable definitions, found ${definitions.size}`)
  for (const [key, definition] of definitions) {
    const client = byId.get(key)
    assert.ok(client, `${key} is not in the client catalogue`)
    const fromDatabase = resolveCounterProduct(definition)
    const fromClient = resolveCounterProduct(client)
    assert.deepEqual(
      { visible: fromDatabase.visible, action: fromDatabase.action, group: fromDatabase.group },
      { visible: fromClient.visible, action: fromClient.action, group: fromClient.group },
      key
    )
  }
})

// ── customer-safe data only, no I/O, no mutation ───────────────────────
test('the module reads only customer-safe fields and never internal commercial data', () => {
  for (const forbidden of ['pricing_definition', 'pricingDefinition', 'supplierCost', 'referencePrice', 'marginRate', 'margin', 'sourceUrl', 'sourceName', 'variants', 'accessories', 'sessions']) {
    assert.ok(!code.includes(forbidden), `${forbidden} must not appear in module code`)
  }
  const forbiddenKeys = new Set(['pricing_definition', 'pricingDefinition', 'supplierCost', 'referencePrice', 'marginRate', 'sourceUrl', 'sourceName'])
  const trap = (target) => new Proxy(target, {
    get(object, key, receiver) {
      if (forbiddenKeys.has(key)) throw new Error(`module read internal field ${String(key)}`)
      const value = Reflect.get(object, key, receiver)
      return value && typeof value === 'object' ? trap(value) : value
    }
  })
  for (const product of products) {
    const guarded = trap({ ...product, pricing_definition: { secret: 1 }, pricingDefinition: {}, supplierCost: 1, referencePrice: 1, marginRate: 1, sourceUrl: 'x', sourceName: 'y' })
    assert.doesNotThrow(() => resolveCounterProduct(guarded), product.id)
    assert.doesNotThrow(() => resolveCounterCatalogue([guarded]), product.id)
  }
})

test('the module is pure: no imports, no I/O, no globals, no auth or Supabase', () => {
  assert.doesNotMatch(code, /^\s*import\s/m)
  assert.doesNotMatch(code, /\b(fetch|window|document|localStorage|sessionStorage|process|require|supabase|rpc|auth|session)\b/i)
  assert.doesNotMatch(code, /\b(await|async|Promise|setTimeout|Date|Math\.random)\b/)
  assert.ok(Object.isFrozen(COUNTER_ACTIONS) && Object.isFrozen(COUNTER_GROUPS) && Object.isFrozen(COUNTER_CATEGORY_GROUPS))

  const deepFreeze = (value) => {
    Object.freeze(value)
    for (const child of Object.values(value)) if (child && typeof child === 'object' && !Object.isFrozen(child)) deepFreeze(child)
    return value
  }
  for (const product of products) {
    const frozen = deepFreeze(structuredClone(product))
    assert.doesNotThrow(() => resolveCounterProduct(frozen), product.id)
  }
})

test('only the Counter screen, its draft logic and the write-readiness rule import the module; nothing else does', () => {
  const importers = []
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const path = new URL(`${entry.name}${entry.isDirectory() ? '/' : ''}`, dir)
      if (entry.isDirectory()) walk(path)
      else if (/\.(jsx?|mjs|cjs)$/.test(entry.name) && /(?:from\s+|import\s*\(\s*|require\s*\(\s*)['"][^'"]*counterCatalogue/.test(fs.readFileSync(path, 'utf8'))) importers.push(entry.name)
    }
  }
  walk(new URL('../src/', import.meta.url))
  assert.deepEqual(importers.sort(), ['CounterView.jsx', 'counterDraft.js', 'counterSubmissionReadiness.js'])
  const navigation = fs.readFileSync(new URL('../src/lib/navigation.js', import.meta.url), 'utf8')
  assert.equal((navigation.match(/counter/gi) || []).length, 3, 'only the /counter route (path, view, comment) - no capability, no menu')
})

test('the new test file is part of npm test', () => {
  const packageJson = JSON.parse(fs.readFileSync(new URL('../package.json', import.meta.url), 'utf8'))
  assert.match(packageJson.scripts.test, /tests\/counter-catalogue\.test\.mjs/)
})
