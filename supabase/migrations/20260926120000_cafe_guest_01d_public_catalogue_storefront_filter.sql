-- CAFE-GUEST-01D: the PUBLIC Quick Solution catalogue enforces
-- channels.storefront on the server.
--
-- Until now public.get_quick_solution_catalog returned every published,
-- available product; only the React app hid storefront=false products. This
-- replaces that one function (latest previous definition:
-- 20260913190841_qs_07_customer_fulfilment_choices.sql) so the server itself
-- excludes products that are not sold through the storefront.
--
-- FILTERING ONLY. Everything else is unchanged: signature, default argument,
-- SECURITY DEFINER, empty search_path, tenant resolution, the published /
-- available filters, the products projection (customer_definition plus id,
-- commerceProductId, name, description and pricingVersion; pricing_definition
-- is still never returned), the ordering, the fulfilmentPoints block, the
-- error message, and the EXECUTE grants (anon and authenticated stay
-- allowed). Only one predicate is added to the products query:
--
--   customer_definition.channels.storefront
--     true                         -> included
--     missing, or JSON null        -> included (legacy-compatible)
--     false                        -> excluded
--     any other type (string, ...) -> excluded (fail closed)
--
-- This is the same storefront contract as commerce._qs_product_channel_enabled
-- (CAFE-GUEST-01C). The predicate is written inline, with exactly the same
-- CASE expression, rather than calling that helper: the rows are already the
-- service_product_configs rows, so the helper would only re-read the same row
-- by key for every product, and it is an internal function that must stay
-- non-executable by API roles. The static tests require the two expressions
-- to be textually identical, so there is one contract, not two.
--
-- channels.pos does NOT participate here. It is not yet curated (every current
-- product is pos=true by blanket default) and no counter catalogue exists.
--
-- Defence in depth with CAFE-GUEST-01C:
--   public catalogue filter (this migration): a storefront=false product is
--     not publicly listed;
--   item channel guard (01C): it cannot be inserted into a storefront order
--     anyway. Direct-order enforcement is NOT moved into this RPC.
-- Together they close the first known gap recorded in
-- 20260926110000_cafe_guest_01c_channel_availability_guard.sql. Deploy this
-- together with (or before) publishing any storefront=false product.
--
-- Not changed and reported separately: the products projection is
-- "customer_definition || ..." (whatever is saved in customer_definition is
-- public); an allow-list projection would be a separate change.

do $preflight$
begin
  if to_regprocedure('public.get_quick_solution_catalog(text)') is null then
    raise exception
      'CAFE_GUEST_01D_MIGRATION_PRECONDITION: public.get_quick_solution_catalog(text) does not exist';
  end if;
end
$preflight$;

create or replace function public.get_quick_solution_catalog(
  p_tenant_slug text default 'quick-solution'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
begin
  select t.id
  into v_tenant_id
  from public.tenants t
  where t.slug = lower(trim(p_tenant_slug))
    and t.status = 'active'
    and exists (
      select 1
      from public.tenant_capabilities tc
      where tc.tenant_id = t.id
        and tc.capability_key = 'quick_solution'
        and tc.enabled = true
    )
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode = '22023', message = 'Quick Solution storefront is not active.';
  end if;

  return jsonb_build_object(
    'tenant', (
      select jsonb_build_object('id',t.id,'slug',t.slug,'name',t.name)
      from public.tenants t
      where t.id = v_tenant_id
    ),
    'products', coalesce((
      select jsonb_agg(
        c.customer_definition ||
        jsonb_build_object(
          'id', c.source_key,
          'commerceProductId', p.id,
          'name', p.name,
          'description', coalesce(p.description, c.customer_definition->>'description'),
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
        and case coalesce(jsonb_typeof(c.customer_definition -> 'channels' -> 'storefront'), 'null')
              when 'null' then true
              when 'boolean' then (c.customer_definition -> 'channels' ->> 'storefront')::boolean
              else false
            end
    ), '[]'::jsonb),
    'fulfilmentPoints', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', fp.id,
          'slug', fp.slug,
          'name', fp.name,
          'kind', fp.kind,
          'address', fp.address,
          'easyLocateBusinessRef', fp.easy_locate_business_ref,
          'easyLocateLink',
            case
              when el.id is null or el.status <> 'verified' then null
              else jsonb_build_object(
                'externalId', el.external_id,
                'externalSlug', el.external_slug,
                'canonicalUrl', el.canonical_url,
                'status', el.status,
                'verifiedAt', el.verified_at,
                'business', jsonb_strip_nulls(jsonb_build_object(
                  'id', el.public_snapshot->>'id',
                  'slug', el.public_snapshot->>'slug',
                  'name', el.public_snapshot->>'name',
                  'categories', coalesce(el.public_snapshot->'categories','[]'::jsonb),
                  'services', coalesce(el.public_snapshot->'services','[]'::jsonb),
                  'locationArea', el.public_snapshot->>'locationArea',
                  'locationExtension', el.public_snapshot->>'locationExtension',
                  'verificationLevel', el.public_snapshot->>'verificationLevel',
                  'claimed', coalesce((el.public_snapshot->>'claimed')::boolean,false)
                ))
              )
            end,
          'latitude', fp.latitude,
          'longitude', fp.longitude,
          'collectionEnabled', fp.collection_enabled,
          'dropoffEnabled', fp.dropoff_enabled,
          'services', fp.services,
          'feeAmount', fp.fee_amount,
          'openingHours', fp.opening_hours
        )
        order by
          case fp.kind when 'cafe' then 0 else 1 end,
          fp.sort_order,
          fp.name
      )
      from commerce.fulfilment_points fp
      left join commerce.fulfilment_point_external_links el
        on el.fulfilment_point_id=fp.id
       and el.tenant_id=fp.tenant_id
       and el.provider='easy_locate'
      where fp.tenant_id = v_tenant_id
        and fp.status = 'active'
        and fp.collection_enabled = true
    ), '[]'::jsonb)
  );
end
$$;

revoke all on function public.get_quick_solution_catalog(text) from public;
grant execute on function public.get_quick_solution_catalog(text) to anon, authenticated;
