-- CAFE-GUEST-01T: every counter order that still owes money, whichever day it was created. Read-only.
--
--   public.list_quick_solution_unpaid_counter_orders()  returns jsonb  (STABLE)
--
-- Today's Orders and today's cash-up only look at TODAY's orders, so an unpaid order from yesterday or earlier could not be
-- found. This lists them all so they can be followed up, opened (01Q order detail) and paid (01Q payment). It writes nothing and
-- takes NO argument: the caller cannot name a tenant, channel, creator or date.
--
-- SECURITY (identical to the other counter RPCs; no app-admin / OPPS-staff bypass, not cafe.operations.manage):
--   1 authenticated 42501   2 canonical tenant 22023   3 has_tenant_capability 'cafe.counter.operate' 42501   4 quick_solution module 22023.
--
-- WHAT "STILL OWES MONEY" MEANS (one rule, consistent with the 01Q order detail's outstanding):
--   * commerce.service_orders of the Cafe tenant with channel = 'counter';
--   * status is not 'draft' or 'cancelled' (an order that is cancelled or never placed owes nothing). A 'completed' or already
--     sent-to-production order that has not been paid DOES still owe money, so it stays listed - the order detail then says whether a
--     counter payment can still be recorded;
--   * payment_status is not settled: 'unpaid', 'pending' or 'failed' (never 'paid', 'refunded' or 'cancelled');
--   * outstanding > 0, where outstanding = total_amount minus the COMPLETED ledger payments (commerce._qs_order_amount_paid), never
--     below 0. The stored status string alone is NOT trusted: an order still marked unpaid whose ledger already covers it is not listed.
--   A completed partial or gateway payment that leaves a remainder keeps the order listed, showing amountPaid and only the remainder as
--   outstanding. No partial-payment feature exists; this just reports what the ledger says.
--
-- AGE is a Cafe BUSINESS-day difference, not a count of 24-hour periods: the creation instant is put on its Africa/Johannesburg
-- business date by the single rule commerce._qs_counter_business_day (01P) and compared with today's business date. An order made one
-- microsecond before local midnight is 1 day old a moment later; one made at local midnight is 0.
--
-- ORDER: oldest first (created_at, then id) so the oldest debt is the first thing seen.
--
-- RESPONSE: { businessDate, timezone, count, outstandingTotal, orders: [ { orderId, orderNumber, createdAt, orderDate, ageDays, status,
-- paymentStatus, customerName, customerEmail, customerPhone, totalAmount, amountPaid, outstanding, items: [ { productKey, productName,
-- quantity, configuration, lineTotal } ] } ] }. count, outstandingTotal and the orders come out of ONE query, so they cannot disagree.
-- Deliberately NOT returned: idempotency keys, source metadata, creator or any auth identity, pricing snapshots or definitions,
-- supplier or margin data, tenant ids. No pagination yet: the list is as long as the unpaid orders are.
--
-- DEPENDENCY: public.has_tenant_capability (OPPS repo, CAFE-ACCESS-01..03), the 01P business-day rule and the 01Q amount-paid rule.

do $preflight$
begin
  if to_regprocedure('public.has_tenant_capability(uuid,text)') is null then
    raise exception 'CAFE_GUEST_01T_MIGRATION_PRECONDITION: public.has_tenant_capability (CAFE-ACCESS) must exist';
  end if;
  if to_regprocedure('commerce._qs_counter_business_day(timestamptz)') is null
     or to_regprocedure('commerce._qs_order_amount_paid(uuid)') is null then
    raise exception 'CAFE_GUEST_01T_MIGRATION_PRECONDITION: the 01P business-day rule and the 01Q amount-paid rule must exist';
  end if;
end
$preflight$;

create or replace function public.list_quick_solution_unpaid_counter_orders()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_today date;
  v_result record;
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

  select d.business_date into v_today from commerce._qs_counter_business_day(now()) d;

  with owing as (
    select
      so.id,
      so.order_number,
      so.created_at,
      so.status,
      so.payment_status,
      so.customer_name,
      so.customer_email,
      so.customer_phone,
      so.total_amount,
      paid.amount as amount_paid,
      greatest(round(so.total_amount - paid.amount, 2), 0) as outstanding,
      od.business_date as order_date
    from commerce.service_orders so
    cross join lateral (select commerce._qs_order_amount_paid(so.id) as amount) paid
    cross join lateral commerce._qs_counter_business_day(so.created_at) od
    where so.tenant_id = v_tenant_id
      and so.channel = 'counter'
      and so.status not in ('draft', 'cancelled')
      and so.payment_status in ('unpaid', 'pending', 'failed')
  )
  select
    count(*) as n,
    coalesce(sum(o.outstanding), 0) as outstanding_total,
    coalesce(jsonb_agg(
      jsonb_build_object(
        'orderId', o.id,
        'orderNumber', o.order_number,
        'createdAt', o.created_at,
        'orderDate', o.order_date,
        'ageDays', v_today - o.order_date,
        'status', o.status,
        'paymentStatus', o.payment_status,
        'customerName', o.customer_name,
        'customerEmail', o.customer_email,
        'customerPhone', o.customer_phone,
        'totalAmount', o.total_amount,
        'amountPaid', o.amount_paid,
        'outstanding', o.outstanding,
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
          where i.order_id = o.id
            and i.tenant_id = v_tenant_id
        ), '[]'::jsonb)
      )
      order by o.created_at, o.id
    ), '[]'::jsonb) as orders
  into v_result
  from owing o
  where o.outstanding > 0;

  return jsonb_build_object(
    'businessDate', v_today,
    'timezone', 'Africa/Johannesburg',
    'count', v_result.n,
    'outstandingTotal', v_result.outstanding_total,
    'orders', v_result.orders
  );
end
$$;

revoke all on function public.list_quick_solution_unpaid_counter_orders()
  from public, anon, authenticated, service_role;
grant execute on function public.list_quick_solution_unpaid_counter_orders()
  to authenticated;

comment on function public.list_quick_solution_unpaid_counter_orders() is
  'CAFE-GUEST-01T: read-only list of every counter-channel order of the Cafe tenant that still owes money (outstanding by the completed ledger > 0, not cancelled or draft), oldest first, with its age in Cafe business days (Africa/Johannesburg). No arguments; no keys, actor, metadata, pricing or tenant ids.';
