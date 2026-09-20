#!/usr/bin/env bash
# Disposable pg16 proof for:
#   20260921090000_qs14_catalog_margin_photography.sql (SUPPLIER_MARGIN /
#   PHOTOGRAPHY_SESSION strategies in commerce.qs_calculate_price, the
#   admin_update_quick_solution_product strategy allow-list, and
#   create_quick_solution_service_request accepting PHOTOGRAPHY_SESSION)
#   20260921090500_qs14_catalog_data.sql (Flags / Gazebos / Quick Photo
#   Session catalogue rows, real supplier data)
#
# This is a LOCAL, DISPOSABLE container only. It never touches staging
# or production. Schema stub covers just enough of commerce.*/public.*
# for these two migrations to apply and their RPCs to run.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
MIG1="$ROOT/supabase/migrations/20260921090000_qs14_catalog_margin_photography.sql"
MIG2="$ROOT/supabase/migrations/20260921090500_qs14_catalog_data.sql"
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
  created_at timestamptz not null default now()
);

create or replace function commerce.qs_generate_order_number() returns text
  language sql as $$ select 'QSC-TEST-' || substr(gen_random_uuid()::text,1,8) $$;

-- Stub for the delegation target: proves unhandled strategies still
-- reach _legacy (existing PER_AREA/PER_PAGE/TIERED/CONFIGURABLE math is
-- tested elsewhere; here we only need to confirm the NEW branches
-- return before ever reaching this, and that delegation itself works).
create or replace function commerce.qs_calculate_price_legacy(p_tenant_id uuid, p_product_key text, p_configuration jsonb)
returns jsonb language plpgsql as $$
begin
  return jsonb_build_object('reachedLegacy', true, 'productKey', p_product_key);
end
$$;

insert into public.tenants (slug, name) values ('quick-solution', 'Joint X Quick Solution Café');
insert into public.tenant_capabilities (tenant_id, capability_key, enabled)
  select id, 'quick_solution', true from public.tenants where slug='quick-solution';

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

echo "=========================================="
echo "SCENARIOS"
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
  -- Telescopic 2.0m single-sided full kit reference = R495.
  -- Gross margin (not markup): 495 / (1-0.5) = 990.
  r := commerce.qs_calculate_price(TENANT, 'flags', '{"variant":"telescopic-2m-ss-full","quantity":1}'::jsonb);
  if (r->>'total')::numeric = 990.00 and (r->'metrics'->>'quoteRequired')::boolean = false
  then raise notice 'PASS 1 R495 reference at 50%% gross margin sells for exactly R990 (not R742.50 markup)';
  else raise notice 'FAIL 1 total=% metrics=%', r->>'total', r->'metrics'; end if;

  -- ── 2 · quantity multiplies the margin-applied unit price ───────────
  r := commerce.qs_calculate_price(TENANT, 'flags', '{"variant":"telescopic-2m-ss-full","quantity":3}'::jsonb);
  if (r->>'total')::numeric = 2970.00
  then raise notice 'PASS 2 quantity 3 at R990/unit totals R2970';
  else raise notice 'FAIL 2 total=%', r->>'total'; end if;

  -- ── 3 · minimum quantity enforced ────────────────────────────────────
  begin
    r := commerce.qs_calculate_price(TENANT, 'flags', '{"variant":"telescopic-2m-ss-full","quantity":0}'::jsonb);
    raise notice 'FAIL 3 quantity 0 should have been rejected (minQuantity=1), got %', r;
  exception when others then
    if sqlerrm like '%Minimum quantity%' then raise notice 'PASS 3 quantity below minQuantity (1) is rejected';
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

  -- ── 5 · accessories add margin-applied amounts on top ────────────────
  -- Cross base reference R250 -> 250/(1-0.5) = 500. 990 + 500 = 1490.
  r := commerce.qs_calculate_price(TENANT, 'flags', '{"variant":"telescopic-2m-ss-full","quantity":1,"accessories":["cross-base"]}'::jsonb);
  if (r->>'total')::numeric = 1490.00
  then raise notice 'PASS 5 an accessory (cross base, R250 ref) also gets 50%% gross margin applied: +R500';
  else raise notice 'FAIL 5 total=%', r->>'total'; end if;

  -- ── 6 · invalid accessory id is rejected ─────────────────────────────
  begin
    r := commerce.qs_calculate_price(TENANT, 'flags', '{"variant":"telescopic-2m-ss-full","quantity":1,"accessories":["not-a-real-accessory"]}'::jsonb);
    raise notice 'FAIL 6 unknown accessory should have been rejected, got %', r;
  exception when others then
    if sqlerrm like '%accessories are invalid%' then raise notice 'PASS 6 an unknown accessory id is rejected';
    else raise notice 'FAIL 6 wrong error: %', sqlerrm; end if;
  end;

  -- ── 7 · artwork fee is added flat, NOT margin-multiplied ─────────────
  -- 990 + design fee R250 (flat, no margin) = 1240.
  r := commerce.qs_calculate_price(TENANT, 'flags', '{"variant":"telescopic-2m-ss-full","quantity":1,"artwork":"design"}'::jsonb);
  if (r->>'total')::numeric = 1240.00
  then raise notice 'PASS 7 artwork/setup fee (R250) is added flat, not margin-multiplied';
  else raise notice 'FAIL 7 total=%', r->>'total'; end if;

  -- ── 8 · gazebos: same engine, different real data ────────────────────
  -- Steel 2x2 full kit reference R2750 -> 2750/(1-0.5) = 5500.
  r := commerce.qs_calculate_price(TENANT, 'gazebos', '{"variant":"steel-2x2-full","quantity":1}'::jsonb);
  if (r->>'total')::numeric = 5500.00
  then raise notice 'PASS 8 Steel gazebo 2x2 full kit (R2750 ref) sells for R5500 at 50%% gross margin';
  else raise notice 'FAIL 8 total=%', r->>'total'; end if;

  -- ── 9 · gazebo wall accessory (a real "replacement/add-on" line) ────
  -- 2x2 half wall reference R325 -> 650.
  r := commerce.qs_calculate_price(TENANT, 'gazebos', '{"variant":"steel-2x2-full","quantity":1,"accessories":["wall-2x2-half"]}'::jsonb);
  if (r->>'total')::numeric = 6150.00
  then raise notice 'PASS 9 gazebo + a wall accessory (R325 ref -> R650) totals R6150';
  else raise notice 'FAIL 9 total=%', r->>'total'; end if;

  -- ── 10 · PHOTOGRAPHY_SESSION: the one approved special ───────────────
  r := commerce.qs_calculate_price(TENANT, 'photo-session', '{"session":"30min-7edits"}'::jsonb);
  if (r->>'total')::numeric = 449.00 and (r->'metrics'->>'quoteRequired')::boolean = false
  then raise notice 'PASS 10 the approved 30-minute/7-edits special prices at exactly R449';
  else raise notice 'FAIL 10 total=% metrics=%', r->>'total', r->'metrics'; end if;

  -- ── 11 · unapproved session -> Quote required, never R0/free ─────────
  r := commerce.qs_calculate_price(TENANT, 'photo-session', '{"session":"custom"}'::jsonb);
  if (r->>'summary') = 'Quote required' and (r->'metrics'->>'quoteRequired')::boolean = true
  then raise notice 'PASS 11 an unapproved/custom session is explicitly Quote required, never a silent R0';
  else raise notice 'FAIL 11 summary=% metrics=%', r->>'summary', r->'metrics'; end if;

  -- ── 12 · extra edits with no approved rate -> Quote required ─────────
  -- Even on the approved base session, requesting extra edits (rate is
  -- null/unapproved) must flip the WHOLE request to quote-required, not
  -- silently charge R449 while ignoring the extra edits.
  r := commerce.qs_calculate_price(TENANT, 'photo-session', '{"session":"30min-7edits","extraEdits":5}'::jsonb);
  if (r->'metrics'->>'quoteRequired')::boolean = true
  then raise notice 'PASS 12 requesting extra edits (unapproved rate) makes the whole request quote-required';
  else raise notice 'FAIL 12 metrics=%', r->'metrics'; end if;

  -- ── 13 · no invented hourly rate: extraEditRate really is null ───────
  if (
    select pricing_definition->>'extraEditRate'
    from commerce.service_product_configs
    where tenant_id = TENANT and source_key = 'photo-session'
  ) is null
  then raise notice 'PASS 13 extraEditRate is genuinely null in the stored pricing_definition — no invented rate';
  else raise notice 'FAIL 13 extraEditRate was set to a value'; end if;

  -- ── 14 · admin editor now accepts the two new strategies ─────────────
  r := public.admin_update_quick_solution_product(
    'quick-solution', 'flags', '{"name":"Flags & Promotional Flags","active":true}'::jsonb,
    (select pricing_definition from commerce.service_product_configs where tenant_id=TENANT and source_key='flags'),
    (select pricing_version from commerce.service_product_configs where tenant_id=TENANT and source_key='flags')
  );
  if (r->>'ok')::boolean = true
  then raise notice 'PASS 14 admin_update_quick_solution_product accepts SUPPLIER_MARGIN (was previously unsupported)';
  else raise notice 'FAIL 14 r=%', r; end if;

  -- ── 15 · admin optimistic-concurrency guard still works ──────────────
  begin
    r := public.admin_update_quick_solution_product(
      'quick-solution', 'flags', '{"name":"Flags","active":true}'::jsonb,
      (select pricing_definition from commerce.service_product_configs where tenant_id=TENANT and source_key='flags'),
      'a-stale-version-string'
    );
    raise notice 'FAIL 15 stale pricing_version should have been rejected, got %', r;
  exception when others then
    if sqlerrm like '%changed after you opened it%' then raise notice 'PASS 15 admin stale-version guard still rejects an outdated pricing_version';
    else raise notice 'FAIL 15 wrong error: %', sqlerrm; end if;
  end;

  -- ── 16 · unsupported strategy is still rejected by the admin editor ──
  begin
    r := public.admin_update_quick_solution_product(
      'quick-solution', 'flags', '{"name":"Flags","active":true}'::jsonb,
      '{"strategy":"MADE_UP_STRATEGY"}'::jsonb,
      (select pricing_version from commerce.service_product_configs where tenant_id=TENANT and source_key='flags')
    );
    raise notice 'FAIL 16 a made-up strategy should have been rejected, got %', r;
  exception when others then
    if sqlerrm like '%not supported%' then raise notice 'PASS 16 a genuinely unsupported strategy is still rejected by the admin editor';
    else raise notice 'FAIL 16 wrong error: %', sqlerrm; end if;
  end;

  -- ── 17 · unrelated existing strategies still delegate correctly ──────
  r := commerce.qs_calculate_price(TENANT, 'pvc-banner', '{"width":2,"height":1,"material":"standard","finishing":"none","artwork":"ready","turnaround":"standard"}'::jsonb);
  if (r->>'reachedLegacy')::boolean = true
  then raise notice 'PASS 17 an unrelated existing strategy (PER_AREA) still delegates to qs_calculate_price_legacy unchanged';
  else raise notice 'FAIL 17 r=%', r; end if;

  -- ── 23 · customer_definition never carries supplier cost or margin ──
  -- get_quick_solution_catalog (the public RPC) only ever returns
  -- customer_definition — this proves the flags row's customer_definition
  -- contains no referencePrice/marginRate/sourceUrl anywhere, even
  -- though pricing_definition (staff-only) does.
  if (
    select customer_definition::text ilike '%referencePrice%'
       or customer_definition::text ilike '%marginRate%'
       or customer_definition::text ilike '%sourceUrl%'
    from commerce.service_product_configs
    where tenant_id = TENANT and source_key = 'flags'
  ) is false
  then raise notice 'PASS 23 customer_definition (the only thing the public catalog RPC returns) contains no referencePrice/marginRate/sourceUrl — supplier cost and margin stay staff-only';
  else raise notice 'FAIL 23 customer_definition leaked supplier cost/margin data'; end if;

  if (
    select (pricing_definition::text ilike '%referencePrice%') and (pricing_definition::text ilike '%marginRate%')
    from commerce.service_product_configs
    where tenant_id = TENANT and source_key = 'flags'
  ) is true
  then raise notice 'PASS 23b pricing_definition (staff-only, admin_get_quick_solution_catalog) DOES carry referencePrice/marginRate, as intended for editing';
  else raise notice 'FAIL 23b pricing_definition is missing the staff-editable cost/margin data'; end if;

end $$;
SQL

echo "=========================================="
echo "SERVICE REQUEST RPC (photography, real order rows)"
echo "=========================================="
docker exec -i "$CID" psql -X -q -U postgres -d m 2>&1 <<'SQL' | grep -E 'PASS|FAIL|RESULT'
do $$
declare
  r jsonb; v_order_id uuid; v_subtotal numeric; v_quote_required boolean; v_status text;
begin
  -- ── 18 · approved session -> real total recorded, still no payment ───
  r := public.create_quick_solution_service_request(
    'quick-solution', 'photo-session', '{"session":"30min-7edits","preferredDate":"2026-10-01"}'::jsonb,
    'Jane Customer', 'jane@example.com', null, null, null, 'idem-key-photo-001'
  );
  v_order_id := (r->>'orderId')::uuid;
  select subtotal, (source_metadata->>'quoteRequired')::boolean, payment_status
    into v_subtotal, v_quote_required, v_status
  from commerce.service_orders where id = v_order_id;

  if (r->>'ok')::boolean = true and v_subtotal = 449.00 and v_quote_required = false and v_status = 'unpaid'
  then raise notice 'PASS 18 approved photo session order records the REAL R449 total, still payment_status=unpaid (no payment token minted -> booking never implied confirmed)';
  else raise notice 'FAIL 18 ok=% subtotal=% quoteRequired=% status=%', r->>'ok', v_subtotal, v_quote_required, v_status; end if;

  -- ── 19 · unapproved session -> R0, quoteRequired true, still recorded ─
  r := public.create_quick_solution_service_request(
    'quick-solution', 'photo-session', '{"session":"custom"}'::jsonb,
    'John Customer', 'john@example.com', null, null, null, 'idem-key-photo-002'
  );
  select subtotal, (source_metadata->>'quoteRequired')::boolean
    into v_subtotal, v_quote_required
  from commerce.service_orders where id = (r->>'orderId')::uuid;

  if v_subtotal = 0 and v_quote_required = true
  then raise notice 'PASS 19 a custom/unapproved session records total=0 but explicit quoteRequired=true (never presented as simply free)';
  else raise notice 'FAIL 19 subtotal=% quoteRequired=%', v_subtotal, v_quote_required; end if;

  -- ── 20 · idempotent replay returns the same order, not a duplicate ────
  r := public.create_quick_solution_service_request(
    'quick-solution', 'photo-session', '{"session":"30min-7edits"}'::jsonb,
    'Jane Customer', 'jane@example.com', null, null, null, 'idem-key-photo-001'
  );
  if (r->>'replayed')::boolean = true and (r->>'orderId')::uuid = v_order_id
  then raise notice 'PASS 20 a repeated idempotency key replays the SAME order (no duplicate booking created)';
  else raise notice 'FAIL 20 r=%', r; end if;

  -- ── 21 · ENQUIRY (existing media-services-style product) is unaffected ─
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
  then raise notice 'PASS 21 existing ENQUIRY media-services flow is completely unchanged: total 0, quoteRequired true, requestType media_service';
  else raise notice 'FAIL 21 subtotal=% quoteRequired=% requestType=%', v_subtotal, v_quote_required, v_status; end if;

  -- ── 22 · a priced (non-ENQUIRY, non-PHOTOGRAPHY_SESSION) product still can't use this RPC ─
  begin
    r := public.create_quick_solution_service_request(
      'quick-solution', 'flags', '{"variant":"telescopic-2m-ss-full","quantity":1}'::jsonb,
      'Wrong Path Customer', 'wrong@example.com', null, null, null, 'idem-key-wrong-001'
    );
    raise notice 'FAIL 22 a SUPPLIER_MARGIN product should not be submittable through create_quick_solution_service_request, got %', r;
  exception when others then
    if sqlerrm like '%not configured as a service enquiry%' then raise notice 'PASS 22 SUPPLIER_MARGIN products are correctly rejected by the service-request RPC (they use the normal paid-order path)';
    else raise notice 'FAIL 22 wrong error: %', sqlerrm; end if;
  end;

end $$;
SQL
