-- CAFE-GUEST-01S: today's counter cash-up summary, read-only.
--
--   public.get_quick_solution_counter_cashup_today()  returns jsonb  (STABLE)
--
-- An operational reconciliation view: what the counter TOOK today by Cash and by Card, the payments that make that up,
-- and the counter orders still unpaid. It writes nothing and takes NO argument (no tenant, channel, date or actor).
--
-- SECURITY (identical to the other counter RPCs; no app-admin / OPPS-staff bypass, not cafe.operations.manage):
--   1 authenticated 42501 'Staff sign-in is required.'   2 canonical tenant 22023 'Quick Solution tenant was not found.'
--   3 has_tenant_capability 'cafe.counter.operate' 42501   4 quick_solution module 22023 'Quick Solution counter is not active.'
--
-- WHICH DAY MONEY BELONGS TO: the day the payment was COMPLETED, not the day the order was created. OPPS finance also
-- recognises money by completed payments and their payment date, and a payment is what a till holds. So an order created
-- yesterday and paid in cash today is part of TODAY's takings; an order created today and paid tomorrow is not (yet). The day
-- is the Cafe business day of commerce._qs_counter_business_day (Africa/Johannesburg, [local midnight, next local midnight)),
-- the same single rule Today's Orders uses - a payment at exactly local midnight belongs to the new day.
--
-- WHAT COUNTS AS TAKINGS: ledger rows (commerce.service_order_payments) with status 'completed' and provider 'cash' or 'card',
-- of COUNTER-channel orders of the Cafe tenant, completed today. Unpaid orders are never money received. Pending, failed and
-- cancelled rows never count. Storefront orders and other tenants are excluded. There are no refunds yet, so nothing is netted.
-- A completed payment of ANY OTHER provider (a gateway payment on a counter order should not exist, but the ledger allows it)
-- is not mixed into Cash or Card: it is reported apart as otherMethods and is not in the total.
--
-- ONE SOURCE FOR THE NUMBERS: the payment list and every takings figure come out of the same single query (one CTE), so a
-- total cannot disagree with the rows it is made of.
--
-- UNPAID: counter orders created today that are still 'unpaid' (not cancelled), with what is outstanding on each. Shown as
-- context, never subtracted from takings. Orders from EARLIER days that are still unpaid are not listed here.
--
-- RESPONSE: { businessDate, timezone,
--   orders: { createdToday, paidToday, unpaidToday },
--   takings: { cash: {count, amount}, card: {count, amount}, total: {count, amount} },
--   otherMethods: {count, amount},
--   unpaid: { count, amount, orders: [ ... same safe fields as Today's Orders + outstanding ] },
--   payments: [ { paymentId, orderId, orderNumber, customerName, method, amount, paidAt, orderTotal, orderCreatedAt } ] } newest first.
-- Deliberately NOT returned: payment or order idempotency keys, the recording actor or any auth identity, source metadata,
-- pricing snapshots/definitions, supplier or margin data, tenant ids.
--
-- DEPENDENCY: public.has_tenant_capability (OPPS repo, CAFE-ACCESS-01..03), the 01P business-day rule and the 01Q ledger columns.

do $preflight$
begin
  if to_regprocedure('public.has_tenant_capability(uuid,text)') is null then
    raise exception 'CAFE_GUEST_01S_MIGRATION_PRECONDITION: public.has_tenant_capability (CAFE-ACCESS) must exist';
  end if;
  if to_regprocedure('commerce._qs_counter_business_day(timestamptz)') is null
     or to_regprocedure('commerce._qs_order_amount_paid(uuid)') is null then
    raise exception 'CAFE_GUEST_01S_MIGRATION_PRECONDITION: the 01P business-day rule and the 01Q amount-paid rule must exist';
  end if;
end
$preflight$;

create or replace function public.get_quick_solution_counter_cashup_today()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_day record;
  v_pay record;
  v_orders record;
  v_unpaid record;
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

  select * into v_day from commerce._qs_counter_business_day(now());

  -- money received today: one query yields the rows AND every figure made from them
  with pay as (
    select
      p.id,
      p.service_order_id,
      p.provider,
      p.amount,
      p.completed_at,
      so.order_number,
      so.customer_name,
      so.total_amount,
      so.created_at as order_created_at
    from commerce.service_order_payments p
    join commerce.service_orders so
      on so.id = p.service_order_id
     and so.tenant_id = p.tenant_id
    where p.tenant_id = v_tenant_id
      and so.channel = 'counter'
      and p.status = 'completed'
      and p.completed_at >= v_day.day_start
      and p.completed_at < v_day.day_end
  )
  select
    coalesce(jsonb_agg(
      jsonb_build_object(
        'paymentId', pay.id,
        'orderId', pay.service_order_id,
        'orderNumber', pay.order_number,
        'customerName', pay.customer_name,
        'method', pay.provider,
        'amount', pay.amount,
        'paidAt', pay.completed_at,
        'orderTotal', pay.total_amount,
        'orderCreatedAt', pay.order_created_at
      )
      order by pay.completed_at desc, pay.id desc
    ) filter (where pay.provider in ('cash', 'card')), '[]'::jsonb) as rows,
    count(*) filter (where pay.provider = 'cash') as cash_count,
    coalesce(sum(pay.amount) filter (where pay.provider = 'cash'), 0) as cash_amount,
    count(*) filter (where pay.provider = 'card') as card_count,
    coalesce(sum(pay.amount) filter (where pay.provider = 'card'), 0) as card_amount,
    count(*) filter (where pay.provider not in ('cash', 'card')) as other_count,
    coalesce(sum(pay.amount) filter (where pay.provider not in ('cash', 'card')), 0) as other_amount,
    count(distinct pay.service_order_id) filter (where pay.provider in ('cash', 'card')) as paid_orders
  into v_pay
  from pay;

  select count(*) as created_today
  into v_orders
  from commerce.service_orders so
  where so.tenant_id = v_tenant_id
    and so.channel = 'counter'
    and so.created_at >= v_day.day_start
    and so.created_at < v_day.day_end;

  -- still unpaid, created today: what is outstanding, never counted as received
  select
    count(*) as n,
    coalesce(sum(u.outstanding), 0) as amount,
    coalesce(jsonb_agg(u.summary order by u.created_at desc, u.id desc), '[]'::jsonb) as orders
  into v_unpaid
  from (
    select
      so.id,
      so.created_at,
      greatest(round(so.total_amount - commerce._qs_order_amount_paid(so.id), 2), 0) as outstanding,
      jsonb_build_object(
        'orderId', so.id,
        'orderNumber', so.order_number,
        'createdAt', so.created_at,
        'status', so.status,
        'paymentStatus', so.payment_status,
        'customerName', so.customer_name,
        'customerEmail', so.customer_email,
        'customerPhone', so.customer_phone,
        'totalAmount', so.total_amount,
        'outstanding', greatest(round(so.total_amount - commerce._qs_order_amount_paid(so.id), 2), 0),
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
          where i.order_id = so.id
            and i.tenant_id = so.tenant_id
        ), '[]'::jsonb)
      ) as summary
    from commerce.service_orders so
    where so.tenant_id = v_tenant_id
      and so.channel = 'counter'
      and so.created_at >= v_day.day_start
      and so.created_at < v_day.day_end
      and so.payment_status = 'unpaid'
      and so.status <> 'cancelled'
  ) u;

  return jsonb_build_object(
    'businessDate', v_day.business_date,
    'timezone', 'Africa/Johannesburg',
    'orders', jsonb_build_object(
      'createdToday', v_orders.created_today,
      'paidToday', v_pay.paid_orders,
      'unpaidToday', v_unpaid.n
    ),
    'takings', jsonb_build_object(
      'cash', jsonb_build_object('count', v_pay.cash_count, 'amount', v_pay.cash_amount),
      'card', jsonb_build_object('count', v_pay.card_count, 'amount', v_pay.card_amount),
      'total', jsonb_build_object('count', v_pay.cash_count + v_pay.card_count, 'amount', v_pay.cash_amount + v_pay.card_amount)
    ),
    'otherMethods', jsonb_build_object('count', v_pay.other_count, 'amount', v_pay.other_amount),
    'unpaid', jsonb_build_object('count', v_unpaid.n, 'amount', v_unpaid.amount, 'orders', v_unpaid.orders),
    'payments', v_pay.rows
  );
end
$$;

revoke all on function public.get_quick_solution_counter_cashup_today()
  from public, anon, authenticated, service_role;
grant execute on function public.get_quick_solution_counter_cashup_today()
  to authenticated;

comment on function public.get_quick_solution_counter_cashup_today() is
  'CAFE-GUEST-01S: read-only counter cash-up for the Cafe business day (Africa/Johannesburg): Cash and Card takings by payment COMPLETION time (counter orders of the Cafe only), the payments that make them up, other-method payments apart, and today''s still-unpaid counter orders. No arguments; no keys, actor, metadata, pricing or tenant ids.';
