-- CAFE-GUEST-01F: contract test for the neutral PER_UNIT pricing strategy.
--
-- Run only against an isolated database that has the real Quick Solution
-- effective schema (commerce.products, commerce.service_product_configs,
-- commerce.qs_calculate_price and commerce.qs_calculate_price_legacy,
-- public.tenants) after applying:
--   20260926130000_cafe_guest_01f_per_unit_pricing.sql
-- Executed by the disposable local harness (supabase/tests/harness/run-local-sql-tests.ps1),
-- which replays the migration history onto the OPPS-owned base layer. The static
-- counterpart is tests/per-unit-pricing.test.mjs, which holds the same case
-- table against the client mirror. Every case name below also appears there.
--
-- All fixtures are synthetic and enclosed by BEGIN/ROLLBACK. The rates in
-- these fixtures are the test's own; no repository price is used.

\set ON_ERROR_STOP on

begin;

-- Test-only helper (pg_temp, rolled back): runs one statement and requires the
-- exact SQLSTATE and that the message contains the expected stable text.
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
      raise exception 'CAFE_GUEST_01F: % expected % containing "%" but got % "%"',
        p_case, p_sqlstate, p_token, v_state, v_message;
    end if;
    return;
  end;
  raise exception 'CAFE_GUEST_01F: % unexpectedly succeeded', p_case;
end
$helper$;

do $catalog$
declare
  v_helper regprocedure := to_regprocedure('commerce._qs_price_per_unit(jsonb,jsonb)');
  v_validator regprocedure := to_regprocedure('commerce._qs_validate_per_unit_definition(jsonb)');
  v_wrapper regprocedure := to_regprocedure('commerce.qs_calculate_price(uuid,text,jsonb)');
  v_oid regprocedure;
begin
  if v_helper is null or v_validator is null or v_wrapper is null then
    raise exception 'the PER_UNIT helper, its definition validator and the price wrapper must exist';
  end if;
  foreach v_oid in array array[v_helper, v_validator, v_wrapper] loop
    if has_function_privilege('anon', v_oid, 'EXECUTE')
       or has_function_privilege('authenticated', v_oid, 'EXECUTE') then
      raise exception '% must not be executable by anon or authenticated', v_oid;
    end if;
  end loop;
  if has_function_privilege('service_role', v_helper, 'EXECUTE')
     or has_function_privilege('service_role', v_validator, 'EXECUTE') then
    raise exception 'the internal PER_UNIT helpers must not be executable by service_role';
  end if;
  foreach v_oid in array array[v_helper, v_validator] loop
    if not exists (
      select 1
      from pg_catalog.pg_proc p,
           lateral pg_catalog.pg_options_to_table(p.proconfig) config
      where p.oid = v_oid
        and config.option_name = 'search_path'
        and btrim(config.option_value, chr(34)) = ''
    ) then
      raise exception '% must use an empty hardened search_path', v_oid;
    end if;
  end loop;
  if lower(pg_catalog.pg_get_functiondef(v_helper)) ~ '(quantity|supplier|margin|referenceprice)' then
    raise exception 'the helper must not mention quantity, supplier cost or margin';
  end if;
end
$catalog$;

do $behavior$
declare
  v_suffix text := replace(gen_random_uuid()::text,'-','');
  v_tenant uuid := gen_random_uuid();
  v_product uuid;
  v_definition constant jsonb := '{"strategy":"PER_UNIT","unitPrice":19.99,"minUnits":1,"maxUnits":50}';
  v_result jsonb;
begin
  -- ── basic calculation and boundaries (pure helper) ─────────────────
  v_result := commerce._qs_price_per_unit('{"unitPrice":2.5,"minUnits":1,"maxUnits":10}', '{"units":1}');
  if (v_result ->> 'total')::numeric <> 2.50 then raise exception 'one unit at 2.50 must total 2.50, got %', v_result; end if;

  v_result := commerce._qs_price_per_unit(v_definition, '{"units":3}');
  if (v_result ->> 'total')::numeric <> 59.97 then raise exception '3 units at 19.99 must total 59.97, got %', v_result; end if;
  if v_result ->> 'summary' is distinct from '3 × 19.99' then raise exception 'summary changed: %', v_result; end if;
  if v_result -> 'lines' is distinct from '[{"label":"Units","value":59.97}]'::jsonb then raise exception 'lines changed: %', v_result; end if;
  if v_result -> 'metrics' is distinct from '{"units":3,"unitPrice":19.99}'::jsonb then raise exception 'metrics changed (and must never hold quantity): %', v_result; end if;

  v_result := commerce._qs_price_per_unit('{"unitPrice":0.05,"minUnits":1,"maxUnits":100}', '{"units":"12"}');
  if (v_result ->> 'total')::numeric <> 0.60 then raise exception 'digit string 12 at 0.05 must total 0.60, got %', v_result; end if;

  v_result := commerce._qs_price_per_unit(v_definition, '{"units":3.0}');
  if (v_result ->> 'total')::numeric <> 59.97 then raise exception 'JSON 3.0 is a whole number, got %', v_result; end if;

  v_result := commerce._qs_price_per_unit(v_definition, '{"units":1}');
  if (v_result ->> 'total')::numeric <> 19.99 then raise exception 'minUnits boundary failed: %', v_result; end if;
  v_result := commerce._qs_price_per_unit(v_definition, '{"units":50}');
  if (v_result ->> 'total')::numeric <> 999.50 then raise exception 'maxUnits boundary failed: %', v_result; end if;
  v_result := commerce._qs_price_per_unit('{"unitPrice":100000,"minUnits":1,"maxUnits":10000}', '{"units":10000}');
  if (v_result ->> 'total')::numeric <> 1000000000 then raise exception 'ceiling total failed: %', v_result; end if;

  -- ── invalid unit counts ────────────────────────────────────────────
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', v_definition, '{}'),
    'units missing', '22023', 'Units are required.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', v_definition, '{"units":null}'),
    'units null', '22023', 'Units are required.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', v_definition, '{"units":"abc"}'),
    'units letters', '22023', 'Units must be a whole number.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', v_definition, '{"units":""}'),
    'units empty string', '22023', 'Units must be a whole number.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', v_definition, '{"units":" 3"}'),
    'units leading space', '22023', 'Units must be a whole number.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', v_definition, '{"units":"3 "}'),
    'units trailing space', '22023', 'Units must be a whole number.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', v_definition, '{"units":"+3"}'),
    'units plus sign', '22023', 'Units must be a whole number.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', v_definition, '{"units":"-3"}'),
    'units minus string', '22023', 'Units must be a whole number.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', v_definition, '{"units":"3.0"}'),
    'units decimal string', '22023', 'Units must be a whole number.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', v_definition, '{"units":"1e1"}'),
    'units exponent string', '22023', 'Units must be a whole number.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', v_definition, '{"units":"007"}'),
    'units leading zeros', '22023', 'Units must be a whole number.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', v_definition, '{"units":3.5}'),
    'units fractional number', '22023', 'Units must be a whole number.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', v_definition, '{"units":true}'),
    'units boolean', '22023', 'Units must be a whole number.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', v_definition, '{"units":[3]}'),
    'units array', '22023', 'Units must be a whole number.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', v_definition, '{"units":{}}'),
    'units object', '22023', 'Units must be a whole number.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', v_definition, '{"units":0}'),
    'units zero', '22023', 'Units are outside the supported range.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', v_definition, '{"units":"0"}'),
    'units zero string', '22023', 'Units are outside the supported range.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', v_definition, '{"units":-3}'),
    'units negative number', '22023', 'Units are outside the supported range.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', v_definition, '{"units":51}'),
    'units above maxUnits', '22023', 'Units are outside the supported range.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', v_definition, '{"units":"1234567890"}'),
    'units more than nine digits', '22023', 'Units are outside the supported range.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', v_definition, '{"units":1e30}'),
    'units enormous number', '22023', 'Units are outside the supported range.');
  -- The nine-digit cap must stop the numeric cast: a string too long for
  -- numeric would otherwise raise a different, database-internal error.
  perform pg_temp.expect_error(
    format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', v_definition, jsonb_build_object('units', '1' || repeat('0', 150000))::text),
    'units digit string longer than numeric can hold', '22023', 'Units are outside the supported range.');

  -- ── invalid pricing definitions ────────────────────────────────────
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', '{"unitPrice":0,"minUnits":1,"maxUnits":5}', '{"units":1}'),
    'unitPrice zero', '22023', 'Pricing configuration is invalid.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', '{"unitPrice":-1,"minUnits":1,"maxUnits":5}', '{"units":1}'),
    'unitPrice negative', '22023', 'Pricing configuration is invalid.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', '{"unitPrice":100000.01,"minUnits":1,"maxUnits":5}', '{"units":1}'),
    'unitPrice above ceiling', '22023', 'Pricing configuration is invalid.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', '{"unitPrice":19.995,"minUnits":1,"maxUnits":5}', '{"units":1}'),
    'unitPrice fractional cent', '22023', 'Pricing configuration is invalid.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', '{"unitPrice":"19.99","minUnits":1,"maxUnits":5}', '{"units":1}'),
    'unitPrice string', '22023', 'Pricing configuration is invalid.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', '{"minUnits":1,"maxUnits":5}', '{"units":1}'),
    'unitPrice missing', '22023', 'Pricing configuration is invalid.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', '{"unitPrice":1,"minUnits":0,"maxUnits":5}', '{"units":1}'),
    'minUnits zero', '22023', 'Pricing configuration is invalid.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', '{"unitPrice":1,"minUnits":1.5,"maxUnits":5}', '{"units":2}'),
    'minUnits fractional', '22023', 'Pricing configuration is invalid.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', '{"unitPrice":1,"minUnits":5,"maxUnits":4}', '{"units":5}'),
    'maxUnits below minUnits', '22023', 'Pricing configuration is invalid.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', '{"unitPrice":1,"minUnits":1,"maxUnits":10001}', '{"units":1}'),
    'maxUnits above ceiling', '22023', 'Pricing configuration is invalid.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', '{"unitPrice":1,"minUnits":1}', '{"units":1}'),
    'maxUnits missing', '22023', 'Pricing configuration is invalid.');
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', '[]', '{"units":1}'),
    'definition not an object', '22023', 'Pricing configuration is invalid.');
  -- The definition is validated before the unit count, so a bad definition
  -- and a bad count report the definition.
  perform pg_temp.expect_error(format('select commerce._qs_price_per_unit(%L::jsonb, %L::jsonb)', '{"unitPrice":0,"minUnits":1,"maxUnits":5}', '{}'),
    'definition checked before units', '22023', 'Pricing configuration is invalid.');

  -- ── through the real price wrapper ─────────────────────────────────
  insert into public.tenants(id,slug,name,status,settings)
  values (v_tenant, 'cg01f-' || left(v_suffix,12), 'CAFE GUEST 01F synthetic', 'active', '{}'::jsonb);

  -- PER_UNIT product (synthetic; not a Scan or Lamination product).
  insert into commerce.products(tenant_id, slug, name, status, availability)
  values (v_tenant, 'cg01f-unit-product', 'CAFE GUEST 01F unit product', 'published', 'available')
  returning id into v_product;
  insert into commerce.service_product_configs(tenant_id, product_id, source_key, pricing_version, customer_definition, pricing_definition, status)
  values (v_tenant, v_product, 'cg01f-unit-product', 'cg01f-v1',
          '{"pricing":{"strategy":"PER_UNIT","unitPrice":19.99,"minUnits":1,"maxUnits":50}}',
          v_definition, 'published');

  v_result := commerce.qs_calculate_price(v_tenant, 'cg01f-unit-product', '{"units":3}');
  if (v_result ->> 'total')::numeric <> 59.97
     or v_result ->> 'productKey' is distinct from 'cg01f-unit-product'
     or v_result ->> 'productName' is distinct from 'CAFE GUEST 01F unit product'
     or v_result ->> 'summary' is distinct from '3 × 19.99' then
    raise exception 'wrapper envelope changed: %', v_result;
  end if;
  if v_result -> 'metrics' ? 'quantity' or v_result -> 'snapshot' -> 'calculation' -> 'metrics' ? 'quantity' then
    raise exception 'PER_UNIT metrics must never contain quantity: %', v_result;
  end if;
  if v_result -> 'snapshot' ->> 'pricingStrategy' is distinct from 'PER_UNIT'
     or v_result -> 'snapshot' -> 'configuration' is distinct from '{"units":3}'::jsonb
     or (v_result -> 'snapshot' -> 'calculation' ->> 'total')::numeric <> 59.97 then
    raise exception 'wrapper snapshot changed: %', v_result -> 'snapshot';
  end if;
  perform pg_temp.expect_error(format('select commerce.qs_calculate_price(%L, %L, %L::jsonb)', v_tenant, 'cg01f-unit-product', '{"units":0}'),
    'wrapper rejects units below min', '22023', 'Units are outside the supported range.');
  perform pg_temp.expect_error(format('select commerce.qs_calculate_price(%L, %L, %L::jsonb)', v_tenant, 'cg01f-unit-product', '{"quantity":3}'),
    'a quantity key is not units', '22023', 'Units are required.');

  -- ── existing strategies are unchanged by the wrapper replacement ───
  -- PER_AREA fixture: 2 x 1.5 m at 100 per m2 -> 300.
  insert into commerce.products(tenant_id, slug, name, status, availability)
  values (v_tenant, 'cg01f-area-product', 'CAFE GUEST 01F area product', 'published', 'available')
  returning id into v_product;
  insert into commerce.service_product_configs(tenant_id, product_id, source_key, pricing_version, pricing_definition, status)
  values (v_tenant, v_product, 'cg01f-area-product', 'cg01f-v1',
          '{"strategy":"PER_AREA","baseRate":100,"minimumBillableArea":1,"materials":{"standard":{"multiplier":1}},"finishing":{"none":{"fee":0}},"artwork":{"ready":{"fee":0}},"turnaround":{"standard":{"multiplier":1}}}',
          'published');
  v_result := commerce.qs_calculate_price(v_tenant, 'cg01f-area-product',
    '{"width":2,"height":1.5,"material":"standard","finishing":"none","artwork":"ready","turnaround":"standard"}');
  if (v_result ->> 'total')::numeric <> 300 then raise exception 'PER_AREA changed: %', v_result; end if;

  -- PER_PAGE fixture on the a4-print key (its document normalization applies):
  -- 12 source pages x 3 copies at 2 per page, one side, no finish -> 72.
  insert into commerce.products(tenant_id, slug, name, status, availability)
  values (v_tenant, 'a4-print', 'CAFE GUEST 01F print product', 'published', 'available')
  returning id into v_product;
  insert into commerce.service_product_configs(tenant_id, product_id, source_key, pricing_version, pricing_definition, status)
  values (v_tenant, v_product, 'a4-print', 'cg01f-v1',
          '{"strategy":"PER_PAGE","rates":{"bw":{"rate":2}},"sides":{"single":{"multiplier":1}},"finishes":{"none":{"fee":0}}}',
          'published');
  v_result := commerce.qs_calculate_price(v_tenant, 'a4-print',
    '{"pages":12,"copies":3,"printMode":"bw","sides":"single","finish":"none","documentInstructions":[{"selection":"all","sourcePages":12}]}');
  if (v_result ->> 'total')::numeric <> 72 then raise exception 'PER_PAGE changed: %', v_result; end if;
  if (v_result -> 'metrics' ->> 'printedPages')::integer <> 36 then raise exception 'PER_PAGE printedPages changed: %', v_result; end if;

  -- ENQUIRY fixture: always a quote.
  insert into commerce.products(tenant_id, slug, name, status, availability)
  values (v_tenant, 'cg01f-enquiry-product', 'CAFE GUEST 01F enquiry product', 'published', 'available')
  returning id into v_product;
  insert into commerce.service_product_configs(tenant_id, product_id, source_key, pricing_version, pricing_definition, status)
  values (v_tenant, v_product, 'cg01f-enquiry-product', 'cg01f-v1', '{"strategy":"ENQUIRY","quoteRequired":true}', 'published');
  v_result := commerce.qs_calculate_price(v_tenant, 'cg01f-enquiry-product', '{}');
  if (v_result -> 'metrics' ->> 'quoteRequired')::boolean is distinct from true then raise exception 'ENQUIRY changed: %', v_result; end if;
end
$behavior$;

rollback;

select 'CAFE-GUEST-01F PER_UNIT pricing contracts passed' as result;
