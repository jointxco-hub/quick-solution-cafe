-- CAFE-GUEST-01G: admin support for the neutral PER_UNIT pricing strategy.
--
-- public.admin_update_quick_solution_product previously rejected PER_UNIT
-- ('Pricing strategy is not supported.'), so a PER_UNIT product could exist
-- but could not be saved through /admin. This replaces that one function
-- (latest previous definition:
-- 20260921120000_qs14_checkout_guards_and_supplier_rules.sql) with exactly four
-- deliberate differences, and nothing else:
--   1. 'PER_UNIT' joins the strategy allow-list;
--   2. a v_pricing_definition variable (equal to p_pricing_definition for every
--      other strategy);
--   3. for PER_UNIT only: the definition is validated by
--      commerce._qs_validate_per_unit_definition (the single rule shared with
--      price time, from 20260926130000_cafe_guest_01f_per_unit_pricing.sql),
--      normalized to exactly { strategy, unitPrice, minUnits, maxUnits }, and
--      customer_definition.pricing is set to that same object;
--   4. the update stores v_pricing_definition.
-- The staff gate (is_app_admin / is_opps_staff / can_access_tenant), tenant
-- resolution, version check, product-name and active handling, the supplier
-- mirror regeneration, the update statements and the return value are
-- byte-for-byte the previous definition; CAFE-ACCESS-01 will replace that gate
-- later and this migration deliberately does not touch it. EXECUTE grants are
-- not touched either (CREATE OR REPLACE preserves them). The static tests
-- prove the four-difference claim by re-applying only those edits to the
-- previous text and requiring an exact match.
--
-- PER_UNIT public/customer mirror: customer_definition.pricing is
-- { strategy, unitPrice, minUnits, maxUnits } - the selling price and unit
-- limits only, the same convention as PER_AREA's baseRate. PER_UNIT has no
-- private fields, so definition and mirror are the same four keys; nothing
-- else from p_pricing_definition is stored or exposed.
--
-- Not changed: no product is created or altered, and no Scan or Lamination
-- product exists. The unit count key stays `units` at order time; nothing here
-- reads or writes configuration.quantity.

do $preflight$
begin
  if to_regprocedure('public.admin_update_quick_solution_product(text,text,jsonb,jsonb,text)') is null
     or to_regprocedure('commerce._qs_validate_per_unit_definition(jsonb)') is null then
    raise exception
      'CAFE_GUEST_01G_MIGRATION_PRECONDITION: admin_update_quick_solution_product and commerce._qs_validate_per_unit_definition (CAFE-GUEST-01F) must exist';
  end if;
end
$preflight$;

create or replace function public.admin_update_quick_solution_product(
  p_tenant_slug text,
  p_product_key text,
  p_customer_definition jsonb,
  p_pricing_definition jsonb,
  p_expected_pricing_version text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_config commerce.service_product_configs;
  v_product_name text;
  v_description text;
  v_active boolean;
  v_strategy text;
  v_new_version text;
  v_customer_definition jsonb;
  v_customer_mirror jsonb;
  v_pricing_definition jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Staff sign-in is required.';
  end if;

  select t.id into v_tenant_id
  from public.tenants t
  where t.slug=lower(trim(p_tenant_slug)) and t.status='active'
  limit 1;
  if v_tenant_id is null then
    raise exception using errcode = '22023', message = 'Quick Solution tenant was not found.';
  end if;

  if not public.is_app_admin()
     and not (public.is_opps_staff() and public.can_access_tenant(v_tenant_id)) then
    raise exception using errcode = '42501', message = 'You do not have access to Quick Solution Product Admin.';
  end if;

  if jsonb_typeof(p_customer_definition) is distinct from 'object'
     or jsonb_typeof(p_pricing_definition) is distinct from 'object' then
    raise exception using errcode = '22023', message = 'Product definitions must be JSON objects.';
  end if;

  select * into v_config
  from commerce.service_product_configs c
  where c.tenant_id=v_tenant_id and c.source_key=trim(p_product_key)
  limit 1;
  if v_config.id is null then
    raise exception using errcode = '22023', message = 'Product was not found.';
  end if;

  if p_expected_pricing_version is null or v_config.pricing_version <> p_expected_pricing_version then
    raise exception using errcode = '40001', message = 'This product changed after you opened it. Reload before saving.';
  end if;

  v_strategy := upper(coalesce(p_pricing_definition->>'strategy',''));
  if v_strategy not in ('PER_AREA','PER_PAGE','TIERED','CONFIGURABLE','SUPPLIER_MARGIN','PHOTOGRAPHY_SESSION','PER_UNIT') then
    raise exception using errcode = '22023', message = 'Pricing strategy is not supported.';
  end if;

  v_product_name := left(trim(coalesce(p_customer_definition->>'name','')), 160);
  v_description := nullif(trim(coalesce(p_customer_definition->>'description', p_customer_definition->>'plainDescription','')), '');
  v_active := coalesce((p_customer_definition->>'active')::boolean, true);
  if length(v_product_name) < 2 then
    raise exception using errcode = '22023', message = 'Product name is required.';
  end if;

  -- SUPPLIER_MARGIN/PHOTOGRAPHY_SESSION: never trust the client's
  -- customer_definition.pricing mirror - regenerate it from the
  -- pricing_definition just validated above, so a stale/spoofed/
  -- out-of-sync selling-price mirror can never be saved. Every other
  -- strategy is unchanged (their customer_definition.pricing already
  -- IS the authoritative numbers, same as pricing_definition, by
  -- design - nothing to regenerate).
  v_customer_definition := p_customer_definition;
  if v_strategy in ('SUPPLIER_MARGIN','PHOTOGRAPHY_SESSION') then
    v_customer_mirror := commerce._qs_derive_customer_pricing_mirror(p_pricing_definition);
    if v_customer_mirror is not null then
      v_customer_definition := jsonb_set(v_customer_definition, '{pricing}', v_customer_mirror, true);
    end if;
  end if;

  -- CAFE-GUEST-01G: PER_UNIT. The definition is validated by the one shared
  -- rule (commerce._qs_validate_per_unit_definition), then normalized to
  -- exactly the four contract fields, and the customer mirror is set to that
  -- same object - so the stored definition and the public mirror can never
  -- drift or carry extra keys. Every other strategy stores
  -- p_pricing_definition exactly as before.
  v_pricing_definition := p_pricing_definition;
  if v_strategy = 'PER_UNIT' then
    perform commerce._qs_validate_per_unit_definition(p_pricing_definition);
    v_pricing_definition := jsonb_build_object(
      'strategy', 'PER_UNIT',
      'unitPrice', p_pricing_definition -> 'unitPrice',
      'minUnits', p_pricing_definition -> 'minUnits',
      'maxUnits', p_pricing_definition -> 'maxUnits'
    );
    v_customer_definition := jsonb_set(v_customer_definition, '{pricing}', v_pricing_definition, true);
  end if;

  v_new_version := 'qsc-' || to_char(clock_timestamp() at time zone 'Africa/Johannesburg','YYYYMMDD-HH24MISS') || '-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,4));

  update commerce.service_product_configs c
  set customer_definition=v_customer_definition,
      pricing_definition=v_pricing_definition,
      pricing_version=v_new_version,
      status=case when v_active then 'published' else 'draft' end,
      updated_at=now()
  where c.id=v_config.id;

  update commerce.products p
  set name=v_product_name,
      description=v_description,
      status=case when v_active then 'published' else 'draft' end,
      availability=case when v_active then 'available' else 'unavailable' end,
      updated_at=now()
  where p.id=v_config.product_id and p.tenant_id=v_tenant_id;

  return jsonb_build_object('ok', true, 'productKey', trim(p_product_key), 'pricingVersion', v_new_version);
end
$$;
