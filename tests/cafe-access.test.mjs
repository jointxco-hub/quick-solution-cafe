import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'
import crypto from 'node:crypto'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

// CAFE-ACCESS-02 - static guards for the tenant-capability access layer and how the
// local SQL harness exercises it. The behavioral proof is SQL, run on a throwaway
// PostgreSQL by `npm run test:sql` (see the OPPS worktree's
// supabase/tests/cafe_access_01_*.sql and cafe_access_02_*.sql). These tests stop a later
// edit from weakening it, and check the capability text itself.
//
// The primitive (public.has_tenant_capability) is owned by the OPPS worktree, next to
// tenant_memberships. Tests that read it are SKIPPED, visibly, when that worktree is absent.

const read = (url) => fs.readFileSync(url, 'utf8').replace(/\r\n/g, '\n')
const cafe = (relative) => new URL(`../${relative}`, import.meta.url)
const runner = read(cafe('supabase/tests/harness/run-local-sql-tests.ps1'))
const stub = read(cafe('supabase/tests/harness/00_opps_base_stub.sql'))
const runnerCode = runner.replace(/<#[\s\S]*?#>/, '').replace(/^\s*#.*$/gm, '')

const oppsRoot = process.env.OPPS_ACCESS_REPO || path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', 'opps-xos-2-7c-test-order-hygiene')
const opps = (relative) => path.join(oppsRoot, relative)
const oppsPresent = ['supabase/migrations', 'supabase/tests'].every((dir) => fs.existsSync(opps(dir)))
const cross = { skip: oppsPresent ? false : `OPPS worktree not found at ${oppsRoot} (set OPPS_ACCESS_REPO)` }

const M1 = 'supabase/migrations/20260924232724_cafe_access_01_tenant_capability_operations.sql'
const M2 = 'supabase/migrations/20260926190000_cafe_access_02_counter_operate_capability.sql'
const T1 = 'supabase/tests/cafe_access_01_tenant_capability_operations.sql'
const M3 = 'supabase/migrations/20260926200000_cafe_access_03_counter_operate_members.sql'
const T2 = 'supabase/tests/cafe_access_02_counter_operate_capability.sql'
const T3 = 'supabase/tests/cafe_access_03_counter_operate_members.sql'
const oppsText = (relative) => fs.readFileSync(opps(relative), 'utf8').replace(/\r\n/g, '\n')
const stripSqlComments = (sql) => sql.replace(/--[^\n]*/g, '')
const sha256 = (text) => crypto.createHash('sha256').update(text).digest('hex')

// ── the harness exercises the access layer, read-only ───────────────────
test('the runner replays the OPPS access migrations by version and runs their SQL tests, reading that worktree only', () => {
  assert.match(runnerCode, /\[string\]\$OppsAccessRepo/)
  assert.match(runnerCode, /opps-xos-2-7c-test-order-hygiene/)
  assert.match(runnerCode, /'cafe_access_\*\.sql'/)
  assert.match(runnerCode, /'\*_cafe_access_\*\.sql'/)
  assert.match(runnerCode, /foreach \(\$file in \(\$files \| Sort-Object \{ \$_\.Name \}\)\)/, 'merged and ordered by version timestamp')
  // Only the files whose names say cafe_access: never a wildcard over another repo's history.
  assert.doesNotMatch(runnerCode, /\$oppsAccessMigrations[^\n]*-Filter\s+\*\.sql/)
  // Absent worktree: an explicit SKIP result, never a silent pass or a failure.
  assert.match(runnerCode, /Add-Result 'access' 'OPPS access layer \(public\.has_tenant_capability\)' 'SKIP'/)
  // Read-only: nothing is written to, removed from or executed against the OPPS worktree.
  for (const line of runnerCode.split('\n').filter((item) => /OppsAccessRepo|oppsAccess/.test(item))) {
    assert.doesNotMatch(line, /Set-Content|Out-File|Remove-Item|Copy-Item|Move-Item|New-Item|git /i, line.trim())
  }
  assert.doesNotMatch(runnerCode, /Remove-Item[^\n]*(Opps|opps)/)
})

test('the base stub reproduces the two real OPPS triggers on public.users the access tests depend on, verbatim', () => {
  assert.match(stub, /create or replace function public\.enforce_approved_admin_role_change\(\)/)
  assert.match(stub, /raise exception 'Only approved owners can assign administrator access\.'/)
  assert.match(stub, /raise exception 'Only approved owners can change administrator access\.'/)
  assert.match(stub, /create trigger trg_users_enforce_admin_role_change\s+before insert or update of role on public\.users/)
  assert.match(stub, /create or replace function public\.add_internal_user_to_joint_x_team\(\)/)
  assert.match(stub, /case when new\.role = 'admin' then 'admin' else 'member' end, 'active'/)
  assert.match(stub, /create trigger trg_internal_user_joint_x_membership\s+after insert or update of auth_user_id, is_active, role on public\.users/)
  // The fixtures' auth.users / public.users columns.
  for (const column of ['aud text', 'email_confirmed_at timestamptz', 'raw_app_meta_data jsonb', 'raw_user_meta_data jsonb', 'user_email text', 'full_name text']) {
    assert.ok(stub.includes(column), column)
  }
})

// ── the counter RPC inventory: exactly these, and no capability named in the front end ─────
test('exactly eleven counter RPCs exist (catalogue, single-item create, orders of the day, order detail, full payment, the cash-up of today, unpaid orders, the dated cash-up, the cancel check, the cancel and the cancelled list), and the front end never names a capability', () => {
  const migrationsDir = cafe('supabase/migrations/')
  const migrations = fs.readdirSync(migrationsDir).filter((name) => name.endsWith('.sql'))
  const users = []
  const counterFunctions = []
  for (const name of migrations) {
    const code = stripSqlComments(read(new URL(name, migrationsDir)))
    if (/has_tenant_capability|cafe\.counter\.operate/.test(code)) users.push(name)
    for (const match of code.matchAll(/create (?:or replace )?function ([\w.]*counter[\w.]*)/gi)) counterFunctions.push(`${name}: ${match[1]}`)
  }
  // The primitive is owned by the OPPS worktree; the Cafe consumers are the counter catalogue (01L) and the counter-create RPC (01M).
  assert.deepEqual(users, ['20260926210000_cafe_guest_01l_counter_catalogue_rpc.sql', '20260926220000_cafe_guest_01m_counter_create_order_rpc.sql', '20260926230000_cafe_guest_01p_counter_orders_today_rpc.sql', '20260926240000_cafe_guest_01q_counter_order_detail_and_payment.sql', '20260926250000_cafe_guest_01s_counter_cashup_today_rpc.sql', '20260926260000_cafe_guest_01t_unpaid_counter_orders_rpc.sql', '20260926270000_cafe_guest_01u_dated_counter_cashup.sql', '20260926280000_cafe_guest_01v_cancel_unpaid_counter_order.sql', '20260926290000_cafe_guest_01w_cancelled_counter_orders_rpc.sql'])
  assert.deepEqual(counterFunctions, [
    '20260926210000_cafe_guest_01l_counter_catalogue_rpc.sql: public.get_quick_solution_counter_catalog',
    '20260926220000_cafe_guest_01m_counter_create_order_rpc.sql: commerce._qs_product_counter_sellable',
    '20260926220000_cafe_guest_01m_counter_create_order_rpc.sql: public.get_quick_solution_counter_catalog',
    '20260926220000_cafe_guest_01m_counter_create_order_rpc.sql: public.create_quick_solution_counter_order',
    '20260926230000_cafe_guest_01p_counter_orders_today_rpc.sql: commerce._qs_counter_business_day',
    '20260926230000_cafe_guest_01p_counter_orders_today_rpc.sql: public.list_quick_solution_counter_orders_today',
    '20260926240000_cafe_guest_01q_counter_order_detail_and_payment.sql: commerce._qs_counter_payment_block',
    '20260926240000_cafe_guest_01q_counter_order_detail_and_payment.sql: public.get_quick_solution_counter_order',
    '20260926240000_cafe_guest_01q_counter_order_detail_and_payment.sql: public.record_quick_solution_counter_payment',
    '20260926250000_cafe_guest_01s_counter_cashup_today_rpc.sql: public.get_quick_solution_counter_cashup_today',
    '20260926260000_cafe_guest_01t_unpaid_counter_orders_rpc.sql: public.list_quick_solution_unpaid_counter_orders',
    '20260926270000_cafe_guest_01u_dated_counter_cashup.sql: commerce._qs_counter_business_day_of',
    '20260926270000_cafe_guest_01u_dated_counter_cashup.sql: commerce._qs_counter_cashup',
    '20260926270000_cafe_guest_01u_dated_counter_cashup.sql: public.get_quick_solution_counter_cashup_today',
    '20260926270000_cafe_guest_01u_dated_counter_cashup.sql: public.get_quick_solution_counter_cashup',
    '20260926280000_cafe_guest_01v_cancel_unpaid_counter_order.sql: commerce._qs_counter_cancel_block',
    '20260926280000_cafe_guest_01v_cancel_unpaid_counter_order.sql: public.get_quick_solution_counter_order_cancel_check',
    '20260926280000_cafe_guest_01v_cancel_unpaid_counter_order.sql: public.cancel_quick_solution_counter_order',
    '20260926290000_cafe_guest_01w_cancelled_counter_orders_rpc.sql: public.list_quick_solution_cancelled_counter_orders'
  ], 'no other counter RPC: no multi-item, refund, void or request creation yet (a receipt is read-only and needs none)')
  const walk = (dir, out = []) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const next = new URL(`${entry.name}${entry.isDirectory() ? '/' : ''}`, dir)
      if (entry.isDirectory()) walk(next, out)
      else if (/\.(jsx?|css)$/.test(entry.name)) out.push({ name: entry.name, text: fs.readFileSync(next, 'utf8') })
    }
    return out
  }
  const offenders = walk(cafe('src/')).filter((file) => /has_tenant_capability|cafe\.counter\.operate|cafe\.operations\.manage/.test(file.text)).map((file) => file.name)
  assert.deepEqual(offenders, [], 'authorization is server-side: the front end never names a capability')
})

// ── the capability text itself (OPPS worktree) ──────────────────────────
test('CAFE-ACCESS-01 is unchanged: its migration and test are byte-identical (LF-normalized) to what was reviewed', cross, () => {
  assert.equal(sha256(oppsText(M1)), 'd062949f608719baaeea5724078e6a04c3a757a6a3dee1fe2095a4808e1e929c')
  assert.equal(sha256(oppsText(T1)), '258d089dce46b27b9999c1d4c576a6ca2336ac00d3562155c73cf94aa85eca38')
})

test('cafe.counter.operate is a separate, exactly named capability: active owner/admin/member of an active tenant, fail closed', cross, () => {
  const sql = stripSqlComments(oppsText(M3))
  const fn = sql.match(/create or replace function public\.has_tenant_capability\([\s\S]*?\n\$\$;/)[0]
  // Exactly two capability names, and nothing that wildcards or normalizes them.
  assert.deepEqual([...new Set([...fn.matchAll(/'(cafe\.[a-z.]+)'/g)].map((match) => match[1]))].sort(), ['cafe.counter.operate', 'cafe.operations.manage'])
  assert.match(fn, /and p_capability in \('cafe\.operations\.manage', 'cafe\.counter\.operate'\)/)
  assert.doesNotMatch(fn, /lower\(|upper\(|\blike\b|ilike|~/i)
  // Two separate CASE arms and an else that denies. Only the counter arm admits a plain member;
  // cafe.operations.manage is NOT broadened and stays exactly active owner/admin.
  assert.match(fn, /when 'cafe\.operations\.manage' then membership\.tenant_role in \('owner', 'admin'\)/)
  assert.match(fn, /when 'cafe\.counter\.operate' then membership\.tenant_role in \('owner', 'admin', 'member'\)/)
  assert.match(fn, /else false\s+end/)
  assert.equal((fn.match(/'member'/g) || []).length, 1, 'the role member appears only in the counter arm')
  // Membership-derived only, scoped to the asked tenant, identity from the JWT, active tenant and membership.
  assert.match(fn, /membership\.tenant_id = p_tenant_id/)
  assert.match(fn, /membership\.auth_user_id = auth\.uid\(\)/)
  assert.match(fn, /membership\.status = 'active'/)
  assert.match(fn, /tenant\.status = 'active'/)
  assert.match(fn, /auth\.uid\(\) is not null/)
  assert.match(fn, /p_tenant_id is not null/)
  assert.doesNotMatch(fn, /is_app_admin|is_opps_staff|can_access_tenant|tenant_capabilities/, 'no app-admin or OPPS-staff bypass, no module table')
  // Never NULL.
  assert.match(fn, /select coalesce\([\s\S]*\),\s*false\s*\)\s*;/)
})

test('cafe.operations.manage keeps exactly the CAFE-ACCESS-01 rule; properties and ACL are unchanged', cross, () => {
  const old = stripSqlComments(oppsText(M1))
  const next = stripSqlComments(oppsText(M3))
  const roles = (sql) => sql.match(/tenant_role in \(([^)]*)\)/)[1].replace(/\s+/g, ' ').trim()
  assert.equal(roles(old), "'owner', 'admin'")
  assert.equal(roles(next), "'owner', 'admin'")
  for (const sql of [old, next]) {
    assert.match(sql, /language sql\s+stable\s+security definer\s+set search_path = ''/)
    assert.match(sql, /revoke all on function public\.has_tenant_capability\(uuid, text\)\s+from public, anon, authenticated, service_role;/)
    assert.match(sql, /grant execute on function public\.has_tenant_capability\(uuid, text\)\s+to authenticated;/)
  }
  // 03 changes only the primitive: no other function, table or grant.
  assert.deepEqual([...next.matchAll(/create (?:or replace )?function ([\w.]+)/gi)].map((match) => match[1]), ['public.has_tenant_capability'])
  assert.doesNotMatch(next, /create\s+(table|trigger|policy|index|view|type)|alter\s+table|\binsert\b|\bdelete\b|\bupdate\b/i)
  assert.match(next, /to_regprocedure\('public\.has_tenant_capability\(uuid,text\)'\) is null/, 'preflight requires the CAFE-ACCESS-01 primitive')
  // The handoff RPC is not redefined here, so it still requires cafe.operations.manage only.
  assert.doesNotMatch(next, /admin_list_quick_solution_opps_handoffs/)
  assert.match(old, /has_tenant_capability\(v_tenant_id, 'cafe\.operations\.manage'\)/)
})

test('CAFE-ACCESS-02 is left as history (owner/admin counter arm), superseded by the forward CAFE-ACCESS-03 migration', cross, () => {
  assert.equal(sha256(oppsText(M2)), '3ee29ad07f5387bc93cc1993fc36fff3990313a541fa39aec874b46b37ba4ad9')
  const two = stripSqlComments(oppsText(M2))
  assert.match(two, /when 'cafe\.counter\.operate' then membership\.tenant_role in \('owner', 'admin'\)/)
  const three = oppsText(M3)
  assert.match(three, /Decision \(confirmed by the business owner\)/)
  assert.match(three, /cafe\.operations\.manage is NOT broadened/)
  for (const need of ['product or pricing', 'finance', 'tenant administration', 'user or role administration', 'general\n-- OPPS access', 'app-admin behavior']) assert.ok(three.includes(need), need)
  // Only the counter arm's role list differs between 02 and 03 (both function bodies, comments stripped).
  const body = (sql) => sql.match(/create or replace function public\.has_tenant_capability\([\s\S]*?\n\$\$;/)[0]
  assert.equal(body(stripSqlComments(oppsText(M3))), body(two).replace("when 'cafe.counter.operate' then membership.tenant_role in ('owner', 'admin')", "when 'cafe.counter.operate' then membership.tenant_role in ('owner', 'admin', 'member')"))
})

test('a future counter RPC can rely on the capability server-side, and the migration says how', cross, () => {
  const text = oppsText(M2)
  assert.match(text, /if not public\.has_tenant_capability\(v_tenant_id, 'cafe\.counter\.operate'\) then/)
  assert.match(text, /SERVER-SIDE/)
  assert.match(text, /not module-aware/, 'the tenant-scoped, not module-aware caveat is recorded for RPC authors')
  assert.match(text, /NULL/, 'the NULL fail-open fix is recorded')
})

test('the CAFE-ACCESS-02 SQL test pins every persona and posture under the real API roles, rollback-contained', cross, () => {
  const sql = oppsText(T2)
  const code = stripSqlComments(sql)
  assert.match(code, /\\set ON_ERROR_STOP on\s*\n\s*begin;/)
  assert.match(code, /\brollback;\s*\n\s*select 'CAFE-ACCESS-02 .* passed' as result;/)
  assert.doesNotMatch(code, /^\s*commit\s*;/im)
  for (const required of [
    /set local role authenticated/, /set local role anon/, /set local role %I/, /'anon', 'service_role'/,
    /anonymous \(no identity\)/, /authenticated non-staff, no membership anywhere/, /suspended owner of the target tenant/,
    /owner of ANOTHER tenant, asking about the target/, /positive control/, /target member \(counter yes, manage no\)/,
    /target admin/, /target owner/, /app admin \(users\.role admin\) with no target membership/, /approved-owner email claim/,
    /OPPS staff \(joint-x member\) with no target membership/, /OPPS staff plus a target member membership \(counter yes, manage no\)/, /target owner with a NULL tenant/,
    /a NULL capability must be exactly false/, /unknown capability/, /cafe\.counter\.operate /, /CAFE\.COUNTER\.OPERATE/,
    /a suspended tenant must deny even its owner/, /an archived tenant must deny even its owner/, /a just-suspended admin must lose/,
    /look-alike schema first in search_path/, /_cafe_access_02_probe_counter_rpc/, /Counter access is required\./,
    /an owner of tenant A must not pass the gate for tenant B/, /must not execute has_tenant_capability/,
    /the handoff list must still return a jsonb array/, /a member must still be denied the handoff list/, /an app admin without target membership must still be denied/
  ]) assert.match(code, required)
})

test('the SQL test for CAFE-ACCESS-03 proves every member scenario under the real API role, rollback-contained', cross, () => {
  const sql = oppsText(T3)
  const code = stripSqlComments(sql)
  assert.match(code, /\\set ON_ERROR_STOP on\s*\n\s*begin;/)
  assert.match(code, /\brollback;\s*\n\s*select 'CAFE-ACCESS-03 .* passed' as result;/)
  assert.doesNotMatch(code, /^\s*commit\s*;/im)
  assert.match(code, /set local role authenticated/)
  for (const required of [
    /an active member must hold cafe\.counter\.operate/, /the SAME member must still be denied cafe\.operations\.manage/,
    /must be exactly false for a member/, /a NULL capability must be exactly false for a member/, /a NULL tenant must be exactly false for a member/,
    /admin and owner must hold both capabilities/, /a member of tenant A must hold nothing in tenant B/,
    /a member of ANOTHER tenant must hold nothing in the target tenant/, /a suspended member must be denied/,
    /a member suspended a moment ago must lose the counter capability/, /a member of a suspended tenant must be denied/,
    /a member of an archived tenant must be denied/, /an app admin without a Cafe membership must be denied/,
    /OPPS staff without a Cafe membership must be denied/, /a member promoted to admin must gain cafe\.operations\.manage/,
    /demoted back to member, manage must go and the counter must stay/, /a member must not list OPPS handoffs/,
    /a member must not edit products or prices/, /a member must not read the staff-only catalogue/,
    /the role member may appear only in the counter arm/, /no other capability may exist/
  ]) assert.match(code, required)
  // Capability names a member must not gain, listed explicitly.
  for (const name of ['finance.read', 'products.manage', 'pricing.manage', 'tenant.admin', 'users.manage', 'roles.manage', 'opps.access', 'app.admin']) assert.ok(code.includes(`'${name}'`), name)
})

test('the migrations are ordered so the primitive exists first: 01 before the Cafe counter work, 02 and 03 after it', cross, () => {
  const oppsFiles = fs.readdirSync(opps('supabase/migrations')).filter((name) => /cafe_access_/.test(name)).sort()
  assert.deepEqual(oppsFiles, ['20260924232724_cafe_access_01_tenant_capability_operations.sql', '20260926190000_cafe_access_02_counter_operate_capability.sql', '20260926200000_cafe_access_03_counter_operate_members.sql'])
  const cafeFiles = fs.readdirSync(cafe('supabase/migrations/')).filter((name) => name.endsWith('.sql')).sort()
  const taken = new Set(['20260924232724', '20260926190000', '20260926200000'])
  assert.ok(cafeFiles.every((name) => !taken.has(name.slice(0, 14))), 'no version collision across the two repos')
  // The Cafe migrations that depend on the primitive (01L, 01M, 01P, 01Q, 01S, 01T, 01U) sort after all three access migrations.
  assert.deepEqual(cafeFiles.slice(-9), ['20260926210000_cafe_guest_01l_counter_catalogue_rpc.sql', '20260926220000_cafe_guest_01m_counter_create_order_rpc.sql', '20260926230000_cafe_guest_01p_counter_orders_today_rpc.sql', '20260926240000_cafe_guest_01q_counter_order_detail_and_payment.sql', '20260926250000_cafe_guest_01s_counter_cashup_today_rpc.sql', '20260926260000_cafe_guest_01t_unpaid_counter_orders_rpc.sql', '20260926270000_cafe_guest_01u_dated_counter_cashup.sql', '20260926280000_cafe_guest_01v_cancel_unpaid_counter_order.sql', '20260926290000_cafe_guest_01w_cancelled_counter_orders_rpc.sql'])
  assert.ok(cafeFiles.at(-9).slice(0, 14) > '20260926200000')
  assert.ok(cafeFiles.at(-10).slice(0, 14) < '20260926190000', 'everything before them is independent of the access layer')
})

test('the new test file is part of npm test', () => {
  assert.match(JSON.parse(read(cafe('package.json'))).scripts.test, /tests\/cafe-access\.test\.mjs/)
})
