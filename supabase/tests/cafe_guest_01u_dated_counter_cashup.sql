-- CAFE-GUEST-01U: behavioral contract test for public.get_quick_solution_counter_cashup(date) and its relationship to today's cash-up.
--
-- Run only against the disposable local harness (supabase/tests/harness/), which replays the migration history INCLUDING the OPPS-owned
-- access layer (public.has_tenant_capability, CAFE-ACCESS-01..03) and
--   20260926270000_cafe_guest_01u_dated_counter_cashup.sql
-- The harness skips this test, visibly, when the OPPS access layer is absent. Orders are created and paid through the REAL 01M / 01Q RPCs
-- under real API roles; their timestamps are then moved to the selected days to test the day rules at exact instants. Everything is
-- enclosed by BEGIN/ROLLBACK.

\set ON_ERROR_STOP on

begin;

-- ── test-only helpers ────────────────────────────────────────────────────
create function public._cg01u_setup(p_role text, p_sub uuid, p_email text) returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claims',
    case when p_sub is null then '{}'
         else jsonb_strip_nulls(jsonb_build_object('sub', p_sub, 'role', 'authenticated', 'email', p_email))::text end, true);
  execute format('set local role %I', p_role);
end
$$;

create function public._cg01u_try(p_role text, p_sub uuid, p_email text, p_date date) returns text
language plpgsql
as $$
declare
  v_state text;
  v_message text;
begin
  perform public._cg01u_setup(p_role, p_sub, p_email);
  perform public.get_quick_solution_counter_cashup(p_date);
  execute 'reset role';
  return 'ok';
exception when others then
  get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
  execute 'reset role';
  return v_state || ' ' || v_message;
end
$$;

create function public._cg01u_cashup(p_sub uuid, p_date date) returns jsonb
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform public._cg01u_setup('authenticated', p_sub, null);
  v_result := public.get_quick_solution_counter_cashup(p_date);
  execute 'reset role';
  return v_result;
end
$$;

create function public._cg01u_today(p_sub uuid) returns jsonb
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform public._cg01u_setup('authenticated', p_sub, null);
  v_result := public.get_quick_solution_counter_cashup_today();
  execute 'reset role';
  return v_result;
end
$$;

create function public._cg01u_create(p_sub uuid, p_key text, p_product text, p_config jsonb) returns uuid
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform public._cg01u_setup('authenticated', p_sub, null);
  v_result := public.create_quick_solution_counter_order(p_key, p_product, p_config);
  execute 'reset role';
  return (v_result ->> 'orderId')::uuid;
end
$$;

create function public._cg01u_pay(p_sub uuid, p_order uuid, p_method text, p_key text) returns jsonb
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform public._cg01u_setup('authenticated', p_sub, null);
  v_result := public.record_quick_solution_counter_payment(p_order, p_method, p_key);
  execute 'reset role';
  return v_result;
end
$$;

create function public._cg01u_mk(p_tenant uuid, p_channel text, p_total numeric, p_status text default 'submitted', p_pay text default 'unpaid') returns uuid
language plpgsql
as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into commerce.service_orders(id, tenant_id, order_number, customer_name, idempotency_key, channel, subtotal, total_amount, status, payment_status)
  values (v_id, p_tenant, 'CG01U-' || left(v_id::text, 8), 'CG01U direct', 'CG01U-KEY-' || v_id::text, p_channel, p_total, p_total, p_status, p_pay);
  return v_id;
end
$$;

create function public._cg01u_counts() returns text
language sql
as $$
  select (select count(*) from commerce.service_orders) || '/' || (select count(*) from commerce.service_order_items) || '/' || (select count(*) from commerce.service_order_payments)
$$;

grant execute on function public._cg01u_setup(text, uuid, text), public._cg01u_try(text, uuid, text, date), public._cg01u_cashup(uuid, date), public._cg01u_today(uuid),
  public._cg01u_create(uuid, text, text, jsonb), public._cg01u_pay(uuid, uuid, text, text), public._cg01u_mk(uuid, text, numeric, text, text),
  public._cg01u_counts() to anon, authenticated, service_role;

-- ═════════ contracts ═════════
do $contracts$
declare
  v_rpc regprocedure := to_regprocedure('public.get_quick_solution_counter_cashup(date)');
  v_today regprocedure := to_regprocedure('public.get_quick_solution_counter_cashup_today()');
  v_impl regprocedure := to_regprocedure('commerce._qs_counter_cashup(uuid,date)');
  v_of regprocedure := to_regprocedure('commerce._qs_counter_business_day_of(date)');
  v_names text[];
  v_def text;
  v_i regprocedure;
begin
  if v_rpc is null or v_today is null or v_impl is null or v_of is null then raise exception 'the dated cash-up, today, the shared implementation and the date helper must all exist'; end if;
  select p.proargnames into v_names from pg_catalog.pg_proc p where p.oid = v_rpc;
  if v_names is distinct from array['p_business_date'] then raise exception 'the only argument is the business date (no tenant, timezone, timestamps or channel), got %', v_names; end if;
  if pg_catalog.pg_get_function_result(v_rpc) <> 'jsonb' then raise exception 'it returns jsonb'; end if;
  foreach v_i in array array[v_rpc, v_today, v_impl] loop
    if not (select p.prosecdef from pg_catalog.pg_proc p where p.oid = v_i) then raise exception '% must be SECURITY DEFINER', v_i; end if;
    if (select p.provolatile from pg_catalog.pg_proc p where p.oid = v_i) <> 's' then raise exception '% only reads: STABLE', v_i; end if;
    if not exists (select 1 from pg_catalog.pg_proc p, lateral pg_catalog.pg_options_to_table(p.proconfig) c where p.oid = v_i and c.option_name = 'search_path' and btrim(c.option_value, chr(34)) = '') then
      raise exception '% must use an empty hardened search_path', v_i;
    end if;
  end loop;
  foreach v_i in array array[v_rpc, v_today] loop
    if exists (select 1 from pg_catalog.pg_proc p, lateral pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) acl where p.oid = v_i and acl.grantee = 0 and acl.privilege_type = 'EXECUTE') then raise exception '% must not grant EXECUTE to PUBLIC', v_i; end if;
    if has_function_privilege('anon', v_i, 'EXECUTE') or has_function_privilege('service_role', v_i, 'EXECUTE') or not has_function_privilege('authenticated', v_i, 'EXECUTE') then raise exception '% is for authenticated only', v_i; end if;
    v_def := lower(pg_catalog.pg_get_functiondef(v_i));
    if v_def !~ 'has_tenant_capability\(v_tenant_id, ''cafe\.counter\.operate''\)' then raise exception '% must require cafe.counter.operate', v_i; end if;
    if v_def like '%cafe.operations.manage%' or v_def ~ '(is_app_admin|is_opps_staff|can_access_tenant)' then raise exception '% has no manage capability and no app-admin / OPPS-staff bypass', v_i; end if;
    if v_def !~ 't\.slug = ''quick-solution''' then raise exception '% resolves the canonical tenant', v_i; end if;
    if v_def !~ '_qs_counter_cashup\(v_tenant_id' then raise exception '% must call the ONE shared implementation', v_i; end if;
    if v_def ~ '(completed_at|provider|service_order_payments|idempotency_key|source_metadata|recorded_by|created_by)' then raise exception '% must not carry cash-up rules of its own', v_i; end if;
    if v_def ~ '(insert into|update commerce|update public|delete from)' then raise exception '% must write nothing', v_i; end if;
  end loop;
  foreach v_i in array array[v_impl, v_of] loop
    if has_function_privilege('anon', v_i, 'EXECUTE') or has_function_privilege('authenticated', v_i, 'EXECUTE') or has_function_privilege('service_role', v_i, 'EXECUTE') then raise exception '% is internal: no API role may execute it', v_i; end if;
  end loop;
  v_def := lower(pg_catalog.pg_get_functiondef(v_rpc));
  if v_def !~ 'p_business_date is null' or v_def !~ 'date ''infinity''' or v_def !~ 'date ''-infinity''' or v_def !~ 'date ''2000-01-01''' or v_def !~ 'p_business_date > v_today' then raise exception 'the date is validated strictly'; end if;
  if v_def !~ '_qs_counter_business_day\(now\(\)\)' then raise exception 'the future check uses the one business-day rule'; end if;
  v_def := lower(pg_catalog.pg_get_functiondef(v_impl));
  if v_def !~ '_qs_counter_business_day_of\(p_date\)' then raise exception 'the day comes from the one business-day rule'; end if;
  if v_def !~ 'p\.completed_at >= v_day\.day_start' or v_def !~ 'p\.completed_at < v_day\.day_end' or v_def !~ 'p\.status = ''completed''' or v_def !~ 'pay\.provider in \(''cash'', ''card''\)' or v_def !~ 'so\.channel = ''counter''' or v_def !~ 'p\.tenant_id = p_tenant_id' then
    raise exception 'takings: completed cash and card payments of counter orders, by completion time, half-open';
  end if;
  if v_def ~ '(idempotency_key|source_metadata|recorded_by|created_by|pricing_snapshot|pricing_definition|referenceprice|marginrate|suppliercost|auth\.jwt|infinity)' then raise exception 'no keys, actor, metadata or pricing may be read'; end if;
  if lower(pg_catalog.pg_get_functiondef(v_of)) !~ '_qs_counter_business_day\(' or lower(pg_catalog.pg_get_functiondef(v_of)) !~ 'africa/johannesburg' then raise exception 'the date helper reads its day back through the one rule'; end if;
end
$contracts$;

-- ═════════ the date helper: exact bounds at month, year and leap-day boundaries ═════════
do $bounds$
declare
  v_a record; v_b record; v_d date;
begin
  foreach v_d in array array[date '2026-01-31', date '2026-02-28', date '2028-02-28', date '2028-02-29', date '2025-12-31', date '2026-03-31']::date[] loop
    select * into v_a from commerce._qs_counter_business_day_of(v_d);
    select * into v_b from commerce._qs_counter_business_day_of(v_d + 1);
    if v_a.business_date <> v_d then raise exception 'CAFE_GUEST_01U: the business date of % must be itself, got %', v_d, v_a.business_date; end if;
    if v_a.day_end <> v_b.day_start or v_a.day_end - v_a.day_start <> interval '24 hours' then raise exception 'CAFE_GUEST_01U: % must end exactly where the next day starts and last 24 hours', v_d; end if;
    -- the read-back through the one rule agrees for the first and last instants
    if (select business_date from commerce._qs_counter_business_day(v_a.day_start)) <> v_d or (select business_date from commerce._qs_counter_business_day(v_a.day_end - interval '1 microsecond')) <> v_d
       or (select business_date from commerce._qs_counter_business_day(v_a.day_end)) <> v_d + 1 or (select business_date from commerce._qs_counter_business_day(v_a.day_start - interval '1 microsecond')) <> v_d - 1 then
      raise exception 'CAFE_GUEST_01U: the bounds of % agree with the single business-day rule', v_d;
    end if;
  end loop;
  -- local midnight is 22:00 UTC the evening before
  select * into v_a from commerce._qs_counter_business_day_of(date '2026-03-01');
  if v_a.day_start <> timestamptz '2026-02-28 22:00:00+00' then raise exception 'CAFE_GUEST_01U: 1 March starts at 22:00 UTC on 28 February, got %', v_a.day_start; end if;
  select * into v_a from commerce._qs_counter_business_day_of(date '2027-01-01');
  if v_a.day_start <> timestamptz '2026-12-31 22:00:00+00' then raise exception 'CAFE_GUEST_01U: the year boundary'; end if;
  select * into v_a from commerce._qs_counter_business_day_of(date '2028-02-29');
  if v_a.day_end <> timestamptz '2028-02-29 22:00:00+00' then raise exception 'CAFE_GUEST_01U: the leap day ends at 22:00 UTC on 29 February 2028'; end if;
  -- today's day is today's day
  select * into v_a from commerce._qs_counter_business_day_of((select business_date from commerce._qs_counter_business_day(now())));
  select * into v_b from commerce._qs_counter_business_day(now());
  if v_a is distinct from v_b then raise exception 'CAFE_GUEST_01U: the day of today''s date is the day of now'; end if;
end
$bounds$;

-- ═════════ fixtures ═════════
create table public._cg01u_ctx (k text primary key, v text);

do $fixtures$
declare
  v_suffix text := replace(gen_random_uuid()::text, '-', '');
  v_cafe uuid;
  v_other uuid := gen_random_uuid();
  u record;
begin
  select t.id into v_cafe from public.tenants t where t.slug = 'quick-solution' and t.status = 'active';
  if v_cafe is null then raise exception 'CAFE_GUEST_01U_TEST_SETUP: the quick-solution tenant must exist'; end if;
  insert into public._cg01u_ctx values ('suffix', v_suffix), ('cafe', v_cafe::text), ('other', v_other::text);
  insert into public.tenants(id, slug, name, status, settings) values (v_other, 'cg01u-other-' || left(v_suffix, 10), 'CG01U other cafe', 'active', '{}'::jsonb);
  insert into public.tenant_capabilities(tenant_id, capability_key, enabled) values (v_other, 'quick_solution', true);

  for u in select * from (values ('nomember'), ('member'), ('member2'), ('admin'), ('owner'), ('suspended'), ('otherowner'), ('appadmin'), ('oppsstaff')) as x(label) loop
    insert into public._cg01u_ctx values ('u_' || u.label, gen_random_uuid()::text);
    insert into auth.users(id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values ((select v::uuid from public._cg01u_ctx where k = 'u_' || u.label), 'authenticated', 'authenticated', 'cg01u-' || u.label || '-' || v_suffix || '@disposable.test', now(), '{}'::jsonb, '{}'::jsonb, now(), now());
  end loop;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', (select v from public._cg01u_ctx where k = 'u_appadmin'), 'role', 'authenticated', 'email', 'jointx.co@gmail.com')::text, true);
  insert into public.users(auth_user_id, user_email, full_name, role, is_active)
  values ((select v::uuid from public._cg01u_ctx where k = 'u_appadmin'), 'cg01u-appadmin-' || v_suffix || '@disposable.test', 'CG01U app admin', 'admin', true),
         ((select v::uuid from public._cg01u_ctx where k = 'u_oppsstaff'), 'cg01u-oppsstaff-' || v_suffix || '@disposable.test', 'CG01U OPPS staff', 'user', true);
  perform set_config('request.jwt.claims', '{}', true);
  if lower(coalesce(auth.jwt() ->> 'email', '')) <> '' then raise exception 'CAFE_GUEST_01U_TEST_SETUP: the temporary approved-owner claim must be cleared'; end if;

  insert into public.tenant_memberships(tenant_id, auth_user_id, tenant_role, status)
  select v_cafe, (select v::uuid from public._cg01u_ctx where k = 'u_' || m.label), m.role, m.status
  from (values ('member', 'member', 'active'), ('member2', 'member', 'active'), ('admin', 'admin', 'active'), ('owner', 'owner', 'active'), ('suspended', 'member', 'suspended')) as m(label, role, status);
  insert into public.tenant_memberships(tenant_id, auth_user_id, tenant_role, status)
  values (v_other, (select v::uuid from public._cg01u_ctx where k = 'u_otherowner'), 'owner', 'active');
  if exists (select 1 from public.tenant_memberships m where m.tenant_id = v_cafe and m.auth_user_id in
     ((select v::uuid from public._cg01u_ctx where k = 'u_appadmin'), (select v::uuid from public._cg01u_ctx where k = 'u_oppsstaff'))) then
    raise exception 'CAFE_GUEST_01U_TEST_SETUP: the app-admin and OPPS-staff fixtures must have no Cafe membership';
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
  v_cafe uuid := (select v::uuid from public._cg01u_ctx where k = 'cafe');
  u_nomember uuid := (select v::uuid from public._cg01u_ctx where k = 'u_nomember');
  u_member uuid := (select v::uuid from public._cg01u_ctx where k = 'u_member');
  u_admin uuid := (select v::uuid from public._cg01u_ctx where k = 'u_admin');
  u_owner uuid := (select v::uuid from public._cg01u_ctx where k = 'u_owner');
  u_suspended uuid := (select v::uuid from public._cg01u_ctx where k = 'u_suspended');
  u_otherowner uuid := (select v::uuid from public._cg01u_ctx where k = 'u_otherowner');
  u_appadmin uuid := (select v::uuid from public._cg01u_ctx where k = 'u_appadmin');
  u_oppsstaff uuid := (select v::uuid from public._cg01u_ctx where k = 'u_oppsstaff');
  v_day date := (select business_date from commerce._qs_counter_business_day(now())) - 2;
  v_labels text[]; v_subs uuid[]; v_emails text[]; v_expect text[];
  i integer; v_got text; v_state text; v_before text := public._cg01u_counts();
  v_module public.tenant_capabilities;
begin
  v_labels := array['anonymous', 'authenticated non-member', 'active member', 'active admin', 'active owner', 'suspended member',
                    'owner of a FOREIGN tenant', 'app admin with no Cafe membership', 'app admin with the approved-owner email', 'OPPS staff with no Cafe membership']::text[];
  v_subs := array[null, u_nomember, u_member, u_admin, u_owner, u_suspended, u_otherowner, u_appadmin, u_appadmin, u_oppsstaff]::uuid[];
  v_emails := array[null, null, null, null, null, null, null, null, 'jointx.co@gmail.com', null]::text[];
  v_expect := array[c_signin, c_denied, 'ok', 'ok', 'ok', c_denied, c_denied, c_denied, c_denied, c_denied]::text[];
  for i in 1 .. array_length(v_labels, 1) loop
    v_got := public._cg01u_try('authenticated', v_subs[i], v_emails[i], v_day);
    if v_got is distinct from v_expect[i] then raise exception 'CAFE_GUEST_01U: access for "%" expected "%" but got "%"', v_labels[i], v_expect[i], v_got; end if;
  end loop;
  -- authorization comes before the date is looked at: a denied caller learns nothing about dates
  if public._cg01u_try('authenticated', u_nomember, null, null) is distinct from c_denied or public._cg01u_try('authenticated', null, null, date '1999-01-01') is distinct from c_signin then raise exception 'CAFE_GUEST_01U: authorization is checked before the date'; end if;
  foreach v_state in array array['anon', 'service_role'] loop
    if public._cg01u_try(v_state, u_owner, null, v_day) not like '42501 permission denied for function get_quick_solution_counter_cashup%' then raise exception 'CAFE_GUEST_01U: % must be refused at the ACL', v_state; end if;
  end loop;
  select * into v_module from public.tenant_capabilities tc where tc.tenant_id = v_cafe and tc.capability_key = 'quick_solution';
  update public.tenant_capabilities set enabled = false where id = v_module.id;
  if public._cg01u_try('authenticated', u_member, null, v_day) is distinct from c_no_module or public._cg01u_try('authenticated', u_owner, null, v_day) is distinct from c_no_module then raise exception 'CAFE_GUEST_01U: a disabled module denies'; end if;
  if public._cg01u_try('authenticated', u_nomember, null, v_day) is distinct from c_denied then raise exception 'CAFE_GUEST_01U: authorization comes before the module check'; end if;
  update public.tenant_capabilities set enabled = true where id = v_module.id;
  foreach v_state in array array['suspended', 'archived'] loop
    update public.tenants set status = v_state where id = v_cafe;
    if public._cg01u_try('authenticated', u_member, null, v_day) is distinct from c_no_tenant then raise exception 'CAFE_GUEST_01U: a % tenant fails closed', v_state; end if;
  end loop;
  update public.tenants set status = 'active' where id = v_cafe;
  update public.tenant_memberships set status = 'suspended' where tenant_id = v_cafe and auth_user_id = u_admin;
  if public._cg01u_try('authenticated', u_admin, null, v_day) is distinct from c_denied then raise exception 'CAFE_GUEST_01U: a just-suspended admin is denied'; end if;
  update public.tenant_memberships set status = 'active' where tenant_id = v_cafe and auth_user_id = u_admin;
  if public._cg01u_counts() is distinct from v_before then raise exception 'CAFE_GUEST_01U: reading, allowed or denied, writes nothing'; end if;
end
$access$;

-- ═════════ date validation: strict, stable messages ═════════
do $dates$
declare
  u_member uuid := (select v::uuid from public._cg01u_ctx where k = 'u_member');
  v_today date := (select business_date from commerce._qs_counter_business_day(now()));
  v_got text; v_r jsonb; v_d date;
begin
  if public._cg01u_try('authenticated', u_member, null, null) is distinct from '22023 Business date is required.' then raise exception 'CAFE_GUEST_01U: a null date is required'; end if;
  foreach v_d in array array[date '-infinity', date 'infinity']::date[] loop
    if public._cg01u_try('authenticated', u_member, null, v_d) is distinct from '22023 Business date is not valid.' then raise exception 'CAFE_GUEST_01U: % is not a valid business date', v_d; end if;
  end loop;
  foreach v_d in array array[date '1999-12-31', date '1900-01-01', date '0100-01-01']::date[] loop
    if public._cg01u_try('authenticated', u_member, null, v_d) is distinct from '22023 Business date is not valid.' then raise exception 'CAFE_GUEST_01U: % is before the supported range', v_d; end if;
  end loop;
  -- the first supported day is fine
  if public._cg01u_try('authenticated', u_member, null, date '2000-01-01') is distinct from 'ok' then raise exception 'CAFE_GUEST_01U: 2000-01-01 is supported'; end if;
  -- a future date is refused, not shown as an empty day
  foreach v_d in array array[v_today + 1, v_today + 30, v_today + 4000]::date[] loop
    if public._cg01u_try('authenticated', u_member, null, v_d) is distinct from '22023 Cash-up date cannot be in the future.' then raise exception 'CAFE_GUEST_01U: % is in the future', v_d; end if;
  end loop;
  -- today and every earlier day are allowed
  foreach v_d in array array[v_today, v_today - 1, v_today - 45, v_today - 400]::date[] loop
    if public._cg01u_try('authenticated', u_member, null, v_d) is distinct from 'ok' then raise exception 'CAFE_GUEST_01U: % is allowed', v_d; end if;
    v_r := public._cg01u_cashup(u_member, v_d);
    if (v_r ->> 'businessDate')::date <> v_d or v_r ->> 'timezone' <> 'Africa/Johannesburg' then raise exception 'CAFE_GUEST_01U: the response names the selected business date, got %', v_r ->> 'businessDate'; end if;
  end loop;
  -- a date with nothing on it is a quiet day of zeros, not an error
  v_r := public._cg01u_cashup(u_member, v_today - 400);
  if v_r -> 'takings' -> 'total' <> '{"count": 0, "amount": 0}'::jsonb or v_r -> 'payments' <> '[]'::jsonb or v_r -> 'unpaid' <> '{"count": 0, "amount": 0, "orders": []}'::jsonb then raise exception 'CAFE_GUEST_01U: a day with no sales is zeros'; end if;
end
$dates$;

-- ═════════ a chosen day: what belongs to it, the reconciliation, the historical unpaid meaning, and equivalence with today ═════════
do $days$
declare
  v_suffix text := (select v from public._cg01u_ctx where k = 'suffix');
  v_cafe uuid := (select v::uuid from public._cg01u_ctx where k = 'cafe');
  v_other uuid := (select v::uuid from public._cg01u_ctx where k = 'other');
  u_member uuid := (select v::uuid from public._cg01u_ctx where k = 'u_member');
  u_member2 uuid := (select v::uuid from public._cg01u_ctx where k = 'u_member2');
  u_admin uuid := (select v::uuid from public._cg01u_ctx where k = 'u_admin');
  u_owner uuid := (select v::uuid from public._cg01u_ctx where k = 'u_owner');
  v_today date := (select business_date from commerce._qs_counter_business_day(now()));
  v_sel date := (select business_date from commerce._qs_counter_business_day(now())) - 3;   -- the selected day
  v_d record;   -- bounds of the selected day
  v_marker constant text := 'CG01U-SECRET';
  v_a uuid; v_b uuid; v_c uuid; v_e uuid; v_f uuid; v_g uuid;
  v_m1 uuid; v_m2 uuid; v_m3 uuid; v_m4 uuid;
  v_u1 uuid; v_u2 uuid; v_u3 uuid; v_st uuid; v_fo uuid; v_pf uuid; v_pend uuid; v_can uuid;
  v_r jsonb; v_t jsonb; v_row jsonb; v_text text; v_before text; n integer; v_sum numeric;
  v_cash numeric; v_card numeric; v_x uuid;
begin
  select * into v_d from commerce._qs_counter_business_day_of(v_sel);

  -- ── orders and payments, made through the real RPCs and moved onto the selected day ──
  v_a := public._cg01u_create(u_member, 'cg01u-' || v_suffix || '-a', 'scan', '{"units":4}');                  -- created ON the day, paid on the day (cash)
  v_b := public._cg01u_create(u_member2, 'cg01u-' || v_suffix || '-b', 'a4-lamination', '{"units":3}');       -- created 2 days EARLIER, paid on the selected day (card)
  v_c := public._cg01u_create(u_member, 'cg01u-' || v_suffix || '-c', 'a3-lamination', '{"units":2}');        -- created ON the day, paid the day AFTER
  v_e := public._cg01u_create(u_member, 'cg01u-' || v_suffix || '-e', 'scan', '{"units":2}');                  -- created on the day, still unpaid now
  v_f := public._cg01u_create(u_member, 'cg01u-' || v_suffix || '-f', 'a4-lamination', '{"units":1}');        -- created the day AFTER, unpaid
  v_g := public._cg01u_create(u_member, 'cg01u-' || v_suffix || '-g', 'scan', '{"units":1}');                  -- created the day BEFORE, unpaid
  update commerce.service_orders set created_at = v_d.day_start + interval '10 hours' where id in (v_a, v_c, v_e);
  update commerce.service_orders set created_at = v_d.day_start - interval '2 days' + interval '9 hours' where id = v_b;
  update commerce.service_orders set created_at = v_d.day_end + interval '3 hours' where id = v_f;
  update commerce.service_orders set created_at = v_d.day_start - interval '4 hours' where id = v_g;
  perform public._cg01u_pay(u_member2, v_a, 'cash', 'cg01u-' || v_suffix || '-pa');
  perform public._cg01u_pay(u_admin, v_b, 'card', 'cg01u-' || v_suffix || '-pb');
  perform public._cg01u_pay(u_owner, v_c, 'cash', 'cg01u-' || v_suffix || '-pc');
  update commerce.service_order_payments set completed_at = v_d.day_start + interval '11 hours' where service_order_id = v_a;
  update commerce.service_order_payments set completed_at = v_d.day_start + interval '13 hours' where service_order_id = v_b;
  update commerce.service_order_payments set completed_at = v_d.day_end + interval '5 hours' where service_order_id = v_c;    -- paid LATER: not this day's money
  -- the exact boundaries of the day, four real payments (each on its own real order)
  v_m1 := public._cg01u_create(u_member, 'cg01u-' || v_suffix || '-m1', 'scan', '{"units":1}');
  v_m2 := public._cg01u_create(u_member, 'cg01u-' || v_suffix || '-m2', 'scan', '{"units":1}');
  v_m3 := public._cg01u_create(u_member, 'cg01u-' || v_suffix || '-m3', 'scan', '{"units":1}');
  v_m4 := public._cg01u_create(u_member, 'cg01u-' || v_suffix || '-m4', 'scan', '{"units":1}');
  perform public._cg01u_pay(u_member, v_m1, 'card', 'cg01u-' || v_suffix || '-pm1');
  perform public._cg01u_pay(u_member, v_m2, 'card', 'cg01u-' || v_suffix || '-pm2');
  perform public._cg01u_pay(u_member, v_m3, 'cash', 'cg01u-' || v_suffix || '-pm3');
  perform public._cg01u_pay(u_member, v_m4, 'cash', 'cg01u-' || v_suffix || '-pm4');
  update commerce.service_order_payments set completed_at = v_d.day_start where service_order_id = v_m1;                                 -- exactly the day's start: IN
  update commerce.service_order_payments set completed_at = v_d.day_start - interval '1 microsecond' where service_order_id = v_m2;    -- one microsecond before: the day before, OUT
  update commerce.service_order_payments set completed_at = v_d.day_end - interval '1 microsecond' where service_order_id = v_m3;      -- the last microsecond: IN
  update commerce.service_order_payments set completed_at = v_d.day_end where service_order_id = v_m4;                                 -- exactly the next day's start: OUT
  update commerce.service_orders set created_at = v_d.day_start + interval '1 hour' where id in (v_m1, v_m2, v_m3, v_m4);
  -- unpaid orders created ON the day (present-day outstanding)
  v_u1 := public._cg01u_mk(v_cafe, 'counter', 40);
  v_u2 := public._cg01u_mk(v_cafe, 'counter', 30);
  v_u3 := public._cg01u_mk(v_cafe, 'counter', 20);
  v_can := public._cg01u_mk(v_cafe, 'counter', 99, 'cancelled', 'unpaid');
  update commerce.service_orders set created_at = v_d.day_start + interval '15 hours' where id in (v_u1, v_u2, v_u3, v_can);
  insert into commerce.service_order_payments(tenant_id, service_order_id, provider, status, amount, completed_at) values (v_cafe, v_u2, 'payfast', 'completed', 10, v_d.day_start + interval '16 hours');   -- part paid on the day by another provider
  -- excluded by scope, and things that are not money received
  v_st := public._cg01u_mk(v_cafe, 'storefront', 500, 'submitted', 'paid');
  insert into commerce.service_order_payments(tenant_id, service_order_id, provider, status, amount, completed_at, recorded_by, idempotency_key) values (v_cafe, v_st, 'cash', 'completed', 500, v_d.day_start + interval '12 hours', u_member, 'cg01u-st-' || v_suffix);
  v_fo := public._cg01u_mk(v_other, 'counter', 700, 'submitted', 'paid');
  insert into commerce.service_order_payments(tenant_id, service_order_id, provider, status, amount, completed_at, recorded_by, idempotency_key) values (v_other, v_fo, 'cash', 'completed', 700, v_d.day_start + interval '12 hours', u_member, 'cg01u-fo-' || v_suffix);
  v_pend := public._cg01u_mk(v_cafe, 'counter', 60);
  insert into commerce.service_order_payments(tenant_id, service_order_id, provider, status, amount, completed_at) values (v_cafe, v_pend, 'payfast', 'pending', 60, null);
  insert into commerce.service_order_payments(tenant_id, service_order_id, provider, status, amount) values (v_cafe, v_pend, 'payfast', 'failed', 60);
  v_pf := public._cg01u_mk(v_cafe, 'counter', 10, 'submitted', 'paid');
  insert into commerce.service_order_payments(tenant_id, service_order_id, provider, status, amount, completed_at) values (v_cafe, v_pf, 'payfast', 'completed', 10, v_d.day_start + interval '14 hours');
  update commerce.service_orders set created_at = v_d.day_start + interval '2 hours' where id in (v_pend, v_pf);
  update commerce.service_orders set source_metadata = source_metadata || jsonb_build_object('secret', v_marker) where id in (v_a, v_b, v_e);

  v_before := public._cg01u_counts();
  v_r := public._cg01u_cashup(u_member, v_sel);
  if public._cg01u_counts() is distinct from v_before then raise exception 'CAFE_GUEST_01U: the cash-up wrote something'; end if;
  if (v_r ->> 'businessDate')::date <> v_sel then raise exception 'CAFE_GUEST_01U: the response is for the selected date'; end if;

  -- ── payment-day semantics: the day the payment was completed, not the day the order was made ──
  select count(*) into n from jsonb_array_elements(v_r -> 'payments');
  if n <> 4 then raise exception 'CAFE_GUEST_01U: exactly 4 cash/card payments were completed on %, got % (%)', v_sel, n, v_r -> 'payments'; end if;
  foreach v_x in array array[v_a, v_b, v_m1, v_m3]::uuid[] loop
    if not exists (select 1 from jsonb_array_elements(v_r -> 'payments') p where p ->> 'orderId' = v_x::text) then raise exception 'CAFE_GUEST_01U: order % must be in the selected day''s takings', v_x; end if;
  end loop;
  foreach v_x in array array[v_c, v_m2, v_m4, v_e, v_f, v_g, v_u1, v_st, v_fo, v_pend, v_pf]::uuid[] loop
    if exists (select 1 from jsonb_array_elements(v_r -> 'payments') p where p ->> 'orderId' = v_x::text) then raise exception 'CAFE_GUEST_01U: order % must NOT be in the selected day''s takings', v_x; end if;
  end loop;
  -- an order made 2 days before and paid on the selected day is that day's money, and says when it was made
  select p into v_row from jsonb_array_elements(v_r -> 'payments') p where p ->> 'orderId' = v_b::text;
  if v_row ->> 'method' <> 'card' or (v_row ->> 'orderCreatedAt')::timestamptz >= v_d.day_start or (v_row ->> 'paidAt')::timestamptz < v_d.day_start or (v_row ->> 'paidAt')::timestamptz >= v_d.day_end then
    raise exception 'CAFE_GUEST_01U: the older order paid on the selected day shows created earlier, paid on the day: %', v_row;
  end if;
  -- the boundary orders: exactly the day's start and its last microsecond are in; one microsecond before and the next start are out
  if not exists (select 1 from jsonb_array_elements(v_r -> 'payments') p where p ->> 'orderId' = v_m1::text and (p ->> 'paidAt')::timestamptz = v_d.day_start)
     or not exists (select 1 from jsonb_array_elements(v_r -> 'payments') p where p ->> 'orderId' = v_m3::text and (p ->> 'paidAt')::timestamptz = v_d.day_end - interval '1 microsecond') then
    raise exception 'CAFE_GUEST_01U: the boundary payments are recognised at their exact instants';
  end if;

  -- ── the reconciliation: every total is exactly its rows ──
  select coalesce(sum((p ->> 'amount')::numeric) filter (where p ->> 'method' = 'cash'), 0), count(*) filter (where p ->> 'method' = 'cash') into v_sum, n from jsonb_array_elements(v_r -> 'payments') p;
  v_cash := (select amount from commerce.service_order_payments where service_order_id = v_a) + (select amount from commerce.service_order_payments where service_order_id = v_m3);
  if (v_r -> 'takings' -> 'cash' ->> 'amount')::numeric <> v_sum or (v_r -> 'takings' -> 'cash' ->> 'count')::integer <> n or v_sum <> v_cash or n <> 2 or v_cash <= 0 then raise exception 'CAFE_GUEST_01U: Cash is A + M3 and equals its rows, got %', v_r -> 'takings' -> 'cash'; end if;
  select coalesce(sum((p ->> 'amount')::numeric) filter (where p ->> 'method' = 'card'), 0), count(*) filter (where p ->> 'method' = 'card') into v_sum, n from jsonb_array_elements(v_r -> 'payments') p;
  v_card := (select amount from commerce.service_order_payments where service_order_id = v_b) + (select amount from commerce.service_order_payments where service_order_id = v_m1);
  if (v_r -> 'takings' -> 'card' ->> 'amount')::numeric <> v_sum or (v_r -> 'takings' -> 'card' ->> 'count')::integer <> n or v_sum <> v_card or n <> 2 or v_card <= 0 then raise exception 'CAFE_GUEST_01U: Card is B + M1 and equals its rows, got %', v_r -> 'takings' -> 'card'; end if;
  if (v_r -> 'takings' -> 'total' ->> 'amount')::numeric <> v_cash + v_card or (v_r -> 'takings' -> 'total' ->> 'count')::integer <> 4
     or (v_r -> 'takings' -> 'total' ->> 'amount')::numeric <> (select sum((p ->> 'amount')::numeric) from jsonb_array_elements(v_r -> 'payments') p) then
    raise exception 'CAFE_GUEST_01U: the combined total is Cash + Card and equals every returned row, got %', v_r -> 'takings' -> 'total';
  end if;
  -- other providers apart (the two completed PayFast rows made on the day), never in Cash, Card or the total
  if v_r -> 'otherMethods' <> '{"count": 2, "amount": 20}'::jsonb then raise exception 'CAFE_GUEST_01U: other methods are reported apart, got %', v_r -> 'otherMethods'; end if;
  -- pending / failed rows, unpaid orders, the storefront order and the foreign order are nothing to the takings (checked above by order)

  -- ── historical unpaid: orders CREATED on the selected day that are STILL unpaid NOW ──
  select count(*) into n from jsonb_array_elements(v_r -> 'unpaid' -> 'orders');
  if n <> 5 or (v_r -> 'unpaid' ->> 'count')::integer <> 5 or (v_r -> 'orders' ->> 'unpaidToday')::integer <> 5 then raise exception 'CAFE_GUEST_01U: 5 orders made on the day are still unpaid (E, U1, U2, U3, and the one with only a pending gateway row), got %', v_r -> 'unpaid'; end if;
  foreach v_x in array array[v_e, v_u1, v_u2, v_u3, v_pend]::uuid[] loop
    if not exists (select 1 from jsonb_array_elements(v_r -> 'unpaid' -> 'orders') o where o ->> 'orderId' = v_x::text) then raise exception 'CAFE_GUEST_01U: order % is unpaid now and was made on the day', v_x; end if;
  end loop;
  foreach v_x in array array[v_f, v_g, v_can, v_a, v_b, v_m1, v_pf, v_st, v_fo]::uuid[] loop
    if exists (select 1 from jsonb_array_elements(v_r -> 'unpaid' -> 'orders') o where o ->> 'orderId' = v_x::text) then raise exception 'CAFE_GUEST_01U: order % is not unpaid-and-made-on-the-day', v_x; end if;
  end loop;
  -- THE LIMITATION, pinned: C was made on the day and was still unpaid when the day ended, but it has been paid since (the day after). The system stores no
  -- historical payment state, so today's view of that day no longer lists it - this is "unpaid now", not "unpaid at the close of the day".
  if exists (select 1 from jsonb_array_elements(v_r -> 'unpaid' -> 'orders') o where o ->> 'orderId' = v_c::text) then raise exception 'CAFE_GUEST_01U: C is paid now, so it is not in the unpaid-now view (documented limitation)'; end if;
  -- amounts are what is outstanding NOW: the part-covered order shows only its remainder, the pending gateway row is not money
  v_sum := (commerce.qs_calculate_price(v_cafe, 'scan', '{"units":2}') ->> 'total')::numeric + 40 + (30 - 10) + 20 + 60;
  if (v_r -> 'unpaid' ->> 'amount')::numeric <> v_sum or (select (o ->> 'outstanding')::numeric from jsonb_array_elements(v_r -> 'unpaid' -> 'orders') o where o ->> 'orderId' = v_u2::text) <> 20 then
    raise exception 'CAFE_GUEST_01U: outstanding now is % (U2 shows 20 after its 10 payfast), got %', v_sum, v_r -> 'unpaid' ->> 'amount';
  end if;
  if (v_r -> 'takings' -> 'total' ->> 'amount')::numeric <> v_cash + v_card then raise exception 'CAFE_GUEST_01U: unpaid is never added to takings'; end if;
  -- orders created on the day: A C E M1-M4 U1 U2 U3 (and the cancelled one) pend pf = 13; paid on the day: A B M1 M3
  if (v_r -> 'orders' ->> 'createdToday')::integer <> 13 or (v_r -> 'orders' ->> 'paidToday')::integer <> 4 then raise exception 'CAFE_GUEST_01U: order counts wrong: %', v_r -> 'orders'; end if;
  -- the shifted order C now belongs to the NEXT day's takings
  if not exists (select 1 from jsonb_array_elements(public._cg01u_cashup(u_member, v_sel + 1) -> 'payments') p where p ->> 'orderId' = v_c::text and p ->> 'method' = 'cash') then raise exception 'CAFE_GUEST_01U: C''s payment is the day after''s money'; end if;
  if exists (select 1 from jsonb_array_elements(public._cg01u_cashup(u_member, v_sel - 1) -> 'payments') p where p ->> 'orderId' in (v_a::text, v_b::text, v_m1::text, v_m3::text, v_c::text)) then raise exception 'CAFE_GUEST_01U: nothing of the selected day leaks into the day before'; end if;
  if not exists (select 1 from jsonb_array_elements(public._cg01u_cashup(u_member, v_sel - 1) -> 'payments') p where p ->> 'orderId' = v_m2::text) then raise exception 'CAFE_GUEST_01U: M2 (one microsecond before) belongs to the day before'; end if;
  if not exists (select 1 from jsonb_array_elements(public._cg01u_cashup(u_member, v_sel + 1) -> 'payments') p where p ->> 'orderId' = v_m4::text) then raise exception 'CAFE_GUEST_01U: M4 (exactly the next start) belongs to the next day'; end if;
  -- each payment row and unpaid row: the pinned safe keys
  select p into v_row from jsonb_array_elements(v_r -> 'payments') p limit 1;
  if (select array_agg(k order by k) from jsonb_object_keys(v_row) k) is distinct from array['amount', 'customerName', 'method', 'orderCreatedAt', 'orderId', 'orderNumber', 'orderTotal', 'paidAt', 'paymentId'] then raise exception 'CAFE_GUEST_01U: a payment row has the pinned keys'; end if;
  select o into v_row from jsonb_array_elements(v_r -> 'unpaid' -> 'orders') o limit 1;
  if (select array_agg(k order by k) from jsonb_object_keys(v_row) k) is distinct from array['createdAt', 'customerEmail', 'customerName', 'customerPhone', 'items', 'orderId', 'orderNumber', 'outstanding', 'paymentStatus', 'status', 'totalAmount'] then raise exception 'CAFE_GUEST_01U: an unpaid row has the pinned keys'; end if;
  -- privacy
  if (select array_agg(k order by k) from jsonb_object_keys(v_r) k) is distinct from array['businessDate', 'orders', 'otherMethods', 'payments', 'takings', 'timezone', 'unpaid'] then raise exception 'CAFE_GUEST_01U: the response has the pinned top-level keys (the 01S shape)'; end if;
  v_text := lower(v_r::text);
  if v_text like '%' || lower(v_marker) || '%' or v_text like '%cg01u-' || lower(v_suffix) || '%' or v_text like '%counter-payment%' or v_text like '%counter:%'
     or v_text like '%' || lower(u_member::text) || '%' or v_text like '%' || lower(u_member2::text) || '%' or v_text like '%' || lower(u_admin::text) || '%' or v_text like '%' || lower(u_owner::text) || '%'
     or v_text like '%' || lower(v_cafe::text) || '%' or v_text like '%' || lower(v_other::text) || '%'
     or v_text ~ '(idempotency|recorded_by|recordedby|created_by|createdby|source_metadata|sourcemetadata|pricing_snapshot|pricingsnapshot|pricing_definition|supplier|margin|tenant_id|tenantid)' then
    raise exception 'CAFE_GUEST_01U: no key, actor, source metadata, pricing or tenant id';
  end if;
  foreach v_x in array array[u_member2, u_admin, u_owner]::uuid[] loop
    if public._cg01u_cashup(v_x, v_sel) is distinct from v_r then raise exception 'CAFE_GUEST_01U: every counter user sees the same day'; end if;
  end loop;

  -- ── compatibility: today's cash-up is exactly the dated cash-up for today's business date ──
  v_x := public._cg01u_create(u_member, 'cg01u-' || v_suffix || '-t1', 'scan', '{"units":3}');
  perform public._cg01u_pay(u_admin, v_x, 'cash', 'cg01u-' || v_suffix || '-pt1');
  v_x := public._cg01u_create(u_member, 'cg01u-' || v_suffix || '-t2', 'a4-lamination', '{"units":2}');
  perform public._cg01u_pay(u_owner, v_x, 'card', 'cg01u-' || v_suffix || '-pt2');
  perform public._cg01u_create(u_member, 'cg01u-' || v_suffix || '-t3', 'scan', '{"units":5}');
  v_t := public._cg01u_today(u_member);
  if v_t is distinct from public._cg01u_cashup(u_member, v_today) then raise exception 'CAFE_GUEST_01U: today''s cash-up equals the dated cash-up for today, exactly'; end if;
  if (v_t -> 'takings' -> 'total' ->> 'count')::integer <> 2 or (v_t -> 'unpaid' ->> 'count')::integer <> 1 or (select array_agg(k order by k) from jsonb_object_keys(v_t) k) is distinct from array['businessDate', 'orders', 'otherMethods', 'payments', 'takings', 'timezone', 'unpaid'] then
    raise exception 'CAFE_GUEST_01U: today''s contract is unchanged: 2 payments taken, 1 unpaid, the 01S keys, got %', v_t;
  end if;
  -- the selected day did not move
  if public._cg01u_cashup(u_member, v_sel) is distinct from v_r then raise exception 'CAFE_GUEST_01U: creating today''s orders does not change an earlier day'; end if;
  -- reading changed nothing
  v_before := public._cg01u_counts();
  perform public._cg01u_cashup(u_member, v_sel);
  perform public._cg01u_today(u_member);
  if public._cg01u_counts() is distinct from v_before then raise exception 'CAFE_GUEST_01U: reading wrote rows'; end if;
end
$days$;

-- ═════════ month and year boundaries, through the RPC ═════════
do $calendar$
declare
  v_suffix text := (select v from public._cg01u_ctx where k = 'suffix');
  u_member uuid := (select v::uuid from public._cg01u_ctx where k = 'u_member');
  u_admin uuid := (select v::uuid from public._cg01u_ctx where k = 'u_admin');
  v_x1 uuid; v_x2 uuid; v_y1 uuid; v_y2 uuid;
begin
  -- 21:59:59.999999 UTC is 23:59:59.999999 local (still the 31st); 22:00:00 UTC is local midnight (the 1st)
  v_x1 := public._cg01u_create(u_member, 'cg01u-' || v_suffix || '-x1', 'scan', '{"units":1}');
  v_x2 := public._cg01u_create(u_member, 'cg01u-' || v_suffix || '-x2', 'scan', '{"units":1}');
  v_y1 := public._cg01u_create(u_member, 'cg01u-' || v_suffix || '-y1', 'scan', '{"units":1}');
  v_y2 := public._cg01u_create(u_member, 'cg01u-' || v_suffix || '-y2', 'scan', '{"units":1}');
  perform public._cg01u_pay(u_admin, v_x1, 'cash', 'cg01u-' || v_suffix || '-px1');
  perform public._cg01u_pay(u_admin, v_x2, 'cash', 'cg01u-' || v_suffix || '-px2');
  perform public._cg01u_pay(u_admin, v_y1, 'card', 'cg01u-' || v_suffix || '-py1');
  perform public._cg01u_pay(u_admin, v_y2, 'card', 'cg01u-' || v_suffix || '-py2');
  update commerce.service_order_payments set completed_at = timestamptz '2026-01-31 21:59:59.999999+00' where service_order_id = v_x1;
  update commerce.service_order_payments set completed_at = timestamptz '2026-01-31 22:00:00+00' where service_order_id = v_x2;
  update commerce.service_order_payments set completed_at = timestamptz '2025-12-31 21:59:59.999999+00' where service_order_id = v_y1;
  update commerce.service_order_payments set completed_at = timestamptz '2025-12-31 22:00:00+00' where service_order_id = v_y2;
  if (select array_agg(p ->> 'orderId') from jsonb_array_elements(public._cg01u_cashup(u_member, date '2026-01-31') -> 'payments') p) is distinct from array[v_x1::text] then raise exception 'CAFE_GUEST_01U: 31 January holds only the payment made in its last microsecond'; end if;
  if (select array_agg(p ->> 'orderId') from jsonb_array_elements(public._cg01u_cashup(u_member, date '2026-02-01') -> 'payments') p) is distinct from array[v_x2::text] then raise exception 'CAFE_GUEST_01U: 1 February holds the payment made at local midnight'; end if;
  if (select array_agg(p ->> 'orderId') from jsonb_array_elements(public._cg01u_cashup(u_member, date '2025-12-31') -> 'payments') p) is distinct from array[v_y1::text] then raise exception 'CAFE_GUEST_01U: 31 December (previous year) holds only its last-microsecond payment'; end if;
  if (select array_agg(p ->> 'orderId') from jsonb_array_elements(public._cg01u_cashup(u_member, date '2026-01-01') -> 'payments') p) is distinct from array[v_y2::text] then raise exception 'CAFE_GUEST_01U: 1 January holds the payment made at local midnight'; end if;
  if (public._cg01u_cashup(u_member, date '2026-01-31') -> 'takings' -> 'cash' ->> 'count')::integer <> 1 or (public._cg01u_cashup(u_member, date '2026-01-01') -> 'takings' -> 'card' ->> 'count')::integer <> 1 then raise exception 'CAFE_GUEST_01U: the counts follow'; end if;
  -- a date between the two has nothing
  if public._cg01u_cashup(u_member, date '2026-01-15') -> 'payments' <> '[]'::jsonb then raise exception 'CAFE_GUEST_01U: a day with no payments is empty'; end if;
end
$calendar$;

rollback;
select 'CAFE-GUEST-01U dated counter cash-up contracts passed' as result;
