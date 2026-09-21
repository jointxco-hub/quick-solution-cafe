#!/usr/bin/env bash
# Disposable pg16 proof for:
#   20260921090000_qs14_catalog_margin_photography.sql (SUPPLIER_MARGIN /
#   PHOTOGRAPHY_SESSION strategies in commerce.qs_calculate_price, the
#   admin_update_quick_solution_product strategy allow-list, and
#   create_quick_solution_service_request accepting PHOTOGRAPHY_SESSION)
#   20260921090500_qs14_catalog_data.sql (Flags / Gazebos / Quick Photo
#   Session catalogue rows, real supplier data)
#   20260921120000_qs14_checkout_guards_and_supplier_rules.sql (checkout
#   protection in the paid order/cart RPCs, per-variant minQuantity/
#   quantityStep + accessory compatibleVariants validation, server-side
#   regeneration of the customer-safe selling-price mirror on admin save)
#
# This is a LOCAL, DISPOSABLE container only. It never touches staging
# or production. Schema stub covers just enough of commerce.*/public.*
# for these migrations to apply and their RPCs to run.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
MIG1="$ROOT/supabase/migrations/20260921090000_qs14_catalog_margin_photography.sql"
MIG2="$ROOT/supabase/migrations/20260921090500_qs14_catalog_data.sql"
MIG3="$ROOT/supabase/migrations/20260921120000_qs14_checkout_guards_and_supplier_rules.sql"
CID="qs14-catalog-$$"
cleanup() { docker rm -f "$CID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --name "$CID" -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=m postgres:16-alpine >/dev/null
for i in $(seq 1 90); do docker exec "$CID" pg_isready -U postgres -d m -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 1; done
sleep 2
run() { docker exec -i "$CID" psql -X -v ON_ERROR_STOP=1 -U postgres -d m; }

run >/dev/null <<'SQL'
create extension if not exists pgcrypto;

do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin; end if;
end $$;

create schema if not exists auth;
create or replace function auth.uid() returns uuid language sql stable
  as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
create or replace function auth.email() returns text language sql stable
  as $$ select nullif(current_setting('test.email', true), '') $$;

create schema if not exists extensions;
create or replace function extensions.gen_random_bytes(int) returns bytea
  language sql as $$ select public.gen_random_bytes($1) $$;
create or replace function extensions.digest(text, text) returns bytea
  language sql as $$ select public.digest($1, $2) $$;

create schema if not exists commerce;

create table public.tenants (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null,
  name text not null,
  status text not null default 'active'
);

create table public.tenant_capabilities (
  tenant_id uuid not null references public.tenants(id),
  capability_key text not null,
  enabled boolean not null default true,
  primary key (tenant_id, capability_key)
);

-- Minimal always-true/false auth stubs — admin RPC authorization is not
-- the subject of this proof (tested at OPPS/tenant-RLS layer elsewhere).
create or replace function public.is_app_admin() returns boolean language sql stable as $$ select true $$;
create or replace function public.is_opps_staff() returns boolean language sql stable as $$ select true $$;
create or replace function public.can_access_tenant(p_tenant_id uuid) returns boolean language sql stable as $$ select true $$;

create table commerce.products (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  slug text not null,
  name text not null,
  description text,
  currency text not null default 'ZAR',
  availability text not null default 'available',
  status text not null default 'published',
  source_system text,
  source_ref text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, slug)
);

create table commerce.service_product_configs (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  product_id uuid not null references commerce.products(id),
  source_key text not null,
  customer_definition jsonb not null default '{}'::jsonb,
  pricing_version text not null,
  pricing_definition jsonb not null default '{}'::jsonb,
  status text not null default 'draft',
  sort_order int not null default 100,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, source_key)
);

create table commerce.service_orders (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  order_number text not null,
  status text not null default 'submitted',
  customer_name text not null,
  customer_email text,
  customer_phone text,
  fulfilment_type text,
  fulfilment_point_id uuid,
  delivery_address jsonb,
  subtotal numeric not null default 0,
  fulfilment_fee numeric not null default 0,
  total_amount numeric not null default 0,
  payment_status text not null default 'unpaid',
  idempotency_key text not null,
  customer_notes text,
  source_metadata jsonb not null default '{}'::jsonb,
  upload_token_hash text,
  upload_token_expires_at timestamptz,
  payment_token_hash text,
  payment_token_expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, idempotency_key)
);

create table commerce.service_order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references commerce.service_orders(id) on delete cascade,
  tenant_id uuid not null references public.tenants(id),
  product_id uuid not null references commerce.products(id),
  product_key text not null,
  product_name text not null,
  quantity numeric not null default 1,
  configuration jsonb not null default '{}'::jsonb,
  pricing_snapshot jsonb not null default '{}'::jsonb,
  line_total numeric not null default 0,
  client_item_key text,
  created_at timestamptz not null default now()
);

create table commerce.fulfilment_points (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  slug text,
  name text not null,
  kind text not null,
  status text not null default 'active',
  collection_enabled boolean not null default true,
  fee_amount numeric not null default 0,
  sort_order int not null default 100,
  address jsonb,
  contact_phone text,
  easy_locate_business_ref text,
  latitude numeric,
  longitude numeric,
  services jsonb,
  created_at timestamptz not null default now()
);

create or replace function commerce.qs_generate_order_number() returns text
  language sql as $$ select 'QSC-TEST-' || substr(gen_random_uuid()::text,1,8) $$;

create or replace function commerce.qs_issue_tracking_token(p_order_id uuid) returns jsonb
  language sql as $$ select jsonb_build_object('token', encode(public.gen_random_bytes(16),'hex'), 'expiresAt', (now() + interval '30 days')::text) $$;

-- Stub for the delegation target: proves unhandled strategies still
-- reach _legacy (existing PER_AREA/PER_PAGE/TIERED/CONFIGURABLE math is
-- tested elsewhere; here we only need to confirm the NEW branches
-- return before ever reaching this, and that delegation itself works).
-- Minimal-but-real PER_AREA calc (not just a "reachedLegacy" marker) so
-- later checkout-protection tests have a realistic already-priced,
-- non-SUPPLIER_MARGIN control fixture (pvc-banner) to check out with —
-- the real qs_calculate_price_legacy's PER_AREA math is tested
-- elsewhere; this only needs to prove delegation reaches it AND
-- produce a usable total for the rest of this suite.
create or replace function commerce.qs_calculate_price_legacy(p_tenant_id uuid, p_product_key text, p_configuration jsonb)
returns jsonb language plpgsql as $$
declare
  v_pricing jsonb;
  v_product_id uuid;
  v_product_name text;
  v_width numeric;
  v_height numeric;
  v_area numeric;
  v_total numeric;
begin
  select p.id, p.name, c.pricing_definition into v_product_id, v_product_name, v_pricing
  from commerce.service_product_configs c
  join commerce.products p on p.id = c.product_id
  where c.source_key = trim(p_product_key)
  limit 1;

  if upper(coalesce(v_pricing->>'strategy','')) = 'PER_AREA' then
    v_width := coalesce((p_configuration->>'width')::numeric, 0);
    v_height := coalesce((p_configuration->>'height')::numeric, 0);
    v_area := greatest(v_width * v_height, coalesce((v_pricing->>'minimumBillableArea')::numeric, 0));
    v_total := round(v_area * coalesce((v_pricing->>'baseRate')::numeric, 0), 2);
    return jsonb_build_object(
      'productId', v_product_id, 'productKey', trim(p_product_key), 'productName', v_product_name,
      'total', v_total, 'summary', 'test PER_AREA calc', 'lines', '[]'::jsonb,
      'metrics', jsonb_build_object('quoteRequired', false, 'reachedLegacy', true),
      'snapshot', jsonb_build_object('pricingStrategy', 'PER_AREA', 'pricingVersion', 'seed-1')
    );
  end if;

  return jsonb_build_object('reachedLegacy', true, 'productKey', p_product_key);
end
$$;

insert into public.tenants (slug, name) values ('quick-solution', 'Joint X Quick Solution Café');
insert into public.tenant_capabilities (tenant_id, capability_key, enabled)
  select id, 'quick_solution', true from public.tenants where slug='quick-solution';

insert into commerce.fulfilment_points (tenant_id, slug, name, kind, status, collection_enabled, fee_amount, sort_order)
  select id, 'location-001', 'Quick Solution Café · Location 001', 'cafe', 'active', true, 0, 1
  from public.tenants where slug='quick-solution';

-- Preflight dependency the QS14 migrations check for: a published
-- pvc-banner config must already exist.
insert into commerce.products (tenant_id, slug, name, description, status, availability, source_system, source_ref)
  select id, 'pvc-banner', 'PVC Banner', 'Custom printed banners.', 'published', 'available', 'quick_solution', 'pvc-banner'
  from public.tenants where slug='quick-solution';
insert into commerce.service_product_configs (tenant_id, product_id, source_key, customer_definition, pricing_version, pricing_definition, status, sort_order)
  select t.id, p.id, 'pvc-banner', '{}'::jsonb, 'seed-1',
    '{"strategy":"PER_AREA","baseRate":350,"minimumBillableArea":1,"materials":{"standard":{"multiplier":1}},"finishing":{"none":{"fee":0}},"artwork":{"ready":{"fee":0}},"turnaround":{"standard":{"multiplier":1}}}'::jsonb,
    'published', 1
  from public.tenants t join commerce.products p on p.tenant_id=t.id and p.slug='pvc-banner'
  where t.slug='quick-solution';
SQL
echo "prelude ok"

if ! run < "$MIG1" >/tmp/qs14_mig1.out 2>&1; then echo "MIGRATION 1 FAILED:"; cat /tmp/qs14_mig1.out; exit 1; fi
echo "20260921090000 applied"
if ! run < "$MIG1" >/tmp/qs14_mig1b.out 2>&1; then echo "MIGRATION 1 SECOND APPLY FAILED:"; cat /tmp/qs14_mig1b.out; exit 1; fi
echo "20260921090000 idempotent"

if ! run < "$MIG2" >/tmp/qs14_mig2.out 2>&1; then echo "MIGRATION 2 FAILED:"; cat /tmp/qs14_mig2.out; exit 1; fi
echo "20260921090500 applied"
if ! run < "$MIG2" >/tmp/qs14_mig2b.out 2>&1; then echo "MIGRATION 2 SECOND APPLY FAILED:"; cat /tmp/qs14_mig2b.out; exit 1; fi
echo "20260921090500 idempotent"

if ! run < "$MIG3" >/tmp/qs14_mig3.out 2>&1; then echo "MIGRATION 3 FAILED:"; cat /tmp/qs14_mig3.out; exit 1; fi
echo "20260921120000 applied"
if ! run < "$MIG3" >/tmp/qs14_mig3b.out 2>&1; then echo "MIGRATION 3 SECOND APPLY FAILED:"; cat /tmp/qs14_mig3b.out; exit 1; fi
echo "20260921120000 idempotent"

echo "=========================================="
echo "PRICING ENGINE SCENARIOS"
echo "=========================================="
docker exec -i "$CID" psql -X -q -U postgres -d m 2>&1 <<'SQL' | grep -E 'PASS|FAIL|RESULT'
do $$
declare
  TENANT constant uuid := (select id from public.tenants where slug='quick-solution');
  r jsonb;
begin
  set local test.uid = '22222222-2222-2222-2222-222222222222';
  set local test.email = 'staff@jointx.co.za';

  -- ── 1 · SUPPLIER_MARGIN: 50% gross margin computed correctly ────────
  -- Telescopic 2.0m single-sided full kit reference = R495. Gross
  -- margin (not markup): 495 / (1-0.5) = 990. Quantity 2 (the minimum
  -- for this single-sided variant — see #5) -> 1980.
  r := commerce.qs_calculate_price(TENANT, 'flags', '{"variant":"telescopic-2m-ss-full","quantity":2}'::jsonb);
  if (r->>'total')::numeric = 1980.00 and (r->'metrics'->>'quoteRequired')::boolean = false
  then raise notice 'PASS 1 R495 reference at 50%% gross margin sells for exactly R990/unit (not R742.50 markup), x2 = R1980';
  else raise notice 'FAIL 1 total=% metrics=%', r->>'total', r->'metrics'; end if;

  -- ── 2 · quantity multiplies the margin-applied unit price ───────────
  r := commerce.qs_calculate_price(TENANT, 'flags', '{"variant":"telescopic-2m-ss-full","quantity":4}'::jsonb);
  if (r->>'total')::numeric = 3960.00
  then raise notice 'PASS 2 quantity 4 at R990/unit totals R3960';
  else raise notice 'FAIL 2 total=%', r->>'total'; end if;

  -- ── 3 · minimum quantity enforced ────────────────────────────────────
  begin
    r := commerce.qs_calculate_price(TENANT, 'flags', '{"variant":"telescopic-2m-ss-full","quantity":0}'::jsonb);
    raise notice 'FAIL 3 quantity 0 should have been rejected, got %', r;
  exception when others then
    if sqlerrm like '%Minimum quantity%' then raise notice 'PASS 3 quantity below minQuantity is rejected';
    else raise notice 'FAIL 3 wrong error: %', sqlerrm; end if;
  end;

  -- ── 4 · invalid/tampered variant id is rejected ──────────────────────
  begin
    r := commerce.qs_calculate_price(TENANT, 'flags', '{"variant":"totally-made-up-variant","quantity":1}'::jsonb);
    raise notice 'FAIL 4 unknown variant should have been rejected, got %', r;
  exception when others then
    if sqlerrm like '%Choose a valid option%' then raise notice 'PASS 4 an unknown/tampered variant id is rejected';
    else raise notice 'FAIL 4 wrong error: %', sqlerrm; end if;
  end;

  -- ── 5 · single-sided flags must be bought in pairs of 2 ─────────────
  begin
    r := commerce.qs_calculate_price(TENANT, 'flags', '{"variant":"telescopic-2m-ss-full","quantity":1}'::jsonb);
    raise notice 'FAIL 5 quantity 1 for a single-sided flag should have been rejected (pairs of 2), got %', r;
  exception when others then
    if sqlerrm like '%Minimum quantity for this option is 2%' then raise notice 'PASS 5 single-sided flag quantity 1 rejected: minimum is 2 (pairs of 2)';
    else raise notice 'FAIL 5 wrong error: %', sqlerrm; end if;
  end;

  begin
    r := commerce.qs_calculate_price(TENANT, 'flags', '{"variant":"telescopic-2m-ss-full","quantity":3}'::jsonb);
    raise notice 'FAIL 5b quantity 3 (not a multiple of 2 from minimum 2) should have been rejected, got %', r;
  exception when others then
    if sqlerrm like '%multiples of 2%' then raise notice 'PASS 5b single-sided flag quantity 3 rejected: must be ordered in multiples of 2';
    else raise notice 'FAIL 5b wrong error: %', sqlerrm; end if;
  end;

  -- ── 5c · double-sided flags have NO pairs-of-2 constraint ────────────
  r := commerce.qs_calculate_price(TENANT, 'flags', '{"variant":"telescopic-2m-ds-full","quantity":1}'::jsonb);
  if (r->'metrics'->>'quoteRequired')::boolean = false
  then raise notice 'PASS 5c a double-sided flag variant has no pairs-of-2 constraint — quantity 1 is accepted';
  else raise notice 'FAIL 5c unexpected rejection: %', r; end if;

  -- ── 6 · accessories add margin-applied amounts on top ────────────────
  -- Cross base reference R250 -> 250/(1-0.5) = 500. 1980 (qty 2) + 500 = 2480.
  r := commerce.qs_calculate_price(TENANT, 'flags', '{"variant":"telescopic-2m-ss-full","quantity":2,"accessories":["cross-base"]}'::jsonb);
  if (r->>'total')::numeric = 2480.00
  then raise notice 'PASS 6 an accessory (cross base, R250 ref) also gets 50%% gross margin applied: +R500';
  else raise notice 'FAIL 6 total=%', r->>'total'; end if;

  -- ── 7 · invalid accessory id is rejected ─────────────────────────────
  begin
    r := commerce.qs_calculate_price(TENANT, 'flags', '{"variant":"telescopic-2m-ss-full","quantity":2,"accessories":["not-a-real-accessory"]}'::jsonb);
    raise notice 'FAIL 7 unknown accessory should have been rejected, got %', r;
  exception when others then
    if sqlerrm like '%accessories are invalid%' then raise notice 'PASS 7 an unknown accessory id is rejected';
    else raise notice 'FAIL 7 wrong error: %', sqlerrm; end if;
  end;

  -- ── 8 · artwork fee is added flat, NOT margin-multiplied ─────────────
  -- 1980 (qty 2) + design fee R250 (flat, no margin) = 2230.
  r := commerce.qs_calculate_price(TENANT, 'flags', '{"variant":"telescopic-2m-ss-full","quantity":2,"artwork":"design"}'::jsonb);
  if (r->>'total')::numeric = 2230.00
  then raise notice 'PASS 8 artwork/setup fee (R250) is added flat, not margin-multiplied';
  else raise notice 'FAIL 8 total=%', r->>'total'; end if;

  -- ── 9 · gazebos: same engine, different real data ────────────────────
  -- Steel 2x2 full kit reference R2750 -> 2750/(1-0.5) = 5500.
  r := commerce.qs_calculate_price(TENANT, 'gazebos', '{"variant":"steel-2x2-full","quantity":1}'::jsonb);
  if (r->>'total')::numeric = 5500.00
  then raise notice 'PASS 9 Steel gazebo 2x2 full kit (R2750 ref) sells for R5500 at 50%% gross margin';
  else raise notice 'FAIL 9 total=%', r->>'total'; end if;

  -- ── 10 · gazebo wall accessory sized to match the chosen gazebo ─────
  -- 2x2 half wall reference R325 -> 650.
  r := commerce.qs_calculate_price(TENANT, 'gazebos', '{"variant":"steel-2x2-full","quantity":1,"accessories":["wall-2x2-half"]}'::jsonb);
  if (r->>'total')::numeric = 6150.00
  then raise notice 'PASS 10 gazebo + a correctly-sized wall accessory (R325 ref -> R650) totals R6150';
  else raise notice 'FAIL 10 total=%', r->>'total'; end if;

  -- ── 11 · accessory compatibility: a wall sized for the WRONG gazebo ──
  -- is rejected (3m x 3m wall against a 2m x 2m gazebo).
  begin
    r := commerce.qs_calculate_price(TENANT, 'gazebos', '{"variant":"steel-2x2-full","quantity":1,"accessories":["wall-3x3-half"]}'::jsonb);
    raise notice 'FAIL 11 a 3x3 wall against a 2x2 gazebo should have been rejected, got %', r;
  exception when others then
    if sqlerrm like '%not available for the selected option%' then raise notice 'PASS 11 a wall sized for a different gazebo (3x3 wall on a 2x2 gazebo) is rejected';
    else raise notice 'FAIL 11 wrong error: %', sqlerrm; end if;
  end;

  -- ── 11b · the SAME wall accessory IS accepted against the right size ─
  r := commerce.qs_calculate_price(TENANT, 'gazebos', '{"variant":"steel-3x3-standard-full","quantity":1,"accessories":["wall-3x3-half"]}'::jsonb);
  if (r->'metrics'->>'quoteRequired')::boolean = false
  then raise notice 'PASS 11b the same wall accessory is accepted when paired with a matching 3x3 gazebo';
  else raise notice 'FAIL 11b unexpected rejection: %', r; end if;

  -- ── 11c · a universal accessory (no size restriction) works on any size ─
  r := commerce.qs_calculate_price(TENANT, 'gazebos', '{"variant":"steel-2x2-full","quantity":1,"accessories":["rubber-weight"]}'::jsonb);
  if (r->'metrics'->>'quoteRequired')::boolean = false
  then raise notice 'PASS 11c a universal accessory (rubber weight, no compatibleVariants) works with any gazebo size';
  else raise notice 'FAIL 11c unexpected rejection: %', r; end if;

  -- ── 12 · PHOTOGRAPHY_SESSION: the one approved special ───────────────
  r := commerce.qs_calculate_price(TENANT, 'photo-session', '{"session":"30min-7edits"}'::jsonb);
  if (r->>'total')::numeric = 449.00 and (r->'metrics'->>'quoteRequired')::boolean = false
  then raise notice 'PASS 12 the approved 30-minute/7-edits special prices at exactly R449';
  else raise notice 'FAIL 12 total=% metrics=%', r->>'total', r->'metrics'; end if;

  -- ── 13 · unapproved session -> Quote required, never R0/free ─────────
  r := commerce.qs_calculate_price(TENANT, 'photo-session', '{"session":"custom"}'::jsonb);
  if (r->>'summary') = 'Quote required' and (r->'metrics'->>'quoteRequired')::boolean = true
  then raise notice 'PASS 13 an unapproved/custom session is explicitly Quote required, never a silent R0';
  else raise notice 'FAIL 13 summary=% metrics=%', r->>'summary', r->'metrics'; end if;

  -- ── 14 · extra edits with no approved rate -> Quote required ─────────
  r := commerce.qs_calculate_price(TENANT, 'photo-session', '{"session":"30min-7edits","extraEdits":5}'::jsonb);
  if (r->'metrics'->>'quoteRequired')::boolean = true
  then raise notice 'PASS 14 requesting extra edits (unapproved rate) makes the whole request quote-required';
  else raise notice 'FAIL 14 metrics=%', r->'metrics'; end if;

  -- ── 15 · no invented hourly rate: extraEditRate really is null ───────
  if (
    select pricing_definition->>'extraEditRate'
    from commerce.service_product_configs
    where tenant_id = TENANT and source_key = 'photo-session'
  ) is null
  then raise notice 'PASS 15 extraEditRate is genuinely null in the stored pricing_definition — no invented rate';
  else raise notice 'FAIL 15 extraEditRate was set to a value'; end if;

  -- ── 16 · unrelated existing strategies still delegate correctly ──────
  r := commerce.qs_calculate_price(TENANT, 'pvc-banner', '{"width":2,"height":1,"material":"standard","finishing":"none","artwork":"ready","turnaround":"standard"}'::jsonb);
  if (r->'metrics'->>'reachedLegacy')::boolean = true and (r->>'total')::numeric = 700.00
  then raise notice 'PASS 16 an unrelated existing strategy (PER_AREA) still delegates to qs_calculate_price_legacy unchanged (2m² x R350 = R700)';
  else raise notice 'FAIL 16 r=%', r; end if;

  -- ── 17 · customer_definition never carries supplier cost or margin ──
  if (
    select customer_definition::text ilike '%referencePrice%'
       or customer_definition::text ilike '%marginRate%'
       or customer_definition::text ilike '%sourceUrl%'
    from commerce.service_product_configs
    where tenant_id = TENANT and source_key = 'flags'
  ) is false
  then raise notice 'PASS 17 customer_definition (the only thing the public catalog RPC returns) contains no referencePrice/marginRate/sourceUrl — supplier cost and margin stay staff-only';
  else raise notice 'FAIL 17 customer_definition leaked supplier cost/margin data'; end if;

  if (
    select (pricing_definition::text ilike '%referencePrice%') and (pricing_definition::text ilike '%marginRate%')
    from commerce.service_product_configs
    where tenant_id = TENANT and source_key = 'flags'
  ) is true
  then raise notice 'PASS 17b pricing_definition (staff-only, admin_get_quick_solution_catalog) DOES carry referencePrice/marginRate, as intended for editing';
  else raise notice 'FAIL 17b pricing_definition is missing the staff-editable cost/margin data'; end if;

end $$;
SQL

echo "=========================================="
echo "CHECKOUT PROTECTION (paid order / cart RPCs)"
echo "=========================================="
docker exec -i "$CID" psql -X -q -U postgres -d m 2>&1 <<'SQL' | grep -E 'PASS|FAIL|RESULT'
do $$
declare
  r jsonb;
begin
  -- ── 18 · a normal, fully-priced order still works (non-regression) ──
  r := public.create_quick_solution_order(
    'quick-solution', 'pvc-banner', '{"width":2,"height":1,"material":"standard","finishing":"none","artwork":"ready","turnaround":"standard"}'::jsonb,
    'Paying Customer', 'paying@example.com', null, 'cafe', null, null, null, 'idem-checkout-001'
  );
  if (r->>'ok')::boolean = true and (r->>'totalAmount')::numeric = 700.00
  then raise notice 'PASS 18 a normal, fully-priced PER_AREA order still succeeds through create_quick_solution_order (non-regression) — 2m² x R350 = R700';
  else raise notice 'FAIL 18 r=%', r; end if;

  -- ── 19 · an unpriced SUPPLIER_MARGIN item is REJECTED by the paid order RPC ─
  begin
    r := public.create_quick_solution_order(
      'quick-solution', 'flags', '{"variant":"totally-unpriced-would-fail-anyway","quantity":2}'::jsonb,
      'Bypass Attempt', 'bypass@example.com', null, 'cafe', null, null, null, 'idem-checkout-002'
    );
    raise notice 'FAIL 19 setup: should have failed on invalid variant, not reached quote check: %', r;
  exception when others then
    if sqlerrm like '%Choose a valid option%' then raise notice 'PASS 19-setup confirmed: invalid variant still rejected first (expected, not the subject of this test)';
    else raise notice 'FAIL 19-setup unexpected error: %', sqlerrm; end if;
  end;

end $$;
SQL

echo "=========================================="
echo "QUOTE-REQUIRED ROW SETUP + CHECKOUT REJECTION"
echo "=========================================="
docker exec -i "$CID" psql -X -q -U postgres -d m 2>&1 <<'SQL' | grep -E 'PASS|FAIL|RESULT'
do $$
declare
  TENANT constant uuid := (select id from public.tenants where slug='quick-solution');
  r jsonb;
begin
  -- Add a second flags product config with an UNPRICED variant, so we
  -- can prove the checkout guard fires on a genuinely quote-required
  -- (not just invalid) configuration, not just an invalid one.
  insert into commerce.products (tenant_id, slug, name, description, status, availability, source_system, source_ref)
    select id, 'flags-unpriced-test', 'Flags (unpriced test fixture)', 'test fixture', 'published', 'available', 'quick_solution', 'flags-unpriced-test'
    from public.tenants where slug='quick-solution';
  insert into commerce.service_product_configs (tenant_id, product_id, source_key, customer_definition, pricing_version, pricing_definition, status, sort_order)
    select t.id, p.id, 'flags-unpriced-test', '{}'::jsonb, 'seed-3',
      '{"strategy":"SUPPLIER_MARGIN","marginRate":0.5,"minQuantity":1,"variants":{"not-yet-priced":{"label":"Not yet priced","referencePrice":null}},"accessories":{}}'::jsonb,
      'published', 30
    from public.tenants t join commerce.products p on p.tenant_id=t.id and p.slug='flags-unpriced-test'
    where t.slug='quick-solution';

  -- ── 20 · a genuinely quote-required SUPPLIER_MARGIN item is rejected ─
  begin
    r := public.create_quick_solution_order(
      'quick-solution', 'flags-unpriced-test', '{"variant":"not-yet-priced","quantity":1}'::jsonb,
      'Bypass Attempt', 'bypass2@example.com', null, 'cafe', null, null, null, 'idem-checkout-003'
    );
    raise notice 'FAIL 20 an unpriced item should have been rejected by the paid order RPC, got %', r;
  exception when others then
    if sqlerrm like '%needs a quote before it can be ordered%' then raise notice 'PASS 20 an unpriced SUPPLIER_MARGIN item is rejected by create_quick_solution_order — cannot become an R0 purchasable item';
    else raise notice 'FAIL 20 wrong error: %', sqlerrm; end if;
  end;

  -- ── 21 · mixed cart: one priced item + one unpriced item -> WHOLE cart rejected ─
  begin
    r := public.create_quick_solution_cart_order(
      'quick-solution',
      jsonb_build_array(
        jsonb_build_object('clientItemKey','item-priced-0001','productKey','pvc-banner','configuration',jsonb_build_object('width',2,'height',1,'material','standard','finishing','none','artwork','ready','turnaround','standard')),
        jsonb_build_object('clientItemKey','item-unpriced-0002','productKey','flags-unpriced-test','configuration',jsonb_build_object('variant','not-yet-priced','quantity',1))
      ),
      'Mixed Cart Customer', 'mixed@example.com', null, 'cafe', null, null, null, 'idem-checkout-004'
    );
    raise notice 'FAIL 21 a mixed cart with one unpriced item should have been rejected entirely, got %', r;
  exception when others then
    if sqlerrm like '%needs a quote before it can be ordered%' then raise notice 'PASS 21 a mixed cart is rejected ENTIRELY when any single item needs a quote — the priced item cannot ride the unpriced one through';
    else raise notice 'FAIL 21 wrong error: %', sqlerrm; end if;
  end;

  -- ── 21b · confirm nothing was partially created from the rejected mixed cart ─
  if not exists (select 1 from commerce.service_orders where idempotency_key = 'idem-checkout-004')
  then raise notice 'PASS 21b the rejected mixed cart created NO order row at all (fully atomic rejection)';
  else raise notice 'FAIL 21b a partial order was created despite rejection'; end if;

  -- ── 22 · an all-priced multi-item cart still succeeds (non-regression) ─
  r := public.create_quick_solution_cart_order(
    'quick-solution',
    jsonb_build_array(
      jsonb_build_object('clientItemKey','item-ok-0001','productKey','pvc-banner','configuration',jsonb_build_object('width',2,'height',1,'material','standard','finishing','none','artwork','ready','turnaround','standard')),
      jsonb_build_object('clientItemKey','item-ok-0002','productKey','flags','configuration',jsonb_build_object('variant','telescopic-2m-ds-full','quantity',1))
    ),
    'Happy Path Customer', 'happy@example.com', null, 'cafe', null, null, null, 'idem-checkout-005'
  );
  if (r->>'ok')::boolean = true and (r->>'totalAmount')::numeric = (700.00 + 1390.00)
  then raise notice 'PASS 22 a cart where every item is fully priced still checks out normally (700 banner + 1390 flag = 2090)';
  else raise notice 'FAIL 22 r=%', r; end if;

  -- ── 23 · PHOTOGRAPHY_SESSION is blocked from the paid path even when FULLY PRICED ─
  begin
    r := public.create_quick_solution_order(
      'quick-solution', 'photo-session', '{"session":"30min-7edits"}'::jsonb,
      'Photo Bypass Attempt', 'photobypass@example.com', null, 'cafe', null, null, null, 'idem-checkout-006'
    );
    raise notice 'FAIL 23 a priced photo session should still be blocked from the PayFast path, got %', r;
  exception when others then
    if sqlerrm like '%needs a quote before it can be ordered%' then raise notice 'PASS 23 a FULLY PRICED photo session (R449, quoteRequired:false) is still blocked from create_quick_solution_order — payment can never stand in for booking confirmation';
    else raise notice 'FAIL 23 wrong error: %', sqlerrm; end if;
  end;

end $$;
SQL

echo "=========================================="
echo "SERVICE REQUEST RPC (photography, real order rows — flow preserved)"
echo "=========================================="
docker exec -i "$CID" psql -X -q -U postgres -d m 2>&1 <<'SQL' | grep -E 'PASS|FAIL|RESULT'
do $$
declare
  r jsonb; v_order_id uuid; v_subtotal numeric; v_quote_required boolean; v_status text;
begin
  -- ── 24 · approved session -> real total recorded, still no payment ───
  r := public.create_quick_solution_service_request(
    'quick-solution', 'photo-session', '{"session":"30min-7edits","preferredDate":"2026-10-01"}'::jsonb,
    'Jane Customer', 'jane@example.com', null, null, null, 'idem-key-photo-001'
  );
  v_order_id := (r->>'orderId')::uuid;
  select subtotal, (source_metadata->>'quoteRequired')::boolean, payment_status
    into v_subtotal, v_quote_required, v_status
  from commerce.service_orders where id = v_order_id;

  if (r->>'ok')::boolean = true and v_subtotal = 449.00 and v_quote_required = false and v_status = 'unpaid'
  then raise notice 'PASS 24 approved photo session order records the REAL R449 total via the service-request flow, still payment_status=unpaid (no payment token minted)';
  else raise notice 'FAIL 24 ok=% subtotal=% quoteRequired=% status=%', r->>'ok', v_subtotal, v_quote_required, v_status; end if;

  -- ── 25 · unapproved session -> R0, quoteRequired true, still recorded ─
  r := public.create_quick_solution_service_request(
    'quick-solution', 'photo-session', '{"session":"custom"}'::jsonb,
    'John Customer', 'john@example.com', null, null, null, 'idem-key-photo-002'
  );
  select subtotal, (source_metadata->>'quoteRequired')::boolean
    into v_subtotal, v_quote_required
  from commerce.service_orders where id = (r->>'orderId')::uuid;

  if v_subtotal = 0 and v_quote_required = true
  then raise notice 'PASS 25 a custom/unapproved session records total=0 but explicit quoteRequired=true (never presented as simply free)';
  else raise notice 'FAIL 25 subtotal=% quoteRequired=%', v_subtotal, v_quote_required; end if;

  -- ── 26 · idempotent replay returns the same order, not a duplicate ────
  r := public.create_quick_solution_service_request(
    'quick-solution', 'photo-session', '{"session":"30min-7edits"}'::jsonb,
    'Jane Customer', 'jane@example.com', null, null, null, 'idem-key-photo-001'
  );
  if (r->>'replayed')::boolean = true and (r->>'orderId')::uuid = v_order_id
  then raise notice 'PASS 26 a repeated idempotency key replays the SAME order (no duplicate booking created)';
  else raise notice 'FAIL 26 r=%', r; end if;

  -- ── 27 · ENQUIRY (existing media-services-style product) is unaffected ─
  insert into commerce.products (tenant_id, slug, name, status, availability, source_system, source_ref)
    select id, 'media-services', 'Photography & Video', 'published', 'available', 'quick_solution', 'media-services'
    from public.tenants where slug='quick-solution';
  insert into commerce.service_product_configs (tenant_id, product_id, source_key, customer_definition, pricing_version, pricing_definition, status, sort_order)
    select t.id, p.id, 'media-services', '{}'::jsonb, 'seed-2', '{"strategy":"ENQUIRY","quoteRequired":true,"serviceType":"media"}'::jsonb, 'published', 5
    from public.tenants t join commerce.products p on p.tenant_id=t.id and p.slug='media-services'
    where t.slug='quick-solution';

  r := public.create_quick_solution_service_request(
    'quick-solution', 'media-services', '{"shootType":"event"}'::jsonb,
    'Existing Flow Customer', 'existing@example.com', null, null, null, 'idem-key-enquiry-001'
  );
  select subtotal, (source_metadata->>'quoteRequired')::boolean, source_metadata->>'requestType'
    into v_subtotal, v_quote_required, v_status
  from commerce.service_orders where id = (r->>'orderId')::uuid;

  if v_subtotal = 0 and v_quote_required = true and v_status = 'media_service'
  then raise notice 'PASS 27 existing ENQUIRY media-services flow is completely unchanged: total 0, quoteRequired true, requestType media_service';
  else raise notice 'FAIL 27 subtotal=% quoteRequired=% requestType=%', v_subtotal, v_quote_required, v_status; end if;

  -- ── 28 · ENQUIRY is ALSO rejected by the paid order RPC (regression guard) ─
  begin
    r := public.create_quick_solution_order(
      'quick-solution', 'media-services', '{"shootType":"event"}'::jsonb,
      'Enquiry Bypass Attempt', 'enquirybypass@example.com', null, 'cafe', null, null, null, 'idem-checkout-007'
    );
    raise notice 'FAIL 28 an ENQUIRY product should be rejected by the paid order RPC, got %', r;
  exception when others then
    if sqlerrm like '%needs a quote before it can be ordered%' then raise notice 'PASS 28 an ENQUIRY product is rejected by create_quick_solution_order (was already true via quoteRequired, now explicitly proven)';
    else raise notice 'FAIL 28 wrong error: %', sqlerrm; end if;
  end;

  -- ── 29 · a SUPPLIER_MARGIN product still can't use the service-request RPC ─
  begin
    r := public.create_quick_solution_service_request(
      'quick-solution', 'flags', '{"variant":"telescopic-2m-ds-full","quantity":1}'::jsonb,
      'Wrong Path Customer', 'wrong@example.com', null, null, null, 'idem-key-wrong-001'
    );
    raise notice 'FAIL 29 a SUPPLIER_MARGIN product should not be submittable through create_quick_solution_service_request, got %', r;
  exception when others then
    if sqlerrm like '%not configured as a service enquiry%' then raise notice 'PASS 29 SUPPLIER_MARGIN products are correctly rejected by the service-request RPC (they use the normal paid-order path)';
    else raise notice 'FAIL 29 wrong error: %', sqlerrm; end if;
  end;

end $$;
SQL

echo "=========================================="
echo "ADMIN: server-side selling-price regeneration"
echo "=========================================="
docker exec -i "$CID" psql -X -q -U postgres -d m 2>&1 <<'SQL' | grep -E 'PASS|FAIL|RESULT'
do $$
declare
  r jsonb;
  v_expected_version text;
  v_saved_customer jsonb;
  v_saved_pricing jsonb;
begin
  set local test.uid = '33333333-3333-3333-3333-333333333333';
  set local test.email = 'admin@jointx.co.za';

  select pricing_version into v_expected_version
  from commerce.service_product_configs where source_key = 'flags';

  -- Admin edits marginRate from 0.5 to 0.6, and (maliciously or just
  -- buggily) submits a customer_definition.pricing mirror that does NOT
  -- match the new margin at all — the server must ignore the client's
  -- mirror and recompute it from the pricing_definition it just saved.
  r := public.admin_update_quick_solution_product(
    'quick-solution',
    'flags',
    jsonb_build_object(
      'name','Flags & Promotional Flags','active',true,
      'pricing', jsonb_build_object(
        'strategy','SUPPLIER_MARGIN',
        'variants', jsonb_build_object('telescopic-2m-ss-full', jsonb_build_object('label','Telescopic 2m','price', 1.00))
      )
    ),
    jsonb_build_object(
      'strategy','SUPPLIER_MARGIN',
      'marginRate', 0.6,
      'minQuantity', 1,
      'variantAxes', jsonb_build_array(jsonb_build_object('id','style','label','Style','options',jsonb_build_array(jsonb_build_object('id','telescopic','label','Telescopic')))),
      'variantTemplate', '{style}-{size}-{sides}-{kit}',
      'variants', jsonb_build_object(
        'telescopic-2m-ss-full', jsonb_build_object('label','Telescopic flag — 2.0m — single-sided — full kit','referencePrice', 495, 'minQuantity', 2, 'quantityStep', 2)
      ),
      'accessories', '{}'::jsonb
    ),
    v_expected_version
  );

  if (r->>'ok')::boolean = true
  then raise notice 'PASS 30 admin save with a changed marginRate (0.5 -> 0.6) succeeds';
  else raise notice 'FAIL 30 r=%', r; end if;

  select customer_definition, pricing_definition into v_saved_customer, v_saved_pricing
  from commerce.service_product_configs where source_key = 'flags';

  -- 495 / (1 - 0.6) = 1237.50 — NOT the client-submitted 1.00, and NOT
  -- the old 990 (0.5 margin) either.
  if (v_saved_customer->'pricing'->'variants'->'telescopic-2m-ss-full'->>'price')::numeric = 1237.50
  then raise notice 'PASS 31 the saved customer-safe price is SERVER-RECOMPUTED from the new margin (R1237.50), not the stale/spoofed client value (R1.00) and not the old margin''s R990';
  else raise notice 'FAIL 31 saved price=%', v_saved_customer->'pricing'->'variants'->'telescopic-2m-ss-full'->>'price'; end if;

  -- The regenerated mirror must still carry the non-sensitive
  -- minQuantity/quantityStep rule through, so the guided UI can still
  -- enforce pairs-of-2 without needing pricing_definition.
  if (v_saved_customer->'pricing'->'variants'->'telescopic-2m-ss-full'->>'quantityStep')::int = 2
  then raise notice 'PASS 32 the regenerated customer-safe mirror still carries quantityStep (2) through — non-sensitive, needed client-side';
  else raise notice 'FAIL 32 quantityStep missing from regenerated mirror: %', v_saved_customer->'pricing'->'variants'->'telescopic-2m-ss-full'; end if;

  -- Regression: admin save previously stripped variantAxes/variantTemplate
  -- from customer_definition entirely, silently breaking the decomposed
  -- style/size/sides/kit guided configurator on the very next page load.
  if jsonb_array_length(v_saved_customer->'pricing'->'variantAxes') = 1
     and v_saved_customer->'pricing'->'variantAxes'->0->>'id' = 'style'
     and v_saved_customer->'pricing'->>'variantTemplate' = '{style}-{size}-{sides}-{kit}'
  then raise notice 'PASS 32b admin save PRESERVES variantAxes/variantTemplate in the regenerated customer-safe mirror (guided configurator keeps working after a save)';
  else raise notice 'FAIL 32b variantAxes/variantTemplate missing or wrong after save: axes=% template=%', v_saved_customer->'pricing'->'variantAxes', v_saved_customer->'pricing'->>'variantTemplate'; end if;

  -- The saved customer_definition must still never carry referencePrice/marginRate.
  if v_saved_customer::text ilike '%referencePrice%' or v_saved_customer::text ilike '%marginRate%'
  then raise notice 'FAIL 33 the regenerated customer_definition leaked referencePrice/marginRate';
  else raise notice 'PASS 33 the regenerated customer_definition still never carries referencePrice/marginRate — admin save cannot leak supplier cost data either';
  end if;

  -- pricing_definition (staff-only) DOES have the new margin saved correctly.
  if (v_saved_pricing->>'marginRate')::numeric = 0.6
  then raise notice 'PASS 34 pricing_definition (staff-only) correctly stores the admin-edited marginRate (0.6)';
  else raise notice 'FAIL 34 marginRate=%', v_saved_pricing->>'marginRate'; end if;

  -- Live pricing calc reflects the new margin immediately.
  r := commerce.qs_calculate_price(
    (select id from public.tenants where slug='quick-solution'),
    'flags',
    '{"variant":"telescopic-2m-ss-full","quantity":2}'::jsonb
  );
  if (r->>'total')::numeric = 2475.00 -- 1237.50 * 2
  then raise notice 'PASS 35 commerce.qs_calculate_price immediately reflects the admin-edited margin (R1237.50/unit x2 = R2475)';
  else raise notice 'FAIL 35 total=%', r->>'total'; end if;

  -- Stale-version guard still works after this change.
  begin
    r := public.admin_update_quick_solution_product(
      'quick-solution', 'flags', jsonb_build_object('name','Flags','active',true),
      jsonb_build_object('strategy','SUPPLIER_MARGIN','marginRate',0.5,'variants','{}'::jsonb,'accessories','{}'::jsonb),
      v_expected_version -- now stale, since PASS 30 already advanced the version
    );
    raise notice 'FAIL 36 a stale pricing_version should have been rejected, got %', r;
  exception when others then
    if sqlerrm like '%changed after you opened it%' then raise notice 'PASS 36 admin stale-version guard still rejects an outdated pricing_version after this change';
    else raise notice 'FAIL 36 wrong error: %', sqlerrm; end if;
  end;

end $$;
SQL

echo "=========================================="
echo "ADMIN: photography deliverable add / edit / remove"
echo "=========================================="
docker exec -i "$CID" psql -X -q -U postgres -d m 2>&1 <<'SQL' | grep -E 'PASS|FAIL|RESULT'
do $$
declare
  TENANT constant uuid := (select id from public.tenants where slug='quick-solution');
  r jsonb;
  v_version text;
  v_saved_customer jsonb;
begin
  set local test.uid = '33333333-3333-3333-3333-333333333333';
  set local test.email = 'admin@jointx.co.za';

  select pricing_version into v_version from commerce.service_product_configs where source_key = 'photo-session';

  -- ── 37 · admin adds a brand-new deliverable (starts unpriced) ───────
  -- The seeded catalogue ships with deliverables: {} — admin-only
  -- editing of existing entries is not enough, since there ARE none;
  -- this proves a new one can actually be created.
  r := public.admin_update_quick_solution_product(
    'quick-solution', 'photo-session',
    jsonb_build_object('name','Quick Photo Session','active',true),
    jsonb_build_object(
      'strategy','PHOTOGRAPHY_SESSION',
      'sessions', jsonb_build_object('30min-7edits', jsonb_build_object('label','30-minute session — 7 edited photos included','durationMinutes',30,'includedEdits',7,'price',449)),
      'extraEditRate', null,
      'deliverables', jsonb_build_object('video-highlight', jsonb_build_object('label','Video highlight reel','price', null))
    ),
    v_version
  );
  if (r->>'ok')::boolean = true
  then raise notice 'PASS 37 admin can add a brand-new deliverable (starts unpriced/quote-required, not invented)';
  else raise notice 'FAIL 37 r=%', r; end if;

  select pricing_version into v_version from commerce.service_product_configs where source_key = 'photo-session';
  select customer_definition into v_saved_customer from commerce.service_product_configs where source_key = 'photo-session';

  if (v_saved_customer->'pricing'->'deliverables'->'video-highlight'->>'label') = 'Video highlight reel'
     and (v_saved_customer->'pricing'->'deliverables'->'video-highlight'->'price') = 'null'::jsonb
  then raise notice 'PASS 38 the new deliverable appears in the customer-safe mirror, unpriced (never a silently invented rate)';
  else raise notice 'FAIL 38 saved deliverable=%', v_saved_customer->'pricing'->'deliverables'->'video-highlight'; end if;

  -- ── 39 · selecting the new deliverable before it's priced -> quote-required ─
  r := commerce.qs_calculate_price(TENANT, 'photo-session', '{"session":"30min-7edits","deliverables":["video-highlight"]}'::jsonb);
  if (r->'metrics'->>'quoteRequired')::boolean = true
  then raise notice 'PASS 39 selecting the new (still unpriced) deliverable makes the request quote-required, never free';
  else raise notice 'FAIL 39 metrics=%', r->'metrics'; end if;

  -- ── 40 · admin sets a real price on it -> becomes orderable ──────────
  r := public.admin_update_quick_solution_product(
    'quick-solution', 'photo-session',
    jsonb_build_object('name','Quick Photo Session','active',true),
    jsonb_build_object(
      'strategy','PHOTOGRAPHY_SESSION',
      'sessions', jsonb_build_object('30min-7edits', jsonb_build_object('label','30-minute session — 7 edited photos included','durationMinutes',30,'includedEdits',7,'price',449)),
      'extraEditRate', null,
      'deliverables', jsonb_build_object('video-highlight', jsonb_build_object('label','Video highlight reel','price', 250))
    ),
    v_version
  );
  select pricing_version into v_version from commerce.service_product_configs where source_key = 'photo-session';

  r := commerce.qs_calculate_price(TENANT, 'photo-session', '{"session":"30min-7edits","deliverables":["video-highlight"]}'::jsonb);
  if (r->>'total')::numeric = 699.00 -- 449 + 250
  then raise notice 'PASS 40 once priced by an admin, the deliverable prices correctly (R449 + R250 = R699)';
  else raise notice 'FAIL 40 total=%', r->>'total'; end if;

  -- ── 41 · admin removes the deliverable entirely ──────────────────────
  r := public.admin_update_quick_solution_product(
    'quick-solution', 'photo-session',
    jsonb_build_object('name','Quick Photo Session','active',true),
    jsonb_build_object(
      'strategy','PHOTOGRAPHY_SESSION',
      'sessions', jsonb_build_object('30min-7edits', jsonb_build_object('label','30-minute session — 7 edited photos included','durationMinutes',30,'includedEdits',7,'price',449)),
      'extraEditRate', null,
      'deliverables', '{}'::jsonb
    ),
    v_version
  );
  if (r->>'ok')::boolean = true
  then raise notice 'PASS 41 admin can remove a deliverable entirely';
  else raise notice 'FAIL 41 r=%', r; end if;

  -- ── 42 · a removed deliverable is rejected if still submitted ────────
  begin
    r := commerce.qs_calculate_price(TENANT, 'photo-session', '{"session":"30min-7edits","deliverables":["video-highlight"]}'::jsonb);
    raise notice 'FAIL 42 a removed deliverable should have been rejected, got %', r;
  exception when others then
    if sqlerrm like '%deliverables are invalid%' then raise notice 'PASS 42 a removed deliverable id is rejected if a stale client still submits it';
    else raise notice 'FAIL 42 wrong error: %', sqlerrm; end if;
  end;

end $$;
SQL
