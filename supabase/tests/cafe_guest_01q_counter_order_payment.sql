-- CAFE-GUEST-01Q: behavioral contract test for
--   public.get_quick_solution_counter_order(uuid)                       (detail)
--   public.record_quick_solution_counter_payment(uuid, text, text)      (full Cash/Card payment)
--
-- Run only against the disposable local harness (supabase/tests/harness/), which replays the migration
-- history INCLUDING the OPPS-owned access layer (public.has_tenant_capability, CAFE-ACCESS-01..03) and
--   20260926240000_cafe_guest_01q_counter_order_detail_and_payment.sql
-- The harness skips this test, visibly, when the OPPS access layer is absent. Orders are created through the
-- REAL create RPC (01M) under real API roles; every expected amount is derived from the server pricing path.
-- Everything is enclosed by BEGIN/ROLLBACK. The genuinely concurrent case (two sessions at once) needs
-- committed data and lives in cafe_guest_01q_counter_payment_concurrency.sql.

\set ON_ERROR_STOP on

begin;

-- ── test-only helpers ────────────────────────────────────────────────────
create function public._cg01q_setup(p_role text, p_sub uuid, p_email text) returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claims',
    case when p_sub is null then '{}'
         else jsonb_strip_nulls(jsonb_build_object('sub', p_sub, 'role', 'authenticated', 'email', p_email))::text end, true);
  execute format('set local role %I', p_role);
end
$$;

create function public._cg01q_try_detail(p_role text, p_sub uuid, p_email text, p_order uuid) returns text
language plpgsql
as $$
declare
  v_state text;
  v_message text;
begin
  perform public._cg01q_setup(p_role, p_sub, p_email);
  perform public.get_quick_solution_counter_order(p_order);
  execute 'reset role';
  return 'ok';
exception when others then
  get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
  execute 'reset role';
  return v_state || ' ' || v_message;
end
$$;

create function public._cg01q_try_pay(p_role text, p_sub uuid, p_email text, p_order uuid, p_method text, p_key text) returns text
language plpgsql
as $$
declare
  v_state text;
  v_message text;
  v_result jsonb;
begin
  perform public._cg01q_setup(p_role, p_sub, p_email);
  v_result := public.record_quick_solution_counter_payment(p_order, p_method, p_key);
  execute 'reset role';
  return case when (v_result ->> 'ok')::boolean then 'ok' else 'refused ' || (v_result ->> 'reason') end;
exception when others then
  get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
  execute 'reset role';
  return v_state || ' ' || v_message;
end
$$;

create function public._cg01q_pay(p_sub uuid, p_order uuid, p_method text, p_key text) returns jsonb
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform public._cg01q_setup('authenticated', p_sub, null);
  v_result := public.record_quick_solution_counter_payment(p_order, p_method, p_key);
  execute 'reset role';
  return v_result;
end
$$;

create function public._cg01q_detail(p_sub uuid, p_order uuid) returns jsonb
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform public._cg01q_setup('authenticated', p_sub, null);
  v_result := public.get_quick_solution_counter_order(p_order);
  execute 'reset role';
  return v_result;
end
$$;

create function public._cg01q_list(p_sub uuid) returns jsonb
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform public._cg01q_setup('authenticated', p_sub, null);
  v_result := public.list_quick_solution_counter_orders_today();
  execute 'reset role';
  return v_result;
end
$$;

create function public._cg01q_create(p_sub uuid, p_key text, p_product text, p_config jsonb) returns uuid
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform public._cg01q_setup('authenticated', p_sub, null);
  v_result := public.create_quick_solution_counter_order(p_key, p_product, p_config);
  execute 'reset role';
  return (v_result ->> 'orderId')::uuid;
end
$$;

-- a direct order row for the cases the create RPC cannot produce (storefront, foreign tenant, odd states)
create function public._cg01q_mk(p_tenant uuid, p_channel text, p_total numeric, p_status text default 'submitted', p_pay text default 'unpaid') returns uuid
language plpgsql
as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into commerce.service_orders(id, tenant_id, order_number, customer_name, idempotency_key, channel, subtotal, total_amount, status, payment_status)
  values (v_id, p_tenant, 'CG01Q-' || left(v_id::text, 8), 'CG01Q direct', 'CG01Q-KEY-' || v_id::text, p_channel, p_total, p_total, p_status, p_pay);
  return v_id;
end
$$;

create function public._cg01q_counts() returns text
language sql
as $$
  select (select count(*) from commerce.service_orders) || '/' || (select count(*) from commerce.service_order_payments)
$$;

grant execute on function public._cg01q_setup(text, uuid, text), public._cg01q_try_detail(text, uuid, text, uuid), public._cg01q_try_pay(text, uuid, text, uuid, text, text),
  public._cg01q_pay(uuid, uuid, text, text), public._cg01q_detail(uuid, uuid), public._cg01q_list(uuid), public._cg01q_create(uuid, text, text, jsonb),
  public._cg01q_mk(uuid, text, numeric, text, text), public._cg01q_counts() to anon, authenticated, service_role;

-- ═════════ contracts ═════════
do $contracts$
declare
  v_detail regprocedure := to_regprocedure('public.get_quick_solution_counter_order(uuid)');
  v_pay regprocedure := to_regprocedure('public.record_quick_solution_counter_payment(uuid,text,text)');
  v_names text[];
  v_def text;
  v_i regprocedure;
begin
  if v_detail is null or v_pay is null then raise exception 'both 01Q RPCs must exist'; end if;
  select p.proargnames into v_names from pg_catalog.pg_proc p where p.oid = v_detail;
  if v_names is distinct from array['p_order_id'] then raise exception 'the detail RPC takes only the order id, got %', v_names; end if;
  select p.proargnames into v_names from pg_catalog.pg_proc p where p.oid = v_pay;
  if v_names is distinct from array['p_order_id', 'p_method', 'p_idempotency_key'] then raise exception 'the payment RPC takes only the order id, method and key (no amount), got %', v_names; end if;
  if (select p.provolatile from pg_catalog.pg_proc p where p.oid = v_detail) <> 's' then raise exception 'the detail RPC only reads: STABLE'; end if;
  if (select p.provolatile from pg_catalog.pg_proc p where p.oid = v_pay) <> 'v' then raise exception 'the payment RPC writes: VOLATILE'; end if;
  foreach v_i in array array[v_detail, v_pay] loop
    if not (select p.prosecdef from pg_catalog.pg_proc p where p.oid = v_i) then raise exception '% must be SECURITY DEFINER', v_i; end if;
    if not exists (select 1 from pg_catalog.pg_proc p, lateral pg_catalog.pg_options_to_table(p.proconfig) c where p.oid = v_i and c.option_name = 'search_path' and btrim(c.option_value, chr(34)) = '') then
      raise exception '% must use an empty hardened search_path', v_i;
    end if;
    if exists (select 1 from pg_catalog.pg_proc p, lateral pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) acl where p.oid = v_i and acl.grantee = 0 and acl.privilege_type = 'EXECUTE') then
      raise exception '% must not grant EXECUTE to PUBLIC', v_i;
    end if;
    if has_function_privilege('anon', v_i, 'EXECUTE') or has_function_privilege('service_role', v_i, 'EXECUTE') or not has_function_privilege('authenticated', v_i, 'EXECUTE') then
      raise exception '% must be executable by authenticated only', v_i;
    end if;
    v_def := lower(pg_catalog.pg_get_functiondef(v_i));
    if v_def !~ 'has_tenant_capability\(v_tenant_id, ''cafe\.counter\.operate''\)' then raise exception '% must require cafe.counter.operate', v_i; end if;
    if v_def like '%cafe.operations.manage%' or v_def ~ '(is_app_admin|is_opps_staff|can_access_tenant)' then raise exception '% must have no manage capability and no app-admin / OPPS-staff bypass', v_i; end if;
    if v_def !~ 't\.slug = ''quick-solution''' or v_def !~ 'so\.channel = ''counter''' or v_def !~ 'so\.tenant_id = v_tenant_id' then
      raise exception '% must resolve the canonical tenant and only counter orders of it', v_i;
    end if;
    if v_def ~ '(pricing_snapshot|pricing_definition|referenceprice|marginrate|suppliercost|source_metadata\s*->|raw_itn|pf_payment_id|cvv|card_number|cardnumber|pan\M)' and v_i = v_detail then
      raise exception 'the detail must not read pricing, gateway or card data';
    end if;
  end loop;
  v_def := lower(pg_catalog.pg_get_functiondef(v_detail));
  if v_def ~ '(idempotency_key|recorded_by|created_by|auth\.jwt)' then raise exception 'the detail must not return idempotency keys or actor identity'; end if;
  if v_def ~ '(insert into|update commerce|delete from)' then raise exception 'the detail must write nothing'; end if;

  v_def := lower(pg_catalog.pg_get_functiondef(v_pay));
  if position('insert into commerce.service_order_payments' in v_def) = 0 or position('set payment_status = ''paid''' in v_def) = 0
     or position('insert into commerce.service_order_payments' in v_def) > position('set payment_status = ''paid''' in v_def) then
    raise exception 'the ledger row must be written, and before the order is marked paid';
  end if;
  if v_def !~ 'p_method not in \(''cash'', ''card''\)' then raise exception 'exactly cash and card'; end if;
  if v_def ~ '(\meft\M|payfast_|lower\(p_method\)|upper\(p_method\)|p_amount|tender|change_due|cvv|card_number|expiry)' then raise exception 'no EFT, no mapping of methods, no amount or card data'; end if;
  if v_def !~ 'for update' or v_def !~ 'pg_advisory_xact_lock' then raise exception 'payment must lock the key and the order'; end if;
  if v_def !~ '''counter-payment:''\s*\|\|\s*v_actor::text' then raise exception 'the payment key must be actor-scoped'; end if;
  if v_def !~ 'recorded_by' or v_def !~ 'auth\.uid\(\)' then raise exception 'the actor is recorded server-side from auth.uid()'; end if;

  -- the ledger enforces the same rules the RPC applies
  if not exists (select 1 from pg_catalog.pg_indexes where schemaname = 'commerce' and indexname = 'uq_qs_service_order_payments_one_counter_payment') then raise exception 'one completed counter payment per order must be a unique index'; end if;
  if not exists (select 1 from pg_catalog.pg_indexes where schemaname = 'commerce' and indexname = 'uq_qs_service_order_payments_idempotency') then raise exception 'payment keys must be a unique index'; end if;
  if not exists (select 1 from pg_catalog.pg_constraint where conrelid = 'commerce.service_order_payments'::regclass and conname = 'service_order_payments_provider_check' and pg_get_constraintdef(oid) ~ 'payfast.*cash.*card' and pg_get_constraintdef(oid) !~* 'eft') then
    raise exception 'the provider vocabulary is payfast, cash and card only';
  end if;
  if has_table_privilege('authenticated', 'commerce.service_order_payments', 'select') or has_table_privilege('anon', 'commerce.service_order_payments', 'insert') then
    raise exception 'the ledger must not be readable or writable by API roles';
  end if;
  foreach v_i in array array[to_regprocedure('commerce._qs_order_amount_paid(uuid)'), to_regprocedure('commerce._qs_counter_payment_block(commerce.service_orders)')] loop
    if has_function_privilege('authenticated', v_i, 'EXECUTE') or has_function_privilege('anon', v_i, 'EXECUTE') or has_function_privilege('service_role', v_i, 'EXECUTE') then raise exception '% is internal', v_i; end if;
  end loop;
end
$contracts$;

-- ═════════ fixtures ═════════
create table public._cg01q_ctx (k text primary key, v text);

do $fixtures$
declare
  v_suffix text := replace(gen_random_uuid()::text, '-', '');
  v_cafe uuid;
  v_other uuid := gen_random_uuid();
  u record;
begin
  select t.id into v_cafe from public.tenants t where t.slug = 'quick-solution' and t.status = 'active';
  if v_cafe is null then raise exception 'CAFE_GUEST_01Q_TEST_SETUP: the quick-solution tenant must exist'; end if;
  insert into public._cg01q_ctx values ('suffix', v_suffix), ('cafe', v_cafe::text), ('other', v_other::text);
  insert into public.tenants(id, slug, name, status, settings) values (v_other, 'cg01q-other-' || left(v_suffix, 10), 'CG01Q other cafe', 'active', '{}'::jsonb);
  insert into public.tenant_capabilities(tenant_id, capability_key, enabled) values (v_other, 'quick_solution', true);

  for u in select * from (values ('nomember'), ('member'), ('member2'), ('admin'), ('owner'), ('suspended'), ('otherowner'), ('appadmin'), ('oppsstaff')) as x(label) loop
    insert into public._cg01q_ctx values ('u_' || u.label, gen_random_uuid()::text);
    insert into auth.users(id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values ((select v::uuid from public._cg01q_ctx where k = 'u_' || u.label), 'authenticated', 'authenticated', 'cg01q-' || u.label || '-' || v_suffix || '@disposable.test', now(), '{}'::jsonb, '{}'::jsonb, now(), now());
  end loop;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', (select v from public._cg01q_ctx where k = 'u_appadmin'), 'role', 'authenticated', 'email', 'jointx.co@gmail.com')::text, true);
  insert into public.users(auth_user_id, user_email, full_name, role, is_active)
  values ((select v::uuid from public._cg01q_ctx where k = 'u_appadmin'), 'cg01q-appadmin-' || v_suffix || '@disposable.test', 'CG01Q app admin', 'admin', true),
         ((select v::uuid from public._cg01q_ctx where k = 'u_oppsstaff'), 'cg01q-oppsstaff-' || v_suffix || '@disposable.test', 'CG01Q OPPS staff', 'user', true);
  perform set_config('request.jwt.claims', '{}', true);
  if lower(coalesce(auth.jwt() ->> 'email', '')) <> '' then raise exception 'CAFE_GUEST_01Q_TEST_SETUP: the temporary approved-owner claim must be cleared'; end if;

  insert into public.tenant_memberships(tenant_id, auth_user_id, tenant_role, status)
  select v_cafe, (select v::uuid from public._cg01q_ctx where k = 'u_' || m.label), m.role, m.status
  from (values ('member', 'member', 'active'), ('member2', 'member', 'active'), ('admin', 'admin', 'active'), ('owner', 'owner', 'active'), ('suspended', 'member', 'suspended')) as m(label, role, status);
  insert into public.tenant_memberships(tenant_id, auth_user_id, tenant_role, status)
  values (v_other, (select v::uuid from public._cg01q_ctx where k = 'u_otherowner'), 'owner', 'active');
  if exists (select 1 from public.tenant_memberships m where m.tenant_id = v_cafe and m.auth_user_id in
     ((select v::uuid from public._cg01q_ctx where k = 'u_appadmin'), (select v::uuid from public._cg01q_ctx where k = 'u_oppsstaff'))) then
    raise exception 'CAFE_GUEST_01Q_TEST_SETUP: the app-admin and OPPS-staff fixtures must have no Cafe membership';
  end if;
end
$fixtures$;

-- ═════════ detail: access, module/tenant state, scope ═════════
do $detail_access$
declare
  c_signin constant text := '42501 Staff sign-in is required.';
  c_denied constant text := '42501 You do not have access to the Quick Solution counter.';
  c_no_tenant constant text := '22023 Quick Solution tenant was not found.';
  c_no_module constant text := '22023 Quick Solution counter is not active.';
  c_not_found constant text := '22023 Counter order was not found.';
  v_suffix text := (select v from public._cg01q_ctx where k = 'suffix');
  v_cafe uuid := (select v::uuid from public._cg01q_ctx where k = 'cafe');
  v_other uuid := (select v::uuid from public._cg01q_ctx where k = 'other');
  u_nomember uuid := (select v::uuid from public._cg01q_ctx where k = 'u_nomember');
  u_member uuid := (select v::uuid from public._cg01q_ctx where k = 'u_member');
  u_admin uuid := (select v::uuid from public._cg01q_ctx where k = 'u_admin');
  u_owner uuid := (select v::uuid from public._cg01q_ctx where k = 'u_owner');
  u_suspended uuid := (select v::uuid from public._cg01q_ctx where k = 'u_suspended');
  u_otherowner uuid := (select v::uuid from public._cg01q_ctx where k = 'u_otherowner');
  u_appadmin uuid := (select v::uuid from public._cg01q_ctx where k = 'u_appadmin');
  u_oppsstaff uuid := (select v::uuid from public._cg01q_ctx where k = 'u_oppsstaff');
  v_order uuid; v_store uuid; v_foreign uuid;
  v_labels text[]; v_subs uuid[]; v_emails text[]; v_expect text[];
  i integer; v_got text; v_state text;
  v_module public.tenant_capabilities;
  v_before text;
begin
  v_order := public._cg01q_create(u_member, 'cg01q-' || v_suffix || '-d1', 'scan', '{"units":3}');
  v_store := public._cg01q_mk(v_cafe, 'storefront', 50);
  v_foreign := public._cg01q_mk(v_other, 'counter', 50);
  insert into public._cg01q_ctx values ('detail_order', v_order::text), ('storefront_order', v_store::text), ('foreign_order', v_foreign::text);
  v_before := public._cg01q_counts();

  v_labels := array['anonymous', 'authenticated non-member', 'active member', 'active admin', 'active owner', 'suspended member',
                    'owner of a FOREIGN tenant', 'app admin with no Cafe membership', 'app admin with the approved-owner email', 'OPPS staff with no Cafe membership']::text[];
  v_subs := array[null, u_nomember, u_member, u_admin, u_owner, u_suspended, u_otherowner, u_appadmin, u_appadmin, u_oppsstaff]::uuid[];
  v_emails := array[null, null, null, null, null, null, null, null, 'jointx.co@gmail.com', null]::text[];
  v_expect := array[c_signin, c_denied, 'ok', 'ok', 'ok', c_denied, c_denied, c_denied, c_denied, c_denied]::text[];
  for i in 1 .. array_length(v_labels, 1) loop
    v_got := public._cg01q_try_detail('authenticated', v_subs[i], v_emails[i], v_order);
    if v_got is distinct from v_expect[i] then raise exception 'CAFE_GUEST_01Q: detail access for "%" expected "%" but got "%"', v_labels[i], v_expect[i], v_got; end if;
  end loop;
  foreach v_state in array array['anon', 'service_role'] loop
    if public._cg01q_try_detail(v_state, u_owner, null, v_order) not like '42501 permission denied for function get_quick_solution_counter_order%' then raise exception 'CAFE_GUEST_01Q: % must be refused at the ACL', v_state; end if;
  end loop;

  -- scope: only counter orders of the Cafe; the three refusals are indistinguishable
  foreach v_state in array array[v_store::text, v_foreign::text, gen_random_uuid()::text] loop
    if public._cg01q_try_detail('authenticated', u_owner, null, v_state::uuid) is distinct from c_not_found then raise exception 'CAFE_GUEST_01Q: a storefront order, a foreign order and an unknown id are all "not found"'; end if;
  end loop;
  if public._cg01q_try_detail('authenticated', u_owner, null, null) is distinct from c_not_found then raise exception 'CAFE_GUEST_01Q: a null id is not found'; end if;
  if public._cg01q_try_detail('authenticated', u_otherowner, null, v_foreign) is distinct from c_denied then raise exception 'CAFE_GUEST_01Q: the foreign owner has no Cafe counter access even to their own tenant''s order here'; end if;

  select * into v_module from public.tenant_capabilities tc where tc.tenant_id = v_cafe and tc.capability_key = 'quick_solution';
  update public.tenant_capabilities set enabled = false where id = v_module.id;
  if public._cg01q_try_detail('authenticated', u_member, null, v_order) is distinct from c_no_module or public._cg01q_try_detail('authenticated', u_owner, null, v_order) is distinct from c_no_module then raise exception 'CAFE_GUEST_01Q: a disabled module denies the detail'; end if;
  if public._cg01q_try_detail('authenticated', u_nomember, null, v_order) is distinct from c_denied then raise exception 'CAFE_GUEST_01Q: authorization comes before the module check'; end if;
  update public.tenant_capabilities set enabled = true where id = v_module.id;
  update public.tenants set status = 'suspended' where id = v_cafe;
  if public._cg01q_try_detail('authenticated', u_member, null, v_order) is distinct from c_no_tenant then raise exception 'CAFE_GUEST_01Q: a suspended tenant fails closed'; end if;
  update public.tenants set status = 'active' where id = v_cafe;
  if public._cg01q_counts() is distinct from v_before then raise exception 'CAFE_GUEST_01Q: the detail must write nothing'; end if;
end
$detail_access$;

-- ═════════ detail: shape, privacy, and a fresh read of an unpaid order ═════════
do $detail_shape$
declare
  v_cafe uuid := (select v::uuid from public._cg01q_ctx where k = 'cafe');
  u_member uuid := (select v::uuid from public._cg01q_ctx where k = 'u_member');
  v_order uuid := (select v::uuid from public._cg01q_ctx where k = 'detail_order');
  v_suffix text := (select v from public._cg01q_ctx where k = 'suffix');
  v_d jsonb; v_text text; v_expected numeric;
begin
  update commerce.service_orders set source_metadata = source_metadata || '{"secret":"CG01Q-SECRET"}'::jsonb where id = v_order;
  v_expected := (commerce.qs_calculate_price(v_cafe, 'scan', '{"units":3}') ->> 'total')::numeric;
  v_d := public._cg01q_detail(u_member, v_order);
  if (select array_agg(k order by k) from jsonb_object_keys(v_d) k) is distinct from
     array['amountPaid', 'createdAt', 'customerEmail', 'customerName', 'customerPhone', 'fulfilmentFee', 'items', 'orderId', 'orderNumber', 'outstanding', 'paymentAllowed', 'paymentStatus', 'payments', 'status', 'subtotal', 'totalAmount'] then
    raise exception 'CAFE_GUEST_01Q: the detail has exactly the pinned keys, got %', (select array_agg(k order by k) from jsonb_object_keys(v_d) k);
  end if;
  if v_d ->> 'paymentStatus' <> 'unpaid' or v_d ->> 'status' <> 'submitted' or (v_d ->> 'totalAmount')::numeric <> v_expected or v_expected <= 0
     or (v_d ->> 'amountPaid')::numeric <> 0 or (v_d ->> 'outstanding')::numeric <> v_expected
     or (v_d -> 'paymentAllowed') <> 'true'::jsonb or v_d -> 'payments' <> '[]'::jsonb or v_d ->> 'customerName' <> 'Walk-in' then
    raise exception 'CAFE_GUEST_01Q: an unpaid order shows zero paid, the full server total outstanding, payment allowed, no payments; got %', v_d;
  end if;
  if jsonb_array_length(v_d -> 'items') <> 1 or (select array_agg(k order by k) from jsonb_object_keys(v_d -> 'items' -> 0) k) is distinct from array['configuration', 'lineTotal', 'productKey', 'productName', 'quantity']
     or v_d -> 'items' -> 0 -> 'configuration' <> '{"units":3}'::jsonb then
    raise exception 'CAFE_GUEST_01Q: one item with the pinned keys and its configuration, got %', v_d -> 'items';
  end if;
  v_text := lower(v_d::text);
  if v_text like '%cg01q-secret%' or v_text like '%counter:%' or v_text like '%' || lower(v_suffix) || '-d1%' or v_text like '%' || lower(u_member::text) || '%' or v_text like '%' || lower(v_cafe::text) || '%'
     or v_text ~ '(pricing_snapshot|pricingsnapshot|source_metadata|idempotency|recorded_by|created_by|tenant_id|channel)' then
    raise exception 'CAFE_GUEST_01Q: no source metadata, key, actor, tenant or pricing internals in the detail';
  end if;
end
$detail_shape$;

-- ═════════ payment: access (member / admin / owner allowed; everyone else refused, nothing written) ═════════
do $pay_access$
declare
  c_signin constant text := '42501 Staff sign-in is required.';
  c_denied constant text := '42501 You do not have access to the Quick Solution counter.';
  c_no_tenant constant text := '22023 Quick Solution tenant was not found.';
  c_no_module constant text := '22023 Quick Solution counter is not active.';
  v_suffix text := (select v from public._cg01q_ctx where k = 'suffix');
  v_cafe uuid := (select v::uuid from public._cg01q_ctx where k = 'cafe');
  u_nomember uuid := (select v::uuid from public._cg01q_ctx where k = 'u_nomember');
  u_member uuid := (select v::uuid from public._cg01q_ctx where k = 'u_member');
  u_admin uuid := (select v::uuid from public._cg01q_ctx where k = 'u_admin');
  u_owner uuid := (select v::uuid from public._cg01q_ctx where k = 'u_owner');
  u_suspended uuid := (select v::uuid from public._cg01q_ctx where k = 'u_suspended');
  u_otherowner uuid := (select v::uuid from public._cg01q_ctx where k = 'u_otherowner');
  u_appadmin uuid := (select v::uuid from public._cg01q_ctx where k = 'u_appadmin');
  u_oppsstaff uuid := (select v::uuid from public._cg01q_ctx where k = 'u_oppsstaff');
  v_labels text[]; v_subs uuid[]; v_emails text[]; v_expect text[];
  i integer; v_got text; v_state text; v_before text; v_o uuid;
  v_module public.tenant_capabilities;
  v_target uuid;
begin
  v_target := public._cg01q_create(u_member, 'cg01q-' || v_suffix || '-pa', 'scan', '{"units":2}');
  insert into public._cg01q_ctx values ('access_order', v_target::text);
  v_labels := array['anonymous', 'authenticated non-member', 'suspended member', 'owner of a FOREIGN tenant', 'app admin with no Cafe membership', 'app admin with the approved-owner email', 'OPPS staff with no Cafe membership']::text[];
  v_subs := array[null, u_nomember, u_suspended, u_otherowner, u_appadmin, u_appadmin, u_oppsstaff]::uuid[];
  v_emails := array[null, null, null, null, null, 'jointx.co@gmail.com', null]::text[];
  v_expect := array[c_signin, c_denied, c_denied, c_denied, c_denied, c_denied, c_denied]::text[];
  v_before := public._cg01q_counts();
  for i in 1 .. array_length(v_labels, 1) loop
    v_got := public._cg01q_try_pay('authenticated', v_subs[i], v_emails[i], v_target, 'cash', 'cg01q-' || v_suffix || '-deny-' || i);
    if v_got is distinct from v_expect[i] then raise exception 'CAFE_GUEST_01Q: payment access for "%" expected "%" but got "%"', v_labels[i], v_expect[i], v_got; end if;
  end loop;
  foreach v_state in array array['anon', 'service_role'] loop
    if public._cg01q_try_pay(v_state, u_owner, null, v_target, 'cash', 'cg01q-' || v_suffix || '-role') not like '42501 permission denied for function record_quick_solution_counter_payment%' then raise exception 'CAFE_GUEST_01Q: % must be refused at the ACL', v_state; end if;
  end loop;
  if public._cg01q_counts() is distinct from v_before or (select payment_status from commerce.service_orders where id = v_target) <> 'unpaid' then raise exception 'CAFE_GUEST_01Q: a refused payment writes nothing'; end if;

  -- module / tenant state / a just-suspended member
  select * into v_module from public.tenant_capabilities tc where tc.tenant_id = v_cafe and tc.capability_key = 'quick_solution';
  update public.tenant_capabilities set enabled = false where id = v_module.id;
  if public._cg01q_try_pay('authenticated', u_member, null, v_target, 'cash', 'cg01q-' || v_suffix || '-mod') is distinct from c_no_module then raise exception 'CAFE_GUEST_01Q: a disabled module denies payment'; end if;
  if public._cg01q_try_pay('authenticated', u_nomember, null, v_target, 'cash', 'cg01q-' || v_suffix || '-mod2') is distinct from c_denied then raise exception 'CAFE_GUEST_01Q: authorization comes before the module check'; end if;
  update public.tenant_capabilities set enabled = true where id = v_module.id;
  update public.tenants set status = 'suspended' where id = v_cafe;
  if public._cg01q_try_pay('authenticated', u_member, null, v_target, 'cash', 'cg01q-' || v_suffix || '-ten') is distinct from c_no_tenant then raise exception 'CAFE_GUEST_01Q: a suspended tenant fails closed'; end if;
  update public.tenants set status = 'active' where id = v_cafe;
  update public.tenant_memberships set status = 'suspended' where tenant_id = v_cafe and auth_user_id = u_admin;
  if public._cg01q_try_pay('authenticated', u_admin, null, v_target, 'cash', 'cg01q-' || v_suffix || '-susp') is distinct from c_denied then raise exception 'CAFE_GUEST_01Q: a just-suspended admin is denied'; end if;
  update public.tenant_memberships set status = 'active' where tenant_id = v_cafe and auth_user_id = u_admin;
  if public._cg01q_counts() is distinct from v_before then raise exception 'CAFE_GUEST_01Q: nothing was written by any refusal'; end if;

  -- allowed: an active member, admin and owner each record a payment on their own order (not manage-only)
  foreach v_state in array array['member', 'admin', 'owner'] loop
    v_o := public._cg01q_create((select v::uuid from public._cg01q_ctx where k = 'u_' || v_state), 'cg01q-' || v_suffix || '-ok-' || v_state, 'a4-lamination', '{"units":2}');
    v_got := public._cg01q_try_pay('authenticated', (select v::uuid from public._cg01q_ctx where k = 'u_' || v_state), null, v_o, 'cash', 'cg01q-' || v_suffix || '-okpay-' || v_state);
    if v_got <> 'ok' then raise exception 'CAFE_GUEST_01Q: an active % may record a payment, got %', v_state, v_got; end if;
    if (select recorded_by from commerce.service_order_payments where service_order_id = v_o) is distinct from (select v::uuid from public._cg01q_ctx where k = 'u_' || v_state) then raise exception 'CAFE_GUEST_01Q: the actor is the caller'; end if;
  end loop;
end
$pay_access$;

-- ═════════ Cash and Card: the ledger row, the amount, the actor, the time, the order state ═════════
do $methods$
declare
  v_suffix text := (select v from public._cg01q_ctx where k = 'suffix');
  v_cafe uuid := (select v::uuid from public._cg01q_ctx where k = 'cafe');
  u_member uuid := (select v::uuid from public._cg01q_ctx where k = 'u_member');
  u_member2 uuid := (select v::uuid from public._cg01q_ctx where k = 'u_member2');
  u_admin uuid := (select v::uuid from public._cg01q_ctx where k = 'u_admin');
  v_method text; v_creator uuid; v_payer uuid; v_config jsonb; v_product text;
  v_order uuid; v_expected numeric; v_r jsonb; v_row commerce.service_order_payments; v_d jsonb; v_o commerce.service_orders;
  v_started timestamptz := clock_timestamp();
  v_text text; v_list jsonb; n integer;
begin
  for v_method, v_creator, v_payer, v_product, v_config in
    select * from (values ('cash', u_member, u_member2, 'scan', '{"units":6}'::jsonb), ('card', u_member2, u_admin, 'a3-lamination', '{"units":3}'::jsonb)) x
  loop
    v_order := public._cg01q_create(v_creator, 'cg01q-' || v_suffix || '-m-' || v_method, v_product, v_config);
    v_expected := (commerce.qs_calculate_price(v_cafe, v_product, v_config) ->> 'total')::numeric;
    v_started := clock_timestamp();
    v_r := public._cg01q_pay(v_payer, v_order, v_method, 'cg01q-' || v_suffix || '-pay-' || v_method);
    if not (v_r ->> 'ok')::boolean or (v_r ->> 'replayed')::boolean or (v_r ->> 'alreadyPaid')::boolean or v_r ->> 'method' <> v_method or v_r ->> 'paymentStatus' <> 'paid'
       or (v_r ->> 'amount')::numeric <> v_expected or (v_r ->> 'outstanding')::numeric <> 0 or (v_r ->> 'amountPaid')::numeric <> v_expected or v_expected <= 0 then
      raise exception 'CAFE_GUEST_01Q: % payment result wrong: %', v_method, v_r;
    end if;
    if (select array_agg(k order by k) from jsonb_object_keys(v_r) k) is distinct from array['alreadyPaid', 'amount', 'amountPaid', 'method', 'ok', 'orderId', 'orderNumber', 'outstanding', 'paidAt', 'paymentId', 'paymentStatus', 'replayed', 'totalAmount'] then
      raise exception 'CAFE_GUEST_01Q: the payment result has exactly the pinned keys, got %', (select array_agg(k order by k) from jsonb_object_keys(v_r) k);
    end if;
    select * into v_row from commerce.service_order_payments where service_order_id = v_order;
    if (select count(*) from commerce.service_order_payments where service_order_id = v_order) <> 1 or v_row.provider <> v_method or v_row.status <> 'completed' or v_row.amount <> v_expected
       or v_row.recorded_by is distinct from v_payer or v_row.tenant_id <> v_cafe or v_row.recorded_by = v_creator and v_creator = v_payer
       or v_row.completed_at < v_started or v_row.completed_at > clock_timestamp() or v_row.idempotency_key <> 'counter-payment:' || v_payer::text || ':cg01q-' || v_suffix || '-pay-' || v_method
       or v_row.pf_payment_id is not null or v_row.raw_itn is not null then
      raise exception 'CAFE_GUEST_01Q: the ledger row for % is wrong: %', v_method, to_jsonb(v_row);
    end if;
    if (v_r ->> 'paymentId')::uuid <> v_row.id or (v_r ->> 'paidAt')::timestamptz <> v_row.completed_at then raise exception 'CAFE_GUEST_01Q: the result names the ledger row'; end if;
    select * into v_o from commerce.service_orders where id = v_order;
    if v_o.payment_status <> 'paid' or v_o.status <> 'submitted' or v_o.total_amount <> v_expected or v_o.source_metadata -> 'payment' ->> 'provider' <> v_method then
      raise exception 'CAFE_GUEST_01Q: the order is now paid with its status untouched, got % / %', v_o.payment_status, v_o.status;
    end if;
    if v_o.channel <> 'counter' or v_o.created_by is distinct from v_creator then raise exception 'CAFE_GUEST_01Q: channel and creator are not touched by payment'; end if;

    -- detail after payment: paid, zero outstanding, the payment summary, nothing private, no payment action
    v_d := public._cg01q_detail(u_member, v_order);
    if v_d ->> 'paymentStatus' <> 'paid' or (v_d ->> 'outstanding')::numeric <> 0 or (v_d ->> 'amountPaid')::numeric <> v_expected or (v_d -> 'paymentAllowed') <> 'false'::jsonb
       or jsonb_array_length(v_d -> 'payments') <> 1 or v_d -> 'payments' -> 0 ->> 'method' <> v_method or (v_d -> 'payments' -> 0 ->> 'amount')::numeric <> v_expected
       or (select array_agg(k order by k) from jsonb_object_keys(v_d -> 'payments' -> 0) k) is distinct from array['amount', 'method', 'paidAt', 'paymentId'] then
      raise exception 'CAFE_GUEST_01Q: the detail after % payment is wrong: %', v_method, v_d;
    end if;
    v_text := lower(v_d::text);
    if v_text like '%' || lower(v_payer::text) || '%' or v_text like '%counter-payment%' then raise exception 'CAFE_GUEST_01Q: neither the actor nor the payment key is returned'; end if;

    -- today's list regression: it now reports Paid
    v_list := public._cg01q_list(u_member);
    select count(*) into n from jsonb_array_elements(v_list -> 'orders') o where o ->> 'orderId' = v_order::text and o ->> 'paymentStatus' = 'paid';
    if n <> 1 then raise exception 'CAFE_GUEST_01Q: Today''s Orders must report the order as paid'; end if;
  end loop;

  -- nothing else was touched by paying: no tokens, files, handoffs
  if exists (select 1 from commerce.service_order_handoffs) or exists (select 1 from commerce.service_order_files) then raise exception 'CAFE_GUEST_01Q: payment creates no handoff or file'; end if;
end
$methods$;

-- ═════════ rejections ═════════
do $rejections$
declare
  c_not_found constant text := '22023 Counter order was not found.';
  c_no_pay constant text := '22023 This order cannot take a payment.';
  v_suffix text := (select v from public._cg01q_ctx where k = 'suffix');
  v_cafe uuid := (select v::uuid from public._cg01q_ctx where k = 'cafe');
  v_other uuid := (select v::uuid from public._cg01q_ctx where k = 'other');
  u_member uuid := (select v::uuid from public._cg01q_ctx where k = 'u_member');
  v_store uuid := (select v::uuid from public._cg01q_ctx where k = 'storefront_order');
  v_foreign uuid := (select v::uuid from public._cg01q_ctx where k = 'foreign_order');
  v_order uuid; v_x uuid; v_before text; v_got text; m text; v_k integer := 0;
begin
  v_order := public._cg01q_create(u_member, 'cg01q-' || v_suffix || '-rej', 'scan', '{"units":2}');
  v_before := public._cg01q_counts();

  -- methods: exactly cash and card, exactly spelled
  foreach m in array array['eft', 'EFT', 'bank transfer', 'payfast', 'Cash', 'CARD', ' cash', 'cash ', 'credit', 'cheque', '', 'card,cash'] loop
    v_k := v_k + 1;
    if public._cg01q_try_pay('authenticated', u_member, null, v_order, m, 'cg01q-' || v_suffix || '-m' || v_k) is distinct from '22023 Payment method is not supported.' then
      raise exception 'CAFE_GUEST_01Q: method "%" must be refused', m;
    end if;
  end loop;
  if public._cg01q_try_pay('authenticated', u_member, null, v_order, null, 'cg01q-' || v_suffix || '-mnull') is distinct from '22023 Payment method is not supported.' then raise exception 'CAFE_GUEST_01Q: a null method is refused'; end if;

  -- key input
  foreach m in array array['', '   ', 'short', '1234567'] loop
    if public._cg01q_try_pay('authenticated', u_member, null, v_order, 'cash', m) is distinct from '22023 Payment idempotency key is required.' then raise exception 'CAFE_GUEST_01Q: key "%" is refused as required', m; end if;
  end loop;
  if public._cg01q_try_pay('authenticated', u_member, null, v_order, 'cash', null) is distinct from '22023 Payment idempotency key is required.' then raise exception 'CAFE_GUEST_01Q: a null key is required'; end if;
  if public._cg01q_try_pay('authenticated', u_member, null, v_order, 'cash', repeat('k', 129)) is distinct from '22023 Payment idempotency key is not valid.' then raise exception 'CAFE_GUEST_01Q: a long key is refused'; end if;

  -- scope
  if public._cg01q_try_pay('authenticated', u_member, null, v_store, 'cash', 'cg01q-' || v_suffix || '-store') is distinct from c_not_found then raise exception 'CAFE_GUEST_01Q: a storefront order cannot be paid here'; end if;
  if public._cg01q_try_pay('authenticated', u_member, null, v_foreign, 'cash', 'cg01q-' || v_suffix || '-foreign') is distinct from c_not_found then raise exception 'CAFE_GUEST_01Q: a foreign tenant order cannot be paid here'; end if;
  if public._cg01q_try_pay('authenticated', u_member, null, gen_random_uuid(), 'cash', 'cg01q-' || v_suffix || '-unknown') is distinct from c_not_found or public._cg01q_try_pay('authenticated', u_member, null, null, 'cash', 'cg01q-' || v_suffix || '-null') is distinct from c_not_found then
    raise exception 'CAFE_GUEST_01Q: an unknown or null order is not found';
  end if;
  if (select payment_status from commerce.service_orders where id in (v_store, v_foreign) group by payment_status) <> 'unpaid' then raise exception 'CAFE_GUEST_01Q: those orders stay unpaid'; end if;

  -- state of the order
  foreach m in array array['cancelled', 'completed', 'draft'] loop
    v_x := public._cg01q_mk(v_cafe, 'counter', 40, m);
    if public._cg01q_try_pay('authenticated', u_member, null, v_x, 'cash', 'cg01q-' || v_suffix || '-st-' || m) is distinct from c_no_pay then raise exception 'CAFE_GUEST_01Q: a % order cannot take a payment', m; end if;
  end loop;
  foreach m in array array['pending', 'failed', 'refunded', 'cancelled'] loop
    v_x := public._cg01q_mk(v_cafe, 'counter', 40, 'submitted', m);
    if public._cg01q_try_pay('authenticated', u_member, null, v_x, 'cash', 'cg01q-' || v_suffix || '-ps-' || m) is distinct from c_no_pay then raise exception 'CAFE_GUEST_01Q: a % payment status cannot take a payment', m; end if;
  end loop;
  v_x := public._cg01q_mk(v_cafe, 'counter', 0);
  if public._cg01q_try_pay('authenticated', u_member, null, v_x, 'cash', 'cg01q-' || v_suffix || '-zero') is distinct from '22023 This order has nothing outstanding.' then raise exception 'CAFE_GUEST_01Q: a zero total has nothing outstanding'; end if;
  -- fully covered by an existing completed ledger row but still marked unpaid: nothing outstanding
  v_x := public._cg01q_mk(v_cafe, 'counter', 40);
  insert into commerce.service_order_payments(tenant_id, service_order_id, provider, status, amount, completed_at) values (v_cafe, v_x, 'payfast', 'completed', 40, now());
  if public._cg01q_try_pay('authenticated', u_member, null, v_x, 'cash', 'cg01q-' || v_suffix || '-covered') is distinct from '22023 This order has nothing outstanding.' then raise exception 'CAFE_GUEST_01Q: an order already covered by the ledger has nothing outstanding'; end if;
  -- partly covered: only the remainder is taken, never the whole total again
  v_x := public._cg01q_mk(v_cafe, 'counter', 40);
  insert into commerce.service_order_payments(tenant_id, service_order_id, provider, status, amount, completed_at) values (v_cafe, v_x, 'payfast', 'completed', 15, now());
  if public._cg01q_try_pay('authenticated', u_member, null, v_x, 'card', 'cg01q-' || v_suffix || '-part') <> 'ok' or (select amount from commerce.service_order_payments where service_order_id = v_x and provider = 'card') <> 25 then
    raise exception 'CAFE_GUEST_01Q: the server settles exactly the outstanding remainder (25)';
  end if;
  -- a pending (not completed) gateway attempt does not count as money received
  v_x := public._cg01q_mk(v_cafe, 'counter', 40);
  insert into commerce.service_order_payments(tenant_id, service_order_id, provider, status, amount) values (v_cafe, v_x, 'payfast', 'pending', 40);
  if public._cg01q_try_pay('authenticated', u_member, null, v_x, 'cash', 'cg01q-' || v_suffix || '-pend') <> 'ok' or (select amount from commerce.service_order_payments where service_order_id = v_x and provider = 'cash') <> 40 then
    raise exception 'CAFE_GUEST_01Q: a pending attempt is not a payment';
  end if;

  -- already sent to production / OPPS: refused, unchanged
  v_x := public._cg01q_mk(v_cafe, 'counter', 40);
  insert into commerce.service_order_handoffs(service_order_id, source_tenant_id, target_tenant_id, status, idempotency_key) values (v_x, v_cafe, v_cafe, 'sent', 'CG01Q-HO-' || v_x::text);
  if public._cg01q_try_pay('authenticated', u_member, null, v_x, 'cash', 'cg01q-' || v_suffix || '-sent') is distinct from '22023 This order has already been sent to production and cannot take a counter payment.' then raise exception 'CAFE_GUEST_01Q: a sent order cannot take a counter payment'; end if;
  -- a merely previewed handoff does not block payment
  v_x := public._cg01q_mk(v_cafe, 'counter', 40);
  insert into commerce.service_order_handoffs(service_order_id, source_tenant_id, target_tenant_id, status, idempotency_key) values (v_x, v_cafe, v_cafe, 'previewed', 'CG01Q-HO-' || v_x::text);
  if public._cg01q_try_pay('authenticated', u_member, null, v_x, 'cash', 'cg01q-' || v_suffix || '-prev') <> 'ok' then raise exception 'CAFE_GUEST_01Q: a previewed handoff does not block payment'; end if;

  -- the order under test was never paid by any of the refused calls
  if (select payment_status from commerce.service_orders where id = v_order) <> 'unpaid' or exists (select 1 from commerce.service_order_payments where service_order_id = v_order) then
    raise exception 'CAFE_GUEST_01Q: refused calls wrote nothing to the order under test';
  end if;
  if (select count(*) from commerce.service_order_payments) - (select count(*) from commerce.service_order_payments p where p.service_order_id in (select id from commerce.service_orders)) <> 0 then raise exception 'CAFE_GUEST_01Q: no orphan ledger rows'; end if;
end
$rejections$;

-- ═════════ idempotency: same request, conflicts, already paid, actor isolation ═════════
do $idem$
declare
  v_suffix text := (select v from public._cg01q_ctx where k = 'suffix');
  u_member uuid := (select v::uuid from public._cg01q_ctx where k = 'u_member');
  u_admin uuid := (select v::uuid from public._cg01q_ctx where k = 'u_admin');
  v_a uuid; v_b uuid; v_r1 jsonb; v_r2 jsonb; v_k text := 'cg01q-' || (select v from public._cg01q_ctx where k = 'suffix') || '-idem';
begin
  v_a := public._cg01q_create(u_member, 'cg01q-' || v_suffix || '-ia', 'a4-lamination', '{"units":5}');
  v_b := public._cg01q_create(u_member, 'cg01q-' || v_suffix || '-ib', 'a4-lamination', '{"units":1}');

  -- a conflicting reuse BEFORE the key is spent on anything is just a fresh key, so spend it first
  v_r1 := public._cg01q_pay(u_member, v_a, 'cash', v_k);
  -- the same request again: the original payment, no second row
  v_r2 := public._cg01q_pay(u_member, v_a, 'cash', v_k);
  if not (v_r2 ->> 'ok')::boolean or not (v_r2 ->> 'replayed')::boolean or v_r2 ->> 'paymentId' <> v_r1 ->> 'paymentId' or v_r2 ->> 'amount' <> v_r1 ->> 'amount' or v_r2 ->> 'paidAt' <> v_r1 ->> 'paidAt' or v_r2 ->> 'method' <> 'cash' then
    raise exception 'CAFE_GUEST_01Q: the same request returns the original payment, got %', v_r2;
  end if;
  if (select count(*) from commerce.service_order_payments where service_order_id = v_a) <> 1 then raise exception 'CAFE_GUEST_01Q: a replay creates no second row'; end if;
  -- the same key with a different method or a different order is a conflict
  if public._cg01q_try_pay('authenticated', u_member, null, v_a, 'card', v_k) is distinct from '23505 This payment key was already used for a different payment request.' then raise exception 'CAFE_GUEST_01Q: same key, changed method = conflict'; end if;
  if public._cg01q_try_pay('authenticated', u_member, null, v_b, 'cash', v_k) is distinct from '23505 This payment key was already used for a different payment request.' then raise exception 'CAFE_GUEST_01Q: same key, changed order = conflict'; end if;
  if (select payment_status from commerce.service_orders where id = v_b) <> 'unpaid' or exists (select 1 from commerce.service_order_payments where service_order_id = v_b) then raise exception 'CAFE_GUEST_01Q: a conflict pays nothing'; end if;
  -- a NEW key after the order is paid never creates another payment
  v_r2 := public._cg01q_pay(u_member, v_a, 'cash', v_k || '-new');
  if (v_r2 ->> 'ok')::boolean or v_r2 ->> 'reason' <> 'already_paid' or v_r2 ->> 'paymentStatus' <> 'paid' or v_r2 ? 'paymentId' or v_r2 ? 'amount' then raise exception 'CAFE_GUEST_01Q: a new key on a paid order is already_paid, got %', v_r2; end if;
  v_r2 := public._cg01q_pay(u_member, v_a, 'card', v_k || '-new2');
  if (v_r2 ->> 'ok')::boolean or v_r2 ->> 'reason' <> 'already_paid' then raise exception 'CAFE_GUEST_01Q: another method after payment is already_paid too'; end if;
  if (select count(*) from commerce.service_order_payments where service_order_id = v_a) <> 1 then raise exception 'CAFE_GUEST_01Q: still exactly one payment'; end if;
  -- actor isolation: another operator using the same key string neither gets the original nor a conflict; the key is theirs alone
  v_r2 := public._cg01q_pay(u_admin, v_a, 'cash', v_k);
  if (v_r2 ->> 'ok')::boolean or v_r2 ->> 'reason' <> 'already_paid' or v_r2 ? 'paymentId' then raise exception 'CAFE_GUEST_01Q: another actor cannot retrieve someone else''s payment through a key, got %', v_r2; end if;
  v_r2 := public._cg01q_pay(u_admin, v_b, 'card', v_k);
  if not (v_r2 ->> 'ok')::boolean or (v_r2 ->> 'replayed')::boolean or v_r2 ->> 'method' <> 'card' then raise exception 'CAFE_GUEST_01Q: the same key string for another actor is an independent key, got %', v_r2; end if;
  if (select count(*) from commerce.service_order_payments where service_order_id = v_b) <> 1 or (select recorded_by from commerce.service_order_payments where service_order_id = v_b) <> u_admin then raise exception 'CAFE_GUEST_01Q: that payment belongs to the admin'; end if;
  -- the key is unique in the database itself
  begin
    insert into commerce.service_order_payments(tenant_id, service_order_id, provider, status, amount, completed_at, recorded_by, idempotency_key)
    select tenant_id, service_order_id, 'cash', 'completed', 1, now(), recorded_by, idempotency_key from commerce.service_order_payments where service_order_id = v_a and provider = 'cash';
    raise exception 'CAFE_GUEST_01Q: a duplicate key must be refused by the database';
  exception when unique_violation then null;
  end;
end
$idem$;

-- ═════════ the database itself refuses a second full payment or a half-formed one ═════════
do $ledger$
declare
  v_cafe uuid := (select v::uuid from public._cg01q_ctx where k = 'cafe');
  u_member uuid := (select v::uuid from public._cg01q_ctx where k = 'u_member');
  v_x uuid;
begin
  v_x := public._cg01q_mk(v_cafe, 'counter', 10);
  insert into commerce.service_order_payments(tenant_id, service_order_id, provider, status, amount, completed_at, recorded_by, idempotency_key) values (v_cafe, v_x, 'cash', 'completed', 10, now(), u_member, 'k-one-' || v_x::text);
  begin
    insert into commerce.service_order_payments(tenant_id, service_order_id, provider, status, amount, completed_at, recorded_by, idempotency_key) values (v_cafe, v_x, 'card', 'completed', 10, now(), u_member, 'k-two-' || v_x::text);
    raise exception 'CAFE_GUEST_01Q: a second completed counter payment on one order must violate the unique index';
  exception when unique_violation then null;
  end;
  begin
    insert into commerce.service_order_payments(tenant_id, service_order_id, provider, status, amount, completed_at, recorded_by) values (v_cafe, public._cg01q_mk(v_cafe, 'counter', 10), 'cash', 'completed', 10, now(), u_member);
    raise exception 'CAFE_GUEST_01Q: a counter payment without a key must violate the shape check';
  exception when check_violation then null;
  end;
  begin
    insert into commerce.service_order_payments(tenant_id, service_order_id, provider, status, amount, recorded_by, idempotency_key) values (v_cafe, public._cg01q_mk(v_cafe, 'counter', 10), 'card', 'pending', 10, u_member, 'k-three-' || gen_random_uuid()::text);
    raise exception 'CAFE_GUEST_01Q: a pending counter payment must violate the shape check';
  exception when check_violation then null;
  end;
  begin
    insert into commerce.service_order_payments(tenant_id, service_order_id, provider, status, amount, completed_at, recorded_by, idempotency_key) values (v_cafe, public._cg01q_mk(v_cafe, 'counter', 10), 'eft', 'completed', 10, now(), u_member, 'k-four-' || gen_random_uuid()::text);
    raise exception 'CAFE_GUEST_01Q: EFT must not be an allowed provider';
  exception when check_violation then null;
  end;
  -- the existing gateway path still fits the ledger
  insert into commerce.service_order_payments(tenant_id, service_order_id, provider, status, amount) values (v_cafe, public._cg01q_mk(v_cafe, 'storefront', 10), 'payfast', 'pending', 10);
end
$ledger$;

-- ═════════ atomicity: a failure after locking and eligibility rolls everything back ═════════
do $atomic$
declare
  v_suffix text := (select v from public._cg01q_ctx where k = 'suffix');
  u_member uuid := (select v::uuid from public._cg01q_ctx where k = 'u_member');
  v_order uuid; v_total numeric; v_got text; v_before text; v_d jsonb;
begin
  v_order := public._cg01q_create(u_member, 'cg01q-' || v_suffix || '-at', 'scan', '{"units":9}');
  select total_amount into v_total from commerce.service_orders where id = v_order;
  v_before := public._cg01q_counts();

  -- 1. the order update fails, after the ledger row was written
  create function public._cg01q_fail_update() returns trigger language plpgsql as $f$ begin if new.payment_status = 'paid' then raise exception 'CG01Q forced failure after the ledger insert'; end if; return new; end $f$;
  create trigger trg_cg01q_fail_update before update on commerce.service_orders for each row execute function public._cg01q_fail_update();
  v_got := public._cg01q_try_pay('authenticated', u_member, null, v_order, 'cash', 'cg01q-' || v_suffix || '-atk1');
  drop trigger trg_cg01q_fail_update on commerce.service_orders;
  if v_got not like '%CG01Q forced failure after the ledger insert' then raise exception 'CAFE_GUEST_01Q: the forced failure must surface, got %', v_got; end if;
  if public._cg01q_counts() is distinct from v_before or exists (select 1 from commerce.service_order_payments where service_order_id = v_order)
     or (select payment_status from commerce.service_orders where id = v_order) <> 'unpaid' or (select source_metadata ? 'payment' from commerce.service_orders where id = v_order) then
    raise exception 'CAFE_GUEST_01Q: a failed transition leaves no ledger row and an unpaid, untouched order';
  end if;

  -- 2. the ledger insert itself fails
  create function public._cg01q_fail_insert() returns trigger language plpgsql as $f$ begin raise exception 'CG01Q forced ledger failure'; end $f$;
  create trigger trg_cg01q_fail_insert before insert on commerce.service_order_payments for each row execute function public._cg01q_fail_insert();
  v_got := public._cg01q_try_pay('authenticated', u_member, null, v_order, 'card', 'cg01q-' || v_suffix || '-atk2');
  drop trigger trg_cg01q_fail_insert on commerce.service_order_payments;
  if v_got not like '%CG01Q forced ledger failure' or public._cg01q_counts() is distinct from v_before or (select payment_status from commerce.service_orders where id = v_order) <> 'unpaid' then
    raise exception 'CAFE_GUEST_01Q: a failed ledger write leaves the order unpaid, got %', v_got;
  end if;

  -- the state a failure leaves is still correct and still payable
  v_d := public._cg01q_detail(u_member, v_order);
  if v_d ->> 'paymentStatus' <> 'unpaid' or (v_d ->> 'outstanding')::numeric <> v_total or (v_d -> 'paymentAllowed') <> 'true'::jsonb or v_d -> 'payments' <> '[]'::jsonb then raise exception 'CAFE_GUEST_01Q: after a failure the detail is still unpaid with the full outstanding'; end if;
  if public._cg01q_try_pay('authenticated', u_member, null, v_order, 'cash', 'cg01q-' || v_suffix || '-atk1') <> 'ok' then raise exception 'CAFE_GUEST_01Q: the same key works once the fault is gone (nothing was recorded for it)'; end if;
  if (select count(*) from commerce.service_order_payments where service_order_id = v_order) <> 1 then raise exception 'CAFE_GUEST_01Q: exactly one payment after recovery'; end if;
end
$atomic$;

rollback;
select 'CAFE-GUEST-01Q counter order payment contracts passed' as result;
