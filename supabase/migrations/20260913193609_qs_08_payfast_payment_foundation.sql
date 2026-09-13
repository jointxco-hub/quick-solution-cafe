-- QS-08: PayFast payment foundation for Quick Solution service orders.
-- Already applied to Joint X XOS Staging as 20260913193609_qs_08_payfast_payment_foundation.

alter table commerce.service_orders
  add column if not exists payment_token_hash text,
  add column if not exists payment_token_expires_at timestamptz;

create table if not exists commerce.service_order_payments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  service_order_id uuid not null references commerce.service_orders(id) on delete cascade,
  provider text not null default 'payfast' check (provider in ('payfast')),
  status text not null default 'pending' check (status in ('pending','completed','failed','cancelled')),
  amount numeric(12,2) not null check (amount > 0),
  pf_payment_id text,
  raw_itn jsonb,
  initiated_at timestamptz not null default now(),
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_qs_service_order_payments_order
  on commerce.service_order_payments(service_order_id, created_at desc);

create unique index if not exists uq_qs_service_order_payments_pf
  on commerce.service_order_payments(provider, pf_payment_id)
  where pf_payment_id is not null;

alter table commerce.service_order_payments enable row level security;
revoke all on commerce.service_order_payments from anon, authenticated;

do $$
begin
  if not exists (
    select 1 from pg_trigger
    where tgname='trg_qs_service_order_payments_updated_at'
      and tgrelid='commerce.service_order_payments'::regclass
  ) then
    create trigger trg_qs_service_order_payments_updated_at
    before update on commerce.service_order_payments
    for each row execute function public.handle_updated_at();
  end if;
end
$$;

create or replace function commerce.qs_begin_payfast_payment(
  p_order_id uuid,
  p_payment_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order commerce.service_orders;
  v_payment_id uuid;
begin
  if coalesce(auth.role(),'') <> 'service_role'
     and session_user not in ('postgres','supabase_admin') then
    raise exception using errcode='42501', message='Trusted backend access is required.';
  end if;

  select * into v_order
  from commerce.service_orders so
  where so.id=p_order_id
  for update;

  if v_order.id is null then
    return jsonb_build_object('ok',false,'reason','not_available');
  end if;

  if v_order.payment_token_hash is null
     or v_order.payment_token_expires_at is null
     or v_order.payment_token_expires_at <= now()
     or encode(extensions.digest(coalesce(p_payment_token,''), 'sha256'),'hex') <> v_order.payment_token_hash then
    return jsonb_build_object('ok',false,'reason','not_available');
  end if;

  if v_order.payment_status='paid' then
    return jsonb_build_object(
      'ok',true,'alreadyPaid',true,'orderId',v_order.id,
      'orderNumber',v_order.order_number,'amount',v_order.total_amount,'paymentStatus','paid'
    );
  end if;

  if v_order.status in ('cancelled','completed') or v_order.total_amount <= 0 then
    return jsonb_build_object('ok',false,'reason','not_available');
  end if;

  select p.id into v_payment_id
  from commerce.service_order_payments p
  where p.service_order_id=v_order.id
    and p.status='pending'
    and p.initiated_at > now() - interval '20 minutes'
  order by p.initiated_at desc
  limit 1;

  if v_payment_id is null then
    insert into commerce.service_order_payments (
      tenant_id, service_order_id, provider, status, amount
    )
    values (
      v_order.tenant_id, v_order.id, 'payfast', 'pending', v_order.total_amount
    )
    returning id into v_payment_id;
  end if;

  return jsonb_build_object(
    'ok',true,'alreadyPaid',false,'paymentIntentId',v_payment_id,
    'orderId',v_order.id,'orderNumber',v_order.order_number,'amount',v_order.total_amount,
    'customerName',v_order.customer_name,'customerEmail',v_order.customer_email,
    'customerPhone',v_order.customer_phone,'paymentStatus',v_order.payment_status
  );
end
$$;

revoke all on function commerce.qs_begin_payfast_payment(uuid,text) from public, anon, authenticated;
grant execute on function commerce.qs_begin_payfast_payment(uuid,text) to service_role;

create or replace function commerce.qs_get_payment_status(
  p_order_id uuid,
  p_payment_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order commerce.service_orders;
  v_completed_at timestamptz;
begin
  if coalesce(auth.role(),'') <> 'service_role'
     and session_user not in ('postgres','supabase_admin') then
    raise exception using errcode='42501', message='Trusted backend access is required.';
  end if;

  select * into v_order
  from commerce.service_orders so
  where so.id=p_order_id
  limit 1;

  if v_order.id is null
     or v_order.payment_token_hash is null
     or v_order.payment_token_expires_at is null
     or v_order.payment_token_expires_at <= now()
     or encode(extensions.digest(coalesce(p_payment_token,''), 'sha256'),'hex') <> v_order.payment_token_hash then
    return jsonb_build_object('ok',false,'reason','not_available');
  end if;

  select p.completed_at into v_completed_at
  from commerce.service_order_payments p
  where p.service_order_id=v_order.id
    and p.status='completed'
  order by p.completed_at desc nulls last, p.created_at desc
  limit 1;

  return jsonb_build_object(
    'ok',true,'orderId',v_order.id,'orderNumber',v_order.order_number,
    'amount',v_order.total_amount,'paymentStatus',v_order.payment_status,
    'paid',v_order.payment_status='paid','paidAt',v_completed_at
  );
end
$$;

revoke all on function commerce.qs_get_payment_status(uuid,text) from public, anon, authenticated;
grant execute on function commerce.qs_get_payment_status(uuid,text) to service_role;

create or replace function commerce.qs_apply_payfast_payment(
  p_order_id uuid,
  p_amount numeric,
  p_pf_payment_id text,
  p_raw_itn jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order commerce.service_orders;
  v_expected numeric;
  v_existing_payment commerce.service_order_payments;
  v_preview jsonb;
  v_handoff_status text;
  v_clean_warnings jsonb := '[]'::jsonb;
begin
  if coalesce(auth.role(),'') <> 'service_role'
     and session_user not in ('postgres','supabase_admin') then
    raise exception using errcode='42501', message='Trusted backend access is required.';
  end if;

  if p_order_id is null
     or nullif(trim(coalesce(p_pf_payment_id,'')),'') is null
     or p_amount is null
     or p_amount <= 0 then
    return jsonb_build_object('ok',false,'reason','invalid_args');
  end if;

  select * into v_order
  from commerce.service_orders so
  where so.id=p_order_id
  for update;

  if v_order.id is null then
    return jsonb_build_object('ok',false,'reason','not_found');
  end if;

  v_expected := round(v_order.total_amount,2);
  if round(p_amount,2) <> v_expected then
    return jsonb_build_object(
      'ok',false,'reason','amount_mismatch','expected',v_expected,'received',round(p_amount,2)
    );
  end if;

  select * into v_existing_payment
  from commerce.service_order_payments p
  where p.provider='payfast'
    and p.pf_payment_id=trim(p_pf_payment_id)
  limit 1;

  if v_existing_payment.id is not null
     and v_existing_payment.service_order_id <> v_order.id then
    return jsonb_build_object('ok',false,'reason','duplicate_provider_reference');
  end if;

  if v_order.payment_status='paid' then
    return jsonb_build_object(
      'ok',true,'duplicate',v_existing_payment.id is not null,'ignored',true,
      'paymentStatus','paid','orderId',v_order.id,'orderNumber',v_order.order_number
    );
  end if;

  if v_existing_payment.id is null then
    insert into commerce.service_order_payments (
      tenant_id, service_order_id, provider, status, amount,
      pf_payment_id, raw_itn, completed_at
    )
    values (
      v_order.tenant_id, v_order.id, 'payfast', 'completed', v_expected,
      trim(p_pf_payment_id), coalesce(p_raw_itn,'{}'::jsonb), now()
    );
  else
    update commerce.service_order_payments
    set status='completed', amount=v_expected,
        raw_itn=coalesce(p_raw_itn,'{}'::jsonb),
        completed_at=coalesce(completed_at,now())
    where id=v_existing_payment.id;
  end if;

  update commerce.service_order_payments
  set status='cancelled'
  where service_order_id=v_order.id
    and provider='payfast'
    and status='pending'
    and pf_payment_id is null;

  update commerce.service_orders
  set payment_status='paid',
      source_metadata=coalesce(source_metadata,'{}'::jsonb) ||
        jsonb_build_object(
          'payment',
          jsonb_build_object(
            'provider','payfast','status','paid','paidAt',now(),
            'pfPaymentId',trim(p_pf_payment_id)
          )
        ),
      updated_at=now()
  where id=v_order.id;

  if v_order.opps_order_id is not null then
    update public.orders
    set payment_status='paid',
        deposit_paid=greatest(coalesce(deposit_paid,0),v_expected),
        updated_at=now()
    where id=v_order.opps_order_id
      and tenant_id=v_order.tenant_id;
  end if;

  select h.status into v_handoff_status
  from commerce.service_order_handoffs h
  where h.service_order_id=v_order.id
  limit 1;

  if v_handoff_status is not null and v_handoff_status <> 'sent' then
    v_preview := commerce.qs_build_opps_handoff_preview(v_order.id);

    update commerce.service_order_handoffs
    set status=case when coalesce((v_preview->>'ready')::boolean,false) then 'ready' else 'blocked' end,
        preview_payload=v_preview,
        blockers=coalesce(v_preview->'blockers','[]'::jsonb),
        warnings=coalesce(v_preview->'warnings','[]'::jsonb),
        last_previewed_at=now(),
        failure_message=null
    where service_order_id=v_order.id;
  elsif v_handoff_status='sent' then
    select coalesce(
      jsonb_agg(item) filter (where item->>'code' is distinct from 'PAYMENT_NOT_PAID'),
      '[]'::jsonb
    )
    into v_clean_warnings
    from commerce.service_order_handoffs h
    left join lateral jsonb_array_elements(coalesce(h.warnings,'[]'::jsonb)) item on true
    where h.service_order_id=v_order.id;

    update commerce.service_order_handoffs
    set warnings=v_clean_warnings,
        preview_payload=
          jsonb_set(
            jsonb_set(
              jsonb_set(
                coalesce(preview_payload,'{}'::jsonb),
                '{warnings}',v_clean_warnings,true
              ),
              '{proposedOppsOrder,payment_status}',to_jsonb('paid'::text),true
            ),
            '{proposedOppsOrder,deposit_paid}',to_jsonb(v_expected),true
          ),
        updated_at=now()
    where service_order_id=v_order.id;
  end if;

  return jsonb_build_object(
    'ok',true,'duplicate',false,'ignored',false,'paymentStatus','paid',
    'orderId',v_order.id,'orderNumber',v_order.order_number,'amount',v_expected
  );
end
$$;

revoke all on function commerce.qs_apply_payfast_payment(uuid,numeric,text,jsonb) from public, anon, authenticated;
grant execute on function commerce.qs_apply_payfast_payment(uuid,numeric,text,jsonb) to service_role;


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
  v_payment_token text;
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
    v_payment_token := encode(extensions.gen_random_bytes(32), 'hex');

    update commerce.service_orders
    set upload_token_hash = encode(extensions.digest(v_upload_token, 'sha256'), 'hex'),
        upload_token_expires_at = now() + interval '24 hours',
        payment_token_hash = encode(extensions.digest(v_payment_token, 'sha256'), 'hex'),
        payment_token_expires_at = now() + interval '7 days'
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
      'paymentStatus', v_existing.payment_status,
      'uploadToken', v_upload_token,
      'uploadTokenExpiresAt', now() + interval '24 hours',
      'paymentToken', v_payment_token,
      'paymentTokenExpiresAt', now() + interval '7 days'
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
      'channel','storefront',
      'deliveryFeeStatus', case when v_fulfilment_type='delivery' then 'pending_confirmation' else 'not_required' end,
      'fulfilmentPointSnapshot', v_fulfilment_snapshot
    ),
    encode(extensions.digest(v_upload_token, 'sha256'), 'hex'),
    now() + interval '24 hours',
    encode(extensions.digest(v_payment_token, 'sha256'), 'hex'),
    now() + interval '7 days'
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
    'paymentStatus', 'unpaid',
    'deliveryFeeStatus', case when v_fulfilment_type='delivery' then 'pending_confirmation' else 'not_required' end,
    'uploadToken', v_upload_token,
    'uploadTokenExpiresAt', now() + interval '24 hours',
    'paymentToken', v_payment_token,
    'paymentTokenExpiresAt', now() + interval '7 days'
  );
end
$$;

revoke all on function public.create_quick_solution_order(text,text,jsonb,text,text,text,text,uuid,jsonb,text,text) from public;
grant execute on function public.create_quick_solution_order(text,text,jsonb,text,text,text,text,uuid,jsonb,text,text) to anon, authenticated;
