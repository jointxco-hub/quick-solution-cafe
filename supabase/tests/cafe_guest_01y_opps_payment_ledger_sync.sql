-- CAFE-GUEST-01Y: behavioral contract test for commerce._qs_sync_opps_payment_ledger and the payment-sync
-- additions to public.admin_send_quick_solution_order_to_opps.
--
-- Run only against the disposable local harness (supabase/tests/harness/), which replays the migration
-- history INCLUDING the OPPS-owned access layer and
--   20260927110000_cafe_guest_01y_opps_payment_ledger_sync.sql
-- Counter orders and their payments are created through the REAL 01M/01Q RPCs; the send-to-OPPS call goes
-- through the real admin_send_quick_solution_order_to_opps as an app-admin. Everything is enclosed by
-- BEGIN/ROLLBACK.

\set ON_ERROR_STOP on

begin;

-- ── test-only helpers ────────────────────────────────────────────────────
create function public._cg01y_setup(p_sub uuid, p_email text) returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claims',
    jsonb_strip_nulls(jsonb_build_object('sub', p_sub, 'role', 'authenticated', 'email', p_email))::text, true);
  execute 'set local role authenticated';
end
$$;

create function public._cg01y_create(p_sub uuid, p_key text, p_product text, p_config jsonb) returns uuid
language plpgsql
as $$
declare v_result jsonb;
begin
  perform public._cg01y_setup(p_sub, null);
  v_result := public.create_quick_solution_counter_order(p_key, p_product, p_config);
  execute 'reset role';
  return (v_result ->> 'orderId')::uuid;
end
$$;

create function public._cg01y_pay(p_sub uuid, p_order uuid, p_method text, p_key text) returns jsonb
language plpgsql
as $$
declare v_result jsonb;
begin
  perform public._cg01y_setup(p_sub, null);
  v_result := public.record_quick_solution_counter_payment(p_order, p_method, p_key);
  execute 'reset role';
  return v_result;
end
$$;

create function public._cg01y_send(p_sub uuid, p_email text, p_order uuid) returns jsonb
language plpgsql
as $$
declare v_result jsonb;
begin
  perform public._cg01y_setup(p_sub, p_email);
  v_result := public.admin_send_quick_solution_order_to_opps(p_order);
  execute 'reset role';
  return v_result;
end
$$;

grant execute on function public._cg01y_setup(uuid, text), public._cg01y_create(uuid, text, text, jsonb),
  public._cg01y_pay(uuid, uuid, text, text), public._cg01y_send(uuid, text, uuid) to anon, authenticated, service_role;

-- ═════════ fixtures ═════════
create table public._cg01y_ctx (k text primary key, v text);

do $fixtures$
declare
  v_cafe uuid;
  u_staff uuid := gen_random_uuid();
  u_appadmin uuid := gen_random_uuid();
  v_suffix text := replace(gen_random_uuid()::text, '-', '');
begin
  select t.id into v_cafe from public.tenants t where t.slug = 'quick-solution' and t.status = 'active';
  if v_cafe is null then raise exception 'CAFE_GUEST_01Y_TEST_SETUP: the quick-solution tenant must exist'; end if;
  insert into public._cg01y_ctx values ('cafe', v_cafe::text), ('u_staff', u_staff::text), ('u_appadmin', u_appadmin::text);

  insert into auth.users(id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values
    (u_staff, 'authenticated', 'authenticated', 'cg01y-staff-' || v_suffix || '@disposable.test', now(), '{}'::jsonb, '{}'::jsonb, now(), now()),
    (u_appadmin, 'authenticated', 'authenticated', 'cg01y-appadmin-' || v_suffix || '@disposable.test', now(), '{}'::jsonb, '{}'::jsonb, now(), now());

  -- u_appadmin is also given a real admin membership of the Cafe tenant: the security patch
  -- (20260927120000) removes admin_send_quick_solution_order_to_opps's is_app_admin() bypass, so
  -- from that migration onward a caller needs cafe.operations.manage, not merely app-admin status,
  -- to send an order.
  insert into public.tenant_memberships(tenant_id, auth_user_id, tenant_role, status)
  values (v_cafe, u_staff, 'member', 'active'),
         (v_cafe, u_appadmin, 'admin', 'active');
end
$fixtures$;

-- ═════════ 1. paid Cash counter order -> one OPPS Cash payment, balance 0 ═
do $t1$
declare
  u_staff uuid := (select v::uuid from public._cg01y_ctx where k = 'u_staff');
  u_appadmin uuid := (select v::uuid from public._cg01y_ctx where k = 'u_appadmin');
  v_order uuid := public._cg01y_create(u_staff, 'cg01y-cash-order-001', 'scan', '{"units":1}'::jsonb);
  v_pay jsonb; v_send jsonb; v_opps_id uuid; v_tx record;
begin
  v_pay := public._cg01y_pay(u_staff, v_order, 'cash', 'cg01y-cash-pay-key');
  if (v_pay ->> 'ok')::boolean is not true then raise exception 'CAFE_GUEST_01Y: cash payment must succeed: %', v_pay; end if;

  v_send := public._cg01y_send(u_appadmin, 'jointx.co@gmail.com', v_order);
  if (v_send ->> 'ok')::boolean is not true or v_send ->> 'handoffStatus' <> 'sent' then raise exception 'CAFE_GUEST_01Y: send must succeed: %', v_send; end if;
  v_opps_id := (v_send ->> 'oppsOrderId')::uuid;

  if (select count(*) from public.transactions where order_id = v_opps_id) <> 1 then
    raise exception 'CAFE_GUEST_01Y: exactly one OPPS transaction must exist for the paid order';
  end if;
  select * into v_tx from public.transactions where order_id = v_opps_id;
  if v_tx.type <> 'income' or v_tx.payment_status <> 'completed' or v_tx.payment_method <> 'cash' or v_tx.amount <> 5.00 then
    raise exception 'CAFE_GUEST_01Y: the OPPS transaction must be income/completed/cash/5.00: %', v_tx;
  end if;

  if (select payment_status from public.orders where id = v_opps_id) <> 'paid' then raise exception 'CAFE_GUEST_01Y: the OPPS order must be paid'; end if;
  if (select deposit_paid from public.orders where id = v_opps_id) <> 5.00 then raise exception 'CAFE_GUEST_01Y: deposit_paid must equal the ledger sum (5.00)'; end if;
  if (select total_amount from public.orders where id = v_opps_id) <> 5.00 then raise exception 'CAFE_GUEST_01Y: total_amount must stay 5.00'; end if;
  -- balance = total_amount - SUM(completed income) = 0
  if (select total_amount - coalesce((select sum(amount) from public.transactions where order_id = v_opps_id and type = 'income' and payment_status = 'completed'), 0) from public.orders where id = v_opps_id) <> 0 then
    raise exception 'CAFE_GUEST_01Y: balance must be exactly 0';
  end if;
  insert into public._cg01y_ctx values ('cash_order', v_order::text), ('cash_opps_id', v_opps_id::text);
end
$t1$;

-- ═════════ 2. paid Card counter order -> correct method/amount ═══════════
do $t2$
declare
  u_staff uuid := (select v::uuid from public._cg01y_ctx where k = 'u_staff');
  u_appadmin uuid := (select v::uuid from public._cg01y_ctx where k = 'u_appadmin');
  v_order uuid := public._cg01y_create(u_staff, 'cg01y-card-order-001', 'a4-lamination', '{"units":1}'::jsonb);
  v_pay jsonb; v_send jsonb; v_opps_id uuid; v_tx record;
begin
  v_pay := public._cg01y_pay(u_staff, v_order, 'card', 'cg01y-card-pay-key');
  if (v_pay ->> 'ok')::boolean is not true then raise exception 'CAFE_GUEST_01Y: card payment must succeed: %', v_pay; end if;

  v_send := public._cg01y_send(u_appadmin, 'jointx.co@gmail.com', v_order);
  v_opps_id := (v_send ->> 'oppsOrderId')::uuid;

  select * into v_tx from public.transactions where order_id = v_opps_id;
  if v_tx.payment_method <> 'card' or v_tx.amount <> 15.00 then raise exception 'CAFE_GUEST_01Y: card method/amount must pass through unchanged: %', v_tx; end if;
  if (select payment_status from public.orders where id = v_opps_id) <> 'paid' then raise exception 'CAFE_GUEST_01Y: the card-paid OPPS order must be paid'; end if;
end
$t2$;

-- ═════════ 3. unpaid counter order -> no OPPS payment ════════════════════
do $t3$
declare
  u_staff uuid := (select v::uuid from public._cg01y_ctx where k = 'u_staff');
  u_appadmin uuid := (select v::uuid from public._cg01y_ctx where k = 'u_appadmin');
  v_order uuid := public._cg01y_create(u_staff, 'cg01y-unpaid-order-001', 'scan', '{"units":1}'::jsonb);
  v_send jsonb; v_opps_id uuid;
begin
  -- the send RPC is gated by the same ready/blocker rule as everything else; an unpaid counter order is
  -- still "ready" (payment is only a warning, CAFE-GUEST-01Q/01S contract), so it can still be sent -
  -- exactly the case this migration must get right: sent, but with NO fabricated payment or Paid flag.
  v_send := public._cg01y_send(u_appadmin, 'jointx.co@gmail.com', v_order);
  if (v_send ->> 'ok')::boolean is not true then raise exception 'CAFE_GUEST_01Y: sending an unpaid order must still succeed: %', v_send; end if;
  v_opps_id := (v_send ->> 'oppsOrderId')::uuid;

  if (select count(*) from public.transactions where order_id = v_opps_id) <> 0 then
    raise exception 'CAFE_GUEST_01Y: an unpaid Cafe order must create zero OPPS transactions';
  end if;
  if (select payment_status from public.orders where id = v_opps_id) <> 'pending' then
    raise exception 'CAFE_GUEST_01Y: an unpaid Cafe order must never be marked paid in OPPS';
  end if;
  if (select deposit_paid from public.orders where id = v_opps_id) <> 0 then
    raise exception 'CAFE_GUEST_01Y: deposit_paid must be 0 for an unpaid order';
  end if;
end
$t3$;

-- ═════════ 4. retry/replay -> no duplicate payment ════════════════════════
do $t4$
declare
  u_appadmin uuid := (select v::uuid from public._cg01y_ctx where k = 'u_appadmin');
  v_order uuid := (select v::uuid from public._cg01y_ctx where k = 'cash_order');
  v_opps_id uuid := (select v::uuid from public._cg01y_ctx where k = 'cash_opps_id');
  v_send jsonb;
begin
  -- retry 1
  v_send := public._cg01y_send(u_appadmin, 'jointx.co@gmail.com', v_order);
  if (v_send ->> 'replayed')::boolean is not true or (v_send ->> 'oppsOrderId')::uuid <> v_opps_id then
    raise exception 'CAFE_GUEST_01Y: a retry must replay the same OPPS order: %', v_send;
  end if;
  -- retry 2
  v_send := public._cg01y_send(u_appadmin, 'jointx.co@gmail.com', v_order);
  if (v_send ->> 'oppsOrderId')::uuid <> v_opps_id then raise exception 'CAFE_GUEST_01Y: a second retry must still replay the same OPPS order'; end if;

  if (select count(*) from public.transactions where order_id = v_opps_id) <> 1 then
    raise exception 'CAFE_GUEST_01Y: retrying must never create a second transaction';
  end if;
  if (select count(*) from public.transactions where order_id = v_opps_id and type = 'income') <> 1 then
    raise exception 'CAFE_GUEST_01Y: exactly one income transaction must exist after retries';
  end if;
  -- calling the sync helper directly, twice more, must also be a no-op (it is called on every replay too)
  perform commerce._qs_sync_opps_payment_ledger(v_order, v_opps_id);
  perform commerce._qs_sync_opps_payment_ledger(v_order, v_opps_id);
  if (select count(*) from public.transactions where order_id = v_opps_id) <> 1 then
    raise exception 'CAFE_GUEST_01Y: calling the sync helper directly must never duplicate the transaction';
  end if;
  if (select deposit_paid from public.orders where id = v_opps_id) <> 5.00 or (select payment_status from public.orders where id = v_opps_id) <> 'paid' then
    raise exception 'CAFE_GUEST_01Y: the order must remain correctly paid/5.00 after repeated syncs';
  end if;
end
$t4$;

-- ═════════ 5. order and payment totals remain consistent ════════════════
do $t5$
declare
  v_opps_id uuid := (select v::uuid from public._cg01y_ctx where k = 'cash_opps_id');
  v_total numeric; v_paid numeric; v_balance numeric;
begin
  select total_amount, deposit_paid into v_total, v_paid from public.orders where id = v_opps_id;
  select coalesce(sum(amount), 0) into v_balance from public.transactions where order_id = v_opps_id and type = 'income' and payment_status = 'completed';
  if v_paid <> v_balance then raise exception 'CAFE_GUEST_01Y: orders.deposit_paid (%) must equal SUM(completed income) (%)', v_paid, v_balance; end if;
  if v_total - v_balance <> 0 then raise exception 'CAFE_GUEST_01Y: total - ledger sum must be exactly 0 for a fully paid order'; end if;
end
$t5$;

-- ═════════ 6. no fabricated payment/method; idempotency is the existing schema, not a new one ═
do $t6$
begin
  if not exists (
    select 1 from pg_indexes where schemaname = 'public' and tablename = 'transactions' and indexname = 'transactions_order_id_unique'
  ) then
    raise exception 'CAFE_GUEST_01Y: the idempotency guarantee rests on the pre-existing order_id unique index';
  end if;
  -- a manually-entered transaction (as OPPS staff would create one directly) is never overwritten by the sync
  declare
    v_order uuid;
    v_opps_id uuid;
    v_manual_amount numeric := 999.00;
  begin
    v_order := public._cg01y_create((select v::uuid from public._cg01y_ctx where k = 'u_staff'), 'cg01y-manual-order-001', 'scan', '{"units":1}'::jsonb);
    perform public._cg01y_pay((select v::uuid from public._cg01y_ctx where k = 'u_staff'), v_order, 'cash', 'cg01y-manual-pay-key');
    declare v_send jsonb; begin
      v_send := public._cg01y_send((select v::uuid from public._cg01y_ctx where k = 'u_appadmin'), 'jointx.co@gmail.com', v_order);
      v_opps_id := (v_send ->> 'oppsOrderId')::uuid;
    end;
    -- tamper with the imported row to simulate "someone already entered something for this order"
    update public.transactions set amount = v_manual_amount where order_id = v_opps_id;
    perform commerce._qs_sync_opps_payment_ledger(v_order, v_opps_id);
    if (select amount from public.transactions where order_id = v_opps_id) <> v_manual_amount then
      raise exception 'CAFE_GUEST_01Y: the sync must never overwrite an existing transaction row for the order';
    end if;
    if (select count(*) from public.transactions where order_id = v_opps_id) <> 1 then
      raise exception 'CAFE_GUEST_01Y: still exactly one row after a re-sync attempt';
    end if;
  end;
end
$t6$;

-- ═════════ 7. existing PayFast/storefront flow: same helper, correct 'other' mapping ══
do $t7$
declare
  v_cafe uuid := (select v::uuid from public._cg01y_ctx where k = 'cafe');
  u_appadmin uuid := (select v::uuid from public._cg01y_ctx where k = 'u_appadmin');
  v_product_id uuid;
  v_order uuid := gen_random_uuid();
  v_num text;
  v_send jsonb; v_opps_id uuid; v_tx record;
begin
  select product_id into v_product_id from commerce.service_product_configs where tenant_id = v_cafe and source_key = 'a4-print';
  v_num := commerce.qs_generate_order_number();
  insert into commerce.service_orders(id, tenant_id, order_number, customer_name, customer_email, idempotency_key, channel, subtotal, total_amount, status, payment_status)
  values (v_order, v_cafe, v_num, 'Storefront customer', 'storefront@example.test', 'cg01y-storefront-key', 'storefront', 20, 20, 'submitted', 'paid');
  insert into commerce.service_order_items(order_id, tenant_id, product_id, product_key, product_name, quantity, configuration, line_total)
  values (v_order, v_cafe, v_product_id, 'a4-print', 'Storefront fixture', 1, '{}'::jsonb, 20);
  insert into commerce.service_order_payments(tenant_id, service_order_id, provider, status, amount, completed_at)
  values (v_cafe, v_order, 'payfast', 'completed', 20, now());

  v_send := public._cg01y_send(u_appadmin, 'jointx.co@gmail.com', v_order);
  if (v_send ->> 'ok')::boolean is not true then raise exception 'CAFE_GUEST_01Y: the storefront/PayFast order must still send successfully: %', v_send; end if;
  v_opps_id := (v_send ->> 'oppsOrderId')::uuid;

  select * into v_tx from public.transactions where order_id = v_opps_id;
  if v_tx.id is null then raise exception 'CAFE_GUEST_01Y: a PayFast-paid storefront order must also get an OPPS transaction (the same general fix)'; end if;
  if v_tx.payment_method <> 'other' then raise exception 'CAFE_GUEST_01Y: PayFast has no native transactions.payment_method value and must map to other, not be fabricated as cash/card'; end if;
  if v_tx.amount <> 20.00 then raise exception 'CAFE_GUEST_01Y: the PayFast amount must pass through unchanged'; end if;
  if v_tx.notes !~ 'payfast' then raise exception 'CAFE_GUEST_01Y: the real provider must be preserved in notes, not lost'; end if;
  if (select payment_status from public.orders where id = v_opps_id) <> 'paid' then raise exception 'CAFE_GUEST_01Y: the PayFast order must be paid in OPPS too'; end if;
end
$t7$;

-- ═════════ tenant isolation: the sync never crosses tenants ═════════════
do $tenant$
declare
  v_count integer;
begin
  select count(*) into v_count
  from public.transactions t
  join public.orders o on o.id = t.order_id
  where t.tenant_id is distinct from o.tenant_id;
  if v_count <> 0 then raise exception 'CAFE_GUEST_01Y: every imported transaction must carry the SAME tenant_id as its order'; end if;
end
$tenant$;

rollback;
select 'CAFE-GUEST-01Y OPPS payment ledger sync contracts passed' as result;
