-- CAFE-GUEST-01X: behavioral contract test for the counter/walk-in exemption in
-- commerce.qs_build_opps_handoff_preview, and its effect on public.admin_send_quick_solution_order_to_opps.
--
-- Run only against the disposable local harness (supabase/tests/harness/), which replays the migration
-- history INCLUDING the OPPS-owned access layer and
--   20260927100000_cafe_guest_01x_counter_opps_handoff_guest_contact.sql
-- Counter orders are created through the REAL 01M RPC; the one storefront-channel fixture (there is no
-- storefront checkout RPC in this repo's migration history) is inserted directly, with a real product and a
-- real order item, so it is only ever the CONTACT rule under test, never NO_ORDER_ITEMS. Everything is
-- enclosed by BEGIN/ROLLBACK.

\set ON_ERROR_STOP on

begin;

-- ── test-only helpers ────────────────────────────────────────────────────
create function public._cg01x_setup(p_sub uuid, p_email text) returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claims',
    jsonb_strip_nulls(jsonb_build_object('sub', p_sub, 'role', 'authenticated', 'email', p_email))::text, true);
  execute 'set local role authenticated';
end
$$;

create function public._cg01x_create_counter(p_sub uuid, p_key text, p_email text, p_phone text) returns uuid
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform public._cg01x_setup(p_sub, null);
  v_result := public.create_quick_solution_counter_order(p_key, 'scan', '{"units":1}'::jsonb, null, p_email, p_phone);
  execute 'reset role';
  return (v_result ->> 'orderId')::uuid;
end
$$;

-- a storefront-channel order, direct insert (no storefront checkout RPC exists in this history), with a
-- real order item so only the contact rule is exercised
create function public._cg01x_mk_storefront(p_tenant uuid, p_email text, p_phone text) returns uuid
language plpgsql
as $$
declare
  v_id uuid := gen_random_uuid();
  v_product_id uuid;
  v_source_key text := 'a4-print';
begin
  select c.product_id into v_product_id
  from commerce.service_product_configs c
  where c.tenant_id = p_tenant and c.source_key = v_source_key;
  if v_product_id is null then raise exception 'CAFE_GUEST_01X_TEST_SETUP: the % product must exist for the fixture', v_source_key; end if;
  insert into commerce.service_orders(id, tenant_id, order_number, customer_name, customer_email, customer_phone, idempotency_key, channel, subtotal, total_amount, status, payment_status)
  values (v_id, p_tenant, 'CG01X-' || left(v_id::text, 8), 'Storefront customer', p_email, p_phone, 'CG01X-KEY-' || v_id::text, 'storefront', 10, 10, 'submitted', 'unpaid');
  insert into commerce.service_order_items(order_id, tenant_id, product_id, product_key, product_name, quantity, configuration, line_total)
  values (v_id, p_tenant, v_product_id, v_source_key, 'Storefront fixture item', 1, '{}'::jsonb, 10);
  return v_id;
end
$$;

create function public._cg01x_preview(p_order uuid) returns jsonb
language sql
as $$ select commerce.qs_build_opps_handoff_preview(p_order) $$;

create function public._cg01x_send(p_sub uuid, p_email text, p_order uuid) returns jsonb
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform public._cg01x_setup(p_sub, p_email);
  v_result := public.admin_send_quick_solution_order_to_opps(p_order);
  execute 'reset role';
  return v_result;
end
$$;

grant execute on function public._cg01x_setup(uuid, text), public._cg01x_create_counter(uuid, text, text, text),
  public._cg01x_mk_storefront(uuid, text, text), public._cg01x_preview(uuid), public._cg01x_send(uuid, text, uuid)
  to anon, authenticated, service_role;

-- ═════════ fixtures ═════════
create table public._cg01x_ctx (k text primary key, v text);

do $fixtures$
declare
  v_cafe uuid;
  u_staff uuid := gen_random_uuid();
  u_appadmin uuid := gen_random_uuid();
  v_suffix text := replace(gen_random_uuid()::text, '-', '');
begin
  select t.id into v_cafe from public.tenants t where t.slug = 'quick-solution' and t.status = 'active';
  if v_cafe is null then raise exception 'CAFE_GUEST_01X_TEST_SETUP: the quick-solution tenant must exist'; end if;
  insert into public._cg01x_ctx values ('cafe', v_cafe::text), ('u_staff', u_staff::text), ('u_appadmin', u_appadmin::text);

  insert into auth.users(id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values
    (u_staff, 'authenticated', 'authenticated', 'cg01x-staff-' || v_suffix || '@disposable.test', now(), '{}'::jsonb, '{}'::jsonb, now(), now()),
    (u_appadmin, 'authenticated', 'authenticated', 'cg01x-appadmin-' || v_suffix || '@disposable.test', now(), '{}'::jsonb, '{}'::jsonb, now(), now());

  -- u_appadmin is also given a real admin membership of the Cafe tenant: the security patch
  -- (20260927120000) removes admin_send_quick_solution_order_to_opps's is_app_admin() bypass, so
  -- from that migration onward a caller needs cafe.operations.manage, not merely app-admin status,
  -- to send an order. The approved-owner email is kept too so this fixture still proves is_app_admin
  -- plays no special role once has_tenant_capability is satisfied on its own merits.
  insert into public.tenant_memberships(tenant_id, auth_user_id, tenant_role, status)
  values (v_cafe, u_staff, 'member', 'active'),
         (v_cafe, u_appadmin, 'admin', 'active');
end
$fixtures$;

-- ═════════ 1. ordinary storefront order without contact remains blocked ═════
do $t1$
declare
  v_cafe uuid := (select v::uuid from public._cg01x_ctx where k = 'cafe');
  v_order uuid := public._cg01x_mk_storefront(v_cafe, null, null);
  v_preview jsonb := public._cg01x_preview(v_order);
begin
  if (v_preview ->> 'ready')::boolean is not false then
    raise exception 'CAFE_GUEST_01X: a storefront order with no contact must not be ready';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_preview -> 'blockers') b where b ->> 'code' = 'NO_CUSTOMER_CONTACT') then
    raise exception 'CAFE_GUEST_01X: a storefront order with no contact must still carry NO_CUSTOMER_CONTACT';
  end if;
  if exists (select 1 from jsonb_array_elements(v_preview -> 'warnings') w where w ->> 'code' = 'COUNTER_GUEST_NO_CONTACT') then
    raise exception 'CAFE_GUEST_01X: a storefront order must never receive the counter-guest warning';
  end if;
end
$t1$;

-- ═════════ 2. authentic counter guest order without phone/email can become ready ═
do $t2$
declare
  u_staff uuid := (select v::uuid from public._cg01x_ctx where k = 'u_staff');
  v_order uuid := public._cg01x_create_counter(u_staff, 'cg01x-guest-order-001', null, null);
  v_preview jsonb := public._cg01x_preview(v_order);
begin
  if (v_preview ->> 'ready')::boolean is not true then
    raise exception 'CAFE_GUEST_01X: a counter order with no contact must be ready: %', v_preview -> 'blockers';
  end if;
  if exists (select 1 from jsonb_array_elements(v_preview -> 'blockers') b where b ->> 'code' = 'NO_CUSTOMER_CONTACT') then
    raise exception 'CAFE_GUEST_01X: a counter order must never be blocked for missing contact';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_preview -> 'warnings') w where w ->> 'code' = 'COUNTER_GUEST_NO_CONTACT') then
    raise exception 'CAFE_GUEST_01X: a contactless counter order must carry the counter-guest warning';
  end if;
  if (v_preview -> 'proposedOppsOrder' ->> 'client_email') is not null or (v_preview -> 'proposedOppsOrder' ->> 'client_phone') is not null then
    raise exception 'CAFE_GUEST_01X: client_email/client_phone must be null, never fabricated, for a contactless counter order';
  end if;
  if (v_preview -> 'proposedOppsOrder' ->> 'client_name') <> 'Walk-in' then
    raise exception 'CAFE_GUEST_01X: client_name must be the real (if generic) Walk-in identity';
  end if;
  if ((v_preview -> 'proposedOppsOrder' -> 'source_metadata' -> 'quick_solution' ->> 'channel') <> 'counter')
     or ((v_preview -> 'proposedOppsOrder' -> 'source_metadata' -> 'quick_solution' -> 'guestContact')::boolean is not true) then
    raise exception 'CAFE_GUEST_01X: OPPS must receive an explicit channel/guestContact signal, not an inference';
  end if;
  insert into public._cg01x_ctx values ('order_guest', v_order::text);
end
$t2$;

-- ═════════ 3. counter order with real customer details continues to work ═══
do $t3$
declare
  u_staff uuid := (select v::uuid from public._cg01x_ctx where k = 'u_staff');
  v_order uuid := public._cg01x_create_counter(u_staff, 'cg01x-contact-order-001', 'walkin@example.test', null);
  v_preview jsonb := public._cg01x_preview(v_order);
begin
  if (v_preview ->> 'ready')::boolean is not true then
    raise exception 'CAFE_GUEST_01X: a counter order with real contact must still be ready: %', v_preview -> 'blockers';
  end if;
  if exists (select 1 from jsonb_array_elements(v_preview -> 'warnings') w where w ->> 'code' = 'COUNTER_GUEST_NO_CONTACT') then
    raise exception 'CAFE_GUEST_01X: a counter order that DOES have contact must not carry the no-contact warning';
  end if;
  if (v_preview -> 'proposedOppsOrder' ->> 'client_email') <> 'walkin@example.test' then
    raise exception 'CAFE_GUEST_01X: the real email must pass through unchanged';
  end if;
  if ((v_preview -> 'proposedOppsOrder' -> 'source_metadata' -> 'quick_solution' -> 'guestContact')::boolean is not false) then
    raise exception 'CAFE_GUEST_01X: guestContact must be false when contact details were actually given';
  end if;
end
$t3$;

-- ═════════ 4. OPPS receives the guest/walk-in order safely ═════════════════
do $t4$
declare
  u_appadmin uuid := (select v::uuid from public._cg01x_ctx where k = 'u_appadmin');
  v_order uuid := (select v::uuid from public._cg01x_ctx where k = 'order_guest');
  v_result jsonb;
  v_opps_id uuid;
  v_opps_row public.orders;
begin
  v_result := public._cg01x_send(u_appadmin, 'jointx.co@gmail.com', v_order);
  if (v_result ->> 'ok')::boolean is not true or v_result ->> 'handoffStatus' <> 'sent' then
    raise exception 'CAFE_GUEST_01X: sending a contactless counter order must succeed: %', v_result;
  end if;
  v_opps_id := (v_result ->> 'oppsOrderId')::uuid;
  select * into v_opps_row from public.orders o where o.id = v_opps_id;
  if v_opps_row.id is null then raise exception 'CAFE_GUEST_01X: the OPPS order must exist'; end if;
  if v_opps_row.client_email is not null or v_opps_row.client_phone is not null then
    raise exception 'CAFE_GUEST_01X: OPPS must never receive a fabricated email or phone for a guest order';
  end if;
  if v_opps_row.client_name <> 'Walk-in' then
    raise exception 'CAFE_GUEST_01X: OPPS must receive the real Walk-in identity';
  end if;
  if (v_opps_row.source_metadata -> 'quick_solution' ->> 'channel') <> 'counter'
     or ((v_opps_row.source_metadata -> 'quick_solution' -> 'guestContact')::boolean is not true) then
    raise exception 'CAFE_GUEST_01X: the OPPS row must carry the explicit channel/guestContact signal';
  end if;
  if v_opps_row.source <> 'quick_solution' then raise exception 'CAFE_GUEST_01X: source must stay quick_solution'; end if;
  insert into public._cg01x_ctx values ('opps_order_guest', v_opps_id::text);
end
$t4$;

-- ═════════ 5. re-sending/retrying cannot create duplicate OPPS orders ══════
do $t5$
declare
  u_appadmin uuid := (select v::uuid from public._cg01x_ctx where k = 'u_appadmin');
  v_order uuid := (select v::uuid from public._cg01x_ctx where k = 'order_guest');
  v_opps_id uuid := (select v::uuid from public._cg01x_ctx where k = 'opps_order_guest');
  v_before_count integer := (select count(*) from public.orders where source = 'quick_solution');
  v_result jsonb;
begin
  -- retry 1: same admin
  v_result := public._cg01x_send(u_appadmin, 'jointx.co@gmail.com', v_order);
  if (v_result ->> 'ok')::boolean is not true or (v_result ->> 'replayed')::boolean is not true or (v_result ->> 'oppsOrderId')::uuid <> v_opps_id then
    raise exception 'CAFE_GUEST_01X: a retry must replay the original OPPS order: %', v_result;
  end if;
  -- retry 2: preview again first (as the UI would before a second send), then send again
  perform public._cg01x_preview(v_order);
  v_result := public._cg01x_send(u_appadmin, 'jointx.co@gmail.com', v_order);
  if (v_result ->> 'oppsOrderId')::uuid <> v_opps_id then raise exception 'CAFE_GUEST_01X: a second retry must still return the same OPPS order'; end if;
  if (select count(*) from public.orders where source = 'quick_solution') <> v_before_count then
    raise exception 'CAFE_GUEST_01X: no duplicate OPPS order was created by retrying';
  end if;
  if (select count(*) from public.orders where id = v_opps_id) <> 1 then
    raise exception 'CAFE_GUEST_01X: exactly one OPPS order exists for the guest order';
  end if;
  if (select count(*) from commerce.service_order_handoffs where service_order_id = v_order) <> 1 then
    raise exception 'CAFE_GUEST_01X: exactly one handoff row exists; idempotency is preserved';
  end if;
end
$t5$;

rollback;
select 'CAFE-GUEST-01X counter/OPPS handoff guest-contact contracts passed' as result;
