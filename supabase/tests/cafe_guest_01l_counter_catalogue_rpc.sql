-- CAFE-GUEST-01L: behavioral contract test for public.get_quick_solution_counter_catalog().
--
-- Run only against the disposable local harness (supabase/tests/harness/), which replays the
-- migration history INCLUDING the OPPS-owned access layer (public.has_tenant_capability,
-- CAFE-ACCESS-01..03) and this migration:
--   20260926210000_cafe_guest_01l_counter_catalogue_rpc.sql
-- The harness skips this test, visibly, when the OPPS access layer is absent.
--
-- The catalogue checks read the REAL seeded products; eligibility variants are synthetic
-- products inserted inside this BEGIN/ROLLBACK. Every call runs under a real API role
-- (SET LOCAL ROLE authenticated / anon / service_role) with identity supplied only through
-- JWT claims, so grants and server-side authorization are exercised, not just inspected.

\set ON_ERROR_STOP on

begin;

-- Test-only helpers, created in public inside this transaction and rolled back with it (a
-- pg_temp function cannot be called after switching to an API role).
create function public._cg01l_try(p_sub uuid, p_email text) returns text
language plpgsql
as $$
declare
  v_state text;
  v_message text;
begin
  perform set_config('request.jwt.claims',
    case when p_sub is null then '{}'
         else jsonb_strip_nulls(jsonb_build_object('sub', p_sub, 'role', 'authenticated', 'email', p_email))::text end, true);
  perform public.get_quick_solution_counter_catalog();
  return 'ok';
exception when others then
  get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
  return v_state || ' ' || v_message;
end
$$;

create function public._cg01l_call(p_sub uuid) returns jsonb
language plpgsql
as $$
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  return public.get_quick_solution_counter_catalog();
end
$$;

grant execute on function public._cg01l_try(uuid, text), public._cg01l_call(uuid) to anon, authenticated, service_role;

-- ═════════ contracts: shape, posture, ACL, and what the body may touch ═════════
do $contracts$
declare
  v_rpc regprocedure := to_regprocedure('public.get_quick_solution_counter_catalog()');
  v_definition text;
begin
  if v_rpc is null then raise exception 'get_quick_solution_counter_catalog() must exist, with no arguments'; end if;
  if (select p.pronargs from pg_catalog.pg_proc p where p.oid = v_rpc) <> 0 then
    raise exception 'the RPC must take NO arguments: the caller cannot name or switch the tenant';
  end if;
  if pg_catalog.pg_get_function_result(v_rpc) <> 'jsonb' then raise exception 'it must return jsonb'; end if;
  if not (select p.prosecdef from pg_catalog.pg_proc p where p.oid = v_rpc) then raise exception 'it must be SECURITY DEFINER'; end if;
  if (select p.provolatile from pg_catalog.pg_proc p where p.oid = v_rpc) <> 's' then raise exception 'it must be STABLE: it writes nothing'; end if;
  if not exists (
    select 1 from pg_catalog.pg_proc p, lateral pg_catalog.pg_options_to_table(p.proconfig) c
    where p.oid = v_rpc and c.option_name = 'search_path' and btrim(c.option_value, chr(34)) = ''
  ) then raise exception 'it must use an empty hardened search_path'; end if;

  if exists (
    select 1 from pg_catalog.pg_proc p, lateral pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) acl
    where p.oid = v_rpc and acl.grantee = 0 and acl.privilege_type = 'EXECUTE'
  ) then raise exception 'it must not grant EXECUTE to PUBLIC'; end if;
  if has_function_privilege('anon', v_rpc, 'EXECUTE') then raise exception 'anon must not execute it'; end if;
  if has_function_privilege('service_role', v_rpc, 'EXECUTE') then raise exception 'service_role must not execute it directly'; end if;
  if not has_function_privilege('authenticated', v_rpc, 'EXECUTE') then raise exception 'authenticated must execute it'; end if;

  v_definition := lower(pg_catalog.pg_get_functiondef(v_rpc));
  if v_definition !~ 'has_tenant_capability\(v_tenant_id, ''cafe\.counter\.operate''\)' then
    raise exception 'it must require has_tenant_capability(tenant, cafe.counter.operate)';
  end if;
  if v_definition like '%cafe.operations.manage%' or v_definition ~ '(is_app_admin|is_opps_staff|can_access_tenant)' then
    raise exception 'it must use only the counter capability: no manage capability, no app-admin or OPPS-staff bypass';
  end if;
  if v_definition !~ 'quick_solution' then raise exception 'it must require the quick_solution module'; end if;
  if v_definition !~ 't\.slug = ''quick-solution''' then raise exception 'it must resolve the canonical Cafe slug server-side'; end if;
  -- It never reads the staff-only pricing definition or any private column.
  if v_definition ~ '(c|p)\.pricing_definition' or v_definition ~ '(suppliercost|referenceprice|marginrate|vatrate|sourceurl)' then
    raise exception 'the body must never read pricing_definition or any private field';
  end if;
  -- Since CAFE-GUEST-01M the eligibility rule lives in ONE predicate shared with the counter-create
  -- RPC; the catalogue must ask it, and it must hold exactly the 01L rule.
  if v_definition !~ '_qs_product_counter_sellable\(c\.tenant_id, c\.source_key\)' then
    raise exception 'eligibility must come from the one shared predicate';
  end if;
  v_definition := lower(pg_catalog.pg_get_functiondef(to_regprocedure('commerce._qs_product_counter_sellable(uuid,text)')));
  if v_definition !~ '_qs_product_channel_enabled\(c\.tenant_id, c\.source_key, ''counter''\)'
     or v_definition !~ 'c\.status = ''published''' or v_definition !~ 'p\.status = ''published''' or v_definition !~ 'p\.availability = ''available'''
     or v_definition !~ 'jsonb_typeof\(c\.customer_definition -> ''active''\)' or v_definition ~ 'storefront' then
    raise exception 'the shared predicate must be exactly the counter eligibility rule';
  end if;
  if v_definition ~ 'storefront' then raise exception 'storefront state must not decide counter eligibility'; end if;
end
$contracts$;

-- ═════════ behavior ═════════
do $behavior$
declare
  c_signin constant text := '42501 Staff sign-in is required.';
  c_denied constant text := '42501 You do not have access to the Quick Solution counter.';
  c_no_tenant constant text := '22023 Quick Solution tenant was not found.';
  c_no_module constant text := '22023 Quick Solution counter is not active.';

  v_suffix text := replace(gen_random_uuid()::text, '-', '');
  v_cafe uuid;
  v_other uuid := gen_random_uuid();
  v_module_row public.tenant_capabilities;

  u_nomember uuid := gen_random_uuid();
  u_member uuid := gen_random_uuid();
  u_admin uuid := gen_random_uuid();
  u_owner uuid := gen_random_uuid();
  u_suspended uuid := gen_random_uuid();
  u_other_owner uuid := gen_random_uuid();
  u_app_admin uuid := gen_random_uuid();
  u_opps_staff uuid := gen_random_uuid();

  v_labels text[]; v_subs uuid[]; v_emails text[]; v_expect text[];
  i integer;
  v_got text;
  v_result jsonb;
  v_ids text[];
  v_expected_ids text[];
  v_item jsonb;
  v_public_before jsonb; v_public_after jsonb;
  v_admin_before jsonb; v_admin_after jsonb;
  v_counts_before text; v_counts_after text;
  v_row jsonb;
  v_product_id uuid;
  v_text text;
  v_state text;
  v_message text;
  v_variants jsonb;
begin
  select t.id into v_cafe from public.tenants t where t.slug = 'quick-solution' and t.status = 'active';
  if v_cafe is null then raise exception 'CAFE_GUEST_01L_TEST_SETUP: the quick-solution tenant must exist'; end if;

  -- a second, unrelated tenant WITH the module and a pos product: it must never be reachable
  insert into public.tenants(id, slug, name, status, settings) values (v_other, 'cg01l-other-' || left(v_suffix, 10), 'CG01L other cafe', 'active', '{}'::jsonb);
  insert into public.tenant_capabilities(tenant_id, capability_key, enabled) values (v_other, 'quick_solution', true);
  insert into commerce.products(tenant_id, slug, name, status, availability) values (v_other, 'other-tenant-product', 'Other tenant product', 'published', 'available') returning id into v_product_id;
  insert into commerce.service_product_configs(tenant_id, product_id, source_key, pricing_version, customer_definition, pricing_definition, status)
  values (v_other, v_product_id, 'other-tenant-product', 'v1', '{"name":"Other tenant product","channels":{"pos":true,"storefront":true},"pricing":{"strategy":"PER_UNIT","unitPrice":1,"minUnits":1,"maxUnits":5},"fields":[]}', '{"strategy":"PER_UNIT","unitPrice":1,"minUnits":1,"maxUnits":5}', 'published');

  insert into auth.users(id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  select u.id, 'authenticated', 'authenticated', 'cg01l-' || u.label || '-' || v_suffix || '@disposable.test', now(), '{}'::jsonb, '{}'::jsonb, now(), now()
  from (values (u_nomember, 'nomember'), (u_member, 'member'), (u_admin, 'admin'), (u_owner, 'owner'), (u_suspended, 'suspended'),
               (u_other_owner, 'otherowner'), (u_app_admin, 'appadmin'), (u_opps_staff, 'oppsstaff')) as u(id, label);

  -- SETUP-ONLY approved-owner claim (the real OPPS trigger allows a role='admin' users row only for
  -- an approved-owner JWT email); cleared immediately and asserted gone.
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_app_admin, 'role', 'authenticated', 'email', 'jointx.co@gmail.com')::text, true);
  insert into public.users(auth_user_id, user_email, full_name, role, is_active)
  values (u_app_admin, 'cg01l-appadmin-' || v_suffix || '@disposable.test', 'CG01L app admin', 'admin', true),
         (u_opps_staff, 'cg01l-oppsstaff-' || v_suffix || '@disposable.test', 'CG01L OPPS staff', 'user', true);
  perform set_config('request.jwt.claims', '{}', true);
  if lower(coalesce(auth.jwt() ->> 'email', '')) <> '' then raise exception 'CAFE_GUEST_01L_TEST_SETUP: the temporary approved-owner claim must be cleared'; end if;

  insert into public.tenant_memberships(tenant_id, auth_user_id, tenant_role, status)
  values (v_cafe, u_member, 'member', 'active'), (v_cafe, u_admin, 'admin', 'active'), (v_cafe, u_owner, 'owner', 'active'),
         (v_cafe, u_suspended, 'member', 'suspended'), (v_other, u_other_owner, 'owner', 'active');
  if exists (select 1 from public.tenant_memberships m where m.tenant_id = v_cafe and m.auth_user_id in (u_app_admin, u_opps_staff)) then
    raise exception 'CAFE_GUEST_01L_TEST_SETUP: the app-admin and OPPS-staff fixtures must have no Cafe membership';
  end if;

  -- snapshots to prove the RPC is read-only and the neighbouring catalogues are unchanged
  v_public_before := public.get_quick_solution_catalog('quick-solution');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_app_admin, 'role', 'authenticated', 'email', 'jointx.co@gmail.com')::text, true);
  v_admin_before := public.admin_get_quick_solution_catalog('quick-solution');
  perform set_config('request.jwt.claims', '{}', true);
  v_counts_before := (select (select count(*) from commerce.products) || '|' || (select count(*) from commerce.service_product_configs) || '|' || (select count(*) from commerce.service_orders) || '|' || (select count(*) from commerce.service_order_items));

  -- ── access: every persona, under the real authenticated role ──
  v_labels := array['anonymous (no identity)', 'authenticated non-member', 'active member', 'active admin', 'active owner', 'suspended member',
                    'owner of a FOREIGN tenant (which has the module and a pos product)', 'app admin with no Cafe membership',
                    'app admin with the approved-owner email and no Cafe membership', 'OPPS staff with no Cafe membership']::text[];
  v_subs := array[null, u_nomember, u_member, u_admin, u_owner, u_suspended, u_other_owner, u_app_admin, u_app_admin, u_opps_staff]::uuid[];
  v_emails := array[null, null, null, null, null, null, null, null, 'jointx.co@gmail.com', null]::text[];
  v_expect := array[c_signin, c_denied, 'ok', 'ok', 'ok', c_denied, c_denied, c_denied, c_denied, c_denied]::text[];
  execute 'set local role authenticated';
  for i in 1 .. array_length(v_labels, 1) loop
    v_got := public._cg01l_try(v_subs[i], v_emails[i]);
    if v_got is distinct from v_expect[i] then
      raise exception 'CAFE_GUEST_01L: access for "%" expected "%" but got "%"', v_labels[i], v_expect[i], v_got;
    end if;
  end loop;

  -- the API roles: anon and service_role cannot execute it at all
  execute 'reset role';
  foreach v_state in array array['anon', 'service_role'] loop
    execute format('set local role %I', v_state);
    v_got := public._cg01l_try(u_owner, null);
    if v_got not like '42501 permission denied for function get_quick_solution_counter_catalog%' then
      raise exception 'CAFE_GUEST_01L: the % role must be refused by the ACL, got "%"', v_state, v_got;
    end if;
    execute 'reset role';
  end loop;

  -- the caller cannot name a tenant: there is no argument to name one with
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_owner, 'role', 'authenticated')::text, true);
  begin
    execute 'select public.get_quick_solution_counter_catalog(''cg01l-other'')';
    raise exception 'CAFE_GUEST_01L: passing a tenant must be impossible';
  exception when undefined_function then null;
  end;
  begin
    execute format('select public.get_quick_solution_counter_catalog(%L::uuid)', v_other);
    raise exception 'CAFE_GUEST_01L: passing a tenant id must be impossible';
  exception when undefined_function then null;
  end;
  execute 'reset role';

  -- ── module and tenant state ──
  select * into v_module_row from public.tenant_capabilities tc where tc.tenant_id = v_cafe and tc.capability_key = 'quick_solution';
  if v_module_row.id is null or v_module_row.enabled is distinct from true then raise exception 'CAFE_GUEST_01L_TEST_SETUP: the seeded quick_solution module must be enabled'; end if;

  update public.tenant_capabilities set enabled = false where id = v_module_row.id;
  execute 'set local role authenticated';
  foreach v_state in array array[u_member::text, u_admin::text, u_owner::text] loop
    if public._cg01l_try(v_state::uuid, null) is distinct from c_no_module then
      raise exception 'CAFE_GUEST_01L: a disabled quick_solution module must deny an authorized actor with the stable module error';
    end if;
  end loop;
  -- authorization comes first: an unauthorized actor learns nothing about the module
  if public._cg01l_try(u_nomember, null) is distinct from c_denied or public._cg01l_try(u_app_admin, 'jointx.co@gmail.com') is distinct from c_denied then
    raise exception 'CAFE_GUEST_01L: an unauthorized actor must get the access error, never the module state';
  end if;
  execute 'reset role';
  delete from public.tenant_capabilities where id = v_module_row.id;
  execute 'set local role authenticated';
  if public._cg01l_try(u_owner, null) is distinct from c_no_module then raise exception 'CAFE_GUEST_01L: a MISSING quick_solution module row must deny'; end if;
  execute 'reset role';
  insert into public.tenant_capabilities(id, tenant_id, capability_key, enabled, config, created_at, updated_at)
  values (v_module_row.id, v_module_row.tenant_id, v_module_row.capability_key, true, v_module_row.config, v_module_row.created_at, v_module_row.updated_at);

  foreach v_state in array array['suspended', 'archived'] loop
    update public.tenants set status = v_state where id = v_cafe;
    execute 'set local role authenticated';
    foreach v_message in array array[u_member::text, u_owner::text] loop
      if public._cg01l_try(v_message::uuid, null) is distinct from c_no_tenant then
        raise exception 'CAFE_GUEST_01L: a % Cafe tenant must fail closed with the tenant-not-found error', v_state;
      end if;
    end loop;
    execute 'reset role';
  end loop;
  update public.tenants set status = 'active' where id = v_cafe;

  update public.tenant_memberships set status = 'suspended' where tenant_id = v_cafe and auth_user_id = u_admin;
  execute 'set local role authenticated';
  if public._cg01l_try(u_admin, null) is distinct from c_denied then raise exception 'CAFE_GUEST_01L: a just-suspended admin must be denied'; end if;
  execute 'reset role';
  update public.tenant_memberships set status = 'active' where tenant_id = v_cafe and auth_user_id = u_admin;

  -- ── the catalogue itself, as an active member ──
  execute 'set local role authenticated';
  v_result := public._cg01l_call(u_member);
  execute 'reset role';
  if (select array_agg(k order by k) from jsonb_object_keys(v_result) k) is distinct from array['products', 'tenant'] then
    raise exception 'CAFE_GUEST_01L: the payload must be exactly { tenant, products }, got %', (select array_agg(k) from jsonb_object_keys(v_result) k);
  end if;
  if v_result -> 'tenant' is distinct from jsonb_build_object('slug', 'quick-solution', 'name', (select t.name from public.tenants t where t.id = v_cafe)) then
    raise exception 'CAFE_GUEST_01L: the tenant block must be exactly slug and name (no tenant id): %', v_result -> 'tenant';
  end if;

  select array_agg(p ->> 'id' order by p ->> 'id') into v_ids from jsonb_array_elements(v_result -> 'products') p;
  v_expected_ids := array['a3-lamination', 'a4-lamination', 'a4-print', 'business-cards', 'flags', 'gazebos', 'media-services', 'photo-session', 'printed-tshirt', 'pvc-banner', 'scan', 'vinyl-stickers'];
  if v_ids is distinct from v_expected_ids then
    raise exception 'CAFE_GUEST_01L: the counter catalogue must be exactly the original nine plus Scan, A4 and A3 Lamination, got %', v_ids;
  end if;
  if 'lamination' = any (v_ids) then raise exception 'CAFE_GUEST_01L: the retired generic lamination must not appear'; end if;
  if 'other-tenant-product' = any (v_ids) then raise exception 'CAFE_GUEST_01L: another tenant''s product must never appear'; end if;

  -- ordering matches the public catalogue: sort_order, then name
  select array_agg(c.source_key order by c.sort_order, p.name) into v_expected_ids
  from commerce.service_product_configs c join commerce.products p on p.id = c.product_id
  where c.tenant_id = v_cafe and c.source_key = any (v_ids);
  if (select array_agg(p ->> 'id') from jsonb_array_elements(v_result -> 'products') p) is distinct from v_expected_ids then
    raise exception 'CAFE_GUEST_01L: products must be ordered by sort_order then name';
  end if;

  -- storefront-off, live, pos products ARE counter products (this is not the storefront filter)
  for v_item in select p from jsonb_array_elements(v_result -> 'products') p where p ->> 'id' in ('scan', 'a4-lamination', 'a3-lamination') loop
    if v_item -> 'channels' is distinct from '{"storefront":false,"guided":false,"pos":true,"quote":false,"advanced":false}'::jsonb then
      raise exception 'CAFE_GUEST_01L: % must keep its counter-only channels, got %', v_item ->> 'id', v_item -> 'channels';
    end if;
  end loop;
  if (select p -> 'pricing' from jsonb_array_elements(v_result -> 'products') p where p ->> 'id' = 'scan') is distinct from '{"strategy":"PER_UNIT","unitPrice":5,"minUnits":1,"maxUnits":300}'::jsonb
     or (select p -> 'pricing' ->> 'unitPrice' from jsonb_array_elements(v_result -> 'products') p where p ->> 'id' = 'a4-lamination') <> '15'
     or (select p -> 'pricing' ->> 'unitPrice' from jsonb_array_elements(v_result -> 'products') p where p ->> 'id' = 'a3-lamination') <> '30' then
    raise exception 'CAFE_GUEST_01L: the customer pricing mirror of Scan / A4 / A3 must be present and exact';
  end if;

  -- every product has what a counter needs to derive visibility, grouping, action, fields, pricing
  for v_item in select p from jsonb_array_elements(v_result -> 'products') p loop
    if v_item ->> 'id' is null or v_item ->> 'name' is null or v_item ->> 'category' is null or v_item ->> 'pricingVersion' is null
       or jsonb_typeof(v_item -> 'channels') <> 'object' or jsonb_typeof(v_item -> 'fields') <> 'array' or v_item -> 'pricing' ->> 'strategy' is null then
      raise exception 'CAFE_GUEST_01L: % lacks a field the counter needs: %', v_item ->> 'id', v_item;
    end if;
    if (v_item -> 'channels' ->> 'pos') <> 'true' or jsonb_typeof(v_item -> 'channels' -> 'pos') <> 'boolean' then
      raise exception 'CAFE_GUEST_01L: every returned product must have channels.pos = true (boolean): %', v_item ->> 'id';
    end if;
  end loop;

  -- ── privacy: nothing private or internal in the payload ──
  v_text := lower(v_result::text);
  foreach v_state in array array['pricing_definition', 'pricingdefinition', 'suppliercost', 'referenceprice', 'marginrate', 'vatrate', 'pricingmode',
                                 'fixedprice', 'sourceurl', 'sourcename', 'commerceproductid', 'tenant_id', 'tenant_role', 'auth_user'] loop
    if position(v_state in v_text) > 0 then
      raise exception 'CAFE_GUEST_01L: the payload must not contain "%"', v_state;
    end if;
  end loop;
  if exists (select 1 from jsonb_array_elements(v_result -> 'products') p where p ? 'pricingDefinition' or p ? 'commerceProductId' or p ? 'pricing_definition') then
    raise exception 'CAFE_GUEST_01L: no product may carry pricingDefinition / commerceProductId';
  end if;

  -- one product DTO: for the original nine it equals the public catalogue's product minus its internal commerce id
  for v_item in select p from jsonb_array_elements(v_public_before -> 'products') p where p ->> 'id' in
      ('pvc-banner', 'vinyl-stickers', 'a4-print', 'business-cards', 'printed-tshirt', 'media-services', 'flags', 'gazebos', 'photo-session') loop
    if (select p from jsonb_array_elements(v_result -> 'products') p where p ->> 'id' = v_item ->> 'id') is distinct from (v_item - 'commerceProductId') then
      raise exception 'CAFE_GUEST_01L: % must be the established customer-safe product shape, identical to the public catalogue apart from its commerce id', v_item ->> 'id';
    end if;
  end loop;

  -- ── read-only, and the neighbouring catalogues are unchanged ──
  v_counts_after := (select (select count(*) from commerce.products) || '|' || (select count(*) from commerce.service_product_configs) || '|' || (select count(*) from commerce.service_orders) || '|' || (select count(*) from commerce.service_order_items));
  if v_counts_after is distinct from v_counts_before then raise exception 'CAFE_GUEST_01L: the RPC must write nothing'; end if;
  v_public_after := public.get_quick_solution_catalog('quick-solution');
  if v_public_after is distinct from v_public_before then raise exception 'CAFE_GUEST_01L: the public storefront catalogue must be unchanged'; end if;
  if (select array_agg(p ->> 'id' order by p ->> 'id') from jsonb_array_elements(v_public_after -> 'products') p) is distinct from
     array['a4-print', 'business-cards', 'flags', 'gazebos', 'media-services', 'photo-session', 'printed-tshirt', 'pvc-banner', 'vinyl-stickers'] then
    raise exception 'CAFE_GUEST_01L: the public catalogue must still be exactly the nine storefront products';
  end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_app_admin, 'role', 'authenticated', 'email', 'jointx.co@gmail.com')::text, true);
  v_admin_after := public.admin_get_quick_solution_catalog('quick-solution');
  perform set_config('request.jwt.claims', '{}', true);
  if v_admin_after is distinct from v_admin_before then raise exception 'CAFE_GUEST_01L: the admin catalogue must be unchanged'; end if;
  if not exists (select 1 from jsonb_array_elements(v_admin_after -> 'products') p where p ->> 'id' = 'scan' and p ? 'pricingDefinition') then
    raise exception 'CAFE_GUEST_01L: the admin catalogue still carries staff pricing definitions (unchanged behaviour)';
  end if;
  -- counter capability semantics unchanged: a member holds counter, not manage
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_member, 'role', 'authenticated')::text, true);
  if public.has_tenant_capability(v_cafe, 'cafe.counter.operate') is distinct from true or public.has_tenant_capability(v_cafe, 'cafe.operations.manage') is distinct from false then
    raise exception 'CAFE_GUEST_01L: the capability semantics must be unchanged (member: counter yes, manage no)';
  end if;
  execute 'reset role';

  -- ── eligibility matrix: synthetic products, each decided by the server rule alone ──
  v_variants := $variants$[
    {"key":"v-ok-both","cs":"published","ps":"published","av":"available","cd":{"channels":{"pos":true,"storefront":true},"active":true},"in":true},
    {"key":"v-ok-storefront-off","cs":"published","ps":"published","av":"available","cd":{"channels":{"pos":true,"storefront":false}},"in":true},
    {"key":"v-ok-active-null","cs":"published","ps":"published","av":"available","cd":{"channels":{"pos":true},"active":null},"in":true},
    {"key":"v-pos-false","cs":"published","ps":"published","av":"available","cd":{"channels":{"pos":false,"storefront":true}},"in":false},
    {"key":"v-pos-missing","cs":"published","ps":"published","av":"available","cd":{"channels":{"storefront":true}},"in":false},
    {"key":"v-channels-missing","cs":"published","ps":"published","av":"available","cd":{"name":"x"},"in":false},
    {"key":"v-pos-string-true","cs":"published","ps":"published","av":"available","cd":{"channels":{"pos":"true"}},"in":false},
    {"key":"v-pos-string-false","cs":"published","ps":"published","av":"available","cd":{"channels":{"pos":"false"}},"in":false},
    {"key":"v-pos-number","cs":"published","ps":"published","av":"available","cd":{"channels":{"pos":1}},"in":false},
    {"key":"v-pos-null","cs":"published","ps":"published","av":"available","cd":{"channels":{"pos":null}},"in":false},
    {"key":"v-pos-object","cs":"published","ps":"published","av":"available","cd":{"channels":{"pos":{}}},"in":false},
    {"key":"v-pos-array","cs":"published","ps":"published","av":"available","cd":{"channels":{"pos":[]}},"in":false},
    {"key":"v-channels-string","cs":"published","ps":"published","av":"available","cd":{"channels":"pos"},"in":false},
    {"key":"v-config-draft","cs":"draft","ps":"published","av":"available","cd":{"channels":{"pos":true}},"in":false},
    {"key":"v-config-archived","cs":"archived","ps":"published","av":"available","cd":{"channels":{"pos":true}},"in":false},
    {"key":"v-product-draft","cs":"published","ps":"draft","av":"available","cd":{"channels":{"pos":true}},"in":false},
    {"key":"v-product-archived","cs":"published","ps":"archived","av":"available","cd":{"channels":{"pos":true}},"in":false},
    {"key":"v-product-unavailable","cs":"published","ps":"published","av":"unavailable","cd":{"channels":{"pos":true}},"in":false},
    {"key":"v-product-out-of-stock","cs":"published","ps":"published","av":"out_of_stock","cd":{"channels":{"pos":true}},"in":false},
    {"key":"v-product-preorder","cs":"published","ps":"published","av":"preorder","cd":{"channels":{"pos":true}},"in":false},
    {"key":"v-active-false","cs":"published","ps":"published","av":"available","cd":{"channels":{"pos":true},"active":false},"in":false},
    {"key":"v-active-string-yes","cs":"published","ps":"published","av":"available","cd":{"channels":{"pos":true},"active":"yes"},"in":false},
    {"key":"v-active-string-true","cs":"published","ps":"published","av":"available","cd":{"channels":{"pos":true},"active":"true"},"in":false},
    {"key":"v-stray-private-keys","cs":"published","ps":"published","av":"available","cd":{"channels":{"pos":true},"pricingDefinition":{"supplierCost":9},"commerceProductId":"leak","pricing_definition":{"x":1}},"in":true}
  ]$variants$::jsonb;
  for v_row in select e from jsonb_array_elements(v_variants) e loop
    insert into commerce.products(tenant_id, slug, name, status, availability)
    values (v_cafe, v_row ->> 'key', 'CG01L ' || (v_row ->> 'key'), v_row ->> 'ps', v_row ->> 'av') returning id into v_product_id;
    insert into commerce.service_product_configs(tenant_id, product_id, source_key, pricing_version, customer_definition, pricing_definition, status, sort_order)
    values (v_cafe, v_product_id, v_row ->> 'key', 'cg01l-v1', (v_row -> 'cd') || jsonb_build_object('pricing', jsonb_build_object('strategy', 'PER_UNIT', 'unitPrice', 1, 'minUnits', 1, 'maxUnits', 9), 'fields', '[]'::jsonb),
            '{"strategy":"PER_UNIT","unitPrice":1,"minUnits":1,"maxUnits":9,"supplierCost":9,"referencePrice":9,"marginRate":0.5,"sourceUrl":"https://example.test/private"}', v_row ->> 'cs', 1000);
  end loop;

  execute 'set local role authenticated';
  v_result := public._cg01l_call(u_owner);
  execute 'reset role';

  -- exactly the products the server rule allows, no more and no fewer
  select coalesce(array_agg(p ->> 'id' order by p ->> 'id'), array[]::text[]) into v_ids
  from jsonb_array_elements(v_result -> 'products') p where p ->> 'id' like 'v-%';
  select coalesce(array_agg(e ->> 'key' order by e ->> 'key'), array[]::text[]) into v_expected_ids
  from jsonb_array_elements(v_variants) e where (e ->> 'in')::boolean;
  if v_ids is distinct from v_expected_ids then
    raise exception 'CAFE_GUEST_01L: eligibility mismatch. included % but the rule allows %; wrongly included: %; wrongly excluded: %',
      v_ids, v_expected_ids,
      (select array_agg(x) from unnest(v_ids) x where x <> all (v_expected_ids)),
      (select array_agg(x) from unnest(v_expected_ids) x where x <> all (v_ids));
  end if;
  if v_expected_ids is distinct from array['v-ok-active-null', 'v-ok-both', 'v-ok-storefront-off', 'v-stray-private-keys'] then
    raise exception 'CAFE_GUEST_01L_TEST_SETUP: the variant table drifted from the documented rule: %', v_expected_ids;
  end if;
  -- a storefront=false product is included; the storefront (public) catalogue is decided differently
  if not exists (select 1 from jsonb_array_elements(v_result -> 'products') p where p ->> 'id' = 'v-ok-storefront-off') then
    raise exception 'CAFE_GUEST_01L: a live pos product with storefront=false must be included';
  end if;

  -- stray private keys inside a customer_definition are stripped, and private columns never leak
  select p into v_item from jsonb_array_elements(v_result -> 'products') p where p ->> 'id' = 'v-stray-private-keys';
  if v_item ? 'pricingDefinition' or v_item ? 'pricing_definition' or v_item ? 'commerceProductId' then
    raise exception 'CAFE_GUEST_01L: stray pricingDefinition / commerceProductId keys must be stripped: %', v_item;
  end if;
  v_text := lower(v_result::text);
  foreach v_state in array array['suppliercost', 'referenceprice', 'marginrate', 'example.test/private', 'leak', 'pricing_definition', 'pricingdefinition'] loop
    if position(v_state in v_text) > 0 then
      raise exception 'CAFE_GUEST_01L: private data reached the payload ("%") even though a synthetic pricing_definition and stray keys were seeded', v_state;
    end if;
  end loop;

  -- the same eligibility for every role that may call it, and never anything else for an unauthorized one
  execute 'set local role authenticated';
  foreach v_state in array array[u_member::text, u_admin::text] loop
    if (select array_agg(p ->> 'id' order by p ->> 'id') from jsonb_array_elements(public._cg01l_call(v_state::uuid) -> 'products') p where p ->> 'id' like 'v-%') is distinct from v_expected_ids then
      raise exception 'CAFE_GUEST_01L: member, admin and owner must all see the same catalogue';
    end if;
  end loop;
  if public._cg01l_try(u_nomember, null) is distinct from c_denied then raise exception 'CAFE_GUEST_01L: a non-member must still be denied after the catalogue changed'; end if;
  execute 'reset role';
end
$behavior$;

rollback;

select 'CAFE-GUEST-01L counter catalogue RPC contracts passed' as result;
