-- CAFE-GUEST-01M: the single-item counter-create RPC.
--
--   public.create_quick_solution_counter_order(
--     p_idempotency_key text, p_product_key text, p_configuration jsonb,
--     p_customer_name text default null, p_customer_email text default null,
--     p_customer_phone text default null) returns jsonb
--
-- Creates exactly ONE commerce.service_orders row and exactly ONE
-- commerce.service_order_items row for a walk-in counter sale, atomically (one function =
-- one transaction: any failure leaves no order behind). Nothing else is written: no payment,
-- no payment method, no tracking or upload token, no file, no handoff.
--
-- The caller supplies ONLY the product, its configuration, an idempotency key and optional
-- customer details. The tenant, the channel ('counter') and the actor (created_by =
-- auth.uid()) are decided by the server; none can be passed in.
--
-- FLOW, all server-side, in this order (nothing depends on the front end or on the caller
-- having fetched the catalogue):
--   1. sign-in required                                 42501 'Staff sign-in is required.'
--   2. the canonical Cafe tenant ('quick-solution', active) 22023 'Quick Solution tenant was not found.'
--   3. has_tenant_capability(tenant, 'cafe.counter.operate') 42501 'You do not have access to the Quick Solution counter.'
--   4. the quick_solution module enabled                22023 'Quick Solution counter is not active.'
--      (1-4 are exactly the counter catalogue's gate, CAFE-GUEST-01L)
--   5. input: idempotency key 8..128 chars; customer details normalized
--   6. IDEMPOTENCY (see below): an exact retry returns the original result, changed input fails
--   7. the product must exist for the tenant                22023 'Product was not found.'
--   8. and be counter-sellable, re-checked HERE by the same predicate the catalogue uses
--      (commerce._qs_product_counter_sellable)         22023 'Product is not available for the counter.'
--   9. priced by the authoritative commerce.qs_calculate_price; nothing is computed here
--  10. a product whose pricing says "quote required", or a photography session, is refused
--      (same rule and wording as the storefront checkout) - request-style services have no
--      counter creation path yet
--  11. `quantity` is refused in the configuration of the strategies that do not use it
--  12. insert the order, then the item, and return a summary
--
-- ELIGIBILITY: one predicate, commerce._qs_product_counter_sellable(tenant, key), introduced
-- here and used by BOTH this RPC and the counter catalogue (whose definition is replaced below
-- with an identical result), so the two can never drift apart. It is exactly the 01L rule:
-- published config, published + available product, strict boolean channels.pos = true (the
-- 01C rule), customer_definition.active not explicitly off. Storefront state plays no part.
--
-- PAYMENT: the order is created 'unpaid' with status 'submitted' - the storefront checkout's
-- own initial values. This RPC accepts no payment method, no paid flag and no reference.
--
-- IDEMPOTENCY (database-enforced): the key is stored in the existing
-- unique (tenant_id, idempotency_key) column as 'counter:<auth.uid()>:<key>', so it is scoped to
-- the ACTOR and can never collide with, or be used to read, another actor's or a storefront
-- order. Same actor + same key:
--   * same product, configuration and customer -> the ORIGINAL order and item are returned
--     (replayed = true); nothing is written and no second order exists;
--   * anything different                       -> 23505 'This idempotency key was already used
--     for a different order request.' (never the wrong order);
-- A per-key advisory lock serializes concurrent identical retries, and the unique constraint is
-- the backstop.
--
-- CUSTOMER: optional. No details -> customer_name 'Walk-in', email and phone null. Details are
-- normalized as the storefront RPC does (trim; email lower-cased with an '@'; phone with >= 7
-- digits). A supplied name must be 2..160 characters. No account or client is linked or created.
--
-- FULFILMENT: 'cafe' with the active Cafe point when there is one; no fulfilment fee.
--
-- DEPENDENCY: public.has_tenant_capability (OPPS repo, CAFE-ACCESS-01..03) and the CAFE-GUEST
-- 01A/01C/01L migrations. The 01A/01C guards stay authoritative: the item trigger re-checks
-- channel eligibility and the order is created with channel 'counter'.

do $preflight$
begin
  if to_regprocedure('public.has_tenant_capability(uuid,text)') is null
     or to_regprocedure('commerce._qs_product_channel_enabled(uuid,text,text)') is null
     or to_regprocedure('public.get_quick_solution_counter_catalog()') is null
     or to_regprocedure('commerce.qs_calculate_price(uuid,text,jsonb)') is null
     or to_regprocedure('commerce.qs_generate_order_number()') is null then
    raise exception
      'CAFE_GUEST_01M_MIGRATION_PRECONDITION: has_tenant_capability (CAFE-ACCESS), the counter catalogue (01L), the 01C channel rule, qs_calculate_price and qs_generate_order_number must exist';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'commerce' and table_name = 'service_orders' and column_name in ('channel')
  ) or not exists (
    select 1 from information_schema.columns
    where table_schema = 'commerce' and table_name = 'service_orders' and column_name = 'created_by'
  ) then
    raise exception 'CAFE_GUEST_01M_MIGRATION_PRECONDITION: commerce.service_orders.channel and created_by (CAFE-GUEST-01A) must exist';
  end if;
end
$preflight$;

-- ── the one counter-eligibility predicate ─────────────────────────────────
create or replace function commerce._qs_product_counter_sellable(
  p_tenant_id uuid,
  p_product_key text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select true
    from commerce.service_product_configs c
    join commerce.products p
      on p.id = c.product_id
     and p.tenant_id = c.tenant_id
    where c.tenant_id = p_tenant_id
      and c.source_key = trim(p_product_key)
      and c.status = 'published'
      and p.status = 'published'
      and p.availability = 'available'
      and commerce._qs_product_channel_enabled(c.tenant_id, c.source_key, 'counter')
      and case coalesce(jsonb_typeof(c.customer_definition -> 'active'), 'null')
            when 'null' then true
            when 'boolean' then (c.customer_definition ->> 'active')::boolean
            else false
          end
    limit 1
  ), false)
$$;

revoke all on function commerce._qs_product_counter_sellable(uuid, text)
  from public, anon, authenticated, service_role;

comment on function commerce._qs_product_counter_sellable(uuid, text) is
  'CAFE-GUEST-01M: the single server-side rule for "may this product be sold at the counter": published config, published + available product, strict boolean channels.pos = true, customer_definition.active not explicitly off. Used by the counter catalogue and the counter-create RPC. Internal.';

-- ── the counter catalogue now asks that same predicate (result unchanged) ─────
create or replace function public.get_quick_solution_counter_catalog()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_tenant jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Staff sign-in is required.';
  end if;

  select t.id, jsonb_build_object('slug', t.slug, 'name', t.name)
  into v_tenant_id, v_tenant
  from public.tenants t
  where t.slug = 'quick-solution'
    and t.status = 'active'
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode = '22023', message = 'Quick Solution tenant was not found.';
  end if;

  if not public.has_tenant_capability(v_tenant_id, 'cafe.counter.operate') then
    raise exception using errcode = '42501', message = 'You do not have access to the Quick Solution counter.';
  end if;

  if not exists (
    select 1
    from public.tenant_capabilities tc
    where tc.tenant_id = v_tenant_id
      and tc.capability_key = 'quick_solution'
      and tc.enabled = true
  ) then
    raise exception using errcode = '22023', message = 'Quick Solution counter is not active.';
  end if;

  return jsonb_build_object(
    'tenant', v_tenant,
    'products', coalesce((
      select jsonb_agg(
        (c.customer_definition - 'pricingDefinition' - 'pricing_definition' - 'commerceProductId') ||
        jsonb_build_object(
          'id', c.source_key,
          'name', p.name,
          'description', coalesce(p.description, c.customer_definition ->> 'description'),
          'pricingVersion', c.pricing_version
        )
        order by c.sort_order, p.name
      )
      from commerce.service_product_configs c
      join commerce.products p
        on p.id = c.product_id
       and p.tenant_id = c.tenant_id
      where c.tenant_id = v_tenant_id
        and commerce._qs_product_counter_sellable(c.tenant_id, c.source_key)
    ), '[]'::jsonb)
  );
end
$$;

revoke all on function public.get_quick_solution_counter_catalog()
  from public, anon, authenticated, service_role;
grant execute on function public.get_quick_solution_counter_catalog()
  to authenticated;

-- ── the counter-create RPC ────────────────────────────────────────────────
create or replace function public.create_quick_solution_counter_order(
  p_idempotency_key text,
  p_product_key text,
  p_configuration jsonb,
  p_customer_name text default null,
  p_customer_email text default null,
  p_customer_phone text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_walk_in constant text := 'Walk-in';
  v_actor uuid;
  v_tenant_id uuid;
  v_key text;
  v_stored_key text;
  v_product_key text;
  v_name text;
  v_email text;
  v_phone text;
  v_existing commerce.service_orders;
  v_item commerce.service_order_items;
  v_price jsonb;
  v_strategy text;
  v_product_id uuid;
  v_product_name text;
  v_subtotal numeric;
  v_point_id uuid;
  v_order_id uuid;
  v_order_number text;
  v_created_at timestamptz;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception using errcode = '42501', message = 'Staff sign-in is required.';
  end if;

  select t.id
  into v_tenant_id
  from public.tenants t
  where t.slug = 'quick-solution'
    and t.status = 'active'
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode = '22023', message = 'Quick Solution tenant was not found.';
  end if;

  if not public.has_tenant_capability(v_tenant_id, 'cafe.counter.operate') then
    raise exception using errcode = '42501', message = 'You do not have access to the Quick Solution counter.';
  end if;

  if not exists (
    select 1
    from public.tenant_capabilities tc
    where tc.tenant_id = v_tenant_id
      and tc.capability_key = 'quick_solution'
      and tc.enabled = true
  ) then
    raise exception using errcode = '22023', message = 'Quick Solution counter is not active.';
  end if;

  -- input
  v_key := trim(coalesce(p_idempotency_key, ''));
  if length(v_key) < 8 then
    raise exception using errcode = '22023', message = 'Order idempotency key is required.';
  end if;
  if length(v_key) > 128 then
    raise exception using errcode = '22023', message = 'Order idempotency key is not valid.';
  end if;

  v_product_key := trim(coalesce(p_product_key, ''));
  v_name := nullif(trim(coalesce(p_customer_name, '')), '');
  v_email := nullif(lower(trim(coalesce(p_customer_email, ''))), '');
  v_phone := nullif(trim(coalesce(p_customer_phone, '')), '');

  if v_name is not null and (length(v_name) < 2 or length(v_name) > 160) then
    raise exception using errcode = '22023', message = 'Customer name is not valid.';
  end if;
  if v_email is not null and position('@' in v_email) < 2 then
    raise exception using errcode = '22023', message = 'Email address is not valid.';
  end if;
  if v_phone is not null and length(regexp_replace(v_phone, '[^0-9+]', '', 'g')) < 7 then
    raise exception using errcode = '22023', message = 'Phone number is not valid.';
  end if;
  v_name := coalesce(v_name, c_walk_in);

  -- idempotency: scoped to this actor, serialized per key, enforced by the unique constraint
  v_stored_key := 'counter:' || v_actor::text || ':' || v_key;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_tenant_id::text || '|' || v_stored_key, 0));

  select so.*
  into v_existing
  from commerce.service_orders so
  where so.tenant_id = v_tenant_id
    and so.idempotency_key = v_stored_key
  limit 1;

  if v_existing.id is not null then
    select i.*
    into v_item
    from commerce.service_order_items i
    where i.order_id = v_existing.id
    order by i.created_at, i.id
    limit 1;

    if v_existing.channel is distinct from 'counter'
       or v_existing.created_by is distinct from v_actor
       or v_item.id is null
       or v_item.product_key is distinct from v_product_key
       or v_item.configuration is distinct from p_configuration
       or v_existing.customer_name is distinct from v_name
       or v_existing.customer_email is distinct from v_email
       or v_existing.customer_phone is distinct from v_phone then
      raise exception using errcode = '23505', message = 'This idempotency key was already used for a different order request.';
    end if;

    return jsonb_build_object(
      'ok', true,
      'replayed', true,
      'orderId', v_existing.id,
      'orderNumber', v_existing.order_number,
      'status', v_existing.status,
      'paymentStatus', v_existing.payment_status,
      'channel', v_existing.channel,
      'createdAt', v_existing.created_at,
      'customerName', v_existing.customer_name,
      'customerEmail', v_existing.customer_email,
      'customerPhone', v_existing.customer_phone,
      'productKey', v_item.product_key,
      'productName', v_item.product_name,
      'configuration', v_item.configuration,
      'lineTotal', v_item.line_total,
      'subtotal', v_existing.subtotal,
      'fulfilmentFee', v_existing.fulfilment_fee,
      'totalAmount', v_existing.total_amount
    );
  end if;

  -- the product: it must exist, and be counter-sellable by the one shared rule
  if not exists (
    select 1
    from commerce.service_product_configs c
    where c.tenant_id = v_tenant_id
      and c.source_key = v_product_key
  ) then
    raise exception using errcode = '22023', message = 'Product was not found.';
  end if;

  if not commerce._qs_product_counter_sellable(v_tenant_id, v_product_key) then
    raise exception using errcode = '22023', message = 'Product is not available for the counter.';
  end if;

  -- the authoritative server price (validates the configuration too)
  v_price := commerce.qs_calculate_price(v_tenant_id, v_product_key, p_configuration);
  v_strategy := upper(coalesce(v_price -> 'snapshot' ->> 'pricingStrategy', ''));

  -- same protection as the storefront checkout: a quote-required item, or a photography
  -- session, is never a payable order. There is no counter path for request-style services yet.
  if coalesce((v_price -> 'metrics' ->> 'quoteRequired')::boolean, false)
     or v_strategy = 'PHOTOGRAPHY_SESSION' then
    raise exception using errcode = '22023',
      message = format('%s needs a quote before it can be ordered. Please use the request-a-quote flow.', coalesce(v_price ->> 'productName', v_product_key));
  end if;

  -- OPPS reads configuration.quantity as a quantity override: refuse it wherever the product
  -- does not itself define a quantity option.
  if p_configuration ? 'quantity' and v_strategy in ('PER_UNIT', 'PER_PAGE', 'PER_AREA') then
    raise exception using errcode = '22023', message = 'Quantity is not an option for this product.';
  end if;

  v_product_id := (v_price ->> 'productId')::uuid;
  v_product_name := v_price ->> 'productName';
  v_subtotal := (v_price ->> 'total')::numeric;

  select fp.id
  into v_point_id
  from commerce.fulfilment_points fp
  where fp.tenant_id = v_tenant_id
    and fp.kind = 'cafe'
    and fp.status = 'active'
    and fp.collection_enabled = true
  order by fp.sort_order, fp.created_at
  limit 1;

  v_order_number := commerce.qs_generate_order_number();

  insert into commerce.service_orders (
    tenant_id,
    order_number,
    status,
    customer_name,
    customer_email,
    customer_phone,
    fulfilment_type,
    fulfilment_point_id,
    subtotal,
    fulfilment_fee,
    total_amount,
    payment_status,
    idempotency_key,
    source_metadata,
    channel,
    created_by
  ) values (
    v_tenant_id,
    v_order_number,
    'submitted',
    v_name,
    v_email,
    v_phone,
    'cafe',
    v_point_id,
    v_subtotal,
    0,
    v_subtotal,
    'unpaid',
    v_stored_key,
    jsonb_build_object('channel', 'counter', 'deliveryFeeStatus', 'not_required'),
    'counter',
    v_actor
  )
  returning id, created_at into v_order_id, v_created_at;

  insert into commerce.service_order_items (
    order_id,
    tenant_id,
    product_id,
    product_key,
    product_name,
    quantity,
    configuration,
    pricing_snapshot,
    line_total
  ) values (
    v_order_id,
    v_tenant_id,
    v_product_id,
    v_product_key,
    v_product_name,
    1,
    p_configuration,
    v_price -> 'snapshot',
    v_subtotal
  );

  return jsonb_build_object(
    'ok', true,
    'replayed', false,
    'orderId', v_order_id,
    'orderNumber', v_order_number,
    'status', 'submitted',
    'paymentStatus', 'unpaid',
    'channel', 'counter',
    'createdAt', v_created_at,
    'customerName', v_name,
    'customerEmail', v_email,
    'customerPhone', v_phone,
    'productKey', v_product_key,
    'productName', v_product_name,
    'configuration', p_configuration,
    'lineTotal', v_subtotal,
    'subtotal', v_subtotal,
    'fulfilmentFee', 0,
    'totalAmount', v_subtotal
  );
end
$$;

-- Staff RPC, called by the browser as the signed-in user: authenticated only.
revoke all on function public.create_quick_solution_counter_order(text, text, jsonb, text, text, text)
  from public, anon, authenticated, service_role;
grant execute on function public.create_quick_solution_counter_order(text, text, jsonb, text, text, text)
  to authenticated;

comment on function public.create_quick_solution_counter_order(text, text, jsonb, text, text, text) is
  'CAFE-GUEST-01M: creates exactly one unpaid counter order with exactly one item, server-priced, for the signed-in Cafe staff member. The tenant, channel (counter) and created_by (auth.uid()) are server-decided; the idempotency key is required and actor-scoped. Requires cafe.counter.operate and the quick_solution module. No payment is accepted or recorded.';
