import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'
import { products } from '../src/data/products.js'
import { isCounterProduct, resolveCounterCatalogue, resolveCounterAction, resolveCounterGroup } from '../src/lib/counterCatalogue.js'

// CAFE-GUEST-01L - static guards for public.get_quick_solution_counter_catalog(). The
// behavioral proof is SQL, run on a throwaway PostgreSQL (npm run test:sql):
// supabase/tests/cafe_guest_01l_counter_catalogue_rpc.sql. These tests stop a later edit from
// widening what the RPC reads, returns or accepts.

const read = (path) => fs.readFileSync(new URL(path, import.meta.url), 'utf8').replace(/\r\n/g, '\n')
const MIGRATION = '../supabase/migrations/20260926210000_cafe_guest_01l_counter_catalogue_rpc.sql'
const migration = read(MIGRATION)
const code = migration.replace(/--[^\n]*/g, '')
const fn = code.match(/create or replace function public\.get_quick_solution_counter_catalog\(\)[\s\S]*?\n\$\$;/)[0]
const body = fn.slice(fn.indexOf('as $$'))
const sqlTest = read('../supabase/tests/cafe_guest_01l_counter_catalogue_rpc.sql')

test('the RPC takes no argument, so the caller can neither name nor switch the tenant', () => {
  assert.match(fn, /create or replace function public\.get_quick_solution_counter_catalog\(\)\s+returns jsonb/)
  assert.doesNotMatch(fn, /\bp_[a-z_]+\b/, 'no parameters of any kind')
  assert.match(body, /where t\.slug = 'quick-solution'\s+and t\.status = 'active'/, 'the canonical slug is resolved server-side, active tenants only')
  assert.match(fn, /language plpgsql\s+stable\s+security definer\s+set search_path = ''/, 'read-only, definer, hardened')
  assert.match(code, /revoke all on function public\.get_quick_solution_counter_catalog\(\)\s+from public, anon, authenticated, service_role;/)
  assert.match(code, /grant execute on function public\.get_quick_solution_counter_catalog\(\)\s+to authenticated;/)
  // The only grantee is authenticated.
  const grants = [...code.matchAll(/grant execute on function [^;]*?\s+to\s+([^;]*);/gi)].map((match) => match[1].trim())
  assert.deepEqual(grants, ['authenticated'])
})

test('authenticate, resolve the tenant, authorize, then check the module - in that order, with stable errors', () => {
  const at = (needle) => body.indexOf(needle)
  const order = ['auth.uid() is null', "t.slug = 'quick-solution'", "has_tenant_capability(v_tenant_id, 'cafe.counter.operate')", "tc.capability_key = 'quick_solution'", "return jsonb_build_object("].map(at)
  assert.ok(order.every((index) => index > 0), 'every step is present')
  assert.deepEqual([...order].sort((a, b) => a - b), order, 'authorization precedes the module check, so module state is only revealed to an authorized actor')
  // Existing conventions reused; one new message that mirrors the storefront's '... is not active.'
  assert.match(body, /errcode = '42501', message = 'Staff sign-in is required\.'/)
  assert.match(body, /errcode = '22023', message = 'Quick Solution tenant was not found\.'/)
  assert.match(body, /errcode = '42501', message = 'You do not have access to the Quick Solution counter\.'/)
  assert.match(body, /errcode = '22023', message = 'Quick Solution counter is not active\.'/)
  for (const message of ['Staff sign-in is required.', 'Quick Solution tenant was not found.']) {
    assert.match(read('../supabase/migrations/20260913164013_qs_03_1_admin_catalog.sql'), new RegExp(message.replace(/\./g, '\\.')), 'reused from the admin catalogue RPC')
  }
  // Only the counter capability: no manage capability, no app-admin / OPPS-staff / tenant-access bypass.
  assert.doesNotMatch(body, /cafe\.operations\.manage|is_app_admin|is_opps_staff|can_access_tenant/)
  assert.match(body, /tc\.enabled = true/)
})

test('product eligibility is exactly: published config, published+available product, strict boolean pos, active not off', () => {
  const where = body.slice(body.indexOf('where c.tenant_id = v_tenant_id'))
  assert.match(where, /c\.status = 'published'/)
  assert.match(where, /p\.status = 'published'/)
  assert.match(where, /p\.availability = 'available'/)
  assert.match(where, /commerce\._qs_product_channel_enabled\(c\.tenant_id, c\.source_key, 'counter'\)/, 'pos comes from the one shared strict rule (CAFE-GUEST-01C)')
  assert.match(where, /case coalesce\(jsonb_typeof\(c\.customer_definition -> 'active'\), 'null'\)\s+when 'null' then true\s+when 'boolean' then \(c\.customer_definition ->> 'active'\)::boolean\s+else false/)
  // It is NOT the storefront filter, and nothing else decides it.
  assert.doesNotMatch(body, /storefront/i)
  assert.doesNotMatch(where, /strategy|category|serviceType|jsonb_typeof\(c\.customer_definition -> 'channels'/)
  assert.match(body, /order by c\.sort_order, p\.name/)
  // The shared rule is strict about pos (unchanged since 01C).
  const rule = read('../supabase/migrations/20260926110000_cafe_guest_01c_channel_availability_guard.sql')
  assert.match(rule, /when 'counter' then\s+case coalesce\(jsonb_typeof\(c\.customer_definition -> 'channels' -> 'pos'\), 'null'\)\s+when 'boolean' then \(c\.customer_definition -> 'channels' ->> 'pos'\)::boolean\s+else false/)
})

test('the response is { tenant: { slug, name }, products } in the established product shape, with nothing private', () => {
  assert.match(body, /jsonb_build_object\('slug', t\.slug, 'name', t\.name\)/, 'no tenant id')
  assert.match(body, /jsonb_build_object\(\s*'tenant', v_tenant,\s*'products', coalesce\(/)
  // Same shape as the public catalogue (customer_definition + id, name, description, pricingVersion), minus the internal commerce id.
  assert.match(body, /\(c\.customer_definition - 'pricingDefinition' - 'pricing_definition' - 'commerceProductId'\) \|\|\s+jsonb_build_object\(\s*'id', c\.source_key,\s*'name', p\.name,\s*'description', coalesce\(p\.description, c\.customer_definition ->> 'description'\),\s*'pricingVersion', c\.pricing_version\s*\)/)
  const publicCatalogue = read('../supabase/migrations/20260926120000_cafe_guest_01d_public_catalogue_storefront_filter.sql')
  assert.match(publicCatalogue, /c\.customer_definition \|\|\s+jsonb_build_object\(\s*'id', c\.source_key,\s*'commerceProductId', p\.id,\s*'name', p\.name,\s*'description', coalesce\(p\.description, c\.customer_definition->>'description'\),\s*'pricingVersion', c\.pricing_version/)
  // The body never reads the staff-only pricing definition or any private column.
  assert.doesNotMatch(body, /\b[cp]\.pricing_definition\b/)
  assert.doesNotMatch(body.replace(/'[^']*'/g, "''"), /supplier|reference|margin|vat|source_?url|finance/i)
  assert.doesNotMatch(body, /tenant_memberships|tenant_role|capabilit(?:y|ies)[^_]*jsonb_build/i, 'no authorization metadata in the response')
  // The request-versus-order distinction stays in the front end.
  assert.doesNotMatch(body, /ENQUIRY|PHOTOGRAPHY_SESSION|serviceType|'request'|'order'/)
})

test('the migration adds only this function: no table, no write, no other function, and depends on the OPPS access layer', () => {
  assert.deepEqual([...code.matchAll(/create (?:or replace )?function ([\w.]+)/gi)].map((match) => match[1]), ['public.get_quick_solution_counter_catalog'])
  const bare = code.replace(/'(?:[^']|'')*'/g, "''")
  assert.doesNotMatch(bare, /\b(insert|update|delete|alter|drop|truncate)\b/i)
  assert.doesNotMatch(bare, /\bcreate\s+(?:or replace\s+)?(?:table|trigger|policy|index|view|type)\b/i)
  assert.match(code, /to_regprocedure\('public\.has_tenant_capability\(uuid,text\)'\) is null/)
  assert.match(code, /to_regprocedure\('commerce\._qs_product_channel_enabled\(uuid,text,text\)'\) is null/)
  // No order, payment, receipt, customer or production logic.
  assert.doesNotMatch(code, /service_orders|service_order_items|payment|receipt|handoff/i)
})

test('the client seed and the server rule agree on which products are counter products', () => {
  const expected = sqlTest.match(/v_expected_ids := array\[([^\]]*)\]/)[1].match(/'([^']+)'/g).map((item) => item.replace(/'/g, '')).sort()
  assert.equal(expected.length, 12)
  // What the pure front-end module derives from the client seed equals what the server test expects the RPC to return.
  assert.deepEqual(resolveCounterCatalogue(products).map((entry) => entry.product.id).sort(), expected)
  assert.deepEqual(products.filter(isCounterProduct).map((product) => product.id).sort(), expected)
  assert.equal(expected.includes('lamination'), false, 'the retired generic placeholder is not a counter product')
  for (const id of ['scan', 'a4-lamination', 'a3-lamination']) {
    const product = products.find((item) => item.id === id)
    assert.equal(product.channels.storefront, false)
    assert.equal(product.channels.pos, true)
    assert.equal(resolveCounterAction(product), 'order')
    assert.equal(resolveCounterGroup(product), 'Quick Services')
  }
})

test('the counter module can consume the RPC shape as is: request/order is derived from customer-safe fields only', () => {
  const rpcProduct = (product) => { const { pricingVersion, ...customerDefinition } = product; return { ...customerDefinition, id: product.id, pricingVersion } }
  const derived = resolveCounterCatalogue(products.map(rpcProduct)).map((entry) => [entry.product.id, entry.action]).sort()
  assert.deepEqual(derived.filter(([, action]) => action === 'request').map(([id]) => id), ['media-services', 'photo-session'])
  assert.equal(derived.length, 12)
  // Nothing private is needed: none of these product objects carries a private pricing field.
  for (const product of products) assert.doesNotMatch(JSON.stringify(product), /pricing_definition|pricingDefinition|supplierCost|referencePrice|marginRate|sourceUrl/i, product.id)
})

test('the SQL contract test covers access, module/tenant state, eligibility, privacy and regression under real roles, rollback-contained', () => {
  const sql = sqlTest.replace(/--[^\n]*/g, '')
  assert.match(sql, /\\set ON_ERROR_STOP on\s*\n\s*begin;/)
  assert.match(sql, /\brollback;\s*\n\s*select 'CAFE-GUEST-01L .* passed' as result;/)
  assert.doesNotMatch(sql, /^\s*commit\s*;/im)
  for (const required of [
    /set local role authenticated/, /set local role %I/, /'anon', 'service_role'/,
    /anonymous \(no identity\)/, /authenticated non-member/, /active member/, /active admin/, /active owner/, /suspended member/,
    /owner of a FOREIGN tenant/, /app admin with no Cafe membership/, /app admin with the approved-owner email/, /OPPS staff with no Cafe membership/,
    /passing a tenant must be impossible/, /passing a tenant id must be impossible/,
    /a disabled quick_solution module must deny/, /a MISSING quick_solution module row must deny/, /an unauthorized actor must get the access error, never the module state/,
    /Cafe tenant must fail closed with the tenant-not-found error/, /a just-suspended admin must be denied/,
    /the retired generic lamination must not appear/, /another tenant''s product must never appear/, /must keep its counter-only channels/,
    /the payload must not contain/, /no product may carry pricingDefinition/, /identical to the public catalogue apart from its commerce id/,
    /the RPC must write nothing/, /the public storefront catalogue must be unchanged/, /the admin catalogue must be unchanged/,
    /capability semantics must be unchanged/, /eligibility mismatch/, /stray pricingDefinition \/ commerceProductId keys must be stripped/
  ]) assert.match(sql, required)
  // The eligibility matrix includes every malformed pos and every non-sellable lifecycle state.
  for (const key of ['v-pos-false', 'v-pos-missing', 'v-channels-missing', 'v-pos-string-true', 'v-pos-number', 'v-pos-null', 'v-pos-object', 'v-pos-array',
    'v-config-draft', 'v-config-archived', 'v-product-draft', 'v-product-archived', 'v-product-unavailable', 'v-product-out-of-stock', 'v-product-preorder',
    'v-active-false', 'v-active-string-yes', 'v-active-string-true', 'v-ok-storefront-off', 'v-stray-private-keys']) {
    assert.ok(sql.includes(`"key":"${key}"`), key)
  }
})

test('since 01M the eligibility rule lives in one shared predicate that the catalogue asks (result unchanged)', () => {
  const create = read('../supabase/migrations/20260926220000_cafe_guest_01m_counter_create_order_rpc.sql').replace(/--[^\n]*/g, '')
  const predicate = create.match(/create or replace function commerce\._qs_product_counter_sellable\([\s\S]*?\n\$\$;/)[0]
  // The predicate holds exactly the 01L rule, clause for clause.
  for (const clause of ["c.status = 'published'", "p.status = 'published'", "p.availability = 'available'", "commerce._qs_product_channel_enabled(c.tenant_id, c.source_key, 'counter')"]) {
    assert.ok(predicate.includes(clause), clause)
    assert.ok(code.includes(clause), `01L: ${clause}`)
  }
  assert.ok(predicate.includes("case coalesce(jsonb_typeof(c.customer_definition -> 'active'), 'null')"))
  assert.doesNotMatch(predicate, /storefront/i)
  // The catalogue is redefined with the identical shape, asking the predicate.
  const catalogue = create.match(/create or replace function public\.get_quick_solution_counter_catalog\(\)[\s\S]*?\n\$\$;/)[0]
  assert.match(catalogue, /commerce\._qs_product_counter_sellable\(c\.tenant_id, c\.source_key\)/)
  assert.doesNotMatch(catalogue, /c\.status = 'published'|p\.availability|_qs_product_channel_enabled/, 'no second copy of the rule')
  assert.equal(catalogue.replace(/\s+/g, ' ').replace(/\s*and commerce\._qs_product_counter_sellable\(c\.tenant_id, c\.source_key\)/, ''), fn.replace(/\s+/g, ' ').replace(/\s*and c\.status = 'published' and p\.status = 'published' and p\.availability = 'available' and commerce\._qs_product_channel_enabled\(c\.tenant_id, c\.source_key, 'counter'\) and case coalesce\(jsonb_typeof\(c\.customer_definition -> 'active'\), 'null'\) when 'null' then true when 'boolean' then \(c\.customer_definition ->> 'active'\)::boolean else false end/, ''), 'apart from the eligibility clauses the catalogue body is unchanged')
})

test('the harness runs it, and skips it visibly when the OPPS access layer it depends on is absent', () => {
  const runner = read('../supabase/tests/harness/run-local-sql-tests.ps1')
  assert.match(runner, /-not \$accessPresent -and \$file\.Origin -eq '' -and \(Select-String -Path \$file\.Path -Pattern 'has_tenant_capability' -Quiet\)/)
  assert.match(runner, /-not \$accessPresent -and \$test\.Origin -eq '' -and \(Select-String -Path \$test\.FullName -Pattern 'has_tenant_capability' -Quiet\)/)
  assert.match(runner, /needs the OPPS access layer/)
})

test('the client wrapper has no tenant argument and one caller, the read-only /counter page', () => {
  const api = read('../src/lib/supabaseApi.js')
  const wrapper = api.match(/export async function loadQuickSolutionCounterCatalog\(\) \{[\s\S]*?\n\}/)[0]
  assert.match(wrapper, /return rpc\('get_quick_solution_counter_catalog', \{\}, \{ accessToken \}\)/, 'no tenant is sent')
  const walk = (dir, out = []) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const next = new URL(`${entry.name}${entry.isDirectory() ? '/' : ''}`, dir)
      if (entry.isDirectory()) walk(next, out)
      else if (/\.(jsx?|css)$/.test(entry.name)) out.push({ name: entry.name, text: fs.readFileSync(next, 'utf8') })
    }
    return out
  }
  const users = walk(new URL('../src/', import.meta.url)).filter((file) => /loadQuickSolutionCounterCatalog|get_quick_solution_counter_catalog/.test(file.text)).map((file) => file.name)
  assert.deepEqual(users, ['CounterPage.jsx', 'supabaseApi.js'], 'since 01N exactly one caller: the read-only /counter page')
  assert.equal((read('../src/lib/navigation.js').match(/counter/gi) || []).length, 3, 'the /counter route and nothing else')
})

test('the new test file is part of npm test', () => {
  assert.match(JSON.parse(read('../package.json')).scripts.test, /tests\/counter-catalogue-rpc\.test\.mjs/)
})
