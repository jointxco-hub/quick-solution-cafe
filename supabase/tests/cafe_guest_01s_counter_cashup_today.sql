-- CAFE-GUEST-01S: behavioral contract test for public.get_quick_solution_counter_cashup_today().
--
-- Run only against the disposable local harness (supabase/tests/harness/), which replays the migration history
-- INCLUDING the OPPS-owned access layer (public.has_tenant_capability, CAFE-ACCESS-01..03) and
--   20260926250000_cafe_guest_01s_counter_cashup_today_rpc.sql
-- The harness skips this test, visibly, when the OPPS access layer is absent. Orders are created and paid through the REAL
-- 01M / 01Q RPCs under real API roles; expected amounts are DERIVED from the server pricing path, never hard-coded. The day
-- boundary is tested with payments placed at exact instants around the Johannesburg midnight. Everything is enclosed by
-- BEGIN/ROLLBACK.

\set ON_ERROR_STOP on

begin;

-- ── test-only helpers ────────────────────────────────────────────────────
create function public._cg01s_setup(p_role text, p_sub uuid, p_email text) returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claims',
    case when p_sub is null then '{}'
         else jsonb_strip_nulls(jsonb_build_object('sub', p_sub, 'role', 'authenticated', 'email', p_email))::text end, true);
  execute format('set local role %I', p_role);
end
$$;

create function public._cg01s_try(p_role text, p_sub uuid, p_email text) returns text
language plpgsql
as $$
declare
  v_state text;
  v_message text;
begin
  perform public._cg01s_setup(p_role, p_sub, p_email);
  perform public.get_quick_solution_counter_cashup_today();
  execute 'reset role';
  return 'ok';
exception when others then
  get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
  execute 'reset role';
  return v_state || ' ' || v_message;
end
$$;

create function public._cg01s_cashup(p_sub uuid) returns jsonb
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform public._cg01s_setup('authenticated', p_sub, null);
  v_result := public.get_quick_solution_counter_cashup_today();
  execute 'reset role';
  return v_result;
end
$$;

create function public._cg01s_call(p_sub uuid, p_fn text, p_arg uuid default null) returns jsonb
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform public._cg01s_setup('authenticated', p_sub, null);
  if p_fn = 'list' then v_result := public.list_quick_solution_counter_orders_today();
  else v_result := public.get_quick_solution_counter_order(p_arg);
  end if;
  execute 'reset role';
  return v_result;
end
$$;

create function public._cg01s_create(p_sub uuid, p_key text, p_product text, p_config jsonb) returns uuid
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform public._cg01s_setup('authenticated', p_sub, null);
  v_result := public.create_quick_solution_counter_order(p_key, p_product, p_config);
  execute 'reset role';
  return (v_result ->> 'orderId')::uuid;
end
$$;

create function public._cg01s_pay(p_sub uuid, p_order uuid, p_method text, p_key text) returns jsonb
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform public._cg01s_setup('authenticated', p_sub, null);
  v_result := public.record_quick_solution_counter_payment(p_order, p_method, p_key);
  execute 'reset role';
  return v_result;
end
$$;

create function public._cg01s_mk(p_tenant uuid, p_channel text, p_total numeric, p_status text default 'submitted', p_pay text default 'unpaid') returns uuid
language plpgsql
as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into commerce.service_orders(id, tenant_id, order_number, customer_name, idempotency_key, channel, subtotal, total_amount, status, payment_status)
  values (v_id, p_tenant, 'CG01S-' || left(v_id::text, 8), 'CG01S direct', 'CG01S-KEY-' || v_id::text, p_channel, p_total, p_total, p_status, p_pay);
  return v_id;
end
$$;

create function public._cg01s_counts() returns text
language sql
as $$
  select (select count(*) from commerce.service_orders) || '/' || (select count(*) from commerce.service_order_items) || '/' || (select count(*) from commerce.service_order_payments)
$$;

grant execute on function public._cg01s_setup(text, uuid, text), public._cg01s_try(text, uuid, text), public._cg01s_cashup(uuid), public._cg01s_call(uuid, text, uuid),
  public._cg01s_create(uuid, text, text, jsonb), public._cg01s_pay(uuid, uuid, text, text), public._cg01s_mk(uuid, text, numeric, text, text),
  public._cg01s_counts() to anon, authenticated, service_role;

-- ═════════ contracts ═════════
do $contracts$
declare
  v_rpc regprocedure := to_regprocedure('public.get_quick_solution_counter_cashup_today()');
  v_def text;
  v_impl text;
begin
  if v_rpc is null then raise exception 'get_quick_solution_counter_cashup_today() must exist'; end if;
  if (select p.pronargs from pg_catalog.pg_proc p where p.oid = v_rpc) <> 0 then raise exception 'it takes no argument: no tenant, channel, date or actor'; end if;
  if pg_catalog.pg_get_function_result(v_rpc) <> 'jsonb' then raise exception 'it returns jsonb'; end if;
  if not (select p.prosecdef from pg_catalog.pg_proc p where p.oid = v_rpc) then raise exception 'it must be SECURITY DEFINER'; end if;
  if (select p.provolatile from pg_catalog.pg_proc p where p.oid = v_rpc) <> 's' then raise exception 'it only reads: STABLE'; end if;
  if not exists (select 1 from pg_catalog.pg_proc p, lateral pg_catalog.pg_options_to_table(p.proconfig) c where p.oid = v_rpc and c.option_name = 'search_path' and btrim(c.option_value, chr(34)) = '') then
    raise exception 'it must use an empty hardened search_path';
  end if;
  if exists (select 1 from pg_catalog.pg_proc p, lateral pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) acl where p.oid = v_rpc and acl.grantee = 0 and acl.privilege_type = 'EXECUTE') then
    raise exception 'it must not grant EXECUTE to PUBLIC';
  end if;
  if has_function_privilege('anon', v_rpc, 'EXECUTE') or has_function_privilege('service_role', v_rpc, 'EXECUTE') or not has_function_privilege('authenticated', v_rpc, 'EXECUTE') then
    raise exception 'authenticated only';
  end if;
  v_def := lower(pg_catalog.pg_get_functiondef(v_rpc));
  if v_def !~ 'has_tenant_capability\(v_tenant_id, ''cafe\.counter\.operate''\)' then raise exception 'it must require cafe.counter.operate'; end if;
  if v_def like '%cafe.operations.manage%' or v_def ~ '(is_app_admin|is_opps_staff|can_access_tenant)' then raise exception 'no manage capability and no app-admin / OPPS-staff bypass'; end if;
  if v_def !~ 't\.slug = ''quick-solution''' then raise exception 'canonical tenant'; end if;
  -- since 01U the rules live once, in the internal implementation both the today and the dated cash-up call
  if v_def !~ '_qs_counter_cashup\(v_tenant_id, \(select d\.business_date from commerce\._qs_counter_business_day\(now\(\)\) d\)\)' then raise exception 'today must call the shared implementation with the business date of now'; end if;
  v_impl := lower(pg_catalog.pg_get_functiondef(to_regprocedure('commerce._qs_counter_cashup(uuid,date)')));
  if v_impl !~ 'so\.channel = ''counter''' or v_impl !~ 'p\.tenant_id = p_tenant_id' then raise exception 'counter channel of the canonical tenant only'; end if;
  if v_impl !~ '_qs_counter_business_day_of\(p_date\)' then raise exception 'the day must come from the one business-day rule'; end if;
  if v_impl !~ 'p\.completed_at >= v_day\.day_start' or v_impl !~ 'p\.completed_at < v_day\.day_end' then raise exception 'takings are recognised by payment completion time, half-open'; end if;
  if v_impl !~ 'p\.status = ''completed''' or v_impl !~ 'pay\.provider in \(''cash'', ''card''\)' then raise exception 'only completed cash and card rows count as takings'; end if;
  if v_impl ~ '(idempotency_key|source_metadata|recorded_by|created_by|pricing_snapshot|pricing_definition|referenceprice|marginrate|suppliercost|auth\.jwt)' then raise exception 'no keys, actor, metadata or pricing may be read'; end if;
  if v_impl ~ '(insert into|update commerce|update public|delete from)' or v_def ~ '(insert into|update commerce|update public|delete from)' then raise exception 'it must write nothing'; end if;
end
$contracts$;

-- ═════════ fixtures ═════════
create table public._cg01s_ctx (k text primary key, v text);

do $fixtures$
declare
  v_suffix text := replace(gen_random_uuid()::text, '-', '');
  v_cafe uuid;
  v_other uuid := gen_random_uuid();
  u record;
begin
  select t.id into v_cafe from public.tenants t where t.slug = 'quick-solution' and t.status = 'active';
  if v_cafe is null then raise exception 'CAFE_GUEST_01S_TEST_SETUP: the quick-solution tenant must exist'; end if;
  insert into public._cg01s_ctx values ('suffix', v_suffix), ('cafe', v_cafe::text), ('other', v_other::text);
  insert into public.tenants(id, slug, name, status, settings) values (v_other, 'cg01s-other-' || left(v_suffix, 10), 'CG01S other cafe', 'active', '{}'::jsonb);
  insert into public.tenant_capabilities(tenant_id, capability_key, enabled) values (v_other, 'quick_solution', true);

  for u in select * from (values ('nomember'), ('member'), ('member2'), ('admin'), ('owner'), ('suspended'), ('otherowner'), ('appadmin'), ('oppsstaff')) as x(label) loop
    insert into public._cg01s_ctx values ('u_' || u.label, gen_random_uuid()::text);
    insert into auth.users(id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values ((select v::uuid from public._cg01s_ctx where k = 'u_' || u.label), 'authenticated', 'authenticated', 'cg01s-' || u.label || '-' || v_suffix || '@disposable.test', now(), '{}'::jsonb, '{}'::jsonb, now(), now());
  end loop;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', (select v from public._cg01s_ctx where k = 'u_appadmin'), 'role', 'authenticated', 'email', 'jointx.co@gmail.com')::text, true);
  insert into public.users(auth_user_id, user_email, full_name, role, is_active)
  values ((select v::uuid from public._cg01s_ctx where k = 'u_appadmin'), 'cg01s-appadmin-' || v_suffix || '@disposable.test', 'CG01S app admin', 'admin', true),
         ((select v::uuid from public._cg01s_ctx where k = 'u_oppsstaff'), 'cg01s-oppsstaff-' || v_suffix || '@disposable.test', 'CG01S OPPS staff', 'user', true);
  perform set_config('request.jwt.claims', '{}', true);
  if lower(coalesce(auth.jwt() ->> 'email', '')) <> '' then raise exception 'CAFE_GUEST_01S_TEST_SETUP: the temporary approved-owner claim must be cleared'; end if;

  insert into public.tenant_memberships(tenant_id, auth_user_id, tenant_role, status)
  select v_cafe, (select v::uuid from public._cg01s_ctx where k = 'u_' || m.label), m.role, m.status
  from (values ('member', 'member', 'active'), ('member2', 'member', 'active'), ('admin', 'admin', 'active'), ('owner', 'owner', 'active'), ('suspended', 'member', 'suspended')) as m(label, role, status);
  insert into public.tenant_memberships(tenant_id, auth_user_id, tenant_role, status)
  values (v_other, (select v::uuid from public._cg01s_ctx where k = 'u_otherowner'), 'owner', 'active');
  if exists (select 1 from public.tenant_memberships m where m.tenant_id = v_cafe and m.auth_user_id in
     ((select v::uuid from public._cg01s_ctx where k = 'u_appadmin'), (select v::uuid from public._cg01s_ctx where k = 'u_oppsstaff'))) then
    raise exception 'CAFE_GUEST_01S_TEST_SETUP: the app-admin and OPPS-staff fixtures must have no Cafe membership';
  end if;
end
$fixtures$;

-- ═════════ access, module and tenant state ═════════
do $access$
declare
  c_signin constant text := '42501 Staff sign-in is required.';
  c_denied constant text := '42501 You do not have access to the Quick Solution counter.';
  c_no_tenant constant text := '22023 Quick Solution tenant was not found.';
  c_no_module constant text := '22023 Quick Solution counter is not active.';
  v_cafe uuid := (select v::uuid from public._cg01s_ctx where k = 'cafe');
  u_nomember uuid := (select v::uuid from public._cg01s_ctx where k = 'u_nomember');
  u_member uuid := (select v::uuid from public._cg01s_ctx where k = 'u_member');
  u_admin uuid := (select v::uuid from public._cg01s_ctx where k = 'u_admin');
  u_owner uuid := (select v::uuid from public._cg01s_ctx where k = 'u_owner');
  u_suspended uuid := (select v::uuid from public._cg01s_ctx where k = 'u_suspended');
  u_otherowner uuid := (select v::uuid from public._cg01s_ctx where k = 'u_otherowner');
  u_appadmin uuid := (select v::uuid from public._cg01s_ctx where k = 'u_appadmin');
  u_oppsstaff uuid := (select v::uuid from public._cg01s_ctx where k = 'u_oppsstaff');
  v_labels text[]; v_subs uuid[]; v_emails text[]; v_expect text[];
  i integer; v_got text; v_state text; v_before text := public._cg01s_counts();
  v_module public.tenant_capabilities;
begin
  v_labels := array['anonymous', 'authenticated non-member', 'active member', 'active admin', 'active owner', 'suspended member',
                    'owner of a FOREIGN tenant', 'app admin with no Cafe membership', 'app admin with the approved-owner email', 'OPPS staff with no Cafe membership']::text[];
  v_subs := array[null, u_nomember, u_member, u_admin, u_owner, u_suspended, u_otherowner, u_appadmin, u_appadmin, u_oppsstaff]::uuid[];
  v_emails := array[null, null, null, null, null, null, null, null, 'jointx.co@gmail.com', null]::text[];
  v_expect := array[c_signin, c_denied, 'ok', 'ok', 'ok', c_denied, c_denied, c_denied, c_denied, c_denied]::text[];
  for i in 1 .. array_length(v_labels, 1) loop
    v_got := public._cg01s_try('authenticated', v_subs[i], v_emails[i]);
    if v_got is distinct from v_expect[i] then raise exception 'CAFE_GUEST_01S: access for "%" expected "%" but got "%"', v_labels[i], v_expect[i], v_got; end if;
  end loop;
  foreach v_state in array array['anon', 'service_role'] loop
    if public._cg01s_try(v_state, u_owner, null) not like '42501 permission denied for function get_quick_solution_counter_cashup_today%' then raise exception 'CAFE_GUEST_01S: % must be refused at the ACL', v_state; end if;
  end loop;
  select * into v_module from public.tenant_capabilities tc where tc.tenant_id = v_cafe and tc.capability_key = 'quick_solution';
  update public.tenant_capabilities set enabled = false where id = v_module.id;
  if public._cg01s_try('authenticated', u_member, null) is distinct from c_no_module or public._cg01s_try('authenticated', u_owner, null) is distinct from c_no_module then raise exception 'CAFE_GUEST_01S: a disabled module denies'; end if;
  if public._cg01s_try('authenticated', u_nomember, null) is distinct from c_denied then raise exception 'CAFE_GUEST_01S: authorization comes before the module check'; end if;
  update public.tenant_capabilities set enabled = true where id = v_module.id;
  foreach v_state in array array['suspended', 'archived'] loop
    update public.tenants set status = v_state where id = v_cafe;
    if public._cg01s_try('authenticated', u_member, null) is distinct from c_no_tenant then raise exception 'CAFE_GUEST_01S: a % tenant fails closed', v_state; end if;
  end loop;
  update public.tenants set status = 'active' where id = v_cafe;
  update public.tenant_memberships set status = 'suspended' where tenant_id = v_cafe and auth_user_id = u_admin;
  if public._cg01s_try('authenticated', u_admin, null) is distinct from c_denied then raise exception 'CAFE_GUEST_01S: a just-suspended admin is denied'; end if;
  update public.tenant_memberships set status = 'active' where tenant_id = v_cafe and auth_user_id = u_admin;
  if public._cg01s_counts() is distinct from v_before then raise exception 'CAFE_GUEST_01S: reading, allowed or denied, writes nothing'; end if;
end
$access$;

-- ═════════ an empty day ═════════
do $empty$
declare
  u_member uuid := (select v::uuid from public._cg01s_ctx where k = 'u_member');
  v_r jsonb;
begin
  v_r := public._cg01s_cashup(u_member);
  if v_r -> 'takings' -> 'cash' <> '{"count": 0, "amount": 0}'::jsonb or v_r -> 'takings' -> 'card' <> '{"count": 0, "amount": 0}'::jsonb or v_r -> 'takings' -> 'total' <> '{"count": 0, "amount": 0}'::jsonb
     or v_r -> 'payments' <> '[]'::jsonb or v_r -> 'unpaid' <> '{"count": 0, "amount": 0, "orders": []}'::jsonb or v_r -> 'otherMethods' <> '{"count": 0, "amount": 0}'::jsonb
     or v_r -> 'orders' <> '{"createdToday": 0, "paidToday": 0, "unpaidToday": 0}'::jsonb then
    raise exception 'CAFE_GUEST_01S: a day with no sales is all zeros and empty lists, got %', v_r;
  end if;
  if v_r ->> 'timezone' <> 'Africa/Johannesburg' or (v_r ->> 'businessDate')::date <> (select business_date from commerce._qs_counter_business_day(now())) then raise exception 'CAFE_GUEST_01S: the response names the business day'; end if;
end
$empty$;

-- ═════════ totals, the day boundary, exclusions and privacy ═════════
do $totals$
declare
  v_suffix text := (select v from public._cg01s_ctx where k = 'suffix');
  v_cafe uuid := (select v::uuid from public._cg01s_ctx where k = 'cafe');
  v_other uuid := (select v::uuid from public._cg01s_ctx where k = 'other');
  u_member uuid := (select v::uuid from public._cg01s_ctx where k = 'u_member');
  u_member2 uuid := (select v::uuid from public._cg01s_ctx where k = 'u_member2');
  u_admin uuid := (select v::uuid from public._cg01s_ctx where k = 'u_admin');
  u_owner uuid := (select v::uuid from public._cg01s_ctx where k = 'u_owner');
  v_day record;
  v_marker constant text := 'CG01S-SECRET';
  v_a uuid; v_b uuid; v_c uuid; v_d uuid; v_e uuid; v_g uuid; v_h uuid; v_i uuid; v_j uuid; v_k uuid;
  v_y uuid; v_t uuid; v_m1 uuid; v_m2 uuid; v_m3 uuid; v_m4 uuid;
  v_price numeric;
  v_cash numeric := 0; v_card numeric := 0; v_cash_n integer := 0; v_card_n integer := 0;
  v_r jsonb; v_row jsonb; v_text text; v_counts_before text; n integer; v_sum numeric;
  v_ids uuid[];
begin
  select * into v_day from commerce._qs_counter_business_day(now());

  -- orders created and paid through the REAL RPCs; each expected amount comes from the server pricing path
  v_a := public._cg01s_create(u_member, 'cg01s-' || v_suffix || '-a', 'scan', '{"units":4}');
  v_b := public._cg01s_create(u_member, 'cg01s-' || v_suffix || '-b', 'a4-lamination', '{"units":3}');
  v_c := public._cg01s_create(u_member2, 'cg01s-' || v_suffix || '-c', 'a3-lamination', '{"units":2}');
  v_d := public._cg01s_create(u_member2, 'cg01s-' || v_suffix || '-d', 'scan', '{"units":9}');
  v_e := public._cg01s_create(u_member, 'cg01s-' || v_suffix || '-e', 'scan', '{"units":2}');
  v_g := public._cg01s_create(u_member, 'cg01s-' || v_suffix || '-g', 'a4-lamination', '{"units":1}');
  perform public._cg01s_pay(u_member2, v_a, 'cash', 'cg01s-' || v_suffix || '-pa');
  perform public._cg01s_pay(u_admin, v_b, 'card', 'cg01s-' || v_suffix || '-pb');
  perform public._cg01s_pay(u_owner, v_c, 'cash', 'cg01s-' || v_suffix || '-pc');
  perform public._cg01s_pay(u_member, v_d, 'card', 'cg01s-' || v_suffix || '-pd');
  v_cash := (select amount from commerce.service_order_payments where service_order_id = v_a) + (select amount from commerce.service_order_payments where service_order_id = v_c);
  v_card := (select amount from commerce.service_order_payments where service_order_id = v_b) + (select amount from commerce.service_order_payments where service_order_id = v_d);
  -- the amounts really are the server prices
  if (select amount from commerce.service_order_payments where service_order_id = v_a) <> (commerce.qs_calculate_price(v_cafe, 'scan', '{"units":4}') ->> 'total')::numeric
     or (select amount from commerce.service_order_payments where service_order_id = v_c) <> (commerce.qs_calculate_price(v_cafe, 'a3-lamination', '{"units":2}') ->> 'total')::numeric
     or v_cash + v_card <= 0 then
    raise exception 'CAFE_GUEST_01S: the payments are the server prices';
  end if;
  v_cash_n := 2; v_card_n := 2;

  -- unpaid: two counter orders that are still unpaid; a pending and a failed gateway attempt is NOT money received
  insert into commerce.service_order_payments(tenant_id, service_order_id, provider, status, amount) values (v_cafe, v_g, 'payfast', 'pending', 15);
  insert into commerce.service_order_payments(tenant_id, service_order_id, provider, status, amount) values (v_cafe, v_g, 'payfast', 'failed', 15);
  insert into commerce.service_order_payments(tenant_id, service_order_id, provider, status, amount) values (v_cafe, v_g, 'payfast', 'cancelled', 15);
  -- a cancelled unpaid order is neither takings nor outstanding
  v_j := public._cg01s_mk(v_cafe, 'counter', 99, 'cancelled', 'unpaid');
  -- excluded by scope: a storefront order and another tenant's counter order, each with a completed cash payment today
  v_h := public._cg01s_mk(v_cafe, 'storefront', 500, 'submitted', 'paid');
  insert into commerce.service_order_payments(tenant_id, service_order_id, provider, status, amount, completed_at, recorded_by, idempotency_key) values (v_cafe, v_h, 'cash', 'completed', 500, now(), u_member, 'cg01s-h-' || v_suffix);
  v_i := public._cg01s_mk(v_other, 'counter', 700, 'submitted', 'paid');
  insert into commerce.service_order_payments(tenant_id, service_order_id, provider, status, amount, completed_at, recorded_by, idempotency_key) values (v_other, v_i, 'cash', 'completed', 700, now(), u_member, 'cg01s-i-' || v_suffix);
  -- a completed payment of another provider on a counter order: reported apart, never mixed into Cash or Card
  v_k := public._cg01s_mk(v_cafe, 'counter', 10, 'submitted', 'paid');
  insert into commerce.service_order_payments(tenant_id, service_order_id, provider, status, amount, completed_at) values (v_cafe, v_k, 'payfast', 'completed', 10, now());

  -- the day boundary and the payment-vs-order date: real orders paid through the RPC, then placed at exact instants
  v_y := public._cg01s_create(u_member, 'cg01s-' || v_suffix || '-y', 'scan', '{"units":5}');
  update commerce.service_orders set created_at = v_day.day_start - interval '12 hours' where id = v_y;
  perform public._cg01s_pay(u_member, v_y, 'cash', 'cg01s-' || v_suffix || '-py');             -- created yesterday, paid today: TODAY's takings
  v_t := public._cg01s_create(u_member, 'cg01s-' || v_suffix || '-t', 'scan', '{"units":6}');
  perform public._cg01s_pay(u_member, v_t, 'cash', 'cg01s-' || v_suffix || '-pt');
  update commerce.service_order_payments set completed_at = v_day.day_end + interval '1 hour' where service_order_id = v_t;   -- created today, paid tomorrow: NOT today
  v_m1 := public._cg01s_create(u_member, 'cg01s-' || v_suffix || '-m1', 'scan', '{"units":1}');
  v_m2 := public._cg01s_create(u_member, 'cg01s-' || v_suffix || '-m2', 'scan', '{"units":1}');
  v_m3 := public._cg01s_create(u_member, 'cg01s-' || v_suffix || '-m3', 'scan', '{"units":1}');
  v_m4 := public._cg01s_create(u_member, 'cg01s-' || v_suffix || '-m4', 'scan', '{"units":1}');
  perform public._cg01s_pay(u_member, v_m1, 'card', 'cg01s-' || v_suffix || '-pm1');
  perform public._cg01s_pay(u_member, v_m2, 'card', 'cg01s-' || v_suffix || '-pm2');
  perform public._cg01s_pay(u_member, v_m3, 'card', 'cg01s-' || v_suffix || '-pm3');
  perform public._cg01s_pay(u_member, v_m4, 'card', 'cg01s-' || v_suffix || '-pm4');
  update commerce.service_order_payments set completed_at = v_day.day_start where service_order_id = v_m1;                              -- exactly local midnight: the new day, IN
  update commerce.service_order_payments set completed_at = v_day.day_start - interval '1 microsecond' where service_order_id = v_m2; -- one microsecond earlier: yesterday, OUT
  update commerce.service_order_payments set completed_at = v_day.day_end - interval '1 microsecond' where service_order_id = v_m3;   -- last microsecond of today, IN
  update commerce.service_order_payments set completed_at = v_day.day_end where service_order_id = v_m4;                              -- next local midnight: tomorrow, OUT

  update commerce.service_orders set source_metadata = source_metadata || jsonb_build_object('secret', v_marker) where id in (v_a, v_b, v_e);
  v_counts_before := public._cg01s_counts();
  v_r := public._cg01s_cashup(u_member);
  if public._cg01s_counts() is distinct from v_counts_before then raise exception 'CAFE_GUEST_01S: the cash-up wrote something'; end if;

  -- included: A, B, C, D (today), Y (created yesterday), M1 and M3 (boundaries)
  v_ids := array[v_a, v_b, v_c, v_d, v_y, v_m1, v_m3];
  select count(*) into n from jsonb_array_elements(v_r -> 'payments');
  if n <> 7 then raise exception 'CAFE_GUEST_01S: exactly 7 payments belong to today, got % (%)', n, v_r -> 'payments'; end if;
  foreach v_h in array v_ids loop
    if not exists (select 1 from jsonb_array_elements(v_r -> 'payments') p where p ->> 'orderId' = v_h::text) then raise exception 'CAFE_GUEST_01S: order % must be in today''s payments', v_h; end if;
  end loop;
  foreach v_h in array array[v_t, v_m2, v_m4, v_e, v_g, v_j, v_k]::uuid[] loop
    if exists (select 1 from jsonb_array_elements(v_r -> 'payments') p where p ->> 'orderId' = v_h::text) then raise exception 'CAFE_GUEST_01S: order % must NOT be in today''s takings', v_h; end if;
  end loop;
  if exists (select 1 from jsonb_array_elements(v_r -> 'payments') p where p ->> 'orderNumber' like 'CG01S-%') then raise exception 'CAFE_GUEST_01S: the storefront and the foreign order are excluded'; end if;

  -- totals are exactly what the rows add up to, by method
  select coalesce(sum((p ->> 'amount')::numeric) filter (where p ->> 'method' = 'cash'), 0), count(*) filter (where p ->> 'method' = 'cash') into v_sum, n from jsonb_array_elements(v_r -> 'payments') p;
  if (v_r -> 'takings' -> 'cash' ->> 'amount')::numeric <> v_sum or (v_r -> 'takings' -> 'cash' ->> 'count')::integer <> n then raise exception 'CAFE_GUEST_01S: the Cash total must equal its rows (% / %)', v_sum, n; end if;
  v_cash := (select amount from commerce.service_order_payments where service_order_id = v_a) + (select amount from commerce.service_order_payments where service_order_id = v_c) + (select amount from commerce.service_order_payments where service_order_id = v_y);
  if (v_r -> 'takings' -> 'cash' ->> 'amount')::numeric <> v_cash or (v_r -> 'takings' -> 'cash' ->> 'count')::integer <> 3 then raise exception 'CAFE_GUEST_01S: Cash = A + C + Y (the order made yesterday, paid today): expected % / 3, got %', v_cash, v_r -> 'takings' -> 'cash'; end if;
  select coalesce(sum((p ->> 'amount')::numeric) filter (where p ->> 'method' = 'card'), 0), count(*) filter (where p ->> 'method' = 'card') into v_sum, n from jsonb_array_elements(v_r -> 'payments') p;
  if (v_r -> 'takings' -> 'card' ->> 'amount')::numeric <> v_sum or (v_r -> 'takings' -> 'card' ->> 'count')::integer <> n then raise exception 'CAFE_GUEST_01S: the Card total must equal its rows'; end if;
  v_card := (select amount from commerce.service_order_payments where service_order_id = v_b) + (select amount from commerce.service_order_payments where service_order_id = v_d) + (select amount from commerce.service_order_payments where service_order_id = v_m1) + (select amount from commerce.service_order_payments where service_order_id = v_m3);
  if (v_r -> 'takings' -> 'card' ->> 'amount')::numeric <> v_card or (v_r -> 'takings' -> 'card' ->> 'count')::integer <> 4 then raise exception 'CAFE_GUEST_01S: Card = B + D + M1 + M3: expected % / 4, got %', v_card, v_r -> 'takings' -> 'card'; end if;
  if (v_r -> 'takings' -> 'total' ->> 'amount')::numeric <> v_cash + v_card or (v_r -> 'takings' -> 'total' ->> 'count')::integer <> 7
     or (v_r -> 'takings' -> 'total' ->> 'amount')::numeric <> (select sum((p ->> 'amount')::numeric) from jsonb_array_elements(v_r -> 'payments') p) then
    raise exception 'CAFE_GUEST_01S: the combined total is Cash + Card and equals every returned row, got %', v_r -> 'takings' -> 'total';
  end if;
  if v_cash <= 0 or v_card <= 0 then raise exception 'CAFE_GUEST_01S: the test must move real money'; end if;

  -- other-method payments are apart, unpaid is not takings, pending/failed/cancelled rows are nothing
  if v_r -> 'otherMethods' <> '{"count": 1, "amount": 10}'::jsonb then raise exception 'CAFE_GUEST_01S: a completed gateway payment is reported apart, got %', v_r -> 'otherMethods'; end if;
  v_price := (commerce.qs_calculate_price(v_cafe, 'scan', '{"units":2}') ->> 'total')::numeric + (commerce.qs_calculate_price(v_cafe, 'a4-lamination', '{"units":1}') ->> 'total')::numeric;
  if (v_r -> 'unpaid' ->> 'count')::integer <> 2 or (v_r -> 'unpaid' ->> 'amount')::numeric <> v_price or jsonb_array_length(v_r -> 'unpaid' -> 'orders') <> 2
     or (v_r -> 'orders' ->> 'unpaidToday')::integer <> 2 then
    raise exception 'CAFE_GUEST_01S: unpaid = the two unpaid counter orders (E, G) with % outstanding, got %', v_price, v_r -> 'unpaid';
  end if;
  if (v_r -> 'takings' -> 'total' ->> 'amount')::numeric <> v_cash + v_card then raise exception 'CAFE_GUEST_01S: unpaid is never added to takings'; end if;
  -- orders: created today (A B C D E G J K T M1..M4 = 13; not Y, not the storefront or foreign order), paid today (7 distinct orders)
  if (v_r -> 'orders' ->> 'createdToday')::integer <> 13 or (v_r -> 'orders' ->> 'paidToday')::integer <> 7 then raise exception 'CAFE_GUEST_01S: order counts wrong: %', v_r -> 'orders'; end if;

  -- each payment row: the pinned safe keys, the method, the order it settles
  select p into v_row from jsonb_array_elements(v_r -> 'payments') p where p ->> 'orderId' = v_y::text;
  if (select array_agg(k order by k) from jsonb_object_keys(v_row) k) is distinct from array['amount', 'customerName', 'method', 'orderCreatedAt', 'orderId', 'orderNumber', 'orderTotal', 'paidAt', 'paymentId'] then
    raise exception 'CAFE_GUEST_01S: a payment row has exactly the pinned keys, got %', (select array_agg(k order by k) from jsonb_object_keys(v_row) k);
  end if;
  if v_row ->> 'method' <> 'cash' or (v_row ->> 'orderCreatedAt')::timestamptz >= v_day.day_start or (v_row ->> 'paidAt')::timestamptz < v_day.day_start or (v_row ->> 'amount')::numeric <> (v_row ->> 'orderTotal')::numeric then
    raise exception 'CAFE_GUEST_01S: the yesterday order shows created yesterday and paid today: %', v_row;
  end if;
  -- newest payment first
  if (select array_agg((p ->> 'paidAt')::timestamptz order by ord) from jsonb_array_elements(v_r -> 'payments') with ordinality as t(p, ord)) is distinct from
     (select array_agg((p ->> 'paidAt')::timestamptz order by (p ->> 'paidAt')::timestamptz desc, p ->> 'paymentId' desc) from jsonb_array_elements(v_r -> 'payments') p) then
    raise exception 'CAFE_GUEST_01S: payments are newest first';
  end if;
  select o into v_row from jsonb_array_elements(v_r -> 'unpaid' -> 'orders') o limit 1;
  if (select array_agg(k order by k) from jsonb_object_keys(v_row) k) is distinct from array['createdAt', 'customerEmail', 'customerName', 'customerPhone', 'items', 'orderId', 'orderNumber', 'outstanding', 'paymentStatus', 'status', 'totalAmount'] then
    raise exception 'CAFE_GUEST_01S: an unpaid order has the Today''s Orders fields plus outstanding, got %', (select array_agg(k order by k) from jsonb_object_keys(v_row) k);
  end if;

  -- privacy
  if (select array_agg(k order by k) from jsonb_object_keys(v_r) k) is distinct from array['businessDate', 'orders', 'otherMethods', 'payments', 'takings', 'timezone', 'unpaid'] then raise exception 'CAFE_GUEST_01S: the response has the pinned top-level keys'; end if;
  v_text := lower(v_r::text);
  if v_text like '%' || lower(v_marker) || '%' or v_text like '%cg01s-' || lower(v_suffix) || '%' or v_text like '%counter-payment%' or v_text like '%counter:%'
     or v_text like '%' || lower(u_member::text) || '%' or v_text like '%' || lower(u_member2::text) || '%' or v_text like '%' || lower(u_admin::text) || '%' or v_text like '%' || lower(u_owner::text) || '%'
     or v_text like '%' || lower(v_cafe::text) || '%' or v_text like '%' || lower(v_other::text) || '%'
     or v_text ~ '(idempotency|recorded_by|recordedby|created_by|createdby|source_metadata|sourcemetadata|pricing_snapshot|pricingsnapshot|pricing_definition|supplier|margin|tenant_id|tenantid)' then
    raise exception 'CAFE_GUEST_01S: no key, actor, source metadata, pricing or tenant id in the cash-up';
  end if;

  -- regression: Today's Orders, the order detail and the receipt data are unchanged and agree with the cash-up
  if jsonb_array_length(public._cg01s_call(u_member, 'list') -> 'orders') <> 13 then raise exception 'CAFE_GUEST_01S: Today''s Orders lists the same 13 counter orders created today'; end if;
  v_row := public._cg01s_call(u_member, 'detail', v_a);
  if v_row ->> 'paymentStatus' <> 'paid' or (v_row ->> 'outstanding')::numeric <> 0 or jsonb_array_length(v_row -> 'payments') <> 1 or v_row -> 'payments' -> 0 ->> 'method' <> 'cash'
     or (select array_agg(k order by k) from jsonb_object_keys(v_row) k) is distinct from array['amountPaid', 'createdAt', 'customerEmail', 'customerName', 'customerPhone', 'fulfilmentFee', 'items', 'orderId', 'orderNumber', 'outstanding', 'paymentAllowed', 'paymentStatus', 'payments', 'status', 'subtotal', 'totalAmount'] then
    raise exception 'CAFE_GUEST_01S: the order detail is unchanged, got %', v_row;
  end if;
  if (select (p ->> 'amount')::numeric from jsonb_array_elements(v_r -> 'payments') p where p ->> 'orderId' = v_a::text) <> (v_row -> 'payments' -> 0 ->> 'amount')::numeric then raise exception 'CAFE_GUEST_01S: the cash-up and the detail agree on the payment'; end if;
  if public._cg01s_counts() is distinct from v_counts_before then raise exception 'CAFE_GUEST_01S: reading wrote rows'; end if;

  -- every member, admin and owner sees the same figures
  foreach v_h in array array[u_member2, u_admin, u_owner]::uuid[] loop
    if public._cg01s_cashup(v_h) is distinct from v_r then raise exception 'CAFE_GUEST_01S: every counter user sees the same cash-up'; end if;
  end loop;
end
$totals$;

-- ═════════ moving the money out of today moves the totals ═════════
do $shift$
declare
  u_member uuid := (select v::uuid from public._cg01s_ctx where k = 'u_member');
  v_cafe uuid := (select v::uuid from public._cg01s_ctx where k = 'cafe');
  v_r jsonb;
begin
  update commerce.service_order_payments set completed_at = completed_at - interval '3 days' where tenant_id = v_cafe and provider in ('cash', 'card');
  v_r := public._cg01s_cashup(u_member);
  if v_r -> 'takings' -> 'total' <> '{"count": 0, "amount": 0}'::jsonb or v_r -> 'payments' <> '[]'::jsonb then raise exception 'CAFE_GUEST_01S: with every payment moved to earlier days today has no takings, got %', v_r -> 'takings'; end if;
  if (v_r -> 'orders' ->> 'paidToday')::integer <> 0 or (v_r -> 'unpaid' ->> 'count')::integer <> 2 then raise exception 'CAFE_GUEST_01S: the unpaid orders are unaffected'; end if;
end
$shift$;

rollback;
select 'CAFE-GUEST-01S counter cash-up today RPC contracts passed' as result;
