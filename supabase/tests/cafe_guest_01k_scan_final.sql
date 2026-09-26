-- CAFE-GUEST-01K: contract test for the finalized, live Scan product (R5 per page,
-- 1..300 pages), and for the forward migration that finalized it.
--
-- Run only against the disposable local harness (supabase/tests/harness/), which
-- replays the whole migration history, including
--   20260926150000_cafe_guest_01h_scan_product.sql   (Scan created, not live, unpriced)
--   20260926180000_cafe_guest_01k_scan_final.sql     (Scan finalized and made live)
-- Everything reads the REAL seeded rows. Prices the test edits (through the real admin
-- function, to prove independent editing) use the TEST'S OWN numbers and exist only
-- inside this BEGIN/ROLLBACK; the confirmed R5 / 1 / 300 are asserted as shipped
-- BEFORE any edit.
--
-- The migration is then re-applied inside the transaction (\ir; it has no BEGIN/COMMIT
-- of its own): over an admin-edited AND unpublished Scan (nothing may be overwritten or
-- republished), and over an environment that only ever had 01H (it must upgrade to the
-- approved values).

\set ON_ERROR_STOP on

begin;

create function pg_temp.expect_error(
  p_sql text,
  p_case text,
  p_sqlstate text,
  p_token text
) returns void
language plpgsql
as $helper$
declare
  v_state text;
  v_message text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
    if v_state is distinct from p_sqlstate
       or position(p_token in coalesce(v_message,'')) = 0 then
      raise exception 'CAFE_GUEST_01K: % expected % containing "%" but got % "%"',
        p_case, p_sqlstate, p_token, v_state, v_message;
    end if;
    return;
  end;
  raise exception 'CAFE_GUEST_01K: % unexpectedly succeeded', p_case;
end
$helper$;

-- Total for one product and one unit count, through the real server price path.
create function pg_temp.price(p_key text, p_units text) returns numeric
language sql
as $$
  select (commerce.qs_calculate_price(
    (select t.id from public.tenants t where t.slug = 'quick-solution'),
    p_key,
    jsonb_build_object('units', p_units::jsonb)) ->> 'total')::numeric
$$;

-- The A4 and A3 Lamination rows, as one comparable value (they must never move here).
create function pg_temp.lamination_rows() returns jsonb
language sql
as $$
  select jsonb_agg(to_jsonb(c) order by c.source_key)
  from commerce.service_product_configs c
  where c.tenant_id = (select t.id from public.tenants t where t.slug = 'quick-solution')
    and c.source_key in ('a4-lamination','a3-lamination')
$$;

-- ═════════ phase 1: shipped state, pricing, guards, independent admin edits ═════════
do $phase1$
declare
  v_suffix text := replace(gen_random_uuid()::text,'-','');
  v_tenant uuid;
  v_config commerce.service_product_configs;
  v_product commerce.products;
  v_customer jsonb;
  v_ids text;
  v_result jsonb;
  v_case text;
  v_lam_before jsonb;
  v_scan_before jsonb;
  v_order_storefront uuid := gen_random_uuid();
  v_order_counter uuid := gen_random_uuid();
  v_staff uuid := gen_random_uuid();
  v_admin uuid := gen_random_uuid();
begin
  select t.id into v_tenant from public.tenants t where t.slug = 'quick-solution';
  if v_tenant is null then raise exception 'the quick-solution tenant must exist'; end if;
  v_lam_before := pg_temp.lamination_rows();

  -- ── exactly once, live, in the approved shape ──────────────────────────
  if (select count(*) from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'scan') <> 1
     or (select count(*) from commerce.products p where p.tenant_id = v_tenant and p.slug = 'scan') <> 1 then
    raise exception 'Scan must exist exactly once (config and product)';
  end if;
  select * into v_config from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'scan';
  select * into v_product from commerce.products p where p.id = v_config.product_id;

  if v_product.name <> 'Document Scanning' or v_product.slug <> 'scan' or v_product.currency <> 'ZAR' then
    raise exception 'unexpected product identity: %', to_jsonb(v_product);
  end if;
  if v_config.status <> 'published' or v_product.status <> 'published' or v_product.availability <> 'available' then
    raise exception 'Scan must be live (published + available): config %, product %, availability %', v_config.status, v_product.status, v_product.availability;
  end if;
  if v_config.pricing_version <> '2026-09-qsc-18' or v_config.sort_order <> 22 then
    raise exception 'unexpected version/sort order: % %', v_config.pricing_version, v_config.sort_order;
  end if;

  -- ── the approved PER_UNIT definition and its public mirror ─────────────
  if v_config.pricing_definition is distinct from '{"strategy":"PER_UNIT","unitPrice":5,"minUnits":1,"maxUnits":300}'::jsonb then
    raise exception 'pricing_definition must be PER_UNIT R5 x 1..300, got %', v_config.pricing_definition;
  end if;
  if v_config.customer_definition -> 'pricing' is distinct from v_config.pricing_definition then
    raise exception 'the customer pricing mirror must equal the definition (four keys, nothing private)';
  end if;
  if (select array_agg(k order by k) from jsonb_object_keys(v_config.customer_definition -> 'pricing') k)
     is distinct from array['maxUnits','minUnits','strategy','unitPrice'] then
    raise exception 'the customer mirror carries fields outside the contract';
  end if;
  if lower(v_config.customer_definition::text || v_config.pricing_definition::text) ~ '(quantity|supplier|margin|referenceprice|sourceurl|setupfee|minimumcharge|tier|discount|multiplier|variant|option)' then
    raise exception 'Scan must carry no quantity, supplier, margin, source, setup fee, minimum charge, tier, discount, variant or option';
  end if;

  v_customer := v_config.customer_definition;
  -- Finalizing did not touch the deliberate channels: counter-only.
  if v_customer -> 'channels' is distinct from '{"storefront":false,"guided":false,"pos":true,"quote":false,"advanced":false}'::jsonb then
    raise exception 'channels must stay the pinned counter-only decision, got %', v_customer -> 'channels';
  end if;
  if v_customer ->> 'category' <> 'Quick Print' or (v_customer ->> 'active')::boolean is distinct from true then
    raise exception 'category / active wrong: %', v_customer;
  end if;
  -- One plain units field, pages not sheets, no file, no options, no max/default.
  if jsonb_array_length(v_customer -> 'fields') <> 1
     or v_customer -> 'fields' -> 0 ->> 'id' <> 'units'
     or v_customer -> 'fields' -> 0 ->> 'type' <> 'number'
     or v_customer -> 'fields' -> 0 ->> 'label' <> 'How many pages need scanning?'
     or v_customer -> 'fields' -> 0 ? 'options'
     or v_customer -> 'fields' -> 0 ? 'max'
     or v_customer -> 'fields' -> 0 ? 'default' then
    raise exception 'Scan has exactly one plain units field (pages): %', v_customer -> 'fields';
  end if;
  if v_customer -> 'fields' @> '[{"type":"file"}]'::jsonb then raise exception 'Scan must not require a file'; end if;

  -- ── nothing else moved: Lamination, the nine originals, the retired placeholder ──
  if v_lam_before -> 0 ->> 'source_key' <> 'a3-lamination' or v_lam_before -> 0 -> 'pricing_definition' is distinct from '{"strategy":"PER_UNIT","unitPrice":30,"minUnits":1,"maxUnits":100}'::jsonb
     or v_lam_before -> 1 -> 'pricing_definition' is distinct from '{"strategy":"PER_UNIT","unitPrice":15,"minUnits":1,"maxUnits":100}'::jsonb
     or v_lam_before -> 0 ->> 'pricing_version' <> '2026-09-qsc-17' or v_lam_before -> 1 ->> 'pricing_version' <> '2026-09-qsc-17'
     or v_lam_before -> 0 ->> 'status' <> 'published' or v_lam_before -> 1 ->> 'status' <> 'published' then
    raise exception 'A4 and A3 Lamination must be exactly as 01J left them: %', v_lam_before;
  end if;
  if (select array_agg(c.source_key order by c.source_key) from commerce.service_product_configs c
      where c.tenant_id = v_tenant and c.status <> 'archived' and c.pricing_definition ->> 'strategy' = 'PER_UNIT')
     is distinct from array['a3-lamination','a4-lamination','scan'] then
    raise exception 'the non-retired PER_UNIT products must be exactly Scan, A4 Lamination and A3 Lamination';
  end if;
  if (select count(*) from commerce.service_product_configs c where c.tenant_id = v_tenant and c.status <> 'archived') <> 12
     or (select count(*) from commerce.service_product_configs c where c.tenant_id = v_tenant) <> 13 then
    raise exception 'nine originals + Scan + A4 + A3 = 12 live configs, plus the retired placeholder = 13';
  end if;
  if (select c.status from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'lamination') <> 'archived' then
    raise exception 'the retired generic lamination must stay archived';
  end if;

  -- ── the confirmed prices, through the real server path ──────────────────
  if pg_temp.price('scan','1') <> 5 or pg_temp.price('scan','4') <> 20 or pg_temp.price('scan','100') <> 500 or pg_temp.price('scan','300') <> 1500 then
    raise exception 'Scan must price 1 -> R5, 4 -> R20, 100 -> R500, 300 -> R1500';
  end if;
  v_result := commerce.qs_calculate_price(v_tenant, 'scan', '{"units":4}');
  if v_result ->> 'summary' is distinct from '4 × 5.00' or v_result -> 'metrics' is distinct from '{"units":4,"unitPrice":5}'::jsonb then
    raise exception 'unexpected Scan envelope: %', v_result;
  end if;
  if pg_temp.price('scan','"7"') <> 35 then raise exception 'digit-string units must price'; end if;
  if pg_temp.price('scan','4') <> (commerce.qs_calculate_price(v_tenant, 'scan', '{"units":4,"quantity":9}') ->> 'total')::numeric then
    raise exception 'a quantity key must be ignored, never used as units';
  end if;

  -- ── invalid units fail through the real server path ─────────────────────
  perform pg_temp.expect_error(format('select commerce.qs_calculate_price(%L,%L,%L::jsonb)', v_tenant, 'scan', '{}'), 'units missing', '22023', 'Units are required.');
  perform pg_temp.expect_error(format('select commerce.qs_calculate_price(%L,%L,%L::jsonb)', v_tenant, 'scan', '{"quantity":3}'), 'quantity cannot substitute for units', '22023', 'Units are required.');
  perform pg_temp.expect_error(format('select commerce.qs_calculate_price(%L,%L,%L::jsonb)', v_tenant, 'scan', '{"units":null}'), 'units null', '22023', 'Units are required.');
  foreach v_case in array array['"abc"', '2.5', '0.5', '"3.0"', '"007"', '"1e1"', '" 3"', '"+3"', 'true', '[3]'] loop
    perform pg_temp.expect_error(format('select commerce.qs_calculate_price(%L,%L,%L::jsonb)', v_tenant, 'scan', '{"units":' || v_case || '}'),
      'scan units ' || v_case, '22023', 'Units must be a whole number.');
  end loop;
  foreach v_case in array array['0', '-3', '301', '"301"', '"1234567890"', '"0"'] loop
    perform pg_temp.expect_error(format('select commerce.qs_calculate_price(%L,%L,%L::jsonb)', v_tenant, 'scan', '{"units":' || v_case || '}'),
      'scan units ' || v_case, '22023', 'Units are outside the supported range.');
  end loop;

  -- ── live, yet never public: counter-only at every layer ─────────────────
  select string_agg(p ->> 'id', ',' order by p ->> 'id') into v_ids
  from jsonb_array_elements(public.get_quick_solution_catalog('quick-solution') -> 'products') p;
  if v_ids like '%scan%' then raise exception 'the public catalogue must not return Scan, even though it is live: %', v_ids; end if;
  if v_ids is distinct from 'a4-print,business-cards,flags,gazebos,media-services,photo-session,printed-tshirt,pvc-banner,vinyl-stickers' then
    raise exception 'the public catalogue must still return exactly the nine original products, got %', v_ids;
  end if;
  if commerce._qs_product_channel_enabled(v_tenant, 'scan', 'counter') is distinct from true
     or commerce._qs_product_channel_enabled(v_tenant, 'scan', 'storefront') is distinct from false then
    raise exception 'Scan must be counter-enabled and storefront-disabled';
  end if;
  insert into commerce.service_orders(id,tenant_id,order_number,customer_name,idempotency_key)
  values (v_order_storefront, v_tenant, 'CG01K-S-'||left(v_suffix,10), 'CAFE GUEST 01K storefront', 'cg01k-'||v_suffix||'-s');
  insert into commerce.service_orders(id,tenant_id,order_number,customer_name,idempotency_key,channel,created_by)
  values (v_order_counter, v_tenant, 'CG01K-C-'||left(v_suffix,10), 'Walk-in', 'cg01k-'||v_suffix||'-c', 'counter', v_staff);
  perform pg_temp.expect_error(
    format('insert into commerce.service_order_items(order_id,tenant_id,product_id,product_key,product_name) values (%L,%L,%L,%L,%L)',
      v_order_storefront, v_tenant, v_product.id, 'scan', v_product.name),
    'Scan on a storefront order', '22023', 'PRODUCT_NOT_AVAILABLE_FOR_CHANNEL');
  insert into commerce.service_order_items(order_id,tenant_id,product_id,product_key,product_name)
  values (v_order_counter, v_tenant, v_product.id, 'scan', v_product.name);

  -- ── admin: Scan is editable through the existing PER_UNIT path, independently ──
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'jointx.co@gmail.com')::text, true);
  select string_agg(p ->> 'id', ',' order by p ->> 'id') into v_ids
  from jsonb_array_elements(public.admin_get_quick_solution_catalog('quick-solution') -> 'products') p;
  if v_ids not like '%scan%' then raise exception 'Scan must appear in the admin catalogue: %', v_ids; end if;

  -- Saving Scan exactly as shipped is accepted (the approved pricing is valid).
  v_result := public.admin_update_quick_solution_product('quick-solution', 'scan', v_config.customer_definition, v_config.pricing_definition, v_config.pricing_version);
  if v_result ->> 'ok' is distinct from 'true' then raise exception 'saving Scan as shipped failed: %', v_result; end if;

  -- The admin still refuses invalid values, and they change nothing.
  select * into v_config from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'scan';
  perform pg_temp.expect_error(
    format('select public.admin_update_quick_solution_product(%L,%L,%L::jsonb,%L::jsonb,%L)', 'quick-solution', 'scan',
      v_config.customer_definition, '{"strategy":"PER_UNIT","unitPrice":0,"minUnits":1,"maxUnits":300}', v_config.pricing_version),
    'a zero price', '22023', 'Pricing configuration is invalid.');
  perform pg_temp.expect_error(
    format('select public.admin_update_quick_solution_product(%L,%L,%L::jsonb,%L::jsonb,%L)', 'quick-solution', 'scan',
      v_config.customer_definition, '{"strategy":"PER_UNIT","unitPrice":5,"minUnits":1,"maxUnits":0}', v_config.pricing_version),
    'a zero maximum', '22023', 'Pricing configuration is invalid.');
  perform pg_temp.expect_error(
    format('select public.admin_update_quick_solution_product(%L,%L,%L::jsonb,%L::jsonb,%L)', 'quick-solution', 'scan',
      v_config.customer_definition, '{"strategy":"PER_UNIT","unitPrice":5.005,"minUnits":1,"maxUnits":300}', v_config.pricing_version),
    'a fractional-cent price', '22023', 'Pricing configuration is invalid.');
  if pg_temp.price('scan','300') <> 1500 then raise exception 'a rejected save must change nothing'; end if;

  -- Edit Scan only (test numbers): Scan changes, A4/A3 do not move at all.
  select * into v_config from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'scan';
  v_result := public.admin_update_quick_solution_product('quick-solution', 'scan',
    jsonb_set(v_config.customer_definition, '{pricing}', '{"strategy":"PER_UNIT","unitPrice":6.5,"minUnits":1,"maxUnits":250}'),
    '{"strategy":"PER_UNIT","unitPrice":6.5,"minUnits":1,"maxUnits":250}', v_config.pricing_version);
  if v_result ->> 'ok' is distinct from 'true' then raise exception 'editing Scan failed: %', v_result; end if;
  if pg_temp.price('scan','4') <> 26 or pg_temp.price('scan','250') <> 1625 then raise exception 'Scan must price at its edited price and maximum'; end if;
  perform pg_temp.expect_error(format('select commerce.qs_calculate_price(%L,%L,%L::jsonb)', v_tenant, 'scan', '{"units":251}'),
    'Scan above its edited maximum', '22023', 'Units are outside the supported range.');
  if pg_temp.lamination_rows() is distinct from v_lam_before then raise exception 'editing Scan must not change A4/A3 Lamination at all'; end if;
  if pg_temp.price('a4-lamination','4') <> 60 or pg_temp.price('a3-lamination','4') <> 120 then raise exception 'Lamination must still price at R15 / R30'; end if;
  select * into v_config from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'scan';
  if v_config.pricing_definition is distinct from '{"strategy":"PER_UNIT","unitPrice":6.5,"minUnits":1,"maxUnits":250}'::jsonb
     or v_config.customer_definition -> 'pricing' is distinct from v_config.pricing_definition
     or v_config.customer_definition -> 'channels' is distinct from '{"storefront":false,"guided":false,"pos":true,"quote":false,"advanced":false}'::jsonb then
    raise exception 'after an admin edit: still the four keys, mirror equal, channels unchanged';
  end if;

  -- And the other way round: editing A4 does not move Scan.
  select to_jsonb(c) into v_scan_before from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'scan';
  select * into v_config from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'a4-lamination';
  v_result := public.admin_update_quick_solution_product('quick-solution', 'a4-lamination',
    jsonb_set(v_config.customer_definition, '{pricing}', '{"strategy":"PER_UNIT","unitPrice":20,"minUnits":1,"maxUnits":100}'),
    '{"strategy":"PER_UNIT","unitPrice":20,"minUnits":1,"maxUnits":100}', v_config.pricing_version);
  if v_result ->> 'ok' is distinct from 'true' then raise exception 'editing A4 failed: %', v_result; end if;
  if (select to_jsonb(c) from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'scan') is distinct from v_scan_before then
    raise exception 'editing A4 Lamination must not change the Scan row at all';
  end if;
  -- Put A4 back so later phases can assert Lamination is exactly as shipped.
  select * into v_config from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'a4-lamination';
  perform public.admin_update_quick_solution_product('quick-solution', 'a4-lamination',
    jsonb_set(v_config.customer_definition, '{pricing}', '{"strategy":"PER_UNIT","unitPrice":15,"minUnits":1,"maxUnits":100}'),
    '{"strategy":"PER_UNIT","unitPrice":15,"minUnits":1,"maxUnits":100}', v_config.pricing_version);
  perform set_config('cg01k.lamination', pg_temp.lamination_rows()::text, true);

  -- The admin takes Scan offline (as an administrator may). It must stay offline through a replay.
  select * into v_config from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'scan';
  v_result := public.admin_update_quick_solution_product('quick-solution', 'scan',
    jsonb_set(v_config.customer_definition, '{active}', 'false'), v_config.pricing_definition, v_config.pricing_version);
  if v_result ->> 'ok' is distinct from 'true' then raise exception 'taking Scan offline failed: %', v_result; end if;
  perform pg_temp.expect_error(format('select commerce.qs_calculate_price(%L,%L,%L::jsonb)', v_tenant, 'scan', '{"units":2}'),
    'an offline Scan cannot be priced', '22023', 'Product is not available.');
end
$phase1$;

-- ═════════ phase 2: re-apply over an admin-edited AND offline Scan ═════════
\ir ../migrations/20260926180000_cafe_guest_01k_scan_final.sql

do $phase2$
declare
  v_tenant uuid;
  v_config commerce.service_product_configs;
  v_product commerce.products;
begin
  select t.id into v_tenant from public.tenants t where t.slug = 'quick-solution';
  select * into v_config from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'scan';
  select * into v_product from commerce.products p where p.id = v_config.product_id;

  if v_config.pricing_definition is distinct from '{"strategy":"PER_UNIT","unitPrice":6.5,"minUnits":1,"maxUnits":250}'::jsonb then
    raise exception 're-applying must not overwrite the edited Scan price (R6.50) and maximum (250): %', v_config.pricing_definition;
  end if;
  if v_config.pricing_version = '2026-09-qsc-18' then raise exception 're-applying must not reset the version an admin save issued'; end if;
  if v_config.status <> 'draft' or v_product.status <> 'draft' or v_product.availability <> 'unavailable'
     or (v_config.customer_definition ->> 'active')::boolean is distinct from false then
    raise exception 're-applying must not republish a Scan an admin took offline: config %, product %, availability %', v_config.status, v_product.status, v_product.availability;
  end if;
  if pg_temp.lamination_rows()::text is distinct from current_setting('cg01k.lamination') then
    raise exception 're-applying must not touch A4 or A3 Lamination';
  end if;
  if (select count(*) from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'scan') <> 1
     or (select count(*) from commerce.service_product_configs c where c.tenant_id = v_tenant) <> 13 then
    raise exception 're-applying must not duplicate or add anything';
  end if;

  -- Simulate an environment where only 01H was ever applied: Scan exactly as 01H seeded it.
  update commerce.service_product_configs c
  set status = 'draft',
      pricing_version = '2026-09-qsc-15',
      pricing_definition = '{"strategy":"PER_UNIT","unitPrice":0,"minUnits":1,"maxUnits":0}'::jsonb,
      customer_definition = jsonb_set(jsonb_set(c.customer_definition, '{pricing}', '{"strategy":"PER_UNIT","unitPrice":0,"minUnits":1,"maxUnits":0}'::jsonb), '{active}', 'false'::jsonb)
  where c.id = v_config.id;
  update commerce.products p set status = 'draft', availability = 'unavailable' where p.id = v_config.product_id;
  perform pg_temp.expect_error(format('select commerce.qs_calculate_price(%L,%L,%L::jsonb)', v_tenant, 'scan', '{"units":2}'),
    'fixture: the 01H-only Scan is not priceable', '22023', 'Product is not available.');
end
$phase2$;

-- ═════════ phase 3: re-apply over an environment that only had 01H ═════════
\ir ../migrations/20260926180000_cafe_guest_01k_scan_final.sql

do $phase3$
declare
  v_tenant uuid;
  v_config commerce.service_product_configs;
  v_product commerce.products;
begin
  select t.id into v_tenant from public.tenants t where t.slug = 'quick-solution';
  select * into v_config from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'scan';
  select * into v_product from commerce.products p where p.id = v_config.product_id;

  if v_config.pricing_definition is distinct from '{"strategy":"PER_UNIT","unitPrice":5,"minUnits":1,"maxUnits":300}'::jsonb
     or v_config.customer_definition -> 'pricing' is distinct from v_config.pricing_definition
     or v_config.pricing_version <> '2026-09-qsc-18'
     or v_config.status <> 'published' or v_product.status <> 'published' or v_product.availability <> 'available'
     or (v_config.customer_definition ->> 'active')::boolean is distinct from true then
    raise exception 'the migration must take a 01H-only Scan to the approved live values: %', to_jsonb(v_config);
  end if;
  -- Everything the migration must NOT change is intact: channels, name, category, the one units field.
  if v_config.customer_definition -> 'channels' is distinct from '{"storefront":false,"guided":false,"pos":true,"quote":false,"advanced":false}'::jsonb
     or v_config.customer_definition ->> 'name' <> 'Document Scanning' or v_config.customer_definition ->> 'category' <> 'Quick Print'
     or jsonb_array_length(v_config.customer_definition -> 'fields') <> 1
     or v_config.customer_definition -> 'fields' -> 0 ->> 'label' <> 'How many pages need scanning?' then
    raise exception 'finalizing must not change Scan''s channels or structure: %', v_config.customer_definition;
  end if;
  if pg_temp.price('scan','300') <> 1500 or pg_temp.price('scan','1') <> 5 then raise exception 'the upgraded Scan must price R5 per page'; end if;
  if pg_temp.lamination_rows()::text is distinct from current_setting('cg01k.lamination') then
    raise exception 'the upgrade must not touch A4 or A3 Lamination';
  end if;
  if (select count(*) from commerce.service_product_configs c where c.tenant_id = v_tenant) <> 13 then
    raise exception 'the upgrade must not add or remove any product';
  end if;
  if exists (select 1 from jsonb_array_elements(public.get_quick_solution_catalog('quick-solution') -> 'products') p where p ->> 'id' = 'scan') then
    raise exception 'the upgraded Scan must still be absent from the public catalogue';
  end if;
end
$phase3$;

rollback;

select 'CAFE-GUEST-01K Scan final product contracts passed' as result;
