-- CAFE-GUEST-01Q: REAL concurrency test for public.record_quick_solution_counter_payment().
--
-- Two genuinely concurrent database sessions (dblink, over loopback to THIS disposable cluster only) try to
-- pay the same order at the same moment. This cannot be rolled back like the other tests, because a second
-- session cannot see uncommitted data, so it COMMITS its own fixtures, runs the race, and then deletes every
-- row it created (also when an assertion fails). The harness afterwards checks the table row counts are back
-- to the baseline.
--
-- Race 1: staff member A starts paying with cash and HOLDS the order (the call sleeps 2 s before it commits);
--         staff member B then tries to pay the same order by card with a different key. B must block on the
--         order, then find it paid. Exactly one payment survives: A's cash payment.
-- Race 2: the same staff member and the same key from two sessions at once: one payment, and the second
--         caller receives that same payment as a replay.
--
-- Run only against the disposable local harness (it needs the OPPS access layer, like the other 01M+ tests).

\set ON_ERROR_STOP on

create extension if not exists dblink;

create table public._cg01qc_ctx (k text primary key, v text);

create function public._cg01qc_race(p_sub uuid, p_order uuid, p_method text, p_key text, p_hold numeric) returns text
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  v_result := public.record_quick_solution_counter_payment(p_order, p_method, p_key);
  perform pg_sleep(p_hold);
  execute 'reset role';
  return v_result::text;
end
$$;

create function public._cg01qc_create(p_sub uuid, p_key text) returns uuid
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

create function public._cg01qc_cleanup() returns void
language plpgsql
as $$
declare
  v_users uuid[] := array(select v::uuid from public._cg01qc_ctx where k in ('u1', 'u2'));
begin
  delete from commerce.service_order_payments where service_order_id in (select id from commerce.service_orders where created_by = any (v_users));
  delete from commerce.service_orders where created_by = any (v_users);
  delete from public.tenant_memberships where auth_user_id = any (v_users);
  delete from auth.users where id = any (v_users);
end
$$;

-- committed fixtures: two active Cafe members
do $fixtures$
declare
  v_suffix text := replace(gen_random_uuid()::text, '-', '');
  v_cafe uuid;
  v_u1 uuid := gen_random_uuid();
  v_u2 uuid := gen_random_uuid();
begin
  select t.id into v_cafe from public.tenants t where t.slug = 'quick-solution' and t.status = 'active';
  if v_cafe is null then raise exception 'CAFE_GUEST_01Q_CONCURRENCY_SETUP: the quick-solution tenant must exist'; end if;
  insert into public._cg01qc_ctx values ('cafe', v_cafe::text), ('suffix', v_suffix), ('u1', v_u1::text), ('u2', v_u2::text);
  insert into auth.users(id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_u1, 'authenticated', 'authenticated', 'cg01qc-a-' || v_suffix || '@disposable.test', now(), '{}'::jsonb, '{}'::jsonb, now(), now()),
         (v_u2, 'authenticated', 'authenticated', 'cg01qc-b-' || v_suffix || '@disposable.test', now(), '{}'::jsonb, '{}'::jsonb, now(), now());
  insert into public.tenant_memberships(tenant_id, auth_user_id, tenant_role, status)
  values (v_cafe, v_u1, 'member', 'active'), (v_cafe, v_u2, 'member', 'active');
end
$fixtures$;

-- the orders are created (and committed) BEFORE the race so the other sessions can see them
insert into public._cg01qc_ctx select 'o1', public._cg01qc_create((select v::uuid from public._cg01qc_ctx where k = 'u1'), 'cg01qc-' || (select v from public._cg01qc_ctx where k = 'suffix') || '-o1')::text;
insert into public._cg01qc_ctx select 'o2', public._cg01qc_create((select v::uuid from public._cg01qc_ctx where k = 'u1'), 'cg01qc-' || (select v from public._cg01qc_ctx where k = 'suffix') || '-o2')::text;

do $race$
declare
  v_suffix text := (select v from public._cg01qc_ctx where k = 'suffix');
  v_u1 uuid := (select v::uuid from public._cg01qc_ctx where k = 'u1');
  v_u2 uuid := (select v::uuid from public._cg01qc_ctx where k = 'u2');
  v_conn text := format('host=127.0.0.1 port=%s dbname=%s user=%s', current_setting('port'), current_database(), current_user);
  v_order uuid;
  v_a jsonb; v_b jsonb; v_t0 timestamptz; v_b_elapsed numeric;
  v_rows integer; v_ok integer;
  v_raw text;
begin
  -- ── race 1: two operators, two keys, two methods, one order ──
  v_order := (select v::uuid from public._cg01qc_ctx where k = 'o1');
  perform dblink_connect('cg01qc_a', v_conn);
  perform dblink_connect('cg01qc_b', v_conn);
  perform dblink_send_query('cg01qc_a', format('select public._cg01qc_race(%L, %L, ''cash'', %L, 2)', v_u1, v_order, 'cg01qc-' || v_suffix || '-a1'));
  perform pg_sleep(0.6);
  v_t0 := clock_timestamp();
  perform dblink_send_query('cg01qc_b', format('select public._cg01qc_race(%L, %L, ''card'', %L, 0)', v_u2, v_order, 'cg01qc-' || v_suffix || '-b1'));

  select r into v_raw from dblink_get_result('cg01qc_a') as t(r text);
  v_a := v_raw::jsonb;
  perform 1 from dblink_get_result('cg01qc_a') as t(r text);
  select r into v_raw from dblink_get_result('cg01qc_b') as t(r text);
  v_b := v_raw::jsonb;
  perform 1 from dblink_get_result('cg01qc_b') as t(r text);
  v_b_elapsed := extract(epoch from clock_timestamp() - v_t0);
  perform dblink_disconnect('cg01qc_a');
  perform dblink_disconnect('cg01qc_b');

  select count(*) into v_rows from commerce.service_order_payments where service_order_id = v_order;
  select count(*) into v_ok from unnest(array[v_a, v_b]) r where (r ->> 'ok')::boolean;
  if v_rows <> 1 or v_ok <> 1 then raise exception 'CAFE_GUEST_01Q_CONCURRENCY: exactly one of two concurrent full payments may succeed, got % payment row(s), a=% b=%', v_rows, v_a, v_b; end if;
  if not (v_a ->> 'ok')::boolean or v_a ->> 'method' <> 'cash' or (v_b ->> 'ok')::boolean or v_b ->> 'reason' <> 'already_paid' or v_b ->> 'paymentStatus' <> 'paid' then
    raise exception 'CAFE_GUEST_01Q_CONCURRENCY: A (first, holding the order) wins with cash; B sees already_paid. a=% b=%', v_a, v_b;
  end if;
  if v_b_elapsed < 1.0 then raise exception 'CAFE_GUEST_01Q_CONCURRENCY: B must have been blocked by A''s lock, but returned after % s (the sessions did not overlap)', v_b_elapsed; end if;
  if (select provider from commerce.service_order_payments where service_order_id = v_order) <> 'cash'
     or (select recorded_by from commerce.service_order_payments where service_order_id = v_order) <> v_u1
     or (select payment_status from commerce.service_orders where id = v_order) <> 'paid'
     or (select amount from commerce.service_order_payments where service_order_id = v_order) <> (select total_amount from commerce.service_orders where id = v_order) then
    raise exception 'CAFE_GUEST_01Q_CONCURRENCY: the surviving payment is A''s full cash payment and the order is paid once';
  end if;

  -- ── race 2: the SAME operator and the SAME key from two sessions at once ──
  v_order := (select v::uuid from public._cg01qc_ctx where k = 'o2');
  perform dblink_connect('cg01qc_a', v_conn);
  perform dblink_connect('cg01qc_b', v_conn);
  perform dblink_send_query('cg01qc_a', format('select public._cg01qc_race(%L, %L, ''card'', %L, 2)', v_u1, v_order, 'cg01qc-' || v_suffix || '-same'));
  perform pg_sleep(0.6);
  perform dblink_send_query('cg01qc_b', format('select public._cg01qc_race(%L, %L, ''card'', %L, 0)', v_u1, v_order, 'cg01qc-' || v_suffix || '-same'));
  select r into v_raw from dblink_get_result('cg01qc_a') as t(r text);
  v_a := v_raw::jsonb;
  perform 1 from dblink_get_result('cg01qc_a') as t(r text);
  select r into v_raw from dblink_get_result('cg01qc_b') as t(r text);
  v_b := v_raw::jsonb;
  perform 1 from dblink_get_result('cg01qc_b') as t(r text);
  perform dblink_disconnect('cg01qc_a');
  perform dblink_disconnect('cg01qc_b');
  select count(*) into v_rows from commerce.service_order_payments where service_order_id = v_order;
  if v_rows <> 1 or not (v_a ->> 'ok')::boolean or (v_a ->> 'replayed')::boolean or not (v_b ->> 'ok')::boolean or not (v_b ->> 'replayed')::boolean or v_a ->> 'paymentId' <> v_b ->> 'paymentId' then
    raise exception 'CAFE_GUEST_01Q_CONCURRENCY: the same key at once yields one payment; the second caller gets it back as a replay. rows=% a=% b=%', v_rows, v_a, v_b;
  end if;
exception when others then
  begin perform dblink_disconnect('cg01qc_a'); exception when others then null; end;
  begin perform dblink_disconnect('cg01qc_b'); exception when others then null; end;
  -- recorded, not re-raised: a re-raise would roll this handler (and the cleanup below) back
  insert into public._cg01qc_ctx values ('failure', sqlerrm);
end
$race$;

-- always delete what this test committed, pass or fail
select public._cg01qc_cleanup();

do $verdict$
begin
  if exists (select 1 from public._cg01qc_ctx where k = 'failure') then
    raise exception '%', (select v from public._cg01qc_ctx where k = 'failure');
  end if;
end
$verdict$;
drop function public._cg01qc_race(uuid, uuid, text, text, numeric);
drop function public._cg01qc_create(uuid, text);
drop function public._cg01qc_cleanup();
drop table public._cg01qc_ctx;
drop extension dblink;

select 'CAFE-GUEST-01Q counter payment concurrency passed' as result;
