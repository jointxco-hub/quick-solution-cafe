-- CAFE-GUEST-01T: behavioral contract test for public.list_quick_solution_unpaid_counter_orders().
--
-- Run only against the disposable local harness (supabase/tests/harness/), which replays the migration history INCLUDING the
-- OPPS-owned access layer (public.has_tenant_capability, CAFE-ACCESS-01..03) and
--   20260926260000_cafe_guest_01t_unpaid_counter_orders_rpc.sql
-- The harness skips this test, visibly, when the OPPS access layer is absent. Orders are created and paid through the REAL 01M / 01Q
-- RPCs under real API roles; older orders are made by moving created_at of a real order. Everything is enclosed by BEGIN/ROLLBACK.

\set ON_ERROR_STOP on

begin;

-- ── test-only helpers ────────────────────────────────────────────────────
create function public._cg01t_setup(p_role text, p_sub uuid, p_email text) returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claims',
    case when p_sub is null then '{}'
         else jsonb_strip_nulls(jsonb_build_object('sub', p_sub, 'role', 'authenticated', 'email', p_email))::text end, true);
  execute format('set local role %I', p_role);
end
$$;

create function public._cg01t_try(p_role text, p_sub uuid, p_email text) returns text
language plpgsql
as $$
declare
  v_state text;
  v_message text;
begin
  perform public._cg01t_setup(p_role, p_sub, p_email);
  perform public.list_quick_solution_unpaid_counter_orders();
  execute 'reset role';
  return 'ok';
exception when others then
  get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
  execute 'reset role';
  return v_state || ' ' || v_message;
end
$$;

create function public._cg01t_call(p_sub uuid, p_fn text, p_arg uuid default null) returns jsonb
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform public._cg01t_setup('authenticated', p_sub, null);
  if p_fn = 'unpaid' then v_result := public.list_quick_solution_unpaid_counter_orders();
  elsif p_fn = 'today' then v_result := public.list_quick_solution_counter_orders_today();
  elsif p_fn = 'cashup' then v_result := public.get_quick_solution_counter_cashup_today();
  else v_result := public.get_quick_solution_counter_order(p_arg);
  end if;
  execute 'reset role';
  return v_result;
end
$$;

create function public._cg01t_create(p_sub uuid, p_key text, p_product text, p_config jsonb) returns uuid
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform public._cg01t_setup('authenticated', p_sub, null);
  v_result := public.create_quick_solution_counter_order(p_key, p_product, p_config);
  execute 'reset role';
  return (v_result ->> 'orderId')::uuid;
end
$$;

create function public._cg01t_pay(p_sub uuid, p_order uuid, p_method text, p_key text) returns jsonb
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform public._cg01t_setup('authenticated', p_sub, null);
  v_result := public.record_quick_solution_counter_payment(p_order, p_method, p_key);
  execute 'reset role';
  return v_result;
end
$$;

create function public._cg01t_mk(p_tenant uuid, p_channel text, p_total numeric, p_status text default 'submitted', p_pay text default 'unpaid') returns uuid
language plpgsql
as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into commerce.service_orders(id, tenant_id, order_number, customer_name, idempotency_key, channel, subtotal, total_amount, status, payment_status)
  values (v_id, p_tenant, 'CG01T-' || left(v_id::text, 8), 'CG01T direct', 'CG01T-KEY-' || v_id::text, p_channel, p_total, p_total, p_status, p_pay);
  return v_id;
end
$$;

create function public._cg01t_counts() returns text
language sql
as $$
  select (select count(*) from commerce.service_orders) || '/' || (select count(*) from commerce.service_order_items) || '/' || (select count(*) from commerce.service_order_payments)
$$;

grant execute on function public._cg01t_setup(text, uuid, text), public._cg01t_try(text, uuid, text), public._cg01t_call(uuid, text, uuid),
  public._cg01t_create(uuid, text, text, jsonb), public._cg01t_pay(uuid, uuid, text, text), public._cg01t_mk(uuid, text, numeric, text, text),
  public._cg01t_counts() to anon, authenticated, service_role;

-- ═════════ contracts ═════════
do $contracts$
declare
  v_rpc regprocedure := to_regprocedure('public.list_quick_solution_unpaid_counter_orders()');
  v_def text;
begin
  if v_rpc is null then raise exception 'list_quick_solution_unpaid_counter_orders() must exist'; end if;
  if (select p.pronargs from pg_catalog.pg_proc p where p.oid = v_rpc) <> 0 then raise exception 'it takes no argument: no tenant, channel, creator or date'; end if;
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
  if v_def !~ 't\.slug = ''quick-solution''' or v_def !~ 'so\.channel = ''counter''' or v_def !~ 'so\.tenant_id = v_tenant_id' then raise exception 'canonical tenant, counter channel only'; end if;
  if v_def !~ '_qs_order_amount_paid\(so\.id\)' or v_def !~ 'o\.outstanding > 0' then raise exception 'unpaid means outstanding by the completed ledger, not just the stored status'; end if;
  if v_def !~ 'so\.status not in \(''draft'', ''cancelled''\)' or v_def !~ 'so\.payment_status in \(''unpaid'', ''pending'', ''failed''\)' then raise exception 'status and payment-status rules'; end if;
  if v_def !~ '_qs_counter_business_day\(so\.created_at\)' or v_def !~ '_qs_counter_business_day\(now\(\)\)' then raise exception 'ages come from the one business-day rule'; end if;
  if v_def !~ 'order by o\.created_at, o\.id' then raise exception 'oldest first, deterministically'; end if;
  if v_def ~ '(idempotency_key|source_metadata|recorded_by|created_by|pricing_snapshot|pricing_definition|referenceprice|marginrate|suppliercost|auth\.jwt)' then raise exception 'no keys, actor, metadata or pricing may be read'; end if;
  if v_def ~ '(insert into|update commerce|update public|delete from)' then raise exception 'it must write nothing'; end if;
end
$contracts$;

-- ═════════ fixtures ═════════
create table public._cg01t_ctx (k text primary key, v text);

do $fixtures$
declare
  v_suffix text := replace(gen_random_uuid()::text, '-', '');
  v_cafe uuid;
  v_other uuid := gen_random_uuid();
  u record;
begin
  select t.id into v_cafe from public.tenants t where t.slug = 'quick-solution' and t.status = 'active';
  if v_cafe is null then raise exception 'CAFE_GUEST_01T_TEST_SETUP: the quick-solution tenant must exist'; end if;
  insert into public._cg01t_ctx values ('suffix', v_suffix), ('cafe', v_cafe::text), ('other', v_other::text);
  insert into public.tenants(id, slug, name, status, settings) values (v_other, 'cg01t-other-' || left(v_suffix, 10), 'CG01T other cafe', 'active', '{}'::jsonb);
  insert into public.tenant_capabilities(tenant_id, capability_key, enabled) values (v_other, 'quick_solution', true);

  for u in select * from (values ('nomember'), ('member'), ('member2'), ('admin'), ('owner'), ('suspended'), ('otherowner'), ('appadmin'), ('oppsstaff')) as x(label) loop
    insert into public._cg01t_ctx values ('u_' || u.label, gen_random_uuid()::text);
    insert into auth.users(id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values ((select v::uuid from public._cg01t_ctx where k = 'u_' || u.label), 'authenticated', 'authenticated', 'cg01t-' || u.label || '-' || v_suffix || '@disposable.test', now(), '{}'::jsonb, '{}'::jsonb, now(), now());
  end loop;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', (select v from public._cg01t_ctx where k = 'u_appadmin'), 'role', 'authenticated', 'email', 'jointx.co@gmail.com')::text, true);
  insert into public.users(auth_user_id, user_email, full_name, role, is_active)
  values ((select v::uuid from public._cg01t_ctx where k = 'u_appadmin'), 'cg01t-appadmin-' || v_suffix || '@disposable.test', 'CG01T app admin', 'admin', true),
         ((select v::uuid from public._cg01t_ctx where k = 'u_oppsstaff'), 'cg01t-oppsstaff-' || v_suffix || '@disposable.test', 'CG01T OPPS staff', 'user', true);
  perform set_config('request.jwt.claims', '{}', true);
  if lower(coalesce(auth.jwt() ->> 'email', '')) <> '' then raise exception 'CAFE_GUEST_01T_TEST_SETUP: the temporary approved-owner claim must be cleared'; end if;

  insert into public.tenant_memberships(tenant_id, auth_user_id, tenant_role, status)
  select v_cafe, (select v::uuid from public._cg01t_ctx where k = 'u_' || m.label), m.role, m.status
  from (values ('member', 'member', 'active'), ('member2', 'member', 'active'), ('admin', 'admin', 'active'), ('owner', 'owner', 'active'), ('suspended', 'member', 'suspended')) as m(label, role, status);
  insert into public.tenant_memberships(tenant_id, auth_user_id, tenant_role, status)
  values (v_other, (select v::uuid from public._cg01t_ctx where k = 'u_otherowner'), 'owner', 'active');
  if exists (select 1 from public.tenant_memberships m where m.tenant_id = v_cafe and m.auth_user_id in
     ((select v::uuid from public._cg01t_ctx where k = 'u_appadmin'), (select v::uuid from public._cg01t_ctx where k = 'u_oppsstaff'))) then
    raise exception 'CAFE_GUEST_01T_TEST_SETUP: the app-admin and OPPS-staff fixtures must have no Cafe membership';
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
  v_cafe uuid := (select v::uuid from public._cg01t_ctx where k = 'cafe');
  u_nomember uuid := (select v::uuid from public._cg01t_ctx where k = 'u_nomember');
  u_member uuid := (select v::uuid from public._cg01t_ctx where k = 'u_member');
  u_admin uuid := (select v::uuid from public._cg01t_ctx where k = 'u_admin');
  u_owner uuid := (select v::uuid from public._cg01t_ctx where k = 'u_owner');
  u_suspended uuid := (select v::uuid from public._cg01t_ctx where k = 'u_suspended');
  u_otherowner uuid := (select v::uuid from public._cg01t_ctx where k = 'u_otherowner');
  u_appadmin uuid := (select v::uuid from public._cg01t_ctx where k = 'u_appadmin');
  u_oppsstaff uuid := (select v::uuid from public._cg01t_ctx where k = 'u_oppsstaff');
  v_labels text[]; v_subs uuid[]; v_emails text[]; v_expect text[];
  i integer; v_got text; v_state text; v_before text := public._cg01t_counts();
  v_module public.tenant_capabilities;
begin
  v_labels := array['anonymous', 'authenticated non-member', 'active member', 'active admin', 'active owner', 'suspended member',
                    'owner of a FOREIGN tenant', 'app admin with no Cafe membership', 'app admin with the approved-owner email', 'OPPS staff with no Cafe membership']::text[];
  v_subs := array[null, u_nomember, u_member, u_admin, u_owner, u_suspended, u_otherowner, u_appadmin, u_appadmin, u_oppsstaff]::uuid[];
  v_emails := array[null, null, null, null, null, null, null, null, 'jointx.co@gmail.com', null]::text[];
  v_expect := array[c_signin, c_denied, 'ok', 'ok', 'ok', c_denied, c_denied, c_denied, c_denied, c_denied]::text[];
  for i in 1 .. array_length(v_labels, 1) loop
    v_got := public._cg01t_try('authenticated', v_subs[i], v_emails[i]);
    if v_got is distinct from v_expect[i] then raise exception 'CAFE_GUEST_01T: access for "%" expected "%" but got "%"', v_labels[i], v_expect[i], v_got; end if;
  end loop;
  foreach v_state in array array['anon', 'service_role'] loop
    if public._cg01t_try(v_state, u_owner, null) not like '42501 permission denied for function list_quick_solution_unpaid_counter_orders%' then raise exception 'CAFE_GUEST_01T: % must be refused at the ACL', v_state; end if;
  end loop;
  select * into v_module from public.tenant_capabilities tc where tc.tenant_id = v_cafe and tc.capability_key = 'quick_solution';
  update public.tenant_capabilities set enabled = false where id = v_module.id;
  if public._cg01t_try('authenticated', u_member, null) is distinct from c_no_module or public._cg01t_try('authenticated', u_owner, null) is distinct from c_no_module then raise exception 'CAFE_GUEST_01T: a disabled module denies'; end if;
  if public._cg01t_try('authenticated', u_nomember, null) is distinct from c_denied then raise exception 'CAFE_GUEST_01T: authorization comes before the module check'; end if;
  update public.tenant_capabilities set enabled = true where id = v_module.id;
  foreach v_state in array array['suspended', 'archived'] loop
    update public.tenants set status = v_state where id = v_cafe;
    if public._cg01t_try('authenticated', u_member, null) is distinct from c_no_tenant then raise exception 'CAFE_GUEST_01T: a % tenant fails closed', v_state; end if;
  end loop;
  update public.tenants set status = 'active' where id = v_cafe;
  update public.tenant_memberships set status = 'suspended' where tenant_id = v_cafe and auth_user_id = u_admin;
  if public._cg01t_try('authenticated', u_admin, null) is distinct from c_denied then raise exception 'CAFE_GUEST_01T: a just-suspended admin is denied'; end if;
  update public.tenant_memberships set status = 'active' where tenant_id = v_cafe and auth_user_id = u_admin;
  if public._cg01t_counts() is distinct from v_before then raise exception 'CAFE_GUEST_01T: reading, allowed or denied, writes nothing'; end if;
end
$access$;

-- ═════════ nothing owed ═════════
do $empty$
declare
  v_r jsonb := public._cg01t_call((select v::uuid from public._cg01t_ctx where k = 'u_member'), 'unpaid');
begin
  if v_r -> 'orders' <> '[]'::jsonb or (v_r ->> 'count')::integer <> 0 or (v_r ->> 'outstandingTotal')::numeric <> 0 or v_r ->> 'timezone' <> 'Africa/Johannesburg'
     or (v_r ->> 'businessDate')::date <> (select business_date from commerce._qs_counter_business_day(now())) then
    raise exception 'CAFE_GUEST_01T: with nothing owed the list is empty and the totals are zero, got %', v_r;
  end if;
end
$empty$;

-- ═════════ what is listed, its age, its order, privacy, and the cross-day lifecycle ═════════
do $lifecycle$
declare
  v_suffix text := (select v from public._cg01t_ctx where k = 'suffix');
  v_cafe uuid := (select v::uuid from public._cg01t_ctx where k = 'cafe');
  v_other uuid := (select v::uuid from public._cg01t_ctx where k = 'other');
  u_member uuid := (select v::uuid from public._cg01t_ctx where k = 'u_member');
  u_member2 uuid := (select v::uuid from public._cg01t_ctx where k = 'u_member2');
  u_admin uuid := (select v::uuid from public._cg01t_ctx where k = 'u_admin');
  u_owner uuid := (select v::uuid from public._cg01t_ctx where k = 'u_owner');
  v_day record;
  v_marker constant text := 'CG01T-SECRET';
  v_today uuid; v_yday uuid; v_old uuid; v_b1 uuid; v_b2 uuid; v_b3 uuid;
  v_paid uuid; v_stale uuid; v_part uuid; v_cancel uuid; v_draft uuid; v_zero uuid; v_store uuid; v_foreign uuid; v_sent uuid; v_pend uuid; v_flag uuid; v_refund uuid;
  v_r jsonb; v_row jsonb; v_text text; v_before text; v_ids uuid[]; v_x uuid; n integer; v_sum numeric; v_price numeric; v_prev timestamptz;
begin
  select * into v_day from commerce._qs_counter_business_day(now());

  -- real orders through the create RPC; older ones by moving created_at of a real order
  v_today := public._cg01t_create(u_member, 'cg01t-' || v_suffix || '-today', 'scan', '{"units":4}');
  v_yday := public._cg01t_create(u_member2, 'cg01t-' || v_suffix || '-yday', 'a4-lamination', '{"units":3}');
  update commerce.service_orders set created_at = v_day.day_start - interval '12 hours' where id = v_yday;
  v_old := public._cg01t_create(u_member, 'cg01t-' || v_suffix || '-old', 'a3-lamination', '{"units":2}');
  update commerce.service_orders set created_at = v_day.day_start - interval '3 days' - interval '5 hours' where id = v_old;
  -- the local-midnight boundary: one microsecond before is YESTERDAY (1 day old), exactly midnight is TODAY (0), and 1 day + 1 us before is 2 days
  v_b1 := public._cg01t_create(u_member, 'cg01t-' || v_suffix || '-b1', 'scan', '{"units":1}');
  update commerce.service_orders set created_at = v_day.day_start - interval '1 microsecond' where id = v_b1;
  v_b2 := public._cg01t_create(u_member, 'cg01t-' || v_suffix || '-b2', 'scan', '{"units":1}');
  update commerce.service_orders set created_at = v_day.day_start where id = v_b2;
  v_b3 := public._cg01t_create(u_member, 'cg01t-' || v_suffix || '-b3', 'scan', '{"units":1}');
  update commerce.service_orders set created_at = v_day.day_start - interval '1 day' - interval '1 microsecond' where id = v_b3;
  -- excluded: paid through the real RPC (created yesterday), and a stored-unpaid order the ledger already covers
  v_paid := public._cg01t_create(u_member, 'cg01t-' || v_suffix || '-paid', 'scan', '{"units":2}');
  update commerce.service_orders set created_at = v_day.day_start - interval '2 days' where id = v_paid;
  perform public._cg01t_pay(u_member2, v_paid, 'cash', 'cg01t-' || v_suffix || '-ppaid');
  v_stale := public._cg01t_mk(v_cafe, 'counter', 40);
  update commerce.service_orders set created_at = v_day.day_start - interval '2 days' where id = v_stale;
  insert into commerce.service_order_payments(tenant_id, service_order_id, provider, status, amount, completed_at) values (v_cafe, v_stale, 'payfast', 'completed', 40, now());
  v_zero := public._cg01t_mk(v_cafe, 'counter', 0);
  v_cancel := public._cg01t_mk(v_cafe, 'counter', 50, 'cancelled', 'unpaid');
  v_draft := public._cg01t_mk(v_cafe, 'counter', 50, 'draft', 'unpaid');
  v_store := public._cg01t_mk(v_cafe, 'storefront', 50);
  v_foreign := public._cg01t_mk(v_other, 'counter', 50);
  -- included although unusual: partly covered by a completed gateway payment (the remainder is what is outstanding), sent to production but unpaid, and a pending payment status
  v_part := public._cg01t_mk(v_cafe, 'counter', 40);
  update commerce.service_orders set created_at = v_day.day_start - interval '4 days' where id = v_part;
  insert into commerce.service_order_payments(tenant_id, service_order_id, provider, status, amount, completed_at) values (v_cafe, v_part, 'payfast', 'completed', 15, now());
  insert into commerce.service_order_payments(tenant_id, service_order_id, provider, status, amount) values (v_cafe, v_part, 'payfast', 'pending', 25);
  v_sent := public._cg01t_mk(v_cafe, 'counter', 30);
  insert into commerce.service_order_handoffs(service_order_id, source_tenant_id, target_tenant_id, status, idempotency_key) values (v_sent, v_cafe, v_cafe, 'sent', 'CG01T-HO-' || v_sent::text);
  v_pend := public._cg01t_mk(v_cafe, 'counter', 20, 'submitted', 'pending');
  -- a stored status of paid or refunded is settled as far as this list goes, even with no completed ledger row behind it (not this list's business to second-guess)
  v_flag := public._cg01t_mk(v_cafe, 'counter', 30, 'submitted', 'paid');
  v_refund := public._cg01t_mk(v_cafe, 'counter', 30, 'submitted', 'refunded');
  update commerce.service_orders set source_metadata = source_metadata || jsonb_build_object('secret', v_marker) where id in (v_today, v_yday, v_old);

  v_before := public._cg01t_counts();
  v_r := public._cg01t_call(u_member, 'unpaid');
  if public._cg01t_counts() is distinct from v_before then raise exception 'CAFE_GUEST_01T: the read wrote something'; end if;

  -- exactly the orders that still owe money
  v_ids := array[v_today, v_yday, v_old, v_b1, v_b2, v_b3, v_part, v_sent, v_pend];
  select count(*) into n from jsonb_array_elements(v_r -> 'orders');
  if n <> 9 or (v_r ->> 'count')::integer <> 9 then raise exception 'CAFE_GUEST_01T: exactly 9 orders owe money, got % (count %)', n, v_r ->> 'count'; end if;
  foreach v_x in array v_ids loop
    if not exists (select 1 from jsonb_array_elements(v_r -> 'orders') o where o ->> 'orderId' = v_x::text) then raise exception 'CAFE_GUEST_01T: order % must be listed', v_x; end if;
  end loop;
  foreach v_x in array array[v_paid, v_stale, v_zero, v_cancel, v_draft, v_store, v_foreign, v_flag, v_refund]::uuid[] loop
    if exists (select 1 from jsonb_array_elements(v_r -> 'orders') o where o ->> 'orderId' = v_x::text) then raise exception 'CAFE_GUEST_01T: order % must NOT be listed (paid, covered, zero, cancelled, draft, storefront or foreign)', v_x; end if;
  end loop;

  -- ages are Cafe business-day differences
  foreach v_row in array array[
    jsonb_build_object('id', v_today, 'age', 0), jsonb_build_object('id', v_yday, 'age', 1), jsonb_build_object('id', v_old, 'age', 4),
    jsonb_build_object('id', v_b1, 'age', 1), jsonb_build_object('id', v_b2, 'age', 0), jsonb_build_object('id', v_b3, 'age', 2), jsonb_build_object('id', v_part, 'age', 4)]
  loop
    if ((select o ->> 'ageDays' from jsonb_array_elements(v_r -> 'orders') o where o ->> 'orderId' = v_row ->> 'id'))::integer is distinct from (v_row ->> 'age')::integer then
      raise exception 'CAFE_GUEST_01T: age of % should be % days, got %', v_row ->> 'id', v_row ->> 'age', (select o ->> 'ageDays' from jsonb_array_elements(v_r -> 'orders') o where o ->> 'orderId' = v_row ->> 'id');
    end if;
  end loop;
  -- one microsecond before local midnight is 1 day old even though it is a moment old in real time
  if (select o ->> 'orderDate' from jsonb_array_elements(v_r -> 'orders') o where o ->> 'orderId' = v_b1::text)::date <> v_day.business_date - 1
     or (select o ->> 'orderDate' from jsonb_array_elements(v_r -> 'orders') o where o ->> 'orderId' = v_b2::text)::date <> v_day.business_date then
    raise exception 'CAFE_GUEST_01T: the order dates follow the Johannesburg business day';
  end if;

  -- oldest first, deterministically
  v_prev := null;
  for n in 0 .. jsonb_array_length(v_r -> 'orders') - 1 loop
    if v_prev is not null and (v_r -> 'orders' -> n ->> 'createdAt')::timestamptz < v_prev then raise exception 'CAFE_GUEST_01T: oldest first'; end if;
    v_prev := (v_r -> 'orders' -> n ->> 'createdAt')::timestamptz;
  end loop;
  if v_r -> 'orders' -> 0 ->> 'orderId' <> v_part::text then raise exception 'CAFE_GUEST_01T: the oldest unpaid order (4 days) is first, got %', v_r -> 'orders' -> 0 ->> 'orderNumber'; end if;

  -- amounts: outstanding is total minus the COMPLETED ledger; the partly covered order shows only its remainder
  select o into v_row from jsonb_array_elements(v_r -> 'orders') o where o ->> 'orderId' = v_part::text;
  if (v_row ->> 'totalAmount')::numeric <> 40 or (v_row ->> 'amountPaid')::numeric <> 15 or (v_row ->> 'outstanding')::numeric <> 25 then raise exception 'CAFE_GUEST_01T: a partly covered order shows paid 15 and outstanding 25 (the pending row is not money), got %', v_row; end if;
  select o into v_row from jsonb_array_elements(v_r -> 'orders') o where o ->> 'orderId' = v_yday::text;
  v_price := (commerce.qs_calculate_price(v_cafe, 'a4-lamination', '{"units":3}') ->> 'total')::numeric;
  if (v_row ->> 'totalAmount')::numeric <> v_price or (v_row ->> 'outstanding')::numeric <> v_price or (v_row ->> 'amountPaid')::numeric <> 0 or v_price <= 0
     or v_row ->> 'paymentStatus' <> 'unpaid' or v_row ->> 'status' <> 'submitted' or v_row -> 'items' -> 0 ->> 'productKey' <> 'a4-lamination' or v_row -> 'items' -> 0 -> 'configuration' <> '{"units":3}'::jsonb then
    raise exception 'CAFE_GUEST_01T: yesterday''s order shows the server price as outstanding and its item, got %', v_row;
  end if;
  select coalesce(sum((o ->> 'outstanding')::numeric), 0) into v_sum from jsonb_array_elements(v_r -> 'orders') o;
  if (v_r ->> 'outstandingTotal')::numeric <> v_sum or v_sum <= 0 then raise exception 'CAFE_GUEST_01T: outstandingTotal is the sum of the listed rows'; end if;

  -- privacy
  if (select array_agg(k order by k) from jsonb_object_keys(v_r) k) is distinct from array['businessDate', 'count', 'orders', 'outstandingTotal', 'timezone'] then raise exception 'CAFE_GUEST_01T: the response has the pinned top-level keys'; end if;
  if (select array_agg(k order by k) from jsonb_object_keys(v_row) k) is distinct from
     array['ageDays', 'amountPaid', 'createdAt', 'customerEmail', 'customerName', 'customerPhone', 'items', 'orderDate', 'orderId', 'orderNumber', 'outstanding', 'paymentStatus', 'status', 'totalAmount'] then
    raise exception 'CAFE_GUEST_01T: an order has exactly the pinned keys, got %', (select array_agg(k order by k) from jsonb_object_keys(v_row) k);
  end if;
  v_text := lower(v_r::text);
  if v_text like '%' || lower(v_marker) || '%' or v_text like '%cg01t-' || lower(v_suffix) || '%' or v_text like '%counter:%' or v_text like '%cg01t-key%'
     or v_text like '%' || lower(u_member::text) || '%' or v_text like '%' || lower(u_member2::text) || '%' or v_text like '%' || lower(u_admin::text) || '%' or v_text like '%' || lower(u_owner::text) || '%'
     or v_text like '%' || lower(v_cafe::text) || '%' or v_text like '%' || lower(v_other::text) || '%'
     or v_text ~ '(idempotency|recorded_by|recordedby|created_by|createdby|source_metadata|sourcemetadata|pricing_snapshot|pricingsnapshot|pricing_definition|supplier|margin|tenant_id|tenantid)' then
    raise exception 'CAFE_GUEST_01T: no key, actor, source metadata, pricing or tenant id in the list';
  end if;

  -- every counter user sees the same list
  foreach v_x in array array[u_member2, u_admin, u_owner]::uuid[] loop
    if public._cg01t_call(v_x, 'unpaid') is distinct from v_r then raise exception 'CAFE_GUEST_01T: every counter user sees the same unpaid list'; end if;
  end loop;

  -- ── the cross-day lifecycle: yesterday's order ──
  -- it is here, and Today's Orders does not show it
  if exists (select 1 from jsonb_array_elements(public._cg01t_call(u_member, 'today') -> 'orders') o where o ->> 'orderId' = v_yday::text) then raise exception 'CAFE_GUEST_01T: yesterday''s order is not in Today''s Orders'; end if;
  if not exists (select 1 from jsonb_array_elements(public._cg01t_call(u_member, 'today') -> 'orders') o where o ->> 'orderId' = v_today::text) then raise exception 'CAFE_GUEST_01T: today''s unpaid order is in Today''s Orders too'; end if;
  if (public._cg01t_call(u_member, 'detail', v_yday) -> 'paymentAllowed') <> 'true'::jsonb then raise exception 'CAFE_GUEST_01T: the existing detail allows paying it'; end if;
  -- pay it today through the existing 01Q payment
  v_x := v_yday;
  if not ((public._cg01t_pay(u_admin, v_x, 'card', 'cg01t-' || v_suffix || '-payyday') ->> 'ok')::boolean) then raise exception 'CAFE_GUEST_01T: paying yesterday''s order through 01Q must work'; end if;
  v_r := public._cg01t_call(u_member, 'unpaid');
  if exists (select 1 from jsonb_array_elements(v_r -> 'orders') o where o ->> 'orderId' = v_yday::text) or (v_r ->> 'count')::integer <> 8 then raise exception 'CAFE_GUEST_01T: once paid it disappears from Unpaid'; end if;
  select o into v_row from jsonb_array_elements(public._cg01t_call(u_member, 'cashup') -> 'payments') o where o ->> 'orderId' = v_yday::text;
  if v_row is null or v_row ->> 'method' <> 'card' or (v_row ->> 'amount')::numeric <> v_price or (v_row ->> 'orderCreatedAt')::timestamptz >= v_day.day_start then
    raise exception 'CAFE_GUEST_01T: yesterday''s order, paid today, is in today''s cash-up takings: %', v_row;
  end if;
  if (public._cg01t_call(u_member, 'cashup') -> 'takings' -> 'card' ->> 'amount')::numeric <> v_price or (public._cg01t_call(u_member, 'detail', v_yday) ->> 'paymentStatus') <> 'paid' then
    raise exception 'CAFE_GUEST_01T: the cash-up card total is that payment and the detail is paid';
  end if;
  -- today's order settled the same way leaves the list too; the rest are untouched
  perform public._cg01t_pay(u_owner, v_today, 'cash', 'cg01t-' || v_suffix || '-paytoday');
  v_r := public._cg01t_call(u_member, 'unpaid');
  if (v_r ->> 'count')::integer <> 7 or exists (select 1 from jsonb_array_elements(v_r -> 'orders') o where o ->> 'orderId' in (v_yday::text, v_today::text)) then raise exception 'CAFE_GUEST_01T: settled orders leave the list, the others stay'; end if;
  -- a stored-unpaid order that becomes covered by the ledger leaves too (the rule is the ledger, not the string)
  insert into commerce.service_order_payments(tenant_id, service_order_id, provider, status, amount, completed_at) values (v_cafe, v_pend, 'payfast', 'completed', 20, now());
  if exists (select 1 from jsonb_array_elements(public._cg01t_call(u_member, 'unpaid') -> 'orders') o where o ->> 'orderId' = v_pend::text) then raise exception 'CAFE_GUEST_01T: an order covered by the completed ledger is not owed even if its status string is not paid'; end if;
  -- cancelling removes it
  update commerce.service_orders set status = 'cancelled' where id = v_old;
  if exists (select 1 from jsonb_array_elements(public._cg01t_call(u_member, 'unpaid') -> 'orders') o where o ->> 'orderId' = v_old::text) then raise exception 'CAFE_GUEST_01T: a cancelled order is not owed'; end if;
  -- and reading changed nothing
  v_before := public._cg01t_counts();
  perform public._cg01t_call(u_member, 'unpaid');
  if public._cg01t_counts() is distinct from v_before then raise exception 'CAFE_GUEST_01T: reading wrote rows'; end if;
end
$lifecycle$;

rollback;
select 'CAFE-GUEST-01T unpaid counter orders RPC contracts passed' as result;
