-- CAFE-GUEST-01V: behavioral contract test for public.cancel_quick_solution_counter_order and
-- public.get_quick_solution_counter_order_cancel_check, and the append-only commerce.service_order_cancellations audit.
--
-- Run only against the disposable local harness (supabase/tests/harness/), which replays the migration history INCLUDING the
-- OPPS-owned access layer (public.has_tenant_capability, CAFE-ACCESS-01..03) and
--   20260926280000_cafe_guest_01v_cancel_unpaid_counter_order.sql
-- Orders are created and paid through the REAL 01M / 01Q RPCs under real API roles; other order shapes are inserted directly.
-- Everything is enclosed by BEGIN/ROLLBACK.

\set ON_ERROR_STOP on

begin;

-- ── test-only helpers ────────────────────────────────────────────────────
create function public._cg01v_setup(p_role text, p_sub uuid, p_email text) returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claims',
    case when p_sub is null then '{}'
         else jsonb_strip_nulls(jsonb_build_object('sub', p_sub, 'role', 'authenticated', 'email', p_email))::text end, true);
  execute format('set local role %I', p_role);
end
$$;

-- what a call returns as text: 'ok' or 'STATE message'
create function public._cg01v_try(p_fn text, p_role text, p_sub uuid, p_email text, p_order uuid, p_reason text) returns text
language plpgsql
as $$
declare
  v_state text;
  v_message text;
begin
  perform public._cg01v_setup(p_role, p_sub, p_email);
  if p_fn = 'cancel' then perform public.cancel_quick_solution_counter_order(p_order, p_reason);
  else perform public.get_quick_solution_counter_order_cancel_check(p_order);
  end if;
  execute 'reset role';
  return 'ok';
exception when others then
  get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
  execute 'reset role';
  return v_state || ' ' || v_message;
end
$$;

create function public._cg01v_cancel(p_sub uuid, p_order uuid, p_reason text) returns jsonb
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform public._cg01v_setup('authenticated', p_sub, null);
  v_result := public.cancel_quick_solution_counter_order(p_order, p_reason);
  execute 'reset role';
  return v_result;
end
$$;

create function public._cg01v_check(p_sub uuid, p_order uuid) returns jsonb
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform public._cg01v_setup('authenticated', p_sub, null);
  v_result := public.get_quick_solution_counter_order_cancel_check(p_order);
  execute 'reset role';
  return v_result;
end
$$;

create function public._cg01v_read(p_sub uuid, p_fn text, p_arg uuid default null) returns jsonb
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform public._cg01v_setup('authenticated', p_sub, null);
  if p_fn = 'unpaid' then v_result := public.list_quick_solution_unpaid_counter_orders();
  elsif p_fn = 'today' then v_result := public.list_quick_solution_counter_orders_today();
  elsif p_fn = 'cashup' then v_result := public.get_quick_solution_counter_cashup_today();
  else v_result := public.get_quick_solution_counter_order(p_arg);
  end if;
  execute 'reset role';
  return v_result;
end
$$;

create function public._cg01v_create(p_sub uuid, p_key text, p_product text, p_config jsonb) returns uuid
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform public._cg01v_setup('authenticated', p_sub, null);
  v_result := public.create_quick_solution_counter_order(p_key, p_product, p_config);
  execute 'reset role';
  return (v_result ->> 'orderId')::uuid;
end
$$;

create function public._cg01v_pay_try(p_sub uuid, p_order uuid, p_method text, p_key text) returns text
language plpgsql
as $$
declare
  v_state text;
  v_message text;
  v_result jsonb;
begin
  perform public._cg01v_setup('authenticated', p_sub, null);
  v_result := public.record_quick_solution_counter_payment(p_order, p_method, p_key);
  execute 'reset role';
  return coalesce(v_result ->> 'reason', 'ok');
exception when others then
  get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
  execute 'reset role';
  return v_state || ' ' || v_message;
end
$$;

create function public._cg01v_mk(p_tenant uuid, p_channel text, p_total numeric, p_status text default 'submitted', p_pay text default 'unpaid') returns uuid
language plpgsql
as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into commerce.service_orders(id, tenant_id, order_number, customer_name, idempotency_key, channel, subtotal, total_amount, status, payment_status)
  values (v_id, p_tenant, 'CG01V-' || left(v_id::text, 8), 'CG01V direct', 'CG01V-KEY-' || v_id::text, p_channel, p_total, p_total, p_status, p_pay);
  return v_id;
end
$$;

create function public._cg01v_counts() returns text
language sql
as $$
  select (select count(*) from commerce.service_orders) || '/' || (select count(*) from commerce.service_order_items) || '/' || (select count(*) from commerce.service_order_payments)
         || '/' || (select count(*) from commerce.service_order_cancellations) || '/' || (select count(*) from commerce.service_order_handoffs)
         || '/' || (select coalesce(sum(length(o.status) + length(o.payment_status)), 0) from commerce.service_orders o)
$$;

grant execute on function public._cg01v_setup(text, uuid, text), public._cg01v_try(text, text, uuid, text, uuid, text),
  public._cg01v_cancel(uuid, uuid, text), public._cg01v_check(uuid, uuid), public._cg01v_read(uuid, text, uuid),
  public._cg01v_create(uuid, text, text, jsonb), public._cg01v_pay_try(uuid, uuid, text, text),
  public._cg01v_mk(uuid, text, numeric, text, text), public._cg01v_counts() to anon, authenticated, service_role;

-- ═════════ contracts ═════════
do $contracts$
declare
  v_cancel regprocedure := to_regprocedure('public.cancel_quick_solution_counter_order(uuid,text)');
  v_check regprocedure := to_regprocedure('public.get_quick_solution_counter_order_cancel_check(uuid)');
  v_block regprocedure := to_regprocedure('commerce._qs_counter_cancel_block(commerce.service_orders)');
  v_fn regprocedure;
  v_def text;
begin
  if v_cancel is null or v_check is null or v_block is null then raise exception 'the cancel RPC, the check RPC and the shared rule must exist'; end if;
  if (select array_agg(a order by ord) from pg_catalog.pg_proc p, unnest(p.proargnames) with ordinality as x(a, ord) where p.oid = v_cancel) <> array['p_order_id', 'p_reason'] then
    raise exception 'cancel takes only the order id and the reason: no tenant, channel, status, actor, time or amount';
  end if;
  if (select array_agg(a order by ord) from pg_catalog.pg_proc p, unnest(p.proargnames) with ordinality as x(a, ord) where p.oid = v_check) <> array['p_order_id'] then
    raise exception 'check takes only the order id';
  end if;
  foreach v_fn in array array[v_cancel, v_check] loop
    if pg_catalog.pg_get_function_result(v_fn) <> 'jsonb' then raise exception '% returns jsonb', v_fn; end if;
    if not (select p.prosecdef from pg_catalog.pg_proc p where p.oid = v_fn) then raise exception '% must be SECURITY DEFINER', v_fn; end if;
    if not exists (select 1 from pg_catalog.pg_proc p, lateral pg_catalog.pg_options_to_table(p.proconfig) c where p.oid = v_fn and c.option_name = 'search_path' and btrim(c.option_value, chr(34)) = '') then
      raise exception '% must use an empty hardened search_path', v_fn;
    end if;
    if exists (select 1 from pg_catalog.pg_proc p, lateral pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) acl where p.oid = v_fn and acl.grantee = 0 and acl.privilege_type = 'EXECUTE') then
      raise exception '% must not grant EXECUTE to PUBLIC', v_fn;
    end if;
    if has_function_privilege('anon', v_fn, 'EXECUTE') or has_function_privilege('service_role', v_fn, 'EXECUTE') or not has_function_privilege('authenticated', v_fn, 'EXECUTE') then
      raise exception '% is for authenticated only', v_fn;
    end if;
    v_def := lower(pg_catalog.pg_get_functiondef(v_fn));
    if v_def ~ '(is_app_admin|is_opps_staff|can_access_tenant)' then raise exception '% must have no app-admin / OPPS-staff bypass', v_fn; end if;
    if v_def !~ 't\.slug = ''quick-solution''' or v_def !~ 'so\.channel = ''counter''' or v_def !~ 'so\.tenant_id = v_tenant_id' then raise exception '% canonical tenant, counter channel only', v_fn; end if;
    if v_def !~ '_qs_counter_cancel_block\(v_order\)' then raise exception '% must use the one shared cancel rule', v_fn; end if;
    if v_def ~ '(idempotency_key|source_metadata|pricing_snapshot|pricing_definition|marginrate|suppliercost|auth\.jwt)' then raise exception '% must not touch keys, metadata or pricing', v_fn; end if;
  end loop;
  if (select p.provolatile from pg_catalog.pg_proc p where p.oid = v_check) <> 's' then raise exception 'the check only reads: STABLE'; end if;
  if (select p.provolatile from pg_catalog.pg_proc p where p.oid = v_cancel) <> 'v' then raise exception 'cancel writes: VOLATILE'; end if;
  v_def := lower(pg_catalog.pg_get_functiondef(v_check));
  if v_def ~ '(insert into|update commerce|update public|delete from)' then raise exception 'the check must write nothing'; end if;
  if v_def !~ 'has_tenant_capability\(v_tenant_id, ''cafe\.counter\.operate''\)' or v_def !~ 'has_tenant_capability\(v_tenant_id, ''cafe\.operations\.manage''\)' then
    raise exception 'the check requires counter.operate and reports manage';
  end if;
  v_def := lower(pg_catalog.pg_get_functiondef(v_cancel));
  if v_def !~ 'has_tenant_capability\(v_tenant_id, ''cafe\.operations\.manage''\)' then raise exception 'cancel must require cafe.operations.manage'; end if;
  if v_def like '%cafe.counter.operate%' then raise exception 'cancel must not accept counter.operate alone (and does not need it: admin/owner hold manage)'; end if;
  if v_def !~ 'for update' then raise exception 'cancel must lock the order row (the same lock the counter payment takes)'; end if;
  if v_def !~ 'set status = ''cancelled''' or v_def !~ 'insert into commerce\.service_order_cancellations' then raise exception 'cancel sets the status and writes the audit row'; end if;
  if v_def !~ 'v_actor := auth\.uid\(\)' or v_def !~ 'cancelled_by' then raise exception 'the actor is auth.uid(), never a parameter'; end if;
  if v_def ~ '(payment_status\s*=|delete from|insert into commerce\.service_order_payments|update commerce\.service_order_payments)' then raise exception 'cancel touches nothing but the status and the audit row'; end if;
  v_def := lower(pg_catalog.pg_get_functiondef(v_block));
  if has_function_privilege('anon', v_block, 'EXECUTE') or has_function_privilege('authenticated', v_block, 'EXECUTE') or has_function_privilege('service_role', v_block, 'EXECUTE') then
    raise exception 'the shared rule is internal: no API role may execute it';
  end if;
  if v_def !~ '_qs_order_amount_paid' or v_def !~ 'opps_order_id is not null' or v_def !~ '''sending'', ''sent''' then raise exception 'the rule uses the ledger and the sent-to-production test'; end if;
  -- the audit table: no API access, RLS on, append-only triggers
  if not (select c.relrowsecurity from pg_catalog.pg_class c where c.oid = 'commerce.service_order_cancellations'::regclass) then raise exception 'RLS must be enabled on the audit table'; end if;
  if has_table_privilege('anon', 'commerce.service_order_cancellations', 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE')
     or has_table_privilege('authenticated', 'commerce.service_order_cancellations', 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE')
     or has_table_privilege('service_role', 'commerce.service_order_cancellations', 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE') then
    raise exception 'no API role may touch the audit table';
  end if;
  if (select count(*) from pg_catalog.pg_trigger t where t.tgrelid = 'commerce.service_order_cancellations'::regclass and not t.tgisinternal) <> 2 then
    raise exception 'the audit table has exactly the two append-only triggers';
  end if;
end
$contracts$;

-- ═════════ fixtures ═════════
create table public._cg01v_ctx (k text primary key, v text);

do $fixtures$
declare
  v_suffix text := replace(gen_random_uuid()::text, '-', '');
  v_cafe uuid;
  v_other uuid := gen_random_uuid();
  u record;
begin
  select t.id into v_cafe from public.tenants t where t.slug = 'quick-solution' and t.status = 'active';
  if v_cafe is null then raise exception 'CAFE_GUEST_01V_TEST_SETUP: the quick-solution tenant must exist'; end if;
  insert into public._cg01v_ctx values ('suffix', v_suffix), ('cafe', v_cafe::text), ('other', v_other::text);
  insert into public.tenants(id, slug, name, status, settings) values (v_other, 'cg01v-other-' || left(v_suffix, 10), 'CG01V other cafe', 'active', '{}'::jsonb);
  insert into public.tenant_capabilities(tenant_id, capability_key, enabled) values (v_other, 'quick_solution', true);

  for u in select * from (values ('nomember'), ('member'), ('member2'), ('admin'), ('admin2'), ('owner'), ('suspended'), ('otherowner'), ('appadmin'), ('oppsstaff')) as x(label) loop
    insert into public._cg01v_ctx values ('u_' || u.label, gen_random_uuid()::text);
    insert into auth.users(id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values ((select v::uuid from public._cg01v_ctx where k = 'u_' || u.label), 'authenticated', 'authenticated', 'cg01v-' || u.label || '-' || v_suffix || '@disposable.test', now(), '{}'::jsonb, '{}'::jsonb, now(), now());
  end loop;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', (select v from public._cg01v_ctx where k = 'u_appadmin'), 'role', 'authenticated', 'email', 'jointx.co@gmail.com')::text, true);
  insert into public.users(auth_user_id, user_email, full_name, role, is_active)
  values ((select v::uuid from public._cg01v_ctx where k = 'u_appadmin'), 'cg01v-appadmin-' || v_suffix || '@disposable.test', 'CG01V app admin', 'admin', true),
         ((select v::uuid from public._cg01v_ctx where k = 'u_oppsstaff'), 'cg01v-oppsstaff-' || v_suffix || '@disposable.test', 'CG01V OPPS staff', 'user', true);
  perform set_config('request.jwt.claims', '{}', true);
  if lower(coalesce(auth.jwt() ->> 'email', '')) <> '' then raise exception 'CAFE_GUEST_01V_TEST_SETUP: the temporary approved-owner claim must be cleared'; end if;

  insert into public.tenant_memberships(tenant_id, auth_user_id, tenant_role, status)
  select v_cafe, (select v::uuid from public._cg01v_ctx where k = 'u_' || m.label), m.role, m.status
  from (values ('member', 'member', 'active'), ('member2', 'member', 'active'), ('admin', 'admin', 'active'), ('admin2', 'admin', 'active'), ('owner', 'owner', 'active'), ('suspended', 'admin', 'suspended')) as m(label, role, status);
  insert into public.tenant_memberships(tenant_id, auth_user_id, tenant_role, status)
  values (v_other, (select v::uuid from public._cg01v_ctx where k = 'u_otherowner'), 'owner', 'active');
  if exists (select 1 from public.tenant_memberships m where m.tenant_id = v_cafe and m.auth_user_id in
     ((select v::uuid from public._cg01v_ctx where k = 'u_appadmin'), (select v::uuid from public._cg01v_ctx where k = 'u_oppsstaff'))) then
    raise exception 'CAFE_GUEST_01V_TEST_SETUP: the app-admin and OPPS-staff fixtures must have no Cafe membership';
  end if;
end
$fixtures$;

-- ═════════ access, module and tenant state ═════════
do $access$
declare
  c_signin constant text := '42501 Staff sign-in is required.';
  c_denied constant text := '42501 Only a Quick Solution admin or owner can cancel a counter order.';
  c_counter_denied constant text := '42501 You do not have access to the Quick Solution counter.';
  c_no_tenant constant text := '22023 Quick Solution tenant was not found.';
  c_no_module constant text := '22023 Quick Solution counter is not active.';
  c_reason constant text := '22023 A reason for the cancellation is required.';
  v_cafe uuid := (select v::uuid from public._cg01v_ctx where k = 'cafe');
  u_nomember uuid := (select v::uuid from public._cg01v_ctx where k = 'u_nomember');
  u_member uuid := (select v::uuid from public._cg01v_ctx where k = 'u_member');
  u_admin uuid := (select v::uuid from public._cg01v_ctx where k = 'u_admin');
  u_owner uuid := (select v::uuid from public._cg01v_ctx where k = 'u_owner');
  u_suspended uuid := (select v::uuid from public._cg01v_ctx where k = 'u_suspended');
  u_otherowner uuid := (select v::uuid from public._cg01v_ctx where k = 'u_otherowner');
  u_appadmin uuid := (select v::uuid from public._cg01v_ctx where k = 'u_appadmin');
  u_oppsstaff uuid := (select v::uuid from public._cg01v_ctx where k = 'u_oppsstaff');
  v_order uuid := public._cg01v_mk(v_cafe, 'counter', 30);
  v_labels text[]; v_subs uuid[]; v_emails text[]; v_expect text[]; v_check_expect text[];
  i integer; v_got text; v_state text; v_before text := public._cg01v_counts();
  v_module public.tenant_capabilities;
begin
  v_labels := array['anonymous', 'authenticated non-member', 'active member', 'active admin', 'active owner', 'suspended admin',
                    'owner of a FOREIGN tenant', 'app admin with no Cafe membership', 'app admin with the approved-owner email', 'OPPS staff with no Cafe membership']::text[];
  v_subs := array[null, u_nomember, u_member, u_admin, u_owner, u_suspended, u_otherowner, u_appadmin, u_appadmin, u_oppsstaff]::uuid[];
  v_emails := array[null, null, null, null, null, null, null, null, 'jointx.co@gmail.com', null]::text[];
  -- with an EMPTY reason: only a caller who passes authorization reaches the reason rule, so this shows exactly who gets past the gate
  v_expect := array[c_signin, c_denied, c_denied, c_reason, c_reason, c_denied, c_denied, c_denied, c_denied, c_denied]::text[];
  for i in 1 .. array_length(v_labels, 1) loop
    v_got := public._cg01v_try('cancel', 'authenticated', v_subs[i], v_emails[i], v_order, '');
    if v_got is distinct from v_expect[i] then raise exception 'CAFE_GUEST_01V: cancel access for "%" expected "%" but got "%"', v_labels[i], v_expect[i], v_got; end if;
  end loop;
  -- the check screen: any counter operator may ask; only admin / owner are "permitted"
  v_check_expect := array[c_signin, c_counter_denied, 'ok', 'ok', 'ok', c_counter_denied, c_counter_denied, c_counter_denied, c_counter_denied, c_counter_denied]::text[];
  for i in 1 .. array_length(v_labels, 1) loop
    v_got := public._cg01v_try('check', 'authenticated', v_subs[i], v_emails[i], v_order, null);
    if v_got is distinct from v_check_expect[i] then raise exception 'CAFE_GUEST_01V: check access for "%" expected "%" but got "%"', v_labels[i], v_check_expect[i], v_got; end if;
  end loop;
  if (public._cg01v_check(u_member, v_order) ->> 'permitted')::boolean is not false
     or (public._cg01v_check(u_admin, v_order) ->> 'permitted')::boolean is not true
     or (public._cg01v_check(u_owner, v_order) ->> 'permitted')::boolean is not true then
    raise exception 'CAFE_GUEST_01V: only admin and owner are permitted, a plain member is not';
  end if;
  foreach v_state in array array['anon', 'service_role'] loop
    if public._cg01v_try('cancel', v_state, u_owner, null, v_order, 'because') not like '42501 permission denied for function cancel_quick_solution_counter_order%' then raise exception 'CAFE_GUEST_01V: % must be refused at the cancel ACL', v_state; end if;
    if public._cg01v_try('check', v_state, u_owner, null, v_order, null) not like '42501 permission denied for function get_quick_solution_counter_order_cancel_check%' then raise exception 'CAFE_GUEST_01V: % must be refused at the check ACL', v_state; end if;
  end loop;
  -- module and tenant state; authorization comes first
  select * into v_module from public.tenant_capabilities tc where tc.tenant_id = v_cafe and tc.capability_key = 'quick_solution';
  update public.tenant_capabilities set enabled = false where id = v_module.id;
  if public._cg01v_try('cancel', 'authenticated', u_admin, null, v_order, 'because') is distinct from c_no_module or public._cg01v_try('cancel', 'authenticated', u_owner, null, v_order, 'because') is distinct from c_no_module then raise exception 'CAFE_GUEST_01V: a disabled module denies'; end if;
  if public._cg01v_try('cancel', 'authenticated', u_member, null, v_order, 'because') is distinct from c_denied then raise exception 'CAFE_GUEST_01V: authorization comes before the module check'; end if;
  update public.tenant_capabilities set enabled = true where id = v_module.id;
  foreach v_state in array array['suspended', 'archived'] loop
    update public.tenants set status = v_state where id = v_cafe;
    if public._cg01v_try('cancel', 'authenticated', u_admin, null, v_order, 'because') is distinct from c_no_tenant then raise exception 'CAFE_GUEST_01V: a % tenant fails closed', v_state; end if;
  end loop;
  update public.tenants set status = 'active' where id = v_cafe;
  update public.tenant_memberships set status = 'suspended' where tenant_id = v_cafe and auth_user_id = u_admin;
  if public._cg01v_try('cancel', 'authenticated', u_admin, null, v_order, 'because') is distinct from c_denied then raise exception 'CAFE_GUEST_01V: a just-suspended admin is denied'; end if;
  update public.tenant_memberships set status = 'active' where tenant_id = v_cafe and auth_user_id = u_admin;
  if public._cg01v_counts() is distinct from v_before then raise exception 'CAFE_GUEST_01V: no denied call, and no check, wrote anything'; end if;
end
$access$;

-- ═════════ the cancel: success, audit, effects, retry ═════════
do $cancel$
declare
  v_suffix text := (select v from public._cg01v_ctx where k = 'suffix');
  v_cafe uuid := (select v::uuid from public._cg01v_ctx where k = 'cafe');
  u_member uuid := (select v::uuid from public._cg01v_ctx where k = 'u_member');
  u_admin uuid := (select v::uuid from public._cg01v_ctx where k = 'u_admin');
  u_admin2 uuid := (select v::uuid from public._cg01v_ctx where k = 'u_admin2');
  u_owner uuid := (select v::uuid from public._cg01v_ctx where k = 'u_owner');
  v_a uuid; v_b uuid; v_c uuid; v_keep uuid;
  v_r jsonb; v_before text; v_audit commerce.service_order_cancellations; v_order commerce.service_orders; v_old commerce.service_orders;
  v_items_before integer; v_text text; v_unpaid_before integer;
begin
  v_a := public._cg01v_create(u_member, 'cg01v-' || v_suffix || '-a', 'scan', '{"units":4}');
  v_b := public._cg01v_create(u_member, 'cg01v-' || v_suffix || '-b', 'a4-lamination', '{"units":3}');
  v_c := public._cg01v_create(u_member, 'cg01v-' || v_suffix || '-c', 'a3-lamination', '{"units":2}');
  v_keep := public._cg01v_create(u_member, 'cg01v-' || v_suffix || '-keep', 'scan', '{"units":1}');
  select * into v_old from commerce.service_orders where id = v_a;
  if v_old.status <> 'submitted' or v_old.payment_status <> 'unpaid' then raise exception 'CAFE_GUEST_01V: setup, a counter order starts submitted and unpaid, got % %', v_old.status, v_old.payment_status; end if;
  select count(*) into v_items_before from commerce.service_order_items where order_id = v_a;
  v_unpaid_before := (public._cg01v_read(u_member, 'cashup') -> 'orders' ->> 'unpaidToday')::integer;

  -- what the screen sees: a member cannot cancel, an admin can
  v_r := public._cg01v_check(u_member, v_a);
  if (v_r ->> 'permitted')::boolean or not (v_r ->> 'cancellable')::boolean or v_r ->> 'block' is not null then raise exception 'CAFE_GUEST_01V: member sees an order that could be cancelled but is not permitted, got %', v_r; end if;
  v_r := public._cg01v_check(u_admin, v_a);
  if not (v_r ->> 'permitted')::boolean or not (v_r ->> 'cancellable')::boolean then raise exception 'CAFE_GUEST_01V: admin may cancel a fresh unpaid order, got %', v_r; end if;

  -- a plain member cannot cancel, and nothing changes
  v_before := public._cg01v_counts();
  if public._cg01v_try('cancel', 'authenticated', u_member, null, v_a, 'Customer changed mind') not like '42501 Only a Quick Solution admin or owner%' then raise exception 'CAFE_GUEST_01V: a member cannot cancel'; end if;
  if public._cg01v_counts() is distinct from v_before then raise exception 'CAFE_GUEST_01V: the refused member changed something'; end if;

  -- the admin cancels; the reason is trimmed
  v_r := public._cg01v_cancel(u_admin, v_a, '   Customer changed their mind   ');
  if not (v_r ->> 'ok')::boolean or (v_r ->> 'replayed')::boolean or v_r ->> 'status' <> 'cancelled' or v_r ->> 'reason' <> 'Customer changed their mind'
     or (v_r ->> 'orderId')::uuid <> v_a then
    raise exception 'CAFE_GUEST_01V: cancel result, got %', v_r;
  end if;
  v_text := v_r::text;
  if v_text ~* (u_admin::text || '|' || v_cafe::text) then raise exception 'CAFE_GUEST_01V: the response must not carry the actor or tenant id: %', v_text; end if;
  select * into v_order from commerce.service_orders where id = v_a;
  if v_order.status <> 'cancelled' or v_order.payment_status <> v_old.payment_status or v_order.total_amount <> v_old.total_amount or v_order.order_number <> v_old.order_number
     or v_order.customer_name is distinct from v_old.customer_name or v_order.channel <> 'counter' or v_order.tenant_id <> v_cafe then
    raise exception 'CAFE_GUEST_01V: only the status changed, got %', to_jsonb(v_order);
  end if;
  if (select count(*) from commerce.service_order_items where order_id = v_a) <> v_items_before then raise exception 'CAFE_GUEST_01V: the items are kept'; end if;
  if (select count(*) from commerce.service_order_payments where service_order_id = v_a) <> 0 then raise exception 'CAFE_GUEST_01V: no payment row is created or removed'; end if;
  -- the audit
  select * into v_audit from commerce.service_order_cancellations where service_order_id = v_a;
  if v_audit.id is null or v_audit.cancelled_by <> u_admin or v_audit.tenant_id <> v_cafe or v_audit.reason <> 'Customer changed their mind'
     or v_audit.prior_status <> 'submitted' or v_audit.prior_payment_status <> 'unpaid' or v_audit.order_total <> v_old.total_amount
     or v_audit.outstanding_at_cancel <> v_old.total_amount or v_audit.cancelled_at is null
     or abs(extract(epoch from (now() - v_audit.cancelled_at))) > 60 then
    raise exception 'CAFE_GUEST_01V: the audit row records who, when, why and what it was, got %', to_jsonb(v_audit);
  end if;
  if (select count(*) from commerce.service_order_cancellations) <> 1 then raise exception 'CAFE_GUEST_01V: exactly one audit row'; end if;

  -- what everything else now says
  v_r := public._cg01v_check(u_admin, v_a);
  if (v_r ->> 'cancellable')::boolean or v_r ->> 'block' <> 'already_cancelled' then raise exception 'CAFE_GUEST_01V: the check now says already_cancelled, got %', v_r; end if;
  v_r := public._cg01v_read(u_member, 'detail', v_a);
  if v_r ->> 'status' <> 'cancelled' or (v_r ->> 'paymentAllowed')::boolean then raise exception 'CAFE_GUEST_01V: the detail shows cancelled and takes no payment, got %', v_r; end if;
  if exists (select 1 from jsonb_array_elements(public._cg01v_read(u_member, 'unpaid') -> 'orders') o where o ->> 'orderId' = v_a::text) then raise exception 'CAFE_GUEST_01V: a cancelled order leaves the unpaid list'; end if;
  if exists (select 1 from jsonb_array_elements(public._cg01v_read(u_member, 'cashup') -> 'unpaid' -> 'orders') o where o ->> 'orderId' = v_a::text)
     or (public._cg01v_read(u_member, 'cashup') -> 'orders' ->> 'unpaidToday')::integer <> v_unpaid_before - 1 then
    raise exception 'CAFE_GUEST_01V: a cancelled order leaves the cash-up unpaid figure';
  end if;
  if public._cg01v_pay_try(u_member, v_a, 'cash', 'cg01v-' || v_suffix || '-pay-a') not like '22023 This order cannot take a payment.' then raise exception 'CAFE_GUEST_01V: a cancelled order can take no payment'; end if;
  if public._cg01v_pay_try(u_admin, v_a, 'card', 'cg01v-' || v_suffix || '-pay-a2') not like '22023 This order cannot take a payment.' then raise exception 'CAFE_GUEST_01V: not even an admin can pay a cancelled order'; end if;
  if (select count(*) from commerce.service_order_payments where service_order_id = v_a) <> 0 then raise exception 'CAFE_GUEST_01V: refused payments wrote nothing'; end if;

  -- retry: same admin + same reason replays, writes nothing; a different reason or admin is refused
  v_before := public._cg01v_counts();
  v_r := public._cg01v_cancel(u_admin, v_a, 'Customer changed their mind');
  if not (v_r ->> 'ok')::boolean or not (v_r ->> 'replayed')::boolean or v_r ->> 'reason' <> 'Customer changed their mind' or (v_r ->> 'cancelledAt')::timestamptz <> v_audit.cancelled_at then raise exception 'CAFE_GUEST_01V: a retry replays the original, got %', v_r; end if;
  if public._cg01v_try('cancel', 'authenticated', u_admin, null, v_a, 'A different reason') is distinct from '22023 This order is already cancelled.' then raise exception 'CAFE_GUEST_01V: a different reason on a cancelled order is refused'; end if;
  if public._cg01v_try('cancel', 'authenticated', u_admin2, null, v_a, 'Customer changed their mind') is distinct from '22023 This order is already cancelled.' then raise exception 'CAFE_GUEST_01V: another admin cannot replay'; end if;
  if public._cg01v_counts() is distinct from v_before then raise exception 'CAFE_GUEST_01V: retries and refusals wrote nothing'; end if;

  -- an owner cancels another; both audit rows carry their own actor and reason
  v_r := public._cg01v_cancel(u_owner, v_b, 'Entered for the wrong customer');
  if not (v_r ->> 'ok')::boolean then raise exception 'CAFE_GUEST_01V: an owner may cancel'; end if;
  if (select cancelled_by from commerce.service_order_cancellations where service_order_id = v_b) <> u_owner or (select count(*) from commerce.service_order_cancellations) <> 2 then raise exception 'CAFE_GUEST_01V: the owner is the actor of the second row'; end if;

  -- a failed order that never took money can also be cancelled
  update commerce.service_orders set payment_status = 'failed' where id = v_c;
  v_r := public._cg01v_check(u_admin, v_c);
  if not (v_r ->> 'cancellable')::boolean then raise exception 'CAFE_GUEST_01V: a failed-payment order with no money is cancellable, got %', v_r; end if;
  perform public._cg01v_cancel(u_admin, v_c, 'Payment failed and customer left');
  if (select prior_payment_status from commerce.service_order_cancellations where service_order_id = v_c) <> 'failed' or (select payment_status from commerce.service_orders where id = v_c) <> 'failed' then raise exception 'CAFE_GUEST_01V: the failed payment status is recorded and left alone'; end if;

  -- other orders are untouched
  if (select status from commerce.service_orders where id = v_keep) <> 'submitted' then raise exception 'CAFE_GUEST_01V: another order was touched'; end if;
  if not exists (select 1 from jsonb_array_elements(public._cg01v_read(u_member, 'unpaid') -> 'orders') o where o ->> 'orderId' = v_keep::text) then raise exception 'CAFE_GUEST_01V: the other order is still listed as unpaid'; end if;
end
$cancel$;

-- ═════════ what may not be cancelled ═════════
do $blocks$
declare
  v_suffix text := (select v from public._cg01v_ctx where k = 'suffix');
  v_cafe uuid := (select v::uuid from public._cg01v_ctx where k = 'cafe');
  v_other uuid := (select v::uuid from public._cg01v_ctx where k = 'other');
  u_member uuid := (select v::uuid from public._cg01v_ctx where k = 'u_member');
  u_admin uuid := (select v::uuid from public._cg01v_ctx where k = 'u_admin');
  u_otherowner uuid := (select v::uuid from public._cg01v_ctx where k = 'u_otherowner');
  v_id uuid; v_x uuid; s text; v_before text; v_msg text; v_r jsonb;
  v_status_expect jsonb := jsonb_build_object('draft', 'not_cancellable', 'accepted', 'in_progress', 'in_production', 'in_progress', 'ready', 'in_progress', 'completed', 'in_progress');
begin
  -- helper: assert that cancelling order X is refused with message M and block B, and that nothing changed
  -- (inlined below as a loop over cases)
  declare
    v_cases jsonb := '[]'::jsonb;
    c jsonb;
  begin
    -- paid through the real payment RPC
    v_id := public._cg01v_create(u_member, 'cg01v-' || v_suffix || '-paid', 'scan', '{"units":4}');
    if public._cg01v_pay_try(u_member, v_id, 'cash', 'cg01v-' || v_suffix || '-paidkey') <> 'ok' then raise exception 'CAFE_GUEST_01V: setup, pay the order'; end if;
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('id', v_id, 'block', 'has_payment', 'msg', '22023 This order has a payment and cannot be cancelled.'));
    -- unpaid string but a completed ledger row (part payment / gateway)
    v_id := public._cg01v_mk(v_cafe, 'counter', 40);
    insert into commerce.service_order_payments(tenant_id, service_order_id, provider, status, amount, completed_at) values (v_cafe, v_id, 'payfast', 'completed', 15, now());
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('id', v_id, 'block', 'has_payment', 'msg', '22023 This order has a payment and cannot be cancelled.'));
    -- refunded
    v_id := public._cg01v_mk(v_cafe, 'counter', 40, 'submitted', 'refunded');
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('id', v_id, 'block', 'has_payment', 'msg', '22023 This order has a payment and cannot be cancelled.'));
    -- a gateway payment still pending, and a pending payment status
    v_id := public._cg01v_mk(v_cafe, 'counter', 40);
    insert into commerce.service_order_payments(tenant_id, service_order_id, provider, status, amount) values (v_cafe, v_id, 'payfast', 'pending', 40);
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('id', v_id, 'block', 'payment_in_progress', 'msg', '22023 A payment for this order is still in progress, so it cannot be cancelled.'));
    v_id := public._cg01v_mk(v_cafe, 'counter', 40, 'submitted', 'pending');
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('id', v_id, 'block', 'payment_in_progress', 'msg', '22023 A payment for this order is still in progress, so it cannot be cancelled.'));
    -- sent on: an OPPS order id, and a sending / sent handoff
    v_id := public._cg01v_mk(v_cafe, 'counter', 40);
    update commerce.service_orders set opps_order_id = gen_random_uuid() where id = v_id;
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('id', v_id, 'block', 'sent_to_production', 'msg', '22023 This order has already been sent to production and cannot be cancelled here.'));
    foreach s in array array['sending', 'sent'] loop
      v_id := public._cg01v_mk(v_cafe, 'counter', 40);
      insert into commerce.service_order_handoffs(service_order_id, source_tenant_id, target_tenant_id, status, idempotency_key) values (v_id, v_cafe, v_cafe, s, 'CG01V-HO-' || v_id::text);
      v_cases := v_cases || jsonb_build_array(jsonb_build_object('id', v_id, 'block', 'sent_to_production', 'msg', '22023 This order has already been sent to production and cannot be cancelled here.'));
    end loop;
    -- order states other than submitted
    for s in select jsonb_object_keys(v_status_expect) loop
      v_id := public._cg01v_mk(v_cafe, 'counter', 40, s);
      v_cases := v_cases || jsonb_build_array(jsonb_build_object('id', v_id, 'block', v_status_expect ->> s,
        'msg', case v_status_expect ->> s when 'in_progress' then '22023 This order is already being worked on and cannot be cancelled here.' else '22023 This order cannot be cancelled.' end));
    end loop;
    -- nothing to cancel: zero value
    v_id := public._cg01v_mk(v_cafe, 'counter', 0);
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('id', v_id, 'block', 'nothing_outstanding', 'msg', '22023 This order has nothing outstanding to cancel.'));
    -- a stored payment status that is neither settled nor open
    v_id := public._cg01v_mk(v_cafe, 'counter', 40, 'submitted', 'cancelled');
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('id', v_id, 'block', 'not_payable_state', 'msg', '22023 This order cannot be cancelled.'));

    v_before := public._cg01v_counts();
    for c in select * from jsonb_array_elements(v_cases) loop
      v_msg := public._cg01v_try('cancel', 'authenticated', u_admin, null, (c ->> 'id')::uuid, 'Trying to cancel');
      if v_msg is distinct from (c ->> 'msg') then raise exception 'CAFE_GUEST_01V: block % expected "%" but got "%"', c ->> 'block', c ->> 'msg', v_msg; end if;
      v_r := public._cg01v_check(u_admin, (c ->> 'id')::uuid);
      if (v_r ->> 'cancellable')::boolean or v_r ->> 'block' is distinct from (c ->> 'block') or not (v_r ->> 'permitted')::boolean then raise exception 'CAFE_GUEST_01V: the check reports block %, got %', c ->> 'block', v_r; end if;
    end loop;
    if public._cg01v_counts() is distinct from v_before then raise exception 'CAFE_GUEST_01V: every refused cancel, and every check, wrote nothing (no status, no audit row)'; end if;
  end;

  -- handoffs that have sent nothing do not stop a cancel (and a cancelled order can no longer be sent)
  foreach s in array array['previewed', 'blocked', 'ready', 'failed'] loop
    v_id := public._cg01v_mk(v_cafe, 'counter', 40);
    insert into commerce.service_order_handoffs(service_order_id, source_tenant_id, target_tenant_id, status, idempotency_key) values (v_id, v_cafe, v_cafe, s, 'CG01V-HO2-' || v_id::text);
    if public._cg01v_try('cancel', 'authenticated', u_admin, null, v_id, 'Not sent, so cancel') is distinct from 'ok' then raise exception 'CAFE_GUEST_01V: a % handoff has sent nothing and does not block', s; end if;
    if (select status from commerce.service_orders where id = v_id) <> 'cancelled' then raise exception 'CAFE_GUEST_01V: cancelled despite a % handoff', s; end if;
  end loop;
  if pg_catalog.pg_get_functiondef('commerce.qs_build_opps_handoff_preview(uuid)'::regprocedure) !~* 'v_order\.status in \(''cancelled'',''completed''\)[^;]*ORDER_CLOSED' then
    raise exception 'CAFE_GUEST_01V: the OPPS handoff preview must refuse a cancelled order (ORDER_CLOSED)';
  end if;

  -- not a counter order of the Cafe: all the same "not found"
  v_before := public._cg01v_counts();
  v_x := public._cg01v_mk(v_cafe, 'storefront', 40);
  v_id := public._cg01v_mk(v_other, 'counter', 40);
  foreach v_id in array array[v_x, v_id, gen_random_uuid()] loop
    if public._cg01v_try('cancel', 'authenticated', u_admin, null, v_id, 'Trying to cancel') is distinct from '22023 Counter order was not found.' then raise exception 'CAFE_GUEST_01V: a storefront, foreign or unknown order is not found'; end if;
    if public._cg01v_try('check', 'authenticated', u_admin, null, v_id, null) is distinct from '22023 Counter order was not found.' then raise exception 'CAFE_GUEST_01V: the check does not find it either'; end if;
    if public._cg01v_try('cancel', 'authenticated', u_otherowner, null, v_id, 'Trying to cancel') like 'ok%' then raise exception 'CAFE_GUEST_01V: the owner of another cafe cancels nothing here'; end if;
  end loop;
  if public._cg01v_try('cancel', 'authenticated', u_admin, null, null, 'Trying to cancel') is distinct from '22023 Counter order was not found.' then raise exception 'CAFE_GUEST_01V: a null order id is not found'; end if;
  if (select status from commerce.service_orders where id = v_x) <> 'submitted' or (select status from commerce.service_orders where tenant_id = v_other limit 1) <> 'submitted' then raise exception 'CAFE_GUEST_01V: a storefront or foreign order was cancelled'; end if;
  if (select count(*) from commerce.service_order_cancellations where service_order_id in (v_x)) <> 0 then raise exception 'CAFE_GUEST_01V: nothing audited for them'; end if;
end
$blocks$;

-- ═════════ the reason ═════════
do $reason$
declare
  v_suffix text := (select v from public._cg01v_ctx where k = 'suffix');
  v_cafe uuid := (select v::uuid from public._cg01v_ctx where k = 'cafe');
  u_admin uuid := (select v::uuid from public._cg01v_ctx where k = 'u_admin');
  v_id uuid := public._cg01v_mk(v_cafe, 'counter', 25);
  v_before text := public._cg01v_counts();
  v_r jsonb;
begin
  if public._cg01v_try('cancel', 'authenticated', u_admin, null, v_id, null) is distinct from '22023 A reason for the cancellation is required.'
     or public._cg01v_try('cancel', 'authenticated', u_admin, null, v_id, '') is distinct from '22023 A reason for the cancellation is required.'
     or public._cg01v_try('cancel', 'authenticated', u_admin, null, v_id, '     ') is distinct from '22023 A reason for the cancellation is required.'
     or public._cg01v_try('cancel', 'authenticated', u_admin, null, v_id, ' ab ') is distinct from '22023 A reason for the cancellation is required.' then
    raise exception 'CAFE_GUEST_01V: a missing, blank or two-character reason is refused';
  end if;
  if public._cg01v_try('cancel', 'authenticated', u_admin, null, v_id, repeat('x', 301)) is distinct from '22023 The cancellation reason is too long.' then raise exception 'CAFE_GUEST_01V: 301 characters is too long'; end if;
  if public._cg01v_try('cancel', 'authenticated', u_admin, null, v_id, 'line one' || chr(10) || 'line two') is distinct from '22023 The cancellation reason is not valid.'
     or public._cg01v_try('cancel', 'authenticated', u_admin, null, v_id, 'tab' || chr(9) || 'char') is distinct from '22023 The cancellation reason is not valid.' then
    raise exception 'CAFE_GUEST_01V: control characters are refused';
  end if;
  if public._cg01v_counts() is distinct from v_before then raise exception 'CAFE_GUEST_01V: a bad reason writes nothing'; end if;
  -- 3 and 300 characters are fine
  v_r := public._cg01v_cancel(u_admin, v_id, repeat('y', 300));
  if length(v_r ->> 'reason') <> 300 then raise exception 'CAFE_GUEST_01V: 300 characters is the limit'; end if;
  v_id := public._cg01v_mk(v_cafe, 'counter', 25);
  v_r := public._cg01v_cancel(u_admin, v_id, ' abc ');
  if v_r ->> 'reason' <> 'abc' then raise exception 'CAFE_GUEST_01V: three characters is the minimum, and the reason is trimmed'; end if;
end
$reason$;

-- ═════════ append-only audit ═════════
do $audit$
declare
  v_cafe uuid := (select v::uuid from public._cg01v_ctx where k = 'cafe');
  u_admin uuid := (select v::uuid from public._cg01v_ctx where k = 'u_admin');
  v_id uuid := public._cg01v_mk(v_cafe, 'counter', 25);
  v_state text; v_message text;
begin
  perform public._cg01v_cancel(u_admin, v_id, 'For the audit test');
  begin update commerce.service_order_cancellations set reason = 'rewritten' where service_order_id = v_id; raise exception 'CAFE_GUEST_01V: an audit row could be updated'; exception when others then get stacked diagnostics v_state = returned_sqlstate, v_message = message_text; if v_state <> '23514' or v_message not like 'SERVICE_ORDER_CANCELLATION_APPEND_ONLY%' then raise; end if; end;
  begin delete from commerce.service_order_cancellations where service_order_id = v_id; raise exception 'CAFE_GUEST_01V: an audit row could be deleted'; exception when others then get stacked diagnostics v_state = returned_sqlstate, v_message = message_text; if v_state <> '23514' or v_message not like 'SERVICE_ORDER_CANCELLATION_APPEND_ONLY%' then raise; end if; end;
  begin truncate commerce.service_order_cancellations; raise exception 'CAFE_GUEST_01V: the audit table could be truncated'; exception when others then get stacked diagnostics v_state = returned_sqlstate, v_message = message_text; if v_state <> '23514' or v_message not like 'SERVICE_ORDER_CANCELLATION_APPEND_ONLY%' then raise; end if; end;
  begin
    insert into commerce.service_order_cancellations(tenant_id, service_order_id, cancelled_by, reason, prior_status, prior_payment_status, order_total, outstanding_at_cancel)
    values (v_cafe, v_id, u_admin, 'A second row for one order', 'submitted', 'unpaid', 25, 25);
    raise exception 'CAFE_GUEST_01V: a second audit row for one order was accepted';
  exception when unique_violation then null; end;
  begin
    insert into commerce.service_order_cancellations(tenant_id, service_order_id, cancelled_by, reason, prior_status, prior_payment_status, order_total, outstanding_at_cancel)
    values (v_cafe, public._cg01v_mk(v_cafe, 'counter', 5), u_admin, ' padded ', 'submitted', 'unpaid', 5, 5);
    raise exception 'CAFE_GUEST_01V: an untrimmed reason was accepted';
  exception when check_violation then null; end;
  -- the API roles cannot read or write it
  foreach v_state in array array['anon', 'authenticated', 'service_role'] loop
    begin
      perform public._cg01v_setup(v_state, u_admin, null);
      perform count(*) from commerce.service_order_cancellations;
      execute 'reset role';
      raise exception 'CAFE_GUEST_01V: % could read the audit table', v_state;
    exception when insufficient_privilege then execute 'reset role'; end;
  end loop;
  -- and the order itself: a cancel needs the audit row, so the two cannot drift
  if (select count(*) from commerce.service_orders o where o.status = 'cancelled' and o.channel = 'counter' and o.id in (select service_order_id from commerce.service_order_cancellations)) <> (select count(*) from commerce.service_order_cancellations) then
    raise exception 'CAFE_GUEST_01V: every audit row belongs to a cancelled counter order';
  end if;
end
$audit$;

rollback;
select 'CAFE-GUEST-01V cancel unpaid counter order contracts passed' as result;
