-- Customer-only ownership. No staff membership or financial receipt is created.
create table commerce.service_order_customers (
  order_id uuid primary key references commerce.service_orders(id) on delete cascade,
  tenant_id uuid not null references public.tenants(id),
  user_id uuid not null references auth.users(id) on delete cascade,
  linked_at timestamptz not null default now()
);
create index service_order_customers_user_tenant on commerce.service_order_customers(user_id,tenant_id,order_id);
alter table commerce.service_order_customers enable row level security;
revoke all on commerce.service_order_customers from public,anon,authenticated;

create table commerce.customer_payment_sessions (
  token_hash text primary key,
  order_id uuid not null references commerce.service_orders(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  expires_at timestamptz not null default now()+interval '15 minutes'
);
create index customer_payment_sessions_order on commerce.customer_payment_sessions(order_id);
alter table commerce.customer_payment_sessions enable row level security;
revoke all on commerce.customer_payment_sessions from public,anon,authenticated;

-- Autoconfirmed password signup is not proof of mailbox ownership. Require a
-- server-signed OTP/magiclink authentication method and a current Auth session.
create function commerce.qs_customer_identity() returns text
language plpgsql security definer set search_path='' as $$
declare email text;
begin
  if auth.uid() is null or not exists(
    select 1 from jsonb_array_elements(coalesce(auth.jwt()->'amr','[]'::jsonb)) a
    where a->>'method' in ('otp','magiclink')
  ) or not exists(select 1 from auth.sessions s where s.id=(auth.jwt()->>'session_id')::uuid and s.user_id=auth.uid()) then
    raise exception using errcode='42501',message='Use the email sign-in link to continue.';
  end if;
  select lower(trim(u.email)) into email from auth.users u
    where u.id=auth.uid() and u.email_confirmed_at is not null
    and u.deleted_at is null and coalesce(u.banned_until,'epoch')<now()
    and lower(trim(u.email))=lower(trim(auth.jwt()->>'email'));
  if email is null then raise exception using errcode='42501',message='Use the email sign-in link to continue.'; end if;
  return email;
end $$;
revoke all on function commerce.qs_customer_identity() from public,anon,authenticated;

create function public.qs_customer_link_order(p_order_id uuid,p_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare email text:=commerce.qs_customer_identity(); o commerce.service_orders; owner_id uuid;
begin
  select so.* into o from commerce.service_orders so join public.tenants t on t.id=so.tenant_id
    where so.id=p_order_id and t.slug='quick-solution' and t.status='active' and so.channel='storefront' for update of so;
  if o.id is null or lower(trim(o.customer_email)) is distinct from email then
    raise exception using errcode='42501',message='This order cannot be saved to this account. Use its original secure link or contact the Café.';
  end if;
  select c.user_id into owner_id from commerce.service_order_customers c where c.order_id=o.id;
  if owner_id=auth.uid() then return jsonb_build_object('ok',true); end if;
  if owner_id is not null or not coalesce((
    (o.payment_token_expires_at>now() and o.payment_token_hash=encode(extensions.digest(coalesce(p_token,''),'sha256'),'hex'))
    or exists(select 1 from commerce.service_order_tracking_tokens tok where tok.service_order_id=o.id
      and tok.tenant_id=o.tenant_id and tok.revoked_at is null and tok.expires_at>now()
      and tok.token_hash=encode(extensions.digest(coalesce(p_token,''),'sha256'),'hex'))
  ),false) then raise exception using errcode='42501',message='This order cannot be saved to this account. Use its original secure link or contact the Café.'; end if;
  insert into commerce.service_order_customers(order_id,tenant_id,user_id) values(o.id,o.tenant_id,auth.uid());
  return jsonb_build_object('ok',true);
end $$;
revoke all on function public.qs_customer_link_order(uuid,text) from public,anon;
grant execute on function public.qs_customer_link_order(uuid,text) to authenticated;

create function public.qs_customer_link_tracking(p_order_number text,p_tracking_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare email text:=commerce.qs_customer_identity(); oid uuid;
begin
  select so.id into oid from commerce.service_orders so join public.tenants t on t.id=so.tenant_id
    where upper(so.order_number)=upper(trim(p_order_number)) and lower(trim(so.customer_email))=email
      and t.slug='quick-solution' and t.status='active' and so.channel='storefront';
  return public.qs_customer_link_order(oid,p_tracking_token);
end $$;
revoke all on function public.qs_customer_link_tracking(text,text) from public,anon;
grant execute on function public.qs_customer_link_tracking(text,text) to authenticated;

-- New signed-in checkouts are linked inside the original transaction. Staff and
-- guest requests do not carry the separate customer token and remain unchanged.
create function commerce.qs_link_new_customer_order() returns trigger
language plpgsql security definer set search_path='' as $$
declare email text;
begin
  if auth.uid() is not null and auth.role()='authenticated' and new.channel='storefront' then
    email:=commerce.qs_customer_identity();
    if lower(trim(new.customer_email)) is distinct from email then
      raise exception using errcode='22023',message='Use your signed-in email for this order, or sign out to order as a guest.';
    end if;
    insert into commerce.service_order_customers(order_id,tenant_id,user_id)
      select new.id,new.tenant_id,auth.uid() from public.tenants t where t.id=new.tenant_id and t.slug='quick-solution';
  end if;
  return new;
end $$;
revoke all on function commerce.qs_link_new_customer_order() from public,anon,authenticated;
create trigger qs_link_new_customer_order after insert on commerce.service_orders for each row execute function commerce.qs_link_new_customer_order();

-- Existing checkout replay rotates guest secrets. Once an order is owned, only
-- its customer or an authorized backend may rotate them through that path.
create function commerce.qs_protect_customer_secrets() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if auth.role()='authenticated' and exists(select 1 from commerce.service_order_customers c where c.order_id=old.id)
    and (new.payment_token_hash is distinct from old.payment_token_hash or new.upload_token_hash is distinct from old.upload_token_hash) then
    perform commerce.qs_customer_identity();
  end if;
  if (new.payment_token_hash is distinct from old.payment_token_hash or new.upload_token_hash is distinct from old.upload_token_hash)
    and coalesce(auth.role(),'') not in ('service_role')
    and exists(select 1 from commerce.service_order_customers c where c.order_id=old.id and c.user_id is distinct from auth.uid()) then
    raise exception using errcode='42501',message='Sign in to the account that owns this order.';
  end if;
  return new;
end $$;
revoke all on function commerce.qs_protect_customer_secrets() from public,anon,authenticated;
create trigger qs_protect_customer_secrets before update on commerce.service_orders for each row execute function commerce.qs_protect_customer_secrets();

CREATE OR REPLACE FUNCTION commerce.qs_customer_payment_snapshot(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  o commerce.service_orders;
  cafe_paid numeric := 0;
  opps_paid numeric := 0;
  invoice_paid numeric := 0;
  invoice_count integer := 0;
  problems jsonb := '[]'::jsonb;
  receipts jsonb := '[]'::jsonb;
begin
  select so.* into o from commerce.service_orders so
    join public.tenants t on t.id=so.tenant_id
    where so.id=p_order_id and t.slug='quick-solution' and t.status='active';
  if o.id is null then
    raise exception using errcode='42501', message='Order is unavailable.';
  end if;

  select coalesce(sum(amount),0) into cafe_paid
    from commerce.service_order_payments where service_order_id=o.id
    and tenant_id=o.tenant_id and status='completed';
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'method',provider,
    'amount',amount,'receivedAt',completed_at) order by completed_at,id),'[]'::jsonb)
    into receipts from commerce.service_order_payments where service_order_id=o.id
    and tenant_id=o.tenant_id and status='completed';

  if o.opps_order_id is not null then
    if not exists(select 1 from public.orders where id=o.opps_order_id
      and tenant_id=o.tenant_id and source='quick_solution') then
      problems:=problems || '"invalid_order_link"'::jsonb;
    else
      if exists(select 1 from public.orders where id=o.opps_order_id
        and total_amount is distinct from o.total_amount) then
        problems:=problems || '"order_total_mismatch"'::jsonb;
      end if;
      select coalesce(sum(amount),0) into opps_paid from public.transactions
        where order_id=o.opps_order_id and tenant_id=o.tenant_id
        and type='income' and payment_status='completed';
      if cafe_paid <> opps_paid then
        problems:=problems || '"payment_balance_mismatch"'::jsonb;
      end if;
      select count(*) into invoice_count from public.opps_invoices
        where source_order_id=o.opps_order_id and tenant_id=o.tenant_id and status<>'void';
      select coalesce(sum(ip.amount),0) into invoice_paid from public.invoice_payments ip
        join public.opps_invoices i on i.id=ip.invoice_id and i.tenant_id=ip.tenant_id
        where i.source_order_id=o.opps_order_id and i.tenant_id=o.tenant_id;
      problems:=problems||commerce.qs_invoice_payment_issues(o.id);
    end if;
  end if;
  if coalesce((o.source_metadata->'paymentProjectionReview'->>'required')::boolean,false) then
    problems:=problems || '"gateway_projection_review_required"'::jsonb;
  end if;
  if cafe_paid>coalesce(o.total_amount,0) then
    problems:=problems || '"overpayment_review_required"'::jsonb;
  end if;
  if o.payment_status in ('refunded','failed','cancelled') then
    problems:=problems || '"payment_status_review_required"'::jsonb;
  end if;
  if o.payment_status='paid' and cafe_paid<coalesce(o.total_amount,0) then
    problems:=problems || '"paid_status_without_receipts"'::jsonb;
  end if;
  return jsonb_build_object('orderId',o.id,'orderNumber',o.order_number,
    'total',o.total_amount,'cafePaid',cafe_paid,
    'oppsPaid',case when o.opps_order_id is not null then opps_paid else null end,
    'invoicePaid',invoice_paid,'receipts',receipts,'issues',problems,
    'reviewRequired',jsonb_array_length(problems)>0,
    'balanceDue',case when jsonb_array_length(problems)=0
      then greatest(coalesce(o.total_amount,0)-cafe_paid,0) else null end,
    'closed',o.status in ('completed','cancelled'));
end $function$
;
revoke all on function commerce.qs_customer_payment_snapshot(uuid) from public,anon,authenticated;

create function commerce.qs_customer_owned_order(p_order_id uuid) returns commerce.service_orders
language plpgsql security definer set search_path='' as $$
declare o commerce.service_orders; email text:=commerce.qs_customer_identity();
begin
  select so.* into o from commerce.service_orders so
    join commerce.service_order_customers c on c.order_id=so.id and c.tenant_id=so.tenant_id
    join public.tenants t on t.id=so.tenant_id
    where so.id=p_order_id and c.user_id=auth.uid() and t.slug='quick-solution' and t.status='active';
  if o.id is null then raise exception using errcode='42501',message='Order is unavailable.'; end if;
  return o;
end $$;
revoke all on function commerce.qs_customer_owned_order(uuid) from public,anon,authenticated;

create function public.qs_customer_orders(p_offset integer default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
declare email text:=commerce.qs_customer_identity(); orders jsonb;
begin
  if p_offset is null or p_offset<0 or p_offset>10000 then raise exception 'Invalid page.'; end if;
  select coalesce(jsonb_agg(x.item order by x.submitted_at desc,x.id desc),'[]'::jsonb) into orders from (
    select so.id,so.submitted_at,jsonb_build_object('id',so.id,'orderNumber',so.order_number,
      'submittedAt',so.submitted_at,'status',so.status,'paymentStatus',so.payment_status,
      'totalAmount',so.total_amount,'itemName',(select soi.product_name from commerce.service_order_items soi
        where soi.order_id=so.id and soi.tenant_id=so.tenant_id order by soi.created_at,soi.id limit 1)) item
    from commerce.service_orders so join commerce.service_order_customers c on c.order_id=so.id and c.tenant_id=so.tenant_id
    join public.tenants t on t.id=so.tenant_id
    where c.user_id=auth.uid() and t.slug='quick-solution' and t.status='active'
    order by so.submitted_at desc,so.id desc limit 20 offset p_offset
  ) x;
  return jsonb_build_object('orders',orders,'email',email,'hasMore',jsonb_array_length(orders)=20);
end $$;

create function public.qs_customer_order(p_order_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare o commerce.service_orders:=commerce.qs_customer_owned_order(p_order_id); s jsonb; eligible boolean; minimum numeric;
begin
  s:=commerce.qs_customer_payment_snapshot(o.id);
  select coalesce((t.settings->'qsPayment'->>'payfastMinimumAmount')::numeric,50) into minimum from public.tenants t where t.id=o.tenant_id;
  select count(*)>0 and bool_and(coalesce((pc.customer_definition->'paymentEligibility'->>'allowPayfast')::boolean,true))
    and count(*)=(select count(*) from commerce.service_order_items where order_id=o.id)
    into eligible from commerce.service_order_items i join commerce.service_product_configs pc on pc.product_id=i.product_id and pc.tenant_id=i.tenant_id where i.order_id=o.id;
  eligible:=coalesce(eligible,false) and not (s->>'reviewRequired')::boolean and not (s->>'closed')::boolean
    and (s->>'balanceDue')::numeric>0 and (s->>'cafePaid')::numeric=0 and o.payment_status in ('unpaid','pending') and o.status<>'draft'
    and o.total_amount>=minimum and not coalesce((o.source_metadata->>'quoteRequired')::boolean,false)
    and (o.fulfilment_type<>'delivery' or o.source_metadata->>'deliveryFeeStatus'='confirmed');
  return jsonb_build_object('tracking',public.get_quick_solution_tracking(o.order_number,null,o.customer_email),
    'payment',jsonb_build_object('total',s->'total','received',s->'cafePaid','balanceDue',s->'balanceDue',
      'reviewRequired',s->'reviewRequired','receipts',s->'receipts','canPay',coalesce(eligible,false)));
end $$;

create function public.qs_customer_payment_session(p_order_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare o commerce.service_orders:=commerce.qs_customer_owned_order(p_order_id); state jsonb; token text;
begin
  perform 1 from commerce.service_orders where id=o.id for update;
  state:=public.qs_customer_order(o.id);
  if not coalesce((state->'payment'->>'canPay')::boolean,false) then
    raise exception using errcode='22023',message='This order cannot accept online payment now. Refresh the order or contact the Café.';
  end if;
  delete from commerce.customer_payment_sessions where order_id=o.id and expires_at<=now();
  if (select count(*) from commerce.customer_payment_sessions where order_id=o.id and user_id=auth.uid())>=20 then
    raise exception 'Please wait before trying payment again.';
  end if;
  token:=encode(extensions.gen_random_bytes(32),'hex');
  insert into commerce.customer_payment_sessions(token_hash,order_id,user_id) values(encode(extensions.digest(token,'sha256'),'hex'),o.id,auth.uid());
  return jsonb_build_object('orderId',o.id,'orderNumber',o.order_number,'paymentToken',token,'amount',state->'payment'->'balanceDue');
end $$;

-- Independent short-lived account payment secrets preserve existing guest links.
create function commerce.qs_valid_customer_payment_token(p_order_id uuid,p_token text) returns boolean
language sql security definer set search_path='' as $$
  select exists(select 1 from commerce.customer_payment_sessions s
    join commerce.service_order_customers c on c.order_id=s.order_id and c.user_id=s.user_id
    where s.order_id=p_order_id and s.expires_at>now()
      and s.token_hash=encode(extensions.digest(coalesce(p_token,''),'sha256'),'hex'));
$$;
revoke all on function commerce.qs_valid_customer_payment_token(uuid,text) from public,anon,authenticated;

revoke all on function public.qs_customer_orders(integer),public.qs_customer_order(uuid),public.qs_customer_payment_session(uuid) from public,anon;
grant execute on function public.qs_customer_orders(integer),public.qs_customer_order(uuid),public.qs_customer_payment_session(uuid) to authenticated;

CREATE OR REPLACE FUNCTION commerce.qs_begin_payfast_payment(p_order_id uuid, p_payment_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_order commerce.service_orders;
  v_payment_id uuid;
  v_minimum numeric;
  v_all_allow_payfast boolean;
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

  if ((v_order.payment_token_hash is null
     or v_order.payment_token_expires_at is null
     or v_order.payment_token_expires_at <= now()
     or encode(extensions.digest(coalesce(p_payment_token,''), 'sha256'),'hex') <> v_order.payment_token_hash) and not commerce.qs_valid_customer_payment_token(v_order.id,p_payment_token)) then
    return jsonb_build_object('ok',false,'reason','not_available');
  end if;

  if commerce.qs_valid_customer_payment_token(v_order.id,p_payment_token) and
    (v_order.status='draft' or v_order.payment_status not in ('unpaid','pending','paid')
     or coalesce((v_order.source_metadata->>'quoteRequired')::boolean,false)
     or (commerce.qs_customer_payment_snapshot(v_order.id)->>'reviewRequired')::boolean
     or ((commerce.qs_customer_payment_snapshot(v_order.id)->>'cafePaid')::numeric>0 and v_order.payment_status<>'paid')) then
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

  select coalesce((t.settings->'qsPayment'->>'payfastMinimumAmount')::numeric, 50)
  into v_minimum
  from public.tenants t
  where t.id = v_order.tenant_id;

  if v_order.total_amount < v_minimum then
    return jsonb_build_object('ok',false,'reason','below_minimum','minimumAmount',v_minimum,'amount',v_order.total_amount);
  end if;

  select coalesce(bool_and(coalesce((spc.customer_definition->'paymentEligibility'->>'allowPayfast')::boolean, true)), false)
         and count(*) = (select count(*) from commerce.service_order_items where order_id = v_order.id)
  into v_all_allow_payfast
  from commerce.service_order_items soi
  join commerce.service_product_configs spc
    on spc.product_id = soi.product_id
   and spc.tenant_id = soi.tenant_id
  where soi.order_id = v_order.id;

  if not coalesce(v_all_allow_payfast, false) then
    return jsonb_build_object('ok',false,'reason','payfast_not_allowed');
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
$function$;

CREATE OR REPLACE FUNCTION commerce.qs_get_payment_status(p_order_id uuid, p_payment_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
     or ((v_order.payment_token_hash is null
     or v_order.payment_token_expires_at is null
     or v_order.payment_token_expires_at <= now()
     or encode(extensions.digest(coalesce(p_payment_token,''), 'sha256'),'hex') <> v_order.payment_token_hash) and not commerce.qs_valid_customer_payment_token(v_order.id,p_payment_token)) then
    return jsonb_build_object('ok',false,'reason','not_available');
  end if;

  select p.completed_at into v_completed_at
  from commerce.service_order_payments p
  where p.service_order_id=v_order.id
    and p.status='completed'
  order by p.completed_at desc nulls last, p.created_at desc
  limit 1;

  return jsonb_build_object(
    'ok',true,
    'orderId',v_order.id,
    'orderNumber',v_order.order_number,
    'amount',v_order.total_amount,
    'paymentStatus',v_order.payment_status,
    'paid',v_order.payment_status='paid',
    'paidAt',v_completed_at
  );
end
$function$;
