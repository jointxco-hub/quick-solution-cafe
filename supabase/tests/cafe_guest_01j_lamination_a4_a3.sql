-- CAFE-GUEST-01J: contract test for A4 Lamination and A3 Lamination, and for the
-- retirement of the generic 'lamination' placeholder.
--
-- Run only against the disposable local harness (supabase/tests/harness/), which
-- replays the whole migration history, including
--   20260926160000_cafe_guest_01i_lamination_product.sql   (generic placeholder)
--   20260926170000_cafe_guest_01j_lamination_a4_a3.sql     (A4 + A3, retires it)
-- so the retirement is exercised on a database that really had the placeholder.
--
-- Everything reads the REAL seeded rows. Prices the test changes (through the real
-- admin function, to prove independent editing) use the TEST'S OWN numbers and exist
-- only inside this BEGIN/ROLLBACK; the confirmed R15 / R30 / max 100 are asserted as
-- shipped BEFORE any edit.
--
-- The migration is then re-applied twice inside the transaction (\ir; it has no
-- BEGIN/COMMIT of its own): once over edited/re-activated data, once with the
-- placeholder rows gone, to prove idempotence and that nothing an admin edited is
-- overwritten.

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
      raise exception 'CAFE_GUEST_01J: % expected % containing "%" but got % "%"',
        p_case, p_sqlstate, p_token, v_state, v_message;
    end if;
    return;
  end;
  raise exception 'CAFE_GUEST_01J: % unexpectedly succeeded', p_case;
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

-- ═════════ phase 1: shipped state, pricing, guards, independent admin edits ═════════
do $phase1$
declare
  v_suffix text := replace(gen_random_uuid()::text,'-','');
  v_tenant uuid;
  v_key text;
  v_size text;
  v_other text;
  v_sort integer;
  v_price numeric;
  v_config commerce.service_product_configs;
  v_product commerce.products;
  v_generic commerce.service_product_configs;
  v_generic_product commerce.products;
  v_scan_before jsonb;
  v_a3_before jsonb;
  v_a4_before jsonb;
  v_ids text;
  v_customer jsonb;
  v_order_storefront uuid := gen_random_uuid();
  v_order_counter uuid := gen_random_uuid();
  v_staff uuid := gen_random_uuid();
  v_admin uuid := gen_random_uuid();
  v_result jsonb;
  v_case text;
begin
  select t.id into v_tenant from public.tenants t where t.slug = 'quick-solution';
  if v_tenant is null then raise exception 'the quick-solution tenant must exist'; end if;

  select to_jsonb(c) into v_scan_before from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'scan';

  -- ── each of A4 and A3: exactly once, live, confirmed definition ─────────
  foreach v_key in array array['a4-lamination','a3-lamination'] loop
    v_size := upper(left(v_key, 2));
    v_price := case v_key when 'a4-lamination' then 15 else 30 end;
    v_sort := case v_key when 'a4-lamination' then 24 else 25 end;
    v_other := case v_size when 'A4' then 'a3' else 'a4' end;

    if (select count(*) from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = v_key) <> 1
       or (select count(*) from commerce.products p where p.tenant_id = v_tenant and p.slug = v_key) <> 1 then
      raise exception '% must exist exactly once (config and product)', v_key;
    end if;
    select * into v_config from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = v_key;
    select * into v_product from commerce.products p where p.id = v_config.product_id;

    if v_product.name <> v_size || ' Lamination' or v_product.currency <> 'ZAR' then
      raise exception '% unexpected product identity: %', v_key, to_jsonb(v_product);
    end if;
    if v_config.status <> 'published' or v_product.status <> 'published' or v_product.availability <> 'available' then
      raise exception '% must be live (published + available): config %, product %, availability %', v_key, v_config.status, v_product.status, v_product.availability;
    end if;
    if v_config.pricing_version <> '2026-09-qsc-17' or v_config.sort_order <> v_sort then
      raise exception '% unexpected version/sort order: % %', v_key, v_config.pricing_version, v_config.sort_order;
    end if;

    -- The confirmed business numbers, as shipped.
    if v_config.pricing_definition is distinct from jsonb_build_object('strategy','PER_UNIT','unitPrice',v_price,'minUnits',1,'maxUnits',100) then
      raise exception '% pricing_definition must be PER_UNIT R% x 1..100, got %', v_key, v_price, v_config.pricing_definition;
    end if;
    if v_config.customer_definition -> 'pricing' is distinct from v_config.pricing_definition then
      raise exception '% customer mirror must equal the definition (four keys, nothing private)', v_key;
    end if;
    if (select array_agg(k order by k) from jsonb_object_keys(v_config.customer_definition -> 'pricing') k)
       is distinct from array['maxUnits','minUnits','strategy','unitPrice'] then
      raise exception '% customer mirror carries fields outside the contract', v_key;
    end if;
    if lower(v_config.customer_definition::text || v_config.pricing_definition::text) ~ '(quantity|supplier|margin|referenceprice|sourceurl|setupfee|minimumcharge|tier|discount|multiplier|variant|pouch|option)' then
      raise exception '% must carry no quantity, supplier, margin, source, setup fee, minimum charge, tier, discount, variant or option', v_key;
    end if;

    v_customer := v_config.customer_definition;
    if v_customer -> 'channels' is distinct from '{"storefront":false,"guided":false,"pos":true,"quote":false,"advanced":false}'::jsonb then
      raise exception '% channels must be the pinned counter-only decision, got %', v_key, v_customer -> 'channels';
    end if;
    if v_customer ->> 'category' <> 'Quick Print' or (v_customer ->> 'active')::boolean is distinct from true then
      raise exception '% category / active wrong: %', v_key, v_customer;
    end if;
    -- One field, the sheet count. No size field (the size IS the product), no options, no file.
    if jsonb_array_length(v_customer -> 'fields') <> 1
       or v_customer -> 'fields' -> 0 ->> 'id' <> 'units'
       or v_customer -> 'fields' -> 0 ->> 'type' <> 'number'
       or v_customer -> 'fields' -> 0 ? 'options'
       or v_customer -> 'fields' -> 0 ? 'max'
       or v_customer -> 'fields' -> 0 ? 'default' then
      raise exception '% has exactly one plain units field: %', v_key, v_customer -> 'fields';
    end if;
    if v_customer -> 'fields' @> '[{"type":"file"}]'::jsonb then raise exception '% must not require a file', v_key; end if;
    if v_customer::text ~* 'pages?\M' then raise exception '% unit is a sheet, never a page: %', v_key, v_customer; end if;
    -- The size named in the text is the product's own size, never the other one.
    if v_customer::text ~* v_other then
      raise exception '% mentions the other size: %', v_key, v_customer;
    end if;
  end loop;

  -- ── the confirmed prices, through the real server path ──────────────────
  if pg_temp.price('a4-lamination','1') <> 15 or pg_temp.price('a4-lamination','4') <> 60 or pg_temp.price('a4-lamination','100') <> 1500 then
    raise exception 'A4 must price 1 -> R15, 4 -> R60, 100 -> R1500';
  end if;
  if pg_temp.price('a3-lamination','1') <> 30 or pg_temp.price('a3-lamination','4') <> 120 or pg_temp.price('a3-lamination','100') <> 3000 then
    raise exception 'A3 must price 1 -> R30, 4 -> R120, 100 -> R3000';
  end if;
  v_result := commerce.qs_calculate_price(v_tenant, 'a4-lamination', '{"units":4}');
  if v_result ->> 'summary' is distinct from '4 × 15.00' or v_result -> 'metrics' is distinct from '{"units":4,"unitPrice":15}'::jsonb then
    raise exception 'unexpected A4 envelope: %', v_result;
  end if;
  if (commerce.qs_calculate_price(v_tenant, 'a3-lamination', '{"units":"7"}') ->> 'total')::numeric <> 210 then raise exception 'digit-string units must price'; end if;
  if pg_temp.price('a4-lamination','4') <> (commerce.qs_calculate_price(v_tenant, 'a4-lamination', '{"units":4,"quantity":9}') ->> 'total')::numeric then
    raise exception 'a quantity key must be ignored, never used as units';
  end if;

  -- ── invalid units fail through the real server path, for both ───────────
  foreach v_key in array array['a4-lamination','a3-lamination'] loop
    perform pg_temp.expect_error(format('select commerce.qs_calculate_price(%L,%L,%L::jsonb)', v_tenant, v_key, '{}'), v_key || ' units missing', '22023', 'Units are required.');
    perform pg_temp.expect_error(format('select commerce.qs_calculate_price(%L,%L,%L::jsonb)', v_tenant, v_key, '{"quantity":3}'), v_key || ' quantity is not units', '22023', 'Units are required.');
    perform pg_temp.expect_error(format('select commerce.qs_calculate_price(%L,%L,%L::jsonb)', v_tenant, v_key, '{"units":null}'), v_key || ' units null', '22023', 'Units are required.');
    foreach v_case in array array['"abc"', '2.5', '"007"', '"1e1"', 'true'] loop
      perform pg_temp.expect_error(format('select commerce.qs_calculate_price(%L,%L,%L::jsonb)', v_tenant, v_key, '{"units":' || v_case || '}'),
        v_key || ' units ' || v_case, '22023', 'Units must be a whole number.');
    end loop;
    foreach v_case in array array['0', '-3', '101', '"101"', '"1234567890"'] loop
      perform pg_temp.expect_error(format('select commerce.qs_calculate_price(%L,%L,%L::jsonb)', v_tenant, v_key, '{"units":' || v_case || '}'),
        v_key || ' units ' || v_case, '22023', 'Units are outside the supported range.');
    end loop;
  end loop;

  -- ── the generic placeholder is retired, and cannot be sold ──────────────
  if (select count(*) from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'lamination') <> 1 then
    raise exception 'the harness replays 01I, so the generic row must exist (retired), exactly once';
  end if;
  select * into v_generic from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'lamination';
  select * into v_generic_product from commerce.products p where p.id = v_generic.product_id;
  if v_generic.status <> 'archived' or v_generic_product.status <> 'archived' or v_generic_product.availability <> 'unavailable' then
    raise exception 'generic lamination must be archived: config %, product %, availability %', v_generic.status, v_generic_product.status, v_generic_product.availability;
  end if;
  if (v_generic.customer_definition ->> 'active')::boolean is distinct from false
     or v_generic.customer_definition -> 'channels' is distinct from '{"storefront":false,"guided":false,"pos":false,"quote":false,"advanced":false}'::jsonb then
    raise exception 'generic lamination must be inactive with every channel off (pos included): %', v_generic.customer_definition;
  end if;
  if v_generic.pricing_version <> '2026-09-qsc-16-retired' then raise exception 'retired version marker wrong: %', v_generic.pricing_version; end if;
  -- What 01I seeded is otherwise kept, not destroyed.
  if v_generic.pricing_definition is distinct from '{"strategy":"PER_UNIT","unitPrice":0,"minUnits":1,"maxUnits":0}'::jsonb
     or v_generic.customer_definition ->> 'name' <> 'Lamination' then
    raise exception 'retirement must keep the row content: %', to_jsonb(v_generic);
  end if;
  perform pg_temp.expect_error(format('select commerce.qs_calculate_price(%L, %L, %L::jsonb)', v_tenant, 'lamination', '{"units":3}'),
    'the retired generic lamination cannot be priced', '22023', 'Product is not available.');
  if commerce._qs_product_channel_enabled(v_tenant, 'lamination', 'counter') is distinct from false
     or commerce._qs_product_channel_enabled(v_tenant, 'lamination', 'storefront') is distinct from false then
    raise exception 'the retired generic lamination must be enabled on no channel';
  end if;

  -- ── no third size, no other new product, Scan untouched ─────────────────
  if exists (select 1 from commerce.service_product_configs c where c.tenant_id = v_tenant and c.status <> 'archived'
             and (lower(c.source_key || (c.customer_definition ->> 'name')) ~ 'a[0-9]-?lamin|lamin.*a[0-9]' and c.source_key not in ('a4-lamination','a3-lamination'))) then
    raise exception 'no size other than A4 and A3 may exist';
  end if;
  if (select array_agg(c.source_key order by c.source_key) from commerce.service_product_configs c
      where c.tenant_id = v_tenant and c.status <> 'archived' and c.pricing_definition ->> 'strategy' = 'PER_UNIT')
     is distinct from array['a3-lamination','a4-lamination','scan'] then
    raise exception 'the non-retired PER_UNIT products must be exactly Scan, A4 Lamination and A3 Lamination';
  end if;
  if (select count(*) from commerce.service_product_configs c where c.tenant_id = v_tenant and c.status <> 'archived') <> 12 then
    raise exception 'the nine original products plus Scan, A4 and A3 = 12 live configs';
  end if;
  -- Scan's own price and live state are CAFE-GUEST-01K's business, not this test's: what
  -- matters here is that 01J left its identity and channels alone and never touches it
  -- afterwards (compared against a snapshot at the end of this phase and in phase 2).
  if v_scan_before ->> 'sort_order' <> '22' or v_scan_before -> 'pricing_definition' ->> 'strategy' <> 'PER_UNIT'
     or v_scan_before -> 'customer_definition' ->> 'name' <> 'Document Scanning'
     or v_scan_before -> 'customer_definition' -> 'channels' is distinct from '{"storefront":false,"guided":false,"pos":true,"quote":false,"advanced":false}'::jsonb then
    raise exception 'Scan is untouched by Lamination: %', v_scan_before;
  end if;
  perform set_config('cg01j.scan', v_scan_before::text, true);

  -- ── the public catalogue is unchanged: nothing storefront=false leaks ──
  select string_agg(p ->> 'id', ',' order by p ->> 'id') into v_ids
  from jsonb_array_elements(public.get_quick_solution_catalog('quick-solution') -> 'products') p;
  if v_ids is distinct from 'a4-print,business-cards,flags,gazebos,media-services,photo-session,printed-tshirt,pvc-banner,vinyl-stickers' then
    raise exception 'the public catalogue must still return exactly the nine original products even though A4/A3 are live, got %', v_ids;
  end if;

  -- ── channel decisions hold at the database guard ────────────────────────
  foreach v_key in array array['a4-lamination','a3-lamination'] loop
    if commerce._qs_product_channel_enabled(v_tenant, v_key, 'counter') is distinct from true
       or commerce._qs_product_channel_enabled(v_tenant, v_key, 'storefront') is distinct from false then
      raise exception '% must be counter-enabled and storefront-disabled', v_key;
    end if;
  end loop;
  insert into commerce.service_orders(id,tenant_id,order_number,customer_name,idempotency_key)
  values (v_order_storefront, v_tenant, 'CG01J-S-'||left(v_suffix,10), 'CAFE GUEST 01J storefront', 'cg01j-'||v_suffix||'-s');
  insert into commerce.service_orders(id,tenant_id,order_number,customer_name,idempotency_key,channel,created_by)
  values (v_order_counter, v_tenant, 'CG01J-C-'||left(v_suffix,10), 'Walk-in', 'cg01j-'||v_suffix||'-c', 'counter', v_staff);
  foreach v_key in array array['a4-lamination','a3-lamination'] loop
    select p.* into v_product from commerce.products p where p.tenant_id = v_tenant and p.slug = v_key;
    perform pg_temp.expect_error(
      format('insert into commerce.service_order_items(order_id,tenant_id,product_id,product_key,product_name) values (%L,%L,%L,%L,%L)',
        v_order_storefront, v_tenant, v_product.id, v_key, v_product.name),
      v_key || ' on a storefront order', '22023', 'PRODUCT_NOT_AVAILABLE_FOR_CHANNEL');
    insert into commerce.service_order_items(order_id,tenant_id,product_id,product_key,product_name)
    values (v_order_counter, v_tenant, v_product.id, v_key, v_product.name);
  end loop;

  -- ── admin: both are editable independently, through the existing PER_UNIT path ──
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'jointx.co@gmail.com')::text, true);

  select string_agg(p ->> 'id', ',' order by p ->> 'id') into v_ids
  from jsonb_array_elements(public.admin_get_quick_solution_catalog('quick-solution') -> 'products') p;
  if v_ids like '%,lamination,%' or v_ids like 'lamination,%' or v_ids like '%,lamination' then
    raise exception 'the retired generic lamination must not appear in the admin catalogue: %', v_ids;
  end if;
  if v_ids not like '%a3-lamination%' or v_ids not like '%a4-lamination%' then
    raise exception 'A4 and A3 must both appear in the admin catalogue: %', v_ids;
  end if;

  -- Saving A4 exactly as shipped is accepted (the confirmed pricing is valid).
  select * into v_config from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'a4-lamination';
  v_result := public.admin_update_quick_solution_product('quick-solution', 'a4-lamination', v_config.customer_definition, v_config.pricing_definition, v_config.pricing_version);
  if v_result ->> 'ok' is distinct from 'true' then raise exception 'saving A4 as shipped failed: %', v_result; end if;

  -- Edit A4 only (test numbers): A4 changes, A3 does not move at all.
  select to_jsonb(c) into v_a3_before from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'a3-lamination';
  select * into v_config from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'a4-lamination';
  v_result := public.admin_update_quick_solution_product('quick-solution', 'a4-lamination',
    jsonb_set(v_config.customer_definition, '{pricing}', '{"strategy":"PER_UNIT","unitPrice":20,"minUnits":1,"maxUnits":50}'),
    '{"strategy":"PER_UNIT","unitPrice":20,"minUnits":1,"maxUnits":50}', v_config.pricing_version);
  if v_result ->> 'ok' is distinct from 'true' then raise exception 'editing A4 failed: %', v_result; end if;
  if pg_temp.price('a4-lamination','4') <> 80 or pg_temp.price('a4-lamination','50') <> 1000 then raise exception 'A4 must price at its edited price and maximum'; end if;
  perform pg_temp.expect_error(format('select commerce.qs_calculate_price(%L,%L,%L::jsonb)', v_tenant, 'a4-lamination', '{"units":51}'),
    'A4 above its edited maximum', '22023', 'Units are outside the supported range.');
  if (select to_jsonb(c) from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'a3-lamination') is distinct from v_a3_before then
    raise exception 'editing A4 must not change the A3 row at all';
  end if;
  if pg_temp.price('a3-lamination','4') <> 120 or pg_temp.price('a3-lamination','100') <> 3000 then raise exception 'A3 must still price at R30 after A4 was edited'; end if;

  -- Edit A3 only: A3 changes, the (already edited) A4 does not move.
  select to_jsonb(c) into v_a4_before from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'a4-lamination';
  select * into v_config from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'a3-lamination';
  v_result := public.admin_update_quick_solution_product('quick-solution', 'a3-lamination',
    jsonb_set(v_config.customer_definition, '{pricing}', '{"strategy":"PER_UNIT","unitPrice":35,"minUnits":1,"maxUnits":80}'),
    '{"strategy":"PER_UNIT","unitPrice":35,"minUnits":1,"maxUnits":80}', v_config.pricing_version);
  if v_result ->> 'ok' is distinct from 'true' then raise exception 'editing A3 failed: %', v_result; end if;
  if pg_temp.price('a3-lamination','4') <> 140 or pg_temp.price('a3-lamination','80') <> 2800 then raise exception 'A3 must price at its edited price and maximum'; end if;
  if (select to_jsonb(c) from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'a4-lamination') is distinct from v_a4_before then
    raise exception 'editing A3 must not change the A4 row at all';
  end if;
  if pg_temp.price('a4-lamination','4') <> 80 then raise exception 'A4 must be unaffected by the A3 edit'; end if;

  -- The admin still refuses an invalid edit, and it changes nothing.
  select * into v_config from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'a4-lamination';
  perform pg_temp.expect_error(
    format('select public.admin_update_quick_solution_product(%L,%L,%L::jsonb,%L::jsonb,%L)', 'quick-solution', 'a4-lamination',
      v_config.customer_definition, '{"strategy":"PER_UNIT","unitPrice":0,"minUnits":1,"maxUnits":100}', v_config.pricing_version),
    'a zero price', '22023', 'Pricing configuration is invalid.');

  -- Editing A4 and A3 (above) did not move Scan.
  if (select to_jsonb(c) from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'scan') is distinct from v_scan_before then
    raise exception 'editing A4/A3 Lamination must not change the Scan row at all';
  end if;

  -- Simulate an environment where the placeholder was applied and then edited / re-activated by an admin.
  update commerce.service_product_configs c
  set status = 'published',
      pricing_definition = jsonb_set(jsonb_set(c.pricing_definition, '{unitPrice}', '5'), '{maxUnits}', '10'),
      customer_definition = jsonb_set(jsonb_set(c.customer_definition, '{active}', 'true'), '{channels}', '{"storefront":false,"guided":false,"pos":true,"quote":false,"advanced":false}')
  where c.tenant_id = v_tenant and c.source_key = 'lamination';
  update commerce.products p set status = 'published', availability = 'available' where p.tenant_id = v_tenant and p.slug = 'lamination';
  if pg_temp.price('lamination','2') <> 10 then raise exception 'fixture: the re-activated placeholder should price at the edited 5 x 2'; end if;
end
$phase1$;

-- ═════════ phase 2: re-apply the migration over edited and re-activated data ═════════
\ir ../migrations/20260926170000_cafe_guest_01j_lamination_a4_a3.sql

do $phase2$
declare
  v_tenant uuid;
  v_generic commerce.service_product_configs;
  v_generic_product commerce.products;
  v_row record;
begin
  select t.id into v_tenant from public.tenants t where t.slug = 'quick-solution';

  -- The re-activated placeholder is retired again; what the admin entered on it is kept.
  select * into v_generic from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'lamination';
  select * into v_generic_product from commerce.products p where p.id = v_generic.product_id;
  if v_generic.status <> 'archived' or v_generic_product.status <> 'archived' or v_generic_product.availability <> 'unavailable'
     or (v_generic.customer_definition ->> 'active')::boolean is distinct from false
     or v_generic.customer_definition -> 'channels' is distinct from '{"storefront":false,"guided":false,"pos":false,"quote":false,"advanced":false}'::jsonb then
    raise exception 're-applying must retire the re-activated placeholder again: %', to_jsonb(v_generic);
  end if;
  if v_generic.pricing_definition -> 'unitPrice' is distinct from '5'::jsonb then raise exception 'retirement must keep the price an admin entered'; end if;
  if v_generic.pricing_version <> '2026-09-qsc-16-retired' then raise exception 'the retired marker must not stack: %', v_generic.pricing_version; end if;
  perform pg_temp.expect_error(format('select commerce.qs_calculate_price(%L, %L, %L::jsonb)', v_tenant, 'lamination', '{"units":2}'),
    'the placeholder cannot be priced after re-retirement', '22023', 'Product is not available.');

  -- Nothing an admin edited on A4 / A3 was overwritten, and nothing was duplicated.
  if pg_temp.price('a4-lamination','4') <> 80 or pg_temp.price('a3-lamination','4') <> 140 then
    raise exception 're-applying must not overwrite the edited A4 (R20) and A3 (R35) prices';
  end if;
  for v_row in select k from unnest(array['a4-lamination','a3-lamination']) k loop
    if (select count(*) from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = v_row.k) <> 1
       or (select count(*) from commerce.products p where p.tenant_id = v_tenant and p.slug = v_row.k) <> 1 then
      raise exception 're-applying must not duplicate %', v_row.k;
    end if;
  end loop;
  if (select count(*) from commerce.service_product_configs c where c.tenant_id = v_tenant) <> 13 then
    raise exception 'twelve live configs plus the retired placeholder = 13 configs in total';
  end if;
  if (select to_jsonb(c) from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'scan')
     is distinct from current_setting('cg01j.scan')::jsonb then
    raise exception 're-applying must not touch Scan';
  end if;

  -- Remove the placeholder entirely (an environment that never had it).
  delete from commerce.service_order_items i using commerce.products p where i.product_id = p.id and p.slug = 'lamination';
  delete from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'lamination';
  delete from commerce.products p where p.tenant_id = v_tenant and p.slug = 'lamination';
end
$phase2$;

-- ═════════ phase 3: re-apply again with no placeholder present ═════════
\ir ../migrations/20260926170000_cafe_guest_01j_lamination_a4_a3.sql

do $phase3$
declare
  v_tenant uuid;
begin
  select t.id into v_tenant from public.tenants t where t.slug = 'quick-solution';
  if exists (select 1 from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'lamination')
     or exists (select 1 from commerce.products p where p.tenant_id = v_tenant and p.slug = 'lamination') then
    raise exception 'with no placeholder the migration must not create one';
  end if;
  if (select count(*) from commerce.service_product_configs c where c.tenant_id = v_tenant) <> 12 then
    raise exception 'twelve configs remain: nine originals, Scan, A4 and A3';
  end if;
  if pg_temp.price('a4-lamination','4') <> 80 or pg_temp.price('a3-lamination','4') <> 140 then
    raise exception 'a third run must still keep the edited prices';
  end if;
end
$phase3$;

rollback;

select 'CAFE-GUEST-01J A4 and A3 Lamination contracts passed' as result;
