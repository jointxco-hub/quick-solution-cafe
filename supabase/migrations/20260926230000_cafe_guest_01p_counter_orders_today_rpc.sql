-- CAFE-GUEST-01P: Today's Counter Orders, read-only.
--
--   public.list_quick_solution_counter_orders_today()  returns jsonb
--
-- Lets Cafe staff see the counter orders created today, so a sale can be recovered after a refresh,
-- an uncertain network result, or when another staff member picks it up. It writes nothing (STABLE)
-- and takes NO argument: the caller cannot name a tenant, a channel, a creator or a date.
--
-- SECURITY, in this order (identical to the other counter RPCs; nothing depends on the front end):
--   1. authenticate: auth.uid() is required.               42501 'Staff sign-in is required.'
--   2. resolve the canonical Cafe tenant, active only.     22023 'Quick Solution tenant was not found.'
--   3. authorize: public.has_tenant_capability(tenant, 'cafe.counter.operate') - an active owner,
--      admin or member of THAT tenant. No app-admin or OPPS-staff bypass, and not the manage
--      capability: a plain active member sees the counter's orders.
--                                                          42501 'You do not have access to the Quick Solution counter.'
--   4. require the tenant's quick_solution module.         22023 'Quick Solution counter is not active.'
--
-- SCOPE: commerce.service_orders of that tenant with channel = 'counter' and created today. Storefront
-- orders, other tenants and other days are never returned. Every counter order of the day is visible,
-- whoever created it: that is the point (one staff member can continue another's sale).
--
-- "TODAY" is the Cafe's BUSINESS day in Africa/Johannesburg - the zone the order numbers (QS-YYMMDD-...)
-- and pricing versions already use. South Africa has no daylight saving, so a day runs from local
-- midnight (22:00 UTC the evening before) to the next. It is decided on created_at with a half-open
-- range [day start, next day start): an order at exactly local midnight belongs to the NEW day, and one
-- a microsecond earlier to the old. The rule lives in one internal function so it can be tested at fixed
-- instants, not only against the clock.
--
-- RESPONSE: { businessDate, timezone, orders: [ { orderId, orderNumber, createdAt, status,
-- paymentStatus, customerName, customerEmail, customerPhone, totalAmount, items: [ { productKey,
-- productName, quantity, configuration, lineTotal } ] } ] }, newest first (created_at, then id).
-- Items are a list so multi-item orders need no change of shape. Deliberately NOT returned: the
-- idempotency key, source_metadata, created_by / any auth identity, pricing_snapshot, pricing
-- definitions, supplier or margin data, tenant ids and fulfilment internals. Staff see the customer
-- details they entered, as they do in the create response.
--
-- DEPENDENCY: public.has_tenant_capability is owned by the OPPS repo (CAFE-ACCESS-01..03).

do $preflight$
begin
  if to_regprocedure('public.has_tenant_capability(uuid,text)') is null then
    raise exception 'CAFE_GUEST_01P_MIGRATION_PRECONDITION: public.has_tenant_capability (CAFE-ACCESS) must exist';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'commerce' and table_name = 'service_orders' and column_name = 'channel'
  ) then
    raise exception 'CAFE_GUEST_01P_MIGRATION_PRECONDITION: commerce.service_orders.channel (CAFE-GUEST-01A) must exist';
  end if;
end
$preflight$;

-- ── the one business-day rule ────────────────────────────────────────────
create or replace function commerce._qs_counter_business_day(p_at timestamptz)
returns table (business_date date, day_start timestamptz, day_end timestamptz)
language sql
stable
set search_path = ''
as $$
  select d.business_date,
         d.business_date::timestamp at time zone 'Africa/Johannesburg',
         (d.business_date + 1)::timestamp at time zone 'Africa/Johannesburg'
  from (select (p_at at time zone 'Africa/Johannesburg')::date as business_date) d
$$;

revoke all on function commerce._qs_counter_business_day(timestamptz)
  from public, anon, authenticated, service_role;

comment on function commerce._qs_counter_business_day(timestamptz) is
  'CAFE-GUEST-01P: the Cafe business day (Africa/Johannesburg) containing an instant, as [day_start, day_end). Internal.';

-- ── the RPC ──────────────────────────────────────────────────────────────
create or replace function public.list_quick_solution_counter_orders_today()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_day record;
  v_orders jsonb;
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

  select coalesce(jsonb_agg(o.summary order by o.created_at desc, o.id desc), '[]'::jsonb)
  into v_orders
  from (
    select
      so.id,
      so.created_at,
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
  ) o;

  return jsonb_build_object(
    'businessDate', v_day.business_date,
    'timezone', 'Africa/Johannesburg',
    'orders', v_orders
  );
end
$$;

-- Staff RPC, called by the browser as the signed-in user: authenticated only.
revoke all on function public.list_quick_solution_counter_orders_today()
  from public, anon, authenticated, service_role;
grant execute on function public.list_quick_solution_counter_orders_today()
  to authenticated;

comment on function public.list_quick_solution_counter_orders_today() is
  'CAFE-GUEST-01P: read-only list of today''s (Africa/Johannesburg business day) counter-channel orders of the Cafe tenant, newest first, for anyone with cafe.counter.operate. No arguments; no idempotency key, source metadata, creator identity or pricing data in the result.';
