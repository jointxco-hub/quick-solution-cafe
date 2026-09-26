-- CAFE-GUEST-01C: contract test for the sales-channel availability guard.
--
-- Run only against an isolated database that has the real Quick Solution
-- effective schema (commerce.service_orders with the CAFE-GUEST-01A channel
-- column, commerce.service_order_items, commerce.service_product_configs,
-- commerce.products, public.tenants) after applying:
--   20260926100000_cafe_guest_01a_counter_channel_foundation.sql
--   20260926110000_cafe_guest_01c_channel_availability_guard.sql
-- Executed by the disposable local harness (supabase/tests/harness/run-local-sql-tests.ps1),
-- which replays the migration history onto the OPPS-owned base layer. The static
-- counterpart is tests/cafe-guest-01c-channel-guard.test.mjs.
--
-- All fixtures are synthetic and enclosed by BEGIN/ROLLBACK.

\set ON_ERROR_STOP on

begin;

-- Test-only helper (pg_temp, rolled back with the transaction): runs one
-- statement and requires the exact SQLSTATE and that the message contains the
-- expected stable token (the migration's own error token, or the constraint
-- name for a CHECK violation).
create function pg_temp.expect_error(
  p_sql text,
  p_case text,
  p_sqlstate text,
  p_token text
) returns void
language plpgsql
as $helper$
declare
  v_state text;
  v_message text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
    if v_state is distinct from p_sqlstate
       or position(p_token in coalesce(v_message,'')) = 0 then
      raise exception 'CAFE_GUEST_01C: % expected % containing "%" but got % "%"',
        p_case, p_sqlstate, p_token, v_state, v_message;
    end if;
    return;
  end;
  raise exception 'CAFE_GUEST_01C: % unexpectedly succeeded', p_case;
end
$helper$;

do $catalog$
declare
  v_helper regprocedure := to_regprocedure('commerce._qs_product_channel_enabled(uuid,text,text)');
  v_item_guard regprocedure := to_regprocedure('commerce.qs_guard_service_order_item_channel()');
  v_origin_guard regprocedure := to_regprocedure('commerce.qs_guard_service_order_origin()');
  v_oid regprocedure;
  v_definition text;
begin
  if v_helper is null or v_item_guard is null or v_origin_guard is null then
    raise exception 'helper and both guard functions must exist';
  end if;

  foreach v_oid in array array[v_helper, v_item_guard, v_origin_guard] loop
    if has_function_privilege('anon', v_oid, 'EXECUTE')
       or has_function_privilege('authenticated', v_oid, 'EXECUTE')
       or has_function_privilege('service_role', v_oid, 'EXECUTE') then
      raise exception '% must not be executable by any API role', v_oid;
    end if;
    if exists (
      select 1
      from pg_catalog.pg_proc p,
           lateral pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) acl
      where p.oid = v_oid and acl.grantee = 0 and acl.privilege_type = 'EXECUTE'
    ) then
      raise exception '% must not grant EXECUTE to PUBLIC', v_oid;
    end if;
    if not exists (
      select 1
      from pg_catalog.pg_proc p,
           lateral pg_catalog.pg_options_to_table(p.proconfig) config
      where p.oid = v_oid
        and config.option_name = 'search_path'
        and btrim(config.option_value, chr(34)) = ''
    ) then
      raise exception '% must use an empty hardened search_path', v_oid;
    end if;
  end loop;

  if not (select p.prosecdef from pg_catalog.pg_proc p where p.oid = v_helper)
     or not (select p.prosecdef from pg_catalog.pg_proc p where p.oid = v_item_guard) then
    raise exception 'helper and item guard must be SECURITY DEFINER (they read RLS-protected tables)';
  end if;
  if (select p.prosecdef from pg_catalog.pg_proc p where p.oid = v_origin_guard) then
    raise exception 'origin guard reads no table and must stay SECURITY INVOKER';
  end if;
  if (select p.provolatile from pg_catalog.pg_proc p where p.oid = v_helper) <> 's' then
    raise exception 'helper must be STABLE';
  end if;

  v_definition := lower(pg_catalog.pg_get_functiondef(v_helper));
  if v_definition ~ '(pricing_definition|supplier|margin|referenceprice)' then
    raise exception 'helper must read availability metadata only';
  end if;
  v_definition := lower(pg_catalog.pg_get_functiondef(v_item_guard));
  if v_definition like '%source_metadata%' then
    raise exception 'guard must enforce on service_orders.channel, never source_metadata';
  end if;

  if not exists (
    select 1 from pg_trigger t
    where t.tgrelid = 'commerce.service_order_items'::regclass
      and t.tgname = 'trg_qs_guard_service_order_item_channel'
      and not t.tgisinternal
      and (t.tgtype & 1) = 1      -- row level
      and (t.tgtype & 2) = 2      -- before
      and (t.tgtype & 4) = 4      -- insert
      and (t.tgtype & 16) = 16    -- update
      and (t.tgtype & 8) = 0      -- not delete
  ) then
    raise exception 'item guard must be a BEFORE INSERT OR UPDATE row trigger';
  end if;
  if not exists (
    select 1 from pg_trigger t
    where t.tgrelid = 'commerce.service_orders'::regclass
      and t.tgname = 'trg_qs_guard_service_order_origin'
      and not t.tgisinternal
      and (t.tgtype & 2) = 2
      and (t.tgtype & 16) = 16
      and (t.tgtype & 4) = 0
      and (t.tgtype & 8) = 0
  ) then
    raise exception 'origin guard must be a BEFORE UPDATE-only row trigger';
  end if;
end
$catalog$;

do $behavior$
declare
  v_suffix text := replace(gen_random_uuid()::text,'-','');
  v_tenant uuid := gen_random_uuid();
  v_other_tenant uuid := gen_random_uuid();
  v_order_storefront uuid := gen_random_uuid();
  v_order_counter uuid := gen_random_uuid();
  v_order_other uuid := gen_random_uuid();
  v_item_counter uuid;
  v_staff uuid := gen_random_uuid();
begin
  insert into public.tenants(id,slug,name,status,settings)
  values
    (v_tenant,'cg01c-a-'||left(v_suffix,12),'CAFE GUEST 01C tenant A','active','{}'::jsonb),
    (v_other_tenant,'cg01c-b-'||right(v_suffix,12),'CAFE GUEST 01C tenant B','active','{}'::jsonb);

  -- Synthetic products, one config each. Only tenant A defines them.
  create temporary table cg01c_products(slug text primary key, customer_definition jsonb not null) on commit drop;
  insert into cg01c_products(slug, customer_definition) values
    ('sf-true',          '{"channels":{"storefront":true,"pos":true}}'),
    ('sf-missing',       '{"channels":{"pos":false}}'),
    ('no-channels',      '{}'),
    ('sf-null',          '{"channels":{"storefront":null,"pos":false}}'),
    ('sf-false',         '{"channels":{"storefront":false,"pos":true}}'),
    ('sf-string-false',  '{"channels":{"storefront":"false","pos":false}}'),
    ('pos-only',         '{"channels":{"storefront":false,"pos":true}}'),
    ('pos-false',        '{"channels":{"storefront":true,"pos":false}}'),
    ('pos-missing',      '{"channels":{"storefront":true}}'),
    ('pos-string-true',  '{"channels":{"storefront":true,"pos":"true"}}');

  insert into commerce.products(tenant_id, slug, name)
  select v_tenant, p.slug, 'CAFE GUEST 01C '||p.slug from cg01c_products p;

  insert into commerce.service_product_configs(tenant_id, product_id, source_key, pricing_version, customer_definition)
  select v_tenant, pr.id, p.slug, 'cg01c-v1', p.customer_definition
  from cg01c_products p
  join commerce.products pr on pr.tenant_id = v_tenant and pr.slug = p.slug;

  -- ── helper truth table ──────────────────────────────────────────────
  if commerce._qs_product_channel_enabled(v_tenant,'sf-true','storefront') is distinct from true then
    raise exception 'storefront=true must be allowed on storefront';
  end if;
  if commerce._qs_product_channel_enabled(v_tenant,'sf-missing','storefront') is distinct from true then
    raise exception 'missing channels.storefront must default to TRUE (legacy compatible)';
  end if;
  if commerce._qs_product_channel_enabled(v_tenant,'no-channels','storefront') is distinct from true then
    raise exception 'missing channels object must default to storefront TRUE';
  end if;
  if commerce._qs_product_channel_enabled(v_tenant,'sf-null','storefront') is distinct from true then
    raise exception 'explicit null channels.storefront must behave as missing';
  end if;
  if commerce._qs_product_channel_enabled(v_tenant,'sf-false','storefront') is distinct from false then
    raise exception 'storefront=false must be denied on storefront';
  end if;
  if commerce._qs_product_channel_enabled(v_tenant,'sf-string-false','storefront') is distinct from false then
    raise exception 'a non-boolean storefront value must fail closed';
  end if;
  if commerce._qs_product_channel_enabled(v_tenant,'pos-only','counter') is distinct from true then
    raise exception 'pos=true must be allowed at the counter';
  end if;
  if commerce._qs_product_channel_enabled(v_tenant,'pos-false','counter') is distinct from false then
    raise exception 'pos=false must be denied at the counter';
  end if;
  if commerce._qs_product_channel_enabled(v_tenant,'pos-missing','counter') is distinct from false then
    raise exception 'missing channels.pos must be denied at the counter';
  end if;
  if commerce._qs_product_channel_enabled(v_tenant,'no-channels','counter') is distinct from false then
    raise exception 'a missing channels object must be denied at the counter';
  end if;
  if commerce._qs_product_channel_enabled(v_tenant,'pos-string-true','counter') is distinct from false then
    raise exception 'a non-boolean pos value must fail closed';
  end if;
  if commerce._qs_product_channel_enabled(v_tenant,'sf-true','kiosk') is distinct from false
     or commerce._qs_product_channel_enabled(v_tenant,'sf-true',null) is distinct from false then
    raise exception 'an unknown or NULL sales channel must fail closed';
  end if;
  if commerce._qs_product_channel_enabled(v_tenant,'no-such-product','storefront') is distinct from false
     or commerce._qs_product_channel_enabled(null,'sf-true','storefront') is distinct from false
     or commerce._qs_product_channel_enabled(v_tenant,null,'storefront') is distinct from false then
    raise exception 'a missing product config or NULL argument must fail closed';
  end if;
  if commerce._qs_product_channel_enabled(v_other_tenant,'sf-true','storefront') is distinct from false then
    raise exception 'availability must be resolved from the same tenant only';
  end if;

  -- ── orders: channel defaults, invalid channel rejected ─────────────
  insert into commerce.service_orders(id,tenant_id,order_number,customer_name,idempotency_key)
  values (v_order_storefront, v_tenant, 'CG01C-S-'||left(v_suffix,10), 'CAFE GUEST 01C storefront', 'cg01c-'||v_suffix||'-s');
  insert into commerce.service_orders(id,tenant_id,order_number,customer_name,idempotency_key,channel,created_by)
  values (v_order_counter, v_tenant, 'CG01C-C-'||left(v_suffix,10), 'Walk-in', 'cg01c-'||v_suffix||'-c', 'counter', v_staff);
  insert into commerce.service_orders(id,tenant_id,order_number,customer_name,idempotency_key)
  values (v_order_other, v_other_tenant, 'CG01C-O-'||left(v_suffix,10), 'CAFE GUEST 01C other tenant', 'cg01c-'||v_suffix||'-o');

  if (select channel from commerce.service_orders where id = v_order_storefront) is distinct from 'storefront' then
    raise exception 'omitted channel must still resolve to storefront';
  end if;

  perform pg_temp.expect_error(
    format('insert into commerce.service_orders(tenant_id,order_number,customer_name,idempotency_key,channel) values (%L,%L,%L,%L,%L)',
      v_tenant, 'CG01C-X-'||left(v_suffix,10), 'invalid channel', 'cg01c-'||v_suffix||'-x', 'kiosk'),
    'invalid channel', '23514', 'service_orders_channel_check');

  -- ── storefront order items ──────────────────────────────────────────
  -- Every product here is storefront-enabled (true, missing or null), so the
  -- guard must allow all of them, including ones that are not counter-enabled.
  insert into commerce.service_order_items(order_id,tenant_id,product_id,product_key,product_name)
  select v_order_storefront, v_tenant, pr.id, pr.slug, pr.name
  from commerce.products pr
  where pr.tenant_id = v_tenant
    and pr.slug in ('sf-true','sf-missing','no-channels','sf-null','pos-false','pos-missing','pos-string-true');

  perform pg_temp.expect_error(
    format('insert into commerce.service_order_items(order_id,tenant_id,product_id,product_key,product_name) select %L,%L,pr.id,pr.slug,pr.name from commerce.products pr where pr.tenant_id=%L and pr.slug=%L',
      v_order_storefront, v_tenant, v_tenant, 'sf-false'),
    'storefront order + storefront=false', '22023', 'PRODUCT_NOT_AVAILABLE_FOR_CHANNEL');
  perform pg_temp.expect_error(
    format('insert into commerce.service_order_items(order_id,tenant_id,product_id,product_key,product_name) select %L,%L,pr.id,pr.slug,pr.name from commerce.products pr where pr.tenant_id=%L and pr.slug=%L',
      v_order_storefront, v_tenant, v_tenant, 'pos-only'),
    'storefront order + counter-only product', '22023', 'PRODUCT_NOT_AVAILABLE_FOR_CHANNEL');

  -- ── counter order items ─────────────────────────────────────────────
  insert into commerce.service_order_items(order_id,tenant_id,product_id,product_key,product_name)
  select v_order_counter, v_tenant, pr.id, pr.slug, pr.name
  from commerce.products pr where pr.tenant_id = v_tenant and pr.slug = 'pos-only';
  insert into commerce.service_order_items(order_id,tenant_id,product_id,product_key,product_name)
  select v_order_counter, v_tenant, pr.id, pr.slug, pr.name
  from commerce.products pr where pr.tenant_id = v_tenant and pr.slug = 'sf-true';
  select i.id into v_item_counter from commerce.service_order_items i
  where i.order_id = v_order_counter and i.product_key = 'pos-only';

  perform pg_temp.expect_error(
    format('insert into commerce.service_order_items(order_id,tenant_id,product_id,product_key,product_name) select %L,%L,pr.id,pr.slug,pr.name from commerce.products pr where pr.tenant_id=%L and pr.slug=%L',
      v_order_counter, v_tenant, v_tenant, 'pos-false'),
    'counter order + pos=false', '22023', 'PRODUCT_NOT_AVAILABLE_FOR_CHANNEL');
  perform pg_temp.expect_error(
    format('insert into commerce.service_order_items(order_id,tenant_id,product_id,product_key,product_name) select %L,%L,pr.id,pr.slug,pr.name from commerce.products pr where pr.tenant_id=%L and pr.slug=%L',
      v_order_counter, v_tenant, v_tenant, 'pos-missing'),
    'counter order + pos missing', '22023', 'PRODUCT_NOT_AVAILABLE_FOR_CHANNEL');

  -- ── tenant integrity ────────────────────────────────────────────────
  perform pg_temp.expect_error(
    format('insert into commerce.service_order_items(order_id,tenant_id,product_id,product_key,product_name) select %L,%L,pr.id,pr.slug,pr.name from commerce.products pr where pr.tenant_id=%L and pr.slug=%L',
      v_order_storefront, v_other_tenant, v_tenant, 'sf-true'),
    'item tenant differs from parent order tenant', '23514', 'SERVICE_ORDER_ITEM_TENANT_MISMATCH');
  perform pg_temp.expect_error(
    format('insert into commerce.service_order_items(order_id,tenant_id,product_id,product_key,product_name) select %L,%L,pr.id,pr.slug,pr.name from commerce.products pr where pr.tenant_id=%L and pr.slug=%L',
      v_order_other, v_other_tenant, v_tenant, 'sf-true'),
    'other-tenant order cannot borrow tenant A product availability', '22023', 'PRODUCT_NOT_AVAILABLE_FOR_CHANNEL');

  -- ── channel and tenant are fixed after creation ─────────────────────
  perform pg_temp.expect_error(
    format('update commerce.service_orders set channel = %L where id = %L', 'counter', v_order_storefront),
    'storefront -> counter', '23514', 'SERVICE_ORDER_CHANNEL_IMMUTABLE');
  perform pg_temp.expect_error(
    format('update commerce.service_orders set channel = %L where id = %L', 'storefront', v_order_counter),
    'counter -> storefront', '23514', 'SERVICE_ORDER_CHANNEL_IMMUTABLE');
  perform pg_temp.expect_error(
    format('update commerce.service_orders set tenant_id = %L where id = %L', v_other_tenant, v_order_storefront),
    'order tenant change', '23514', 'SERVICE_ORDER_TENANT_IMMUTABLE');
  -- Re-assigning the same value is a no-op and allowed.
  update commerce.service_orders set channel = channel, tenant_id = tenant_id where id = v_order_storefront;

  -- ── item mutation cannot bypass the guard ───────────────────────────
  perform pg_temp.expect_error(
    format('update commerce.service_order_items set product_key = %L where order_id = %L and product_key = %L', 'sf-false', v_order_storefront, 'sf-true'),
    'product_key -> storefront=false product on a storefront order', '22023', 'PRODUCT_NOT_AVAILABLE_FOR_CHANNEL');
  perform pg_temp.expect_error(
    format('update commerce.service_order_items set order_id = %L where id = %L', v_order_storefront, v_item_counter),
    'counter-only item moved to a storefront order', '22023', 'PRODUCT_NOT_AVAILABLE_FOR_CHANNEL');
  perform pg_temp.expect_error(
    format('update commerce.service_order_items set order_id = %L where order_id = %L and product_key = %L', v_order_counter, v_order_storefront, 'pos-false'),
    'pos=false item moved to a counter order', '22023', 'PRODUCT_NOT_AVAILABLE_FOR_CHANNEL');
  perform pg_temp.expect_error(
    format('update commerce.service_order_items set tenant_id = %L where id = %L', v_other_tenant, v_item_counter),
    'item tenant change', '23514', 'SERVICE_ORDER_ITEM_TENANT_MISMATCH');

  -- ── unrelated updates remain allowed ────────────────────────────────
  update commerce.service_orders
  set status = 'accepted', payment_status = 'paid',
      upload_token_hash = 'x', upload_token_expires_at = now(),
      payment_token_hash = 'y', payment_token_expires_at = now(),
      source_metadata = coalesce(source_metadata,'{}'::jsonb) || '{"note":"cg01c"}'::jsonb
  where id in (v_order_storefront, v_order_counter);
  update commerce.service_order_items
  set file_refs = coalesce(file_refs,'[]'::jsonb) || '[{"synthetic":true}]'::jsonb,
      quantity = 2, line_total = 5
  where order_id in (v_order_storefront, v_order_counter);
end
$behavior$;

rollback;

select 'CAFE-GUEST-01C channel availability guard contracts passed' as result;
