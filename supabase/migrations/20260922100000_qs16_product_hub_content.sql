-- QS-16: Visual Product Hub — optional customer-facing content for the
-- vinyl-stickers catalogue row.
--
-- Purely additive JSONB merge onto the EXISTING
-- commerce.service_product_configs.customer_definition row (no new
-- column, no new table, no schema change at all — customer_definition
-- is already `jsonb not null default '{}'::jsonb`). Adds two optional
-- keys, 'media' and 'productPage', with the exact same shape and content
-- as the local src/data/products.js fallback object added in this same
-- change — see that file's vinyl-stickers entry for the field-by-field
-- reasoning (every value here is derived from facts already present in
-- this row's own customer_definition/pricing_definition: the material,
-- finishing, artwork and turnaround field labels — no new durability,
-- thickness, waterproofing, adhesive-grade, turnaround-day, minimum-
-- quantity or price claims).
--
-- Every other key already on this row (id, name, pricing, fields, ...)
-- is left completely untouched by the `||` merge below. This migration
-- does not touch pricing_definition, does not change any price, and does
-- not touch any other product's row.
--
-- NOT APPLIED YET — written for review only, per instruction.

begin;

do $qs16_preflight$
begin
  if not exists (
    select 1
    from public.tenants t
    join commerce.service_product_configs c on c.tenant_id = t.id
    where t.slug = 'quick-solution'
      and c.source_key = 'vinyl-stickers'
  ) then
    raise exception 'QS16 prerequisite missing: quick-solution vinyl-stickers catalogue row (expected from QS-11)';
  end if;
end
$qs16_preflight$;

update commerce.service_product_configs c
set customer_definition = c.customer_definition || jsonb_build_object(
  'media', jsonb_build_object(
    'hero', '/qs11/product-vinyl-labels-clean.webp',
    'gallery', jsonb_build_array(
      '/qs11/product-vinyl-labels-clean.webp',
      '/qs11/product-vinyl.webp',
      '/qs11/product-labels-perfume.webp',
      '/qs11/product-labels-household.webp'
    )
  ),
  'productPage', jsonb_build_object(
    'headline', 'Custom vinyl stickers and labels for bottles, packaging, windows and branding',
    'intro', 'Choose the print area, artwork help and whether you need print only or print + cut.',
    'useCases', jsonb_build_array(
      jsonb_build_object('label', 'Bottles'),
      jsonb_build_object('label', 'Packaging'),
      jsonb_build_object('label', 'Windows'),
      jsonb_build_object('label', 'Product branding')
    ),
    'highlights', jsonb_build_array(
      jsonb_build_object('label', 'White self-adhesive vinyl'),
      jsonb_build_object('label', 'Print only or print + cut'),
      jsonb_build_object('label', 'Artwork ready, checked, or designed for you'),
      jsonb_build_object('label', 'Standard or express turnaround, where available')
    ),
    'configPreview', jsonb_build_array('finishing', 'artwork'),
    -- Correction: showStartingPrice is opt-in and only enabled once the
    -- default configuration is confirmed to be the genuine cheapest
    -- valid one - not merely because a pricing object exists. Confirmed
    -- for vinyl-stickers (matches src/data/products.js's reasoning
    -- comment exactly): commerce.qs_calculate_price's PER_AREA path is
    -- monotonically non-decreasing in area/material multiplier/
    -- finishing fee/artwork fee/turnaround multiplier, and every default
    -- option (1x1m matching minimumBillableArea, the only material
    -- option, 'print-only'/'ready'/'standard' - each the zero-fee/1x
    -- choice for its field) is that minimum.
    'showStartingPrice', true
  )
),
updated_at = now()
from public.tenants t
where c.tenant_id = t.id
  and t.slug = 'quick-solution'
  and c.source_key = 'vinyl-stickers';

commit;

-- Manual verification (run in Studio after applying, before considering
-- this "done" for a second product):
--
--   select customer_definition->'media', customer_definition->'productPage'
--   from commerce.service_product_configs c
--   join public.tenants t on t.id = c.tenant_id
--   where t.slug = 'quick-solution' and c.source_key = 'vinyl-stickers';
--
-- Expect the exact objects above. Confirm no other key on the row
-- changed by diffing against a pre-migration export if in doubt.
