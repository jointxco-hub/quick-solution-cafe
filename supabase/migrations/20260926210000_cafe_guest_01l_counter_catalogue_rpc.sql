-- CAFE-GUEST-01L: the server-safe counter catalogue RPC.
--
--   public.get_quick_solution_counter_catalog()  returns jsonb
--
-- The first counter RPC. It returns the products Cafe staff may start a counter sale or
-- request from, and nothing else. It is the "already server-safe catalogue" that the pure
-- front-end module (src/lib/counterCatalogue.js) assumes exists. It creates no order and
-- writes nothing (STABLE).
--
-- SECURITY, in this order (all server-side; nothing here depends on the front end):
--   1. authenticate: auth.uid() is required.               42501 'Staff sign-in is required.'
--   2. resolve the Cafe tenant by the canonical slug 'quick-solution', active only. The RPC
--      takes NO argument, so the caller can neither name a tenant nor switch tenant.
--                                                          22023 'Quick Solution tenant was not found.'
--   3. authorize: public.has_tenant_capability(tenant, 'cafe.counter.operate') - an active
--      owner, admin or member of THAT tenant. No app-admin or OPPS-staff bypass.
--                                                          42501 'You do not have access to the Quick Solution counter.'
--   4. require the tenant's `quick_solution` module (public.tenant_capabilities) to be enabled.
--                                                          22023 'Quick Solution counter is not active.'
-- Authorization runs BEFORE the module check, so the module's state is only ever revealed to
-- an authorized actor. Error codes and wording follow the existing admin RPCs
-- (admin_get_quick_solution_catalog, admin_list_quick_solution_opps_handoffs) and the public
-- catalogue ('... is not active.').
--
-- PRODUCT ELIGIBILITY (server-side, strict): a product is returned only if ALL hold
--   a. its config is 'published', and its commerce product is 'published' and 'available'
--      - the same lifecycle the public catalogue and commerce.qs_calculate_price require, so
--      anything returned here can also be priced. Draft, archived (retired), unavailable and
--      unpublished products are never returned, even with pos true;
--   b. customer_definition.channels.pos is the JSON boolean true - decided by the one shared
--      rule commerce._qs_product_channel_enabled(tenant, key, 'counter') (CAFE-GUEST-01C):
--      missing, null, false, and every non-boolean ("true", 1, {}, []) are excluded;
--   c. customer_definition.active is not explicitly off: missing/null counts as on (the
--      client default), a boolean must be true, anything else is excluded.
-- Nothing else decides it: not channels.storefront (so storefront-off products such as Scan
-- and A4/A3 Lamination ARE returned), not the pricing strategy, category or the front end.
-- Ordering matches the public catalogue: sort_order, then name.
--
-- RESPONSE: { tenant: { slug, name }, products: [ ... ] }. Each product is the established
-- customer-safe customer_definition (id, name, shortName, category, description, keywords,
-- channels, pricing mirror, fields, ...) plus id (the product key), name, description and
-- pricingVersion - the same shape as the public catalogue, so the front end needs no second
-- product DTO. It carries NO tenant id, commerce ids, authorization data, pricing_definition,
-- supplier cost, reference price, margin, VAT or source data: the function never reads
-- pricing_definition, and defensively strips pricingDefinition / commerceProductId keys.
-- The request-versus-order distinction stays in the front-end module (it reads only the
-- customer-safe strategy and serviceType).
--
-- DEPENDENCY: public.has_tenant_capability is owned by the OPPS repo (CAFE-ACCESS-01..03),
-- so this migration must apply after those (its version sorts after them).

do $preflight$
begin
  if to_regprocedure('public.has_tenant_capability(uuid,text)') is null
     or to_regprocedure('commerce._qs_product_channel_enabled(uuid,text,text)') is null then
    raise exception
      'CAFE_GUEST_01L_MIGRATION_PRECONDITION: public.has_tenant_capability (CAFE-ACCESS) and commerce._qs_product_channel_enabled (CAFE-GUEST-01C) must exist';
  end if;
end
$preflight$;

create or replace function public.get_quick_solution_counter_catalog()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_tenant jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Staff sign-in is required.';
  end if;

  select t.id, jsonb_build_object('slug', t.slug, 'name', t.name)
  into v_tenant_id, v_tenant
  from public.tenants t
  where t.slug = 'quick-solution'
    and t.status = 'active'
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode = '22023', message = 'Quick Solution tenant was not found.';
  end if;

  if not public.has_tenant_capability(v_tenant_id, 'cafe.counter.operate') then
    raise exception using errcode = '42501', message = 'You do not have access to the Quick Solution counter.';
  end if;

  if not exists (
    select 1
    from public.tenant_capabilities tc
    where tc.tenant_id = v_tenant_id
      and tc.capability_key = 'quick_solution'
      and tc.enabled = true
  ) then
    raise exception using errcode = '22023', message = 'Quick Solution counter is not active.';
  end if;

  return jsonb_build_object(
    'tenant', v_tenant,
    'products', coalesce((
      select jsonb_agg(
        (c.customer_definition - 'pricingDefinition' - 'pricing_definition' - 'commerceProductId') ||
        jsonb_build_object(
          'id', c.source_key,
          'name', p.name,
          'description', coalesce(p.description, c.customer_definition ->> 'description'),
          'pricingVersion', c.pricing_version
        )
        order by c.sort_order, p.name
      )
      from commerce.service_product_configs c
      join commerce.products p
        on p.id = c.product_id
       and p.tenant_id = c.tenant_id
      where c.tenant_id = v_tenant_id
        and c.status = 'published'
        and p.status = 'published'
        and p.availability = 'available'
        and commerce._qs_product_channel_enabled(c.tenant_id, c.source_key, 'counter')
        and case coalesce(jsonb_typeof(c.customer_definition -> 'active'), 'null')
              when 'null' then true
              when 'boolean' then (c.customer_definition ->> 'active')::boolean
              else false
            end
    ), '[]'::jsonb)
  );
end
$$;

-- Staff RPC, called by the browser as the signed-in user: authenticated only.
revoke all on function public.get_quick_solution_counter_catalog()
  from public, anon, authenticated, service_role;
grant execute on function public.get_quick_solution_counter_catalog()
  to authenticated;

comment on function public.get_quick_solution_counter_catalog() is
  'CAFE-GUEST-01L: counter-safe catalogue for Quick Solution Cafe staff. No arguments: the Cafe tenant is resolved server-side. Requires cafe.counter.operate and the quick_solution module. Returns only published, available, active-not-off products whose channels.pos is the boolean true, as the customer-safe customer_definition. Never exposes pricing_definition or any private field. Read-only.';
