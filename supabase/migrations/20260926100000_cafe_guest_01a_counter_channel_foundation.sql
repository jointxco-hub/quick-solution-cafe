-- CAFE-GUEST-01A: counter-channel data foundation for commerce.service_orders.
--
-- A Quick Job (counter / walk-in sale) is a commerce.service_orders row whose
-- channel is 'counter'. Storefront orders and Quick Jobs share one commercial
-- model; no parallel order tables are introduced.
--
-- Additive only. No create RPC, no payment change, no handoff change.
--
-- channel     canonical operational channel: 'storefront' or 'counter'.
--             Existing rows, and every existing create RPC (which never names
--             this column), resolve to 'storefront' through the column
--             default. It is NOT an authorization input and NOT a production
--             or OPPS-handoff eligibility signal. Handoff stays an explicit
--             staff action (preview, then send); eligibility will be decided
--             by its own mechanism, never by channel alone.
--
-- created_by  auth.uid() of the authenticated staff member who created a
--             counter job. NULL for storefront orders and existing rows.
--             Plain uuid with no foreign key, matching the existing staff
--             identity columns in this schema (service_order_handoffs
--             .last_previewed_by, fulfilment_point_external_links
--             .verified_by): the id is written only by a future SECURITY
--             DEFINER RPC from auth.uid(), and it stays meaningful for audit
--             after a staff auth user is removed.
--
-- source_metadata keeps its detailed, historical provenance (for example
-- channel = 'storefront_cart'). It is not rewritten. channel is the canonical
-- operational channel; source_metadata.channel is provenance/context only.
--
-- customer_name remains NOT NULL. A future anonymous counter RPC will
-- server-write 'Walk-in' when no name or contact is supplied.

do $preflight$
begin
  if to_regclass('commerce.service_orders') is null then
    raise exception
      'CAFE_GUEST_01A_MIGRATION_PRECONDITION: commerce.service_orders does not exist';
  end if;
end
$preflight$;

alter table commerce.service_orders
  add column if not exists channel text not null default 'storefront',
  add column if not exists created_by uuid;

alter table commerce.service_orders
  drop constraint if exists service_orders_channel_check;

alter table commerce.service_orders
  add constraint service_orders_channel_check
  check (channel in ('storefront','counter'));

comment on column commerce.service_orders.channel is
  'Canonical operational channel: storefront or counter. Not an authorization input and not a production/OPPS-handoff eligibility signal. Detailed provenance stays in source_metadata.';

comment on column commerce.service_orders.created_by is
  'auth.uid() of the staff member who created a counter job; NULL for storefront orders. Plain uuid, intentionally without a foreign key.';
