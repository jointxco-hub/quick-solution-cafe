import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'

// CAFE-GUEST-01A - static contract for the counter-channel data foundation.
// Behavioral execution of supabase/tests/cafe_guest_01a_counter_channel_foundation.sql
// is pending a disposable database harness; these tests read the migration
// chain as text only.

const migrationsDir = new URL('../supabase/migrations/', import.meta.url)
const NEW_MIGRATION = '20260926100000_cafe_guest_01a_counter_channel_foundation.sql'

const migrationFiles = fs.readdirSync(migrationsDir).filter((name) => name.endsWith('.sql')).sort()
const stripComments = (sql) => sql.replace(/--[^\n]*/g, '')
// `bare` also drops single-quoted literals (e.g. COMMENT ON text) so
// "must not mention X" checks look only at executable SQL.
const stripLiterals = (sql) => sql.replace(/'(?:[^']|'')*'/g, "''")
const migrations = migrationFiles.map((name) => {
  const raw = fs.readFileSync(new URL(name, migrationsDir), 'utf8')
  const code = stripComments(raw)
  return { name, raw, code, bare: stripLiterals(code) }
})
const byName = (name) => migrations.find((migration) => migration.name === name)
const foundation = byName(NEW_MIGRATION)

const packageJson = JSON.parse(fs.readFileSync(new URL('../package.json', import.meta.url), 'utf8'))

function latestFunctionBody(functionName) {
  const pattern = new RegExp(`create\\s+or\\s+replace\\s+function\\s+public\\.${functionName}\\s*\\(`, 'gi')
  let latest = null
  for (const migration of migrations) {
    for (const match of migration.code.matchAll(pattern)) {
      latest = { migration, index: match.index }
    }
  }
  assert.ok(latest, `no definition of public.${functionName} found`)
  const rest = latest.migration.code.slice(latest.index + 1)
  const next = rest.search(/create\s+or\s+replace\s+function/i)
  return {
    file: latest.migration.name,
    body: next === -1 ? rest : rest.slice(0, next)
  }
}

test('the counter-channel migration exists, is additive, and is owned by the Cafe repository', () => {
  assert.ok(foundation, `${NEW_MIGRATION} must exist`)
  const earlier = migrationFiles.filter((name) => !/cafe_guest_01/.test(name))
  assert.ok(earlier.every((name) => name < NEW_MIGRATION), 'it must sort after every pre-CAFE-GUEST migration')
  assert.doesNotMatch(foundation.bare, /create\s+(or\s+replace\s+)?function/i, 'no RPC is created or replaced in this slice')
  assert.doesNotMatch(foundation.bare, /\b(create|drop)\s+(table|policy|trigger|index|type|domain|schema)\b/i)
  assert.doesNotMatch(foundation.bare, /\b(grant|revoke)\b/i, 'table privileges are unchanged')
  assert.doesNotMatch(foundation.bare, /\b(insert|update|delete)\b/i, 'no existing row is rewritten or backfilled')
  const alters = [...foundation.code.matchAll(/alter\s+table\s+([\w.]+)/gi)].map((match) => match[1].toLowerCase())
  assert.ok(alters.length > 0)
  assert.deepEqual([...new Set(alters)], ['commerce.service_orders'])
})

test('channel is text NOT NULL DEFAULT storefront, restricted to storefront/counter by a named CHECK', () => {
  assert.match(foundation.code, /add\s+column\s+if\s+not\s+exists\s+channel\s+text\s+not\s+null\s+default\s+'storefront'/i)

  const constraint = foundation.code.match(
    /add\s+constraint\s+service_orders_channel_check\s+check\s*\(\s*channel\s+in\s*\(([^)]*)\)\s*\)/i
  )
  assert.ok(constraint, 'named service_orders_channel_check constraint is required')
  const values = [...constraint[1].matchAll(/'([a-z_]+)'/g)].map((match) => match[1])
  assert.deepEqual(values, ['storefront', 'counter'])
  assert.match(foundation.code, /drop\s+constraint\s+if\s+exists\s+service_orders_channel_check/i, 'idempotent re-run')
})

test('repository convention is text + CHECK: no enum or domain is introduced anywhere in the migration chain', () => {
  for (const migration of migrations) {
    assert.doesNotMatch(migration.code, /create\s+type\s|create\s+domain\s|as\s+enum/i, migration.name)
  }
  const original = byName('20260913155351_qs_03_quick_solution_foundation.sql')
  assert.match(original.code, /status\s+text\s+not\s+null\s+default\s+'submitted'\s*check\s*\(status\s+in/i)
})

test('created_by is a nullable uuid with no default and no foreign key', () => {
  assert.match(foundation.code, /add\s+column\s+if\s+not\s+exists\s+created_by\s+uuid\s*(;|,|\n)/i)
  const definition = foundation.code.match(/created_by\s+uuid[^;,]*/i)[0]
  assert.doesNotMatch(definition, /not\s+null/i)
  assert.doesNotMatch(definition, /references/i)
  assert.doesNotMatch(definition, /default/i)
  assert.doesNotMatch(foundation.bare, /foreign\s+key|references/i)
})

test('the existing staff-identity columns in this schema are plain uuid, which is the convention created_by follows', () => {
  const handoffs = byName('20260913174927_qs_04a_opps_handoff_boundary.sql')
  const links = byName('20260913185224_qs_06_easy_locate_verified_links.sql')
  assert.match(handoffs.code, /last_previewed_by\s+uuid\s*,/i)
  assert.match(links.code, /verified_by\s+uuid\s*,/i)
})

test('customer_name keeps its NOT NULL contract and is not touched by this migration', () => {
  const original = byName('20260913155351_qs_03_quick_solution_foundation.sql')
  assert.match(original.code, /customer_name\s+text\s+not\s+null/i)
  assert.doesNotMatch(foundation.code, /customer_name/i)
  for (const migration of migrations) {
    assert.doesNotMatch(
      migration.code,
      /alter\s+column\s+customer_name\s+drop\s+not\s+null/i,
      migration.name
    )
  }
})

test('every existing service_orders INSERT names its columns and none names channel or created_by, so defaults apply', () => {
  let total = 0
  for (const migration of migrations) {
    if (migration.name === NEW_MIGRATION) continue
    // the 01M counter-create RPC is the one writer that sets channel and created_by (pinned in counter-create-order-rpc.test.mjs)
    if (/cafe_guest_01m_counter_create_order_rpc/.test(migration.name)) continue
    for (const match of migration.code.matchAll(/insert\s+into\s+commerce\.service_orders\s*(\(([^)]*)\))?/gi)) {
      total += 1
      assert.ok(match[2], `${migration.name}: positional INSERT INTO commerce.service_orders would break on new columns`)
      const columns = match[2].split(',').map((column) => column.trim().toLowerCase())
      assert.ok(columns.includes('tenant_id') && columns.includes('customer_name'), migration.name)
      assert.ok(!columns.includes('channel'), `${migration.name} must not set channel`)
      assert.ok(!columns.includes('created_by'), `${migration.name} must not set created_by`)
    }
  }
  assert.ok(total >= 9, `expected the nine known insert sites, found ${total}`)
})

test('the latest storefront create RPCs still insert with explicit columns and keep their signatures', () => {
  for (const name of [
    'create_quick_solution_cart_order',
    'create_quick_solution_order',
    'create_quick_solution_service_request'
  ]) {
    const { file, body } = latestFunctionBody(name)
    assert.notEqual(file, NEW_MIGRATION, `${name} must not be redefined by this slice`)
    const insert = body.match(/insert\s+into\s+commerce\.service_orders\s*\(([^)]*)\)/i)
    assert.ok(insert, `${name} (${file}) must insert into service_orders with an explicit column list`)
    assert.doesNotMatch(insert[1], /\b(channel|created_by)\b/i, name)
  }
})

test('SELECT * INTO row-type variables and no whole-row JSON serialization mean the new columns do not leak to callers', () => {
  for (const migration of migrations) {
    assert.doesNotMatch(
      migration.code,
      /(to_jsonb|row_to_json)\s*\(\s*(so|v_order|v_existing|v_service_order)\s*\)/i,
      `${migration.name} serializes a whole service_orders row`
    )
  }
})

test('source_metadata provenance is preserved: historical channel values remain and the migration does not rewrite them', () => {
  const values = new Set()
  for (const migration of migrations) {
    if (migration.name === NEW_MIGRATION) continue
    // 01M creates counter orders, so its own provenance says 'counter'; the historical values are what this pins
    if (/cafe_guest_01m_counter_create_order_rpc/.test(migration.name)) continue
    for (const match of migration.code.matchAll(/'channel'\s*,\s*'([a-z_]+)'/gi)) values.add(match[1])
  }
  assert.deepEqual([...values].sort(), ['storefront', 'storefront_cart'])
  assert.doesNotMatch(foundation.bare, /source_metadata/i)

  const documented = foundation.raw.replace(/^--\s?/gm, '').replace(/\s+/g, ' ')
  assert.match(documented, /canonical operational channel/)
  assert.match(documented, /source_metadata\.channel is provenance\/context only/)
})

test('channel is not an authorization input', () => {
  assert.doesNotMatch(foundation.bare, /has_tenant_capability|is_app_admin|is_opps_staff|can_access_tenant|auth\.uid/i)
  for (const migration of migrations) {
    if (migration.name === NEW_MIGRATION) continue
    assert.doesNotMatch(
      migration.code,
      /\bchannel\b[^;\n]{0,40}(is_app_admin|is_opps_staff|can_access_tenant|has_tenant_capability)|(is_app_admin|is_opps_staff|can_access_tenant|has_tenant_capability)[^;\n]{0,40}\bchannel\b/i,
      migration.name
    )
  }
  const documented = foundation.raw.replace(/^--\s?/gm, '').replace(/\s+/g, ' ')
  assert.match(documented, /NOT an authorization input/)
})

test('handoff contract: channel is never a production/OPPS-handoff eligibility signal', () => {
  const documented = foundation.raw.replace(/^--\s?/gm, '').replace(/\s+/g, ' ')
  assert.match(documented, /NOT a production or OPPS-handoff eligibility signal/)
  assert.match(documented, /Handoff stays an explicit staff action/)

  // No handoff-related migration references channel, so nothing hardcodes
  // "counter = never production" or "counter = always production".
  const handoffMigrations = migrationFiles.filter((name) => /opps_handoff|create_opps_order|backend_acceptance|handoff_queue|sent_preview|collection_point_visibility|rpc_grants/.test(name))
  assert.ok(handoffMigrations.length >= 5)
  for (const name of handoffMigrations) {
    assert.doesNotMatch(byName(name).code, /\bchannel\b/i, `${name} must not depend on channel`)
  }

  // The eventual eligibility rule must not be a bare channel filter.
  for (const migration of migrations) {
    assert.doesNotMatch(migration.code, /channel\s*(<>|!=)\s*'counter'/i, migration.name)
    assert.doesNotMatch(migration.code, /channel\s*=\s*'counter'[^;]{0,120}handoff|handoff[^;]{0,120}channel\s*=\s*'counter'/i, migration.name)
  }

  // Every trigger on service_orders is a BEFORE UPDATE trigger (updated_at,
  // and the CAFE-GUEST-01C origin guard): no trigger can create a handoff (or
  // anything else) from an insert, whatever its channel.
  const triggers = []
  for (const migration of migrations) {
    for (const match of migration.code.matchAll(/create\s+trigger\s+(\w+)\s+(before|after)\s+([a-z_ ,]+?)\s+on\s+commerce\.service_orders/gi)) {
      triggers.push([match[1], match[2].toLowerCase(), match[3].trim().toLowerCase().split(/\s+/)[0]])
    }
  }
  assert.deepEqual(triggers, [
    ['trg_qs_service_orders_updated_at', 'before', 'update'],
    ['trg_qs_guard_service_order_origin', 'before', 'update']
  ])
})

test('handoff rows are created only by explicit staff (admin_*) RPCs', () => {
  let sites = 0
  for (const migration of migrations) {
    for (const match of migration.code.matchAll(/insert\s+into\s+commerce\.service_order_handoffs/gi)) {
      sites += 1
      const before = migration.code.slice(0, match.index)
      const owners = [...before.matchAll(/create\s+or\s+replace\s+function\s+([\w.]+)/gi)]
      const owner = owners.at(-1)?.[1]
      assert.match(owner ?? '', /^public\.admin_/i, `${migration.name}: handoff insert inside ${owner}`)
    }
  }
  assert.ok(sites >= 3, `expected the known handoff insert sites, found ${sites}`)
})

test('scope guard: the slice adds no RPC, payment, client link, capability, or fulfilmentMode', () => {
  assert.doesNotMatch(
    foundation.bare,
    /counter_job|client_id|payment|fulfilment_?mode|cafe\.counter|has_tenant_capability|walk_in_orders|counter_orders|quick_copy_orders/i
  )
})

test('SQL contract test is rollback-contained, never commits, and covers every required property', () => {
  const sql = fs.readFileSync(new URL('../supabase/tests/cafe_guest_01a_counter_channel_foundation.sql', import.meta.url), 'utf8')
  const code = stripComments(sql)
  assert.match(code, /^\s*\\set ON_ERROR_STOP on\s*\n\s*begin;/m)
  assert.match(code, /\brollback;\s*\n\s*select 'CAFE-GUEST-01A/)
  assert.doesNotMatch(code, /\bcommit\b/i)
  for (const required of [
    /column_name='channel'/,
    /column_name='created_by'/,
    /is_nullable <> 'NO'/,
    /is_nullable <> 'YES'/,
    /not like '''storefront''%'/,
    /array\['counter','storefront'\]/,
    /contype='f'/,
    /omitted channel must resolve to storefront/,
    /omitted created_by must resolve to NULL/,
    /exception when check_violation/,
    /exception when not_null_violation/,
    /'kiosk'/
  ]) {
    assert.match(code, required)
  }
})

test('the new test file is part of npm test', () => {
  assert.match(packageJson.scripts.test, /tests\/cafe-guest-01a-counter-channel\.test\.mjs/)
})
