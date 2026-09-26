import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'
import {
  A4_COUNTER_PRINT_LIMITS,
  A4_COUNTER_PRINT_OPTIONS,
  A4_COUNTER_PRINT_DEFAULTS,
  CounterPrintInputError,
  validateA4CounterPrintInput,
  buildA4CounterPrintConfig
} from '../src/lib/counterPrintConfig.js'
import { products } from '../src/data/products.js'

// CAFE-GUEST-01F - the A4 counter print configuration adapter. No price is
// calculated anywhere in these tests: they pin the configuration SHAPE the
// existing server (commerce.qs_calculate_price) already accepts.

const moduleUrl = new URL('../src/lib/counterPrintConfig.js', import.meta.url)
const source = fs.readFileSync(moduleUrl, 'utf8')
const code = source.replace(/\/\/[^\n]*/g, '')
const read = (path) => fs.readFileSync(new URL(path, import.meta.url), 'utf8')
const a4 = products.find((product) => product.id === 'a4-print')

const FIELDS = ['pages', 'copies', 'printMode', 'sides', 'finish', 'documentInstructions', 'documentPlanValid']

function keysDeep(value, found = new Set()) {
  if (Array.isArray(value)) value.forEach((item) => keysDeep(item, found))
  else if (value && typeof value === 'object') {
    for (const [key, child] of Object.entries(value)) {
      found.add(key)
      keysDeep(child, found)
    }
  }
  return found
}
const codesOf = (input) => validateA4CounterPrintInput(input).errors.map((error) => `${error.field}:${error.code}`)

// ── output shape ───────────────────────────────────────────────────────
test('a physical A4 job builds exactly the existing a4-print configuration shape', () => {
  assert.deepEqual(
    buildA4CounterPrintConfig({ pages: 12, copies: 3, printMode: 'bw', sides: 'single', finish: 'none' }),
    {
      pages: 12,
      copies: 3,
      printMode: 'bw',
      sides: 'single',
      finish: 'none',
      documentInstructions: [{ selection: 'all', sourcePages: 12 }],
      documentPlanValid: true
    }
  )
})

test('pages vs copies: 12 pages x 3 copies is one 12-page source set, three copies - never 36 pages or a quantity', () => {
  const config = buildA4CounterPrintConfig({ pages: 12, copies: 3 })
  assert.equal(config.pages, 12)
  assert.equal(config.copies, 3)
  assert.equal(config.documentInstructions.length, 1)
  assert.equal(config.documentInstructions[0].sourcePages, 12)
  const sourcePages = config.documentInstructions.reduce((sum, item) => sum + item.sourcePages, 0)
  assert.equal(sourcePages, 12, 'the source set is 12 pages, not 36')
  assert.ok(!keysDeep(config).has('quantity'))
  assert.ok(!keysDeep(config).has('printedPages'), 'printedPages is derived by the server, never sent')
  assert.ok(!JSON.stringify(config).includes('36'))
  // What the server derives from this configuration (a count, not a price):
  assert.equal(sourcePages * config.copies, 36)
})

test('modes, sides and finishes: every supported combination builds and validates', () => {
  let count = 0
  for (const printMode of ['bw', 'colour']) {
    for (const sides of ['single', 'double']) {
      for (const finish of ['none', 'staple', 'clear-sleeve']) {
        const input = { pages: 5, copies: 2, printMode, sides, finish }
        assert.deepEqual(validateA4CounterPrintInput(input), { ok: true, errors: [] })
        const config = buildA4CounterPrintConfig(input)
        assert.deepEqual([config.printMode, config.sides, config.finish], [printMode, sides, finish])
        count += 1
      }
    }
  }
  assert.equal(count, 12)
})

// ── no quantity, no fake file ──────────────────────────────────────────
test('configuration.quantity is impossible: never produced, and a quantity input is rejected', () => {
  for (const input of [{ pages: 1 }, { pages: 12, copies: 3 }, { pages: 1000, copies: 500, printMode: 'colour', sides: 'double', finish: 'staple' }]) {
    const config = buildA4CounterPrintConfig(input)
    assert.ok(!keysDeep(config).has('quantity'), JSON.stringify(input))
    assert.deepEqual(Object.keys(config), FIELDS)
  }
  for (const quantity of [3, 36, '3', null, undefined, 1]) {
    const input = { pages: 12, copies: 3, quantity }
    assert.ok('quantity' in input)
    assert.deepEqual(codesOf(input), ['quantity:unknown_field'])
    assert.throws(() => buildA4CounterPrintConfig(input), CounterPrintInputError)
  }
  assert.doesNotMatch(code, /quantity/i, 'the module code never mentions quantity')

  // Why it matters: the handoff preview reads configuration.quantity as a
  // product quantity override, and configuration.fileName as an expected file.
  const handoff = read('../supabase/migrations/20260913192900_qs_07_1_collection_point_visibility.sql')
  assert.match(handoff, /coalesce\(public\.safe_numeric\(soi\.configuration->>'quantity'\), soi\.quantity, 1\)/)
  assert.match(handoff, /soi\.configuration->>'fileName'/)
})

test('physical / no-file job: no fileName, fileRefs, file record or invented instruction metadata', () => {
  const config = buildA4CounterPrintConfig({ pages: 12, copies: 3 })
  const keys = keysDeep(config)
  for (const forbidden of ['fileName', 'fileRefs', 'file_refs', 'file', 'files', 'key', 'name', 'mimeType', 'source', 'pagesSpec', 'selectedPages', 'serverCalculatedPages', 'clientEstimate', 'serviceType']) {
    assert.ok(!keys.has(forbidden), `${forbidden} must not be produced`)
  }
  assert.deepEqual(Object.keys(config.documentInstructions[0]), ['selection', 'sourcePages'])
  for (const input of [{ pages: 1, fileName: 'x.pdf' }, { pages: 1, fileRefs: [] }, { pages: 1, file: {} }, { pages: 1, source: 'counter' }, { pages: 1, documentInstructions: [] }]) {
    assert.ok(codesOf(input).every((entry) => entry.endsWith(':unknown_field')), JSON.stringify(input))
    assert.ok(codesOf(input).length > 0)
  }
})

// ── validation ─────────────────────────────────────────────────────────
test('boundary values come from the server contract', () => {
  const normalizer = read('../supabase/migrations/20260917184200_qs_13_4_3_document_instruction_pricing_validation.sql')
  const legacy = read('../supabase/migrations/20260913155351_qs_03_quick_solution_foundation.sql')

  const sourcePages = normalizer.match(/v_source_pages < (\d+) or v_source_pages > (\d+)/)
  assert.deepEqual([Number(sourcePages[1]), Number(sourcePages[2])], [A4_COUNTER_PRINT_LIMITS.pagesMin, A4_COUNTER_PRINT_LIMITS.pagesMax])
  const copies = normalizer.match(/if v_copies > (\d+) then/)
  assert.equal(Number(copies[1]), A4_COUNTER_PRINT_LIMITS.copiesMax)
  const legacyLimits = legacy.match(/if v_pages > (\d+) or v_copies > (\d+) then/)
  assert.deepEqual([Number(legacyLimits[1]), Number(legacyLimits[2])], [A4_COUNTER_PRINT_LIMITS.pagesMax, A4_COUNTER_PRINT_LIMITS.copiesMax])
  const documents = normalizer.match(/if v_count < (\d+) or v_count > (\d+) then/)
  assert.deepEqual([Number(documents[1]), Number(documents[2])], [1, 25], 'one document is within 1..25')
  assert.equal(A4_COUNTER_PRINT_LIMITS.copiesMin, 1, 'the server raises copies below 1 to 1')

  assert.equal(buildA4CounterPrintConfig({ pages: 1 }).pages, 1)
  assert.equal(buildA4CounterPrintConfig({ pages: 1000 }).pages, 1000)
  assert.equal(buildA4CounterPrintConfig({ pages: 1, copies: 1 }).copies, 1)
  assert.equal(buildA4CounterPrintConfig({ pages: 1, copies: 500 }).copies, 500)
  assert.deepEqual(codesOf({ pages: 0 }), ['pages:out_of_range'])
  assert.deepEqual(codesOf({ pages: 1001 }), ['pages:out_of_range'])
  assert.deepEqual(codesOf({ pages: 1, copies: 0 }), ['copies:out_of_range'])
  assert.deepEqual(codesOf({ pages: 1, copies: 501 }), ['copies:out_of_range'])
})

test('invalid pages are rejected, never clamped or coerced', () => {
  assert.deepEqual(codesOf({}), ['pages:required'])
  assert.deepEqual(codesOf({ pages: undefined }), ['pages:required'])
  for (const pages of [null, '12', '', 12.5, NaN, Infinity, -Infinity, true, [], {}, [12], 1e3 + 0.5]) {
    assert.deepEqual(codesOf({ pages }), ['pages:not_integer'], String(pages))
  }
  for (const pages of [0, -1, 1001, 100000, -0]) {
    assert.deepEqual(codesOf({ pages }), ['pages:out_of_range'], String(pages))
  }
})

test('invalid copies are rejected, never clamped or coerced', () => {
  for (const copies of [null, '3', 2.5, NaN, Infinity, false, [], {}]) {
    assert.deepEqual(codesOf({ pages: 1, copies }), ['copies:not_integer'], String(copies))
  }
  for (const copies of [0, -1, 501, 1e6]) {
    assert.deepEqual(codesOf({ pages: 1, copies }), ['copies:out_of_range'], String(copies))
  }
})

test('invalid printMode, sides and finish values are rejected exactly', () => {
  for (const field of ['printMode', 'sides', 'finish']) {
    for (const value of ['', 'BW', 'color', 'single ', ' bw', 'grey', 'double-sided', 'staple,none', null, 1, true, [], {}, 'none-'].filter((item) => !A4_COUNTER_PRINT_OPTIONS[field === 'printMode' ? 'printModes' : field === 'finish' ? 'finishes' : 'sides'].includes(item))) {
      assert.deepEqual(codesOf({ pages: 1, [field]: value }), [`${field}:invalid_option`], `${field}=${JSON.stringify(value)}`)
    }
  }
  // An option from a different field is not valid here.
  assert.deepEqual(codesOf({ pages: 1, printMode: 'single' }), ['printMode:invalid_option'])
  assert.deepEqual(codesOf({ pages: 1, sides: 'bw' }), ['sides:invalid_option'])
})

test('non-object input and multiple problems are reported clearly', () => {
  for (const input of [null, undefined, 12, 'pages', [], () => ({ pages: 1 })]) {
    assert.deepEqual(codesOf(input), ['input:invalid_input'], String(input))
  }
  assert.deepEqual(codesOf({ pages: 0, copies: 'x', printMode: 'grey', quantity: 1 }), [
    'pages:out_of_range', 'copies:not_integer', 'printMode:invalid_option', 'quantity:unknown_field'
  ])
  try {
    buildA4CounterPrintConfig({ pages: 0, copies: 501 })
    assert.fail('should have thrown')
  } catch (error) {
    assert.ok(error instanceof CounterPrintInputError)
    assert.equal(error.name, 'CounterPrintInputError')
    assert.deepEqual(error.errors.map((entry) => entry.field), ['pages', 'copies'])
    assert.ok(error.errors.every((entry) => typeof entry.message === 'string' && entry.message.length > 0))
  }
})

// ── defaults and option ids ────────────────────────────────────────────
test('defaults are only the established ones, agreed by the product fields and the server fallbacks', () => {
  assert.deepEqual(A4_COUNTER_PRINT_DEFAULTS, { copies: 1, printMode: 'bw', sides: 'single', finish: 'none' })
  const config = buildA4CounterPrintConfig({ pages: 7 })
  assert.deepEqual([config.copies, config.printMode, config.sides, config.finish], [1, 'bw', 'single', 'none'])

  const field = (id) => a4.fields.find((item) => item.id === id)
  assert.equal(field('copies').default, A4_COUNTER_PRINT_DEFAULTS.copies)
  assert.equal(field('printMode').default, A4_COUNTER_PRINT_DEFAULTS.printMode)
  assert.equal(field('sides').default, A4_COUNTER_PRINT_DEFAULTS.sides)
  assert.equal(field('finish').default, A4_COUNTER_PRINT_DEFAULTS.finish)

  const legacy = read('../supabase/migrations/20260913155351_qs_03_quick_solution_foundation.sql')
  const fallback = (name) => legacy.match(new RegExp(`coalesce\\(nullif\\(p_configuration->>'${name}',''\\), '(\\w+)'\\)`))[1]
  assert.equal(fallback('printMode'), A4_COUNTER_PRINT_DEFAULTS.printMode)
  assert.equal(fallback('sides'), A4_COUNTER_PRINT_DEFAULTS.sides)
  assert.equal(fallback('finish'), A4_COUNTER_PRINT_DEFAULTS.finish)
  assert.match(legacy, /greatest\(coalesce\(\(p_configuration->>'copies'\)::integer, 1\), 1\)/)
})

test('pages has no default: the existing defaults disagree, so it is required', () => {
  const pagesField = a4.fields.find((item) => item.id === 'pages')
  assert.equal(pagesField.default, 0, 'client default is 0')
  assert.equal(pagesField.min, 0)
  const seed = read('../supabase/seed.sql')
  const seeded = seed.match(/select t\.id, p\.id, 'a4-print',\s*'(\{[\s\S]*?\})'::jsonb,/)
  const seededPages = JSON.parse(seeded[1]).fields.find((item) => item.id === 'pages')
  assert.equal(seededPages.default, 1, 'the seeded definition defaults to 1')
  assert.equal(seededPages.min, 1)
  assert.equal('pages' in A4_COUNTER_PRINT_DEFAULTS, false)
  assert.deepEqual(codesOf({ copies: 2 }), ['pages:required'])
})

test('option ids match the a4-print client fields and the seeded pricing definition keys', () => {
  const ids = (fieldId) => a4.fields.find((item) => item.id === fieldId).options.map((option) => option.id).sort()
  assert.deepEqual([...A4_COUNTER_PRINT_OPTIONS.printModes].sort(), ids('printMode'))
  assert.deepEqual([...A4_COUNTER_PRINT_OPTIONS.sides].sort(), ids('sides'))
  assert.deepEqual([...A4_COUNTER_PRINT_OPTIONS.finishes].sort(), ids('finish'))

  const seed = read('../supabase/seed.sql')
  const seeded = seed.match(/select t\.id, p\.id, 'a4-print',\s*'(\{[\s\S]*?\})'::jsonb,\s*'[^']+',\s*'(\{[\s\S]*?\})'::jsonb/)
  const pricing = JSON.parse(seeded[2])
  assert.deepEqual(Object.keys(pricing.rates).sort(), [...A4_COUNTER_PRINT_OPTIONS.printModes].sort())
  assert.deepEqual(Object.keys(pricing.sides).sort(), [...A4_COUNTER_PRINT_OPTIONS.sides].sort())
  assert.deepEqual(Object.keys(pricing.finishes).sort(), [...A4_COUNTER_PRINT_OPTIONS.finishes].sort())
})

// ── acceptance by the server contract, and the documented differences ──
test('the output is accepted by the server normalization rules (evaluated here as a count, not a price)', () => {
  const normalize = (config) => {
    const list = config.documentInstructions
    assert.ok(Array.isArray(list) && list.length >= 1 && list.length <= 25, 'documentInstructions must hold 1..25 documents')
    let total = 0
    for (const item of list) {
      assert.equal(item.selection, 'all')
      assert.ok(Number.isInteger(item.sourcePages) && item.sourcePages >= 1 && item.sourcePages <= 1000)
      total += item.sourcePages
    }
    assert.ok(total <= 1000)
    assert.ok(Number.isInteger(config.copies) && config.copies >= 1 && config.copies <= 500)
    return { pages: total, copies: config.copies, printedPages: total * config.copies }
  }
  assert.deepEqual(normalize(buildA4CounterPrintConfig({ pages: 12, copies: 3 })), { pages: 12, copies: 3, printedPages: 36 })
  assert.deepEqual(normalize(buildA4CounterPrintConfig({ pages: 1000, copies: 500 })), { pages: 1000, copies: 500, printedPages: 500000 })
  // The stored config's pages already equals the server-derived total.
  const config = buildA4CounterPrintConfig({ pages: 40, copies: 2 })
  assert.equal(config.pages, normalize(config).pages)
})

test('known frontend/server differences are documented, not compensated for', () => {
  // The copies field has no maximum on the client; the server caps it at 500.
  assert.equal(a4.fields.find((item) => item.id === 'copies').max, undefined)
  // The client price mirror clamps copies to >= 1 and accepts decimals; the
  // server casts to integer. This adapter rejects both instead of choosing.
  const mirror = read('../src/lib/pricing.js')
  assert.match(mirror, /Math\.max\(Number\(config\.copies \|\| 1\), 1\)/)
  assert.deepEqual(codesOf({ pages: 1, copies: 2.5 }), ['copies:not_integer'])
  assert.deepEqual(codesOf({ pages: 1, copies: 0 }), ['copies:out_of_range'])
  // The storefront's own page-count validation matches the server range.
  const plan = read('../src/components/DocumentPrintPlan.jsx')
  assert.match(plan, /Number\.isInteger\(count\) && count > 0 && count <= 1000/)
})

// ── immutability and purity ────────────────────────────────────────────
test('the input is never mutated and the output shares no mutable state', () => {
  const input = Object.freeze({ pages: 12, copies: 3, printMode: 'colour', sides: 'double', finish: 'staple' })
  const before = JSON.stringify(input)
  const first = buildA4CounterPrintConfig(input)
  assert.equal(JSON.stringify(input), before)

  const second = buildA4CounterPrintConfig(input)
  assert.notEqual(first, second)
  assert.notEqual(first.documentInstructions, second.documentInstructions)
  assert.notEqual(first.documentInstructions[0], second.documentInstructions[0])
  first.documentInstructions[0].sourcePages = 999
  first.documentInstructions.push({ selection: 'all', sourcePages: 1 })
  first.pages = 1
  assert.equal(second.documentInstructions[0].sourcePages, 12)
  assert.equal(second.documentInstructions.length, 1)
  assert.equal(input.pages, 12)

  // Validation of a frozen or mutated input never throws or writes.
  assert.doesNotThrow(() => validateA4CounterPrintInput(Object.freeze({ pages: 0, extra: 1 })))
  const defaults = Object.isFrozen(A4_COUNTER_PRINT_DEFAULTS) && Object.isFrozen(A4_COUNTER_PRINT_LIMITS) && Object.isFrozen(A4_COUNTER_PRINT_OPTIONS.finishes)
  assert.ok(defaults, 'exported constants are frozen')
  const config = buildA4CounterPrintConfig({ pages: 1 })
  config.copies = 99
  assert.equal(buildA4CounterPrintConfig({ pages: 1 }).copies, 1, 'defaults are not shared')
})

test('the module is pure and has no pricing, cost, margin, supplier, network, React or Supabase dependency', () => {
  assert.doesNotMatch(code, /^\s*import\s/m)
  assert.doesNotMatch(code, /\b(fetch|window|document|localStorage|process|require|supabase|rpc|React|useState|await|async|Promise)\b/)
  assert.doesNotMatch(code, /price|pricing|rate|multiplier|fee|cost|margin|supplier|reference|total|zar|money|formatMoney|calculate/i)
  assert.doesNotMatch(code, /pricing_definition|pricingDefinition|marginRate|sourceUrl/)
  assert.doesNotMatch(code, /counterCatalogue|productContent|navigation/)
})

test('counterCatalogue stays pure and is untouched by this module', () => {
  const catalogue = read('../src/lib/counterCatalogue.js').replace(/\/\/[^\n]*/g, '')
  assert.doesNotMatch(catalogue, /^\s*import\s/m)
  assert.doesNotMatch(catalogue, /counterPrintConfig|supabase|fetch/i)
  assert.doesNotMatch(code, /^\s*import\s/m)
})

test('since 01N only the Counter draft logic imports the adapter (the screen itself never rebuilds the shape)', () => {
  const importers = []
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const path = new URL(`${entry.name}${entry.isDirectory() ? '/' : ''}`, dir)
      if (entry.isDirectory()) walk(path)
      else if (/\.(jsx?|mjs|cjs)$/.test(entry.name) && /counterPrintConfig/.test(fs.readFileSync(path, 'utf8'))) importers.push(entry.name)
    }
  }
  walk(new URL('../src/', import.meta.url))
  assert.deepEqual(importers, ['counterDraft.js'])
})

test('the new test file is part of npm test', () => {
  const packageJson = JSON.parse(read('../package.json'))
  assert.match(packageJson.scripts.test, /tests\/counter-print-config\.test\.mjs/)
})
