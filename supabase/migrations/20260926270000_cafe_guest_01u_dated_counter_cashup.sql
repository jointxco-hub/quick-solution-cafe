-- CAFE-GUEST-01U: the counter cash-up for a SELECTED Cafe business date, read-only.
--
--   public.get_quick_solution_counter_cashup(p_business_date date)  returns jsonb  (STABLE)
--   public.get_quick_solution_counter_cashup_today()                returns jsonb  (STABLE, same contract as 01S)
--
-- ONE IMPLEMENTATION. The 01S rules now live once, in the internal commerce._qs_counter_cashup(tenant, date); both public functions do
-- only the access gate (and, for the dated one, the date validation) and then call it. So "today" and "a chosen day" cannot drift
-- apart, and the 01S contract (response keys, meanings) is unchanged: the today function returns exactly what the dated one returns for
-- today's business date (the SQL test asserts the two results are identical).
--
-- DATE. The caller supplies only a business DATE (a calendar day of the Cafe). The server turns it into exact bounds with
-- commerce._qs_counter_business_day_of(date), which places local midnight of that date in Africa/Johannesburg and reads the day back
-- through the single 01P rule commerce._qs_counter_business_day - so there is still one interpretation of "a business day": [local
-- midnight, next local midnight). A timezone, tenant, timestamp or channel cannot be supplied. Validation, AFTER the access gate (so an
-- unauthorised caller learns nothing about dates), with stable messages:
--     null                                   22023 'Business date is required.'
--     +/-infinity, or before 2000-01-01      22023 'Business date is not valid.'
--     after today's business date            22023 'Cash-up date cannot be in the future.'   (a future day has no takings; refused, not shown as zero)
--
-- WHAT IS RECOGNISED ON THE DAY (unchanged from 01S): takings are completed cash and card ledger rows of COUNTER orders of the Cafe whose
-- payment was COMPLETED on that business date - not the order's creation date. An order made a week earlier and paid on the selected day
-- is that day's takings; an order made on the selected day and paid later is not. Other completed providers are reported apart
-- (otherMethods) and are not in the total. No refunds exist yet, so nothing is netted.
--
-- UNPAID, HISTORICALLY: unpaid.* is "counter orders CREATED on the selected date that are STILL unpaid NOW" (not cancelled/draft), with what is
-- outstanding now. It is a present-day view of the orders that originated that day. It is NOT a snapshot of the day's end: the system does not
-- store historical payment state, so an order made on the selected day, unpaid when the day closed but paid the day after, is no longer
-- listed. Orders 'createdToday' likewise means created on the selected date (the key keeps its 01S name so today's contract is unchanged).
--
-- DEPENDENCY: public.has_tenant_capability (OPPS repo, CAFE-ACCESS-01..03), the 01P business-day rule, the 01Q amount-paid rule, the 01S shape.

do $preflight$
begin
  if to_regprocedure('public.has_tenant_capability(uuid,text)') is null then
    raise exception 'CAFE_GUEST_01U_MIGRATION_PRECONDITION: public.has_tenant_capability (CAFE-ACCESS) must exist';
  end if;
  if to_regprocedure('commerce._qs_counter_business_day(timestamptz)') is null
     or to_regprocedure('commerce._qs_order_amount_paid(uuid)') is null
     or to_regprocedure('public.get_quick_solution_counter_cashup_today()') is null then
    raise exception 'CAFE_GUEST_01U_MIGRATION_PRECONDITION: the 01P business-day rule, the 01Q amount-paid rule and the 01S cash-up must exist';
  end if;
end
$preflight$;

-- ── a business date -> its exact bounds, through the one existing rule ────────
create or replace function commerce._qs_counter_business_day_of(p_date date)
returns table (business_date date, day_start timestamptz, day_end timestamptz)
language sql
stable
set search_path = ''
as $$
  select d.business_date, d.day_start, d.day_end
  from commerce._qs_counter_business_day((p_date::timestamp at time zone 'Africa/Johannesburg')) d
$$;

revoke all on function commerce._qs_counter_business_day_of(date)
  from public, anon, authenticated, service_role;

comment on function commerce._qs_counter_business_day_of(date) is
  'CAFE-GUEST-01U: the Cafe business day (Africa/Johannesburg) of a calendar date as [day_start, day_end): local midnight of the date, read back through commerce._qs_counter_business_day. Internal.';

-- ── the cash-up itself: the 01S rules, once, for any business date ───────────
create or replace function commerce._qs_counter_cashup(p_tenant_id uuid, p_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_day record;
  v_pay record;
  v_orders record;
  v_unpaid record;
begin
  select * into v_day from commerce._qs_counter_business_day_of(p_date);

  -- money received on the day: one query yields the rows AND every figure made from them
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
    where p.tenant_id = p_tenant_id
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

  -- orders that ORIGINATED on the day
  select count(*) as created_today
  into v_orders
  from commerce.service_orders so
  where so.tenant_id = p_tenant_id
    and so.channel = 'counter'
    and so.created_at >= v_day.day_start
    and so.created_at < v_day.day_end;

  -- ... of those, the ones still unpaid NOW: what is outstanding, never counted as received
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
    where so.tenant_id = p_tenant_id
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

revoke all on function commerce._qs_counter_cashup(uuid, date)
  from public, anon, authenticated, service_role;

comment on function commerce._qs_counter_cashup(uuid, date) is
  'CAFE-GUEST-01U: the one implementation of the counter cash-up for a Cafe business date: Cash and Card takings by payment COMPLETION time, the payments that make them up, other-method payments apart, orders created on the date, and those still unpaid now. Internal.';

-- ── today: same access gate, same contract, now a thin caller ────────────────
create or replace function public.get_quick_solution_counter_cashup_today()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
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

  return commerce._qs_counter_cashup(v_tenant_id, (select d.business_date from commerce._qs_counter_business_day(now()) d));
end
$$;

revoke all on function public.get_quick_solution_counter_cashup_today()
  from public, anon, authenticated, service_role;
grant execute on function public.get_quick_solution_counter_cashup_today()
  to authenticated;

-- ── a selected business date ─────────────────────────────────────────────
create or replace function public.get_quick_solution_counter_cashup(p_business_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_today date;
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

  -- the date, strictly
  if p_business_date is null then
    raise exception using errcode = '22023', message = 'Business date is required.';
  end if;
  if p_business_date in (date 'infinity', date '-infinity') or p_business_date < date '2000-01-01' then
    raise exception using errcode = '22023', message = 'Business date is not valid.';
  end if;
  select d.business_date into v_today from commerce._qs_counter_business_day(now()) d;
  if p_business_date > v_today then
    raise exception using errcode = '22023', message = 'Cash-up date cannot be in the future.';
  end if;

  return commerce._qs_counter_cashup(v_tenant_id, p_business_date);
end
$$;

revoke all on function public.get_quick_solution_counter_cashup(date)
  from public, anon, authenticated, service_role;
grant execute on function public.get_quick_solution_counter_cashup(date)
  to authenticated;

comment on function public.get_quick_solution_counter_cashup(date) is
  'CAFE-GUEST-01U: read-only counter cash-up for a chosen Cafe business date (Africa/Johannesburg; never a future date): Cash and Card takings by payment COMPLETION date, the payments behind them, other-method payments apart, and the orders created that day that are still unpaid NOW (not an end-of-day snapshot). Same result shape as get_quick_solution_counter_cashup_today, which returns the same figures for today.';
