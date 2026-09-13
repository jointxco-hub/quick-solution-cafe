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
      'deliveryFeeStatus', case when v_fulfilment_type='delivery' then 'pending_confirmation' else 'not_required' end
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

grant execute on function public.create_quick_solution_order(text,text,jsonb,text,text,text,text,uuid,jsonb,text,text) to anon, authenticated;

create or replace function public.qs_authorize_file_upload(
  p_order_id uuid,
  p_upload_token text,
  p_order_item_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order commerce.service_orders;
  v_item_id uuid;
begin
  select * into v_order
  from commerce.service_orders so
  where so.id = p_order_id
  limit 1;

  if v_order.id is null
     or v_order.upload_token_hash is null
     or v_order.upload_token_expires_at is null
     or v_order.upload_token_expires_at < now()
     or encode(extensions.digest(coalesce(p_upload_token,''), 'sha256'), 'hex') <> v_order.upload_token_hash then
    raise exception using errcode = '42501', message = 'Upload authorization is invalid or expired.';
  end if;
  if v_order.status in ('completed','cancelled') then
    raise exception using errcode = '22023', message = 'This order no longer accepts uploads.';
  end if;

  select soi.id into v_item_id
  from commerce.service_order_items soi
  where soi.order_id = v_order.id
    and soi.tenant_id = v_order.tenant_id
    and (p_order_item_id is null or soi.id = p_order_item_id)
  order by soi.created_at asc
  limit 1;
  if v_item_id is null then
    raise exception using errcode = '22023', message = 'Order item could not be resolved.';
  end if;

  return jsonb_build_object(
    'ok', true,
    'tenantId', v_order.tenant_id,
    'orderId', v_order.id,
    'orderItemId', v_item_id,
    'orderNumber', v_order.order_number,
    'storageBucket', 'uploads',
    'maxFiles', 5,
    'maxBytes', 20971520
  );
end
$$;

revoke all on function public.qs_authorize_file_upload(uuid,text,uuid) from public, anon, authenticated;
grant execute on function public.qs_authorize_file_upload(uuid,text,uuid) to service_role;

create or replace function public.qs_register_file_upload(
  p_order_id uuid,
  p_order_item_id uuid,
  p_upload_token text,
  p_storage_path text,
  p_original_filename text,
  p_mime_type text,
  p_byte_size bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth jsonb;
  v_tenant_id uuid;
  v_file_id uuid;
  v_ref jsonb;
  v_prefix text;
  v_existing_count integer;
begin
  v_auth := public.qs_authorize_file_upload(p_order_id, p_upload_token, p_order_item_id);
  v_tenant_id := (v_auth->>'tenantId')::uuid;
  v_prefix := v_tenant_id::text || '/quick-solution/orders/' || p_order_id::text || '/' || p_order_item_id::text || '/';

  if p_storage_path is null
     or p_storage_path not like (v_prefix || '%')
     or p_storage_path like '%..%' then
    raise exception using errcode = '22023', message = 'Storage path is not valid for this order.';
  end if;
  if length(trim(coalesce(p_original_filename,''))) < 1 or length(p_original_filename) > 255 then
    raise exception using errcode = '22023', message = 'Filename is not valid.';
  end if;
  if p_byte_size <= 0 or p_byte_size > 20971520 then
    raise exception using errcode = '22023', message = 'File is larger than the 20MB limit.';
  end if;

  select count(*) into v_existing_count
  from commerce.service_order_files f
  where f.order_id = p_order_id
    and f.order_item_id = p_order_item_id
    and f.status = 'uploaded';
  if v_existing_count >= 5 then
    raise exception using errcode = '22023', message = 'This order item already has the maximum number of files.';
  end if;

  insert into commerce.service_order_files (
    tenant_id, order_id, order_item_id, storage_bucket, storage_path,
    original_filename, mime_type, byte_size, status
  ) values (
    v_tenant_id, p_order_id, p_order_item_id, 'uploads', p_storage_path,
    trim(p_original_filename), nullif(trim(coalesce(p_mime_type,'')), ''), p_byte_size, 'uploaded'
  ) returning id into v_file_id;

  v_ref := jsonb_build_object(
    'id', v_file_id,
    'bucket', 'uploads',
    'path', p_storage_path,
    'name', trim(p_original_filename),
    'mimeType', nullif(trim(coalesce(p_mime_type,'')), ''),
    'byteSize', p_byte_size,
    'uploadedAt', now()
  );

  update commerce.service_order_items soi
  set file_refs = coalesce(soi.file_refs, '[]'::jsonb) || jsonb_build_array(v_ref)
  where soi.id = p_order_item_id
    and soi.order_id = p_order_id
    and soi.tenant_id = v_tenant_id;

  return jsonb_build_object('ok',true,'file',v_ref);
end
$$;

revoke all on function public.qs_register_file_upload(uuid,uuid,text,text,text,text,bigint) from public, anon, authenticated;
grant execute on function public.qs_register_file_upload(uuid,uuid,text,text,text,text,bigint) to service_role;
