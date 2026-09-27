-- CAFE-GUEST-01C: server-side sales-channel availability guard.
--
-- customer_definition.channels.storefront / .pos are sales-channel
-- availability metadata. They are NOT authorization, NOT production or OPPS
-- handoff eligibility, and NOT a fulfilment mode. Until now nothing on the
-- server read them: the React app hid storefront=false products, but any
-- create RPC would still price and order a published product by key.
--
-- This migration enforces the rule at the data layer, keyed on the canonical
-- commerce.service_orders.channel added by CAFE-GUEST-01A (never on
-- source_metadata.channel), without replacing any create RPC:
--
--   storefront order  needs channels.storefront  missing or null -> allowed
--                                                 true            -> allowed
--                                                 false / other   -> rejected
--   counter order     needs channels.pos         true            -> allowed
--                                                 missing / false / other
--                                                                 -> rejected
--   unknown channel, NULL argument, or no product config -> rejected
--
-- Objects (all in schema commerce; none is browser-callable):
--   _qs_product_channel_enabled(tenant, product_key, channel)  pure helper
--   qs_guard_service_order_item_channel()   trigger on service_order_items
--   qs_guard_service_order_origin()         trigger on service_orders
--
-- Item guard: BEFORE INSERT, and BEFORE UPDATE OF order_id, tenant_id,
-- product_key (the only columns that can change the order/product/channel
-- relationship; no existing function updates them - the sole existing item
-- UPDATE appends to file_refs and never fires the guard). It resolves the
-- parent order, requires item and parent to share a tenant (the schema has
-- no composite foreign key, so this is not structural), reads the parent's
-- channel, and rejects a product that is unavailable for it.
--
-- Origin guard: BEFORE UPDATE OF channel, tenant_id on service_orders.
-- channel is order ORIGIN and tenant is order OWNER; no existing function
-- changes either (every existing UPDATE names only token, payment, status,
-- opps_order_id and source_metadata columns), so neither may change after
-- insert. Ordinary status/payment/token/handoff updates do not fire it.
--
-- Stable error contract (message prefix is the machine token):
--   PRODUCT_NOT_AVAILABLE_FOR_CHANNEL    22023
--   SERVICE_ORDER_ITEM_TENANT_MISMATCH   23514
--   SERVICE_ORDER_ITEM_ORDER_NOT_FOUND   23503
--   SERVICE_ORDER_CHANNEL_IMMUTABLE      23514
--   SERVICE_ORDER_TENANT_IMMUTABLE       23514
-- Messages never include pricing, cost, margin or admin metadata.
--
-- Privilege model: the helper and the item guard are SECURITY DEFINER with an
-- empty search_path because they read RLS-protected tables that the writing
-- role may not be able to read; the origin guard reads no table and stays
-- SECURITY INVOKER. Execute is revoked from every API role on all three; a
-- trigger function is invoked by the trigger, not called by users.
--
-- KNOWN GAPS THAT REMAIN (deliberately not fixed here):
--   * NO storefront=false product may be published until the public catalogue
--     server projection (get_quick_solution_catalog) is also filtered. After
--     this guard such a product cannot be ordered online, but it would still
--     appear in the public catalogue. Do not rely on the React UI.
--   * channels.pos is a blanket true on every current product. No counter
--     catalogue may be exposed until a deliberate product curation pass sets
--     it. No product data is changed here.
--
-- Additive only: no create RPC is replaced, no product is published,
-- unpublished or changed, and no counter product is introduced.

do $preflight$
begin
  if to_regclass('commerce.service_orders') is null
     or to_regclass('commerce.service_order_items') is null
     or to_regclass('commerce.service_product_configs') is null then
    raise exception
      'CAFE_GUEST_01C_MIGRATION_PRECONDITION: commerce service order and product config tables must exist';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_attribute a
    where a.attrelid = 'commerce.service_orders'::regclass
      and a.attname = 'channel'
      and not a.attisdropped
  ) then
    raise exception
      'CAFE_GUEST_01C_MIGRATION_PRECONDITION: commerce.service_orders.channel (CAFE-GUEST-01A) must exist';
  end if;
end
$preflight$;

create or replace function commerce._qs_product_channel_enabled(
  p_tenant_id uuid,
  p_product_key text,
  p_channel text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select
      case p_channel
        when 'storefront' then
          case coalesce(jsonb_typeof(c.customer_definition -> 'channels' -> 'storefront'), 'null')
            when 'null' then true
            when 'boolean' then (c.customer_definition -> 'channels' ->> 'storefront')::boolean
            else false
          end
        when 'counter' then
          case coalesce(jsonb_typeof(c.customer_definition -> 'channels' -> 'pos'), 'null')
            when 'boolean' then (c.customer_definition -> 'channels' ->> 'pos')::boolean
            else false
          end
        else false
      end
    from commerce.service_product_configs c
    where c.tenant_id = p_tenant_id
      and c.source_key = trim(p_product_key)
    limit 1
  ), false)
$$;

revoke all on function commerce._qs_product_channel_enabled(uuid, text, text)
  from public, anon, authenticated, service_role;

comment on function commerce._qs_product_channel_enabled(uuid, text, text) is
  'CAFE-GUEST-01C: whether a product may be sold through a sales channel (storefront or counter), read from service_product_configs.customer_definition.channels for the same tenant. storefront: missing/null -> true; counter: missing -> false; unknown channel or missing config -> false. Availability metadata only: not authorization, not production eligibility.';

create or replace function commerce.qs_guard_service_order_item_channel()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order_tenant uuid;
  v_order_channel text;
begin
  if tg_op = 'UPDATE'
     and new.order_id is not distinct from old.order_id
     and new.tenant_id is not distinct from old.tenant_id
     and new.product_key is not distinct from old.product_key then
    return new;
  end if;

  select so.tenant_id, so.channel
    into v_order_tenant, v_order_channel
  from commerce.service_orders so
  where so.id = new.order_id;

  if not found then
    raise exception using errcode = '23503',
      message = 'SERVICE_ORDER_ITEM_ORDER_NOT_FOUND: The order for this item does not exist.';
  end if;

  if v_order_tenant is distinct from new.tenant_id then
    raise exception using errcode = '23514',
      message = 'SERVICE_ORDER_ITEM_TENANT_MISMATCH: An order item must belong to the same tenant as its order.';
  end if;

  if not commerce._qs_product_channel_enabled(new.tenant_id, new.product_key, v_order_channel) then
    raise exception using errcode = '22023',
      message = 'PRODUCT_NOT_AVAILABLE_FOR_CHANNEL: This product is not available through this sales channel.';
  end if;

  return new;
end
$$;

revoke all on function commerce.qs_guard_service_order_item_channel()
  from public, anon, authenticated, service_role;

comment on function commerce.qs_guard_service_order_item_channel() is
  'CAFE-GUEST-01C: rejects an order item whose product is unavailable for the parent order channel (service_orders.channel) or whose tenant differs from its order. Integrity trigger, not an API.';

create or replace function commerce.qs_guard_service_order_origin()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.channel is distinct from old.channel then
    raise exception using errcode = '23514',
      message = 'SERVICE_ORDER_CHANNEL_IMMUTABLE: The sales channel of an order cannot be changed.';
  end if;

  if new.tenant_id is distinct from old.tenant_id then
    raise exception using errcode = '23514',
      message = 'SERVICE_ORDER_TENANT_IMMUTABLE: The tenant of an order cannot be changed.';
  end if;

  return new;
end
$$;

revoke all on function commerce.qs_guard_service_order_origin()
  from public, anon, authenticated, service_role;

comment on function commerce.qs_guard_service_order_origin() is
  'CAFE-GUEST-01C: order channel (origin) and tenant (owner) are fixed at creation. Integrity trigger, not an API.';

drop trigger if exists trg_qs_guard_service_order_item_channel on commerce.service_order_items;
create trigger trg_qs_guard_service_order_item_channel
before insert or update of order_id, tenant_id, product_key
on commerce.service_order_items
for each row execute function commerce.qs_guard_service_order_item_channel();

drop trigger if exists trg_qs_guard_service_order_origin on commerce.service_orders;
create trigger trg_qs_guard_service_order_origin
before update of channel, tenant_id
on commerce.service_orders
for each row execute function commerce.qs_guard_service_order_origin();
