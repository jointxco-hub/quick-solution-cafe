import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'

// CAFE-GUEST-01C - static contract for the server-side sales-channel
// availability guard. Behavioral execution of
// supabase/tests/cafe_guest_01c_channel_availability_guard.sql is done by the
// local SQL harness (npm run test:sql); these tests read the migration
// chain as text only. The helper's decision table is additionally evaluated
// by parsing its CASE arms out of the SQL, so the semantics are checked
// against the real text rather than a keyword.

const migrationsDir = new URL('../supabase/migrations/', import.meta.url)
const GUARD = '20260926110000_cafe_guest_01c_channel_availability_guard.sql'
const FOUNDATION = '20260926100000_cafe_guest_01a_counter_channel_foundation.sql'

const migrationFiles = fs.readdirSync(migrationsDir).filter((name) => name.endsWith('.sql')).sort()
const stripComments = (sql) => sql.replace(/--[^\n]*/g, '')
const stripLiterals = (sql) => sql.replace(/'(?:[^']|'')*'/g, "''")
const migrations = migrationFiles.map((name) => {
  const raw = fs.readFileSync(new URL(name, migrationsDir), 'utf8')
  const code = stripComments(raw)
  return { name, raw, code, bare: stripLiterals(code) }
})
const byName = (name) => migrations.find((migration) => migration.name === name)
const guard = byName(GUARD)
const normalizedHeader = guard?.raw.replace(/^--\s?/gm, '').replace(/\s+/g, ' ') ?? ''
const packageJson = JSON.parse(fs.readFileSync(new URL('../package.json', import.meta.url), 'utf8'))
// A real data-changing statement (not the INSERT/UPDATE events of a trigger definition).
const DML = /\binsert\s+into\b|\bupdate\s+[\w."]+\s+(?:\w+\s+)?set\b|\bdelete\s+from\b/i

function sectionOf(sql, functionName) {
  const start = sql.search(new RegExp(`create\\s+or\\s+replace\\s+function\\s+${functionName.replace('.', '\\.')}\\s*\\(`, 'i'))
  assert.ok(start >= 0, `${functionName} definition not found`)
  const rest = sql.slice(start + 1)
  const next = rest.search(/create\s+or\s+replace\s+function|\bdrop\s+trigger\b|\bcreate\s+trigger\b/i)
  return next === -1 ? rest : rest.slice(0, next)
}

function latestFunctionBody(functionName) {
  const pattern = new RegExp(`create\\s+or\\s+replace\\s+function\\s+public\\.${functionName}\\s*\\(`, 'gi')
  let latest = null
  for (const migration of migrations) {
    for (const match of migration.code.matchAll(pattern)) latest = { migration, index: match.index }
  }
  assert.ok(latest, `no definition of public.${functionName} found`)
  const rest = latest.migration.code.slice(latest.index + 1)
  const next = rest.search(/create\s+or\s+replace\s+function/i)
  return { file: latest.migration.name, body: next === -1 ? rest : rest.slice(0, next) }
}

// ── helper semantics, evaluated from the SQL text ─────────────────────
const helperSql = guard ? sectionOf(guard.code, 'commerce._qs_product_channel_enabled') : ''

function parseBranch(sql) {
  const key = sql.match(/jsonb_typeof\(\s*c\.customer_definition\s*->\s*'channels'\s*->\s*'([a-z]+)'\s*\)/)
  assert.ok(key, 'branch must read customer_definition.channels.<key> through jsonb_typeof')
  assert.match(sql, /coalesce\(\s*jsonb_typeof\([^)]*\)\s*,\s*'null'\s*\)/, 'a missing key must be read as the json type null')
  const arms = new Map()
  for (const arm of sql.matchAll(/when\s+'(\w+)'\s+then\s+(true|false|\([^()]*\)::boolean)/g)) arms.set(arm[1], arm[2])
  const otherwise = sql.match(/else\s+(true|false)/)
  assert.ok(otherwise, 'branch must have an ELSE arm')
  return { key: key[1], arms, otherwise: otherwise[1] === 'true' }
}

function evaluateBranch(branch, value) {
  const type = value === undefined || value === null ? 'null' : typeof value === 'boolean' ? 'boolean' : 'other'
  const arm = branch.arms.get(type)
  if (arm === undefined) return branch.otherwise
  if (arm === 'true') return true
  if (arm === 'false') return false
  return Boolean(value)
}

function evaluateHelper(channel, channels, { configExists = true } = {}) {
  if (!configExists) return false
  const storefront = parseBranch(helperSql.match(/when\s+'storefront'\s+then([\s\S]*?)when\s+'counter'\s+then/)[1])
  const counter = parseBranch(helperSql.match(/when\s+'counter'\s+then([\s\S]*?)\bfrom\s+commerce\.service_product_configs/)[1])
  if (channel === 'storefront') return evaluateBranch(storefront, channels?.[storefront.key])
  if (channel === 'counter') return evaluateBranch(counter, channels?.[counter.key])
  return false
}

test('the guard migration exists, sorts after CAFE-GUEST-01A, and is additive', () => {
  assert.ok(guard, `${GUARD} must exist`)
  assert.ok(migrationFiles.indexOf(GUARD) > migrationFiles.indexOf(FOUNDATION))
  assert.doesNotMatch(guard.bare, /create\s+or\s+replace\s+function\s+public\./i, 'no public RPC is created or replaced')
  assert.doesNotMatch(guard.bare, /\balter\s+table\b/i)
  assert.doesNotMatch(guard.bare, DML, 'no data or product change')
  assert.doesNotMatch(guard.bare, /\bcreate\s+(table|policy|index|type|domain|schema|view)\b/i)
  assert.doesNotMatch(guard.bare, /\bgrant\b/i)
  assert.match(guard.code, /commerce\.service_orders\.channel|attname\s*=\s*'channel'/i, 'preflight requires the CAFE-GUEST-01A channel column')
})

test('helper: signature, purity and privileges', () => {
  assert.match(helperSql, /commerce\._qs_product_channel_enabled\(\s*p_tenant_id\s+uuid,\s*p_product_key\s+text,\s*p_channel\s+text\s*\)\s*returns\s+boolean/i)
  assert.match(helperSql, /language\s+sql\s+stable\s+security\s+definer\s+set\s+search_path\s*=\s*''/i)
  assert.match(helperSql, /c\.tenant_id\s*=\s*p_tenant_id/i)
  assert.match(helperSql, /c\.source_key\s*=\s*trim\(p_product_key\)/i)
  assert.match(helperSql, /from\s+commerce\.service_product_configs\s+c/i)
})

test('helper: decision table (storefront missing/true/false, counter missing/true/false, unknown channel)', () => {
  const cases = [
    // [channel, channels object, expected, description]
    ['storefront', undefined, true, 'storefront, no channels object'],
    ['storefront', {}, true, 'storefront, channels.storefront missing'],
    ['storefront', { storefront: null }, true, 'storefront, explicit null'],
    ['storefront', { storefront: true }, true, 'storefront, true'],
    ['storefront', { storefront: false }, false, 'storefront, false'],
    ['storefront', { storefront: 'false' }, false, 'storefront, non-boolean fails closed'],
    ['storefront', { storefront: 1 }, false, 'storefront, number fails closed'],
    ['storefront', { pos: false }, true, 'storefront ignores pos'],
    ['counter', undefined, false, 'counter, no channels object'],
    ['counter', {}, false, 'counter, channels.pos missing'],
    ['counter', { pos: null }, false, 'counter, explicit null'],
    ['counter', { pos: true }, true, 'counter, true'],
    ['counter', { pos: false }, false, 'counter, false'],
    ['counter', { pos: 'true' }, false, 'counter, non-boolean fails closed'],
    ['counter', { storefront: true }, false, 'counter ignores storefront'],
    ['counter', { storefront: false, pos: true }, true, 'counter-only product'],
    ['kiosk', { storefront: true, pos: true }, false, 'unknown channel'],
    ['guided', { storefront: true, guided: true, pos: true }, false, 'guided is not a sales channel'],
    ['quote', { storefront: true, quote: true, pos: true }, false, 'quote is not a sales channel'],
    [null, { storefront: true, pos: true }, false, 'NULL channel'],
    ['storefront', { storefront: true }, false, 'missing product config', { configExists: false }]
  ]
  for (const [channel, channels, expected, description, options] of cases) {
    assert.equal(evaluateHelper(channel, channels, options), expected, description)
  }
})

test('helper: unknown channel and missing config are denied in the SQL itself, and only availability metadata is read', () => {
  assert.match(helperSql, /else\s+false\s+end\s+from\s+commerce\.service_product_configs/i, 'unknown channel -> false')
  assert.match(helperSql, /\)\s*,\s*false\s*\)/, 'no config row / NULL argument -> coalesce to false')
  assert.doesNotMatch(helperSql, /pricing_definition|supplier|margin|referencePrice|cost/i)
  assert.doesNotMatch(helperSql, /'(guided|quote|advanced)'/i, 'guided/quote/advanced are not sales channels')
  assert.doesNotMatch(helperSql, /source_metadata/i)
})

test('item guard reads the canonical service_orders.channel, never source_metadata', () => {
  const itemGuard = sectionOf(guard.code, 'commerce.qs_guard_service_order_item_channel')
  assert.match(itemGuard, /select\s+so\.tenant_id\s*,\s*so\.channel[\s\S]*from\s+commerce\.service_orders\s+so[\s\S]*where\s+so\.id\s*=\s*new\.order_id/i)
  assert.match(itemGuard, /commerce\._qs_product_channel_enabled\(\s*new\.tenant_id\s*,\s*new\.product_key\s*,\s*v_order_channel\s*\)/i)
  assert.doesNotMatch(guard.bare, /source_metadata/i)
  assert.doesNotMatch(guard.bare, /pricing_definition/i)
  assert.match(itemGuard, /security\s+definer[\s\S]*set\s+search_path\s*=\s*''/i)
  // Unrelated UPDATEs skip the availability lookup entirely.
  assert.match(itemGuard, /tg_op\s*=\s*'UPDATE'[\s\S]*new\.order_id\s+is\s+not\s+distinct\s+from\s+old\.order_id[\s\S]*new\.tenant_id\s+is\s+not\s+distinct\s+from\s+old\.tenant_id[\s\S]*new\.product_key\s+is\s+not\s+distinct\s+from\s+old\.product_key[\s\S]*return\s+new/i)
})

test('trigger definitions: item guard covers INSERT and the three relationship columns; origin guard is UPDATE-only', () => {
  assert.match(
    guard.code,
    /create\s+trigger\s+trg_qs_guard_service_order_item_channel\s+before\s+insert\s+or\s+update\s+of\s+order_id\s*,\s*tenant_id\s*,\s*product_key\s+on\s+commerce\.service_order_items\s+for\s+each\s+row\s+execute\s+function\s+commerce\.qs_guard_service_order_item_channel\(\)/i
  )
  assert.match(
    guard.code,
    /create\s+trigger\s+trg_qs_guard_service_order_origin\s+before\s+update\s+of\s+channel\s*,\s*tenant_id\s+on\s+commerce\.service_orders\s+for\s+each\s+row\s+execute\s+function\s+commerce\.qs_guard_service_order_origin\(\)/i
  )
  assert.match(guard.code, /drop\s+trigger\s+if\s+exists\s+trg_qs_guard_service_order_item_channel/i, 'idempotent re-run')
  assert.match(guard.code, /drop\s+trigger\s+if\s+exists\s+trg_qs_guard_service_order_origin/i, 'idempotent re-run')
})

// ── mutation audit: what the repository actually writes ───────────────
function splitTopLevel(text) {
  const parts = []
  let depth = 0
  let quote = false
  let current = ''
  for (let index = 0; index < text.length; index += 1) {
    const char = text[index]
    if (char === "'") quote = !quote
    if (!quote) {
      if (char === '(') depth += 1
      if (char === ')') depth -= 1
      if (char === ',' && depth === 0) {
        parts.push(current)
        current = ''
        continue
      }
    }
    current += char
  }
  parts.push(current)
  return parts
}

function assignedColumns() {
  const byTable = { service_orders: new Set(), service_order_items: new Set() }
  const counts = { service_orders: 0, service_order_items: 0 }
  for (const migration of migrations) {
    for (const match of migration.code.matchAll(/update\s+commerce\.(service_orders|service_order_items)\b(?:\s+\w+)?\s+set\s+([\s\S]*?)\bwhere\b/gi)) {
      counts[match[1]] += 1
      for (const assignment of splitTopLevel(match[2])) {
        const column = assignment.match(/^\s*(?:\w+\.)?(\w+)\s*=/)
        assert.ok(column, `${migration.name}: could not parse assignment "${assignment.trim().slice(0, 60)}"`)
        byTable[match[1]].add(column[1].toLowerCase())
      }
    }
  }
  return { byTable, counts }
}

test('mutation audit: existing functions never assign channel, tenant, order or product on service orders/items', () => {
  const { byTable, counts } = assignedColumns()
  assert.ok(counts.service_orders >= 10, `expected the known service_orders UPDATE sites, found ${counts.service_orders}`)
  assert.ok(counts.service_order_items >= 1)

  const allowedOrderColumns = new Set([
    'upload_token_hash', 'upload_token_expires_at', 'payment_token_hash', 'payment_token_expires_at',
    'opps_order_id', 'status', 'source_metadata', 'payment_status', 'updated_at'
  ])
  for (const column of byTable.service_orders) {
    assert.ok(allowedOrderColumns.has(column), `service_orders UPDATE assigns unexpected column ${column}`)
  }
  assert.ok(!byTable.service_orders.has('channel') && !byTable.service_orders.has('tenant_id'))

  assert.deepEqual([...byTable.service_order_items], ['file_refs'], 'the only item UPDATE appends file_refs')
})

test('mutation audit: no DELETE, upsert or broad row assignment touches service orders/items', () => {
  for (const migration of migrations) {
    assert.doesNotMatch(migration.code, /delete\s+from\s+commerce\.service_order(s|_items)\b/i, migration.name)
    assert.doesNotMatch(migration.code, /truncate[^;]*commerce\.service_order(?!_cancellations\b)/i, migration.name)
    assert.doesNotMatch(
      migration.code,
      /insert\s+into\s+commerce\.service_order(s|_items)\b[^;]*on\s+conflict/i,
      `${migration.name}: an upsert could change channel or tenant`
    )
  }
})

test('tenant integrity is not structural: the schema has no composite (order, tenant) key, so the guard checks it', () => {
  const foundation = byName('20260913155351_qs_03_quick_solution_foundation.sql')
  assert.match(foundation.code, /order_id\s+uuid\s+not\s+null\s+references\s+commerce\.service_orders\(id\)\s+on\s+delete\s+cascade/i)
  assert.match(foundation.code, /tenant_id\s+uuid\s+not\s+null\s+references\s+public\.tenants\(id\)\s+on\s+delete\s+restrict,\s*\n\s*product_id/i)
  for (const migration of migrations) {
    assert.doesNotMatch(migration.code, /foreign\s+key\s*\(\s*order_id\s*,\s*tenant_id\s*\)/i, migration.name)
    assert.doesNotMatch(migration.code, /unique\s*\(\s*id\s*,\s*tenant_id\s*\)/i, migration.name)
  }
  const itemGuard = sectionOf(guard.code, 'commerce.qs_guard_service_order_item_channel')
  assert.match(itemGuard, /v_order_tenant\s+is\s+distinct\s+from\s+new\.tenant_id/i)
  assert.match(itemGuard, /new\.tenant_id\s*,\s*new\.product_key/i, 'availability is resolved from the item tenant, which was just proven equal to the order tenant')
})

test('origin guard: channel and tenant are immutable, and it reads no table', () => {
  const originGuard = sectionOf(guard.code, 'commerce.qs_guard_service_order_origin')
  assert.match(originGuard, /new\.channel\s+is\s+distinct\s+from\s+old\.channel/i)
  assert.match(originGuard, /new\.tenant_id\s+is\s+distinct\s+from\s+old\.tenant_id/i)
  const originBody = originGuard.match(/as\s+\$\$([\s\S]*?)\$\$/)[1]
  assert.doesNotMatch(originBody, /(?<!distinct\s)\b(from|join)\b/i, 'no table is read (IS DISTINCT FROM is an operator, not a FROM clause)')
  assert.doesNotMatch(originBody, /\bcommerce\.|\bpublic\./i, 'no table or function outside the row is referenced')
  assert.doesNotMatch(originGuard, /security\s+definer/i)
  assert.match(originGuard, /set\s+search_path\s*=\s*''/i)
})

test('security model: closed ACLs, no grants, no browser-callable function', () => {
  for (const signature of [
    'commerce._qs_product_channel_enabled\\(uuid, text, text\\)',
    'commerce\\.qs_guard_service_order_item_channel\\(\\)',
    'commerce\\.qs_guard_service_order_origin\\(\\)'
  ]) {
    assert.match(
      guard.code,
      new RegExp(`revoke\\s+all\\s+on\\s+function\\s+${signature}\\s+from\\s+public,\\s*anon,\\s*authenticated,\\s*service_role`, 'i'),
      signature
    )
  }
  assert.doesNotMatch(guard.bare, /\bgrant\b/i)
  assert.doesNotMatch(guard.bare, /create\s+or\s+replace\s+function\s+public\./i)
})

test('stable error contract: distinct tokens and SQLSTATEs, no internal metadata in messages', () => {
  const errors = new Map()
  for (const match of guard.code.matchAll(/errcode\s*=\s*'(\w+)'\s*,\s*message\s*=\s*'([A-Z_]+):([^']*)'/g)) {
    errors.set(match[2], { errcode: match[1], text: match[3] })
  }
  assert.deepEqual(
    Object.fromEntries([...errors].map(([token, value]) => [token, value.errcode])),
    {
      SERVICE_ORDER_ITEM_ORDER_NOT_FOUND: '23503',
      SERVICE_ORDER_ITEM_TENANT_MISMATCH: '23514',
      PRODUCT_NOT_AVAILABLE_FOR_CHANNEL: '22023',
      SERVICE_ORDER_CHANNEL_IMMUTABLE: '23514',
      SERVICE_ORDER_TENANT_IMMUTABLE: '23514'
    }
  )
  for (const [token, value] of errors) {
    assert.doesNotMatch(`${token} ${value.text}`, /pricing|cost|margin|supplier|admin|definition|metadata|source_/i, token)
  }
})

test('backward compatibility: no create RPC or public catalogue is replaced, and signatures are unchanged', () => {
  for (const name of [
    'create_quick_solution_order',
    'create_quick_solution_cart_order',
    'create_quick_solution_service_request',
    'get_quick_solution_catalog'
  ]) {
    assert.notEqual(latestFunctionBody(name).file, GUARD, `${name} must not be redefined by this slice`)
  }
  assert.equal(latestFunctionBody('create_quick_solution_cart_order').file, '20260921120000_qs14_checkout_guards_and_supplier_rules.sql')
  assert.equal(latestFunctionBody('create_quick_solution_order').file, '20260921120000_qs14_checkout_guards_and_supplier_rules.sql')
  assert.equal(latestFunctionBody('create_quick_solution_service_request').file, '20260921090000_qs14_catalog_margin_photography.sql')
})

test('backward compatibility: every existing service_order_items INSERT names order_id, tenant_id and product_key, so the guard sees them', () => {
  let total = 0
  for (const migration of migrations) {
    for (const match of migration.code.matchAll(/insert\s+into\s+commerce\.service_order_items\s*\(([^)]*)\)/gi)) {
      total += 1
      const columns = match[1].split(',').map((column) => column.trim().toLowerCase())
      for (const required of ['order_id', 'tenant_id', 'product_key']) {
        assert.ok(columns.includes(required), `${migration.name}: item INSERT must name ${required}`)
      }
    }
  }
  assert.ok(total >= 9, `expected the known item insert sites, found ${total}`)
})

function channelsBlocks() {
  const blocks = []
  const files = [
    ...migrations.map((migration) => ({ name: migration.name, text: migration.code })),
    { name: 'seed.sql', text: fs.readFileSync(new URL('../supabase/seed.sql', import.meta.url), 'utf8') }
  ]
  for (const file of files) {
    for (const match of file.text.matchAll(/"channels"\s*:\s*\{[^}]*\}/g)) blocks.push({ file: file.name, text: match[0] })
    for (const match of file.text.matchAll(/'channels'\s*,\s*jsonb_build_object\([^)]*\)/g)) blocks.push({ file: file.name, text: match[0] })
  }
  return blocks
}

// CAFE-GUEST-01H / 01I / 01J: Scan and Lamination are the ONLY deliberate exceptions - counter-only products.
// 01I is the historical generic placeholder (retired by 01J); 01J defines A4 and A3 Lamination (two blocks).
const SCAN_MIGRATION = '20260926150000_cafe_guest_01h_scan_product.sql'
const LAMINATION_PLACEHOLDER_MIGRATION = '20260926160000_cafe_guest_01i_lamination_product.sql'
const LAMINATION_MIGRATION = '20260926170000_cafe_guest_01j_lamination_a4_a3.sql'
const COUNTER_ONLY_MIGRATIONS = [SCAN_MIGRATION, LAMINATION_PLACEHOLDER_MIGRATION, LAMINATION_MIGRATION]

test('backward compatibility: every product defined in the repository is explicitly storefront=true, except the deliberate counter-only Scan and Lamination definitions', () => {
  const blocks = channelsBlocks()
  assert.ok(blocks.length >= 9, `expected the known channel blocks, found ${blocks.length}`)
  const exceptions = blocks.filter((block) => COUNTER_ONLY_MIGRATIONS.includes(block.file))
  assert.deepEqual(exceptions.map((block) => block.file), [SCAN_MIGRATION, LAMINATION_PLACEHOLDER_MIGRATION, LAMINATION_MIGRATION, LAMINATION_MIGRATION], 'exactly these exceptions: Scan, the retired placeholder, and A4 + A3 Lamination')
  for (const exception of exceptions) {
    assert.deepEqual(JSON.parse(exception.text.replace(/^"channels"\s*:\s*/, '')), { storefront: false, guided: false, pos: true, quote: false, advanced: false }, exception.file)
  }
  for (const block of blocks.filter((item) => !COUNTER_ONLY_MIGRATIONS.includes(item.file))) {
    assert.match(block.text, /"storefront"\s*:\s*true|'storefront'\s*,\s*true/, `${block.file}: ${block.text}`)
    assert.doesNotMatch(block.text, /storefront"?'?\s*[:,]\s*false/)
  }
  const client = fs.readFileSync(new URL('../src/App.jsx', import.meta.url), 'utf8')
  assert.match(client, /product\.channels\?\.storefront\s*!==\s*false/, 'the client default (missing = visible) matches the server helper')
})

test('the slice changes no product data, publishes no product and introduces no counter product', () => {
  assert.doesNotMatch(guard.bare, DML)
  assert.doesNotMatch(guard.bare, /service_product_configs\s+(set|values)/i)
  for (const migration of migrations) {
    if (migration.name === GUARD || migration.name === FOUNDATION || COUNTER_ONLY_MIGRATIONS.includes(migration.name)) continue
    // No repository migration defines a counter-only product (Scan 01H, the retired 01I placeholder and Lamination 01J are the exceptions, pinned above).
    assert.doesNotMatch(migration.code, /"pos"\s*:\s*true[^}]*"storefront"\s*:\s*false|"storefront"\s*:\s*false[^}]*"pos"\s*:\s*true/, migration.name)
  }
})

test('channel is not authorization and not production/handoff eligibility', () => {
  assert.doesNotMatch(guard.bare, /has_tenant_capability|is_app_admin|is_opps_staff|can_access_tenant|auth\.uid|auth\.role|session_user/i)
  assert.doesNotMatch(guard.bare, /handoff|opps|fulfilment_?mode|production/i)
  assert.match(normalizedHeader, /NOT authorization, NOT production or OPPS handoff eligibility, and NOT a fulfilment mode/)
})

test('the gaps recorded by this slice are explicit; the public catalogue gap is closed by CAFE-GUEST-01D, not here', () => {
  assert.match(normalizedHeader, /NO storefront=false product may be published until the public catalogue server projection \(get_quick_solution_catalog\) is also filtered/)
  assert.match(normalizedHeader, /No counter catalogue may be exposed until a deliberate product curation pass sets it/)
  assert.match(normalizedHeader, /Do not rely on the React UI/)
  // This slice never redefines the catalogue; CAFE-GUEST-01D (a separate
  // migration) does. The pos curation gap is unchanged by both.
  assert.doesNotMatch(guard.code, /get_quick_solution_catalog/i)
  assert.equal(latestFunctionBody('get_quick_solution_catalog').file, '20260926120000_cafe_guest_01d_public_catalogue_storefront_filter.sql')
})

test('SQL contract test is rollback-contained, never commits, and covers every required case', () => {
  const sql = fs.readFileSync(new URL('../supabase/tests/cafe_guest_01c_channel_availability_guard.sql', import.meta.url), 'utf8')
  const code = stripComments(sql)
  assert.match(code, /^\s*\\set ON_ERROR_STOP on\s*\n\s*begin;/m)
  assert.match(code, /\brollback;\s*\n\s*select 'CAFE-GUEST-01C/)
  assert.doesNotMatch(code, /^\s*commit\s*;/im, 'the transaction is never committed ("on commit drop" is a temp-table option)')
  for (const required of [
    /storefront=true must be allowed on storefront/,
    /missing channels\.storefront must default to TRUE/,
    /storefront=false must be denied on storefront/,
    /pos=true must be allowed at the counter/,
    /pos=false must be denied at the counter/,
    /missing channels\.pos must be denied at the counter/,
    /unknown or NULL sales channel must fail closed/,
    /'service_orders_channel_check'/,
    /storefront order \+ storefront=false/,
    /counter order \+ pos=false/,
    /counter order \+ pos missing/,
    /storefront -> counter/,
    /counter -> storefront/,
    /order tenant change/,
    /product_key -> storefront=false product on a storefront order/,
    /counter-only item moved to a storefront order/,
    /item tenant differs from parent order tenant/,
    /SERVICE_ORDER_CHANNEL_IMMUTABLE/,
    /PRODUCT_NOT_AVAILABLE_FOR_CHANNEL/,
    /SERVICE_ORDER_ITEM_TENANT_MISMATCH/,
    /set status = 'accepted', payment_status = 'paid'/,
    /set file_refs = coalesce/
  ]) {
    assert.match(code, required)
  }
})

test('the new test file is part of npm test', () => {
  assert.match(packageJson.scripts.test, /tests\/cafe-guest-01c-channel-guard\.test\.mjs/)
})
