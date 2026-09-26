-- CAFE-GUEST-01D: contract test for the storefront filter in the PUBLIC catalogue.
--
-- Run only against an isolated database that has the real Quick Solution
-- effective schema (commerce.products, commerce.service_product_configs,
-- commerce.fulfilment_points, public.tenants, public.tenant_capabilities)
-- after applying:
--   20260926120000_cafe_guest_01d_public_catalogue_storefront_filter.sql
-- Executed by the disposable local harness (supabase/tests/harness/run-local-sql-tests.ps1),
-- which replays the migration history onto the OPPS-owned base layer. The static
-- counterpart is tests/cafe-guest-01d-public-catalogue.test.mjs.
--
-- All fixtures are synthetic and enclosed by BEGIN/ROLLBACK.

\set ON_ERROR_STOP on

begin;

do $catalog$
declare
  v_rpc regprocedure := to_regprocedure('public.get_quick_solution_catalog(text)');
begin
  if v_rpc is null then
    raise exception 'public.get_quick_solution_catalog(text) must exist';
  end if;
  if not (select p.prosecdef from pg_catalog.pg_proc p where p.oid = v_rpc) then
    raise exception 'the public catalogue must remain SECURITY DEFINER';
  end if;
  if (select pg_catalog.pg_get_function_result(v_rpc)) <> 'jsonb' then
    raise exception 'the public catalogue must keep its jsonb return contract';
  end if;
  if (select p.pronargdefaults from pg_catalog.pg_proc p where p.oid = v_rpc) <> 1 then
    raise exception 'the public catalogue must keep its default tenant-slug argument';
  end if;
  if not exists (
    select 1
    from pg_catalog.pg_proc p,
         lateral pg_catalog.pg_options_to_table(p.proconfig) config
    where p.oid = v_rpc
      and config.option_name = 'search_path'
      and btrim(config.option_value, chr(34)) = ''
  ) then
    raise exception 'the public catalogue must keep an empty hardened search_path';
  end if;
  -- The catalogue is public by design: anon and authenticated stay allowed.
  if not has_function_privilege('anon', v_rpc, 'EXECUTE')
     or not has_function_privilege('authenticated', v_rpc, 'EXECUTE') then
    raise exception 'anon and authenticated must keep EXECUTE on the public catalogue';
  end if;
  if exists (
    select 1
    from pg_catalog.pg_proc p,
         lateral pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) acl
    where p.oid = v_rpc and acl.grantee = 0 and acl.privilege_type = 'EXECUTE'
  ) then
    raise exception 'PUBLIC must not hold EXECUTE (anon/authenticated are granted explicitly)';
  end if;
  if lower(pg_catalog.pg_get_functiondef(v_rpc)) ~ '(pricing_definition|supplier|referenceprice|marginrate)' then
    raise exception 'the public catalogue must never reference pricing_definition or supplier data';
  end if;
end
$catalog$;

do $behavior$
declare
  v_suffix text := replace(gen_random_uuid()::text,'-','');
  v_tenant uuid := gen_random_uuid();
  v_other_tenant uuid := gen_random_uuid();
  v_slug text;
  v_result jsonb;
  v_ids text[];
  v_row jsonb;
begin
  v_slug := 'cg01d-a-' || left(v_suffix,12);

  insert into public.tenants(id,slug,name,status,settings)
  values
    (v_tenant, v_slug, 'CAFE GUEST 01D tenant A', 'active', '{}'::jsonb),
    (v_other_tenant, 'cg01d-b-' || right(v_suffix,12), 'CAFE GUEST 01D tenant B', 'active', '{}'::jsonb);

  insert into public.tenant_capabilities(tenant_id, capability_key, enabled)
  values (v_tenant, 'quick_solution', true), (v_other_tenant, 'quick_solution', true);

  create temporary table cg01d_products(
    slug text primary key,
    customer_definition jsonb not null,
    sort_order integer not null,
    product_status text not null default 'published',
    availability text not null default 'available',
    config_status text not null default 'published',
    expect_listed boolean not null
  ) on commit drop;

  insert into cg01d_products(slug, customer_definition, sort_order, expect_listed) values
    ('sf-true',         '{"channels":{"storefront":true,"pos":false}}',   10, true),
    ('sf-missing',      '{"channels":{"pos":false}}',                     20, true),
    ('no-channels',     '{"note":"legacy row"}',                          30, true),
    ('sf-null',         '{"channels":{"storefront":null,"pos":true}}',    40, true),
    ('pos-false',       '{"channels":{"storefront":true,"pos":false}}',   50, true),
    ('pos-missing',     '{"channels":{"storefront":true}}',               60, true),
    ('sf-false',        '{"channels":{"storefront":false,"pos":true}}',   70, false),
    ('pos-only',        '{"channels":{"storefront":false,"pos":true}}',   80, false),
    ('sf-string-false', '{"channels":{"storefront":"false"}}',            90, false),
    ('sf-string-true',  '{"channels":{"storefront":"true"}}',            100, false),
    ('sf-number',       '{"channels":{"storefront":0}}',                 110, false),
    ('sf-object',       '{"channels":{"storefront":{}}}',                120, false),
    ('sf-array',        '{"channels":{"storefront":[]}}',                130, false);

  -- The other published/available filters must be untouched.
  insert into cg01d_products(slug, customer_definition, sort_order, product_status, expect_listed)
  values ('draft-product', '{"channels":{"storefront":true}}', 140, 'draft', false);
  insert into cg01d_products(slug, customer_definition, sort_order, availability, expect_listed)
  values ('unavailable-product', '{"channels":{"storefront":true}}', 150, 'unavailable', false);
  insert into cg01d_products(slug, customer_definition, sort_order, config_status, expect_listed)
  values ('draft-config', '{"channels":{"storefront":true}}', 160, 'draft', false);

  insert into commerce.products(tenant_id, slug, name, status, availability)
  select v_tenant, p.slug, 'CAFE GUEST 01D ' || p.slug, p.product_status, p.availability
  from cg01d_products p;

  insert into commerce.service_product_configs(
    tenant_id, product_id, source_key, pricing_version, customer_definition,
    pricing_definition, status, sort_order
  )
  select v_tenant, pr.id, p.slug, 'cg01d-v1', p.customer_definition,
         '{"strategy":"PER_PAGE","internalMarker":"cg01d-secret-marker"}'::jsonb,
         p.config_status, p.sort_order
  from cg01d_products p
  join commerce.products pr on pr.tenant_id = v_tenant and pr.slug = p.slug;

  -- A storefront-enabled product that belongs to another tenant.
  insert into commerce.products(tenant_id, slug, name, status)
  values (v_other_tenant, 'other-tenant-product', 'CAFE GUEST 01D other tenant', 'published');
  insert into commerce.service_product_configs(tenant_id, product_id, source_key, pricing_version, customer_definition, status)
  select v_other_tenant, pr.id, 'other-tenant-product', 'cg01d-v1', '{"channels":{"storefront":true}}'::jsonb, 'published'
  from commerce.products pr where pr.tenant_id = v_other_tenant and pr.slug = 'other-tenant-product';

  v_result := public.get_quick_solution_catalog(v_slug);

  select coalesce(array_agg(p ->> 'id' order by (p ->> 'id')), array[]::text[])
    into v_ids
  from jsonb_array_elements(v_result -> 'products') p;

  if v_ids is distinct from (
    select coalesce(array_agg(p.slug order by p.slug), array[]::text[])
    from cg01d_products p
    where p.expect_listed
  ) then
    raise exception 'catalogue must list exactly the storefront-enabled published products, got %', v_ids;
  end if;

  if v_ids && array['sf-false','pos-only','sf-string-false','sf-string-true','sf-number','sf-object','sf-array','other-tenant-product'] then
    raise exception 'catalogue leaked a product that is not sold through the storefront: %', v_ids;
  end if;

  -- pos does not participate: storefront=true/pos=false is listed; storefront=false/pos=true is not.
  if not (v_ids @> array['pos-false','pos-missing']) or (v_ids && array['pos-only']) then
    raise exception 'channels.pos must not affect the public catalogue: %', v_ids;
  end if;

  -- Ordering is unchanged: sort_order, then name.
  if (select array_agg(p ->> 'id' order by ord) from jsonb_array_elements(v_result -> 'products') with ordinality as t(p, ord))
     is distinct from array['sf-true','sf-missing','no-channels','sf-null','pos-false','pos-missing'] then
    raise exception 'catalogue ordering changed: %', v_result -> 'products';
  end if;

  -- Response shape is unchanged and never carries pricing_definition.
  for v_row in select p from jsonb_array_elements(v_result -> 'products') p loop
    if not (v_row ?& array['id','commerceProductId','name','description','pricingVersion']) then
      raise exception 'product projection lost a field: %', v_row;
    end if;
    if v_row ? 'pricingDefinition' or v_row ? 'pricing_definition' then
      raise exception 'public product must not carry pricing_definition';
    end if;
  end loop;
  if v_result::text like '%cg01d-secret-marker%' then
    raise exception 'pricing_definition content leaked into the public catalogue';
  end if;
  if not (v_result ?& array['tenant','products','fulfilmentPoints']) then
    raise exception 'catalogue top-level shape changed';
  end if;
  if v_result -> 'tenant' ->> 'slug' is distinct from v_slug then
    raise exception 'tenant resolution changed';
  end if;

  -- The 01C item guard remains the direct-order boundary: a storefront=false
  -- product is not only unlisted, it cannot be added to a storefront order.
  -- (Exercised by cafe_guest_01c_channel_availability_guard.sql.)
end
$behavior$;

rollback;

select 'CAFE-GUEST-01D public catalogue storefront filter contracts passed' as result;
