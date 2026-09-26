-- CAFE-GUEST-01M: behavioral contract test for public.create_quick_solution_counter_order().
--
-- Run only against the disposable local harness (supabase/tests/harness/), which replays the
-- migration history INCLUDING the OPPS-owned access layer (public.has_tenant_capability,
-- CAFE-ACCESS-01..03) and
--   20260926220000_cafe_guest_01m_counter_create_order_rpc.sql
-- The harness skips this test, visibly, when the OPPS access layer is absent.
--
-- The RPC is exercised against the REAL seeded products and the REAL server pricing path;
-- expected totals are DERIVED by calling commerce.qs_calculate_price directly, never
-- hard-coded. Every call runs under a real API role (the helper switches with SET LOCAL ROLE),
-- with identity supplied only through JWT claims. Everything is enclosed by BEGIN/ROLLBACK.

\set ON_ERROR_STOP on

begin;

-- ── test-only helpers (public, created in this transaction, rolled back with it) ──────────
create function public._cg01m_try(
  p_role text, p_sub uuid, p_email text, p_key text, p_product text, p_config jsonb,
  p_name text default null, p_mail text default null, p_phone text default null
) returns text
language plpgsql
as $$
declare
  v_state text;
  v_message text;
begin
  perform set_config('request.jwt.claims',
    case when p_sub is null then '{}'
         else jsonb_strip_nulls(jsonb_build_object('sub', p_sub, 'role', 'authenticated', 'email', p_email))::text end, true);
  execute format('set local role %I', p_role);
  perform public.create_quick_solution_counter_order(p_key, p_product, p_config, p_name, p_mail, p_phone);
  execute 'reset role';
  return 'ok';
exception when others then
  get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
  execute 'reset role';
  return v_state || ' ' || v_message;
end
$$;

create function public._cg01m_call(
  p_sub uuid, p_key text, p_product text, p_config jsonb,
  p_name text default null, p_mail text default null, p_phone text default null
) returns jsonb
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  v_result := public.create_quick_solution_counter_order(p_key, p_product, p_config, p_name, p_mail, p_phone);
  execute 'reset role';
  return v_result;
end
$$;

create function public._cg01m_catalog_ids(p_sub uuid) returns text[]
language plpgsql
as $$
declare
  v_ids text[];
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select array_agg(p ->> 'id' order by p ->> 'id') into v_ids from jsonb_array_elements(public.get_quick_solution_counter_catalog() -> 'products') p;
  execute 'reset role';
  return v_ids;
end
$$;

-- Order and item counts for the Cafe tenant, and rows in every commerce table a payment, token, file or handoff could land in.
create function public._cg01m_counts() returns text
language plpgsql
as $$
declare
  v_text text;
  v_table text;
  v_count bigint;
begin
  v_text := (select count(*) from commerce.service_orders) || '/' || (select count(*) from commerce.service_order_items);
  for v_table in
    select c.relname from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'commerce' and c.relkind = 'r'
      and (c.relname like '%payment%' or c.relname like '%token%' or c.relname like '%file%' or c.relname like '%handoff%' or c.relname like '%event%')
    order by c.relname
  loop
    execute format('select count(*) from commerce.%I', v_table) into v_count;
    v_text := v_text || '|' || v_table || '=' || v_count;
  end loop;
  return v_text;
end
$$;

grant execute on function public._cg01m_try(text, uuid, text, text, text, jsonb, text, text, text), public._cg01m_call(uuid, text, text, jsonb, text, text, text),
  public._cg01m_catalog_ids(uuid), public._cg01m_counts() to anon, authenticated, service_role;

-- ═════════ contracts: signature, posture, ACL and what the body may touch ═════════
do $contracts$
declare
  v_rpc regprocedure := to_regprocedure('public.create_quick_solution_counter_order(text,text,jsonb,text,text,text)');
  v_pred regprocedure := to_regprocedure('commerce._qs_product_counter_sellable(uuid,text)');
  v_names text[];
  v_definition text;
begin
  if v_rpc is null then raise exception 'create_quick_solution_counter_order(text,text,jsonb,text,text,text) must exist'; end if;
  select p.proargnames into v_names from pg_catalog.pg_proc p where p.oid = v_rpc;
  if v_names is distinct from array['p_idempotency_key', 'p_product_key', 'p_configuration', 'p_customer_name', 'p_customer_email', 'p_customer_phone'] then
    raise exception 'the arguments must be exactly the idempotency key, product key, configuration and optional customer details, got %', v_names;
  end if;
  if (select p.pronargdefaults from pg_catalog.pg_proc p where p.oid = v_rpc) <> 3 then raise exception 'exactly the three customer fields are optional'; end if;
  if array_to_string(v_names, ',') ~* '(tenant|channel|created|actor|paid|payment|method|amount|price|total|status)' then
    raise exception 'no tenant, channel, actor, payment or price argument may exist: %', v_names;
  end if;
  if pg_catalog.pg_get_function_result(v_rpc) <> 'jsonb' then raise exception 'it must return jsonb'; end if;
  if not (select p.prosecdef from pg_catalog.pg_proc p where p.oid = v_rpc) then raise exception 'it must be SECURITY DEFINER'; end if;
  if (select p.provolatile from pg_catalog.pg_proc p where p.oid = v_rpc) <> 'v' then raise exception 'it writes, so it must be VOLATILE'; end if;
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
  if v_definition !~ '_qs_product_counter_sellable\(v_tenant_id, v_product_key\)' then raise exception 'eligibility must be re-checked by the shared predicate'; end if;
  if v_definition !~ 'qs_calculate_price\(v_tenant_id, v_product_key, p_configuration\)' then raise exception 'price must come from the authoritative server pricing'; end if;
  if v_definition !~ 'auth\.uid\(\)' or v_definition !~ '''counter'',\s+v_actor' then raise exception 'channel counter and created_by = auth.uid() are set server-side'; end if;
  -- no price arithmetic, no private data, no payment writes
  if v_definition ~ '(pricing_definition|unitprice|baserate|marginrate|suppliercost|referenceprice)' then raise exception 'the body must not read or compute pricing itself'; end if;
  if v_definition ~ '(service_order_payments|payment_method|payfast|receipt|tracking_token|upload_token|service_order_files|service_order_handoffs)' then
    raise exception 'the body must not touch payments, tokens, files or handoffs';
  end if;
  if v_definition !~ '''unpaid''' or v_definition !~ '''submitted''' then raise exception 'the canonical initial state is submitted / unpaid'; end if;

  if v_pred is null then raise exception 'the shared counter-eligibility predicate must exist'; end if;
  if has_function_privilege('anon', v_pred, 'EXECUTE') or has_function_privilege('authenticated', v_pred, 'EXECUTE') or has_function_privilege('service_role', v_pred, 'EXECUTE') then
    raise exception 'the internal predicate must not be executable by any API role';
  end if;
  -- the catalogue and the write path ask the very same predicate
  if lower(pg_catalog.pg_get_functiondef(to_regprocedure('public.get_quick_solution_counter_catalog()'))) !~ '_qs_product_counter_sellable\(c\.tenant_id, c\.source_key\)' then
    raise exception 'the counter catalogue must use the shared predicate';
  end if;
end
$contracts$;

-- ═════════ fixtures ═════════
create table public._cg01m_ctx (k text primary key, v text);

do $fixtures$
declare
  v_suffix text := replace(gen_random_uuid()::text, '-', '');
  v_cafe uuid;
  v_other uuid := gen_random_uuid();
  u record;
  v_product_id uuid;
begin
  select t.id into v_cafe from public.tenants t where t.slug = 'quick-solution' and t.status = 'active';
  if v_cafe is null then raise exception 'CAFE_GUEST_01M_TEST_SETUP: the quick-solution tenant must exist'; end if;
  insert into public._cg01m_ctx values ('suffix', v_suffix), ('cafe', v_cafe::text), ('other', v_other::text);

  insert into public.tenants(id, slug, name, status, settings) values (v_other, 'cg01m-other-' || left(v_suffix, 10), 'CG01M other cafe', 'active', '{}'::jsonb);
  insert into public.tenant_capabilities(tenant_id, capability_key, enabled) values (v_other, 'quick_solution', true);

  for u in select * from (values ('nomember'), ('member'), ('member2'), ('admin'), ('owner'), ('suspended'), ('otherowner'), ('appadmin'), ('oppsstaff')) as x(label) loop
    insert into public._cg01m_ctx values ('u_' || u.label, gen_random_uuid()::text);
    insert into auth.users(id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values ((select v::uuid from public._cg01m_ctx where k = 'u_' || u.label), 'authenticated', 'authenticated', 'cg01m-' || u.label || '-' || v_suffix || '@disposable.test', now(), '{}'::jsonb, '{}'::jsonb, now(), now());
  end loop;

  -- SETUP-ONLY approved-owner claim (the real OPPS trigger lets a role='admin' users row in only for an approved-owner email); cleared at once.
  perform set_config('request.jwt.claims', jsonb_build_object('sub', (select v from public._cg01m_ctx where k = 'u_appadmin'), 'role', 'authenticated', 'email', 'jointx.co@gmail.com')::text, true);
  insert into public.users(auth_user_id, user_email, full_name, role, is_active)
  values ((select v::uuid from public._cg01m_ctx where k = 'u_appadmin'), 'cg01m-appadmin-' || v_suffix || '@disposable.test', 'CG01M app admin', 'admin', true),
         ((select v::uuid from public._cg01m_ctx where k = 'u_oppsstaff'), 'cg01m-oppsstaff-' || v_suffix || '@disposable.test', 'CG01M OPPS staff', 'user', true);
  perform set_config('request.jwt.claims', '{}', true);
  if lower(coalesce(auth.jwt() ->> 'email', '')) <> '' then raise exception 'CAFE_GUEST_01M_TEST_SETUP: the temporary approved-owner claim must be cleared'; end if;

  insert into public.tenant_memberships(tenant_id, auth_user_id, tenant_role, status)
  select v_cafe, (select v::uuid from public._cg01m_ctx where k = 'u_' || m.label), m.role, m.status
  from (values ('member', 'member', 'active'), ('member2', 'member', 'active'), ('admin', 'admin', 'active'), ('owner', 'owner', 'active'), ('suspended', 'member', 'suspended')) as m(label, role, status);
  insert into public.tenant_memberships(tenant_id, auth_user_id, tenant_role, status)
  values (v_other, (select v::uuid from public._cg01m_ctx where k = 'u_otherowner'), 'owner', 'active');
  if exists (select 1 from public.tenant_memberships m where m.tenant_id = v_cafe and m.auth_user_id in
     ((select v::uuid from public._cg01m_ctx where k = 'u_appadmin'), (select v::uuid from public._cg01m_ctx where k = 'u_oppsstaff'))) then
    raise exception 'CAFE_GUEST_01M_TEST_SETUP: the app-admin and OPPS-staff fixtures must have no Cafe membership';
  end if;
end
$fixtures$;

-- ═════════ access, module and tenant state, customer and idempotency-key input ═════════
do $access$
declare
  c_signin constant text := '42501 Staff sign-in is required.';
  c_denied constant text := '42501 You do not have access to the Quick Solution counter.';
  c_no_tenant constant text := '22023 Quick Solution tenant was not found.';
  c_no_module constant text := '22023 Quick Solution counter is not active.';
  v_suffix text := (select v from public._cg01m_ctx where k = 'suffix');
  v_cafe uuid := (select v::uuid from public._cg01m_ctx where k = 'cafe');
  u_nomember uuid := (select v::uuid from public._cg01m_ctx where k = 'u_nomember');
  u_member uuid := (select v::uuid from public._cg01m_ctx where k = 'u_member');
  u_admin uuid := (select v::uuid from public._cg01m_ctx where k = 'u_admin');
  u_owner uuid := (select v::uuid from public._cg01m_ctx where k = 'u_owner');
  u_suspended uuid := (select v::uuid from public._cg01m_ctx where k = 'u_suspended');
  u_otherowner uuid := (select v::uuid from public._cg01m_ctx where k = 'u_otherowner');
  u_appadmin uuid := (select v::uuid from public._cg01m_ctx where k = 'u_appadmin');
  u_oppsstaff uuid := (select v::uuid from public._cg01m_ctx where k = 'u_oppsstaff');
  v_scan constant jsonb := '{"units":2}';
  v_labels text[]; v_subs uuid[]; v_emails text[]; v_expect text[];
  i integer;
  v_got text;
  v_before text;
  v_module public.tenant_capabilities;
  v_state text;
begin
  v_labels := array['anonymous', 'authenticated non-member', 'active member', 'active admin', 'active owner', 'suspended member',
                    'owner of a FOREIGN tenant', 'app admin with no Cafe membership', 'app admin with the approved-owner email', 'OPPS staff with no Cafe membership']::text[];
  v_subs := array[null, u_nomember, u_member, u_admin, u_owner, u_suspended, u_otherowner, u_appadmin, u_appadmin, u_oppsstaff]::uuid[];
  v_emails := array[null, null, null, null, null, null, null, null, 'jointx.co@gmail.com', null]::text[];
  v_expect := array[c_signin, c_denied, 'ok', 'ok', 'ok', c_denied, c_denied, c_denied, c_denied, c_denied]::text[];
  for i in 1 .. array_length(v_labels, 1) loop
    v_before := public._cg01m_counts();
    v_got := public._cg01m_try('authenticated', v_subs[i], v_emails[i], 'cg01m-' || v_suffix || '-access-' || i, 'scan', v_scan);
    if v_got is distinct from v_expect[i] then
      raise exception 'CAFE_GUEST_01M: access for "%" expected "%" but got "%"', v_labels[i], v_expect[i], v_got;
    end if;
    if v_expect[i] <> 'ok' and public._cg01m_counts() is distinct from v_before then
      raise exception 'CAFE_GUEST_01M: a denied "%" must write nothing', v_labels[i];
    end if;
  end loop;

  -- the API roles: anon and service_role cannot execute it at all
  foreach v_state in array array['anon', 'service_role'] loop
    v_before := public._cg01m_counts();
    v_got := public._cg01m_try(v_state, u_owner, null, 'cg01m-' || v_suffix || '-role', 'scan', v_scan);
    if v_got not like '42501 permission denied for function create_quick_solution_counter_order%' or public._cg01m_counts() is distinct from v_before then
      raise exception 'CAFE_GUEST_01M: the % role must be refused by the ACL and write nothing, got "%"', v_state, v_got;
    end if;
  end loop;

  -- module and tenant state (an authorized actor gets the stable error; nothing is written)
  select * into v_module from public.tenant_capabilities tc where tc.tenant_id = v_cafe and tc.capability_key = 'quick_solution';
  v_before := public._cg01m_counts();
  update public.tenant_capabilities set enabled = false where id = v_module.id;
  if public._cg01m_try('authenticated', u_member, null, 'cg01m-' || v_suffix || '-mod1', 'scan', v_scan) is distinct from c_no_module
     or public._cg01m_try('authenticated', u_owner, null, 'cg01m-' || v_suffix || '-mod2', 'scan', v_scan) is distinct from c_no_module then
    raise exception 'CAFE_GUEST_01M: a disabled quick_solution module must deny with the stable module error';
  end if;
  if public._cg01m_try('authenticated', u_nomember, null, 'cg01m-' || v_suffix || '-mod3', 'scan', v_scan) is distinct from c_denied then
    raise exception 'CAFE_GUEST_01M: authorization comes before the module check';
  end if;
  update public.tenant_capabilities set enabled = true where id = v_module.id;
  foreach v_state in array array['suspended', 'archived'] loop
    update public.tenants set status = v_state where id = v_cafe;
    if public._cg01m_try('authenticated', u_member, null, 'cg01m-' || v_suffix || '-ten-' || v_state, 'scan', v_scan) is distinct from c_no_tenant then
      raise exception 'CAFE_GUEST_01M: a % Cafe tenant must fail closed with the tenant-not-found error', v_state;
    end if;
  end loop;
  update public.tenants set status = 'active' where id = v_cafe;
  if public._cg01m_counts() is distinct from v_before then raise exception 'CAFE_GUEST_01M: module/tenant denials must write nothing'; end if;

  -- a just-suspended member is denied
  update public.tenant_memberships set status = 'suspended' where tenant_id = v_cafe and auth_user_id = u_admin;
  if public._cg01m_try('authenticated', u_admin, null, 'cg01m-' || v_suffix || '-susp', 'scan', v_scan) is distinct from c_denied then
    raise exception 'CAFE_GUEST_01M: a just-suspended admin must be denied';
  end if;
  update public.tenant_memberships set status = 'active' where tenant_id = v_cafe and auth_user_id = u_admin;

  -- idempotency key input
  foreach v_state in array array[null, '', '   ', 'short', '1234567'] loop
    if public._cg01m_try('authenticated', u_member, null, v_state, 'scan', v_scan) is distinct from '22023 Order idempotency key is required.' then
      raise exception 'CAFE_GUEST_01M: idempotency key "%" must be refused as required', v_state;
    end if;
  end loop;
  if public._cg01m_try('authenticated', u_member, null, repeat('k', 129), 'scan', v_scan) is distinct from '22023 Order idempotency key is not valid.' then
    raise exception 'CAFE_GUEST_01M: an over-long idempotency key must be refused';
  end if;
  if public._cg01m_try('authenticated', u_member, null, repeat('k', 128), 'scan', v_scan) is distinct from 'ok' then
    raise exception 'CAFE_GUEST_01M: a 128-character idempotency key is valid';
  end if;

  -- customer input
  if public._cg01m_try('authenticated', u_member, null, 'cg01m-' || v_suffix || '-cn1', 'scan', v_scan, 'A') is distinct from '22023 Customer name is not valid.'
     or public._cg01m_try('authenticated', u_member, null, 'cg01m-' || v_suffix || '-cn2', 'scan', v_scan, repeat('n', 161)) is distinct from '22023 Customer name is not valid.'
     or public._cg01m_try('authenticated', u_member, null, 'cg01m-' || v_suffix || '-cn3', 'scan', v_scan, null, 'not-an-email') is distinct from '22023 Email address is not valid.'
     or public._cg01m_try('authenticated', u_member, null, 'cg01m-' || v_suffix || '-cn4', 'scan', v_scan, null, null, '12') is distinct from '22023 Phone number is not valid.' then
    raise exception 'CAFE_GUEST_01M: invalid customer details must be refused with the established messages';
  end if;
end
$access$;

-- ═════════ writes, customer defaulting and real server pricing ═════════
do $writes$
declare
  v_suffix text := (select v from public._cg01m_ctx where k = 'suffix');
  v_cafe uuid := (select v::uuid from public._cg01m_ctx where k = 'cafe');
  v_other uuid := (select v::uuid from public._cg01m_ctx where k = 'other');
  u_member uuid := (select v::uuid from public._cg01m_ctx where k = 'u_member');
  u_admin uuid := (select v::uuid from public._cg01m_ctx where k = 'u_admin');
  u_owner uuid := (select v::uuid from public._cg01m_ctx where k = 'u_owner');
  v_result jsonb;
  v_order commerce.service_orders;
  v_item commerce.service_order_items;
  v_direct jsonb;
  v_before text;
  v_cfg jsonb;
  v_case jsonb;
  v_orders_before bigint;
  v_items_before bigint;
begin
  -- ── one order, one item, server-decided identity ──
  v_cfg := '{"units":4}'::jsonb;
  v_orders_before := (select count(*) from commerce.service_orders);
  v_items_before := (select count(*) from commerce.service_order_items);
  v_result := public._cg01m_call(u_member, 'cg01m-' || v_suffix || '-w1', 'scan', v_cfg);
  if (select count(*) from commerce.service_orders) <> v_orders_before + 1 or (select count(*) from commerce.service_order_items) <> v_items_before + 1 then
    raise exception 'CAFE_GUEST_01M: exactly one order and exactly one item must be created';
  end if;
  select * into v_order from commerce.service_orders where id = (v_result ->> 'orderId')::uuid;
  select * into v_item from commerce.service_order_items where order_id = v_order.id;
  if (select count(*) from commerce.service_order_items where order_id = v_order.id) <> 1 then raise exception 'CAFE_GUEST_01M: the order must have exactly one item'; end if;

  if v_order.tenant_id <> v_cafe then raise exception 'CAFE_GUEST_01M: the order must belong to the Cafe tenant'; end if;
  if v_order.channel <> 'counter' then raise exception 'CAFE_GUEST_01M: channel must be counter, got %', v_order.channel; end if;
  if v_order.created_by is distinct from u_member then raise exception 'CAFE_GUEST_01M: created_by must be auth.uid(), got %', v_order.created_by; end if;
  if v_order.status <> 'submitted' or v_order.payment_status <> 'unpaid' then raise exception 'CAFE_GUEST_01M: the canonical initial state is submitted / unpaid, got % / %', v_order.status, v_order.payment_status; end if;
  if v_order.customer_name <> 'Walk-in' or v_order.customer_email is not null or v_order.customer_phone is not null then
    raise exception 'CAFE_GUEST_01M: no details must default to Walk-in with null email and phone, got % % %', v_order.customer_name, v_order.customer_email, v_order.customer_phone;
  end if;
  if v_order.fulfilment_type <> 'cafe' or v_order.fulfilment_fee <> 0 or v_order.delivery_address is not null then raise exception 'CAFE_GUEST_01M: a counter sale is a Cafe sale with no fee'; end if;
  if v_order.source_metadata ->> 'channel' <> 'counter' or v_order.order_number is null or v_order.opps_order_id is not null then raise exception 'CAFE_GUEST_01M: unexpected order metadata'; end if;
  if v_order.idempotency_key <> 'counter:' || u_member::text || ':cg01m-' || v_suffix || '-w1' then raise exception 'CAFE_GUEST_01M: the idempotency key must be actor-scoped in the database'; end if;

  -- the price is the authoritative server result, written verbatim
  v_direct := commerce.qs_calculate_price(v_cafe, 'scan', v_cfg);
  if (v_direct ->> 'total')::numeric <= 0 then raise exception 'CAFE_GUEST_01M_TEST_SETUP: the reference price must be positive'; end if;
  if v_order.subtotal <> (v_direct ->> 'total')::numeric or v_order.total_amount <> v_order.subtotal or v_item.line_total <> v_order.subtotal then
    raise exception 'CAFE_GUEST_01M: subtotal, total and line total must equal the server price %, got % % %', v_direct ->> 'total', v_order.subtotal, v_order.total_amount, v_item.line_total;
  end if;
  if v_item.product_key <> 'scan' or v_item.quantity <> 1 or v_item.configuration is distinct from v_cfg or v_item.pricing_snapshot is distinct from v_direct -> 'snapshot'
     or v_item.file_refs is distinct from '[]'::jsonb or v_item.tenant_id <> v_cafe or v_item.product_id <> (v_direct ->> 'productId')::uuid then
    raise exception 'CAFE_GUEST_01M: the item must carry the product, one unit of quantity, the configuration, the server snapshot and no files: %', to_jsonb(v_item);
  end if;

  -- the response: exactly the summary the counter needs, nothing private
  if (select array_agg(k order by k) from jsonb_object_keys(v_result) k) is distinct from
     array['channel', 'configuration', 'createdAt', 'customerEmail', 'customerName', 'customerPhone', 'fulfilmentFee', 'lineTotal', 'ok', 'orderId', 'orderNumber',
           'paymentStatus', 'productKey', 'productName', 'replayed', 'status', 'subtotal', 'totalAmount'] then
    raise exception 'CAFE_GUEST_01M: unexpected response keys %', (select array_agg(k) from jsonb_object_keys(v_result) k);
  end if;
  if v_result ->> 'channel' <> 'counter' or v_result ->> 'paymentStatus' <> 'unpaid' or v_result ->> 'status' <> 'submitted' or (v_result ->> 'replayed')::boolean is not false
     or (v_result ->> 'lineTotal')::numeric <> v_order.subtotal or (v_result ->> 'totalAmount')::numeric <> v_order.total_amount or v_result -> 'configuration' is distinct from v_cfg then
    raise exception 'CAFE_GUEST_01M: the response must mirror the stored order: %', v_result;
  end if;
  if position(lower(u_member::text) in lower(v_result::text)) > 0 or position(v_cafe::text in v_result::text) > 0
     or lower(v_result::text) ~ '(pricing_definition|pricingdefinition|suppliercost|referenceprice|marginrate|created_by|tenant_id|capability|idempotency)' then
    raise exception 'CAFE_GUEST_01M: the response must carry no actor, tenant, authorization, idempotency or private pricing data: %', v_result;
  end if;

  -- ── nothing the caller passes can choose the actor, tenant or channel ──
  v_result := public._cg01m_call(u_admin, 'cg01m-' || v_suffix || '-w2', 'scan',
    jsonb_build_object('units', 3, 'channel', 'storefront', 'created_by', u_owner, 'tenant_id', v_other, 'tenantId', v_other, 'paid', true, 'paymentStatus', 'paid'));
  select * into v_order from commerce.service_orders where id = (v_result ->> 'orderId')::uuid;
  if v_order.channel <> 'counter' or v_order.created_by is distinct from u_admin or v_order.tenant_id <> v_cafe or v_order.payment_status <> 'unpaid' then
    raise exception 'CAFE_GUEST_01M: stray configuration keys must not change the channel, actor, tenant or payment state';
  end if;

  -- ── customer details: default, blank, partial and supplied (normalized like the storefront RPC) ──
  for v_case in select e from jsonb_array_elements('[
      {"n":null,"m":null,"p":null,"en":"Walk-in","em":null,"ep":null},
      {"n":"","m":"","p":"","en":"Walk-in","em":null,"ep":null},
      {"n":"   ","m":"  ","p":"  ","en":"Walk-in","em":null,"ep":null},
      {"n":null,"m":" Only.Email@Example.COM ","p":null,"en":"Walk-in","em":"only.email@example.com","ep":null},
      {"n":null,"m":null,"p":" 082 123 4567 ","en":"Walk-in","em":null,"ep":"082 123 4567"},
      {"n":"  Thandi Mokoena  ","m":"THANDI@Example.com","p":"+27 82 123 4567","en":"Thandi Mokoena","em":"thandi@example.com","ep":"+27 82 123 4567"}
    ]'::jsonb) e loop
    v_result := public._cg01m_call(u_member, 'cg01m-' || v_suffix || '-cust-' || md5(v_case::text), 'scan', '{"units":1}', v_case ->> 'n', v_case ->> 'm', v_case ->> 'p');
    if v_result ->> 'customerName' is distinct from v_case ->> 'en' or v_result ->> 'customerEmail' is distinct from v_case ->> 'em' or v_result ->> 'customerPhone' is distinct from v_case ->> 'ep' then
      raise exception 'CAFE_GUEST_01M: customer details % were normalized to %', v_case, v_result;
    end if;
    select * into v_order from commerce.service_orders where id = (v_result ->> 'orderId')::uuid;
    if v_order.customer_name is distinct from v_case ->> 'en' or v_order.customer_email is distinct from v_case ->> 'em' or v_order.customer_phone is distinct from v_case ->> 'ep' then
      raise exception 'CAFE_GUEST_01M: customer details %s must persist as normalized, got % % %', v_case, v_order.customer_name, v_order.customer_email, v_order.customer_phone;
    end if;
  end loop;
  -- no client or account was linked or created
  if exists (select 1 from public.users u where u.user_email in ('thandi@example.com', 'only.email@example.com')) or exists (select 1 from auth.users u where u.email in ('thandi@example.com', 'only.email@example.com')) then
    raise exception 'CAFE_GUEST_01M: no user or customer account may be created';
  end if;

  -- ── real pricing through the server path, derived not hard-coded ──
  for v_case in select e from jsonb_array_elements('[
      {"p":"scan","c":{"units":4}},
      {"p":"scan","c":{"units":300}},
      {"p":"a4-lamination","c":{"units":3}},
      {"p":"a4-lamination","c":{"units":100}},
      {"p":"a3-lamination","c":{"units":7}},
      {"p":"a4-print","c":{"pages":12,"copies":3,"printMode":"bw","sides":"single","finish":"none","documentInstructions":[{"selection":"all","sourcePages":12}],"documentPlanValid":true}},
      {"p":"a4-print","c":{"pages":5,"copies":1,"printMode":"colour","sides":"double","finish":"staple","documentInstructions":[{"selection":"all","sourcePages":5}],"documentPlanValid":true}},
      {"p":"business-cards","c":{"quantity":"100","stock":"standard","finish":"standard","artwork":"ready"}},
      {"p":"pvc-banner","c":{"width":2,"height":1,"material":"standard","finishing":"hem-eyelets","artwork":"ready","turnaround":"standard"}}
    ]'::jsonb) e loop
    v_direct := commerce.qs_calculate_price(v_cafe, v_case ->> 'p', v_case -> 'c');
    v_result := public._cg01m_call(u_member, 'cg01m-' || v_suffix || '-price-' || md5(v_case::text), v_case ->> 'p', v_case -> 'c');
    select * into v_order from commerce.service_orders where id = (v_result ->> 'orderId')::uuid;
    select * into v_item from commerce.service_order_items where order_id = v_order.id;
    if (v_direct ->> 'total')::numeric <= 0 then raise exception 'CAFE_GUEST_01M_TEST_SETUP: % must price above zero', v_case; end if;
    if v_order.subtotal <> (v_direct ->> 'total')::numeric or v_item.line_total <> (v_direct ->> 'total')::numeric or v_item.pricing_snapshot is distinct from v_direct -> 'snapshot'
       or v_item.product_name <> v_direct ->> 'productName' or v_item.configuration is distinct from v_case -> 'c' or v_item.quantity <> 1 then
      raise exception 'CAFE_GUEST_01M: % must be written at the server price %: order % item %', v_case ->> 'p', v_direct ->> 'total', v_order.subtotal, to_jsonb(v_item);
    end if;
    if v_order.channel <> 'counter' or v_order.payment_status <> 'unpaid' then raise exception 'CAFE_GUEST_01M: % must be a counter / unpaid order', v_case ->> 'p'; end if;
  end loop;

  -- A4 physical counter print: no fake file, no file name, no file record, no quantity
  v_result := public._cg01m_call(u_member, 'cg01m-' || v_suffix || '-a4', 'a4-print',
    '{"pages":12,"copies":3,"printMode":"bw","sides":"single","finish":"none","documentInstructions":[{"selection":"all","sourcePages":12}],"documentPlanValid":true}');
  select * into v_item from commerce.service_order_items where order_id = (v_result ->> 'orderId')::uuid;
  if v_item.file_refs is distinct from '[]'::jsonb or v_item.configuration ? 'fileName' or v_item.configuration ? 'quantity'
     or exists (select 1 from commerce.service_order_files f where f.order_id = (v_result ->> 'orderId')::uuid) then
    raise exception 'CAFE_GUEST_01M: a physical A4 counter print needs no file, file name, file record or quantity';
  end if;
  -- the product's OWN quantity option (business cards) is a legitimate configuration, not an override of the line quantity
  v_result := public._cg01m_call(u_member, 'cg01m-' || v_suffix || '-bc', 'business-cards', '{"quantity":"250","stock":"standard","finish":"standard","artwork":"ready"}');
  select * into v_item from commerce.service_order_items where order_id = (v_result ->> 'orderId')::uuid;
  if v_item.configuration ->> 'quantity' <> '250' or v_item.quantity <> 1 then raise exception 'CAFE_GUEST_01M: a product-defined quantity option must be accepted and the line quantity stay 1'; end if;

  -- a stored key with surrounding blanks is the same key
  v_before := public._cg01m_counts();
  v_result := public._cg01m_call(u_member, '  cg01m-' || v_suffix || '-w1  ', 'scan', '{"units":4}');
  if (v_result ->> 'replayed')::boolean is not true or public._cg01m_counts() is distinct from v_before then raise exception 'CAFE_GUEST_01M: a key with surrounding blanks must replay the original'; end if;
end
$writes$;

-- ═════════ safety, request-style products, idempotency, atomicity, payment ═════════
do $safety$
declare
  c_unavailable constant text := '22023 Product is not available for the counter.';
  v_suffix text := (select v from public._cg01m_ctx where k = 'suffix');
  v_cafe uuid := (select v::uuid from public._cg01m_ctx where k = 'cafe');
  u_member uuid := (select v::uuid from public._cg01m_ctx where k = 'u_member');
  u_member2 uuid := (select v::uuid from public._cg01m_ctx where k = 'u_member2');
  u_admin uuid := (select v::uuid from public._cg01m_ctx where k = 'u_admin');
  u_owner uuid := (select v::uuid from public._cg01m_ctx where k = 'u_owner');
  u_suspended uuid := (select v::uuid from public._cg01m_ctx where k = 'u_suspended');
  v_before text;
  v_got text;
  v_row jsonb;
  v_variants jsonb;
  v_product_id uuid;
  v_first jsonb; v_replay jsonb; v_second jsonb; v_other jsonb;
  v_order commerce.service_orders;
  v_ids text[];
  v_key text;
  v_public_before jsonb;
  v_admin_before jsonb;
begin
  v_before := public._cg01m_counts();

  -- ── the retired generic lamination, unknown and missing products ──
  if public._cg01m_try('authenticated', u_member, null, 'cg01m-' || v_suffix || '-s1', 'lamination', '{"units":2}') is distinct from c_unavailable then
    raise exception 'CAFE_GUEST_01M: the retired generic lamination must not be orderable';
  end if;
  foreach v_key in array array['no-such-product', '', '   '] loop
    if public._cg01m_try('authenticated', u_member, null, 'cg01m-' || v_suffix || '-s2', v_key, '{"units":2}') is distinct from '22023 Product was not found.' then
      raise exception 'CAFE_GUEST_01M: unknown product key "%" must be reported as not found', v_key;
    end if;
  end loop;
  if public._cg01m_try('authenticated', u_member, null, 'cg01m-' || v_suffix || '-s3', null, '{"units":2}') is distinct from '22023 Product was not found.' then
    raise exception 'CAFE_GUEST_01M: a NULL product key must be reported as not found';
  end if;
  -- a product key with blanks around it is the same product
  if public._cg01m_try('authenticated', u_member, null, 'cg01m-' || v_suffix || '-s4', '  scan  ', '{"units":2}') is distinct from 'ok' then
    raise exception 'CAFE_GUEST_01M: a padded product key must resolve to the product';
  end if;

  -- ── eligibility matrix: the write path decides exactly as the catalogue does ──
  v_variants := $variants$[
    {"key":"v-ok-both","cs":"published","ps":"published","av":"available","cd":{"channels":{"pos":true,"storefront":true},"active":true},"in":true},
    {"key":"v-ok-storefront-off","cs":"published","ps":"published","av":"available","cd":{"channels":{"pos":true,"storefront":false}},"in":true},
    {"key":"v-ok-active-null","cs":"published","ps":"published","av":"available","cd":{"channels":{"pos":true},"active":null},"in":true},
    {"key":"v-pos-false","cs":"published","ps":"published","av":"available","cd":{"channels":{"pos":false,"storefront":true}},"in":false},
    {"key":"v-pos-missing","cs":"published","ps":"published","av":"available","cd":{"channels":{"storefront":true}},"in":false},
    {"key":"v-channels-missing","cs":"published","ps":"published","av":"available","cd":{"name":"x"},"in":false},
    {"key":"v-pos-string-true","cs":"published","ps":"published","av":"available","cd":{"channels":{"pos":"true"}},"in":false},
    {"key":"v-pos-number","cs":"published","ps":"published","av":"available","cd":{"channels":{"pos":1}},"in":false},
    {"key":"v-pos-null","cs":"published","ps":"published","av":"available","cd":{"channels":{"pos":null}},"in":false},
    {"key":"v-pos-object","cs":"published","ps":"published","av":"available","cd":{"channels":{"pos":{}}},"in":false},
    {"key":"v-config-draft","cs":"draft","ps":"published","av":"available","cd":{"channels":{"pos":true}},"in":false},
    {"key":"v-config-archived","cs":"archived","ps":"published","av":"available","cd":{"channels":{"pos":true}},"in":false},
    {"key":"v-product-draft","cs":"published","ps":"draft","av":"available","cd":{"channels":{"pos":true}},"in":false},
    {"key":"v-product-archived","cs":"published","ps":"archived","av":"available","cd":{"channels":{"pos":true}},"in":false},
    {"key":"v-product-unavailable","cs":"published","ps":"published","av":"unavailable","cd":{"channels":{"pos":true}},"in":false},
    {"key":"v-active-false","cs":"published","ps":"published","av":"available","cd":{"channels":{"pos":true},"active":false},"in":false},
    {"key":"v-active-string-yes","cs":"published","ps":"published","av":"available","cd":{"channels":{"pos":true},"active":"yes"},"in":false}
  ]$variants$::jsonb;
  for v_row in select e from jsonb_array_elements(v_variants) e loop
    insert into commerce.products(tenant_id, slug, name, status, availability)
    values (v_cafe, v_row ->> 'key', 'CG01M ' || (v_row ->> 'key'), v_row ->> 'ps', v_row ->> 'av') returning id into v_product_id;
    insert into commerce.service_product_configs(tenant_id, product_id, source_key, pricing_version, customer_definition, pricing_definition, status, sort_order)
    values (v_cafe, v_product_id, v_row ->> 'key', 'cg01m-v1',
            (v_row -> 'cd') || '{"pricing":{"strategy":"PER_UNIT","unitPrice":2,"minUnits":1,"maxUnits":9},"fields":[]}'::jsonb,
            '{"strategy":"PER_UNIT","unitPrice":2,"minUnits":1,"maxUnits":9}', v_row ->> 'cs', 1000);
  end loop;
  v_ids := public._cg01m_catalog_ids(u_member);
  for v_row in select e from jsonb_array_elements(v_variants) e loop
    v_got := public._cg01m_try('authenticated', u_member, null, 'cg01m-' || v_suffix || '-v-' || (v_row ->> 'key'), v_row ->> 'key', '{"units":2}');
    if (v_row ->> 'in')::boolean then
      if v_got <> 'ok' then raise exception 'CAFE_GUEST_01M: % is counter-sellable and must be orderable, got "%"', v_row ->> 'key', v_got; end if;
    else
      if v_got <> c_unavailable then raise exception 'CAFE_GUEST_01M: % is not counter-sellable and must be refused, got "%"', v_row ->> 'key', v_got; end if;
    end if;
    if ((v_row ->> 'key') = any (v_ids)) is distinct from (v_row ->> 'in')::boolean then
      raise exception 'CAFE_GUEST_01M: the catalogue and the write path must decide % identically', v_row ->> 'key';
    end if;
  end loop;

  -- ── configuration and pricing failures: refused, nothing written ──
  v_before := public._cg01m_counts();
  foreach v_key in array array['[]', '"x"', '5', 'null'] loop
    if public._cg01m_try('authenticated', u_member, null, 'cg01m-' || v_suffix || '-c1', 'scan', v_key::jsonb) is distinct from '22023 Configuration must be a JSON object.' then
      raise exception 'CAFE_GUEST_01M: configuration % must be refused as not a JSON object', v_key;
    end if;
  end loop;
  if public._cg01m_try('authenticated', u_member, null, 'cg01m-' || v_suffix || '-c2', 'scan', null) is distinct from '22023 Configuration must be a JSON object.' then
    raise exception 'CAFE_GUEST_01M: a SQL NULL configuration must be refused';
  end if;
  for v_row in select e from jsonb_array_elements('[
      {"c":{},"m":"22023 Units are required."}, {"c":{"units":null},"m":"22023 Units are required."},
      {"c":{"units":0},"m":"22023 Units are outside the supported range."}, {"c":{"units":301},"m":"22023 Units are outside the supported range."},
      {"c":{"units":2.5},"m":"22023 Units must be a whole number."}, {"c":{"units":"abc"},"m":"22023 Units must be a whole number."},
      {"c":{"units":"007"},"m":"22023 Units must be a whole number."}, {"c":{"quantity":3},"m":"22023 Units are required."}
    ]'::jsonb) e loop
    if public._cg01m_try('authenticated', u_member, null, 'cg01m-' || v_suffix || '-c3', 'scan', v_row -> 'c') is distinct from v_row ->> 'm' then
      raise exception 'CAFE_GUEST_01M: scan configuration % must fail with %', v_row -> 'c', v_row ->> 'm';
    end if;
  end loop;
  -- no configuration.quantity override leaks in, for the strategies that do not define a quantity option
  for v_row in select e from jsonb_array_elements('[
      {"p":"scan","c":{"units":2,"quantity":9}}, {"p":"a4-lamination","c":{"units":2,"quantity":9}},
      {"p":"a4-print","c":{"pages":1,"copies":1,"printMode":"bw","sides":"single","finish":"none","documentInstructions":[{"selection":"all","sourcePages":1}],"quantity":9}},
      {"p":"pvc-banner","c":{"width":2,"height":1,"material":"standard","finishing":"hem-eyelets","artwork":"ready","turnaround":"standard","quantity":9}}
    ]'::jsonb) e loop
    if public._cg01m_try('authenticated', u_member, null, 'cg01m-' || v_suffix || '-q-' || (v_row ->> 'p'), v_row ->> 'p', v_row -> 'c') is distinct from '22023 Quantity is not an option for this product.' then
      raise exception 'CAFE_GUEST_01M: a configuration.quantity override must be refused for %', v_row ->> 'p';
    end if;
  end loop;
  -- request-style services have no counter creation path: refused, and no payable order exists
  for v_key in select unnest(array['media-services', 'photo-session']) loop
    v_got := public._cg01m_try('authenticated', u_member, null, 'cg01m-' || v_suffix || '-r-' || v_key, v_key,
      case v_key when 'media-services' then '{"mediumFocus":"balanced","shootType":"business-content","shootLocation":"cafe","crew":"recommend","duration":"not-sure","preferredDate":"","preferredTime":"","shootAddress":"","deliverables":""}'::jsonb
                 else '{"session":"30min-7edits","extraEdits":0,"preferredDate":"","preferredTime":""}'::jsonb end);
    if v_got not like '22023 % needs a quote before it can be ordered. Please use the request-a-quote flow.' then
      raise exception 'CAFE_GUEST_01M: request-style % must be refused with the quote-required error, got "%"', v_key, v_got;
    end if;
  end loop;
  -- (everything above except the 'ok' calls wrote nothing: only successful calls create orders)
  if (select count(*) from commerce.service_orders o where o.channel = 'counter' and not exists (select 1 from commerce.service_order_items i where i.order_id = o.id)) <> 0 then
    raise exception 'CAFE_GUEST_01M: no counter order may exist without its item';
  end if;
  if exists (select 1 from commerce.service_orders o where o.channel = 'counter' and (o.source_metadata ->> 'channel' is distinct from 'counter'
       or o.payment_status <> 'unpaid' or o.status <> 'submitted' or o.created_by is null)) then
    raise exception 'CAFE_GUEST_01M: every counter order is unpaid, submitted, attributed and channel-stamped';
  end if;

  -- ── idempotency ──
  v_before := public._cg01m_counts();
  v_key := 'cg01m-' || v_suffix || '-idem';
  v_first := public._cg01m_call(u_member, v_key, 'a4-lamination', '{"units":3}', 'Sipho', 'sipho@example.com', '0821234567');
  if (v_first ->> 'replayed')::boolean is not false then raise exception 'CAFE_GUEST_01M: the first call is not a replay'; end if;
  if (select count(*) from commerce.service_orders) <> split_part(v_before, '/', 1)::bigint + 1 then raise exception 'CAFE_GUEST_01M: the first call creates one order'; end if;
  v_before := public._cg01m_counts();

  -- exact retry (even with keys in another order): the ORIGINAL result, nothing new
  v_replay := public._cg01m_call(u_member, v_key, 'a4-lamination', '{ "units" : 3 }', 'Sipho', 'SIPHO@example.com', '0821234567');
  if (v_replay ->> 'replayed')::boolean is not true or v_replay ->> 'orderId' <> v_first ->> 'orderId' or v_replay ->> 'orderNumber' <> v_first ->> 'orderNumber'
     or v_replay ->> 'createdAt' <> v_first ->> 'createdAt' or v_replay - 'replayed' is distinct from v_first - 'replayed' then
    raise exception 'CAFE_GUEST_01M: an exact retry must return the original order unchanged: % vs %', v_first, v_replay;
  end if;
  if public._cg01m_counts() is distinct from v_before then raise exception 'CAFE_GUEST_01M: a retry must not increase any row count'; end if;

  -- changed input with the same key is a conflict, never the wrong order and never a second order
  foreach v_got in array array[
    public._cg01m_try('authenticated', u_member, null, v_key, 'a4-lamination', '{"units":4}', 'Sipho', 'sipho@example.com', '0821234567'),
    public._cg01m_try('authenticated', u_member, null, v_key, 'a3-lamination', '{"units":3}', 'Sipho', 'sipho@example.com', '0821234567'),
    public._cg01m_try('authenticated', u_member, null, v_key, 'a4-lamination', '{"units":3}', 'Other Name', 'sipho@example.com', '0821234567'),
    public._cg01m_try('authenticated', u_member, null, v_key, 'a4-lamination', '{"units":3}', 'Sipho', 'other@example.com', '0821234567'),
    public._cg01m_try('authenticated', u_member, null, v_key, 'a4-lamination', '{"units":3}', 'Sipho', 'sipho@example.com', '0829999999'),
    public._cg01m_try('authenticated', u_member, null, v_key, 'a4-lamination', '{"units":3}'),
    public._cg01m_try('authenticated', u_member, null, v_key, 'a4-lamination', '{"units":3,"note":"x"}', 'Sipho', 'sipho@example.com', '0821234567')
  ] loop
    if v_got is distinct from '23505 This idempotency key was already used for a different order request.' then
      raise exception 'CAFE_GUEST_01M: reusing a key with different input must be a conflict, got "%"', v_got;
    end if;
  end loop;
  if public._cg01m_counts() is distinct from v_before then raise exception 'CAFE_GUEST_01M: a conflicting reuse must write nothing'; end if;

  -- a different key creates a second order
  v_second := public._cg01m_call(u_member, v_key || '-2', 'a4-lamination', '{"units":3}', 'Sipho', 'sipho@example.com', '0821234567');
  if v_second ->> 'orderId' = v_first ->> 'orderId' or v_second ->> 'orderNumber' = v_first ->> 'orderNumber' or (v_second ->> 'replayed')::boolean is not false then
    raise exception 'CAFE_GUEST_01M: a different key must create a different order';
  end if;

  -- another actor using the SAME key and request gets their OWN order, and never sees or touches the first
  v_other := public._cg01m_call(u_member2, v_key, 'a4-lamination', '{"units":3}', 'Sipho', 'sipho@example.com', '0821234567');
  if v_other ->> 'orderId' = v_first ->> 'orderId' or (v_other ->> 'replayed')::boolean is not false then
    raise exception 'CAFE_GUEST_01M: another actor must never receive someone else''s order through a shared key';
  end if;
  select * into v_order from commerce.service_orders where id = (v_other ->> 'orderId')::uuid;
  if v_order.created_by is distinct from u_member2 then raise exception 'CAFE_GUEST_01M: the second actor''s order belongs to them'; end if;
  if (select created_by from commerce.service_orders where id = (v_first ->> 'orderId')::uuid) is distinct from u_member then raise exception 'CAFE_GUEST_01M: the first order is untouched'; end if;
  -- ... and different input from that other actor with the same key is a conflict only against THEIR order
  if public._cg01m_try('authenticated', u_member2, null, v_key, 'scan', '{"units":1}') is distinct from '23505 This idempotency key was already used for a different order request.' then
    raise exception 'CAFE_GUEST_01M: conflicts are evaluated within an actor''s own keys';
  end if;

  -- a storefront order that happens to carry a crafted key can never be returned or overwritten
  insert into commerce.service_orders(tenant_id, order_number, customer_name, idempotency_key, channel)
  values (v_cafe, 'CG01M-SF-' || left(v_suffix, 10), 'Storefront customer', 'counter:' || u_admin::text || ':cg01m-' || v_suffix || '-crafted', 'storefront');
  if public._cg01m_try('authenticated', u_admin, null, 'cg01m-' || v_suffix || '-crafted', 'scan', '{"units":1}') is distinct from '23505 This idempotency key was already used for a different order request.' then
    raise exception 'CAFE_GUEST_01M: a colliding storefront order must never be returned as a counter result';
  end if;
  -- the database backstop: the unique constraint refuses a second row for a stored key
  begin
    insert into commerce.service_orders(tenant_id, order_number, customer_name, idempotency_key, channel)
    values (v_cafe, 'CG01M-DUP-' || left(v_suffix, 10), 'dup', 'counter:' || u_member::text || ':' || v_key, 'counter');
    raise exception 'CAFE_GUEST_01M: the unique constraint must refuse a duplicate stored key';
  exception when unique_violation then null;
  end;

  -- a replay still returns the original even if the product has since been withdrawn (the sale already happened)
  update commerce.products set availability = 'unavailable' where tenant_id = v_cafe and slug = 'a4-lamination';
  v_replay := public._cg01m_call(u_member, v_key, 'a4-lamination', '{"units":3}', 'Sipho', 'sipho@example.com', '0821234567');
  if (v_replay ->> 'replayed')::boolean is not true or v_replay ->> 'orderId' <> v_first ->> 'orderId' then raise exception 'CAFE_GUEST_01M: a replay must return the original even after the product was withdrawn'; end if;
  if public._cg01m_try('authenticated', u_member, null, v_key || '-new', 'a4-lamination', '{"units":3}') is distinct from c_unavailable then raise exception 'CAFE_GUEST_01M: a NEW order for a withdrawn product must be refused'; end if;
  update commerce.products set availability = 'available' where tenant_id = v_cafe and slug = 'a4-lamination';
  -- but authorization is still checked first on a replay
  update public.tenant_memberships set status = 'suspended' where tenant_id = v_cafe and auth_user_id = u_member;
  if public._cg01m_try('authenticated', u_member, null, v_key, 'a4-lamination', '{"units":3}', 'Sipho', 'sipho@example.com', '0821234567') is distinct from '42501 You do not have access to the Quick Solution counter.' then
    raise exception 'CAFE_GUEST_01M: a suspended member must not replay';
  end if;
  update public.tenant_memberships set status = 'active' where tenant_id = v_cafe and auth_user_id = u_member;

  -- ── atomicity: a failure AFTER the order row is inserted leaves nothing behind ──
  v_before := public._cg01m_counts();
  execute $t$create function public._cg01m_fail_item() returns trigger language plpgsql as $f$ begin raise exception using errcode = 'P0001', message = 'CG01M forced item failure'; end $f$$t$;
  execute 'create trigger cg01m_fail_item before insert on commerce.service_order_items for each row execute function public._cg01m_fail_item()';
  v_got := public._cg01m_try('authenticated', u_member, null, 'cg01m-' || v_suffix || '-atomic', 'scan', '{"units":5}');
  execute 'drop trigger cg01m_fail_item on commerce.service_order_items';
  if v_got is distinct from 'P0001 CG01M forced item failure' then raise exception 'CAFE_GUEST_01M: the forced item failure must surface, got "%"', v_got; end if;
  if public._cg01m_counts() is distinct from v_before then raise exception 'CAFE_GUEST_01M: a failed item insert must leave no order behind (before %, after %)', v_before, public._cg01m_counts(); end if;
  if exists (select 1 from commerce.service_orders where idempotency_key = 'counter:' || u_member::text || ':cg01m-' || v_suffix || '-atomic') then raise exception 'CAFE_GUEST_01M: no orphan order'; end if;
  -- the same key works afterwards: nothing was half-recorded
  if public._cg01m_try('authenticated', u_member, null, 'cg01m-' || v_suffix || '-atomic', 'scan', '{"units":5}') is distinct from 'ok' then raise exception 'CAFE_GUEST_01M: the key must be reusable after a rolled-back failure'; end if;
  -- a pricing failure is also atomic (it happens before any write)
  v_before := public._cg01m_counts();
  if public._cg01m_try('authenticated', u_member, null, 'cg01m-' || v_suffix || '-atomic2', 'scan', '{"units":9999}') is distinct from '22023 Units are outside the supported range.' then raise exception 'CAFE_GUEST_01M: pricing failures surface with the server message'; end if;
  if public._cg01m_counts() is distinct from v_before then raise exception 'CAFE_GUEST_01M: a pricing failure must leave nothing behind'; end if;

  -- ── payment: unpaid, and nothing in any payment / token / file / handoff table ──
  if exists (select 1 from commerce.service_orders o where o.channel = 'counter' and o.payment_status <> 'unpaid') then raise exception 'CAFE_GUEST_01M: no counter order may be anything but unpaid'; end if;
  if (select count(*) from commerce.service_order_payments) <> 0 then raise exception 'CAFE_GUEST_01M: no payment row may be created'; end if;
  if (regexp_replace(public._cg01m_counts(), '^[0-9]+/[0-9]+', '')) ~ '=[1-9]' then
    raise exception 'CAFE_GUEST_01M: no payment, token, file, handoff or event row may be created: %', public._cg01m_counts();
  end if;
  foreach v_key in array array['paymentMethod', 'payment_method', 'paid', 'paymentStatus', 'reference', 'transactionId'] loop
    if exists (select 1 from pg_catalog.pg_proc p where p.oid = 'public.create_quick_solution_counter_order(text,text,jsonb,text,text,text)'::regprocedure and v_key = any (p.proargnames)) then
      raise exception 'CAFE_GUEST_01M: no payment argument may exist: %', v_key;
    end if;
  end loop;

  -- ── the 01A / 01C guards remain authoritative ──
  if not exists (select 1 from pg_catalog.pg_trigger t where t.tgrelid = 'commerce.service_order_items'::regclass and t.tgname = 'trg_qs_guard_service_order_item_channel' and not t.tgisinternal)
     or not exists (select 1 from pg_catalog.pg_trigger t where t.tgrelid = 'commerce.service_orders'::regclass and t.tgname = 'trg_qs_guard_service_order_origin' and not t.tgisinternal) then
    raise exception 'CAFE_GUEST_01M: the 01C guard triggers must still be in force';
  end if;
  begin
    insert into commerce.service_order_items(order_id, tenant_id, product_id, product_key, product_name)
    select o.id, o.tenant_id, p.id, p.slug, p.name
    from commerce.service_orders o, commerce.products p
    where o.id = (v_first ->> 'orderId')::uuid and p.tenant_id = v_cafe and p.slug = 'v-pos-false';
    raise exception 'CAFE_GUEST_01M: the item guard must still refuse a pos=false product on a counter order';
  exception when others then
    if sqlerrm not like 'PRODUCT_NOT_AVAILABLE_FOR_CHANNEL%' then raise; end if;
  end;
end
$safety$;

-- ═════════ regression: the neighbouring catalogues are unaffected ═════════
do $regression$
declare
  v_cafe uuid := (select v::uuid from public._cg01m_ctx where k = 'cafe');
  u_member uuid := (select v::uuid from public._cg01m_ctx where k = 'u_member');
  v_ids text[];
begin
  v_ids := public._cg01m_catalog_ids(u_member);
  if (select array_agg(x order by x) from unnest(v_ids) x where x not like 'v-%') is distinct from
     array['a3-lamination', 'a4-lamination', 'a4-print', 'business-cards', 'flags', 'gazebos', 'media-services', 'photo-session', 'printed-tshirt', 'pvc-banner', 'scan', 'vinyl-stickers'] then
    raise exception 'CAFE_GUEST_01M: the counter catalogue must still be the original nine plus Scan, A4 and A3 Lamination, got %', v_ids;
  end if;
  if 'lamination' = any (v_ids) then raise exception 'CAFE_GUEST_01M: the retired generic lamination stays out of the catalogue'; end if;
  if (select array_agg(p ->> 'id' order by p ->> 'id') from jsonb_array_elements(public.get_quick_solution_catalog('quick-solution') -> 'products') p where p ->> 'id' not like 'v-%') is distinct from
     array['a4-print', 'business-cards', 'flags', 'gazebos', 'media-services', 'photo-session', 'printed-tshirt', 'pvc-banner', 'vinyl-stickers'] then
    raise exception 'CAFE_GUEST_01M: the public storefront catalogue must be unchanged';
  end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', (select v from public._cg01m_ctx where k = 'u_appadmin'), 'role', 'authenticated', 'email', 'jointx.co@gmail.com')::text, true);
  if not exists (select 1 from jsonb_array_elements(public.admin_get_quick_solution_catalog('quick-solution') -> 'products') p where p ->> 'id' = 'scan' and p ? 'pricingDefinition') then
    raise exception 'CAFE_GUEST_01M: the admin catalogue is unchanged';
  end if;
  perform set_config('request.jwt.claims', '{}', true);
  -- capability semantics unchanged
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_member, 'role', 'authenticated')::text, true);
  if public.has_tenant_capability(v_cafe, 'cafe.counter.operate') is distinct from true or public.has_tenant_capability(v_cafe, 'cafe.operations.manage') is distinct from false then
    raise exception 'CAFE_GUEST_01M: the capability semantics must be unchanged (member: counter yes, manage no)';
  end if;
end
$regression$;

rollback;

select 'CAFE-GUEST-01M counter create order RPC contracts passed' as result;
