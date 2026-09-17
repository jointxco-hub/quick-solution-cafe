-- QS-13.3: additive multi-item cart order intake for Quick Solution.
-- Keeps public.create_quick_solution_order(...) unchanged for legacy/single-item flow.

alter table commerce.service_order_items
  add column if not exists client_item_key text;

create unique index if not exists uq_qs_service_order_items_order_client_key
  on commerce.service_order_items(order_id, client_item_key)
  where client_item_key is not null;

create or replace function public.create_quick_solution_cart_order(
  p_tenant_slug text,
  p_items jsonb,
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
  v_existing commerce.service_orders;
  v_order_number text;
  v_subtotal numeric := 0;
  v_fulfilment_fee numeric := 0;
  v_total numeric := 0;
  v_fulfilment_type text;
  v_point commerce.fulfilment_points;
  v_email text;
  v_phone text;
  v_upload_token text;
  v_payment_token text;
  v_tracking jsonb;
  v_fulfilment_snapshot jsonb := null;
  v_item jsonb;
  v_price jsonb;
  v_product_id uuid;
  v_product_name text;
  v_product_key text;
  v_configuration jsonb;
  v_client_item_key text;
  v_priced_items jsonb := '[]'::jsonb;
  v_response_items jsonb := '[]'::jsonb;
  v_order_item_id uuid;
  v_count integer;
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

  if p_items is null or jsonb_typeof(p_items) is distinct from 'array' then
    raise exception using errcode = '22023', message = 'Cart items must be an array.';
  end if;

  v_count := jsonb_array_length(p_items);
  if v_count < 1 then
    raise exception using errcode = '22023', message = 'Add at least one item to the order.';
  end if;
  if v_count > 25 then
    raise exception using errcode = '22023', message = 'This order has too many items. Split it into smaller orders.';
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
    v_payment_token := encode(extensions.gen_random_bytes(32), 'hex');
    v_tracking := commerce.qs_issue_tracking_token(v_existing.id);

    update commerce.service_orders
    set upload_token_hash = encode(extensions.digest(v_upload_token, 'sha256'), 'hex'),
        upload_token_expires_at = now() + interval '24 hours',
        payment_token_hash = encode(extensions.digest(v_payment_token, 'sha256'), 'hex'),
        payment_token_expires_at = now() + interval '7 days'
    where id = v_existing.id;

    select coalesce(jsonb_agg(jsonb_build_object(
      'clientItemKey', soi.client_item_key,
      'orderItemId', soi.id,
      'productKey', soi.product_key,
      'productName', soi.product_name,
      'lineTotal', soi.line_total
    ) order by soi.created_at, soi.id), '[]'::jsonb)
    into v_response_items
    from commerce.service_order_items soi
    where soi.order_id = v_existing.id;

    return jsonb_build_object(
      'ok', true,
      'replayed', true,
      'orderId', v_existing.id,
      'orderNumber', v_existing.order_number,
      'items', v_response_items,
      'subtotal', v_existing.subtotal,
      'fulfilmentFee', v_existing.fulfilment_fee,
      'totalAmount', v_existing.total_amount,
      'status', v_existing.status,
      'paymentStatus', v_existing.payment_status,
      'deliveryFeeStatus', coalesce(v_existing.source_metadata->>'deliveryFeeStatus','not_required'),
      'uploadToken', v_upload_token,
      'uploadTokenExpiresAt', now() + interval '24 hours',
      'paymentToken', v_payment_token,
      'paymentTokenExpiresAt', now() + interval '7 days',
      'trackingToken', v_tracking->>'token',
      'trackingTokenExpiresAt', v_tracking->>'expiresAt'
    );
  end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    if jsonb_typeof(v_item) is distinct from 'object' then
      raise exception using errcode = '22023', message = 'Every cart item must be an object.';
    end if;

    v_product_key := trim(coalesce(v_item->>'productKey',''));
    v_client_item_key := trim(coalesce(v_item->>'clientItemKey',''));
    v_configuration := coalesce(v_item->'configuration','{}'::jsonb);

    if v_product_key = '' then
      raise exception using errcode = '22023', message = 'Every cart item needs a product key.';
    end if;
    if length(v_client_item_key) < 8 then
      raise exception using errcode = '22023', message = 'Every cart item needs a stable item key.';
    end if;
    if jsonb_typeof(v_configuration) is distinct from 'object' then
      raise exception using errcode = '22023', message = 'Every cart item configuration must be an object.';
    end if;
    if exists (
      select 1
      from jsonb_array_elements(v_priced_items) x
      where x->>'clientItemKey' = v_client_item_key
    ) then
      raise exception using errcode = '22023', message = 'Duplicate cart item key.';
    end if;

    v_price := commerce.qs_calculate_price(v_tenant_id, v_product_key, v_configuration);
    v_product_id := (v_price->>'productId')::uuid;
    v_product_name := v_price->>'productName';
    v_subtotal := v_subtotal + (v_price->>'total')::numeric;

    v_priced_items := v_priced_items || jsonb_build_array(jsonb_build_object(
      'clientItemKey', v_client_item_key,
      'productId', v_product_id,
      'productKey', v_product_key,
      'productName', v_product_name,
      'configuration', v_configuration,
      'pricingSnapshot', v_price->'snapshot',
      'lineTotal', (v_price->>'total')::numeric
    ));
  end loop;

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

  v_subtotal := round(v_subtotal,2);
  v_total := round(v_subtotal + v_fulfilment_fee,2);
  v_order_number := commerce.qs_generate_order_number();
  v_upload_token := encode(extensions.gen_random_bytes(32), 'hex');
  v_payment_token := encode(extensions.gen_random_bytes(32), 'hex');

  insert into commerce.service_orders (
    tenant_id, order_number, status, customer_name, customer_email, customer_phone,
    fulfilment_type, fulfilment_point_id, delivery_address, subtotal, fulfilment_fee,
    total_amount, payment_status, idempotency_key, customer_notes, source_metadata,
    upload_token_hash, upload_token_expires_at,
    payment_token_hash, payment_token_expires_at
  ) values (
    v_tenant_id, v_order_number, 'submitted', trim(p_customer_name), v_email, v_phone,
    v_fulfilment_type,
    case when v_fulfilment_type in ('cafe','quick_point') then v_point.id else null end,
    case when v_fulfilment_type='delivery' then p_delivery_address else null end,
    v_subtotal, v_fulfilment_fee, v_total, 'unpaid', trim(p_idempotency_key),
    nullif(trim(coalesce(p_customer_notes,'')), ''),
    jsonb_build_object(
      'channel','storefront_cart',
      'itemCount', v_count,
      'deliveryFeeStatus', case when v_fulfilment_type='delivery' then 'pending_confirmation' else 'not_required' end,
      'fulfilmentPointSnapshot', v_fulfilment_snapshot
    ),
    encode(extensions.digest(v_upload_token, 'sha256'), 'hex'),
    now() + interval '24 hours',
    encode(extensions.digest(v_payment_token, 'sha256'), 'hex'),
    now() + interval '7 days'
  ) returning id into v_order_id;

  for v_item in select value from jsonb_array_elements(v_priced_items)
  loop
    insert into commerce.service_order_items (
      order_id, tenant_id, product_id, product_key, product_name, quantity,
      configuration, pricing_snapshot, line_total, client_item_key
    ) values (
      v_order_id,
      v_tenant_id,
      (v_item->>'productId')::uuid,
      v_item->>'productKey',
      v_item->>'productName',
      1,
      v_item->'configuration',
      v_item->'pricingSnapshot',
      (v_item->>'lineTotal')::numeric,
      v_item->>'clientItemKey'
    ) returning id into v_order_item_id;

    v_response_items := v_response_items || jsonb_build_array(jsonb_build_object(
      'clientItemKey', v_item->>'clientItemKey',
      'orderItemId', v_order_item_id,
      'productKey', v_item->>'productKey',
      'productName', v_item->>'productName',
      'lineTotal', (v_item->>'lineTotal')::numeric
    ));
  end loop;

  v_tracking := commerce.qs_issue_tracking_token(v_order_id);

  return jsonb_build_object(
    'ok', true,
    'replayed', false,
    'orderId', v_order_id,
    'orderNumber', v_order_number,
    'items', v_response_items,
    'subtotal', v_subtotal,
    'fulfilmentFee', v_fulfilment_fee,
    'totalAmount', v_total,
    'status', 'submitted',
    'paymentStatus', 'unpaid',
    'deliveryFeeStatus', case when v_fulfilment_type='delivery' then 'pending_confirmation' else 'not_required' end,
    'uploadToken', v_upload_token,
    'uploadTokenExpiresAt', now() + interval '24 hours',
    'paymentToken', v_payment_token,
    'paymentTokenExpiresAt', now() + interval '7 days',
    'trackingToken', v_tracking->>'token',
    'trackingTokenExpiresAt', v_tracking->>'expiresAt'
  );
end
$$;

revoke all on function public.create_quick_solution_cart_order(text,jsonb,text,text,text,text,uuid,jsonb,text,text) from public;
grant execute on function public.create_quick_solution_cart_order(text,jsonb,text,text,text,text,uuid,jsonb,text,text) to anon, authenticated;
