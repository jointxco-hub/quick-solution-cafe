-- CAFE-GUEST-01W: the cancelled counter orders, with who cancelled them, when and why. Read-only.
--
--   public.list_quick_solution_cancelled_counter_orders()  returns jsonb  (STABLE)
--
-- 01V lets an admin or owner cancel a never-paid counter order and records an append-only audit row. This lets them REVIEW those
-- cancellations. It writes nothing and takes NO argument: the caller cannot name a tenant, channel, actor or date.
--
-- WHO. cafe.operations.manage (active admin or owner) - the same capability that may cancel. A plain counter member is refused: the
-- audit names a colleague and a reason, and is for owners to review. No app-admin / OPPS-staff bypass. Order of checks:
--   1 authenticated 42501 'Staff sign-in is required.'   2 canonical tenant 22023   3 has_tenant_capability 'cafe.operations.manage' 42501
--   'Only a Quick Solution admin or owner can view cancelled counter orders.'   4 quick_solution module 22023.
--
-- WHAT. Exactly the orders that have a 01V audit row (commerce.service_order_cancellations), of the Cafe tenant, channel 'counter'. An
-- order that merely has status 'cancelled' with no audit row (cancelled some other way) is NOT listed: this is the audited list, and it
-- says so. Newest cancellation first (cancelled_at desc, then id), at most the 100 most recent; `count` is the total that exist and
-- `shown` how many are returned, so a longer history is visible, never silent.
--
-- RESPONSE: { count, shown, limit, orders: [ { orderId, orderNumber, createdAt, cancelledAt, reason, cancelledBy, priorStatus,
-- priorPaymentStatus, totalAmount, outstandingAtCancel, customerName, customerEmail, customerPhone, items: [ { productKey, productName,
-- quantity, configuration, lineTotal } ] } ] }. `cancelledBy` is the staff member's DISPLAY NAME from public.users (or null when there is
-- none); the auth user id is never returned. Deliberately NOT returned: idempotency keys, source metadata, pricing snapshots or
-- definitions, supplier or margin data, tenant ids, auth identities. Count, shown and the rows come out of ONE query.
--
-- DEPENDENCY: public.has_tenant_capability (OPPS repo, CAFE-ACCESS-01..03) and the 01V audit table.

do $preflight$
begin
  if to_regprocedure('public.has_tenant_capability(uuid,text)') is null then
    raise exception 'CAFE_GUEST_01W_MIGRATION_PRECONDITION: public.has_tenant_capability (CAFE-ACCESS) must exist';
  end if;
  if to_regclass('commerce.service_order_cancellations') is null then
    raise exception 'CAFE_GUEST_01W_MIGRATION_PRECONDITION: the 01V cancellation audit table must exist';
  end if;
end
$preflight$;

create or replace function public.list_quick_solution_cancelled_counter_orders()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
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

  if not public.has_tenant_capability(v_tenant_id, 'cafe.operations.manage') then
    raise exception using errcode = '42501', message = 'Only a Quick Solution admin or owner can view cancelled counter orders.';
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

  with cancelled as (
    select
      so.id,
      so.order_number,
      so.created_at,
      so.customer_name,
      so.customer_email,
      so.customer_phone,
      c.cancelled_at,
      c.reason,
      c.prior_status,
      c.prior_payment_status,
      c.order_total,
      c.outstanding_at_cancel,
      (select u.full_name from public.users u where u.auth_user_id = c.cancelled_by limit 1) as cancelled_by_name
    from commerce.service_order_cancellations c
    join commerce.service_orders so
      on so.id = c.service_order_id
     and so.tenant_id = c.tenant_id
    where c.tenant_id = v_tenant_id
      and so.channel = 'counter'
  ),
  recent as (
    select * from cancelled order by cancelled_at desc, id desc limit 100
  )
  select
    (select count(*) from cancelled) as n,
    count(*) as shown,
    coalesce(jsonb_agg(
      jsonb_build_object(
        'orderId', r.id,
        'orderNumber', r.order_number,
        'createdAt', r.created_at,
        'cancelledAt', r.cancelled_at,
        'reason', r.reason,
        'cancelledBy', r.cancelled_by_name,
        'priorStatus', r.prior_status,
        'priorPaymentStatus', r.prior_payment_status,
        'totalAmount', r.order_total,
        'outstandingAtCancel', r.outstanding_at_cancel,
        'customerName', r.customer_name,
        'customerEmail', r.customer_email,
        'customerPhone', r.customer_phone,
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
          where i.order_id = r.id
            and i.tenant_id = v_tenant_id
        ), '[]'::jsonb)
      )
      order by r.cancelled_at desc, r.id desc
    ), '[]'::jsonb) as orders
  into v_result
  from recent r;

  return jsonb_build_object(
    'count', v_result.n,
    'shown', v_result.shown,
    'limit', 100,
    'orders', v_result.orders
  );
end
$$;

revoke all on function public.list_quick_solution_cancelled_counter_orders()
  from public, anon, authenticated, service_role;
grant execute on function public.list_quick_solution_cancelled_counter_orders()
  to authenticated;

comment on function public.list_quick_solution_cancelled_counter_orders() is
  'CAFE-GUEST-01W: read-only. The audited cancelled counter orders of the Cafe tenant (who, when, why), newest first, at most 100 with the total count, for cafe.operations.manage (admin/owner) only. Takes no argument and writes nothing.';
