-- Staging: preserve an auditable reason when an OPPS fulfillment ticket
-- duplicates an existing Café storefront order. No sale or payment mutation.
alter table public.cafe_opps_handoffs
  add column if not exists reconciliation_reason text,
  add column if not exists existing_service_order_id uuid references commerce.service_orders(id),
  add column if not exists reconciled_at timestamptz;
create index if not exists cafe_opps_handoffs_service_order_idx
  on public.cafe_opps_handoffs(existing_service_order_id)
  where existing_service_order_id is not null;
