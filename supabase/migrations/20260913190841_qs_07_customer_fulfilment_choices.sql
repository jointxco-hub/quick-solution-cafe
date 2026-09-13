-- QS-07: customer-facing fulfilment choices + safe Easy Locate identity in public catalogue.
-- Also repairs the staging acceptance setup so Bhungane is a Quick Point, not the main café identity.

do $$
declare
  v_tenant_id uuid;
  v_cafe_id uuid;
  v_bhungane_point_id uuid;
  v_bhungane_link_id uuid;
  v_bhungane_external_id text;
  v_snapshot jsonb;
begin
  select id into v_tenant_id
  from public.tenants
  where slug='quick-solution'
  limit 1;

  if v_tenant_id is null then
    return;
  end if;

  select id into v_cafe_id
  from commerce.fulfilment_points
  where tenant_id=v_tenant_id
    and slug='location-001'
  limit 1;

  select el.id, el.external_id, el.public_snapshot
  into v_bhungane_link_id, v_bhungane_external_id, v_snapshot
  from commerce.fulfilment_point_external_links el
  where el.tenant_id=v_tenant_id
    and el.provider='easy_locate'
    and el.external_slug='bhungane-porcupine-enterprise-00a7a894'
  limit 1;

  if v_bhungane_link_id is not null then
    select id into v_bhungane_point_id
    from commerce.fulfilment_points
    where tenant_id=v_tenant_id
      and slug='bhungane-porcupine-enterprise'
    limit 1;

    if v_bhungane_point_id is null then
      insert into commerce.fulfilment_points (
        tenant_id,
        slug,
        name,
        kind,
        status,
        address,
        contact_phone,
        contact_email,
        easy_locate_business_ref,
        latitude,
        longitude,
        collection_enabled,
        dropoff_enabled,
        services,
        fee_amount,
        opening_hours,
        sort_order
      )
      values (
        v_tenant_id,
        'bhungane-porcupine-enterprise',
        coalesce(nullif(v_snapshot->>'name',''),'Bhungane Porcupine Enterprise'),
        'quick_point',
        'active',
        jsonb_strip_nulls(jsonb_build_object(
          'line1', nullif(v_snapshot->>'locationExtension',''),
          'area', nullif(v_snapshot->>'locationArea','')
        )),
        null,
        null,
        v_bhungane_external_id,
        null,
        null,
        true,
        false,
        '{}'::text[],
        0,
        '{}'::jsonb,
        50
      )
      returning id into v_bhungane_point_id;
    else
      update commerce.fulfilment_points
      set name=coalesce(nullif(v_snapshot->>'name',''),name),
          kind='quick_point',
          status='active',
          address=jsonb_strip_nulls(jsonb_build_object(
            'line1', nullif(v_snapshot->>'locationExtension',''),
            'area', nullif(v_snapshot->>'locationArea','')
          )),
          easy_locate_business_ref=v_bhungane_external_id,
          collection_enabled=true,
          dropoff_enabled=false,
          updated_at=now()
      where id=v_bhungane_point_id;
    end if;

    update commerce.fulfilment_point_external_links
    set fulfilment_point_id=v_bhungane_point_id,
        updated_at=now()
    where id=v_bhungane_link_id;

    if v_cafe_id is not null and v_cafe_id <> v_bhungane_point_id then
      update commerce.fulfilment_points
      set easy_locate_business_ref=null,
          updated_at=now()
      where id=v_cafe_id
        and easy_locate_business_ref=v_bhungane_external_id;
    end if;
  end if;
end
$$;

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
