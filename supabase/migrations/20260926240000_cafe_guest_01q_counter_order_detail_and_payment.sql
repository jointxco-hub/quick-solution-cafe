-- CAFE-GUEST-01Q: counter order detail + full Cash/Card payment recording.
--
--   public.get_quick_solution_counter_order(p_order_id uuid)                                  returns jsonb  (STABLE)
--   public.record_quick_solution_counter_payment(p_order_id uuid, p_method text, p_idempotency_key text)  returns jsonb
--
-- THE LEDGER. The Cafe already has one payment ledger: commerce.service_order_payments (QS-08, PayFast).
-- This slice reuses it instead of adding a parallel one:
--   provider   is the canonical "who took the money" column and gains 'cash' and 'card' beside 'payfast'.
--              Those two values ARE the counter payment methods; there is no separate method column.
--   status     'completed' for a recorded counter payment (the existing vocabulary).
--   amount     numeric(12,2) > 0, exactly the outstanding balance at the moment of payment.
--   completed_at   server time (now()).
--   recorded_by    NEW: auth.uid() of the staff member who recorded it (server-side, never from the caller).
--   idempotency_key NEW: the actor-scoped payment key.
-- Orders keep their stored payment_status (unpaid -> paid); the ledger row is the authority and is written in
-- the same transaction. There is no "UPDATE payment_status" without the ledger row.
--
-- OUTSTANDING = total_amount - sum(amount of COMPLETED ledger rows of the order), never below 0. A payment
-- settles exactly that, once. No amount argument exists, so no partial payment, overpayment or tolerance.
--
-- WHEN PAYMENT IS ALLOWED (one internal rule, commerce._qs_counter_payment_block, used by both RPCs):
--   channel 'counter' of the Cafe tenant; payment_status 'unpaid'; status not 'cancelled'/'completed' (the same
--   two states the PayFast path already refuses); not already sent to OPPS (opps_order_id or a handoff that is
--   'sending'/'sent' - the OPPS order would then need its own payment mirror, which this slice does not do);
--   total > 0 and outstanding > 0. Already 'paid' is reported as such, never paid twice.
--
-- SECURITY, in this order for both RPCs (identical to the other counter RPCs; no app-admin / OPPS-staff bypass,
-- and NOT cafe.operations.manage - any active member, admin or owner):
--   1 authenticated 42501 'Staff sign-in is required.'   2 canonical tenant 22023   3 has_tenant_capability
--   'cafe.counter.operate' 42501   4 quick_solution module 22023.
-- A storefront order, an order of another tenant and an unknown id are all the same 22023 'Counter order was
-- not found.' The caller supplies only the order id (plus method and key for payment).
--
-- PAYMENT IDEMPOTENCY. The key is stored as 'counter-payment:<auth.uid()>:<key>' in a unique index, so it is
-- scoped to the acting staff member (like the counter-create key): nobody can replay or probe another operator's
-- key. Same actor + key + order + method returns the original payment (replayed true, no second row); the same key
-- for a different order or method is a 23505 conflict. A NEW key after the order is paid never creates a payment:
-- it returns { ok:false, reason:'already_paid' } and writes nothing.
--
-- CONCURRENCY. A per-key advisory lock, then the order row FOR UPDATE, then a re-check of everything under the
-- lock; and a partial unique index allows only ONE completed cash/card payment per order. Two staff paying the
-- same order at once: one wins, the other sees 'already_paid' - never two full payments.
--
-- DEPENDENCY: public.has_tenant_capability (OPPS repo, CAFE-ACCESS-01..03) and the 01A/01M counter migrations.

do $preflight$
begin
  if to_regprocedure('public.has_tenant_capability(uuid,text)') is null then
    raise exception 'CAFE_GUEST_01Q_MIGRATION_PRECONDITION: public.has_tenant_capability (CAFE-ACCESS) must exist';
  end if;
  if to_regclass('commerce.service_order_payments') is null or to_regclass('commerce.service_order_handoffs') is null then
    raise exception 'CAFE_GUEST_01Q_MIGRATION_PRECONDITION: the QS-08 payment ledger and the QS-04 handoff table must exist';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema = 'commerce' and table_name = 'service_orders' and column_name = 'channel') then
    raise exception 'CAFE_GUEST_01Q_MIGRATION_PRECONDITION: commerce.service_orders.channel (CAFE-GUEST-01A) must exist';
  end if;
end
$preflight$;

-- ── ledger: two methods, an actor, a key, and one completed manual payment per order ──
alter table commerce.service_order_payments
  add column if not exists recorded_by uuid,
  add column if not exists idempotency_key text;

alter table commerce.service_order_payments
  drop constraint if exists service_order_payments_provider_check;
alter table commerce.service_order_payments
  add constraint service_order_payments_provider_check
  check (provider in ('payfast', 'cash', 'card'));

-- A counter payment is always complete, attributed and keyed: it cannot exist half-formed.
alter table commerce.service_order_payments
  drop constraint if exists service_order_payments_counter_shape_check;
alter table commerce.service_order_payments
  add constraint service_order_payments_counter_shape_check
  check (
    provider not in ('cash', 'card')
    or (status = 'completed' and recorded_by is not null and idempotency_key is not null and completed_at is not null)
  );

create unique index if not exists uq_qs_service_order_payments_idempotency
  on commerce.service_order_payments (tenant_id, idempotency_key)
  where idempotency_key is not null;

-- The database itself refuses a second full counter payment for one order.
create unique index if not exists uq_qs_service_order_payments_one_counter_payment
  on commerce.service_order_payments (service_order_id)
  where provider in ('cash', 'card') and status = 'completed';

comment on column commerce.service_order_payments.recorded_by is
  'CAFE-GUEST-01Q: auth.uid() of the staff member who recorded a counter (cash/card) payment. Null for gateway payments.';
comment on column commerce.service_order_payments.idempotency_key is
  'CAFE-GUEST-01Q: actor-scoped key (counter-payment:<uid>:<key>) of a counter payment. Never returned to clients.';

-- ── shared rules ─────────────────────────────────────────────────────────
create or replace function commerce._qs_order_amount_paid(p_order_id uuid)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(p.amount), 0)
  from commerce.service_order_payments p
  where p.service_order_id = p_order_id
    and p.status = 'completed'
$$;

revoke all on function commerce._qs_order_amount_paid(uuid) from public, anon, authenticated, service_role;

comment on function commerce._qs_order_amount_paid(uuid) is
  'CAFE-GUEST-01Q: the sum of COMPLETED ledger payments of a service order. Outstanding = total_amount - this, never below 0. Internal.';

-- Why a counter order cannot take a payment right now, or null when it can.
create or replace function commerce._qs_counter_payment_block(p_order commerce.service_orders)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_handoff text;
begin
  if p_order.payment_status = 'paid' then return 'already_paid'; end if;
  if p_order.payment_status <> 'unpaid' or p_order.status in ('draft', 'cancelled', 'completed') then return 'not_payable'; end if;

  select h.status into v_handoff from commerce.service_order_handoffs h where h.service_order_id = p_order.id limit 1;
  if p_order.opps_order_id is not null or v_handoff in ('sending', 'sent') then return 'sent_to_production'; end if;

  if p_order.total_amount <= 0
     or round(p_order.total_amount - commerce._qs_order_amount_paid(p_order.id), 2) <= 0 then
    return 'nothing_outstanding';
  end if;
  return null;
end
$$;

revoke all on function commerce._qs_counter_payment_block(commerce.service_orders) from public, anon, authenticated, service_role;

comment on function commerce._qs_counter_payment_block(commerce.service_orders) is
  'CAFE-GUEST-01Q: the one rule for "may this counter order take a payment": null, or already_paid / not_payable / sent_to_production / nothing_outstanding. Internal.';

-- ── order detail (read-only) ─────────────────────────────────────────────
create or replace function public.get_quick_solution_counter_order(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_order commerce.service_orders;
  v_paid numeric;
  v_outstanding numeric;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Staff sign-in is required.';
  end if;

  select t.id
  into v_tenant_id
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

  select so.*
  into v_order
  from commerce.service_orders so
  where so.id = p_order_id
    and so.tenant_id = v_tenant_id
    and so.channel = 'counter';

  if v_order.id is null then
    raise exception using errcode = '22023', message = 'Counter order was not found.';
  end if;

  v_paid := commerce._qs_order_amount_paid(v_order.id);
  v_outstanding := greatest(round(v_order.total_amount - v_paid, 2), 0);

  return jsonb_build_object(
    'orderId', v_order.id,
    'orderNumber', v_order.order_number,
    'createdAt', v_order.created_at,
    'status', v_order.status,
    'paymentStatus', v_order.payment_status,
    'customerName', v_order.customer_name,
    'customerEmail', v_order.customer_email,
    'customerPhone', v_order.customer_phone,
    'subtotal', v_order.subtotal,
    'fulfilmentFee', v_order.fulfilment_fee,
    'totalAmount', v_order.total_amount,
    'amountPaid', v_paid,
    'outstanding', v_outstanding,
    'paymentAllowed', commerce._qs_counter_payment_block(v_order) is null,
    'items', coalesce((
      select jsonb_agg(
               jsonb_build_object(
                 'productKey', i.product_key,
                 'productName', i.product_name,
                 'quantity', i.quantity,
                 'configuration', i.configuration,
                 'lineTotal', i.line_total
               )
               order by i.created_at, i.id
             )
      from commerce.service_order_items i
      where i.order_id = v_order.id
        and i.tenant_id = v_order.tenant_id
    ), '[]'::jsonb),
    'payments', coalesce((
      select jsonb_agg(
               jsonb_build_object(
                 'paymentId', p.id,
                 'method', p.provider,
                 'amount', p.amount,
                 'paidAt', p.completed_at
               )
               order by p.completed_at, p.id
             )
      from commerce.service_order_payments p
      where p.service_order_id = v_order.id
        and p.tenant_id = v_order.tenant_id
        and p.status = 'completed'
    ), '[]'::jsonb)
  );
end
$$;

revoke all on function public.get_quick_solution_counter_order(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.get_quick_solution_counter_order(uuid)
  to authenticated;

comment on function public.get_quick_solution_counter_order(uuid) is
  'CAFE-GUEST-01Q: read-only detail of ONE counter-channel order of the Cafe tenant for cafe.counter.operate: items, totals, amount paid, outstanding, whether payment is allowed, and completed payments (method, amount, time). No idempotency keys, source metadata, actor identity or pricing data.';

-- ── full payment ─────────────────────────────────────────────────────────
create or replace function public.record_quick_solution_counter_payment(
  p_order_id uuid,
  p_method text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_actor uuid;
  v_tenant_id uuid;
  v_key text;
  v_stored_key text;
  v_order commerce.service_orders;
  v_existing commerce.service_order_payments;
  v_block text;
  v_amount numeric;
  v_paid numeric;
  v_payment_id uuid;
  v_paid_at timestamptz;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception using errcode = '42501', message = 'Staff sign-in is required.';
  end if;

  select t.id
  into v_tenant_id
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

  -- input: exactly the two supported methods, no mapping, no case folding
  if p_method is null or p_method not in ('cash', 'card') then
    raise exception using errcode = '22023', message = 'Payment method is not supported.';
  end if;
  v_key := trim(coalesce(p_idempotency_key, ''));
  if length(v_key) < 8 then
    raise exception using errcode = '22023', message = 'Payment idempotency key is required.';
  end if;
  if length(v_key) > 128 then
    raise exception using errcode = '22023', message = 'Payment idempotency key is not valid.';
  end if;
  if p_order_id is null then
    raise exception using errcode = '22023', message = 'Counter order was not found.';
  end if;

  -- serialize on the key, then on the order (always in this order, so two callers cannot deadlock)
  v_stored_key := 'counter-payment:' || v_actor::text || ':' || v_key;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_tenant_id::text || '|' || v_stored_key, 0));

  select so.*
  into v_order
  from commerce.service_orders so
  where so.id = p_order_id
    and so.tenant_id = v_tenant_id
    and so.channel = 'counter'
  for update;

  -- a retry of a payment this actor already recorded returns the original, whatever the order looks like now
  select p.*
  into v_existing
  from commerce.service_order_payments p
  where p.tenant_id = v_tenant_id
    and p.idempotency_key = v_stored_key;

  if v_existing.id is not null then
    if v_existing.service_order_id is distinct from p_order_id
       or v_existing.provider is distinct from p_method
       or v_existing.recorded_by is distinct from v_actor then
      raise exception using errcode = '23505', message = 'This payment key was already used for a different payment request.';
    end if;
    return jsonb_build_object(
      'ok', true,
      'replayed', true,
      'alreadyPaid', false,
      'orderId', v_existing.service_order_id,
      'orderNumber', v_order.order_number,
      'paymentId', v_existing.id,
      'method', v_existing.provider,
      'amount', v_existing.amount,
      'paidAt', v_existing.completed_at,
      'paymentStatus', v_order.payment_status,
      'totalAmount', v_order.total_amount,
      'amountPaid', commerce._qs_order_amount_paid(v_order.id),
      'outstanding', greatest(round(v_order.total_amount - commerce._qs_order_amount_paid(v_order.id), 2), 0)
    );
  end if;

  if v_order.id is null then
    raise exception using errcode = '22023', message = 'Counter order was not found.';
  end if;

  v_block := commerce._qs_counter_payment_block(v_order);
  if v_block = 'already_paid' then
    return jsonb_build_object(
      'ok', false,
      'reason', 'already_paid',
      'orderId', v_order.id,
      'orderNumber', v_order.order_number,
      'paymentStatus', v_order.payment_status
    );
  elsif v_block = 'sent_to_production' then
    raise exception using errcode = '22023', message = 'This order has already been sent to production and cannot take a counter payment.';
  elsif v_block = 'nothing_outstanding' then
    raise exception using errcode = '22023', message = 'This order has nothing outstanding.';
  elsif v_block is not null then
    raise exception using errcode = '22023', message = 'This order cannot take a payment.';
  end if;

  -- the server decides the amount: everything still outstanding
  v_amount := round(v_order.total_amount - commerce._qs_order_amount_paid(v_order.id), 2);
  v_paid_at := clock_timestamp();

  insert into commerce.service_order_payments (
    tenant_id, service_order_id, provider, status, amount, initiated_at, completed_at, recorded_by, idempotency_key
  )
  values (
    v_tenant_id, v_order.id, p_method, 'completed', v_amount, v_paid_at, v_paid_at, v_actor, v_stored_key
  )
  returning id into v_payment_id;

  v_paid := commerce._qs_order_amount_paid(v_order.id);
  if round(v_order.total_amount - v_paid, 2) <> 0 then
    raise exception using errcode = '22023', message = 'The recorded amount does not settle the order.';
  end if;

  update commerce.service_orders
  set payment_status = 'paid',
      source_metadata = coalesce(source_metadata, '{}'::jsonb) ||
        jsonb_build_object('payment', jsonb_build_object('provider', p_method, 'status', 'paid', 'paidAt', v_paid_at)),
      updated_at = now()
  where id = v_order.id;

  return jsonb_build_object(
    'ok', true,
    'replayed', false,
    'alreadyPaid', false,
    'orderId', v_order.id,
    'orderNumber', v_order.order_number,
    'paymentId', v_payment_id,
    'method', p_method,
    'amount', v_amount,
    'paidAt', v_paid_at,
    'paymentStatus', 'paid',
    'totalAmount', v_order.total_amount,
    'amountPaid', v_paid,
    'outstanding', 0
  );
end
$$;

revoke all on function public.record_quick_solution_counter_payment(uuid, text, text)
  from public, anon, authenticated, service_role;
grant execute on function public.record_quick_solution_counter_payment(uuid, text, text)
  to authenticated;

comment on function public.record_quick_solution_counter_payment(uuid, text, text) is
  'CAFE-GUEST-01Q: records ONE full cash or card payment of the whole outstanding balance of a counter order, for cafe.counter.operate. The server sets the amount, the actor and the time, writes the ledger row and marks the order paid atomically, is idempotent per (actor, key), and can never pay an order twice. No amount argument, no card data, no EFT, no partial payment.';
