import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'
import {
  PER_UNIT_LIMITS,
  PER_UNIT_MESSAGES,
  validatePerUnitDefinition,
  parseUnits,
  calculatePerUnit
} from '../src/lib/perUnitPricing.js'
import { calculateProductPrice, getDefaultConfig } from '../src/lib/pricing.js'
import { resolveCounterAction } from '../src/lib/counterCatalogue.js'
import { products } from '../src/data/products.js'

// CAFE-GUEST-01F - the neutral PER_UNIT pricing strategy. The client mirror is
// executed for real; the server (SQL) is checked statically, and its rollback
// contract test (supabase/tests/cafe_guest_01f_per_unit_pricing.sql, executed
// by the local harness: npm run test:sql) must hold the SAME case table: each case here is a pair of
// JSON literals that the client parses and that must appear verbatim, with the
// same expected message, in that SQL test.

const read = (path) => fs.readFileSync(new URL(path, import.meta.url), 'utf8')
const stripComments = (sql) => sql.replace(/--[^\n]*/g, '')
const squash = (sql) => sql.replace(/\s+/g, ' ').trim()
const escapeRegex = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

const MIGRATION = '../supabase/migrations/20260926130000_cafe_guest_01f_per_unit_pricing.sql'
const migration = read(MIGRATION)
const migrationCode = stripComments(migration)
const sqlTest = read('../supabase/tests/cafe_guest_01f_per_unit_pricing.sql')
const clientSource = read('../src/lib/perUnitPricing.js')
const clientCode = clientSource.replace(/\/\/[^\n]*/g, '')

const DEFAULT = '{"strategy":"PER_UNIT","unitPrice":19.99,"minUnits":1,"maxUnits":50}'
const RANGE = 'Units are outside the supported range.'
const WHOLE = 'Units must be a whole number.'
const REQUIRED = 'Units are required.'
const INVALID = 'Pricing configuration is invalid.'

const VALID_CASES = [
  { def: '{"unitPrice":2.5,"minUnits":1,"maxUnits":10}', cfg: '{"units":1}', total: 2.5, summary: '1 × 2.50' },
  { def: DEFAULT, cfg: '{"units":3}', total: 59.97, summary: '3 × 19.99' },
  { def: '{"unitPrice":0.05,"minUnits":1,"maxUnits":100}', cfg: '{"units":"12"}', total: 0.6, summary: '12 × 0.05' },
  { def: DEFAULT, cfg: '{"units":3.0}', total: 59.97, summary: '3 × 19.99' },
  { def: DEFAULT, cfg: '{"units":1}', total: 19.99, summary: '1 × 19.99' },
  { def: DEFAULT, cfg: '{"units":50}', total: 999.5, summary: '50 × 19.99' },
  { def: '{"unitPrice":100000,"minUnits":1,"maxUnits":10000}', cfg: '{"units":10000}', total: 1000000000, summary: '10000 × 100000.00' }
]

const ERROR_CASES = [
  // unit counts
  { name: 'units missing', def: DEFAULT, cfg: '{}', message: REQUIRED },
  { name: 'units null', def: DEFAULT, cfg: '{"units":null}', message: REQUIRED },
  { name: 'units letters', def: DEFAULT, cfg: '{"units":"abc"}', message: WHOLE },
  { name: 'units empty string', def: DEFAULT, cfg: '{"units":""}', message: WHOLE },
  { name: 'units leading space', def: DEFAULT, cfg: '{"units":" 3"}', message: WHOLE },
  { name: 'units trailing space', def: DEFAULT, cfg: '{"units":"3 "}', message: WHOLE },
  { name: 'units plus sign', def: DEFAULT, cfg: '{"units":"+3"}', message: WHOLE },
  { name: 'units minus string', def: DEFAULT, cfg: '{"units":"-3"}', message: WHOLE },
  { name: 'units decimal string', def: DEFAULT, cfg: '{"units":"3.0"}', message: WHOLE },
  { name: 'units exponent string', def: DEFAULT, cfg: '{"units":"1e1"}', message: WHOLE },
  { name: 'units leading zeros', def: DEFAULT, cfg: '{"units":"007"}', message: WHOLE },
  { name: 'units fractional number', def: DEFAULT, cfg: '{"units":3.5}', message: WHOLE },
  { name: 'units boolean', def: DEFAULT, cfg: '{"units":true}', message: WHOLE },
  { name: 'units array', def: DEFAULT, cfg: '{"units":[3]}', message: WHOLE },
  { name: 'units object', def: DEFAULT, cfg: '{"units":{}}', message: WHOLE },
  { name: 'units zero', def: DEFAULT, cfg: '{"units":0}', message: RANGE },
  { name: 'units zero string', def: DEFAULT, cfg: '{"units":"0"}', message: RANGE },
  { name: 'units negative number', def: DEFAULT, cfg: '{"units":-3}', message: RANGE },
  { name: 'units above maxUnits', def: DEFAULT, cfg: '{"units":51}', message: RANGE },
  { name: 'units more than nine digits', def: DEFAULT, cfg: '{"units":"1234567890"}', message: RANGE },
  { name: 'units enormous number', def: DEFAULT, cfg: '{"units":1e30}', message: RANGE },
  // pricing definitions
  { name: 'unitPrice zero', def: '{"unitPrice":0,"minUnits":1,"maxUnits":5}', cfg: '{"units":1}', message: INVALID },
  { name: 'unitPrice negative', def: '{"unitPrice":-1,"minUnits":1,"maxUnits":5}', cfg: '{"units":1}', message: INVALID },
  { name: 'unitPrice above ceiling', def: '{"unitPrice":100000.01,"minUnits":1,"maxUnits":5}', cfg: '{"units":1}', message: INVALID },
  { name: 'unitPrice fractional cent', def: '{"unitPrice":19.995,"minUnits":1,"maxUnits":5}', cfg: '{"units":1}', message: INVALID },
  { name: 'unitPrice string', def: '{"unitPrice":"19.99","minUnits":1,"maxUnits":5}', cfg: '{"units":1}', message: INVALID },
  { name: 'unitPrice missing', def: '{"minUnits":1,"maxUnits":5}', cfg: '{"units":1}', message: INVALID },
  { name: 'minUnits zero', def: '{"unitPrice":1,"minUnits":0,"maxUnits":5}', cfg: '{"units":1}', message: INVALID },
  { name: 'minUnits fractional', def: '{"unitPrice":1,"minUnits":1.5,"maxUnits":5}', cfg: '{"units":2}', message: INVALID },
  { name: 'maxUnits below minUnits', def: '{"unitPrice":1,"minUnits":5,"maxUnits":4}', cfg: '{"units":5}', message: INVALID },
  { name: 'maxUnits above ceiling', def: '{"unitPrice":1,"minUnits":1,"maxUnits":10001}', cfg: '{"units":1}', message: INVALID },
  { name: 'maxUnits missing', def: '{"unitPrice":1,"minUnits":1}', cfg: '{"units":1}', message: INVALID },
  { name: 'definition not an object', def: '[]', cfg: '{"units":1}', message: INVALID },
  { name: 'definition checked before units', def: '{"unitPrice":0,"minUnits":1,"maxUnits":5}', cfg: '{}', message: INVALID }
]

const sqlDefinition = (def) => (def === DEFAULT ? 'v_definition' : `'${def}'`)

// ── the client mirror, executed ────────────────────────────────────────
test('basic calculation and boundaries: total = units x unitPrice, exact to the cent', () => {
  for (const { def, cfg, total, summary } of VALID_CASES) {
    const result = calculatePerUnit(JSON.parse(def), JSON.parse(cfg))
    assert.equal(result.ok, true, `${def} ${cfg}`)
    assert.equal(result.total, total, `${def} ${cfg}`)
    assert.equal(result.summary, summary)
    assert.deepEqual(result.lines, [{ label: 'Units', value: total }])
    assert.deepEqual(result.metrics, { units: JSON.parse(cfg).units === undefined ? undefined : Number(JSON.parse(cfg).units), unitPrice: JSON.parse(def).unitPrice })
  }
})

test('invalid unit counts and invalid pricing definitions are rejected with the server messages, never priced', () => {
  for (const { name, def, cfg, message } of ERROR_CASES) {
    const result = calculatePerUnit(JSON.parse(def), JSON.parse(cfg))
    assert.equal(result.ok, false, name)
    assert.equal(result.message, message, name)
    assert.equal('total' in result, false, `${name}: a failed result carries no total`)
  }
})

test('parseUnits: number inputs deliver strings, and only plain whole numbers pass', () => {
  assert.deepEqual(parseUnits('12'), { ok: true, units: 12 })
  assert.deepEqual(parseUnits(12), { ok: true, units: 12 })
  assert.deepEqual(parseUnits(0), { ok: true, units: 0 }, 'zero parses; the range check rejects it')
  for (const value of [undefined, null]) assert.equal(parseUnits(value).code, 'required')
  for (const value of [NaN, 1.5, '1.5', '', ' ', '01', '1,000', true, false, [], {}, Symbol('x'), 10n]) {
    assert.equal(parseUnits(value).code, 'not_whole', String(typeof value))
  }
  assert.equal(parseUnits(Infinity).code, 'out_of_range')
  assert.equal(parseUnits(-Infinity).code, 'out_of_range')
  assert.equal(parseUnits('1234567890').code, 'out_of_range')
  assert.deepEqual(parseUnits('123456789'), { ok: true, units: 123456789 })
})

test('validatePerUnitDefinition: exact limits and whole-cent unit prices', () => {
  const ok = (pricing) => validatePerUnitDefinition(pricing).ok
  assert.equal(ok({ unitPrice: 0.01, minUnits: 1, maxUnits: 1 }), true)
  assert.equal(ok({ unitPrice: 100000, minUnits: 1, maxUnits: 10000 }), true)
  assert.equal(ok({ unitPrice: 19.9, minUnits: 1, maxUnits: 5 }), true)
  for (const unitPrice of [0, -0.01, 100000.01, 19.995, 0.001, 0.1 + 0.2, 1e-7, NaN, Infinity, '1', null, undefined, true]) {
    assert.equal(ok({ unitPrice, minUnits: 1, maxUnits: 5 }), false, String(unitPrice))
  }
  for (const [minUnits, maxUnits] of [[0, 5], [1.5, 5], [5, 4], [1, 10001], [1, 1.5], ['1', 5], [1, '5'], [undefined, 5], [1, undefined], [NaN, 5], [1, Infinity]]) {
    assert.equal(ok({ unitPrice: 1, minUnits, maxUnits }), false, `${minUnits}/${maxUnits}`)
  }
  for (const pricing of [null, undefined, [], 'PER_UNIT', 3]) assert.equal(ok(pricing), false)
  assert.deepEqual(
    [PER_UNIT_LIMITS.minUnitsFloor, PER_UNIT_LIMITS.maxUnitsCeiling, PER_UNIT_LIMITS.maxUnitPrice, PER_UNIT_LIMITS.maxUnitDigits],
    [1, 10000, 100000, 9]
  )
})

test('rounding and money: whole-cent prices give exact totals with no floating drift', () => {
  for (let cents = 1; cents <= 250; cents += 1) {
    const unitPrice = cents / 100
    for (const units of [1, 3, 7, 33, 100, 999]) {
      const result = calculatePerUnit({ unitPrice, minUnits: 1, maxUnits: 1000 }, { units })
      assert.equal(result.ok, true)
      assert.equal(result.total.toFixed(2), ((units * cents) / 100).toFixed(2))
      assert.equal(Number(result.total.toFixed(2)), result.total, `${units} x ${unitPrice} has no sub-cent residue`)
    }
  }
})

test('inputs are never mutated and results share no state', () => {
  const pricing = Object.freeze({ strategy: 'PER_UNIT', unitPrice: 4.5, minUnits: 1, maxUnits: 20 })
  const config = Object.freeze({ units: 6, note: 'x' })
  const a = calculatePerUnit(pricing, config)
  const b = calculatePerUnit(pricing, config)
  assert.deepEqual(a, b)
  assert.notEqual(a.lines, b.lines)
  a.lines.push('x')
  assert.equal(b.lines.length, 1)
  assert.equal(calculatePerUnit(pricing, null).message, REQUIRED)
  assert.equal(calculatePerUnit(pricing, undefined).message, REQUIRED)
})

// ── integration with the client price calculator ───────────────────────
const unitProduct = (pricing) => ({ id: 'synthetic-unit', name: 'Synthetic unit product', pricingVersion: 'v1', pricing, fields: [] })

test('calculateProductPrice: PER_UNIT prices through the same envelope as every strategy', () => {
  const result = calculateProductPrice(unitProduct(JSON.parse(DEFAULT)), { units: '3' })
  assert.equal(result.total, 59.97)
  assert.equal(result.summary, '3 × 19.99')
  assert.deepEqual(result.metrics, { units: 3, unitPrice: 19.99 })
  assert.equal(result.snapshot.pricingStrategy, 'PER_UNIT')
  assert.deepEqual(result.snapshot.calculation.metrics, { units: 3, unitPrice: 19.99 })
  assert.deepEqual(Object.keys(result).sort(), ['lines', 'metrics', 'snapshot', 'summary', 'total'])
})

test('calculateProductPrice: invalid PER_UNIT input yields no usable total and never throws', () => {
  for (const config of [{}, { units: '' }, { units: 'x' }, { units: 0 }, { units: 51 }, { units: 2.5 }, { quantity: 3 }]) {
    const result = calculateProductPrice(unitProduct(JSON.parse(DEFAULT)), config)
    assert.equal(result.total, 0, JSON.stringify(config))
    assert.equal(result.metrics.invalid, true)
    assert.equal(result.metrics.units, null)
    assert.ok([REQUIRED, WHOLE, RANGE].includes(result.summary), result.summary)
    assert.deepEqual(result.lines, [])
  }
  for (const pricing of [{ strategy: 'PER_UNIT' }, { strategy: 'PER_UNIT', unitPrice: 0, minUnits: 1, maxUnits: 5 }, undefined]) {
    const product = { ...unitProduct(pricing), pricing: pricing && { ...pricing } }
    if (!pricing) product.pricing = { strategy: 'PER_UNIT' }
    const result = calculateProductPrice(product, { units: 1 })
    assert.equal(result.total, 0)
    assert.equal(result.summary, INVALID)
    assert.equal(result.metrics.invalid, true)
  }
})

test('no accidental configuration.quantity: the count key is units, and quantity is neither read, written nor accepted', () => {
  const deepKeys = (value, keys = new Set()) => {
    if (Array.isArray(value)) value.forEach((item) => deepKeys(item, keys))
    else if (value && typeof value === 'object') for (const [key, child] of Object.entries(value)) { keys.add(key); deepKeys(child, keys) }
    return keys
  }
  const good = calculatePerUnit(JSON.parse(DEFAULT), { units: 3 })
  assert.equal(deepKeys(good).has('quantity'), false)
  assert.equal(deepKeys(calculateProductPrice(unitProduct(JSON.parse(DEFAULT)), { units: 3 }).metrics).has('quantity'), false)
  // A quantity does not stand in for units.
  assert.equal(calculatePerUnit(JSON.parse(DEFAULT), { quantity: 3 }).message, REQUIRED)
  assert.equal(calculatePerUnit(JSON.parse(DEFAULT), { quantity: 3, units: 2 }).total, 39.98)

  assert.doesNotMatch(clientCode, /quantity/i, 'client module code never mentions quantity')
  const helper = migrationCode.match(/create or replace function commerce\._qs_price_per_unit[\s\S]*?\$function\$;/)[0]
  assert.doesNotMatch(helper, /quantity/i, 'server helper never mentions quantity')
  const dispatch = migrationCode.match(/if v_strategy = 'PER_UNIT' then[\s\S]*?end if;/)[0]
  assert.doesNotMatch(dispatch, /quantity/i, 'server dispatch never mentions quantity')
  // The word units is used nowhere else in the catalogue as a config key - only
  // by Scan (CAFE-GUEST-01H), the first PER_UNIT product, as its `units` field.
  const catalogue = read('../src/data/products.js')
  const scanStart = catalogue.indexOf('// CAFE-GUEST-01H / 01K - Scan')
  const scanEnd = catalogue.indexOf('export const guidedJourneys')
  assert.ok(scanStart > 0 && scanEnd > scanStart)
  assert.doesNotMatch(catalogue.slice(0, scanStart), /\bunits\b/, 'the nine original products')
  assert.doesNotMatch(read('../supabase/seed.sql'), /\bunits\b/)
  // Why: the handoff treats configuration.quantity as a quantity override.
  assert.match(read('../supabase/migrations/20260913192900_qs_07_1_collection_point_visibility.sql'), /soi\.configuration->>'quantity'/)
})

// ── existing strategies are unchanged ──────────────────────────────────
test('client regression: every existing product prices exactly as before (golden outputs captured pre-change)', () => {
  const golden = JSON.parse(read('./fixtures/pricing-golden-before-per-unit.json'))
  const overrides = {
    'pvc-banner': [{}, { width: 2, height: 1.5, material: 'premium', finishing: 'eyelets', turnaround: 'express' }],
    'vinyl-stickers': [{}, { width: 0.5, height: 0.5 }],
    'a4-print': [{ pages: 12 }, { pages: 12, copies: 3, printMode: 'colour', sides: 'double', finish: 'staple' }],
    'business-cards': [{}, { quantity: '250', stock: 'thick', finish: 'matt' }],
    'printed-tshirt': [{}, { quantity: 12 }],
    'media-services': [{}], flags: [{}], gazebos: [{}], 'photo-session': [{}]
  }
  // The golden file covers the nine products that existed before PER_UNIT; Scan (01H) and A4/A3 Lamination (01J) are new.
  const original = products.filter((product) => !['scan', 'a4-lamination', 'a3-lamination'].includes(product.id))
  assert.deepEqual(Object.keys(golden).sort(), original.map((product) => product.id).sort())
  for (const product of original) {
    const actual = overrides[product.id].map((preset) => {
      const { total, summary, lines, metrics } = calculateProductPrice(product, getDefaultConfig(product, preset))
      return JSON.parse(JSON.stringify({ preset, total, summary, lines, metrics }))
    })
    assert.deepEqual(actual, golden[product.id], product.id)
  }
})

test('client regression: an unknown strategy still falls back to a quote, and PER_UNIT is the only case added', () => {
  const unknown = calculateProductPrice({ id: 'x', name: 'X', pricingVersion: 'v', pricing: { strategy: 'SOMETHING_NEW' }, fields: [] }, {})
  assert.deepEqual([unknown.total, unknown.summary], [0, 'Quote required'])
  const source = read('../src/lib/pricing.js')
  const cases = [...source.matchAll(/case '([A-Z_]+)':/g)].map((match) => match[1])
  assert.deepEqual(cases, ['PER_AREA', 'PER_PAGE', 'PER_UNIT', 'TIERED', 'CONFIGURABLE', 'ENQUIRY', 'SUPPLIER_MARGIN', 'PHOTOGRAPHY_SESSION'])
})

function wrapperOf(sql) {
  const match = sql.replace(/\r\n/g, '\n').match(/create or replace function commerce\.qs_calculate_price\(p_tenant_id uuid, p_product_key text, p_configuration jsonb\)[\s\S]*?\n\$function\$;/)
  assert.ok(match, 'wrapper definition not found')
  return match[0]
}

test('server regression: the wrapper is the latest previous definition plus exactly one PER_UNIT dispatch block', () => {
  const previous = wrapperOf(read('../supabase/migrations/20260921120000_qs14_checkout_guards_and_supplier_rules.sql'))
  const next = wrapperOf(migration)
  const start = next.indexOf('  -- CAFE-GUEST-01F: neutral PER_UNIT strategy.')
  const end = next.indexOf('  return commerce.qs_calculate_price_legacy(')
  assert.ok(start > 0 && end > start, 'dispatch block markers')
  const withoutBlock = next.slice(0, start) + next.slice(end)
  assert.equal(squash(withoutBlock), squash(previous), 'every existing strategy is byte-for-byte the previous definition')
  assert.equal(next.split("v_strategy = 'PER_UNIT'").length - 1, 1, 'PER_UNIT is dispatched exactly once')

  // No later migration redefines the wrapper, so this really is the latest.
  const files = fs.readdirSync(new URL('../supabase/migrations/', import.meta.url)).sort()
  const definers = files.filter((name) => /create or replace function commerce\.qs_calculate_price\(/i.test(read(`../supabase/migrations/${name}`)))
  assert.equal(definers.at(-1), '20260926130000_cafe_guest_01f_per_unit_pricing.sql')
  assert.equal(definers.at(-2), '20260921120000_qs14_checkout_guards_and_supplier_rules.sql')

  // The dispatch comes after every other strategy and before the legacy delegation.
  assert.ok(next.indexOf("v_strategy = 'PHOTOGRAPHY_SESSION'") < start)
})

// ── server contract, checked statically ────────────────────────────────
const helperOf = (name) => migrationCode.match(new RegExp(`create or replace function commerce\\.${name}[\\s\\S]*?\\$function\\$;`))[0]

test('server helpers: signatures, purity, privileges and messages', () => {
  const helper = helperOf('_qs_price_per_unit')
  const validator = helperOf('_qs_validate_per_unit_definition')
  assert.match(squash(helper), /commerce\._qs_price_per_unit\( p_pricing jsonb, p_configuration jsonb \) returns jsonb language plpgsql immutable set search_path = ''/)
  assert.match(squash(validator), /commerce\._qs_validate_per_unit_definition\( p_pricing jsonb \) returns void language plpgsql immutable set search_path = ''/)
  assert.match(migrationCode, /revoke all on function commerce\._qs_price_per_unit\(jsonb, jsonb\)\s+from public, anon, authenticated, service_role;/)
  assert.match(migrationCode, /revoke all on function commerce\._qs_validate_per_unit_definition\(jsonb\)\s+from public, anon, authenticated, service_role;/)
  assert.doesNotMatch(migrationCode, /\bgrant\b/i)
  for (const body of [helper, validator]) assert.doesNotMatch(body, /\b(from|insert|update|delete)\s+(commerce|public)\./i, 'the helpers read no table')

  const raised = [...(validator + helper).matchAll(/errcode = '(\d+)', message = '([^']+)'/g)].map((match) => [match[1], match[2]])
  assert.ok(raised.length >= 8)
  assert.ok(raised.every(([code]) => code === '22023'))
  assert.deepEqual([...new Set(raised.map(([, message]) => message))].sort(), Object.values(PER_UNIT_MESSAGES).sort())
  // The definition rule lives only in the validator, and only it raises the definition message.
  assert.deepEqual([...new Set([...validator.matchAll(/message = '([^']+)'/g)].map((match) => match[1]))], [PER_UNIT_MESSAGES.definitionInvalid])
  assert.doesNotMatch(helper, /Pricing configuration is invalid/)
})

test('server helpers: limits, money and order of validation match the client', () => {
  const helper = helperOf('_qs_price_per_unit')
  const validator = squash(helperOf('_qs_validate_per_unit_definition'))
  const text = squash(helper)
  assert.match(validator, new RegExp(`v_unit_price > ${PER_UNIT_LIMITS.maxUnitPrice}`))
  assert.match(validator, new RegExp(`v_max_units > ${PER_UNIT_LIMITS.maxUnitsCeiling}`))
  assert.match(validator, new RegExp(`v_min_units < ${PER_UNIT_LIMITS.minUnitsFloor}`))
  assert.match(text, new RegExp(`length\\(v_text\\) > ${PER_UNIT_LIMITS.maxUnitDigits}`))
  assert.match(validator, /v_unit_price <= 0/)
  assert.match(validator, /v_unit_price <> round\(v_unit_price, 2\)/, 'whole-cent unit prices')
  assert.match(validator, /v_min_units <> trunc\(v_min_units\)/)
  assert.match(validator, /v_max_units <> trunc\(v_max_units\)/)
  assert.match(validator, /v_max_units < v_min_units/)
  assert.match(text, /perform commerce\._qs_validate_per_unit_definition\(p_pricing\);/, 'price time reuses the one rule')
  assert.match(text, /v_total := round\(v_units \* v_unit_price, 2\)/)
  assert.match(text, /'summary', v_units::bigint::text \|\| ' × ' \|\| to_char\(v_unit_price, 'FM9999999990\.00'\)/)
  assert.match(text, /'metrics', jsonb_build_object\('units', v_units::bigint, 'unitPrice', v_unit_price\)/)

  // Same digit rule as the client.
  const clientDigits = clientSource.match(/PLAIN_DIGITS = \/(.*)\//)[1]
  assert.ok(helper.includes(`'${clientDigits}'`), 'the digit pattern is identical')

  // Definition first, then presence/format of units, then range.
  const order = ['perform commerce._qs_validate_per_unit_definition', "'Units are required.'", "'Units must be a whole number.'", "'Units are outside the supported range.'"].map((needle) => helper.indexOf(needle))
  assert.ok(order.every((index) => index >= 0))
  assert.deepEqual([...order].sort((a, b) => a - b), order)
})

test('the client and the server agree on every case: each case table entry appears verbatim in the SQL contract test', () => {
  for (const { name, def, cfg, message } of ERROR_CASES) {
    const pattern = new RegExp(`${escapeRegex(sqlDefinition(def))}, '${escapeRegex(cfg)}'\\),\\s*'${escapeRegex(name)}', '22023', '${escapeRegex(message)}'`)
    assert.match(sqlTest, pattern, name)
  }
  for (const { def, cfg, total } of VALID_CASES) {
    const call = new RegExp(`_qs_price_per_unit\\(${escapeRegex(sqlDefinition(def))}, '${escapeRegex(cfg)}'\\)`)
    assert.match(sqlTest, call, `${def} ${cfg}`)
    const expected = total.toFixed(2).replace(/\.00$/, '')
    assert.ok(sqlTest.includes(expected), `expected total ${expected} appears in the SQL test`)
  }
  assert.ok(sqlTest.includes(`v_definition constant jsonb := '${DEFAULT}'`))
})

test('the SQL contract test is rollback-contained, holds the regression fixtures and covers the wrapper', () => {
  const code = stripComments(sqlTest)
  assert.match(code, /^\s*\\set ON_ERROR_STOP on\s*\n\s*begin;/m)
  assert.match(code, /\brollback;\s*\n\s*select 'CAFE-GUEST-01F/)
  assert.doesNotMatch(code, /^\s*commit\s*;/im)
  for (const required of [
    /PER_UNIT metrics must never contain quantity/, /wrapper envelope changed/, /wrapper snapshot changed/,
    /PER_AREA changed/, /PER_PAGE changed/, /printedPages/, /ENQUIRY changed/, /a quantity key is not units/,
    /has_function_privilege\('anon'/, /must not mention quantity, supplier cost or margin/
  ]) assert.match(code, required)
})

// ── scope: no product, no admin change, nothing else ───────────────────
test('only Scan and the two Lamination products use PER_UNIT, and the nine original products are unchanged', () => {
  assert.equal(products.length, 12, 'the nine original products plus Scan, A4 Lamination and A3 Lamination')
  assert.deepEqual(products.filter((product) => product.pricing.strategy === 'PER_UNIT').map((product) => product.id), ['scan', 'a4-lamination', 'a3-lamination'])
  for (const product of products) {
    if (!/^a[34]-lamination$/.test(product.id)) assert.doesNotMatch(`${product.id} ${product.name}`, /lamin/i)
    if (product.id !== 'scan') assert.doesNotMatch(`${product.id} ${product.name}`, /\bscan/i)
  }
  const files = fs.readdirSync(new URL('../supabase/migrations/', import.meta.url)).sort()
  const users = files.filter((name) => /PER_UNIT/.test(read(`../supabase/migrations/${name}`)))
  assert.deepEqual(
    users,
    ['20260926130000_cafe_guest_01f_per_unit_pricing.sql', '20260926140000_cafe_guest_01g_admin_per_unit_support.sql', '20260926150000_cafe_guest_01h_scan_product.sql', '20260926160000_cafe_guest_01i_lamination_product.sql', '20260926170000_cafe_guest_01j_lamination_a4_a3.sql', '20260926180000_cafe_guest_01k_scan_final.sql', '20260926220000_cafe_guest_01m_counter_create_order_rpc.sql'],
    'only the 01F pricing, 01G admin, 01H Scan, 01I placeholder (historical), 01J Lamination, 01K Scan-final and 01M counter-create (quantity-override refusal) migrations mention PER_UNIT'
  )
  assert.doesNotMatch(read('../supabase/seed.sql'), /PER_UNIT/)
  const catalogueSource = read('../src/data/products.js')
  assert.doesNotMatch(catalogueSource.slice(0, catalogueSource.indexOf('// CAFE-GUEST-01H / 01K - Scan')), /PER_UNIT/, 'nothing before the Scan entry uses PER_UNIT')
  assert.equal((catalogueSource.match(/strategy: 'PER_UNIT'/g) || []).length, 3, 'exactly three product definitions: Scan, A4 Lamination, A3 Lamination')
  for (const name of files.filter((file) => /^20260926/.test(file) && !/per_unit|01g_admin|01h_scan|01i_lamination|01j_lamination|01k_scan|01m_counter_create/.test(file))) {
    assert.doesNotMatch(stripComments(read(`../supabase/migrations/${name}`)), /PER_UNIT/, name)
  }
})

test('the migration changes no data, product, admin function, RPC signature or table', () => {
  const code = migrationCode.replace(/'(?:[^']|'')*'/g, "''")
  assert.doesNotMatch(code, /\binsert\s+into\b|\bupdate\s+[\w."]+\s+(?:\w+\s+)?set\b|\bdelete\s+from\b/i)
  assert.doesNotMatch(code, /\balter\s+table\b|\bcreate\s+(table|index|trigger|policy|type|domain|view)\b/i)
  const created = [...code.matchAll(/create or replace function ([\w.]+)/gi)].map((match) => match[1])
  assert.deepEqual(created, ['commerce._qs_validate_per_unit_definition', 'commerce._qs_price_per_unit', 'commerce.qs_calculate_price'])
  assert.doesNotMatch(code, /admin_update_quick_solution_product|has_tenant_capability|is_app_admin|is_opps_staff|auth\.uid/i)
})

test('the admin save path is CAFE-GUEST-01G: this migration records it and shares its definition rule', () => {
  assert.match(migration, /admin save path/)
  assert.match(migration, /20260926140000_cafe_guest_01g_admin_per_unit_support\.sql/)
  assert.match(read('../supabase/migrations/20260926140000_cafe_guest_01g_admin_per_unit_support.sql'), /commerce\._qs_validate_per_unit_definition\(p_pricing_definition\)/)
})

test('other strategies and modules are untouched: A4 contract, supplier logic, counter rules, POS decisions', () => {
  assert.equal(resolveCounterAction({ pricing: { strategy: 'PER_UNIT' } }), 'order')
  assert.equal(products.find((product) => product.id === 'photo-session').active, false, 'photo-session drift left as found')
  for (const product of products) assert.strictEqual(product.channels.pos, true, product.id)
  const a4 = read('../src/lib/counterPrintConfig.js')
  assert.doesNotMatch(a4, /PER_UNIT|perUnit/)
})

test('the module is pure: no imports, I/O, React or Supabase, and no product or pricing-definition internals', () => {
  assert.doesNotMatch(clientCode, /^\s*import\s/m)
  assert.doesNotMatch(clientCode, /\b(fetch|window|document|localStorage|process|require|supabase|rpc|React|await|async|Promise)\b/)
  assert.doesNotMatch(clientCode, /pricing_definition|pricingDefinition|marginRate|supplier|referencePrice|sourceUrl|scan|lamin/i)
  assert.ok(Object.isFrozen(PER_UNIT_LIMITS) && Object.isFrozen(PER_UNIT_MESSAGES))
  assert.match(read('../src/lib/pricing.js'), /^import \{ calculatePerUnit \} from '\.\/perUnitPricing\.js'/m)
})

test('the new test file is part of npm test', () => {
  assert.match(JSON.parse(read('../package.json')).scripts.test, /tests\/per-unit-pricing\.test\.mjs/)
})
