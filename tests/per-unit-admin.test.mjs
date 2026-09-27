import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'
import { buildPricingDefinition } from '../src/lib/pricingDefinition.js'
import { validatePerUnitDefinition, PER_UNIT_LIMITS } from '../src/lib/perUnitPricing.js'
import { calculateProductPrice } from '../src/lib/pricing.js'
import { products } from '../src/data/products.js'

// CAFE-GUEST-01G - admin support for PER_UNIT. The client serializer is
// executed for real; the server function (SQL) is checked statically, and its
// rollback contract test (supabase/tests/cafe_guest_01g_admin_per_unit_support.sql,
// executed by the local harness: npm run test:sql) must hold the SAME
// invalid-definition table as the client here.

const read = (path) => fs.readFileSync(new URL(path, import.meta.url), 'utf8').replace(/\r\n/g, '\n')
const stripComments = (sql) => sql.replace(/--[^\n]*/g, '')
const squash = (sql) => sql.replace(/\s+/g, ' ').trim()

const PREVIOUS = '../supabase/migrations/20260921120000_qs14_checkout_guards_and_supplier_rules.sql'
const MIGRATION = '../supabase/migrations/20260926140000_cafe_guest_01g_admin_per_unit_support.sql'
const migration = read(MIGRATION)
const migrationCode = stripComments(migration)
const sqlTest = read('../supabase/tests/cafe_guest_01g_admin_per_unit_support.sql')

const ADMIN_FUNCTION = /create or replace function public\.admin_update_quick_solution_product\([\s\S]*?\n\$\$;/
const functionOf = (sql) => {
  const match = sql.match(ADMIN_FUNCTION)
  assert.ok(match, 'admin_update_quick_solution_product definition not found')
  return match[0]
}
const previousFunction = functionOf(read(PREVIOUS))
const nextFunction = functionOf(migration)

const perUnitProduct = (pricing, extra = {}) => ({
  id: 'synthetic-unit',
  name: 'Synthetic unit product',
  pricingVersion: 'v1',
  pricing: { strategy: 'PER_UNIT', unitPrice: 19.99, minUnits: 1, maxUnits: 50, ...pricing },
  fields: [],
  ...extra
})

// Each entry is the JSON the client rejects and the SQL contract test must
// list verbatim (rejected with 'Pricing configuration is invalid.', 22023).
const INVALID_DEFINITIONS = [
  { name: 'unitPrice zero', pricing: '{"strategy":"PER_UNIT","unitPrice":0,"minUnits":1,"maxUnits":5}', problem: /unitPrice must be greater than 0/ },
  { name: 'unitPrice negative', pricing: '{"strategy":"PER_UNIT","unitPrice":-1,"minUnits":1,"maxUnits":5}', problem: /unitPrice must be greater than 0/ },
  { name: 'unitPrice above ceiling', pricing: '{"strategy":"PER_UNIT","unitPrice":100000.01,"minUnits":1,"maxUnits":5}', problem: /at most 100000/ },
  { name: 'unitPrice fractional cent', pricing: '{"strategy":"PER_UNIT","unitPrice":19.995,"minUnits":1,"maxUnits":5}', problem: /whole cents/ },
  { name: 'unitPrice string', pricing: '{"strategy":"PER_UNIT","unitPrice":"19.99","minUnits":1,"maxUnits":5}', problem: /unitPrice must be a number/ },
  { name: 'unitPrice missing', pricing: '{"strategy":"PER_UNIT","minUnits":1,"maxUnits":5}', problem: /unitPrice must be a number/ },
  { name: 'minUnits zero', pricing: '{"strategy":"PER_UNIT","unitPrice":1,"minUnits":0,"maxUnits":5}', problem: /minUnits must be at least 1/ },
  { name: 'minUnits fractional', pricing: '{"strategy":"PER_UNIT","unitPrice":1,"minUnits":1.5,"maxUnits":5}', problem: /whole numbers/ },
  { name: 'maxUnits below minUnits', pricing: '{"strategy":"PER_UNIT","unitPrice":1,"minUnits":5,"maxUnits":4}', problem: /maxUnits must be at least minUnits/ },
  { name: 'maxUnits above ceiling', pricing: '{"strategy":"PER_UNIT","unitPrice":1,"minUnits":1,"maxUnits":10001}', problem: /at most 10000/ },
  { name: 'maxUnits missing', pricing: '{"strategy":"PER_UNIT","unitPrice":1,"minUnits":1}', problem: /whole numbers/ }
]

// ── client: buildPricingDefinition ─────────────────────────────────────
test('buildPricingDefinition serializes PER_UNIT as exactly the four contract fields', () => {
  const definition = buildPricingDefinition(perUnitProduct())
  assert.deepEqual(definition, { strategy: 'PER_UNIT', unitPrice: 19.99, minUnits: 1, maxUnits: 50 })
  assert.deepEqual(Object.keys(definition), ['strategy', 'unitPrice', 'minUnits', 'maxUnits'])
})

test('PER_UNIT round trips: the definition survives JSON and equals the customer mirror numbers', () => {
  for (const pricing of [
    { unitPrice: 0.01, minUnits: 1, maxUnits: 1 },
    { unitPrice: 100000, minUnits: 1, maxUnits: 10000 },
    { unitPrice: 2.5, minUnits: 3, maxUnits: 3 },
    { unitPrice: 19.9, minUnits: 10, maxUnits: 200 }
  ]) {
    const product = perUnitProduct(pricing)
    const definition = buildPricingDefinition(product)
    assert.deepEqual(JSON.parse(JSON.stringify(definition)), definition)
    assert.deepEqual(definition, { strategy: 'PER_UNIT', ...pricing })
    // What the server would store is what the client would price with.
    const priced = calculateProductPrice({ ...product, pricing: definition }, { units: pricing.minUnits })
    assert.equal(priced.total, Math.round(pricing.minUnits * pricing.unitPrice * 100) / 100)
  }
})

test('PER_UNIT serialization carries nothing extra: no other pricing key, no private internals, no quantity', () => {
  const product = perUnitProduct(
    { setupFee: 5, quantity: 9, supplierCost: 3, marginRate: 0.5, referencePrice: 2 },
    { pricingDefinition: { strategy: 'PER_UNIT', supplierCost: 3, marginRate: 0.5 }, commerceProductId: 'p-1' }
  )
  const definition = buildPricingDefinition(product)
  assert.deepEqual(Object.keys(definition), ['strategy', 'unitPrice', 'minUnits', 'maxUnits'])
  assert.doesNotMatch(JSON.stringify(definition), /quantity|supplier|margin|reference|setup|commerceProductId/i)
})

test('buildPricingDefinition never mutates the product and shares no state with it', () => {
  const product = perUnitProduct()
  const frozen = JSON.stringify(product)
  Object.freeze(product.pricing)
  const a = buildPricingDefinition(product)
  const b = buildPricingDefinition(product)
  assert.deepEqual(a, b)
  assert.notEqual(a, b)
  assert.notEqual(a, product.pricing)
  assert.equal(JSON.stringify(product), frozen)
})

test('invalid PER_UNIT values are refused with a specific reason, never clamped, coerced or defaulted', () => {
  for (const { name, pricing, problem } of INVALID_DEFINITIONS) {
    const product = perUnitProduct({}, { pricing: JSON.parse(pricing) })
    assert.throws(() => buildPricingDefinition(product), (error) => problem.test(error.message) && /^PER_UNIT pricing is invalid: /.test(error.message), name)
    assert.equal(validatePerUnitDefinition(JSON.parse(pricing)).ok, false, name)
  }
  // Values the generic editor could produce or leave behind.
  for (const bad of [NaN, Infinity, -Infinity, null, undefined, '', '5', true, [], {}]) {
    assert.throws(() => buildPricingDefinition(perUnitProduct({ unitPrice: bad })), /PER_UNIT pricing is invalid/, `unitPrice ${String(bad)}`)
    assert.throws(() => buildPricingDefinition(perUnitProduct({ minUnits: bad })), /PER_UNIT pricing is invalid/, `minUnits ${String(bad)}`)
    assert.throws(() => buildPricingDefinition(perUnitProduct({ maxUnits: bad })), /PER_UNIT pricing is invalid/, `maxUnits ${String(bad)}`)
  }
  assert.throws(() => buildPricingDefinition({ pricing: { strategy: 'PER_UNIT' } }), /PER_UNIT pricing is invalid/)
})

test('whole-cent rule: two decimal places pass, anything finer is refused', () => {
  for (const unitPrice of [0.01, 0.1, 0.99, 1, 19.9, 19.99, 123.45, 99999.99, 100000]) {
    assert.doesNotThrow(() => buildPricingDefinition(perUnitProduct({ unitPrice })), String(unitPrice))
  }
  for (const unitPrice of [0.001, 0.005, 19.995, 0.1 + 0.2, 1e-7, 100000.001, 1.0000001]) {
    assert.throws(() => buildPricingDefinition(perUnitProduct({ unitPrice })), /unitPrice/, String(unitPrice))
  }
})

test('min/max rule: 1 <= minUnits <= maxUnits <= 10000, whole numbers, boundaries exact', () => {
  const ok = (minUnits, maxUnits) => { buildPricingDefinition(perUnitProduct({ minUnits, maxUnits })) }
  assert.doesNotThrow(() => ok(1, 1))
  assert.doesNotThrow(() => ok(1, 10000))
  assert.doesNotThrow(() => ok(10000, 10000))
  assert.doesNotThrow(() => ok(7, 7))
  for (const [min, max] of [[0, 1], [-1, 5], [2, 1], [1, 10001], [10001, 10001], [1.5, 5], [1, 5.5]]) {
    assert.throws(() => ok(min, max), /PER_UNIT pricing is invalid/, `${min}/${max}`)
  }
  assert.equal(PER_UNIT_LIMITS.maxUnitsCeiling, 10000)
  assert.equal(PER_UNIT_LIMITS.minUnitsFloor, 1)
})

test('a PER_UNIT product with priced field options is refused: the price is units x unitPrice only', () => {
  const field = (option) => ({ id: 'finish', label: 'Finish', options: [{ id: 'a', label: 'A', ...option }] })
  for (const key of ['rate', 'fee', 'multiplier', 'total', 'unitFee']) {
    assert.throws(() => buildPricingDefinition(perUnitProduct({}, { fields: [field({ [key]: 5 })] })), /cannot have priced field options \(finish\.a\./, key)
    assert.throws(() => buildPricingDefinition(perUnitProduct({}, { fields: [field({ [key]: 0 })] })), /priced field options/, `${key}: 0 is still a price`)
  }
  assert.doesNotThrow(() => buildPricingDefinition(perUnitProduct({}, { fields: [field({})] })), 'unpriced options are fine')
  // The guard's key list is the admin editor's own list of editable modifiers.
  const editorKeys = read('../src/admin/AdminProductManager.jsx').match(/const modifierKeys = \[([^\]]*)\]/)[1].match(/'(\w+)'/g).map((key) => key.replace(/'/g, ''))
  assert.deepEqual(editorKeys, ['rate', 'fee', 'multiplier', 'total', 'unitFee'])
  assert.match(read('../src/lib/pricingDefinition.js'), /PRICED_OPTION_KEYS = \['rate', 'fee', 'multiplier', 'total', 'unitFee'\]/)
})

// ── existing strategies are unchanged ──────────────────────────────────
test('existing strategy serialization is unchanged: golden outputs captured before the function moved', () => {
  const golden = JSON.parse(read('./fixtures/pricing-definition-golden-before-admin-per-unit.json'))
  const run = (product) => {
    try { return { definition: JSON.parse(JSON.stringify(buildPricingDefinition(product))) } } catch (error) { return { throws: error.message } }
  }
  const actual = {}
  // The golden file covers the nine products that existed before PER_UNIT; Scan (01H) and A4/A3 Lamination (01J) have their own tests.
  for (const product of products.filter((item) => !['scan', 'a4-lamination', 'a3-lamination'].includes(item.id))) actual[product.id] = run(product)
  actual['synthetic-supplier-with-definition'] = run({ pricing: { strategy: 'SUPPLIER_MARGIN' }, pricingDefinition: { strategy: 'SUPPLIER_MARGIN', marker: 'x' } })
  actual['synthetic-photo-with-definition'] = run({ pricing: { strategy: 'PHOTOGRAPHY_SESSION' }, pricingDefinition: { strategy: 'PHOTOGRAPHY_SESSION', marker: 'y' } })
  for (const strategy of ['SUPPORTED_NOWHERE', undefined]) actual[`unknown-${strategy}`] = run({ pricing: { strategy } })
  assert.deepEqual(actual, golden)
  // Missing numbers still default to 0 for the mirror-derived strategies, and the
  // supplier strategies still hand back the very same staff-only object.
  assert.deepEqual(buildPricingDefinition({ pricing: { strategy: 'PER_AREA' } }), {
    strategy: 'PER_AREA', baseRate: 0, minimumBillableArea: 0, materials: {}, finishing: {}, artwork: {}, turnaround: {}
  })
  const staffOnly = { strategy: 'SUPPLIER_MARGIN', marker: 'x' }
  assert.strictEqual(buildPricingDefinition({ pricing: { strategy: 'SUPPLIER_MARGIN' }, pricingDefinition: staffOnly }), staffOnly)
  for (const id of ['pvc-banner', 'vinyl-stickers', 'a4-print', 'business-cards', 'printed-tshirt', 'media-services']) {
    assert.ok(golden[id].definition, `${id} still serializes`)
  }
})

test('the move is behaviour-preserving in shape: supabaseApi re-exports it and saveQuickSolutionProduct is unchanged', () => {
  const api = read('../src/lib/supabaseApi.js')
  assert.match(api, /^import \{ buildPricingDefinition \} from '\.\/pricingDefinition\.js'/m)
  assert.match(api, /^export \{ buildPricingDefinition \}/m)
  assert.doesNotMatch(api, /function optionMap|function buildPricingDefinition/, 'no second copy of the serializer')
  const save = api.match(/export async function saveQuickSolutionProduct[\s\S]*?\n\}/)[0]
  assert.equal(
    squash(save),
    squash(`export async function saveQuickSolutionProduct(product) {
      const accessToken = await getAdminAccessToken()
      return rpc('admin_update_quick_solution_product', {
        p_tenant_slug: TENANT_SLUG,
        p_product_key: product.id,
        p_customer_definition: customerDefinitionFromProduct(product),
        p_pricing_definition: buildPricingDefinition(product),
        p_expected_pricing_version: product.pricingVersion
      }, { accessToken })
    }`)
  )
  assert.doesNotMatch(api, /PER_UNIT/, 'the transport layer needs no strategy knowledge')
})

test('the serializer module is pure: only the PER_UNIT validator is imported, no I/O or environment', () => {
  const source = read('../src/lib/pricingDefinition.js')
  const code = source.replace(/\/\/[^\n]*/g, '')
  assert.deepEqual([...code.matchAll(/^import .* from '(.*)'/gm)].map((match) => match[1]), ['./perUnitPricing.js'])
  assert.doesNotMatch(code, /import\.meta|\b(fetch|window|document|localStorage|process|supabase|rpc|React|await|async)\b/)
  // The PER_UNIT branch never mentions quantity.
  const branch = code.match(/if \(strategy === 'PER_UNIT'\) \{[\s\S]*?\n {2}\}/)[0]
  assert.doesNotMatch(branch, /quantity|supplier|margin|pricingDefinition/i)
})

test('no visible admin UI was added: the generic editor already renders every PER_UNIT number, and nothing PER_UNIT-specific exists in admin', () => {
  const admin = read('../src/admin/AdminProductManager.jsx')
  assert.doesNotMatch(admin, /PER_UNIT|perUnit/)
  // The generic editor lists every numeric key of product.pricing except strategy.
  assert.match(admin, /Object\.entries\(product\.pricing\)\.filter\(\(\[key, value\]\) => key !== 'strategy' && typeof value === 'number'\)/)
  const rendered = Object.entries(perUnitProduct().pricing).filter(([key, value]) => key !== 'strategy' && typeof value === 'number').map(([key]) => key)
  assert.deepEqual(rendered, ['unitPrice', 'minUnits', 'maxUnits'])
  const adminFiles = fs.readdirSync(new URL('../src/admin/', import.meta.url))
  for (const name of adminFiles.filter((file) => /\.(jsx?|css)$/.test(file))) assert.doesNotMatch(read(`../src/admin/${name}`), /PER_UNIT|perUnit/, name)
})

// ── server: admin_update_quick_solution_product ─────────────────────────
test('server: the new function is the previous function plus exactly the four deliberate differences', () => {
  let reverted = nextFunction
  const revert = (label, from, to) => {
    assert.equal(reverted.split(from).length - 1, 1, `${label}: expected exactly one occurrence`)
    reverted = reverted.replace(from, to)
  }
  revert('allow-list', ",'PHOTOGRAPHY_SESSION','PER_UNIT') then", ",'PHOTOGRAPHY_SESSION') then")
  revert('declaration', '  v_pricing_definition jsonb;\n', '')
  const blockStart = reverted.indexOf('  -- CAFE-GUEST-01G: PER_UNIT.')
  const blockEnd = reverted.indexOf("  v_new_version := 'qsc-'")
  assert.ok(blockStart > 0 && blockEnd > blockStart, 'PER_UNIT block markers')
  reverted = reverted.slice(0, blockStart) + reverted.slice(blockEnd)
  revert('stored definition', 'pricing_definition=v_pricing_definition,', 'pricing_definition=p_pricing_definition,')
  assert.equal(reverted, previousFunction, 'reverting only the four differences must give the previous body byte for byte')
  assert.notEqual(nextFunction, previousFunction)
})

test('server: PER_UNIT joins the allow-list and nothing else is added or removed from it', () => {
  const list = (fn) => fn.match(/v_strategy not in \(([^)]*)\)/)[1].match(/'[A-Z_]+'/g).map((item) => item.replace(/'/g, ''))
  assert.deepEqual(list(previousFunction), ['PER_AREA', 'PER_PAGE', 'TIERED', 'CONFIGURABLE', 'SUPPLIER_MARGIN', 'PHOTOGRAPHY_SESSION'])
  assert.deepEqual(list(nextFunction), [...list(previousFunction), 'PER_UNIT'])
  // ENQUIRY stays outside the allow-list, as before.
  assert.doesNotMatch(list(nextFunction).join(), /ENQUIRY/)
})

test('server: PER_UNIT is validated by the shared rule, normalized to four keys, and mirrored identically', () => {
  const block = nextFunction.slice(nextFunction.indexOf('  v_pricing_definition := p_pricing_definition;'), nextFunction.indexOf("  v_new_version := 'qsc-'"))
  const code = squash(stripComments(block))
  assert.equal(
    code,
    squash(`v_pricing_definition := p_pricing_definition;
    if v_strategy = 'PER_UNIT' then
      perform commerce._qs_validate_per_unit_definition(p_pricing_definition);
      v_pricing_definition := jsonb_build_object(
        'strategy', 'PER_UNIT',
        'unitPrice', p_pricing_definition -> 'unitPrice',
        'minUnits', p_pricing_definition -> 'minUnits',
        'maxUnits', p_pricing_definition -> 'maxUnits'
      );
      v_customer_definition := jsonb_set(v_customer_definition, '{pricing}', v_pricing_definition, true);
    end if;`)
  )
  // Validation precedes the normalization, so an invalid value is never stored.
  assert.ok(block.indexOf('_qs_validate_per_unit_definition') < block.indexOf('jsonb_build_object'))
  // The block sits after the version check and before the version is issued and the row updated.
  const at = (needle) => nextFunction.indexOf(needle)
  assert.ok(at('This product changed after you opened it') < at('v_pricing_definition := p_pricing_definition;'))
  assert.ok(at('v_pricing_definition := p_pricing_definition;') < at('update commerce.service_product_configs'))
  assert.equal(nextFunction.split('pricing_definition=v_pricing_definition').length - 1, 1)
  assert.doesNotMatch(nextFunction, /pricing_definition=p_pricing_definition/)
})

test('server: no private internals or quantity reach the stored definition or the public mirror', () => {
  const block = stripComments(nextFunction.slice(nextFunction.indexOf('  v_pricing_definition := p_pricing_definition;'), nextFunction.indexOf("  v_new_version := 'qsc-'")))
  assert.doesNotMatch(block, /quantity|supplier|margin|reference|setup|fee/i, 'only strategy, unitPrice, minUnits, maxUnits')
  assert.deepEqual([...block.matchAll(/'(\w+)', p_pricing_definition -> '(\w+)'/g)].map((match) => [match[1], match[2]]), [['unitPrice', 'unitPrice'], ['minUnits', 'minUnits'], ['maxUnits', 'maxUnits']])
  // The public projection is the same object the staff definition is.
  assert.match(block, /jsonb_set\(v_customer_definition, '\{pricing\}', v_pricing_definition, true\)/)
})

test('server: the staff gate, security posture and grants are byte-for-byte the previous ones', () => {
  const gate = /if not public\.is_app_admin\(\) and not \(public\.is_opps_staff\(\) and public\.can_access_tenant\(v_tenant_id\)\) then/
  for (const fn of [previousFunction, nextFunction]) {
    assert.equal(squash(fn).match(new RegExp(gate.source, 'g')).length, 1)
    assert.match(squash(fn), /returns jsonb language plpgsql security definer set search_path = ''/)
    assert.match(fn, /auth\.uid\(\) is null/)
  }
  // Everything before the first deliberate difference is identical, including the whole gate.
  const head = (fn) => fn.slice(0, fn.indexOf('v_customer_mirror jsonb;'))
  assert.equal(head(nextFunction), head(previousFunction))
  const gateSection = (fn) => fn.slice(fn.indexOf('if auth.uid() is null'), fn.indexOf('if jsonb_typeof(p_customer_definition)'))
  assert.ok(gateSection(nextFunction).includes('public.is_app_admin()'))
  assert.equal(gateSection(nextFunction), gateSection(previousFunction))
  // No ACL or ownership statement, and no other object, is touched.
  assert.doesNotMatch(migrationCode, /\b(grant|revoke|alter|drop|insert|delete)\b/i)
  assert.doesNotMatch(migrationCode.replace(/'(?:[^']|'')*'/g, "''"), /\bcreate\s+(?!or replace function public\.admin_update_quick_solution_product)/i)
  const created = [...migrationCode.matchAll(/create or replace function ([\w.]+)/gi)].map((match) => match[1])
  assert.deepEqual(created, ['public.admin_update_quick_solution_product'])
  assert.doesNotMatch(migrationCode, /has_tenant_capability|admin_get_quick_solution_catalog|create_counter|counter_/i)
})

test('server: this is the latest definition of the admin function and the previous one is the QS-14 copy', () => {
  const files = fs.readdirSync(new URL('../supabase/migrations/', import.meta.url)).sort()
  const definers = files.filter((name) => /create or replace function public\.admin_update_quick_solution_product/i.test(read(`../supabase/migrations/${name}`)))
  assert.equal(definers.at(-1), '20260926140000_cafe_guest_01g_admin_per_unit_support.sql')
  assert.equal(definers.at(-2), '20260921120000_qs14_checkout_guards_and_supplier_rules.sql')
  assert.ok(files.includes('20260926130000_cafe_guest_01f_per_unit_pricing.sql') && files.indexOf('20260926130000_cafe_guest_01f_per_unit_pricing.sql') < files.indexOf('20260926140000_cafe_guest_01g_admin_per_unit_support.sql'), 'runs after the validator exists')
  assert.match(migration, /to_regprocedure\('commerce\._qs_validate_per_unit_definition\(jsonb\)'\) is null/, 'preflight')
})

test('server: the shared validator is the one definition rule and is not re-implemented in the admin function', () => {
  const rule = read('../supabase/migrations/20260926130000_cafe_guest_01f_per_unit_pricing.sql')
  assert.match(rule, /create or replace function commerce\._qs_validate_per_unit_definition\(/)
  assert.doesNotMatch(nextFunction, /100000|10000|round\(|trunc\(/, 'no second copy of the limits')
})

// ── scope: no product converted, nothing else touched ──────────────────
test('01G itself converts no product and creates none (Scan and A4/A3 Lamination arrive separately, in 01H and 01J)', () => {
  // The nine original products are not PER_UNIT; Scan (01H) and A4/A3 Lamination (01J) are the only PER_UNIT products.
  assert.deepEqual(products.filter((product) => product.pricing.strategy === 'PER_UNIT').map((product) => product.id), ['scan', 'a4-lamination', 'a3-lamination'])
  assert.doesNotMatch(read('../supabase/seed.sql'), /PER_UNIT/)
  assert.doesNotMatch(migrationCode.replace(/'(?:[^']|'')*'/g, "''"), /lamin|\bscan|counter|walk-?in/i)
  assert.doesNotMatch(migrationCode, /service_order|\binsert\s+into\b|\bdelete\s+from\b/i)
  // The rows this function writes are the same two as before: the config row and its product.
  assert.deepEqual([...nextFunction.matchAll(/update ([\w.]+)/g)].map((match) => match[1]), [...previousFunction.matchAll(/update ([\w.]+)/g)].map((match) => match[1]))
})

test('runtime configuration is unchanged: units, never quantity', () => {
  assert.doesNotMatch(migrationCode, /quantity/i)
  assert.doesNotMatch(read('../src/lib/pricingDefinition.js').match(/if \(strategy === 'PER_UNIT'\) \{[\s\S]*?\n {2}\}/)[0], /quantity/i)
  const priced = calculateProductPrice({ ...perUnitProduct(), pricing: buildPricingDefinition(perUnitProduct()) }, { units: '4' })
  assert.deepEqual(priced.metrics, { units: 4, unitPrice: 19.99 })
  assert.equal(calculateProductPrice({ ...perUnitProduct(), pricing: buildPricingDefinition(perUnitProduct()) }, { quantity: 4 }).total, 0)
})

// ── the SQL contract test ───────────────────────────────────────────────
test('the SQL contract test is rollback-contained and holds the same invalid-definition table as the client', () => {
  const code = stripComments(sqlTest)
  assert.match(code, /^\s*\\set ON_ERROR_STOP on\s*\n\s*begin;/m)
  assert.match(code, /\brollback;\s*\n\s*select 'CAFE-GUEST-01G/)
  assert.doesNotMatch(code, /^\s*commit\s*;/im)
  for (const { name, pricing } of INVALID_DEFINITIONS) {
    const literal = pricing.replace(/^\{"strategy":"PER_UNIT",/, '{"strategy":"PER_UNIT",')
    assert.ok(sqlTest.includes(`'${literal}'`), `SQL test lists: ${name}`)
  }
  assert.match(code, /'22023', 'Pricing configuration is invalid\.'/)
  for (const required of [
    /Staff sign-in is required\./, /You do not have access to Quick Solution Product Admin\./,
    /stored definition must be exactly the four contract fields/, /customer mirror must equal the definition/,
    /extra keys must not be stored anywhere/, /a rejected save must not change the stored definition/,
    /Pricing strategy is not supported\./, /PER_AREA must store p_pricing_definition verbatim/,
    /a saved PER_UNIT definition must price/
  ]) assert.match(code, required)
  assert.match(sqlTest, /'\{"strategy":"PER_UNIT","unitPrice":19\.99,"minUnits":1,"maxUnits":50\}'::jsonb/)
})

test('the new test file is part of npm test', () => {
  assert.match(JSON.parse(read('../package.json')).scripts.test, /tests\/per-unit-admin\.test\.mjs/)
})
