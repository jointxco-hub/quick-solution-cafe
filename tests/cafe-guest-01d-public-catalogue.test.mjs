import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'

// CAFE-GUEST-01D - static contract for the server-side storefront filter in
// the PUBLIC catalogue RPC. Behavioral execution of
// supabase/tests/cafe_guest_01d_public_catalogue_storefront_filter.sql is done
// by the local SQL harness (npm run test:sql). These tests read the
// migration chain as text. The inline predicate is proven identical to the
// CAFE-GUEST-01C helper's storefront rule by comparing their text and by
// evaluating both against the same truth table.

const migrationsDir = new URL('../supabase/migrations/', import.meta.url)
const NEW = '20260926120000_cafe_guest_01d_public_catalogue_storefront_filter.sql'
const PREVIOUS = '20260913190841_qs_07_customer_fulfilment_choices.sql'
const ORIGINAL = '20260913155351_qs_03_quick_solution_foundation.sql'
const GUARD = '20260926110000_cafe_guest_01c_channel_availability_guard.sql'

const migrationFiles = fs.readdirSync(migrationsDir).filter((name) => name.endsWith('.sql')).sort()
const stripComments = (sql) => sql.replace(/--[^\n]*/g, '')
const stripLiterals = (sql) => sql.replace(/'(?:[^']|'')*'/g, "''")
const squash = (sql) => sql.replace(/\s+/g, ' ').trim()
const migrations = migrationFiles.map((name) => {
  const raw = fs.readFileSync(new URL(name, migrationsDir), 'utf8')
  const code = stripComments(raw)
  return { name, raw, code, bare: stripLiterals(code) }
})
const byName = (name) => migrations.find((migration) => migration.name === name)
const next = byName(NEW)
const previous = byName(PREVIOUS)
const guard = byName(GUARD)
const packageJson = JSON.parse(fs.readFileSync(new URL('../package.json', import.meta.url), 'utf8'))
const DML = /\binsert\s+into\b|\bupdate\s+[\w."]+\s+(?:\w+\s+)?set\b|\bdelete\s+from\b/i

const catalogueBlock = (sql) => {
  const match = sql.match(/create\s+or\s+replace\s+function\s+public\.get_quick_solution_catalog\([\s\S]*?\n\$\$;/i)
  assert.ok(match, 'catalogue definition not found')
  return match[0]
}
const aclStatements = (sql) => [...sql.matchAll(/\b(revoke|grant)\b[^;]*get_quick_solution_catalog[^;]*;/gi)].map((match) => squash(match[0]))

// The storefront rule, exactly as written in the catalogue's WHERE clause.
const PREDICATE = squash(`and case coalesce(jsonb_typeof(c.customer_definition -> 'channels' -> 'storefront'), 'null')
  when 'null' then true
  when 'boolean' then (c.customer_definition -> 'channels' ->> 'storefront')::boolean
  else false
end`)

function parseCase(sql) {
  const arms = new Map()
  for (const arm of sql.matchAll(/when\s+'(\w+)'\s+then\s+(true|false|\([^()]*\)::boolean)/g)) arms.set(arm[1], arm[2])
  const otherwise = sql.match(/else\s+(true|false)/)
  assert.ok(otherwise)
  return { arms, otherwise: otherwise[1] === 'true' }
}

function evaluateCase(parsed, value) {
  const type = value === undefined || value === null ? 'null' : typeof value === 'boolean' ? 'boolean' : 'other'
  const arm = parsed.arms.get(type)
  if (arm === undefined) return parsed.otherwise
  if (arm === 'true') return true
  if (arm === 'false') return false
  return Boolean(value)
}

const helperStorefrontCase = () => {
  const helper = guard.code.match(/when\s+'storefront'\s+then([\s\S]*?)when\s+'counter'\s+then/)
  assert.ok(helper, 'CAFE-GUEST-01C helper storefront branch not found')
  return squash(helper[1])
}
const cataloguePredicate = () => {
  const block = squash(catalogueBlock(next.code))
  const start = block.indexOf('and case coalesce(jsonb_typeof(')
  assert.ok(start >= 0, 'storefront predicate not found in the catalogue')
  const end = block.indexOf(" end ", start) + " end".length
  return block.slice(start, end)
}

test('the migration replaces the latest public catalogue definition, and only that function', () => {
  assert.ok(next, `${NEW} must exist`)
  assert.ok(migrationFiles.indexOf(NEW) > migrationFiles.indexOf(GUARD), 'sorts after CAFE-GUEST-01C')

  const definers = migrations
    .filter((migration) => /create\s+or\s+replace\s+function\s+public\.get_quick_solution_catalog\(/i.test(migration.code))
    .map((migration) => migration.name)
  assert.deepEqual(definers, [ORIGINAL, PREVIOUS, NEW], 'full history of the public catalogue RPC')

  const created = [...next.bare.matchAll(/create\s+or\s+replace\s+function\s+([\w.]+)/gi)].map((match) => match[1])
  assert.deepEqual(created, ['public.get_quick_solution_catalog'])
  assert.match(next.code, /to_regprocedure\('public\.get_quick_solution_catalog\(text\)'\)/, 'preflight requires the existing function')
})

test('signature, SECURITY DEFINER, search_path and EXECUTE grants are preserved exactly', () => {
  const headOf = (sql) => squash(catalogueBlock(sql).split(/\bas\s+\$\$/i)[0])
  assert.equal(headOf(next.code), headOf(previous.code))
  assert.match(headOf(next.code), /\(\s*p_tenant_slug text default 'quick-solution'\s*\) returns jsonb language plpgsql security definer set search_path = ''/i)

  assert.deepEqual(aclStatements(next.code), aclStatements(previous.code))
  assert.deepEqual(aclStatements(next.code), [
    'revoke all on function public.get_quick_solution_catalog(text) from public;',
    'grant execute on function public.get_quick_solution_catalog(text) to anon, authenticated;'
  ])
  assert.doesNotMatch(next.bare, /revoke[^;]*\banon\b/i, 'anon access to the public catalogue must not be revoked')
  assert.doesNotMatch(next.bare, /\balter\s+function\b|\bowner\s+to\b/i)
})

test('FILTERING ONLY: removing the storefront predicate leaves exactly the previous definition', () => {
  const before = squash(catalogueBlock(previous.code))
  const after = squash(catalogueBlock(next.code))
  assert.equal(after.split(PREDICATE).length - 1, 1, 'the predicate appears exactly once')
  assert.equal(after.replace(PREDICATE, '').replace(/\s+/g, ' '), before.replace(/\s+/g, ' '))
})

test('the predicate sits in the products query only, after the published/available filters', () => {
  const block = squash(catalogueBlock(next.code))
  const products = block.slice(block.indexOf("'products'"), block.indexOf("'fulfilmentPoints'"))
  assert.ok(products.includes(PREDICATE))
  assert.ok(products.indexOf("p.availability = 'available'") < products.indexOf(PREDICATE))
  const rest = block.slice(block.indexOf("'fulfilmentPoints'"))
  assert.ok(!rest.includes('storefront'), 'fulfilment points are not filtered by a product channel')
})

test('response shape is unchanged and pricing_definition is still never returned', () => {
  const projection = (sql) => squash(catalogueBlock(sql).match(/select jsonb_agg\(([\s\S]*?)order by c\.sort_order, p\.name/i)[1])
  assert.equal(projection(next.code), projection(previous.code))
  for (const key of ['id', 'commerceProductId', 'name', 'description', 'pricingVersion']) {
    assert.match(projection(next.code), new RegExp(`'${key}'`), key)
  }
  assert.match(projection(next.code), /c\.customer_definition \|\|/)

  const body = catalogueBlock(next.code)
  assert.doesNotMatch(stripLiterals(body), /pricing_definition/i)
  assert.doesNotMatch(body, /supplier|referencePrice|marginRate|margin|source_url|sourceUrl/i)
  assert.doesNotMatch(body, /admin/i)
})

test('storefront truth table: true/missing/null included; false/non-boolean excluded', () => {
  const parsed = parseCase(cataloguePredicate())
  const cases = [
    [undefined, true, 'missing storefront key'],
    [null, true, 'explicit null'],
    [true, true, 'explicit true'],
    [false, false, 'explicit false'],
    ['false', false, 'string "false"'],
    ['true', false, 'string "true" is not a boolean'],
    [0, false, 'number 0'],
    [1, false, 'number 1'],
    [{}, false, 'object'],
    [[], false, 'array']
  ]
  for (const [value, expected, description] of cases) {
    assert.equal(evaluateCase(parsed, value), expected, description)
  }
  // A product with no channels object at all reads as a missing storefront key.
  assert.match(cataloguePredicate(), /coalesce\(jsonb_typeof\(c\.customer_definition -> 'channels' -> 'storefront'\), 'null'\)/)
})

test('one contract: the inline predicate is textually and behaviourally identical to the CAFE-GUEST-01C helper', () => {
  const helperCase = helperStorefrontCase()
  const inline = cataloguePredicate().replace(/^and /, '')
  assert.equal(inline, helperCase, 'the two storefront expressions must be identical text')

  const helper = parseCase(helperCase)
  const predicate = parseCase(inline)
  for (const value of [undefined, null, true, false, 'false', 'true', 0, 1, {}, []]) {
    assert.equal(evaluateCase(predicate, value), evaluateCase(helper, value), String(JSON.stringify(value)))
  }
})

test('helper reuse would add avoidable per-row lookups, so the helper is not called or exposed', () => {
  assert.doesNotMatch(catalogueBlock(next.code), /_qs_product_channel_enabled/)
  assert.doesNotMatch(next.bare, /\bgrant\b[^;]*_qs_/i)
  assert.doesNotMatch(next.bare, /commerce\.\w*\s*\(/, 'no commerce function is called from the public catalogue')
})

test('pos does not participate, and no counter catalogue, RPC or auth work is included', () => {
  assert.doesNotMatch(next.code, /'pos'|"pos"|\bpos\b/i, 'channels.pos is not read')
  assert.doesNotMatch(next.bare, /counter|has_tenant_capability|is_app_admin|is_opps_staff|can_access_tenant|auth\.uid|auth\.role|session_user/i)
  assert.doesNotMatch(next.bare, /fulfilment_?mode|handoff|payment/i)
  const created = [...next.bare.matchAll(/create\s+or\s+replace\s+function\s+([\w.]+)/gi)].map((match) => match[1])
  assert.deepEqual(created, ['public.get_quick_solution_catalog'], 'no counter catalogue or counter RPC')
})

test('no product data, schema object, trigger or other function is changed', () => {
  assert.doesNotMatch(next.bare, DML)
  assert.doesNotMatch(next.bare, /\balter\s+table\b|\bcreate\s+(table|index|trigger|policy|type|domain|view|schema)\b|\bdrop\s+/i)
})

test('React is not the only enforcement: the server predicate exists and the item guard remains the order boundary', () => {
  assert.ok(next.code.includes("'storefront'"), 'the server reads channels.storefront')
  assert.match(guard.code, /create\s+trigger\s+trg_qs_guard_service_order_item_channel/i)
  assert.match(guard.code, /PRODUCT_NOT_AVAILABLE_FOR_CHANNEL/)
  // The client filter stays as harmless presentation; enforcement no longer depends on it.
  const client = fs.readFileSync(new URL('../src/App.jsx', import.meta.url), 'utf8')
  assert.match(client, /product\.channels\?\.storefront\s*!==\s*false/)
})

function channelBlocks() {
  const blocks = []
  const files = [
    ...migrations.map((migration) => ({ name: migration.name, text: migration.code })),
    { name: 'seed.sql', text: fs.readFileSync(new URL('../supabase/seed.sql', import.meta.url), 'utf8') }
  ]
  for (const file of files) {
    for (const match of file.text.matchAll(/"channels"\s*:\s*\{[^}]*\}/g)) blocks.push({ file: file.name, text: match[0], value: JSON.parse(match[0].replace(/^"channels"\s*:\s*/, '')) })
    for (const match of file.text.matchAll(/'channels'\s*,\s*jsonb_build_object\(([^)]*)\)/g)) {
      const value = {}
      for (const pair of match[1].matchAll(/'(\w+)'\s*,\s*(true|false)/g)) value[pair[1]] = pair[2] === 'true'
      blocks.push({ file: file.name, text: match[0], value })
    }
  }
  return blocks
}

test('legacy behaviour is preserved: every product defined in the repository is still returned, except the deliberate counter-only Scan and Lamination (CAFE-GUEST-01H, 01I, 01J)', () => {
  // 01I is the historical generic placeholder (retired by 01J); 01J defines A4 and A3 Lamination (two blocks).
  const COUNTER_ONLY = ['20260926150000_cafe_guest_01h_scan_product.sql', '20260926160000_cafe_guest_01i_lamination_product.sql', '20260926170000_cafe_guest_01j_lamination_a4_a3.sql']
  const parsed = parseCase(cataloguePredicate())
  const blocks = channelBlocks()
  assert.ok(blocks.length >= 9, `expected the known channel blocks, found ${blocks.length}`)
  const hidden = blocks.filter((block) => COUNTER_ONLY.includes(block.file))
  assert.deepEqual(hidden.map((block) => block.file), [COUNTER_ONLY[0], COUNTER_ONLY[1], COUNTER_ONLY[2], COUNTER_ONLY[2]], 'exactly these definitions are hidden from the storefront: Scan, the retired placeholder, A4 and A3 Lamination')
  for (const block of hidden) assert.equal(evaluateCase(parsed, block.value.storefront), false, `${block.file} is not returned by the public catalogue`)
  for (const block of blocks.filter((item) => !COUNTER_ONLY.includes(item.file))) {
    assert.equal(evaluateCase(parsed, block.value.storefront), true, `${block.file} would be hidden: ${block.text}`)
  }
})

test('callers: the public RPC has one storefront caller; /admin uses its own RPC and is not coupled', () => {
  const sourceFiles = []
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const path = new URL(`${entry.name}${entry.isDirectory() ? '/' : ''}`, dir)
      if (entry.isDirectory()) walk(path)
      else if (/\.(jsx?|mjs|cjs|ts|tsx)$/.test(entry.name)) sourceFiles.push({ name: entry.name, text: fs.readFileSync(path, 'utf8') })
    }
  }
  walk(new URL('../src/', import.meta.url))

  const rpcCallers = sourceFiles.filter((file) => /['"]get_quick_solution_catalog['"]/.test(file.text)).map((file) => file.name)
  assert.deepEqual(rpcCallers, ['supabaseApi.js'])
  const functionCallers = sourceFiles.filter((file) => /\bloadQuickSolutionCatalog\b/.test(file.text)).map((file) => file.name).sort()
  assert.deepEqual(functionCallers, ['App.jsx', 'supabaseApi.js'])

  const admin = sourceFiles.find((file) => file.name === 'AdminProductManager.jsx')
  assert.match(admin.text, /loadQuickSolutionAdminCatalog/)
  assert.doesNotMatch(admin.text, /\bloadQuickSolutionCatalog\b/)
  const api = sourceFiles.find((file) => file.name === 'supabaseApi.js')
  assert.match(api.text, /rpc\('admin_get_quick_solution_catalog'/)
})

test('SQL contract test is rollback-contained, never commits, and covers the storefront truth table and shape', () => {
  const sql = fs.readFileSync(new URL('../supabase/tests/cafe_guest_01d_public_catalogue_storefront_filter.sql', import.meta.url), 'utf8')
  const code = stripComments(sql)
  assert.match(code, /^\s*\\set ON_ERROR_STOP on\s*\n\s*begin;/m)
  assert.match(code, /\brollback;\s*\n\s*select 'CAFE-GUEST-01D/)
  assert.doesNotMatch(code, /^\s*commit\s*;/im)
  for (const required of [
    /'sf-true'/, /'sf-missing'/, /'no-channels'/, /'sf-null'/, /'sf-false'/,
    /'sf-string-false'/, /'sf-string-true'/, /'sf-number'/, /'sf-object'/, /'sf-array'/,
    /'pos-only'/, /'pos-false'/, /'pos-missing'/,
    /'draft-product'/, /'unavailable-product'/, /'draft-config'/, /other-tenant-product/,
    /must list exactly the storefront-enabled published products/,
    /channels\.pos must not affect the public catalogue/,
    /cg01d-secret-marker/,
    /has_function_privilege\('anon'/,
    /catalogue ordering changed/
  ]) {
    assert.match(code, required)
  }
})

test('the new test file is part of npm test', () => {
  assert.match(packageJson.scripts.test, /tests\/cafe-guest-01d-public-catalogue\.test\.mjs/)
})
