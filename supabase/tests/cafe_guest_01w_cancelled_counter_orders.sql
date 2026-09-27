-- CAFE-GUEST-01W: behavioral contract test for public.list_quick_solution_cancelled_counter_orders().
--
-- Run only against the disposable local harness (supabase/tests/harness/), which replays the migration history INCLUDING the OPPS-owned
-- access layer and 20260926290000_cafe_guest_01w_cancelled_counter_orders_rpc.sql. Orders are created and cancelled through the REAL
-- 01M / 01V RPCs under real API roles; other shapes are inserted directly. Everything is enclosed by BEGIN/ROLLBACK.

\set ON_ERROR_STOP on

begin;

create function public._cg01w_setup(p_role text, p_sub uuid, p_email text) returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claims',
    case when p_sub is null then '{}'
         else jsonb_strip_nulls(jsonb_build_object('sub', p_sub, 'role', 'authenticated', 'email', p_email))::text end, true);
  execute format('set local role %I', p_role);
end
$$;

create function public._cg01w_try(p_role text, p_sub uuid, p_email text) returns text
language plpgsql
as $$
declare
  v_state text;
  v_message text;
begin
  perform public._cg01w_setup(p_role, p_sub, p_email);
  perform public.list_quick_solution_cancelled_counter_orders();
  execute 'reset role';
  return 'ok';
exception when others then
  get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
  execute 'reset role';
  return v_state || ' ' || v_message;
end
$$;

create function public._cg01w_list(p_sub uuid) returns jsonb
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform public._cg01w_setup('authenticated', p_sub, null);
  v_result := public.list_quick_solution_cancelled_counter_orders();
  execute 'reset role';
  return v_result;
end
$$;

create function public._cg01w_create(p_sub uuid, p_key text, p_product text, p_config jsonb) returns uuid
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform public._cg01w_setup('authenticated', p_sub, null);
  v_result := public.create_quick_solution_counter_order(p_key, p_product, p_config);
  execute 'reset role';
  return (v_result ->> 'orderId')::uuid;
end
$$;

create function public._cg01w_cancel(p_sub uuid, p_order uuid, p_reason text) returns jsonb
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform public._cg01w_setup('authenticated', p_sub, null);
  v_result := public.cancel_quick_solution_counter_order(p_order, p_reason);
  execute 'reset role';
  return v_result;
end
$$;

create function public._cg01w_mk(p_tenant uuid, p_channel text, p_total numeric, p_status text default 'submitted') returns uuid
language plpgsql
as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into commerce.service_orders(id, tenant_id, order_number, customer_name, idempotency_key, channel, subtotal, total_amount, status, payment_status)
  values (v_id, p_tenant, 'CG01W-' || left(v_id::text, 8), 'CG01W direct', 'CG01W-KEY-' || v_id::text, p_channel, p_total, p_total, p_status, 'unpaid');
  return v_id;
end
$$;

create function public._cg01w_audit(p_tenant uuid, p_order uuid, p_by uuid, p_at timestamptz, p_reason text) returns void
language sql
as $$
  insert into commerce.service_order_cancellations(tenant_id, service_order_id, cancelled_by, cancelled_at, reason, prior_status, prior_payment_status, order_total, outstanding_at_cancel)
  values (p_tenant, p_order, p_by, p_at, p_reason, 'submitted', 'unpaid', 10, 10)
$$;

create function public._cg01w_counts() returns text
language sql
as $$
  select (select count(*) from commerce.service_orders) || '/' || (select count(*) from commerce.service_order_items) || '/' || (select count(*) from commerce.service_order_payments)
         || '/' || (select count(*) from commerce.service_order_cancellations) || '/' || (select coalesce(sum(length(o.status)), 0) from commerce.service_orders o)
$$;

grant execute on function public._cg01w_setup(text, uuid, text), public._cg01w_try(text, uuid, text), public._cg01w_list(uuid),
  public._cg01w_create(uuid, text, text, jsonb), public._cg01w_cancel(uuid, uuid, text), public._cg01w_mk(uuid, text, numeric, text),
  public._cg01w_counts() to anon, authenticated, service_role;

-- ═════════ contracts ═════════
do $contracts$
declare
  v_rpc regprocedure := to_regprocedure('public.list_quick_solution_cancelled_counter_orders()');
  v_def text;
begin
  if v_rpc is null then raise exception 'list_quick_solution_cancelled_counter_orders() must exist'; end if;
  if (select p.pronargs from pg_catalog.pg_proc p where p.oid = v_rpc) <> 0 then raise exception 'it takes no argument: no tenant, channel, actor or date'; end if;
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
  if v_def !~ 'has_tenant_capability\(v_tenant_id, ''cafe\.operations\.manage''\)' then raise exception 'it must require cafe.operations.manage'; end if;
  if v_def like '%cafe.counter.operate%' or v_def ~ '(is_app_admin|is_opps_staff|can_access_tenant)' then raise exception 'manage only, and no app-admin / OPPS-staff bypass'; end if;
  if v_def !~ 't\.slug = ''quick-solution''' or v_def !~ 'so\.channel = ''counter''' or v_def !~ 'c\.tenant_id = v_tenant_id' or v_def !~ 'so\.tenant_id = c\.tenant_id' then raise exception 'canonical tenant, counter channel only'; end if;
  if v_def !~ 'from commerce\.service_order_cancellations c' then raise exception 'the audited cancellations are the source'; end if;
  if v_def !~ 'order by cancelled_at desc, id desc limit 100' or v_def !~ 'order by r\.cancelled_at desc, r\.id desc' then raise exception 'newest first, deterministically, capped at 100'; end if;
  if v_def ~ '(idempotency_key|source_metadata|recorded_by|pricing_snapshot|pricing_definition|referenceprice|marginrate|suppliercost|auth\.jwt|user_email)' then raise exception 'no keys, metadata, pricing or email may be read'; end if;
  if v_def ~ '''cancelledby'', c\.cancelled_by|''cancelledby'', r\.cancelled_by,' then raise exception 'the auth user id must not be returned'; end if;
  if v_def ~ '(insert into|update commerce|update public|delete from)' then raise exception 'it must write nothing'; end if;
end
$contracts$;

-- ═════════ fixtures ═════════
create table public._cg01w_ctx (k text primary key, v text);

do $fixtures$
declare
  v_suffix text := replace(gen_random_uuid()::text, '-', '');
  v_cafe uuid;
  v_other uuid := gen_random_uuid();
  u record;
begin
  select t.id into v_cafe from public.tenants t where t.slug = 'quick-solution' and t.status = 'active';
  if v_cafe is null then raise exception 'CAFE_GUEST_01W_TEST_SETUP: the quick-solution tenant must exist'; end if;
  insert into public._cg01w_ctx values ('suffix', v_suffix), ('cafe', v_cafe::text), ('other', v_other::text);
  insert into public.tenants(id, slug, name, status, settings) values (v_other, 'cg01w-other-' || left(v_suffix, 10), 'CG01W other cafe', 'active', '{}'::jsonb);
  insert into public.tenant_capabilities(tenant_id, capability_key, enabled) values (v_other, 'quick_solution', true);

  for u in select * from (values ('nomember'), ('member'), ('admin'), ('owner'), ('suspended'), ('otherowner'), ('appadmin'), ('oppsstaff')) as x(label) loop
    insert into public._cg01w_ctx values ('u_' || u.label, gen_random_uuid()::text);
    insert into auth.users(id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values ((select v::uuid from public._cg01w_ctx where k = 'u_' || u.label), 'authenticated', 'authenticated', 'cg01w-' || u.label || '-' || v_suffix || '@disposable.test', now(), '{}'::jsonb, '{}'::jsonb, now(), now());
  end loop;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', (select v from public._cg01w_ctx where k = 'u_appadmin'), 'role', 'authenticated', 'email', 'jointx.co@gmail.com')::text, true);
  insert into public.users(auth_user_id, user_email, full_name, role, is_active)
  values ((select v::uuid from public._cg01w_ctx where k = 'u_appadmin'), 'cg01w-appadmin-' || v_suffix || '@disposable.test', 'CG01W app admin', 'admin', true),
         ((select v::uuid from public._cg01w_ctx where k = 'u_oppsstaff'), 'cg01w-oppsstaff-' || v_suffix || '@disposable.test', 'CG01W OPPS staff', 'user', true),
         ((select v::uuid from public._cg01w_ctx where k = 'u_admin'), 'cg01w-admin-' || v_suffix || '@disposable.test', 'Ada Admin', 'user', true);
  perform set_config('request.jwt.claims', '{}', true);
  if lower(coalesce(auth.jwt() ->> 'email', '')) <> '' then raise exception 'CAFE_GUEST_01W_TEST_SETUP: the temporary approved-owner claim must be cleared'; end if;

  insert into public.tenant_memberships(tenant_id, auth_user_id, tenant_role, status)
  select v_cafe, (select v::uuid from public._cg01w_ctx where k = 'u_' || m.label), m.role, m.status
  from (values ('member', 'member', 'active'), ('admin', 'admin', 'active'), ('owner', 'owner', 'active'), ('suspended', 'admin', 'suspended')) as m(label, role, status);
  insert into public.tenant_memberships(tenant_id, auth_user_id, tenant_role, status)
  values (v_other, (select v::uuid from public._cg01w_ctx where k = 'u_otherowner'), 'owner', 'active');
end
$fixtures$;

-- ═════════ access, module and tenant state ═════════
do $access$
declare
  c_signin constant text := '42501 Staff sign-in is required.';
  c_denied constant text := '42501 Only a Quick Solution admin or owner can view cancelled counter orders.';
  c_no_tenant constant text := '22023 Quick Solution tenant was not found.';
  c_no_module constant text := '22023 Quick Solution counter is not active.';
  v_cafe uuid := (select v::uuid from public._cg01w_ctx where k = 'cafe');
  u_admin uuid := (select v::uuid from public._cg01w_ctx where k = 'u_admin');
  u_owner uuid := (select v::uuid from public._cg01w_ctx where k = 'u_owner');
  u_member uuid := (select v::uuid from public._cg01w_ctx where k = 'u_member');
  v_labels text[]; v_subs uuid[]; v_emails text[]; v_expect text[];
  i integer; v_got text; v_state text; v_before text := public._cg01w_counts();
  v_module public.tenant_capabilities;
begin
  v_labels := array['anonymous', 'authenticated non-member', 'active member', 'active admin', 'active owner', 'suspended admin',
                    'owner of a FOREIGN tenant', 'app admin with no Cafe membership', 'app admin with the approved-owner email', 'OPPS staff with no Cafe membership']::text[];
  v_subs := array[null, (select v::uuid from public._cg01w_ctx where k = 'u_nomember'), u_member, u_admin, u_owner, (select v::uuid from public._cg01w_ctx where k = 'u_suspended'),
                  (select v::uuid from public._cg01w_ctx where k = 'u_otherowner'), (select v::uuid from public._cg01w_ctx where k = 'u_appadmin'),
                  (select v::uuid from public._cg01w_ctx where k = 'u_appadmin'), (select v::uuid from public._cg01w_ctx where k = 'u_oppsstaff')]::uuid[];
  v_emails := array[null, null, null, null, null, null, null, null, 'jointx.co@gmail.com', null]::text[];
  v_expect := array[c_signin, c_denied, c_denied, 'ok', 'ok', c_denied, c_denied, c_denied, c_denied, c_denied]::text[];
  for i in 1 .. array_length(v_labels, 1) loop
    v_got := public._cg01w_try('authenticated', v_subs[i], v_emails[i]);
    if v_got is distinct from v_expect[i] then raise exception 'CAFE_GUEST_01W: access for "%" expected "%" but got "%"', v_labels[i], v_expect[i], v_got; end if;
  end loop;
  foreach v_state in array array['anon', 'service_role'] loop
    if public._cg01w_try(v_state, u_owner, null) not like '42501 permission denied for function list_quick_solution_cancelled_counter_orders%' then raise exception 'CAFE_GUEST_01W: % must be refused at the ACL', v_state; end if;
  end loop;
  select * into v_module from public.tenant_capabilities tc where tc.tenant_id = v_cafe and tc.capability_key = 'quick_solution';
  update public.tenant_capabilities set enabled = false where id = v_module.id;
  if public._cg01w_try('authenticated', u_admin, null) is distinct from c_no_module or public._cg01w_try('authenticated', u_owner, null) is distinct from c_no_module then raise exception 'CAFE_GUEST_01W: a disabled module denies'; end if;
  if public._cg01w_try('authenticated', u_member, null) is distinct from c_denied then raise exception 'CAFE_GUEST_01W: authorization comes before the module check'; end if;
  update public.tenant_capabilities set enabled = true where id = v_module.id;
  foreach v_state in array array['suspended', 'archived'] loop
    update public.tenants set status = v_state where id = v_cafe;
    if public._cg01w_try('authenticated', u_admin, null) is distinct from c_no_tenant then raise exception 'CAFE_GUEST_01W: a % tenant fails closed', v_state; end if;
  end loop;
  update public.tenants set status = 'active' where id = v_cafe;
  update public.tenant_memberships set status = 'suspended' where tenant_id = v_cafe and auth_user_id = u_admin;
  if public._cg01w_try('authenticated', u_admin, null) is distinct from c_denied then raise exception 'CAFE_GUEST_01W: a just-suspended admin is denied'; end if;
  update public.tenant_memberships set status = 'active' where tenant_id = v_cafe and auth_user_id = u_admin;
  if public._cg01w_counts() is distinct from v_before then raise exception 'CAFE_GUEST_01W: reading, allowed or denied, writes nothing'; end if;
end
$access$;

-- ═════════ nothing cancelled yet ═════════
do $empty$
declare
  v_r jsonb := public._cg01w_list((select v::uuid from public._cg01w_ctx where k = 'u_admin'));
begin
  if v_r <> jsonb_build_object('count', 0, 'shown', 0, 'limit', 100, 'orders', '[]'::jsonb) then raise exception 'CAFE_GUEST_01W: with nothing cancelled the list is empty, got %', v_r; end if;
end
$empty$;

-- ═════════ what is listed, in what order, with what, and what is not ═════════
do $content$
declare
  v_suffix text := (select v from public._cg01w_ctx where k = 'suffix');
  v_cafe uuid := (select v::uuid from public._cg01w_ctx where k = 'cafe');
  v_other uuid := (select v::uuid from public._cg01w_ctx where k = 'other');
  u_member uuid := (select v::uuid from public._cg01w_ctx where k = 'u_member');
  u_admin uuid := (select v::uuid from public._cg01w_ctx where k = 'u_admin');
  u_owner uuid := (select v::uuid from public._cg01w_ctx where k = 'u_owner');
  v_a uuid; v_b uuid; v_c uuid; v_keep uuid; v_paid uuid; v_plain uuid; v_store uuid; v_foreign uuid; v_first uuid;
  v_r jsonb; v_row jsonb; v_text text; v_before text; n integer; i integer;
begin
  v_a := public._cg01w_create(u_member, 'cg01w-' || v_suffix || '-a', 'scan', '{"units":4}');
  v_b := public._cg01w_create(u_member, 'cg01w-' || v_suffix || '-b', 'a4-lamination', '{"units":3}');
  v_c := public._cg01w_create(u_member, 'cg01w-' || v_suffix || '-c', 'a3-lamination', '{"units":2}');
  v_keep := public._cg01w_create(u_member, 'cg01w-' || v_suffix || '-keep', 'scan', '{"units":1}');
  update commerce.service_orders set customer_name = 'Thandi Nkosi', customer_phone = '0751234567', customer_email = 'thandi@example.test' where id = v_a;

  perform public._cg01w_cancel(u_admin, v_a, 'Customer changed their mind');
  perform public._cg01w_cancel(u_owner, v_b, 'Entered for the wrong customer');
  perform public._cg01w_cancel(u_admin, v_c, 'Left without paying');

  v_r := public._cg01w_list(u_admin);
  if (v_r ->> 'count')::integer is distinct from 3 or (v_r ->> 'shown')::integer is distinct from 3 or (v_r ->> 'limit')::integer is distinct from 100 or jsonb_array_length(v_r -> 'orders') <> 3 then raise exception 'CAFE_GUEST_01W: three audited cancellations, got %', v_r; end if;
  -- newest first: c, b, a
  if (v_r -> 'orders' -> 0 ->> 'orderId')::uuid is distinct from v_c or (v_r -> 'orders' -> 1 ->> 'orderId')::uuid is distinct from v_b or (v_r -> 'orders' -> 2 ->> 'orderId')::uuid is distinct from v_a then raise exception 'CAFE_GUEST_01W: newest cancellation first'; end if;
  -- the same list for an owner
  if public._cg01w_list(u_owner) <> v_r then raise exception 'CAFE_GUEST_01W: an owner sees the same list'; end if;

  select o into v_row from jsonb_array_elements(v_r -> 'orders') o where o ->> 'orderId' = v_a::text;
  if v_row ->> 'reason' is distinct from 'Customer changed their mind' or v_row ->> 'cancelledBy' is distinct from 'Ada Admin' or v_row ->> 'priorStatus' is distinct from 'submitted' or v_row ->> 'priorPaymentStatus' is distinct from 'unpaid'
     or (v_row ->> 'totalAmount')::numeric is distinct from (select total_amount from commerce.service_orders where id = v_a)
     or (v_row ->> 'outstandingAtCancel')::numeric is distinct from (select total_amount from commerce.service_orders where id = v_a)
     or v_row ->> 'customerName' is distinct from 'Thandi Nkosi' or v_row ->> 'customerPhone' is distinct from '0751234567' or v_row ->> 'customerEmail' is distinct from 'thandi@example.test'
     or v_row ->> 'orderNumber' is distinct from (select order_number from commerce.service_orders where id = v_a)
     or (v_row ->> 'cancelledAt')::timestamptz is distinct from (select cancelled_at from commerce.service_order_cancellations where service_order_id = v_a)
     or (v_row ->> 'createdAt')::timestamptz is distinct from (select created_at from commerce.service_orders where id = v_a) then
    raise exception 'CAFE_GUEST_01W: an entry carries the order, the reason, who and when, got %', v_row;
  end if;
  if jsonb_array_length(v_row -> 'items') is distinct from 1 or v_row -> 'items' -> 0 ->> 'productKey' is distinct from 'scan' or (v_row -> 'items' -> 0 -> 'configuration' ->> 'units') is distinct from '4' or v_row -> 'items' -> 0 ->> 'productName' is null then raise exception 'CAFE_GUEST_01W: the items are listed, got %', v_row -> 'items'; end if;
  -- a cancelling owner with no users row has no display name, never an id
  select o into v_row from jsonb_array_elements(v_r -> 'orders') o where o ->> 'orderId' = v_b::text;
  if (v_row -> 'cancelledBy') is distinct from 'null'::jsonb then raise exception 'CAFE_GUEST_01W: no display name is null, got %', v_row -> 'cancelledBy'; end if;

  -- privacy: no actor or tenant id, no key, no metadata, no pricing
  v_text := v_r::text;
  if v_text like '%' || u_admin::text || '%' or v_text like '%' || u_owner::text || '%' or v_text like '%' || v_cafe::text || '%' or v_text like '%' || u_member::text || '%'
     or v_text ~* ('(idempotency|cg01w-' || v_suffix || '|source_metadata|sourceMetadata|recordedBy|pricing|margin|supplier|cancelledById)') then
    raise exception 'CAFE_GUEST_01W: no actor id, tenant id, key, metadata or pricing may appear: %', v_text;
  end if;

  -- not listed: an order that is merely still unpaid, one that was paid, one cancelled with no audit row, a storefront order and a foreign order (both with audit rows)
  v_paid := public._cg01w_create(u_member, 'cg01w-' || v_suffix || '-paid', 'scan', '{"units":2}');
  perform public._cg01w_setup('authenticated', u_member, null);
  perform public.record_quick_solution_counter_payment(v_paid, 'cash', 'cg01w-' || v_suffix || '-paykey');
  execute 'reset role';
  v_plain := public._cg01w_mk(v_cafe, 'counter', 10, 'cancelled');
  v_store := public._cg01w_mk(v_cafe, 'storefront', 10, 'cancelled');
  v_foreign := public._cg01w_mk(v_other, 'counter', 10, 'cancelled');
  perform public._cg01w_audit(v_cafe, v_store, u_admin, now(), 'storefront cancelled');
  perform public._cg01w_audit(v_other, v_foreign, u_admin, now(), 'foreign cancelled');
  v_r := public._cg01w_list(u_admin);
  if (v_r ->> 'count')::integer is distinct from 3 or exists (select 1 from jsonb_array_elements(v_r -> 'orders') o where (o ->> 'orderId')::uuid in (v_keep, v_paid, v_plain, v_store, v_foreign)) then
    raise exception 'CAFE_GUEST_01W: only audited Cafe counter cancellations are listed, got %', v_r;
  end if;

  -- a later cancellation goes to the top and the count follows the server
  perform public._cg01w_cancel(u_admin, v_keep, 'Duplicate order');
  v_r := public._cg01w_list(u_admin);
  if (v_r ->> 'count')::integer is distinct from 4 or (v_r -> 'orders' -> 0 ->> 'orderId')::uuid is distinct from v_keep or v_r -> 'orders' -> 0 ->> 'reason' is distinct from 'Duplicate order' then raise exception 'CAFE_GUEST_01W: a new cancellation is first'; end if;

  -- the cap: many more, newest 100 shown, the total still reported, oldest left out
  v_before := public._cg01w_counts();
  for i in 1 .. 105 loop
    v_first := public._cg01w_mk(v_cafe, 'counter', 10, 'cancelled');
    perform public._cg01w_audit(v_cafe, v_first, u_admin, now() + make_interval(mins => i), 'bulk ' || i);
  end loop;
  v_r := public._cg01w_list(u_admin);
  if (v_r ->> 'count')::integer is distinct from 109 or (v_r ->> 'shown')::integer is distinct from 100 or jsonb_array_length(v_r -> 'orders') <> 100 or (v_r ->> 'limit')::integer is distinct from 100 then raise exception 'CAFE_GUEST_01W: at most 100 shown, all counted, got count % shown %', v_r ->> 'count', v_r ->> 'shown'; end if;
  if v_r -> 'orders' -> 0 ->> 'reason' is distinct from 'bulk 105' or v_r -> 'orders' -> 99 ->> 'reason' is distinct from 'bulk 6' then raise exception 'CAFE_GUEST_01W: the newest 100, in order'; end if;
  if exists (select 1 from jsonb_array_elements(v_r -> 'orders') o where o ->> 'reason' in ('bulk 1', 'bulk 5', 'Customer changed their mind')) then raise exception 'CAFE_GUEST_01W: the oldest are left out of the page'; end if;
  select count(*) into n from (select o ->> 'cancelledAt' as t, lag(o ->> 'cancelledAt') over () as p from jsonb_array_elements(v_r -> 'orders') o) x where p is not null and t::timestamptz > p::timestamptz;
  if n <> 0 then raise exception 'CAFE_GUEST_01W: strictly newest first'; end if;

  -- reading changed nothing
  v_before := public._cg01w_counts();
  perform public._cg01w_list(u_admin);
  perform public._cg01w_try('authenticated', u_member, null);
  if public._cg01w_counts() is distinct from v_before then raise exception 'CAFE_GUEST_01W: reading wrote rows'; end if;
end
$content$;

rollback;
select 'CAFE-GUEST-01W cancelled counter orders RPC contracts passed' as result;
