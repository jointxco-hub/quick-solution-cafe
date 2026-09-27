-- CAFE-GUEST-01V: REAL concurrency test for public.cancel_quick_solution_counter_order() against the counter payment.
--
-- Two genuinely concurrent database sessions (dblink, over loopback to THIS disposable cluster only). Like the 01Q payment race it cannot be
-- rolled back (a second session cannot see uncommitted data), so it COMMITS its own fixtures, runs the races, and then deletes every row it
-- created (also when an assertion fails). The cancellation audit table is append-only, so the cleanup - and only the cleanup - disables its
-- guard trigger inside one transaction, deletes, and enables it again. The harness afterwards checks the row counts are back to baseline.
--
-- Race 1: staff A starts PAYING an order in cash and HOLDS it (2 s before commit); an admin B tries to CANCEL it. B must block on the order,
--         then find it paid and be refused. The order is paid exactly once, is not cancelled, and has no cancellation row.
-- Race 2: an admin A starts CANCELLING and HOLDS the order; a member B tries to PAY it. B must block, then be refused. The order is cancelled
--         exactly once, took no payment, and has one cancellation row.
-- Race 3: two admins cancel the SAME order at the same moment with different reasons: one wins, the other is told it is already cancelled,
--         and exactly one audit row exists (the winner's).
-- Race 4: the SAME admin sends the SAME cancel twice at once: one audit row; the second caller receives the original as a replay.
--
-- Run only against the disposable local harness (it needs the OPPS access layer, like the other 01M+ tests).

\set ON_ERROR_STOP on

create extension if not exists dblink;

create table public._cg01vc_ctx (k text primary key, v text);

create function public._cg01vc_race(p_sub uuid, p_kind text, p_order uuid, p_arg text, p_hold numeric) returns text
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    if p_kind = 'pay' then v_result := public.record_quick_solution_counter_payment(p_order, 'cash', p_arg);
    else v_result := public.cancel_quick_solution_counter_order(p_order, p_arg);
    end if;
  exception when others then
    execute 'reset role';
    return 'ERR ' || sqlstate || ' ' || sqlerrm;
  end;
  perform pg_sleep(p_hold);
  execute 'reset role';
  return v_result::text;
end
$$;

create function public._cg01vc_create(p_sub uuid, p_key text) returns uuid
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  v_result := public.create_quick_solution_counter_order(p_key, 'scan', '{"units":8}');
  execute 'reset role';
  return (v_result ->> 'orderId')::uuid;
end
$$;

create function public._cg01vc_cleanup() returns void
language plpgsql
as $$
declare
  v_users uuid[] := array(select v::uuid from public._cg01vc_ctx where k in ('member', 'admin1', 'admin2'));
begin
  alter table commerce.service_order_cancellations disable trigger trg_qs_cancellation_no_update_delete;
  delete from commerce.service_order_cancellations where service_order_id in (select id from commerce.service_orders where created_by = any (v_users));
  alter table commerce.service_order_cancellations enable trigger trg_qs_cancellation_no_update_delete;
  delete from commerce.service_order_payments where service_order_id in (select id from commerce.service_orders where created_by = any (v_users));
  delete from commerce.service_orders where created_by = any (v_users);
  delete from public.tenant_memberships where auth_user_id = any (v_users);
  delete from auth.users where id = any (v_users);
end
$$;

-- committed fixtures: an active member and two active admins of the Cafe
do $fixtures$
declare
  v_suffix text := replace(gen_random_uuid()::text, '-', '');
  v_cafe uuid;
  v_member uuid := gen_random_uuid();
  v_admin1 uuid := gen_random_uuid();
  v_admin2 uuid := gen_random_uuid();
begin
  select t.id into v_cafe from public.tenants t where t.slug = 'quick-solution' and t.status = 'active';
  if v_cafe is null then raise exception 'CAFE_GUEST_01V_CONCURRENCY_SETUP: the quick-solution tenant must exist'; end if;
  insert into public._cg01vc_ctx values ('cafe', v_cafe::text), ('suffix', v_suffix), ('member', v_member::text), ('admin1', v_admin1::text), ('admin2', v_admin2::text);
  insert into auth.users(id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_member, 'authenticated', 'authenticated', 'cg01vc-m-' || v_suffix || '@disposable.test', now(), '{}'::jsonb, '{}'::jsonb, now(), now()),
         (v_admin1, 'authenticated', 'authenticated', 'cg01vc-a1-' || v_suffix || '@disposable.test', now(), '{}'::jsonb, '{}'::jsonb, now(), now()),
         (v_admin2, 'authenticated', 'authenticated', 'cg01vc-a2-' || v_suffix || '@disposable.test', now(), '{}'::jsonb, '{}'::jsonb, now(), now());
  insert into public.tenant_memberships(tenant_id, auth_user_id, tenant_role, status)
  values (v_cafe, v_member, 'member', 'active'), (v_cafe, v_admin1, 'admin', 'active'), (v_cafe, v_admin2, 'admin', 'active');
end
$fixtures$;

-- the orders are created (and committed) BEFORE the races so the other sessions can see them
insert into public._cg01vc_ctx
select 'o' || n, public._cg01vc_create((select v::uuid from public._cg01vc_ctx where k = 'member'), 'cg01vc-' || (select v from public._cg01vc_ctx where k = 'suffix') || '-o' || n)::text
from generate_series(1, 4) n;

do $race$
declare
  v_suffix text := (select v from public._cg01vc_ctx where k = 'suffix');
  v_member uuid := (select v::uuid from public._cg01vc_ctx where k = 'member');
  v_admin1 uuid := (select v::uuid from public._cg01vc_ctx where k = 'admin1');
  v_admin2 uuid := (select v::uuid from public._cg01vc_ctx where k = 'admin2');
  v_conn text := format('host=127.0.0.1 port=%s dbname=%s user=%s', current_setting('port'), current_database(), current_user);
  v_order uuid;
  v_a text; v_b text; v_t0 timestamptz; v_b_elapsed numeric;
begin
  -- one race: A starts (and holds), B follows 0.6 s later; returns both answers and how long B waited
  -- (inlined four times below through a small loop over the cases)
  declare
    c record;
  begin
    for c in
      select * from (values
        (1, 'pay',    v_member, 'cg01vc-' || v_suffix || '-pay1', 'cancel', v_admin1, 'Customer walked out'),
        (2, 'cancel', v_admin1, 'Left without paying',            'pay',    v_member, 'cg01vc-' || v_suffix || '-pay2'),
        (3, 'cancel', v_admin1, 'Reason from admin one',          'cancel', v_admin2, 'Reason from admin two'),
        (4, 'cancel', v_admin1, 'Same reason twice',              'cancel', v_admin1, 'Same reason twice')
      ) as t(n, a_kind, a_sub, a_arg, b_kind, b_sub, b_arg)
    loop
      v_order := (select v::uuid from public._cg01vc_ctx where k = 'o' || c.n);
      perform dblink_connect('cg01vc_a', v_conn);
      perform dblink_connect('cg01vc_b', v_conn);
      perform dblink_send_query('cg01vc_a', format('select public._cg01vc_race(%L, %L, %L, %L, 2)', c.a_sub, c.a_kind, v_order, c.a_arg));
      perform pg_sleep(0.6);
      v_t0 := clock_timestamp();
      perform dblink_send_query('cg01vc_b', format('select public._cg01vc_race(%L, %L, %L, %L, 0)', c.b_sub, c.b_kind, v_order, c.b_arg));
      select r into v_a from dblink_get_result('cg01vc_a') as t(r text);
      perform 1 from dblink_get_result('cg01vc_a') as t(r text);
      select r into v_b from dblink_get_result('cg01vc_b') as t(r text);
      perform 1 from dblink_get_result('cg01vc_b') as t(r text);
      v_b_elapsed := extract(epoch from clock_timestamp() - v_t0);
      perform dblink_disconnect('cg01vc_a');
      perform dblink_disconnect('cg01vc_b');
      if v_b_elapsed < 1.0 then raise exception 'CAFE_GUEST_01V_CONCURRENCY: race % - B must have been blocked by A''s lock, but returned after % s (the sessions did not overlap)', c.n, v_b_elapsed; end if;

      if c.n = 1 then
        -- A paid and held; B (cancel) is refused because a payment now exists
        if (v_a::jsonb ->> 'ok')::boolean is not true or v_b <> 'ERR 22023 This order has a payment and cannot be cancelled.' then
          raise exception 'CAFE_GUEST_01V_CONCURRENCY: race 1 - the payment wins and the cancel is refused. a=% b=%', v_a, v_b;
        end if;
        if (select count(*) from commerce.service_order_payments where service_order_id = v_order) <> 1
           or (select payment_status from commerce.service_orders where id = v_order) <> 'paid'
           or (select status from commerce.service_orders where id = v_order) <> 'submitted'
           or (select count(*) from commerce.service_order_cancellations where service_order_id = v_order) <> 0 then
          raise exception 'CAFE_GUEST_01V_CONCURRENCY: race 1 - paid once, not cancelled, no audit row';
        end if;
      elsif c.n = 2 then
        -- A cancelled and held; B (pay) is refused because the order is cancelled
        if (v_a::jsonb ->> 'ok')::boolean is not true or v_b <> 'ERR 22023 This order cannot take a payment.' then
          raise exception 'CAFE_GUEST_01V_CONCURRENCY: race 2 - the cancel wins and the payment is refused. a=% b=%', v_a, v_b;
        end if;
        if (select count(*) from commerce.service_order_payments where service_order_id = v_order) <> 0
           or (select status from commerce.service_orders where id = v_order) <> 'cancelled'
           or (select count(*) from commerce.service_order_cancellations where service_order_id = v_order) <> 1 then
          raise exception 'CAFE_GUEST_01V_CONCURRENCY: race 2 - cancelled once, no payment, one audit row';
        end if;
      elsif c.n = 3 then
        -- two admins, two reasons: the first (holding) wins, the second is told it is already cancelled
        if (v_a::jsonb ->> 'ok')::boolean is not true or v_b <> 'ERR 22023 This order is already cancelled.' then
          raise exception 'CAFE_GUEST_01V_CONCURRENCY: race 3 - one admin wins, the other is refused. a=% b=%', v_a, v_b;
        end if;
        if (select count(*) from commerce.service_order_cancellations where service_order_id = v_order) <> 1
           or (select cancelled_by from commerce.service_order_cancellations where service_order_id = v_order) <> v_admin1
           or (select reason from commerce.service_order_cancellations where service_order_id = v_order) <> 'Reason from admin one' then
          raise exception 'CAFE_GUEST_01V_CONCURRENCY: race 3 - exactly one audit row, the winner''s';
        end if;
      else
        -- the same admin and reason twice: one audit row, the second call gets the original back as a replay
        if (v_a::jsonb ->> 'ok')::boolean is not true or (v_a::jsonb ->> 'replayed')::boolean
           or (v_b::jsonb ->> 'ok')::boolean is not true or (v_b::jsonb ->> 'replayed')::boolean is not true
           or (v_a::jsonb ->> 'cancelledAt') <> (v_b::jsonb ->> 'cancelledAt') then
          raise exception 'CAFE_GUEST_01V_CONCURRENCY: race 4 - the same cancel twice is one cancellation and a replay. a=% b=%', v_a, v_b;
        end if;
        if (select count(*) from commerce.service_order_cancellations where service_order_id = v_order) <> 1 then
          raise exception 'CAFE_GUEST_01V_CONCURRENCY: race 4 - exactly one audit row';
        end if;
      end if;
    end loop;
  end;
exception when others then
  begin perform dblink_disconnect('cg01vc_a'); exception when others then null; end;
  begin perform dblink_disconnect('cg01vc_b'); exception when others then null; end;
  -- recorded, not re-raised: a re-raise would roll this handler (and the cleanup below) back
  insert into public._cg01vc_ctx values ('failure', sqlerrm);
end
$race$;

-- always delete what this test committed, pass or fail
select public._cg01vc_cleanup();

do $verdict$
begin
  if exists (select 1 from public._cg01vc_ctx where k = 'failure') then
    raise exception '%', (select v from public._cg01vc_ctx where k = 'failure');
  end if;
end
$verdict$;
drop function public._cg01vc_race(uuid, text, uuid, text, numeric);
drop function public._cg01vc_create(uuid, text);
drop function public._cg01vc_cleanup();
drop table public._cg01vc_ctx;
drop extension dblink;

select 'CAFE-GUEST-01V cancel and payment concurrency passed' as result;
