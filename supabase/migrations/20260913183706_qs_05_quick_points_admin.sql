-- QS-05: staff-managed Quick Points + fulfilment snapshot at checkout.
-- Quick Points remain tenant-owned in XOS. Easy Locate is linked by reference only in this phase.

create or replace function public.admin_get_quick_solution_fulfilment_points(
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
  if auth.uid() is null then
    raise exception using errcode='42501', message='Staff sign-in is required.';
  end if;

  select t.id into v_tenant_id
  from public.tenants t
  where t.slug=lower(trim(p_tenant_slug))
    and t.status='active'
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode='22023', message='Quick Solution tenant was not found.';
  end if;

  if not public.is_app_admin()
     and not (public.is_opps_staff() and public.can_access_tenant(v_tenant_id)) then
    raise exception using errcode='42501', message='You do not have access to Quick Solution fulfilment points.';
  end if;

  return jsonb_build_object(
    'tenantId', v_tenant_id,
    'points', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', fp.id,
          'slug', fp.slug,
          'name', fp.name,
          'kind', fp.kind,
          'status', fp.status,
          'address', fp.address,
          'contactPhone', fp.contact_phone,
          'contactEmail', fp.contact_email,
          'easyLocateBusinessRef', fp.easy_locate_business_ref,
          'latitude', fp.latitude,
          'longitude', fp.longitude,
          'collectionEnabled', fp.collection_enabled,
          'dropoffEnabled', fp.dropoff_enabled,
          'services', fp.services,
          'feeAmount', fp.fee_amount,
          'openingHours', fp.opening_hours,
          'sortOrder', fp.sort_order,
          'createdAt', fp.created_at,
          'updatedAt', fp.updated_at,
          'orderCount', (
            select count(*)
            from commerce.service_orders so
            where so.fulfilment_point_id=fp.id
          )
        )
        order by
          case fp.kind when 'cafe' then 0 else 1 end,
          fp.sort_order,
          fp.name
      )
      from commerce.fulfilment_points fp
      where fp.tenant_id=v_tenant_id
    ), '[]'::jsonb)
  );
end
$$;

revoke all on function public.admin_get_quick_solution_fulfilment_points(text) from public, anon, authenticated;
grant execute on function public.admin_get_quick_solution_fulfilment_points(text) to authenticated;

create or replace function public.admin_upsert_quick_solution_fulfilment_point(
  p_tenant_slug text,
  p_point_id uuid,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_existing commerce.fulfilment_points;
  v_point_id uuid;
  v_name text;
  v_slug text;
  v_kind text;
  v_status text;
  v_address jsonb;
  v_contact_phone text;
  v_contact_email text;
  v_easy_ref text;
  v_lat numeric;
  v_lng numeric;
  v_collection boolean;
  v_dropoff boolean;
  v_services text[];
  v_fee numeric;
  v_opening_hours jsonb;
  v_sort integer;
begin
  if auth.uid() is null then
    raise exception using errcode='42501', message='Staff sign-in is required.';
  end if;

  select t.id into v_tenant_id
  from public.tenants t
  where t.slug=lower(trim(p_tenant_slug))
    and t.status='active'
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode='22023', message='Quick Solution tenant was not found.';
  end if;

  if not public.is_app_admin()
     and not (public.is_opps_staff() and public.can_access_tenant(v_tenant_id)) then
    raise exception using errcode='42501', message='You do not have access to Quick Solution fulfilment points.';
  end if;

  if p_payload is null or jsonb_typeof(p_payload) is distinct from 'object' then
    raise exception using errcode='22023', message='Quick Point details must be a JSON object.';
  end if;

  if p_point_id is not null then
    select * into v_existing
    from commerce.fulfilment_points fp
    where fp.id=p_point_id
      and fp.tenant_id=v_tenant_id
    for update;

    if v_existing.id is null then
      raise exception using errcode='22023', message='Quick Point was not found.';
    end if;
  end if;

  v_name := left(trim(coalesce(p_payload->>'name','')), 160);
  if length(v_name) < 2 then
    raise exception using errcode='22023', message='Quick Point name is required.';
  end if;

  v_kind := lower(trim(coalesce(
    case when p_point_id is not null then v_existing.kind else null end,
    p_payload->>'kind',
    'quick_point'
  )));

  if v_kind not in ('cafe','quick_point') then
    raise exception using errcode='22023', message='Point type must be café or Quick Point.';
  end if;

  if p_point_id is not null
     and v_existing.kind is distinct from v_kind
     and exists (select 1 from commerce.service_orders so where so.fulfilment_point_id=v_existing.id) then
    raise exception using errcode='22023', message='Point type cannot change after orders have used this location.';
  end if;

  v_status := lower(trim(coalesce(p_payload->>'status', case when p_point_id is null then 'active' else v_existing.status end, 'active')));
  if v_status not in ('active','inactive','coming_soon') then
    raise exception using errcode='22023', message='Point status is not supported.';
  end if;

  v_collection := coalesce((p_payload->>'collectionEnabled')::boolean, true);
  v_dropoff := coalesce((p_payload->>'dropoffEnabled')::boolean, false);
  if not v_collection and not v_dropoff then
    raise exception using errcode='22023', message='Enable collection, drop-off, or both.';
  end if;

  v_address := coalesce(p_payload->'address','{}'::jsonb);
  if jsonb_typeof(v_address) is distinct from 'object' then
    raise exception using errcode='22023', message='Address must be a JSON object.';
  end if;

  v_contact_phone := nullif(left(trim(coalesce(p_payload->>'contactPhone','')), 80),'');
  v_contact_email := nullif(left(lower(trim(coalesce(p_payload->>'contactEmail',''))), 180),'');
  if v_contact_email is not null and position('@' in v_contact_email) < 2 then
    raise exception using errcode='22023', message='Contact email is not valid.';
  end if;

  v_easy_ref := nullif(left(trim(coalesce(p_payload->>'easyLocateBusinessRef','')), 240),'');
  v_lat := nullif(p_payload->>'latitude','')::numeric;
  v_lng := nullif(p_payload->>'longitude','')::numeric;

  if v_lat is not null and (v_lat < -90 or v_lat > 90) then
    raise exception using errcode='22023', message='Latitude must be between -90 and 90.';
  end if;
  if v_lng is not null and (v_lng < -180 or v_lng > 180) then
    raise exception using errcode='22023', message='Longitude must be between -180 and 180.';
  end if;

  v_fee := greatest(coalesce(nullif(p_payload->>'feeAmount','')::numeric,0),0);
  v_sort := coalesce(nullif(p_payload->>'sortOrder','')::integer, 100);

  v_opening_hours := coalesce(p_payload->'openingHours','{}'::jsonb);
  if jsonb_typeof(v_opening_hours) is distinct from 'object' then
    raise exception using errcode='22023', message='Opening hours must be a JSON object.';
  end if;

  select coalesce(array_agg(value order by ordinality), '{}'::text[])
  into v_services
  from jsonb_array_elements_text(coalesce(p_payload->'services','[]'::jsonb)) with ordinality t(value, ordinality)
  where length(trim(value)) between 1 and 80;

  if p_point_id is null then
    v_slug := regexp_replace(lower(v_name), '[^a-z0-9]+', '-', 'g');
    v_slug := regexp_replace(v_slug, '(^-+|-+$)', '', 'g');
    if length(v_slug) < 2 then
      v_slug := 'quick-point-' || lower(substr(replace(gen_random_uuid()::text,'-',''),1,6));
    end if;

    if exists (
      select 1 from commerce.fulfilment_points fp
      where fp.tenant_id=v_tenant_id and fp.slug=v_slug
    ) then
      v_slug := left(v_slug, 90) || '-' || lower(substr(replace(gen_random_uuid()::text,'-',''),1,4));
    end if;

    insert into commerce.fulfilment_points (
      tenant_id, slug, name, kind, status, address,
      contact_phone, contact_email, easy_locate_business_ref,
      latitude, longitude, collection_enabled, dropoff_enabled,
      services, fee_amount, opening_hours, sort_order
    )
    values (
      v_tenant_id, v_slug, v_name, v_kind, v_status, v_address,
      v_contact_phone, v_contact_email, v_easy_ref,
      v_lat, v_lng, v_collection, v_dropoff,
      coalesce(v_services,'{}'::text[]), v_fee, v_opening_hours, v_sort
    )
    returning id into v_point_id;
  else
    v_point_id := v_existing.id;
    v_slug := v_existing.slug;

    if v_existing.kind='cafe'
       and (v_status <> 'active' or v_collection=false)
       and not exists (
         select 1
         from commerce.fulfilment_points fp
         where fp.tenant_id=v_tenant_id
           and fp.id <> v_existing.id
           and fp.kind='cafe'
           and fp.status='active'
           and fp.collection_enabled=true
       ) then
      raise exception using errcode='22023', message='Keep at least one active café collection location.';
    end if;

    update commerce.fulfilment_points fp
    set name=v_name,
        kind=v_kind,
        status=v_status,
        address=v_address,
        contact_phone=v_contact_phone,
        contact_email=v_contact_email,
        easy_locate_business_ref=v_easy_ref,
        latitude=v_lat,
        longitude=v_lng,
        collection_enabled=v_collection,
        dropoff_enabled=v_dropoff,
        services=coalesce(v_services,'{}'::text[]),
        fee_amount=v_fee,
        opening_hours=v_opening_hours,
        sort_order=v_sort,
        updated_at=now()
    where fp.id=v_existing.id
      and fp.tenant_id=v_tenant_id;
  end if;

  return (
    select jsonb_build_object(
      'ok', true,
      'point', jsonb_build_object(
        'id', fp.id,
        'slug', fp.slug,
        'name', fp.name,
        'kind', fp.kind,
        'status', fp.status,
        'address', fp.address,
        'contactPhone', fp.contact_phone,
        'contactEmail', fp.contact_email,
        'easyLocateBusinessRef', fp.easy_locate_business_ref,
        'latitude', fp.latitude,
        'longitude', fp.longitude,
        'collectionEnabled', fp.collection_enabled,
        'dropoffEnabled', fp.dropoff_enabled,
        'services', fp.services,
        'feeAmount', fp.fee_amount,
        'openingHours', fp.opening_hours,
        'sortOrder', fp.sort_order,
        'updatedAt', fp.updated_at
      )
    )
    from commerce.fulfilment_points fp
    where fp.id=v_point_id
  );
end
$$;

revoke all on function public.admin_upsert_quick_solution_fulfilment_point(text,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.admin_upsert_quick_solution_fulfilment_point(text,uuid,jsonb) to authenticated;

-- Capture the fulfilment point at order creation so later edits do not erase
-- what the customer originally chose.
create or replace function public.create_quick_solution_order(
  p_tenant_slug text,
  p_product_key text,
  p_configuration jsonb,
  p_customer_name text,
  p_customer_email text default null,
  p_customer_phone text default null,
  p_fulfilment_type text default 'cafe',
  p_fulfilment_point_id uuid default null,
  p_delivery_address jsonb default null,
  p_customer_notes text default null,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_order_id uuid;
  v_order_item_id uuid;
  v_existing commerce.service_orders;
  v_order_number text;
  v_price jsonb;
  v_product_id uuid;
  v_product_name text;
  v_subtotal numeric;
  v_fulfilment_fee numeric := 0;
  v_total numeric;
  v_fulfilment_type text;
  v_point commerce.fulfilment_points;
  v_email text;
  v_phone text;
  v_upload_token text;
  v_fulfilment_snapshot jsonb := null;
begin
  select t.id into v_tenant_id
  from public.tenants t
  where t.slug = lower(trim(p_tenant_slug))
    and t.status = 'active'
    and exists (
      select 1 from public.tenant_capabilities tc
      where tc.tenant_id = t.id
        and tc.capability_key = 'quick_solution'
        and tc.enabled = true
    )
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode = '22023', message = 'Quick Solution storefront is not active.';
  end if;
  if length(trim(coalesce(p_idempotency_key,''))) < 8 then
    raise exception using errcode = '22023', message = 'Order idempotency key is required.';
  end if;
  if length(trim(coalesce(p_customer_name,''))) < 2 then
    raise exception using errcode = '22023', message = 'Customer name is required.';
  end if;

  v_email := nullif(lower(trim(coalesce(p_customer_email,''))), '');
  v_phone := nullif(trim(coalesce(p_customer_phone,'')), '');
  if v_email is null and v_phone is null then
    raise exception using errcode = '22023', message = 'Provide an email address or phone number.';
  end if;
  if v_email is not null and position('@' in v_email) < 2 then
    raise exception using errcode = '22023', message = 'Email address is not valid.';
  end if;
  if v_phone is not null and length(regexp_replace(v_phone, '[^0-9+]', '', 'g')) < 7 then
    raise exception using errcode = '22023', message = 'Phone number is not valid.';
  end if;

  select * into v_existing
  from commerce.service_orders so
  where so.tenant_id = v_tenant_id
    and so.idempotency_key = trim(p_idempotency_key)
  limit 1;

  if v_existing.id is not null then
    v_upload_token := encode(extensions.gen_random_bytes(32), 'hex');
    update commerce.service_orders
    set upload_token_hash = encode(extensions.digest(v_upload_token, 'sha256'), 'hex'),
        upload_token_expires_at = now() + interval '24 hours'
    where id = v_existing.id;

    select soi.id into v_order_item_id
    from commerce.service_order_items soi
    where soi.order_id = v_existing.id
    order by soi.created_at asc
    limit 1;

    return jsonb_build_object(
      'ok', true, 'replayed', true,
      'orderId', v_existing.id, 'orderItemId', v_order_item_id,
      'orderNumber', v_existing.order_number,
      'subtotal', v_existing.subtotal,
      'fulfilmentFee', v_existing.fulfilment_fee,
      'totalAmount', v_existing.total_amount,
      'status', v_existing.status,
      'uploadToken', v_upload_token,
      'uploadTokenExpiresAt', now() + interval '24 hours'
    );
  end if;

  v_price := commerce.qs_calculate_price(v_tenant_id, trim(p_product_key), p_configuration);
  v_product_id := (v_price->>'productId')::uuid;
  v_product_name := v_price->>'productName';
  v_subtotal := (v_price->>'total')::numeric;
  v_fulfilment_type := lower(trim(coalesce(p_fulfilment_type,'cafe')));

  if v_fulfilment_type in ('cafe','quick_point') then
    if p_fulfilment_point_id is null then
      if v_fulfilment_type = 'quick_point' then
        raise exception using errcode = '22023', message = 'Choose a Quick Point.';
      end if;
      select * into v_point
      from commerce.fulfilment_points fp
      where fp.tenant_id = v_tenant_id
        and fp.kind = 'cafe'
        and fp.status = 'active'
        and fp.collection_enabled = true
      order by fp.sort_order, fp.created_at
      limit 1;
    else
      select * into v_point
      from commerce.fulfilment_points fp
      where fp.id = p_fulfilment_point_id
        and fp.tenant_id = v_tenant_id
        and fp.kind = v_fulfilment_type
        and fp.status = 'active'
        and fp.collection_enabled = true
      limit 1;
    end if;

    if v_point.id is null then
      raise exception using errcode = '22023', message = 'Selected collection point is not available.';
    end if;

    v_fulfilment_fee := coalesce(v_point.fee_amount,0);
    v_fulfilment_snapshot := jsonb_build_object(
      'id', v_point.id,
      'slug', v_point.slug,
      'name', v_point.name,
      'kind', v_point.kind,
      'address', v_point.address,
      'contactPhone', v_point.contact_phone,
      'easyLocateBusinessRef', v_point.easy_locate_business_ref,
      'latitude', v_point.latitude,
      'longitude', v_point.longitude,
      'services', v_point.services,
      'feeAmount', v_point.fee_amount
    );
  elsif v_fulfilment_type = 'delivery' then
    if p_delivery_address is null or jsonb_typeof(p_delivery_address) is distinct from 'object' then
      raise exception using errcode = '22023', message = 'Delivery address is required.';
    end if;
    v_fulfilment_fee := 0;
  else
    raise exception using errcode = '22023', message = 'Unsupported fulfilment type.';
  end if;

  v_total := round(v_subtotal + v_fulfilment_fee, 2);
  v_order_number := commerce.qs_generate_order_number();
  v_upload_token := encode(extensions.gen_random_bytes(32), 'hex');

  insert into commerce.service_orders (
    tenant_id, order_number, status, customer_name, customer_email, customer_phone,
    fulfilment_type, fulfilment_point_id, delivery_address, subtotal, fulfilment_fee,
    total_amount, payment_status, idempotency_key, customer_notes, source_metadata,
    upload_token_hash, upload_token_expires_at
  ) values (
    v_tenant_id, v_order_number, 'submitted', trim(p_customer_name), v_email, v_phone,
    v_fulfilment_type,
    case when v_fulfilment_type in ('cafe','quick_point') then v_point.id else null end,
    case when v_fulfilment_type='delivery' then p_delivery_address else null end,
    v_subtotal, v_fulfilment_fee, v_total, 'unpaid', trim(p_idempotency_key),
    nullif(trim(coalesce(p_customer_notes,'')), ''),
    jsonb_build_object(
      'channel','storefront',
      'deliveryFeeStatus', case when v_fulfilment_type='delivery' then 'pending_confirmation' else 'not_required' end,
      'fulfilmentPointSnapshot', v_fulfilment_snapshot
    ),
    encode(extensions.digest(v_upload_token, 'sha256'), 'hex'),
    now() + interval '24 hours'
  ) returning id into v_order_id;

  insert into commerce.service_order_items (
    order_id, tenant_id, product_id, product_key, product_name, quantity,
    configuration, pricing_snapshot, line_total
  ) values (
    v_order_id, v_tenant_id, v_product_id, trim(p_product_key), v_product_name, 1,
    p_configuration, v_price->'snapshot', v_subtotal
  ) returning id into v_order_item_id;

  return jsonb_build_object(
    'ok', true, 'replayed', false,
    'orderId', v_order_id, 'orderItemId', v_order_item_id,
    'orderNumber', v_order_number,
    'subtotal', v_subtotal,
    'fulfilmentFee', v_fulfilment_fee,
    'totalAmount', v_total,
    'status', 'submitted',
    'deliveryFeeStatus', case when v_fulfilment_type='delivery' then 'pending_confirmation' else 'not_required' end,
    'uploadToken', v_upload_token,
    'uploadTokenExpiresAt', now() + interval '24 hours'
  );
end
$$;

revoke all on function public.create_quick_solution_order(text,text,jsonb,text,text,text,text,uuid,jsonb,text,text) from public;
grant execute on function public.create_quick_solution_order(text,text,jsonb,text,text,text,text,uuid,jsonb,text,text) to anon, authenticated;
