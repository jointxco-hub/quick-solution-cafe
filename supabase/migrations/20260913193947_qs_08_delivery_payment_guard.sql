-- QS-08 delivery payment guard.
-- Already applied to Joint X XOS Staging as 20260913193947_qs_08_delivery_payment_guard.

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

  if v_order.fulfilment_type='delivery'
     and coalesce(v_order.source_metadata->>'deliveryFeeStatus','pending_confirmation') <> 'confirmed' then
    return jsonb_build_object('ok',false,'reason','delivery_fee_pending');
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
