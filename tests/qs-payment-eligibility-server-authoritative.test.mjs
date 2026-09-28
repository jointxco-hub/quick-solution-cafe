import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'

// QS Payment Eligibility v1 - closing the four pre-production gaps:
// 1. PayFast eligibility (the R50 minimum and the per-line allowPayfast
//    flag) is enforced server-side in commerce.qs_begin_payfast_payment,
//    not just in the storefront UI.
// 2. Counter POS can locate a storefront "pay at counter" order, by its
//    explicit pending counter-intent row - never by broadening to every
//    storefront unpaid order.
// 3. EFT bank details are tenant-scoped and never hardcoded in a
//    component; if incomplete, EFT stays unavailable (covered by
//    tests/payment-eligibility.test.mjs's isEftBankDetailsComplete cases).
//
// No live database is available in this run (see the accompanying report),
// so - exactly like this repo's other migration-contract tests
// (tests/cafe-guest-01c-channel-guard.test.mjs etc.) - these read the
// migration file as text and prove its structure, not its runtime
// behavior on a real Postgres instance.

const migrationPath = new URL('../supabase/migrations/20260928170000_qs_payment_eligibility_v1.sql', import.meta.url)
const migration = fs.readFileSync(migrationPath, 'utf8')
const stripComments = (sql) => sql.replace(/--[^\n]*/g, '')
const code = stripComments(migration)

function functionBlock(schema, name) {
  const pattern = new RegExp(`create\\s+or\\s+replace\\s+function\\s+${schema}\\.${name}\\([\\s\\S]*?\\n\\$\\$;`, 'i')
  const match = code.match(pattern)
  assert.ok(match, `${schema}.${name} definition not found in the migration`)
  return match[0]
}

// ── 1. Server-authoritative PayFast eligibility ─────────────────────────
const beginPayfast = functionBlock('commerce', 'qs_begin_payfast_payment')

test('commerce.qs_begin_payfast_payment keeps its original signature - no client-submitted amount/eligibility field can be added or trusted', () => {
  assert.match(beginPayfast, /qs_begin_payfast_payment\(\s*p_order_id uuid,\s*p_payment_token text\s*\)/)
})

test('commerce.qs_begin_payfast_payment rejects an order below the tenant\'s configured minimum, read from server-held tenant settings only', () => {
  assert.match(beginPayfast, /payfastMinimumAmount/)
  assert.match(beginPayfast, /v_order\.total_amount\s*<\s*v_minimum/)
  assert.match(beginPayfast, /'reason','below_minimum'/)
})

test('commerce.qs_begin_payfast_payment derives per-line PayFast eligibility from the order\'s own items joined to their server-side product config, never from the request payload', () => {
  assert.match(beginPayfast, /from\s+commerce\.service_order_items\s+soi\s*\n\s*join\s+commerce\.service_product_configs\s+spc/i)
  assert.match(beginPayfast, /spc\.customer_definition->'paymentEligibility'->>'allowPayfast'/)
  assert.match(beginPayfast, /'reason','payfast_not_allowed'/)
})

test('commerce.qs_begin_payfast_payment fails closed if a line\'s product config cannot be found at all, rather than defaulting it to allowed', () => {
  assert.match(beginPayfast, /count\(\*\)\s*=\s*\(select count\(\*\) from commerce\.service_order_items where order_id = v_order\.id\)/)
  assert.match(beginPayfast, /coalesce\(v_all_allow_payfast,\s*false\)/)
})

test('the public quick-solution-payfast Edge Function trusts only order_id/payment_token from the client - amount and eligibility always come back from the RPC, never from the request body', () => {
  const source = fs.readFileSync(new URL('../supabase/functions/quick-solution-payfast/index.ts', import.meta.url), 'utf8')
  assert.match(source, /const orderId = String\(body\?\.order_id/)
  assert.match(source, /const paymentToken = String\(body\?\.payment_token/)
  assert.doesNotMatch(source, /body\?\.amount/)
  assert.doesNotMatch(source, /body\?\.eligib/i)
  assert.match(source, /const amount = Number\(intent\.amount\)/, 'the amount charged is whatever the RPC returned for the real order, not the request')
})

// ── 2. Counter POS operational for storefront "pay at counter" orders ──
for (const [schema, name] of [
  ['public', 'list_quick_solution_counter_orders_today'],
  ['public', 'list_quick_solution_unpaid_counter_orders'],
  ['public', 'record_quick_solution_counter_payment']
]) {
  test(`${name} finds a storefront order explicitly by its pending counter intent, never by broadening to every unpaid storefront order`, () => {
    const block = functionBlock(schema, name)
    assert.match(block, /so\.channel = 'counter'/)
    assert.match(block, /p\.provider = 'counter'\s*\n\s*and p\.status = 'pending'/)
    assert.doesNotMatch(block, /payment_status\s*(=|in)\s*.*unpaid.*or.*channel/is, 'never an OR on payment_status alone - must be the explicit pending counter-intent row')
  })
}

test('record_quick_solution_counter_payment still records the real cash/card payment through the unchanged completed-payment mechanism', () => {
  assert.match(beginPayfast, /.*/) // sanity: file parsed
  const block = functionBlock('public', 'record_quick_solution_counter_payment')
  assert.match(block, /provider, status, amount, initiated_at, completed_at, recorded_by, idempotency_key/)
  assert.match(block, /v_tenant_id, v_order\.id, p_method, 'completed', v_amount/)
})

test('record_quick_solution_counter_payment never treats the pending counter intent as money received, and cancels (never deletes) it once the real payment settles - an audit trail survives', () => {
  const block = functionBlock('public', 'record_quick_solution_counter_payment')
  const paymentInsertIndex = block.indexOf("'completed', v_amount")
  const cancelIndex = block.indexOf("status = 'cancelled'")
  assert.ok(paymentInsertIndex > -1 && cancelIndex > paymentInsertIndex, 'the pending counter intent is cancelled AFTER the real payment is recorded, not instead of it')
  assert.match(block.slice(cancelIndex - 80, cancelIndex + 120), /update commerce\.service_order_payments\s*\n\s*set status = 'cancelled'/)
  assert.doesNotMatch(block.slice(cancelIndex - 80, cancelIndex + 200), /delete from/i)
})

test('record_quick_solution_counter_payment cannot create a duplicate completed payment - the existing idempotency-key replay guard is untouched', () => {
  const block = functionBlock('public', 'record_quick_solution_counter_payment')
  assert.match(block, /v_stored_key := 'counter-payment:' \|\| v_actor::text \|\| ':' \|\| v_key;/)
  assert.match(block, /pg_advisory_xact_lock/)
})

// ── Hash-pinning discipline ──────────────────────────────────────────────
// Whitespace-insensitive: staging's live commerce.qs_begin_payfast_payment
// was reformatted by an earlier reconciliation pass (same logic,
// different jsonb_build_object line-wrapping), and the three Counter POS
// RPCs differ from this git checkout only by CRLF vs LF - both confirmed,
// by direct diff against staging, to be content-identical once whitespace
// is ignored. A raw (whitespace-sensitive) hash would false-fail on both.
test('the migration pins the exact pre-change hash of every function it replaces, and refuses to run against a drifted copy', () => {
  assert.match(code, /regexp_replace\(p\.prosrc, '\\s\+', '', 'g'\)/)
  assert.match(code, /'commerce','qs_begin_payfast_payment','75bccb72312c013d0d1a8dd12695ba80'/)
  assert.match(code, /'public','list_quick_solution_counter_orders_today','b49539ed742d5cd281bc01c4c70812d1'/)
  assert.match(code, /'public','list_quick_solution_unpaid_counter_orders','2afc9b86aa0cc556d5f8ff9b25f34f88'/)
  assert.match(code, /'public','record_quick_solution_counter_payment','22bb17aa5718a930883f5c5904c9a375'/)
})

// ── 3. EFT config is tenant-scoped, never a git-committed literal ───────
test('the migration never commits a real bank account number/holder as a literal - it only reserves the eftBankDetails shape', () => {
  assert.doesNotMatch(code, /6310357/)
  assert.doesNotMatch(code, /K2021866615/)
  assert.doesNotMatch(code, /Gold Business Account/)
  assert.match(code, /eftBankDetails/)
})

test('no React/JS source file hardcodes the real EFT bank details - they only ever come from paymentConfig.eftBankDetails', () => {
  const files = ['../src/App.jsx', '../src/components/OrderBasket.jsx', '../src/lib/paymentEligibility.js', '../src/admin/AdminProductManager.jsx']
  for (const file of files) {
    const source = fs.readFileSync(new URL(file, import.meta.url), 'utf8')
    assert.doesNotMatch(source, /6310357/)
    assert.doesNotMatch(source, /FNB\/RMB/)
    assert.doesNotMatch(source, /Gold Business Account/)
  }
})
