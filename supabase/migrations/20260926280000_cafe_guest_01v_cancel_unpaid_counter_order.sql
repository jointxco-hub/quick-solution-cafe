-- CAFE-GUEST-01V: an admin or owner cancels a counter order that was never paid, with a reason and a permanent audit row.
--
--   public.get_quick_solution_counter_order_cancel_check(p_order_id uuid)   returns jsonb  (STABLE, read-only)
--   public.cancel_quick_solution_counter_order(p_order_id uuid, p_reason text)  returns jsonb  (VOLATILE)
--   commerce.service_order_cancellations                                    append-only audit table
--   commerce._qs_counter_cancel_block(commerce.service_orders)              the ONE rule for "may this order be cancelled" (internal)
--
-- WHO. cafe.operations.manage (active owner or admin of the Cafe tenant; CAFE-ACCESS-01/03). A plain counter member holds only
-- cafe.counter.operate: they create orders and take payments but cannot cancel. Admins and owners also hold counter.operate, but
-- cancelling asks for the manage capability ONLY. No app-admin / OPPS-staff bypass.
--
-- WHEN (commerce._qs_counter_cancel_block returns null). Derived from an audit of what the codebase really does to a service order:
--   * live code only ever sets status 'submitted' (counter and storefront create) and moves 'submitted' -> 'accepted' when the order is
--     handed to OPPS (QS-04B, which also sets opps_order_id and the handoff row to 'sent'). 'in_production', 'ready' and 'completed' are
--     legal values of the status check but NO function in this repo writes them: they are written by OPPS / production, so they mean work
--     has begun. 'draft' is a basket that was never placed (counter orders never are). 'cancelled' is already done.
--   * therefore ONLY status 'submitted' can be cancelled; every other status is refused ('draft' as not_cancellable, 'accepted' /
--     'in_production' / 'ready' / 'completed' as in_progress). This is the narrowest list the audit supports; widening it is a decision.
--   * never when money may exist: any COMPLETED ledger row (has_payment), or any PENDING ledger row / payment_status 'pending'
--     (payment_in_progress: a gateway payment could still complete), or payment_status other than 'unpaid' / 'failed'.
--   * never when it has been sent on: opps_order_id set or handoff 'sending' / 'sent' (sent_to_production, the same rule as 01Q payment).
--     A handoff that is only 'previewed', 'blocked', 'ready' or 'failed' has sent nothing, so the order can still be cancelled; the OPPS
--     handoff preview already refuses a cancelled order (ORDER_CLOSED) and the PayFast path already refuses one, so it cannot be sent
--     or paid afterwards.
--   * total > 0 and outstanding > 0 (a zero-value order owes nothing to cancel).
--   Checked in this order: already_cancelled, has_payment, payment_in_progress, sent_to_production, in_progress / not_cancellable,
--   not_payable_state (odd payment_status), nothing_outstanding.
--
-- WHAT IT WRITES, in one transaction under the order row lock (the same lock the counter payment takes, so a payment and a cancel of
-- one order serialise: one wins and the other sees the result): service_orders.status = 'cancelled' (payment_status is left as it was;
-- every counter query already treats status 'cancelled' as owing nothing), and ONE commerce.service_order_cancellations row.
--
-- AUDIT. Who (auth.uid(), server-side, never from the caller), when (server time), why (the reason), and what it looked like (prior
-- status, prior payment status, total, outstanding). One row per order (unique). Append-only: RLS on, no API grants, and triggers refuse
-- UPDATE, DELETE and TRUNCATE for everyone, including the table owner.
--
-- REASON. Required, trimmed, 3..300 characters, no control characters. Nothing else is accepted from the caller: no tenant, channel,
-- status, actor, time or amount.
--
-- RETRY. A retry by the same admin with the same reason after a successful cancel returns the original result (replayed true) and writes
-- nothing. Any other second cancel is refused ("already cancelled").
--
-- SECURITY, in this order (both RPCs): 1 authenticated 42501 'Staff sign-in is required.'  2 canonical tenant 22023  3 has_tenant_capability
-- 'cafe.operations.manage' 42501  4 quick_solution module 22023. A storefront order, another tenant's order and an unknown id are all the
-- same 22023 'Counter order was not found.'
--   The CHECK RPC is for the screen: it needs cafe.counter.operate (like every counter read), tells the caller whether they may cancel
--   (permitted, decided by manage) and whether the order can be cancelled (cancellable / block, decided by the shared rule); it writes nothing.
--
-- DEPENDENCY: public.has_tenant_capability (OPPS repo, CAFE-ACCESS-01..03), the 01Q ledger helper commerce._qs_order_amount_paid.

do $preflight$
begin
  if to_regprocedure('public.has_tenant_capability(uuid,text)') is null then
    raise exception 'CAFE_GUEST_01V_MIGRATION_PRECONDITION: public.has_tenant_capability (CAFE-ACCESS) must exist';
  end if;
  if to_regprocedure('commerce._qs_order_amount_paid(uuid)') is null then
    raise exception 'CAFE_GUEST_01V_MIGRATION_PRECONDITION: the 01Q amount-paid rule must exist';
  end if;
  if to_regclass('commerce.service_order_handoffs') is null or to_regclass('commerce.service_order_payments') is null then
    raise exception 'CAFE_GUEST_01V_MIGRATION_PRECONDITION: the QS-04 handoff table and the QS-08 payment ledger must exist';
  end if;
end
$preflight$;

-- ── audit table ──────────────────────────────────────────────────────────
create table if not exists commerce.service_order_cancellations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  service_order_id uuid not null references commerce.service_orders(id) on delete restrict,
  cancelled_by uuid not null,
  cancelled_at timestamptz not null default now(),
  reason text not null,
  prior_status text not null,
  prior_payment_status text not null,
  order_total numeric(12, 2) not null,
  outstanding_at_cancel numeric(12, 2) not null,
  constraint service_order_cancellations_one_per_order unique (service_order_id),
  constraint service_order_cancellations_reason_check
    check (reason = btrim(reason) and char_length(reason) between 3 and 300 and reason !~ '[[:cntrl:]]')
);

create index if not exists idx_qs_cancellations_tenant_time
  on commerce.service_order_cancellations (tenant_id, cancelled_at desc);

alter table commerce.service_order_cancellations enable row level security;
revoke all on commerce.service_order_cancellations from public, anon, authenticated, service_role;

create or replace function commerce.qs_guard_service_order_cancellation_append_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception using errcode = '23514',
    message = 'SERVICE_ORDER_CANCELLATION_APPEND_ONLY: a cancellation record cannot be changed or removed.';
end
$$;

revoke all on function commerce.qs_guard_service_order_cancellation_append_only()
  from public, anon, authenticated, service_role;

drop trigger if exists trg_qs_cancellation_no_update_delete on commerce.service_order_cancellations;
create trigger trg_qs_cancellation_no_update_delete
before update or delete on commerce.service_order_cancellations
for each row execute function commerce.qs_guard_service_order_cancellation_append_only();

drop trigger if exists trg_qs_cancellation_no_truncate on commerce.service_order_cancellations;
create trigger trg_qs_cancellation_no_truncate
before truncate on commerce.service_order_cancellations
for each statement execute function commerce.qs_guard_service_order_cancellation_append_only();

comment on table commerce.service_order_cancellations is
  'CAFE-GUEST-01V: append-only audit of a cancelled counter order: who, when, why and what it looked like. One row per order. Written only by cancel_quick_solution_counter_order; no API role can read or write it.';

-- ── the one rule: may this counter order be cancelled? ───────────────────
create or replace function commerce._qs_counter_cancel_block(p_order commerce.service_orders)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_handoff text;
begin
  if p_order.status = 'cancelled' then return 'already_cancelled'; end if;

  if p_order.payment_status in ('paid', 'refunded')
     or exists (
       select 1 from commerce.service_order_payments p
       where p.service_order_id = p_order.id and p.tenant_id = p_order.tenant_id and p.status = 'completed'
     ) then
    return 'has_payment';
  end if;

  if p_order.payment_status = 'pending'
     or exists (
       select 1 from commerce.service_order_payments p
       where p.service_order_id = p_order.id and p.tenant_id = p_order.tenant_id and p.status = 'pending'
     ) then
    return 'payment_in_progress';
  end if;

  select h.status into v_handoff from commerce.service_order_handoffs h where h.service_order_id = p_order.id limit 1;
  if p_order.opps_order_id is not null or v_handoff in ('sending', 'sent') then return 'sent_to_production'; end if;

  if p_order.status = 'draft' then return 'not_cancellable'; end if;
  if p_order.status <> 'submitted' then return 'in_progress'; end if;

  if p_order.payment_status not in ('unpaid', 'failed') then return 'not_payable_state'; end if;

  if p_order.total_amount <= 0
     or round(p_order.total_amount - commerce._qs_order_amount_paid(p_order.id), 2) <= 0 then
    return 'nothing_outstanding';
  end if;
  return null;
end
$$;

revoke all on function commerce._qs_counter_cancel_block(commerce.service_orders)
  from public, anon, authenticated, service_role;

comment on function commerce._qs_counter_cancel_block(commerce.service_orders) is
  'CAFE-GUEST-01V: the one rule for "may this counter order be cancelled": null, or already_cancelled / has_payment / payment_in_progress / sent_to_production / not_cancellable / in_progress / not_payable_state / nothing_outstanding. Internal.';

-- ── check (read-only, for the screen) ────────────────────────────────────
create or replace function public.get_quick_solution_counter_order_cancel_check(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_order commerce.service_orders;
  v_permitted boolean;
  v_block text;
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

  v_permitted := public.has_tenant_capability(v_tenant_id, 'cafe.operations.manage');
  v_block := commerce._qs_counter_cancel_block(v_order);

  return jsonb_build_object(
    'orderId', v_order.id,
    'permitted', v_permitted,
    'cancellable', v_block is null,
    'block', v_block
  );
end
$$;

revoke all on function public.get_quick_solution_counter_order_cancel_check(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.get_quick_solution_counter_order_cancel_check(uuid)
  to authenticated;

comment on function public.get_quick_solution_counter_order_cancel_check(uuid) is
  'CAFE-GUEST-01V: read-only. For a caller with cafe.counter.operate: whether THEY may cancel this counter order (permitted = cafe.operations.manage) and whether the ORDER can be cancelled (cancellable / block from the one shared rule). Writes nothing.';

-- ── cancel ───────────────────────────────────────────────────────────────
create or replace function public.cancel_quick_solution_counter_order(p_order_id uuid, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_actor uuid;
  v_tenant_id uuid;
  v_reason text;
  v_order commerce.service_orders;
  v_existing commerce.service_order_cancellations;
  v_block text;
  v_outstanding numeric;
  v_at timestamptz;
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

  if not public.has_tenant_capability(v_tenant_id, 'cafe.operations.manage') then
    raise exception using errcode = '42501', message = 'Only a Quick Solution admin or owner can cancel a counter order.';
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

  v_reason := btrim(coalesce(p_reason, ''));
  if char_length(v_reason) < 3 then
    raise exception using errcode = '22023', message = 'A reason for the cancellation is required.';
  end if;
  if char_length(v_reason) > 300 then
    raise exception using errcode = '22023', message = 'The cancellation reason is too long.';
  end if;
  if v_reason ~ '[[:cntrl:]]' then
    raise exception using errcode = '22023', message = 'The cancellation reason is not valid.';
  end if;
  if p_order_id is null then
    raise exception using errcode = '22023', message = 'Counter order was not found.';
  end if;

  -- the same order row lock the counter payment takes: a payment and a cancel of one order cannot both win
  select so.*
  into v_order
  from commerce.service_orders so
  where so.id = p_order_id
    and so.tenant_id = v_tenant_id
    and so.channel = 'counter'
  for update;

  if v_order.id is null then
    raise exception using errcode = '22023', message = 'Counter order was not found.';
  end if;

  v_block := commerce._qs_counter_cancel_block(v_order);

  if v_block = 'already_cancelled' then
    select c.* into v_existing
    from commerce.service_order_cancellations c
    where c.service_order_id = v_order.id;
    if v_existing.id is not null and v_existing.cancelled_by = v_actor and v_existing.reason = v_reason then
      return jsonb_build_object(
        'ok', true,
        'replayed', true,
        'orderId', v_order.id,
        'orderNumber', v_order.order_number,
        'status', 'cancelled',
        'cancelledAt', v_existing.cancelled_at,
        'reason', v_existing.reason
      );
    end if;
    raise exception using errcode = '22023', message = 'This order is already cancelled.';
  elsif v_block = 'has_payment' then
    raise exception using errcode = '22023', message = 'This order has a payment and cannot be cancelled.';
  elsif v_block = 'payment_in_progress' then
    raise exception using errcode = '22023', message = 'A payment for this order is still in progress, so it cannot be cancelled.';
  elsif v_block = 'sent_to_production' then
    raise exception using errcode = '22023', message = 'This order has already been sent to production and cannot be cancelled here.';
  elsif v_block = 'in_progress' then
    raise exception using errcode = '22023', message = 'This order is already being worked on and cannot be cancelled here.';
  elsif v_block = 'nothing_outstanding' then
    raise exception using errcode = '22023', message = 'This order has nothing outstanding to cancel.';
  elsif v_block is not null then
    raise exception using errcode = '22023', message = 'This order cannot be cancelled.';
  end if;

  v_outstanding := greatest(round(v_order.total_amount - commerce._qs_order_amount_paid(v_order.id), 2), 0);
  v_at := clock_timestamp();

  update commerce.service_orders
  set status = 'cancelled',
      updated_at = now()
  where id = v_order.id;

  insert into commerce.service_order_cancellations (
    tenant_id, service_order_id, cancelled_by, cancelled_at, reason, prior_status, prior_payment_status, order_total, outstanding_at_cancel
  )
  values (
    v_tenant_id, v_order.id, v_actor, v_at, v_reason, v_order.status, v_order.payment_status, v_order.total_amount, v_outstanding
  );

  return jsonb_build_object(
    'ok', true,
    'replayed', false,
    'orderId', v_order.id,
    'orderNumber', v_order.order_number,
    'status', 'cancelled',
    'cancelledAt', v_at,
    'reason', v_reason
  );
end
$$;

revoke all on function public.cancel_quick_solution_counter_order(uuid, text)
  from public, anon, authenticated, service_role;
grant execute on function public.cancel_quick_solution_counter_order(uuid, text)
  to authenticated;

comment on function public.cancel_quick_solution_counter_order(uuid, text) is
  'CAFE-GUEST-01V: cancels ONE never-paid counter order of the Cafe tenant for cafe.operations.manage (owner/admin only). Requires a reason; refuses a paid, part-paid, payment-pending, sent-on, in-progress or already cancelled order; sets status cancelled and writes one append-only audit row (who, when, why) in the same transaction under the order row lock.';
