import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'
import { buildA4CounterPrintConfig } from '../src/lib/counterPrintConfig.js'

// CAFE-GUEST-01M - static guards for public.create_quick_solution_counter_order(). The behavioral
// proof is SQL, run on a throwaway PostgreSQL (npm run test:sql):
// supabase/tests/cafe_guest_01m_counter_create_order_rpc.sql. These tests stop a later edit from
// adding an argument, weakening a check, or writing anything the counter must not write.

const read = (path) => fs.readFileSync(new URL(path, import.meta.url), 'utf8').replace(/\r\n/g, '\n')
const MIGRATION = '../supabase/migrations/20260926220000_cafe_guest_01m_counter_create_order_rpc.sql'
const migration = read(MIGRATION)
const code = migration.replace(/--[^\n]*/g, '')
const fn = code.match(/create or replace function public\.create_quick_solution_counter_order\([\s\S]*?\n\$\$;/)[0]
const body = fn.slice(fn.indexOf('as $$'))
const bare = body.replace(/'(?:[^']|'')*'/g, "''")
const sqlTest = read('../supabase/tests/cafe_guest_01m_counter_create_order_rpc.sql')

test('the signature is the idempotency key, product, configuration and optional customer details - nothing else', () => {
  assert.match(fn, /create or replace function public\.create_quick_solution_counter_order\(\s+p_idempotency_key text,\s+p_product_key text,\s+p_configuration jsonb,\s+p_customer_name text default null,\s+p_customer_email text default null,\s+p_customer_phone text default null\s+\)\s+returns jsonb/)
  const params = [...fn.slice(0, fn.indexOf('returns jsonb')).matchAll(/\bp_[a-z_]+\b/g)].map((match) => match[0])
  assert.deepEqual(params, ['p_idempotency_key', 'p_product_key', 'p_configuration', 'p_customer_name', 'p_customer_email', 'p_customer_phone'])
  assert.doesNotMatch(params.join(' '), /tenant|channel|created|actor|paid|payment|method|amount|price|total|status|file|quantity/i)
  assert.match(fn, /language plpgsql\s+security definer\s+set search_path = ''/)
  assert.doesNotMatch(fn.slice(0, fn.indexOf('as $$')), /\bstable\b|\bimmutable\b/, 'it writes: volatile')
  assert.match(code, /revoke all on function public\.create_quick_solution_counter_order\(text, text, jsonb, text, text, text\)\s+from public, anon, authenticated, service_role;/)
  const grants = [...code.matchAll(/grant execute on function public\.create_quick_solution_counter_order\([^)]*\)\s+to\s+([^;]*);/gi)].map((match) => match[1].trim())
  assert.deepEqual(grants, ['authenticated'])
})

test('sign-in, tenant, capability and module come first, in that order, with the catalogue\'s exact errors; then input, idempotency, product, pricing, writes', () => {
  const at = (needle) => body.indexOf(needle)
  const order = [
    'v_actor := auth.uid();', "t.slug = 'quick-solution'", "has_tenant_capability(v_tenant_id, 'cafe.counter.operate')", "tc.capability_key = 'quick_solution'",
    'v_key := trim(coalesce(p_idempotency_key', 'pg_advisory_xact_lock', 'from commerce.service_orders so', 'commerce._qs_product_counter_sellable(v_tenant_id, v_product_key)',
    'commerce.qs_calculate_price(v_tenant_id, v_product_key, p_configuration)', "needs a quote before it can be ordered", "p_configuration ? 'quantity'",
    'insert into commerce.service_orders', 'insert into commerce.service_order_items'
  ].map(at)
  order.push(body.lastIndexOf('return jsonb_build_object('), 0) // the created-order return; the replay return comes earlier, correctly
  order.pop()
  assert.ok(order.every((index) => index > 0), `every step is present: ${order}`)
  assert.deepEqual([...order].sort((a, b) => a - b), order)
  for (const [state, message] of [['42501', 'Staff sign-in is required.'], ['22023', 'Quick Solution tenant was not found.'], ['42501', 'You do not have access to the Quick Solution counter.'],
    ['22023', 'Quick Solution counter is not active.'], ['22023', 'Order idempotency key is required.'], ['22023', 'Order idempotency key is not valid.'],
    ['22023', 'Customer name is not valid.'], ['22023', 'Email address is not valid.'], ['22023', 'Phone number is not valid.'],
    ['22023', 'Product was not found.'], ['22023', 'Product is not available for the counter.'], ['22023', 'Quantity is not an option for this product.'],
    ['23505', 'This idempotency key was already used for a different order request.']]) {
    assert.match(body, new RegExp(`errcode = '${state}',\\s+message = '${message.replace(/\./g, '\\.')}'`), message)
  }
  // Only the counter capability: no manage capability, no app-admin / OPPS-staff / tenant-access bypass.
  assert.doesNotMatch(body, /cafe\.operations\.manage|is_app_admin|is_opps_staff|can_access_tenant/)
  // Existing storefront messages reused verbatim.
  const storefront = read('../supabase/migrations/20260921120000_qs14_checkout_guards_and_supplier_rules.sql')
  for (const message of ['Order idempotency key is required.', 'Email address is not valid.', 'Phone number is not valid.', 'needs a quote before it can be ordered. Please use the request-a-quote flow.']) {
    assert.ok(storefront.includes(message), `reused from the storefront RPC: ${message}`)
  }
})

test('the server decides the tenant, channel and actor, and writes the canonical unpaid state: no payment, no file, no token', () => {
  const insertOrder = body.match(/insert into commerce\.service_orders \(([\s\S]*?)\) values \(([\s\S]*?)\)\s+returning/)
  const columns = insertOrder[1].split(',').map((column) => column.trim())
  const values = insertOrder[2].split(/,\s*(?![^()]*\))/).map((value) => value.trim())
  const row = Object.fromEntries(columns.map((column, index) => [column, values[index]]))
  assert.equal(row.tenant_id, 'v_tenant_id')
  assert.equal(row.channel, "'counter'")
  assert.equal(row.created_by, 'v_actor')
  assert.equal(row.status, "'submitted'")
  assert.equal(row.payment_status, "'unpaid'")
  assert.equal(row.fulfilment_type, "'cafe'")
  assert.equal(row.fulfilment_fee, '0')
  assert.equal(row.subtotal, 'v_subtotal')
  assert.equal(row.total_amount, 'v_subtotal')
  assert.equal(row.customer_name, 'v_name')
  assert.equal(row.idempotency_key, 'v_stored_key')
  assert.match(body, /v_actor := auth\.uid\(\);/)
  assert.doesNotMatch(columns.join(' '), /paid|payment_(?!status)|opps_order_id|delivery|customer_notes|upload|token/)
  const insertItem = body.match(/insert into commerce\.service_order_items \(([\s\S]*?)\) values \(([\s\S]*?)\);/)
  assert.deepEqual(insertItem[1].split(',').map((column) => column.trim()), ['order_id', 'tenant_id', 'product_id', 'product_key', 'product_name', 'quantity', 'configuration', 'pricing_snapshot', 'line_total'])
  assert.match(insertItem[2].replace(/\s+/g, ' '), /v_order_id, v_tenant_id, v_product_id, v_product_key, v_product_name, 1, p_configuration, v_price -> 'snapshot', v_subtotal/)
  // Exactly one order and one item, and nothing else is written by this migration.
  assert.equal((body.match(/insert into commerce\./g) || []).length, 2)
  assert.doesNotMatch(bare, /\b(update|delete)\b|\bcreate\s+table|service_order_payments|service_order_files|service_order_handoffs|tracking|upload_token|payfast|receipt/i)
  assert.doesNotMatch(body, /payment_method|paymentMethod|payment_reference|transaction/i)
})

test('the price is the authoritative server result: nothing is computed here', () => {
  assert.match(body, /v_price := commerce\.qs_calculate_price\(v_tenant_id, v_product_key, p_configuration\);/)
  assert.match(body, /v_subtotal := \(v_price ->> 'total'\)::numeric;/)
  assert.doesNotMatch(bare, /round\(|unitPrice|baseRate|pricing_definition|marginRate|supplierCost|referencePrice|\bfee_amount\b/i)
  assert.equal((bare.match(/\bv_subtotal\s*:=/g) || []).length, 1, 'assigned once, from the server result')
  // Request-style services: the storefront checkout's rule, refused for the counter.
  assert.match(body, /coalesce\(\(v_price -> 'metrics' ->> 'quoteRequired'\)::boolean, false\)\s+or v_strategy = 'PHOTOGRAPHY_SESSION'/)
  // configuration.quantity is refused only where the strategy has no quantity option.
  assert.match(body, /p_configuration \? 'quantity' and v_strategy in \('PER_UNIT', 'PER_PAGE', 'PER_AREA'\)/)
})

test('idempotency is database-enforced, actor-scoped, compared on replay, and never returns someone else\'s order', () => {
  assert.match(body, /v_stored_key := 'counter:' \|\| v_actor::text \|\| ':' \|\| v_key;/)
  assert.match(body, /pg_catalog\.pg_advisory_xact_lock\(pg_catalog\.hashtextextended\(v_tenant_id::text \|\| '\|' \|\| v_stored_key, 0\)\)/, 'concurrent retries are serialized per key')
  const replay = body.slice(body.indexOf('if v_existing.id is not null then'), body.indexOf('-- the product: it must exist'))
  for (const check of ["v_existing.channel is distinct from 'counter'", 'v_existing.created_by is distinct from v_actor', 'v_item.id is null', 'v_item.product_key is distinct from v_product_key',
    'v_item.configuration is distinct from p_configuration', 'v_existing.customer_name is distinct from v_name', 'v_existing.customer_email is distinct from v_email', 'v_existing.customer_phone is distinct from v_phone']) {
    assert.ok(replay.includes(check), check)
  }
  assert.match(replay, /errcode = '23505'/)
  assert.match(replay, /'replayed', true/)
  assert.match(body, /'replayed', false/)
  // The existing unique constraint is the backstop.
  assert.match(read('../supabase/migrations/20260913155351_qs_03_quick_solution_foundation.sql'), /unique \(tenant_id, idempotency_key\)/)
  // The lookup is by stored key and tenant only; the replay returns the stored rows, never a recomputed price.
  assert.match(body, /where so\.tenant_id = v_tenant_id\s+and so\.idempotency_key = v_stored_key/)
  assert.match(replay, /'lineTotal', v_item\.line_total/)
})

test('customer details are optional: Walk-in with null email and phone by default, normalized like the storefront, no account created', () => {
  assert.match(body, /c_walk_in constant text := 'Walk-in';/)
  assert.match(body, /v_name := coalesce\(v_name, c_walk_in\);/)
  assert.match(body, /v_email := nullif\(lower\(trim\(coalesce\(p_customer_email, ''\)\)\), ''\);/)
  assert.match(body, /v_phone := nullif\(trim\(coalesce\(p_customer_phone, ''\)\), ''\);/)
  assert.match(body, /position\('@' in v_email\) < 2/)
  assert.match(body, /length\(regexp_replace\(v_phone, '\[\^0-9\+\]', '', 'g'\)\) < 7/)
  assert.doesNotMatch(bare, /public\.users|auth\.users|clients/, 'no account or client is created or linked')
  assert.doesNotMatch(body, /provide an email address or phone number/i, 'contact details are NOT required')
})

test('one predicate decides counter eligibility for both RPCs, and it is internal', () => {
  const predicate = code.match(/create or replace function commerce\._qs_product_counter_sellable\([\s\S]*?\n\$\$;/)[0]
  assert.match(predicate, /returns boolean\s+language sql\s+stable\s+security definer\s+set search_path = ''/)
  assert.match(code, /revoke all on function commerce\._qs_product_counter_sellable\(uuid, text\)\s+from public, anon, authenticated, service_role;/)
  assert.doesNotMatch(code, /grant execute on function commerce\._qs_product_counter_sellable/)
  assert.doesNotMatch(predicate, /storefront/i)
  assert.match(body, /if not commerce\._qs_product_counter_sellable\(v_tenant_id, v_product_key\) then/)
  // Exactly three functions are defined: the predicate, the catalogue (same result), the create RPC.
  assert.deepEqual([...code.matchAll(/create or replace function ([\w.]+)/g)].map((match) => match[1]), ['commerce._qs_product_counter_sellable', 'public.get_quick_solution_counter_catalog', 'public.create_quick_solution_counter_order'])
  assert.doesNotMatch(code.replace(/'(?:[^']|'')*'/g, "''"), /\bcreate\s+(?:or replace\s+)?(?:table|trigger|policy|index|view|type)\b|\balter\b|\bdrop\b|\btruncate\b|\bgrant execute on function commerce\./i)
  assert.match(code, /to_regprocedure\('public\.has_tenant_capability\(uuid,text\)'\) is null/)
})

test('the response is a flat customer/staff-safe summary whose keys match what the SQL test pins', () => {
  const created = body.slice(body.lastIndexOf('return jsonb_build_object('))
  const keys = [...created.matchAll(/^\s+'([a-zA-Z]+)',/gm)].map((match) => match[1]).sort()
  assert.deepEqual(keys, ['channel', 'configuration', 'createdAt', 'customerEmail', 'customerName', 'customerPhone', 'fulfilmentFee', 'lineTotal', 'ok', 'orderId', 'orderNumber',
    'paymentStatus', 'productKey', 'productName', 'replayed', 'status', 'subtotal', 'totalAmount'])
  const pinned = sqlTest.match(/array\['channel', 'configuration'[^\]]*\]/)[0].match(/'([^']+)'/g).map((item) => item.replace(/'/g, ''))
  assert.deepEqual(pinned, keys)
  assert.doesNotMatch(created, /created_by|tenant_id|idempotency|pricing_snapshot|pricing_definition|capabilit/i)
})

test('the A4 physical-print convention from the pure adapter is exactly what the SQL test submits: no fake file, no fileName, no quantity', () => {
  const config = buildA4CounterPrintConfig({ pages: 12, copies: 3, printMode: 'bw', sides: 'single', finish: 'none' })
  assert.deepEqual(config, { pages: 12, copies: 3, printMode: 'bw', sides: 'single', finish: 'none', documentInstructions: [{ selection: 'all', sourcePages: 12 }], documentPlanValid: true })
  assert.ok(sqlTest.includes(JSON.stringify(config)), 'the SQL test submits the adapter\'s output verbatim')
  assert.equal('fileName' in config || 'quantity' in config || 'file' in config, false)
})

test('the SQL contract test covers access, writes, pricing, safety, idempotency, atomicity and payment under real roles, rollback-contained', () => {
  const sql = sqlTest.replace(/--[^\n]*/g, '')
  assert.match(sql, /\\set ON_ERROR_STOP on\s*\n\s*begin;/)
  assert.match(sql, /\brollback;\s*\n\s*select 'CAFE-GUEST-01M .* passed' as result;/)
  assert.doesNotMatch(sql, /^\s*commit\s*;/im)
  assert.match(sql, /execute format\('set local role %I', p_role\)/)
  for (const required of [
    /anonymous/, /authenticated non-member/, /active member/, /active admin/, /active owner/, /suspended member/, /owner of a FOREIGN tenant/,
    /app admin with no Cafe membership/, /app admin with the approved-owner email/, /OPPS staff with no Cafe membership/, /'anon', 'service_role'/,
    /a disabled quick_solution module must deny/, /authorization comes before the module check/, /Cafe tenant must fail closed/, /a just-suspended admin must be denied/,
    /exactly one order and exactly one item must be created/, /channel must be counter/, /created_by must be auth\.uid\(\)/, /the canonical initial state is submitted \/ unpaid/,
    /no details must default to Walk-in/, /stray configuration keys must not change the channel, actor, tenant or payment state/, /no user or customer account may be created/,
    /must be written at the server price/, /a physical A4 counter print needs no file, file name, file record or quantity/, /a product-defined quantity option must be accepted/,
    /the retired generic lamination must not be orderable/, /the catalogue and the write path must decide % identically/, /a configuration\.quantity override must be refused/,
    /request-style % must be refused with the quote-required error/, /an exact retry must return the original order unchanged/, /a retry must not increase any row count/,
    /reusing a key with different input must be a conflict/, /a different key must create a different order/, /another actor must never receive someone else/,
    /a colliding storefront order must never be returned as a counter result/, /the unique constraint must refuse a duplicate stored key/,
    /a failed item insert must leave no order behind/, /the key must be reusable after a rolled-back failure/, /a pricing failure must leave nothing behind/,
    /no payment row may be created/, /no payment, token, file, handoff or event row may be created/, /the 01C guard triggers must still be in force/,
    /the public storefront catalogue must be unchanged/, /the admin catalogue is unchanged/, /the capability semantics must be unchanged/
  ]) assert.match(sql, required)
  for (const key of ['v-pos-false', 'v-pos-missing', 'v-channels-missing', 'v-pos-string-true', 'v-pos-number', 'v-pos-null', 'v-pos-object', 'v-config-draft', 'v-config-archived',
    'v-product-draft', 'v-product-archived', 'v-product-unavailable', 'v-active-false', 'v-active-string-yes', 'v-ok-storefront-off']) assert.ok(sql.includes(`"key":"${key}"`), key)
  // Prices are derived from the server, never hard-coded in the SQL test.
  assert.doesNotMatch(sql, /subtotal\s*(?:<>|=)\s*\d|line_total\s*(?:<>|=)\s*\d|total\s*(?:<>|=)\s*\d{2,}/)
  assert.match(sql, /commerce\.qs_calculate_price\(v_cafe, v_case ->> 'p', v_case -> 'c'\)/)
})

test('the isolated client wrapper sends only the idempotency key, product, configuration and optional customer fields, and nothing calls it', () => {
  const api = read('../src/lib/supabaseApi.js')
  const wrapper = api.match(/export async function createQuickSolutionCounterOrder\([\s\S]*?\n\}/)[0]
  assert.match(wrapper, /\{ idempotencyKey, productKey, configuration, customerName, customerEmail, customerPhone \}/)
  assert.match(wrapper, /p_idempotency_key: idempotencyKey,\s+p_product_key: productKey,\s+p_configuration: configuration/)
  assert.match(wrapper, /return rpc\('create_quick_solution_counter_order', body, \{ accessToken \}\)/)
  assert.doesNotMatch(wrapper, /tenant|channel|created|actor|paid|payment|method|price|total|status|capabilit/i)
  const walk = (dir, out = []) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const next = new URL(`${entry.name}${entry.isDirectory() ? '/' : ''}`, dir)
      if (entry.isDirectory()) walk(next, out)
      else if (/\.(jsx?|css)$/.test(entry.name)) out.push({ name: entry.name, text: fs.readFileSync(next, 'utf8') })
    }
    return out
  }
  const users = walk(new URL('../src/', import.meta.url)).filter((file) => /createQuickSolutionCounterOrder|create_quick_solution_counter_order/.test(file.text)).map((file) => file.name)
  assert.deepEqual(users, ['CounterPage.jsx', 'supabaseApi.js'], 'since 01O exactly one caller: the Counter page, for the four supported products')
  assert.equal((read('../src/lib/navigation.js').match(/counter/gi) || []).length, 3, 'only the /counter route')
})

test('the harness runs it and skips it visibly without the OPPS access layer; the new test file is part of npm test', () => {
  const runner = read('../supabase/tests/harness/run-local-sql-tests.ps1')
  assert.match(runner, /has_tenant_capability/)
  assert.match(JSON.parse(read('../package.json')).scripts.test, /tests\/counter-create-order-rpc\.test\.mjs/)
})
