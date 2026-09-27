-- CAFE-GUEST-01P: behavioral contract test for public.list_quick_solution_counter_orders_today().
--
-- Run only against the disposable local harness (supabase/tests/harness/), which replays the
-- migration history INCLUDING the OPPS-owned access layer (public.has_tenant_capability,
-- CAFE-ACCESS-01..03) and
--   20260926230000_cafe_guest_01p_counter_orders_today_rpc.sql
-- The harness skips this test, visibly, when the OPPS access layer is absent.
--
-- Orders are created two ways: through the REAL create RPC (01M) under real API roles, and by direct
-- inserts at exact instants around the Africa/Johannesburg midnight boundary. The business-day rule is
-- also tested at FIXED instants, so the result does not depend on when the test runs. Everything is
-- enclosed by BEGIN/ROLLBACK.

\set ON_ERROR_STOP on

begin;

-- ── test-only helpers (public, created in this transaction, rolled back with it) ──────────
create function public._cg01p_try(p_role text, p_sub uuid, p_email text) returns text
language plpgsql
as $$
declare
  v_state text;
  v_message text;
  v_result jsonb;
begin
  perform set_config('request.jwt.claims',
    case when p_sub is null then '{}'
         else jsonb_strip_nulls(jsonb_build_object('sub', p_sub, 'role', 'authenticated', 'email', p_email))::text end, true);
  execute format('set local role %I', p_role);
  v_result := public.list_quick_solution_counter_orders_today();
  execute 'reset role';
  return 'ok ' || jsonb_array_length(v_result -> 'orders');
exception when others then
  get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
  execute 'reset role';
  return v_state || ' ' || v_message;
end
$$;

create function public._cg01p_list(p_sub uuid) returns jsonb
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  v_result := public.list_quick_solution_counter_orders_today();
  execute 'reset role';
  return v_result;
end
$$;

create function public._cg01p_create(p_sub uuid, p_key text, p_product text, p_config jsonb, p_name text default null, p_mail text default null) returns jsonb
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  v_result := public.create_quick_solution_counter_order(p_key, p_product, p_config, p_name, p_mail, null);
  execute 'reset role';
  return v_result;
end
$$;

create function public._cg01p_counts() returns text
language sql
as $$
  select (select count(*) from commerce.service_orders) || '/' || (select count(*) from commerce.service_order_items)
$$;

grant execute on function public._cg01p_try(text, uuid, text), public._cg01p_list(uuid), public._cg01p_create(uuid, text, text, jsonb, text, text),
  public._cg01p_counts() to anon, authenticated, service_role;

-- ═════════ contracts ═════════
do $contracts$
declare
  v_rpc regprocedure := to_regprocedure('public.list_quick_solution_counter_orders_today()');
  v_day regprocedure := to_regprocedure('commerce._qs_counter_business_day(timestamptz)');
  v_definition text;
begin
  if v_rpc is null then raise exception 'list_quick_solution_counter_orders_today() must exist'; end if;
  if (select p.pronargs from pg_catalog.pg_proc p where p.oid = v_rpc) <> 0 then raise exception 'it must take no argument: no tenant, channel, creator or date'; end if;
  if pg_catalog.pg_get_function_result(v_rpc) <> 'jsonb' then raise exception 'it must return jsonb'; end if;
  if not (select p.prosecdef from pg_catalog.pg_proc p where p.oid = v_rpc) then raise exception 'it must be SECURITY DEFINER'; end if;
  if (select p.provolatile from pg_catalog.pg_proc p where p.oid = v_rpc) <> 's' then raise exception 'it only reads, so it must be STABLE'; end if;
  if not exists (
    select 1 from pg_catalog.pg_proc p, lateral pg_catalog.pg_options_to_table(p.proconfig) c
    where p.oid = v_rpc and c.option_name = 'search_path' and btrim(c.option_value, chr(34)) = ''
  ) then raise exception 'it must use an empty hardened search_path'; end if;
  if exists (
    select 1 from pg_catalog.pg_proc p, lateral pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) acl
    where p.oid = v_rpc and acl.grantee = 0 and acl.privilege_type = 'EXECUTE'
  ) then raise exception 'it must not grant EXECUTE to PUBLIC'; end if;
  if has_function_privilege('anon', v_rpc, 'EXECUTE') or has_function_privilege('service_role', v_rpc, 'EXECUTE') then
    raise exception 'anon and service_role must not execute it';
  end if;
  if not has_function_privilege('authenticated', v_rpc, 'EXECUTE') then raise exception 'authenticated must execute it'; end if;

  v_definition := lower(pg_catalog.pg_get_functiondef(v_rpc));
  if v_definition !~ 'has_tenant_capability\(v_tenant_id, ''cafe\.counter\.operate''\)' then raise exception 'it must require cafe.counter.operate'; end if;
  if v_definition like '%cafe.operations.manage%' or v_definition ~ '(is_app_admin|is_opps_staff|can_access_tenant)' then
    raise exception 'only the counter capability: no manage capability, no app-admin or OPPS-staff bypass';
  end if;
  if v_definition !~ 't\.slug = ''quick-solution''' then raise exception 'the canonical tenant is resolved server-side'; end if;
  if v_definition !~ 'so\.channel = ''counter''' or v_definition !~ 'so\.tenant_id = v_tenant_id' then raise exception 'it must scope to the Cafe tenant and the counter channel'; end if;
  if v_definition !~ '_qs_counter_business_day\(now\(\)\)' then raise exception 'today must come from the one business-day rule'; end if;
  if v_definition ~ '(idempotency_key|source_metadata|created_by|pricing_snapshot|pricing_definition|referenceprice|marginrate|suppliercost|auth\.jwt|raw_app_meta|auth\.users|public\.users)' then
    raise exception 'the body must not read the idempotency key, source metadata, creator identity or any pricing data';
  end if;
  if v_definition ~ '(insert into|update commerce|update public|delete from)' then
    raise exception 'it must write nothing';
  end if;

  if v_day is null then raise exception 'the business-day function must exist'; end if;
  if has_function_privilege('anon', v_day, 'EXECUTE') or has_function_privilege('authenticated', v_day, 'EXECUTE') or has_function_privilege('service_role', v_day, 'EXECUTE') then
    raise exception 'the internal business-day function must not be executable by any API role';
  end if;
  if lower(pg_catalog.pg_get_functiondef(v_day)) !~ 'africa/johannesburg' then raise exception 'the business day is Africa/Johannesburg'; end if;
end
$contracts$;

-- ═════════ the business-day rule at FIXED instants (independent of the clock) ═════════
do $day$
declare
  v_row record;
  c_tz constant text := 'Africa/Johannesburg';
begin
  -- one microsecond before local midnight: still the 26th
  select * into v_row from commerce._qs_counter_business_day('2026-09-26 21:59:59.999999+00');
  if v_row.business_date <> date '2026-09-26' or v_row.day_start <> timestamptz '2026-09-25 22:00:00+00' or v_row.day_end <> timestamptz '2026-09-26 22:00:00+00' then
    raise exception 'CAFE_GUEST_01P: 21:59:59.999999 UTC is 23:59:59.999999 in Johannesburg, still 2026-09-26; got % [% , %)', v_row.business_date, v_row.day_start, v_row.day_end;
  end if;
  -- exactly local midnight: the NEW day
  select * into v_row from commerce._qs_counter_business_day('2026-09-26 22:00:00+00');
  if v_row.business_date <> date '2026-09-27' or v_row.day_start <> timestamptz '2026-09-26 22:00:00+00' then
    raise exception 'CAFE_GUEST_01P: 22:00:00 UTC is local midnight and belongs to 2026-09-27; got % from %', v_row.business_date, v_row.day_start;
  end if;
  -- 23:30 UTC is 01:30 the NEXT local day: a UTC-day rule would put it on the 26th
  select * into v_row from commerce._qs_counter_business_day('2026-09-26 23:30:00+00');
  if v_row.business_date <> date '2026-09-27' then raise exception 'CAFE_GUEST_01P: 23:30 UTC must be the 27th locally, not the UTC date; got %', v_row.business_date; end if;
  -- 00:30 UTC is 02:30 the same local day: the 26th
  select * into v_row from commerce._qs_counter_business_day('2026-09-26 00:30:00+00');
  if v_row.business_date <> date '2026-09-26' then raise exception 'CAFE_GUEST_01P: 00:30 UTC is 02:30 local on the 26th; got %', v_row.business_date; end if;
  -- year end, and a day is always exactly 24 hours (no daylight saving)
  select * into v_row from commerce._qs_counter_business_day('2026-12-31 22:00:00+00');
  if v_row.business_date <> date '2027-01-01' then raise exception 'CAFE_GUEST_01P: the year boundary must follow local midnight; got %', v_row.business_date; end if;
  for v_row in select * from commerce._qs_counter_business_day('2026-03-29 10:00:00+00') union all select * from commerce._qs_counter_business_day('2026-10-25 10:00:00+00') union all select * from commerce._qs_counter_business_day('2026-06-15 10:00:00+00') loop
    if v_row.day_end - v_row.day_start <> interval '24 hours' then raise exception 'CAFE_GUEST_01P: a Johannesburg day has no daylight saving and must be 24 hours: %', v_row.day_end - v_row.day_start; end if;
  end loop;
end
$day$;

-- ═════════ fixtures ═════════
create table public._cg01p_ctx (k text primary key, v text);

do $fixtures$
declare
  v_suffix text := replace(gen_random_uuid()::text, '-', '');
  v_cafe uuid;
  v_other uuid := gen_random_uuid();
  u record;
begin
  select t.id into v_cafe from public.tenants t where t.slug = 'quick-solution' and t.status = 'active';
  if v_cafe is null then raise exception 'CAFE_GUEST_01P_TEST_SETUP: the quick-solution tenant must exist'; end if;
  insert into public._cg01p_ctx values ('suffix', v_suffix), ('cafe', v_cafe::text), ('other', v_other::text);

  insert into public.tenants(id, slug, name, status, settings) values (v_other, 'cg01p-other-' || left(v_suffix, 10), 'CG01P other cafe', 'active', '{}'::jsonb);
  insert into public.tenant_capabilities(tenant_id, capability_key, enabled) values (v_other, 'quick_solution', true);

  for u in select * from (values ('nomember'), ('member'), ('member2'), ('admin'), ('owner'), ('suspended'), ('otherowner'), ('appadmin'), ('oppsstaff')) as x(label) loop
    insert into public._cg01p_ctx values ('u_' || u.label, gen_random_uuid()::text);
    insert into auth.users(id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values ((select v::uuid from public._cg01p_ctx where k = 'u_' || u.label), 'authenticated', 'authenticated', 'cg01p-' || u.label || '-' || v_suffix || '@disposable.test', now(), '{}'::jsonb, '{}'::jsonb, now(), now());
  end loop;

  -- SETUP-ONLY approved-owner claim (see the 01M test); cleared at once.
  perform set_config('request.jwt.claims', jsonb_build_object('sub', (select v from public._cg01p_ctx where k = 'u_appadmin'), 'role', 'authenticated', 'email', 'jointx.co@gmail.com')::text, true);
  insert into public.users(auth_user_id, user_email, full_name, role, is_active)
  values ((select v::uuid from public._cg01p_ctx where k = 'u_appadmin'), 'cg01p-appadmin-' || v_suffix || '@disposable.test', 'CG01P app admin', 'admin', true),
         ((select v::uuid from public._cg01p_ctx where k = 'u_oppsstaff'), 'cg01p-oppsstaff-' || v_suffix || '@disposable.test', 'CG01P OPPS staff', 'user', true);
  perform set_config('request.jwt.claims', '{}', true);
  if lower(coalesce(auth.jwt() ->> 'email', '')) <> '' then raise exception 'CAFE_GUEST_01P_TEST_SETUP: the temporary approved-owner claim must be cleared'; end if;

  insert into public.tenant_memberships(tenant_id, auth_user_id, tenant_role, status)
  select v_cafe, (select v::uuid from public._cg01p_ctx where k = 'u_' || m.label), m.role, m.status
  from (values ('member', 'member', 'active'), ('member2', 'member', 'active'), ('admin', 'admin', 'active'), ('owner', 'owner', 'active'), ('suspended', 'member', 'suspended')) as m(label, role, status);
  insert into public.tenant_memberships(tenant_id, auth_user_id, tenant_role, status)
  values (v_other, (select v::uuid from public._cg01p_ctx where k = 'u_otherowner'), 'owner', 'active');
  if exists (select 1 from public.tenant_memberships m where m.tenant_id = v_cafe and m.auth_user_id in
     ((select v::uuid from public._cg01p_ctx where k = 'u_appadmin'), (select v::uuid from public._cg01p_ctx where k = 'u_oppsstaff'))) then
    raise exception 'CAFE_GUEST_01P_TEST_SETUP: the app-admin and OPPS-staff fixtures must have no Cafe membership';
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
  v_cafe uuid := (select v::uuid from public._cg01p_ctx where k = 'cafe');
  u_nomember uuid := (select v::uuid from public._cg01p_ctx where k = 'u_nomember');
  u_member uuid := (select v::uuid from public._cg01p_ctx where k = 'u_member');
  u_admin uuid := (select v::uuid from public._cg01p_ctx where k = 'u_admin');
  u_owner uuid := (select v::uuid from public._cg01p_ctx where k = 'u_owner');
  u_suspended uuid := (select v::uuid from public._cg01p_ctx where k = 'u_suspended');
  u_otherowner uuid := (select v::uuid from public._cg01p_ctx where k = 'u_otherowner');
  u_appadmin uuid := (select v::uuid from public._cg01p_ctx where k = 'u_appadmin');
  u_oppsstaff uuid := (select v::uuid from public._cg01p_ctx where k = 'u_oppsstaff');
  v_labels text[]; v_subs uuid[]; v_emails text[]; v_expect text[];
  i integer;
  v_got text;
  v_before text := public._cg01p_counts();
  v_module public.tenant_capabilities;
  v_state text;
begin
  v_labels := array['anonymous', 'authenticated non-member', 'active member', 'active admin', 'active owner', 'suspended member',
                    'owner of a FOREIGN tenant', 'app admin with no Cafe membership', 'app admin with the approved-owner email', 'OPPS staff with no Cafe membership']::text[];
  v_subs := array[null, u_nomember, u_member, u_admin, u_owner, u_suspended, u_otherowner, u_appadmin, u_appadmin, u_oppsstaff]::uuid[];
  v_emails := array[null, null, null, null, null, null, null, null, 'jointx.co@gmail.com', null]::text[];
  v_expect := array[c_signin, c_denied, 'ok', 'ok', 'ok', c_denied, c_denied, c_denied, c_denied, c_denied]::text[];
  for i in 1 .. array_length(v_labels, 1) loop
    v_got := public._cg01p_try('authenticated', v_subs[i], v_emails[i]);
    if v_expect[i] = 'ok' then
      if v_got not like 'ok %' then raise exception 'CAFE_GUEST_01P: access for "%" expected success but got "%"', v_labels[i], v_got; end if;
    elsif v_got is distinct from v_expect[i] then
      raise exception 'CAFE_GUEST_01P: access for "%" expected "%" but got "%"', v_labels[i], v_expect[i], v_got;
    end if;
  end loop;

  foreach v_state in array array['anon', 'service_role'] loop
    v_got := public._cg01p_try(v_state, u_owner, null);
    if v_got not like '42501 permission denied for function list_quick_solution_counter_orders_today%' then
      raise exception 'CAFE_GUEST_01P: the % role must be refused by the ACL, got "%"', v_state, v_got;
    end if;
  end loop;

  select * into v_module from public.tenant_capabilities tc where tc.tenant_id = v_cafe and tc.capability_key = 'quick_solution';
  update public.tenant_capabilities set enabled = false where id = v_module.id;
  if public._cg01p_try('authenticated', u_member, null) is distinct from c_no_module or public._cg01p_try('authenticated', u_owner, null) is distinct from c_no_module then
    raise exception 'CAFE_GUEST_01P: a disabled quick_solution module must deny with the stable module error';
  end if;
  if public._cg01p_try('authenticated', u_nomember, null) is distinct from c_denied then
    raise exception 'CAFE_GUEST_01P: authorization comes before the module check';
  end if;
  update public.tenant_capabilities set enabled = true where id = v_module.id;
  foreach v_state in array array['suspended', 'archived'] loop
    update public.tenants set status = v_state where id = v_cafe;
    if public._cg01p_try('authenticated', u_member, null) is distinct from c_no_tenant then
      raise exception 'CAFE_GUEST_01P: a % Cafe tenant must fail closed with the tenant-not-found error', v_state;
    end if;
  end loop;
  update public.tenants set status = 'active' where id = v_cafe;

  update public.tenant_memberships set status = 'suspended' where tenant_id = v_cafe and auth_user_id = u_admin;
  if public._cg01p_try('authenticated', u_admin, null) is distinct from c_denied then raise exception 'CAFE_GUEST_01P: a just-suspended admin must be denied'; end if;
  update public.tenant_memberships set status = 'active' where tenant_id = v_cafe and auth_user_id = u_admin;

  if public._cg01p_counts() is distinct from v_before then raise exception 'CAFE_GUEST_01P: listing (allowed or denied) must write nothing'; end if;
end
$access$;

-- ═════════ filtering, ordering, the day boundary, and data safety ═════════
do $filtering$
declare
  v_suffix text := (select v from public._cg01p_ctx where k = 'suffix');
  v_cafe uuid := (select v::uuid from public._cg01p_ctx where k = 'cafe');
  v_other uuid := (select v::uuid from public._cg01p_ctx where k = 'other');
  u_member uuid := (select v::uuid from public._cg01p_ctx where k = 'u_member');
  u_member2 uuid := (select v::uuid from public._cg01p_ctx where k = 'u_member2');
  u_admin uuid := (select v::uuid from public._cg01p_ctx where k = 'u_admin');
  u_owner uuid := (select v::uuid from public._cg01p_ctx where k = 'u_owner');
  u_otherowner uuid := (select v::uuid from public._cg01p_ctx where k = 'u_otherowner');
  v_day record;
  v_marker constant text := 'CG01P-SECRET';
  v_created jsonb;
  v_walkin jsonb;
  v_result jsonb;
  v_orders jsonb;
  v_text text;
  v_before text;
  v_expected_price numeric;
  v_ids uuid[];
  v_early_id uuid; v_late_id uuid;
  v_o jsonb;
  v_prev_created timestamptz; v_prev_id uuid; v_cur_created timestamptz; v_cur_id uuid;
  v_numbers text[];
  n integer;
  v_counts_after_setup text;
begin
  select * into v_day from commerce._qs_counter_business_day(now());
  v_before := public._cg01p_counts();

  -- orders through the REAL create RPC (01M), as three different staff members
  v_created := public._cg01p_create(u_member, 'cg01p-' || v_suffix || '-a', 'scan', '{"units":4}', 'Thandi Nkosi', 'Thandi@Example.com');
  v_walkin := public._cg01p_create(u_member2, 'cg01p-' || v_suffix || '-b', 'a4-lamination', '{"units":3}');
  perform public._cg01p_create(u_admin, 'cg01p-' || v_suffix || '-c', 'a3-lamination', '{"units":1}');
  update commerce.service_orders set source_metadata = source_metadata || jsonb_build_object('secret', v_marker)
  where id in ((v_created ->> 'orderId')::uuid, (v_walkin ->> 'orderId')::uuid);

  -- direct rows at exact instants around the business-day boundary (all counter, Cafe tenant)
  insert into commerce.service_orders(tenant_id, order_number, customer_name, idempotency_key, channel, created_by, source_metadata, created_at)
  values
    (v_cafe, 'CG01P-EARLY-' || left(v_suffix, 8), 'Day start', 'CG01P-IDEMKEY-early-' || v_suffix, 'counter', u_member, jsonb_build_object('secret', v_marker), v_day.day_start),
    (v_cafe, 'CG01P-LATE-' || left(v_suffix, 8), 'Day end', 'CG01P-IDEMKEY-late-' || v_suffix, 'counter', u_member, jsonb_build_object('secret', v_marker), v_day.day_end - interval '1 microsecond'),
    (v_cafe, 'CG01P-YDAY-' || left(v_suffix, 8), 'One microsecond before today', 'CG01P-IDEMKEY-yday-' || v_suffix, 'counter', u_member, '{}', v_day.day_start - interval '1 microsecond'),
    (v_cafe, 'CG01P-YDAY2-' || left(v_suffix, 8), 'Yesterday noon', 'CG01P-IDEMKEY-yday2-' || v_suffix, 'counter', u_member, '{}', v_day.day_start - interval '12 hours'),
    (v_cafe, 'CG01P-TOM-' || left(v_suffix, 8), 'Exactly tomorrow midnight', 'CG01P-IDEMKEY-tom-' || v_suffix, 'counter', u_member, '{}', v_day.day_end),
    (v_cafe, 'CG01P-FUT-' || left(v_suffix, 8), 'Future', 'CG01P-IDEMKEY-fut-' || v_suffix, 'counter', u_member, '{}', v_day.day_end + interval '2 days'),
    (v_cafe, 'CG01P-STORE-' || left(v_suffix, 8), 'Storefront today', 'CG01P-IDEMKEY-store-' || v_suffix, 'storefront', null, jsonb_build_object('secret', v_marker), v_day.day_start + interval '1 second'),
    (v_other, 'CG01P-OTHER-' || left(v_suffix, 8), 'Foreign tenant today', 'CG01P-IDEMKEY-other-' || v_suffix, 'counter', u_otherowner, '{}', v_day.day_start + interval '1 second');

  v_counts_after_setup := public._cg01p_counts();
  -- what a plain member (not the creator of most of these) sees
  v_result := public._cg01p_list(u_member);
  v_orders := v_result -> 'orders';
  select array_agg(o ->> 'orderNumber') into v_numbers from jsonb_array_elements(v_orders) o;

  -- exactly the three real orders plus the two boundary rows that are inside today
  if jsonb_array_length(v_orders) <> 5 then raise exception 'CAFE_GUEST_01P: expected exactly 5 orders today, got % (%)', jsonb_array_length(v_orders), v_numbers; end if;
  foreach v_text in array array['CG01P-EARLY-' || left(v_suffix, 8), 'CG01P-LATE-' || left(v_suffix, 8), v_created ->> 'orderNumber', v_walkin ->> 'orderNumber'] loop
    if not (v_text = any (v_numbers)) then raise exception 'CAFE_GUEST_01P: % must be listed, got %', v_text, v_numbers; end if;
  end loop;
  foreach v_text in array array['YDAY', 'YDAY2', 'TOM', 'FUT', 'STORE', 'OTHER'] loop
    if exists (select 1 from unnest(v_numbers) x where x like 'CG01P-' || v_text || '-%') then
      raise exception 'CAFE_GUEST_01P: % must not be listed (yesterday, tomorrow, future, storefront or another tenant): %', v_text, v_numbers;
    end if;
  end loop;
  if v_result ->> 'businessDate' <> v_day.business_date::text or v_result ->> 'timezone' <> 'Africa/Johannesburg' then
    raise exception 'CAFE_GUEST_01P: the response names the business date and zone, got % / %', v_result ->> 'businessDate', v_result ->> 'timezone';
  end if;
  if v_numbers[1] <> 'CG01P-LATE-' || left(v_suffix, 8) or v_numbers[array_length(v_numbers, 1)] <> 'CG01P-EARLY-' || left(v_suffix, 8) then
    raise exception 'CAFE_GUEST_01P: newest first: the last microsecond of the day is first and the first instant is last, got %', v_numbers;
  end if;
  -- ties (the three created in one transaction share now()) break deterministically by id, newest id first
  v_prev_created := null;
  for n in 0 .. jsonb_array_length(v_orders) - 1 loop
    v_o := v_orders -> n;
    v_cur_created := (v_o ->> 'createdAt')::timestamptz;
    v_cur_id := (v_o ->> 'orderId')::uuid;
    if v_prev_created is not null and (v_cur_created > v_prev_created or (v_cur_created = v_prev_created and v_cur_id > v_prev_id)) then
      raise exception 'CAFE_GUEST_01P: not ordered by created_at desc, id desc at position %', n;
    end if;
    v_prev_created := v_cur_created;
    v_prev_id := v_cur_id;
  end loop;

  -- every active member, admin and owner sees the same list (not just their own orders)
  foreach v_text in array array['member2', 'admin', 'owner'] loop
    if (public._cg01p_list((select v::uuid from public._cg01p_ctx where k = 'u_' || v_text)) -> 'orders') is distinct from v_orders then
      raise exception 'CAFE_GUEST_01P: % must see exactly the same orders as any other counter user', v_text;
    end if;
  end loop;

  -- an order created through the 01M RPC appears with what the server recorded
  select o into v_o from jsonb_array_elements(v_orders) o where o ->> 'orderId' = v_created ->> 'orderId';
  if v_o is null then raise exception 'CAFE_GUEST_01P: the order created through the create RPC must appear'; end if;
  v_expected_price := (commerce.qs_calculate_price(v_cafe, 'scan', '{"units":4}') ->> 'total')::numeric;
  if v_o ->> 'status' <> 'submitted' or v_o ->> 'paymentStatus' <> 'unpaid'
     or v_o ->> 'customerName' <> 'Thandi Nkosi' or v_o ->> 'customerEmail' <> 'thandi@example.com' or v_o -> 'customerPhone' <> 'null'::jsonb
     or (v_o ->> 'totalAmount')::numeric <> v_expected_price or v_expected_price <= 0
     or (v_o ->> 'orderNumber') <> v_created ->> 'orderNumber' then
    raise exception 'CAFE_GUEST_01P: the created order must list as submitted / unpaid with its customer and the server total, got %', v_o;
  end if;
  if jsonb_array_length(v_o -> 'items') <> 1
     or v_o -> 'items' -> 0 ->> 'productKey' <> 'scan' or v_o -> 'items' -> 0 ->> 'productName' is null
     or (v_o -> 'items' -> 0 ->> 'quantity')::numeric <> 1 or v_o -> 'items' -> 0 -> 'configuration' <> '{"units":4}'::jsonb
     or (v_o -> 'items' -> 0 ->> 'lineTotal')::numeric <> v_expected_price then
    raise exception 'CAFE_GUEST_01P: the item summary must carry the product, quantity, configuration and server line total, got %', v_o -> 'items';
  end if;
  select o into v_o from jsonb_array_elements(v_orders) o where o ->> 'orderId' = v_walkin ->> 'orderId';
  if v_o ->> 'customerName' <> 'Walk-in' or v_o -> 'customerEmail' <> 'null'::jsonb or v_o -> 'customerPhone' <> 'null'::jsonb then
    raise exception 'CAFE_GUEST_01P: an order with no customer lists as Walk-in with no email or phone, got %', v_o;
  end if;
  -- a boundary row without items lists with an empty item list
  select o into v_o from jsonb_array_elements(v_orders) o where o ->> 'orderNumber' = 'CG01P-EARLY-' || left(v_suffix, 8);
  if v_o -> 'items' <> '[]'::jsonb then raise exception 'CAFE_GUEST_01P: an order with no items lists an empty item list, got %', v_o -> 'items'; end if;
  -- replaying the same key does not create a second listing
  perform public._cg01p_create(u_member, 'cg01p-' || v_suffix || '-a', 'scan', '{"units":4}', 'Thandi Nkosi', 'Thandi@Example.com');
  if jsonb_array_length(public._cg01p_list(u_member) -> 'orders') <> 5 then raise exception 'CAFE_GUEST_01P: an idempotent replay must not add a listing'; end if;

  -- data safety: exact keys, and nothing private anywhere in the text
  for n in 0 .. jsonb_array_length(v_orders) - 1 loop
    v_o := v_orders -> n;
    if (select array_agg(k order by k) from jsonb_object_keys(v_o) k) is distinct from
       array['createdAt', 'customerEmail', 'customerName', 'customerPhone', 'items', 'orderId', 'orderNumber', 'paymentStatus', 'status', 'totalAmount'] then
      raise exception 'CAFE_GUEST_01P: an order has exactly the pinned keys, got %', (select array_agg(k order by k) from jsonb_object_keys(v_o) k);
    end if;
    if jsonb_array_length(v_o -> 'items') > 0 and (select array_agg(k order by k) from jsonb_object_keys(v_o -> 'items' -> 0) k) is distinct from
       array['configuration', 'lineTotal', 'productKey', 'productName', 'quantity'] then
      raise exception 'CAFE_GUEST_01P: an item has exactly the pinned keys, got %', (select array_agg(k order by k) from jsonb_object_keys(v_o -> 'items' -> 0) k);
    end if;
  end loop;
  if (select array_agg(k order by k) from jsonb_object_keys(v_result) k) is distinct from array['businessDate', 'orders', 'timezone'] then
    raise exception 'CAFE_GUEST_01P: the response has exactly businessDate, orders and timezone';
  end if;
  v_text := lower(v_result::text);
  if v_text like '%' || lower(v_marker) || '%' or v_text like '%idemkey%' or v_text like '%cg01p-' || lower(v_suffix) || '-a%' or v_text like '%counter:%' then
    raise exception 'CAFE_GUEST_01P: source metadata and idempotency keys must never be returned';
  end if;
  if v_text ~ '(pricing_snapshot|pricingsnapshot|pricing_definition|pricingdefinition|suppliercost|marginrate|referenceprice|source_metadata|sourcemetadata|created_by|createdby|tenant_id|tenantid|channel)' then
    raise exception 'CAFE_GUEST_01P: pricing, supplier, metadata, creator, tenant or channel internals must never be returned';
  end if;
  if v_text like '%' || lower(u_member::text) || '%' or v_text like '%' || lower(u_member2::text) || '%' or v_text like '%' || lower(u_admin::text) || '%' or v_text like '%' || lower(v_cafe::text) || '%' or v_text like '%' || lower(v_other::text) || '%' then
    raise exception 'CAFE_GUEST_01P: no creator identity or tenant id may appear';
  end if;
  if v_text like '%foreign tenant today%' or v_text like '%storefront today%' or v_text like '%cg01p-other%' then raise exception 'CAFE_GUEST_01P: no other-tenant or storefront data'; end if;

  -- the foreign tenant's own owner cannot use this to see the Cafe's orders
  if public._cg01p_try('authenticated', u_otherowner, null) is distinct from '42501 You do not have access to the Quick Solution counter.' then
    raise exception 'CAFE_GUEST_01P: a foreign tenant owner is denied';
  end if;

  -- reading changed nothing
  if public._cg01p_counts() is distinct from v_counts_after_setup then raise exception 'CAFE_GUEST_01P: listing changed the row counts'; end if;
  if (select count(*) from commerce.service_orders where tenant_id = v_cafe and channel = 'counter' and created_at >= v_day.day_start and created_at < v_day.day_end) <> 5 then
    raise exception 'CAFE_GUEST_01P: the test data changed under the read';
  end if;
end
$filtering$;

-- ═════════ a listing after no orders exist today for an empty day is an empty list, not an error ═════════
do $empty$
declare
  u_member uuid := (select v::uuid from public._cg01p_ctx where k = 'u_member');
  v_cafe uuid := (select v::uuid from public._cg01p_ctx where k = 'cafe');
  v_result jsonb;
begin
  -- push every counter order of the Cafe out of today, in this rolled-back transaction only
  update commerce.service_orders set created_at = created_at - interval '10 days' where tenant_id = v_cafe and channel = 'counter';
  v_result := public._cg01p_list(u_member);
  if v_result -> 'orders' is distinct from '[]'::jsonb then raise exception 'CAFE_GUEST_01P: an empty day lists as [] , got %', v_result -> 'orders'; end if;
end
$empty$;

rollback;
select 'CAFE-GUEST-01P counter orders today RPC contracts passed' as result;
