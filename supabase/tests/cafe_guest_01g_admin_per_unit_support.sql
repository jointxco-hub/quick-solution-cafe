-- CAFE-GUEST-01G: contract test for PER_UNIT support in
-- public.admin_update_quick_solution_product.
--
-- Run only against the disposable local harness (supabase/tests/harness/), which
-- replays the migration history - including
--   20260926130000_cafe_guest_01f_per_unit_pricing.sql
--   20260926140000_cafe_guest_01g_admin_per_unit_support.sql
-- - onto the OPPS-owned base layer. The static counterpart is
-- tests/per-unit-admin.test.mjs.
--
-- All fixtures are synthetic and enclosed by BEGIN/ROLLBACK. The staff gate is
-- exercised exactly as it exists today, through the real OPPS helper bodies:
--   * anonymous                      -> 'Staff sign-in is required.'
--   * signed in, not staff           -> denied
--   * OPPS staff, no tenant access   -> denied
--   * OPPS staff with tenant access  -> admitted
--   * app admin (the owner-email arm of is_app_admin(), a claim used only to
--     pass the unchanged gate)       -> admitted

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
      raise exception 'CAFE_GUEST_01G: % expected % containing "%" but got % "%"',
        p_case, p_sqlstate, p_token, v_state, v_message;
    end if;
    return;
  end;
  raise exception 'CAFE_GUEST_01G: % unexpectedly succeeded', p_case;
end
$helper$;

do $behavior$
declare
  v_suffix text := replace(gen_random_uuid()::text,'-','');
  v_tenant uuid := gen_random_uuid();
  v_slug text;
  v_product uuid;
  v_area_product uuid;
  v_result jsonb;
  v_config commerce.service_product_configs;
  v_admin uuid := gen_random_uuid();
  v_staff uuid := gen_random_uuid();
  v_joint_x uuid;
  v_staff_product uuid;
  v_unit_customer constant jsonb := '{"name":"CAFE GUEST 01G unit product","active":true,"pricing":{"strategy":"PER_UNIT","unitPrice":1,"minUnits":1,"maxUnits":5},"fields":[]}';
begin
  v_slug := 'cg01g-' || left(v_suffix,12);

  insert into public.tenants(id,slug,name,status,settings)
  values (v_tenant, v_slug, 'CAFE GUEST 01G synthetic', 'active', '{}'::jsonb);

  -- A synthetic PER_UNIT product (not Scan or Lamination) and a PER_AREA one.
  insert into commerce.products(tenant_id, slug, name, status, availability)
  values (v_tenant, 'cg01g-unit-product', 'CAFE GUEST 01G unit product', 'published', 'available')
  returning id into v_product;
  insert into commerce.service_product_configs(tenant_id, product_id, source_key, pricing_version, customer_definition, pricing_definition, status)
  values (v_tenant, v_product, 'cg01g-unit-product', 'cg01g-v1', v_unit_customer,
          '{"strategy":"PER_UNIT","unitPrice":1,"minUnits":1,"maxUnits":5}', 'published');

  insert into commerce.products(tenant_id, slug, name, status, availability)
  values (v_tenant, 'cg01g-area-product', 'CAFE GUEST 01G area product', 'published', 'available')
  returning id into v_area_product;
  insert into commerce.service_product_configs(tenant_id, product_id, source_key, pricing_version, customer_definition, pricing_definition, status)
  values (v_tenant, v_area_product, 'cg01g-area-product', 'cg01g-v1',
          '{"name":"CAFE GUEST 01G area product","active":true,"pricing":{"strategy":"PER_AREA","baseRate":100}}',
          '{"strategy":"PER_AREA","baseRate":100,"minimumBillableArea":1}', 'published');

  -- ── the staff gate is unchanged ────────────────────────────────────
  perform set_config('request.jwt.claims', '{}', true);
  perform pg_temp.expect_error(
    format('select public.admin_update_quick_solution_product(%L,%L,%L::jsonb,%L::jsonb,%L)',
      v_slug, 'cg01g-unit-product', v_unit_customer, '{"strategy":"PER_UNIT","unitPrice":2,"minUnits":1,"maxUnits":5}', 'cg01g-v1'),
    'anonymous caller', '42501', 'Staff sign-in is required.');

  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', gen_random_uuid(), 'role', 'authenticated', 'email', 'cg01g-nobody-' || v_suffix || '@disposable.test')::text, true);
  perform pg_temp.expect_error(
    format('select public.admin_update_quick_solution_product(%L,%L,%L::jsonb,%L::jsonb,%L)',
      v_slug, 'cg01g-unit-product', v_unit_customer, '{"strategy":"PER_UNIT","unitPrice":2,"minUnits":1,"maxUnits":5}', 'cg01g-v1'),
    'signed-in caller without staff authority', '42501', 'You do not have access to Quick Solution Product Admin.');

  -- ── the OPPS-staff arm of the gate: staff of the joint-x tenant, admitted only
  --    for a tenant they can access. Runs the real is_opps_staff() and
  --    can_access_tenant() bodies against synthetic membership rows.
  select t.id into v_joint_x from public.tenants t where t.slug = 'joint-x' and t.status = 'active';
  if v_joint_x is null then raise exception 'the joint-x staff tenant must exist for the OPPS-staff gate arm'; end if;
  insert into auth.users(id, email) values (v_staff, 'cg01g-staff-' || v_suffix || '@disposable.test');
  insert into public.users(auth_user_id, role, is_active) values (v_staff, 'staff', true);
  -- The real OPPS trigger already gave this active internal user a joint-x membership; the
  -- explicit insert only keeps the fixture independent of that trigger.
  insert into public.tenant_memberships(tenant_id, auth_user_id) values (v_joint_x, v_staff)
  on conflict (tenant_id, auth_user_id) do nothing;

  insert into commerce.products(tenant_id, slug, name, status, availability)
  values (v_tenant, 'cg01g-staff-product', 'CAFE GUEST 01G staff product', 'published', 'available')
  returning id into v_staff_product;
  insert into commerce.service_product_configs(tenant_id, product_id, source_key, pricing_version, customer_definition, pricing_definition, status)
  values (v_tenant, v_staff_product, 'cg01g-staff-product', 'cg01g-v1', v_unit_customer,
          '{"strategy":"PER_UNIT","unitPrice":1,"minUnits":1,"maxUnits":5}', 'published');

  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', v_staff, 'role', 'authenticated', 'email', 'cg01g-staff-' || v_suffix || '@disposable.test')::text, true);
  if not public.is_opps_staff() or public.is_app_admin() then
    raise exception 'fixture: the staff caller must be OPPS staff and not an app admin';
  end if;
  perform pg_temp.expect_error(
    format('select public.admin_update_quick_solution_product(%L,%L,%L::jsonb,%L::jsonb,%L)',
      v_slug, 'cg01g-staff-product', v_unit_customer, '{"strategy":"PER_UNIT","unitPrice":2,"minUnits":1,"maxUnits":5}', 'cg01g-v1'),
    'OPPS staff without access to the tenant', '42501', 'You do not have access to Quick Solution Product Admin.');

  insert into public.tenant_memberships(tenant_id, auth_user_id) values (v_tenant, v_staff);
  v_result := public.admin_update_quick_solution_product(
    v_slug, 'cg01g-staff-product', v_unit_customer, '{"strategy":"PER_UNIT","unitPrice":2,"minUnits":1,"maxUnits":5}', 'cg01g-v1');
  if v_result ->> 'ok' is distinct from 'true' then raise exception 'OPPS staff with tenant access must be admitted: %', v_result; end if;

  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'jointx.co@gmail.com')::text, true);

  -- ── PER_UNIT is now accepted and normalized ────────────────────────
  v_result := public.admin_update_quick_solution_product(
    v_slug, 'cg01g-unit-product', v_unit_customer,
    '{"strategy":"per_unit","unitPrice":19.99,"minUnits":1,"maxUnits":50,"setupFee":5,"supplierCost":3,"marginRate":0.5}',
    'cg01g-v1');
  if v_result ->> 'ok' is distinct from 'true' then raise exception 'PER_UNIT save failed: %', v_result; end if;

  select * into v_config from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'cg01g-unit-product';
  if v_config.pricing_definition is distinct from '{"strategy":"PER_UNIT","unitPrice":19.99,"minUnits":1,"maxUnits":50}'::jsonb then
    raise exception 'stored definition must be exactly the four contract fields, got %', v_config.pricing_definition;
  end if;
  if v_config.customer_definition -> 'pricing' is distinct from '{"strategy":"PER_UNIT","unitPrice":19.99,"minUnits":1,"maxUnits":50}'::jsonb then
    raise exception 'customer mirror must equal the definition and carry no private field, got %', v_config.customer_definition -> 'pricing';
  end if;
  if v_config.customer_definition::text ~* '(setupfee|suppliercost|marginrate)' or v_config.pricing_definition::text ~* '(setupfee|suppliercost|marginrate)' then
    raise exception 'extra keys must not be stored anywhere';
  end if;
  if v_config.pricing_version = 'cg01g-v1' or v_config.pricing_version not like 'qsc-%' then
    raise exception 'a new pricing version must be issued, got %', v_config.pricing_version;
  end if;
  if v_config.status <> 'published' then raise exception 'active product must stay published'; end if;

  -- ── invalid definitions are rejected and change nothing ────────────
  for v_result in
    select to_jsonb(d) from (values
      ('{"strategy":"PER_UNIT","unitPrice":0,"minUnits":1,"maxUnits":5}'::jsonb),
      ('{"strategy":"PER_UNIT","unitPrice":-1,"minUnits":1,"maxUnits":5}'),
      ('{"strategy":"PER_UNIT","unitPrice":100000.01,"minUnits":1,"maxUnits":5}'),
      ('{"strategy":"PER_UNIT","unitPrice":19.995,"minUnits":1,"maxUnits":5}'),
      ('{"strategy":"PER_UNIT","unitPrice":"19.99","minUnits":1,"maxUnits":5}'),
      ('{"strategy":"PER_UNIT","minUnits":1,"maxUnits":5}'),
      ('{"strategy":"PER_UNIT","unitPrice":1,"minUnits":0,"maxUnits":5}'),
      ('{"strategy":"PER_UNIT","unitPrice":1,"minUnits":1.5,"maxUnits":5}'),
      ('{"strategy":"PER_UNIT","unitPrice":1,"minUnits":5,"maxUnits":4}'),
      ('{"strategy":"PER_UNIT","unitPrice":1,"minUnits":1,"maxUnits":10001}'),
      ('{"strategy":"PER_UNIT","unitPrice":1,"minUnits":1}')
    ) as d(definition)
  loop
    perform pg_temp.expect_error(
      format('select public.admin_update_quick_solution_product(%L,%L,%L::jsonb,%L::jsonb,%L)',
        v_slug, 'cg01g-unit-product', v_unit_customer, v_result -> 'definition',
        (select c.pricing_version from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'cg01g-unit-product')),
      'invalid PER_UNIT definition ' || (v_result -> 'definition')::text, '22023', 'Pricing configuration is invalid.');
  end loop;
  if (select c.pricing_definition from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'cg01g-unit-product')
     is distinct from '{"strategy":"PER_UNIT","unitPrice":19.99,"minUnits":1,"maxUnits":50}'::jsonb then
    raise exception 'a rejected save must not change the stored definition';
  end if;

  -- ── the allow-list still rejects unknown strategies ────────────────
  perform pg_temp.expect_error(
    format('select public.admin_update_quick_solution_product(%L,%L,%L::jsonb,%L::jsonb,%L)',
      v_slug, 'cg01g-unit-product', v_unit_customer, '{"strategy":"PER_NOTHING"}',
      (select c.pricing_version from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'cg01g-unit-product')),
    'unknown strategy', '22023', 'Pricing strategy is not supported.');

  -- ── existing strategies store their definition exactly as before ───
  v_result := public.admin_update_quick_solution_product(
    v_slug, 'cg01g-area-product',
    '{"name":"CAFE GUEST 01G area product","active":true,"pricing":{"strategy":"PER_AREA","baseRate":100}}',
    '{"strategy":"PER_AREA","baseRate":100,"minimumBillableArea":1,"extraKeyKeptAsBefore":true}',
    'cg01g-v1');
  select * into v_config from commerce.service_product_configs c where c.tenant_id = v_tenant and c.source_key = 'cg01g-area-product';
  if v_config.pricing_definition is distinct from '{"strategy":"PER_AREA","baseRate":100,"minimumBillableArea":1,"extraKeyKeptAsBefore":true}'::jsonb then
    raise exception 'PER_AREA must store p_pricing_definition verbatim, got %', v_config.pricing_definition;
  end if;
  if v_config.customer_definition -> 'pricing' is distinct from '{"strategy":"PER_AREA","baseRate":100}'::jsonb then
    raise exception 'PER_AREA mirror must be the client value, unchanged';
  end if;

  -- ── the saved PER_UNIT product prices through the real wrapper ─────
  v_result := commerce.qs_calculate_price(v_tenant, 'cg01g-unit-product', '{"units":3}');
  if (v_result ->> 'total')::numeric <> 59.97 then raise exception 'a saved PER_UNIT definition must price, got %', v_result; end if;
end
$behavior$;

rollback;

select 'CAFE-GUEST-01G admin PER_UNIT support contracts passed' as result;
