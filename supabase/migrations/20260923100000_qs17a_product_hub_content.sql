-- QS-17A: Product Hub content for pvc-banner, business-cards, printed-tshirt.
--
-- Purely additive JSONB merge onto EXISTING
-- commerce.service_product_configs.customer_definition rows (no new
-- column, no new table, no schema change - customer_definition is
-- already `jsonb not null default '{}'::jsonb`, same pattern as
-- 20260922100000_qs16_product_hub_content.sql). Adds two optional keys,
-- 'media' and 'productPage', per row - every other existing key (id,
-- name, pricing, fields, channels, guidedJourneyId, ...) is left
-- completely untouched by the `||` merge below (see QS-16's migration
-- for the full reasoning on why this operator is safe here: it only
-- ever replaces/adds the exact top-level keys named in the right-hand
-- operand, nothing else).
--
-- No presets on these three - QS-17's curated preset layer is scoped to
-- flags/gazebos only (see 20260923100500_qs17b_...). None of these three
-- products need it: pvc-banner/printed-tshirt are simple field-driven
-- configurators already, and business-cards is a flat quantity-tier
-- pick - there's no "technically complex variant matrix" to shortcut.
--
-- Content is derived directly from each product's own existing
-- description/plainDescription/field data - see the matching comments
-- on the local src/data/products.js fallback objects added in this same
-- change for the field-by-field reasoning. No new durability/material-
-- spec/turnaround-day claims and no prices.
--
-- pvc-banner and business-cards and printed-tshirt predate this repo's
-- tracked migration history (confirmed: no earlier migration file
-- defines their base commerce.products/service_product_configs rows -
-- they were seeded before 20260913155351_qs_03_quick_solution_foundation.sql,
-- or outside the migrations folder entirely). The preflight check below
-- only confirms they are already published, exactly like QS-11/QS-14's
-- own preflight checks against pvc-banner do - it does not create them.
--
-- NOT APPLIED YET - written for review only, per instruction.

begin;

do $qs17a_preflight$
begin
  if not exists (
    select 1
    from public.tenants t
    join commerce.service_product_configs c on c.tenant_id = t.id
    where t.slug = 'quick-solution'
      and c.source_key = 'pvc-banner'
      and c.status = 'published'
  ) then
    raise exception 'QS17A prerequisite missing: quick-solution pvc-banner catalogue row';
  end if;

  if not exists (
    select 1
    from public.tenants t
    join commerce.service_product_configs c on c.tenant_id = t.id
    where t.slug = 'quick-solution'
      and c.source_key = 'business-cards'
      and c.status = 'published'
  ) then
    raise exception 'QS17A prerequisite missing: quick-solution business-cards catalogue row';
  end if;

  if not exists (
    select 1
    from public.tenants t
    join commerce.service_product_configs c on c.tenant_id = t.id
    where t.slug = 'quick-solution'
      and c.source_key = 'printed-tshirt'
      and c.status = 'published'
  ) then
    raise exception 'QS17A prerequisite missing: quick-solution printed-tshirt catalogue row';
  end if;
end
$qs17a_preflight$;

update commerce.service_product_configs c
set customer_definition = c.customer_definition || jsonb_build_object(
  'media', jsonb_build_object(
    'hero', '/qs11/product-pvc-banner-clean.webp',
    'gallery', jsonb_build_array('/qs11/product-pvc-banner-clean.webp', '/qs11/pvc-banner.webp')
  ),
  'productPage', jsonb_build_object(
    'headline', 'Custom PVC banners for shops, events and promotions',
    'intro', 'Choose the size, finish and artwork help you need.',
    'useCases', jsonb_build_array(
      jsonb_build_object('label', 'Shop signage'),
      jsonb_build_object('label', 'Events'),
      jsonb_build_object('label', 'Promotions')
    ),
    'highlights', jsonb_build_array(
      jsonb_build_object('label', 'Standard, premium or mesh PVC'),
      jsonb_build_object('label', 'Hem and eyelet finishing available'),
      jsonb_build_object('label', 'Artwork ready, checked, or designed for you'),
      jsonb_build_object('label', 'Standard or express turnaround')
    ),
    'configPreview', jsonb_build_array('material', 'finishing'),
    'showStartingPrice', false
  )
),
updated_at = now()
from public.tenants t
where c.tenant_id = t.id
  and t.slug = 'quick-solution'
  and c.source_key = 'pvc-banner';

update commerce.service_product_configs c
set customer_definition = c.customer_definition || jsonb_build_object(
  'media', jsonb_build_object(
    'hero', '/qs11/product-business-cards-clean.webp',
    'gallery', jsonb_build_array('/qs11/product-business-cards-clean.webp', '/qs11/business-cards.webp')
  ),
  'productPage', jsonb_build_object(
    'headline', 'Professional business cards with clear quantity-based pricing',
    'intro', 'Choose quantity, stock and whether you need design help.',
    'highlights', jsonb_build_array(
      jsonb_build_object('label', 'Standard or extra-thick card stock'),
      jsonb_build_object('label', 'Matt or gloss lamination available'),
      jsonb_build_object('label', 'Design ready, checked, or designed for you')
    ),
    'configPreview', jsonb_build_array('stock', 'finish'),
    -- showStartingPrice: true per the agreed rule - confirmed safe: the
    -- default config (100 cards, standard stock x1, standard finish fee
    -- 0, ready artwork fee 0) is every field's cheapest option, so it is
    -- genuinely the minimum price, not merely "a" price.
    'showStartingPrice', true
  )
),
updated_at = now()
from public.tenants t
where c.tenant_id = t.id
  and t.slug = 'quick-solution'
  and c.source_key = 'business-cards';

update commerce.service_product_configs c
set customer_definition = c.customer_definition || jsonb_build_object(
  'media', jsonb_build_object(
    'hero', '/qs11/product-tshirt-clean.webp',
    'gallery', jsonb_build_array('/qs11/product-tshirt-clean.webp', '/qs11/apparel-printing.webp')
  ),
  'productPage', jsonb_build_object(
    'headline', 'Custom printed T-shirts, your garment or ours',
    'intro', 'Choose the shirt, print size and quantity without print jargon.',
    'highlights', jsonb_build_array(
      jsonb_build_object('label', 'Bring your own shirt or choose a Joint X blank'),
      jsonb_build_object('label', 'Front and back print sizes available'),
      jsonb_build_object('label', 'Artwork ready, checked, or designed for you')
    ),
    'configPreview', jsonb_build_array('garment', 'frontPrint'),
    'showStartingPrice', false
  )
),
updated_at = now()
from public.tenants t
where c.tenant_id = t.id
  and t.slug = 'quick-solution'
  and c.source_key = 'printed-tshirt';

commit;

-- Manual verification (run in Studio after applying):
--
--   select c.source_key, c.customer_definition->'media', c.customer_definition->'productPage'
--   from commerce.service_product_configs c
--   join public.tenants t on t.id = c.tenant_id
--   where t.slug = 'quick-solution' and c.source_key in ('pvc-banner', 'business-cards', 'printed-tshirt');
--
-- Expect the exact objects above for each row. Confirm no other key on
-- any of the three rows changed by diffing against a pre-migration
-- export if in doubt.
