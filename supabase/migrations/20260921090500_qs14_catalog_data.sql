-- QS-14 catalogue data: Flags, Gazebos (SUPPLIER_MARGIN) and
-- Quick Photo Session (PHOTOGRAPHY_SESSION).
--
-- Supplier reference prices for Flags and Gazebos are sourced from
-- Banner and Flag Online's published End User Price List (Excl. VAT),
-- effective 2026-08-11 — see sourceUrl/sourceDate on each
-- pricing_definition below. These are PUBLIC LIST reference prices,
-- not verified wholesale/negotiated cost — flagged explicitly via
-- pricing_definition itself (staff-only; get_quick_solution_catalog
-- never returns pricing_definition to the public catalog RPC, only
-- customer_definition, so none of this — reference price, margin,
-- source — is ever exposed to a customer).
--
-- Selling price = referencePrice / (1 - marginRate) — GROSS margin
-- (0.5 = 50%), not markup. Every reference/margin figure here is
-- editable afterwards through admin_update_quick_solution_product
-- (the standard Quick Solution Product Admin editor), same as every
-- other product's pricing_definition — nothing here is hardcoded
-- outside the database.
--
-- Quick Photo Session carries exactly one approved price (R449 for a
-- 30-minute session with 7 edited photos included). Every other
-- duration, extra edited photos, and every deliverable is
-- unapproved (price: null) and resolves to "Quote required" per
-- commerce.qs_calculate_price's PHOTOGRAPHY_SESSION branch — no
-- hourly rate is invented, no expiry/travel/turnaround is implied.
-- The existing media-services ENQUIRY product (Photography & Video,
-- for headshots/events/campaigns/etc.) is untouched by this migration.

begin;

do $qs14_preflight$
begin
  if not exists (
    select 1 from public.tenants t
    join commerce.service_product_configs c on c.tenant_id=t.id
    where t.slug='quick-solution' and c.source_key='pvc-banner' and c.status='published'
  ) then
    raise exception 'QS14 prerequisite missing: published Quick Solution PVC Banner config';
  end if;
end
$qs14_preflight$;

-- ── Flags & Promotional Flags ──────────────────────────────────────────────
insert into commerce.products (
  tenant_id, slug, name, description, currency, availability, status, source_system, source_ref
)
select
  t.id,
  'flags',
  'Flags & Promotional Flags',
  'Telescopic, Shark Fin and Curved flags for shopfronts, stands and events.',
  'ZAR',
  'available',
  'published',
  'quick_solution',
  'flags'
from public.tenants t
where t.slug='quick-solution'
  and not exists (
    select 1 from commerce.products p where p.tenant_id=t.id and p.slug='flags'
  );

update commerce.products p
set name='Flags & Promotional Flags',
    description='Telescopic, Shark Fin and Curved flags for shopfronts, stands and events.',
    availability='available',
    status='published',
    source_system='quick_solution',
    source_ref='flags',
    updated_at=now()
from public.tenants t
where p.tenant_id=t.id and t.slug='quick-solution' and p.slug='flags';

insert into commerce.service_product_configs (
  tenant_id, product_id, source_key, customer_definition, pricing_version, pricing_definition, status, sort_order
)
select
  t.id,
  p.id,
  'flags',
  $cd${"id":"flags","name":"Flags & Promotional Flags","shortName":"Flags","category":"Flags & Events","description":"Telescopic, Shark Fin and Curved flags for shopfronts, stands and events.","plainDescription":"Choose the flag style, size, sides and whether you need the full kit or just a replacement print.","image":"/qs14/flags-placeholder.webp","keywords":["flag","flags","promotional flag","feather flag","teardrop flag","telescopic banner","shark fin banner","event flag","outdoor flag"],"popular":false,"active":true,"channels":{"storefront":true,"guided":true,"pos":true,"quote":true},"guidedJourneyId":"flags-guided","nextActionLabel":"Continue to collection","pricing":{"strategy":"SUPPLIER_MARGIN","minQuantity":1,"variantAxes":[{"id":"style","label":"Style","options":[{"id":"telescopic","label":"Telescopic"},{"id":"sharkfin","label":"Shark Fin"},{"id":"curved","label":"Curved"}]},{"id":"size","label":"Size","options":[{"id":"2m","label":"2.0m"},{"id":"3m","label":"3.0m"},{"id":"4m","label":"4.0m"}]},{"id":"sides","label":"Sides","options":[{"id":"ss","label":"Single-sided (must be ordered in pairs of 2)"},{"id":"ds","label":"Double-sided"}]},{"id":"kit","label":"Kit","options":[{"id":"full","label":"Full kit (print + system + ground spike + carry bag)"},{"id":"reprint","label":"Replacement print only"}]}],"variantTemplate":"{style}-{size}-{sides}-{kit}","variants":{"telescopic-2m-ss-full":{"label":"Telescopic flag — 2.0m — single-sided — full kit (print + system + ground spike + carry bag)","price":990,"minQuantity":2,"quantityStep":2},"telescopic-3m-ss-full":{"label":"Telescopic flag — 3.0m — single-sided — full kit (print + system + ground spike + carry bag)","price":1190,"minQuantity":2,"quantityStep":2},"telescopic-4m-ss-full":{"label":"Telescopic flag — 4.0m — single-sided — full kit (print + system + ground spike + carry bag)","price":1390,"minQuantity":2,"quantityStep":2},"telescopic-2m-ds-full":{"label":"Telescopic flag — 2.0m — double-sided — full kit (print + system + ground spike + carry bag)","price":1390},"telescopic-3m-ds-full":{"label":"Telescopic flag — 3.0m — double-sided — full kit (print + system + ground spike + carry bag)","price":1750},"telescopic-4m-ds-full":{"label":"Telescopic flag — 4.0m — double-sided — full kit (print + system + ground spike + carry bag)","price":2100},"telescopic-2m-ss-reprint":{"label":"Telescopic flag — 2.0m — single-sided — replacement print only","price":470,"minQuantity":2,"quantityStep":2},"telescopic-3m-ss-reprint":{"label":"Telescopic flag — 3.0m — single-sided — replacement print only","price":650,"minQuantity":2,"quantityStep":2},"telescopic-4m-ss-reprint":{"label":"Telescopic flag — 4.0m — single-sided — replacement print only","price":790,"minQuantity":2,"quantityStep":2},"telescopic-2m-ds-reprint":{"label":"Telescopic flag — 2.0m — double-sided — replacement print only","price":900},"telescopic-3m-ds-reprint":{"label":"Telescopic flag — 3.0m — double-sided — replacement print only","price":1150},"telescopic-4m-ds-reprint":{"label":"Telescopic flag — 4.0m — double-sided — replacement print only","price":1450},"sharkfin-2m-ss-full":{"label":"Shark Fin flag — 2.0m — single-sided — full kit (print + system + ground spike + carry bag)","price":990,"minQuantity":2,"quantityStep":2},"sharkfin-3m-ss-full":{"label":"Shark Fin flag — 3.0m — single-sided — full kit (print + system + ground spike + carry bag)","price":1190,"minQuantity":2,"quantityStep":2},"sharkfin-4m-ss-full":{"label":"Shark Fin flag — 4.0m — single-sided — full kit (print + system + ground spike + carry bag)","price":1390,"minQuantity":2,"quantityStep":2},"sharkfin-2m-ds-full":{"label":"Shark Fin flag — 2.0m — double-sided — full kit (print + system + ground spike + carry bag)","price":1390},"sharkfin-3m-ds-full":{"label":"Shark Fin flag — 3.0m — double-sided — full kit (print + system + ground spike + carry bag)","price":1750},"sharkfin-4m-ds-full":{"label":"Shark Fin flag — 4.0m — double-sided — full kit (print + system + ground spike + carry bag)","price":2100},"sharkfin-2m-ss-reprint":{"label":"Shark Fin flag — 2.0m — single-sided — replacement print only","price":470,"minQuantity":2,"quantityStep":2},"sharkfin-3m-ss-reprint":{"label":"Shark Fin flag — 3.0m — single-sided — replacement print only","price":650,"minQuantity":2,"quantityStep":2},"sharkfin-4m-ss-reprint":{"label":"Shark Fin flag — 4.0m — single-sided — replacement print only","price":790,"minQuantity":2,"quantityStep":2},"sharkfin-2m-ds-reprint":{"label":"Shark Fin flag — 2.0m — double-sided — replacement print only","price":900},"sharkfin-3m-ds-reprint":{"label":"Shark Fin flag — 3.0m — double-sided — replacement print only","price":1150},"sharkfin-4m-ds-reprint":{"label":"Shark Fin flag — 4.0m — double-sided — replacement print only","price":1450},"curved-2m-ss-full":{"label":"Curved flag — 2.0m — single-sided — full kit (print + system + ground spike + carry bag)","price":1050,"minQuantity":2,"quantityStep":2},"curved-3m-ss-full":{"label":"Curved flag — 3.0m — single-sided — full kit (print + system + ground spike + carry bag)","price":1250,"minQuantity":2,"quantityStep":2},"curved-4m-ss-full":{"label":"Curved flag — 4.0m — single-sided — full kit (print + system + ground spike + carry bag)","price":1500,"minQuantity":2,"quantityStep":2},"curved-2m-ds-full":{"label":"Curved flag — 2.0m — double-sided — full kit (print + system + ground spike + carry bag)","price":1500},"curved-3m-ds-full":{"label":"Curved flag — 3.0m — double-sided — full kit (print + system + ground spike + carry bag)","price":1850},"curved-4m-ds-full":{"label":"Curved flag — 4.0m — double-sided — full kit (print + system + ground spike + carry bag)","price":2190},"curved-2m-ss-reprint":{"label":"Curved flag — 2.0m — single-sided — replacement print only","price":500,"minQuantity":2,"quantityStep":2},"curved-3m-ss-reprint":{"label":"Curved flag — 3.0m — single-sided — replacement print only","price":700,"minQuantity":2,"quantityStep":2},"curved-4m-ss-reprint":{"label":"Curved flag — 4.0m — single-sided — replacement print only","price":850,"minQuantity":2,"quantityStep":2},"curved-2m-ds-reprint":{"label":"Curved flag — 2.0m — double-sided — replacement print only","price":950},"curved-3m-ds-reprint":{"label":"Curved flag — 3.0m — double-sided — replacement print only","price":1300},"curved-4m-ds-reprint":{"label":"Curved flag — 4.0m — double-sided — replacement print only","price":1500}},"accessories":{"cross-base":{"label":"Cross base","price":500},"ground-spike":{"label":"Ground spike","price":160},"water-bag":{"label":"Water weight bag","price":390},"wall-bracket":{"label":"Wall bracket","price":300},"cluster-flag-stand":{"label":"Cluster flag stand (holds 4 flags)","price":1190}},"artwork":{"ready":{"label":"My artwork is ready","fee":0},"check":{"label":"Please check my artwork","fee":75},"design":{"label":"I need help with the design","fee":250}}},"fields":[{"id":"variant","type":"select","label":"Which flag would you like?","shortLabel":"Flag","options":[{"id":"telescopic-2m-ss-full","label":"Telescopic flag — 2.0m — single-sided — full kit (print + system + ground spike + carry bag)"},{"id":"telescopic-3m-ss-full","label":"Telescopic flag — 3.0m — single-sided — full kit (print + system + ground spike + carry bag)"},{"id":"telescopic-4m-ss-full","label":"Telescopic flag — 4.0m — single-sided — full kit (print + system + ground spike + carry bag)"},{"id":"telescopic-2m-ds-full","label":"Telescopic flag — 2.0m — double-sided — full kit (print + system + ground spike + carry bag)"},{"id":"telescopic-3m-ds-full","label":"Telescopic flag — 3.0m — double-sided — full kit (print + system + ground spike + carry bag)"},{"id":"telescopic-4m-ds-full","label":"Telescopic flag — 4.0m — double-sided — full kit (print + system + ground spike + carry bag)"},{"id":"telescopic-2m-ss-reprint","label":"Telescopic flag — 2.0m — single-sided — replacement print only"},{"id":"telescopic-3m-ss-reprint","label":"Telescopic flag — 3.0m — single-sided — replacement print only"},{"id":"telescopic-4m-ss-reprint","label":"Telescopic flag — 4.0m — single-sided — replacement print only"},{"id":"telescopic-2m-ds-reprint","label":"Telescopic flag — 2.0m — double-sided — replacement print only"},{"id":"telescopic-3m-ds-reprint","label":"Telescopic flag — 3.0m — double-sided — replacement print only"},{"id":"telescopic-4m-ds-reprint","label":"Telescopic flag — 4.0m — double-sided — replacement print only"},{"id":"sharkfin-2m-ss-full","label":"Shark Fin flag — 2.0m — single-sided — full kit (print + system + ground spike + carry bag)"},{"id":"sharkfin-3m-ss-full","label":"Shark Fin flag — 3.0m — single-sided — full kit (print + system + ground spike + carry bag)"},{"id":"sharkfin-4m-ss-full","label":"Shark Fin flag — 4.0m — single-sided — full kit (print + system + ground spike + carry bag)"},{"id":"sharkfin-2m-ds-full","label":"Shark Fin flag — 2.0m — double-sided — full kit (print + system + ground spike + carry bag)"},{"id":"sharkfin-3m-ds-full","label":"Shark Fin flag — 3.0m — double-sided — full kit (print + system + ground spike + carry bag)"},{"id":"sharkfin-4m-ds-full","label":"Shark Fin flag — 4.0m — double-sided — full kit (print + system + ground spike + carry bag)"},{"id":"sharkfin-2m-ss-reprint","label":"Shark Fin flag — 2.0m — single-sided — replacement print only"},{"id":"sharkfin-3m-ss-reprint","label":"Shark Fin flag — 3.0m — single-sided — replacement print only"},{"id":"sharkfin-4m-ss-reprint","label":"Shark Fin flag — 4.0m — single-sided — replacement print only"},{"id":"sharkfin-2m-ds-reprint","label":"Shark Fin flag — 2.0m — double-sided — replacement print only"},{"id":"sharkfin-3m-ds-reprint","label":"Shark Fin flag — 3.0m — double-sided — replacement print only"},{"id":"sharkfin-4m-ds-reprint","label":"Shark Fin flag — 4.0m — double-sided — replacement print only"},{"id":"curved-2m-ss-full","label":"Curved flag — 2.0m — single-sided — full kit (print + system + ground spike + carry bag)"},{"id":"curved-3m-ss-full","label":"Curved flag — 3.0m — single-sided — full kit (print + system + ground spike + carry bag)"},{"id":"curved-4m-ss-full","label":"Curved flag — 4.0m — single-sided — full kit (print + system + ground spike + carry bag)"},{"id":"curved-2m-ds-full","label":"Curved flag — 2.0m — double-sided — full kit (print + system + ground spike + carry bag)"},{"id":"curved-3m-ds-full","label":"Curved flag — 3.0m — double-sided — full kit (print + system + ground spike + carry bag)"},{"id":"curved-4m-ds-full","label":"Curved flag — 4.0m — double-sided — full kit (print + system + ground spike + carry bag)"},{"id":"curved-2m-ss-reprint","label":"Curved flag — 2.0m — single-sided — replacement print only"},{"id":"curved-3m-ss-reprint","label":"Curved flag — 3.0m — single-sided — replacement print only"},{"id":"curved-4m-ss-reprint","label":"Curved flag — 4.0m — single-sided — replacement print only"},{"id":"curved-2m-ds-reprint","label":"Curved flag — 2.0m — double-sided — replacement print only"},{"id":"curved-3m-ds-reprint","label":"Curved flag — 3.0m — double-sided — replacement print only"},{"id":"curved-4m-ds-reprint","label":"Curved flag — 4.0m — double-sided — replacement print only"}]},{"id":"quantity","type":"number","label":"How many?","shortLabel":"Quantity","default":1,"min":1,"step":1,"required":true},{"id":"artwork","type":"select","label":"What is happening with the design?","shortLabel":"Artwork","default":"ready","options":[{"id":"ready","label":"My artwork is ready"},{"id":"check","label":"Please check my artwork"},{"id":"design","label":"I need help with the design"}]},{"id":"file","type":"file","label":"Artwork file","help":"PDF or high-resolution PNG/JPG works best."}]}$cd$::jsonb,
  '2026-09-qsc-14a',
  $pd${"strategy":"SUPPLIER_MARGIN","marginRate":0.5,"vatBasis":"excl_vat","sourceName":"Banner and Flag Online — End User Price List","sourceUrl":"https://www.bannerandflagonline.co.za/wp-content/uploads/2026/08/End-User-Price_11-August-2026.pdf","sourceDate":"2026-08-11","minQuantity":1,"variantAxes":[{"id":"style","label":"Style","options":[{"id":"telescopic","label":"Telescopic"},{"id":"sharkfin","label":"Shark Fin"},{"id":"curved","label":"Curved"}]},{"id":"size","label":"Size","options":[{"id":"2m","label":"2.0m"},{"id":"3m","label":"3.0m"},{"id":"4m","label":"4.0m"}]},{"id":"sides","label":"Sides","options":[{"id":"ss","label":"Single-sided (must be ordered in pairs of 2)"},{"id":"ds","label":"Double-sided"}]},{"id":"kit","label":"Kit","options":[{"id":"full","label":"Full kit (print + system + ground spike + carry bag)"},{"id":"reprint","label":"Replacement print only"}]}],"variantTemplate":"{style}-{size}-{sides}-{kit}","variants":{"telescopic-2m-ss-full":{"label":"Telescopic flag — 2.0m — single-sided — full kit (print + system + ground spike + carry bag)","referencePrice":495,"minQuantity":2,"quantityStep":2},"telescopic-3m-ss-full":{"label":"Telescopic flag — 3.0m — single-sided — full kit (print + system + ground spike + carry bag)","referencePrice":595,"minQuantity":2,"quantityStep":2},"telescopic-4m-ss-full":{"label":"Telescopic flag — 4.0m — single-sided — full kit (print + system + ground spike + carry bag)","referencePrice":695,"minQuantity":2,"quantityStep":2},"telescopic-2m-ds-full":{"label":"Telescopic flag — 2.0m — double-sided — full kit (print + system + ground spike + carry bag)","referencePrice":695},"telescopic-3m-ds-full":{"label":"Telescopic flag — 3.0m — double-sided — full kit (print + system + ground spike + carry bag)","referencePrice":875},"telescopic-4m-ds-full":{"label":"Telescopic flag — 4.0m — double-sided — full kit (print + system + ground spike + carry bag)","referencePrice":1050},"telescopic-2m-ss-reprint":{"label":"Telescopic flag — 2.0m — single-sided — replacement print only","referencePrice":235,"minQuantity":2,"quantityStep":2},"telescopic-3m-ss-reprint":{"label":"Telescopic flag — 3.0m — single-sided — replacement print only","referencePrice":325,"minQuantity":2,"quantityStep":2},"telescopic-4m-ss-reprint":{"label":"Telescopic flag — 4.0m — single-sided — replacement print only","referencePrice":395,"minQuantity":2,"quantityStep":2},"telescopic-2m-ds-reprint":{"label":"Telescopic flag — 2.0m — double-sided — replacement print only","referencePrice":450},"telescopic-3m-ds-reprint":{"label":"Telescopic flag — 3.0m — double-sided — replacement print only","referencePrice":575},"telescopic-4m-ds-reprint":{"label":"Telescopic flag — 4.0m — double-sided — replacement print only","referencePrice":725},"sharkfin-2m-ss-full":{"label":"Shark Fin flag — 2.0m — single-sided — full kit (print + system + ground spike + carry bag)","referencePrice":495,"minQuantity":2,"quantityStep":2},"sharkfin-3m-ss-full":{"label":"Shark Fin flag — 3.0m — single-sided — full kit (print + system + ground spike + carry bag)","referencePrice":595,"minQuantity":2,"quantityStep":2},"sharkfin-4m-ss-full":{"label":"Shark Fin flag — 4.0m — single-sided — full kit (print + system + ground spike + carry bag)","referencePrice":695,"minQuantity":2,"quantityStep":2},"sharkfin-2m-ds-full":{"label":"Shark Fin flag — 2.0m — double-sided — full kit (print + system + ground spike + carry bag)","referencePrice":695},"sharkfin-3m-ds-full":{"label":"Shark Fin flag — 3.0m — double-sided — full kit (print + system + ground spike + carry bag)","referencePrice":875},"sharkfin-4m-ds-full":{"label":"Shark Fin flag — 4.0m — double-sided — full kit (print + system + ground spike + carry bag)","referencePrice":1050},"sharkfin-2m-ss-reprint":{"label":"Shark Fin flag — 2.0m — single-sided — replacement print only","referencePrice":235,"minQuantity":2,"quantityStep":2},"sharkfin-3m-ss-reprint":{"label":"Shark Fin flag — 3.0m — single-sided — replacement print only","referencePrice":325,"minQuantity":2,"quantityStep":2},"sharkfin-4m-ss-reprint":{"label":"Shark Fin flag — 4.0m — single-sided — replacement print only","referencePrice":395,"minQuantity":2,"quantityStep":2},"sharkfin-2m-ds-reprint":{"label":"Shark Fin flag — 2.0m — double-sided — replacement print only","referencePrice":450},"sharkfin-3m-ds-reprint":{"label":"Shark Fin flag — 3.0m — double-sided — replacement print only","referencePrice":575},"sharkfin-4m-ds-reprint":{"label":"Shark Fin flag — 4.0m — double-sided — replacement print only","referencePrice":725},"curved-2m-ss-full":{"label":"Curved flag — 2.0m — single-sided — full kit (print + system + ground spike + carry bag)","referencePrice":525,"minQuantity":2,"quantityStep":2},"curved-3m-ss-full":{"label":"Curved flag — 3.0m — single-sided — full kit (print + system + ground spike + carry bag)","referencePrice":625,"minQuantity":2,"quantityStep":2},"curved-4m-ss-full":{"label":"Curved flag — 4.0m — single-sided — full kit (print + system + ground spike + carry bag)","referencePrice":750,"minQuantity":2,"quantityStep":2},"curved-2m-ds-full":{"label":"Curved flag — 2.0m — double-sided — full kit (print + system + ground spike + carry bag)","referencePrice":750},"curved-3m-ds-full":{"label":"Curved flag — 3.0m — double-sided — full kit (print + system + ground spike + carry bag)","referencePrice":925},"curved-4m-ds-full":{"label":"Curved flag — 4.0m — double-sided — full kit (print + system + ground spike + carry bag)","referencePrice":1095},"curved-2m-ss-reprint":{"label":"Curved flag — 2.0m — single-sided — replacement print only","referencePrice":250,"minQuantity":2,"quantityStep":2},"curved-3m-ss-reprint":{"label":"Curved flag — 3.0m — single-sided — replacement print only","referencePrice":350,"minQuantity":2,"quantityStep":2},"curved-4m-ss-reprint":{"label":"Curved flag — 4.0m — single-sided — replacement print only","referencePrice":425,"minQuantity":2,"quantityStep":2},"curved-2m-ds-reprint":{"label":"Curved flag — 2.0m — double-sided — replacement print only","referencePrice":475},"curved-3m-ds-reprint":{"label":"Curved flag — 3.0m — double-sided — replacement print only","referencePrice":650},"curved-4m-ds-reprint":{"label":"Curved flag — 4.0m — double-sided — replacement print only","referencePrice":750}},"accessories":{"cross-base":{"label":"Cross base","referencePrice":250},"ground-spike":{"label":"Ground spike","referencePrice":80},"water-bag":{"label":"Water weight bag","referencePrice":195},"wall-bracket":{"label":"Wall bracket","referencePrice":150},"cluster-flag-stand":{"label":"Cluster flag stand (holds 4 flags)","referencePrice":595}},"artwork":{"ready":{"label":"My artwork is ready","fee":0},"check":{"label":"Please check my artwork","fee":75},"design":{"label":"I need help with the design","fee":250}}}$pd$::jsonb,
  'published',
  20
from public.tenants t
join commerce.products p on p.tenant_id=t.id and p.slug='flags'
where t.slug='quick-solution'
on conflict (tenant_id, source_key) do update
set product_id=excluded.product_id,
    customer_definition=excluded.customer_definition,
    pricing_version=excluded.pricing_version,
    pricing_definition=excluded.pricing_definition,
    status='published',
    sort_order=excluded.sort_order,
    updated_at=now();

-- ── Gazebos & Event Displays ──────────────────────────────────────────────
insert into commerce.products (
  tenant_id, slug, name, description, currency, availability, status, source_system, source_ref
)
select
  t.id,
  'gazebos',
  'Gazebos & Event Displays',
  'Branded steel and aluminium gazebos for markets, activations and events.',
  'ZAR',
  'available',
  'published',
  'quick_solution',
  'gazebos'
from public.tenants t
where t.slug='quick-solution'
  and not exists (
    select 1 from commerce.products p where p.tenant_id=t.id and p.slug='gazebos'
  );

update commerce.products p
set name='Gazebos & Event Displays',
    description='Branded steel and aluminium gazebos for markets, activations and events.',
    availability='available',
    status='published',
    source_system='quick_solution',
    source_ref='gazebos',
    updated_at=now()
from public.tenants t
where p.tenant_id=t.id and t.slug='quick-solution' and p.slug='gazebos';

insert into commerce.service_product_configs (
  tenant_id, product_id, source_key, customer_definition, pricing_version, pricing_definition, status, sort_order
)
select
  t.id,
  p.id,
  'gazebos',
  $cd${"id":"gazebos","name":"Gazebos & Event Displays","shortName":"Gazebos","category":"Flags & Events","description":"Branded steel and aluminium gazebos for markets, activations and events.","plainDescription":"Choose the frame, size and whether you need the full kit or just a replacement canopy print.","image":"/qs11/event-gazebo.webp","keywords":["gazebo","event display","market stand","branded gazebo","pop up tent","event branding"],"popular":false,"active":true,"channels":{"storefront":true,"guided":true,"pos":true,"quote":true},"guidedJourneyId":"gazebos-guided","nextActionLabel":"Continue to collection","pricing":{"strategy":"SUPPLIER_MARGIN","minQuantity":1,"variantAxes":[{"id":"frame","label":"Frame","options":[{"id":"steel","label":"Steel"},{"id":"aluminium","label":"Aluminium"}]},{"id":"size","label":"Size","options":[{"id":"2x2","label":"2m × 2m"},{"id":"3x3-standard","label":"3m × 3m standard"},{"id":"3x3-deluxe","label":"3m × 3m deluxe"},{"id":"3x4.5-deluxe","label":"3m × 4.5m deluxe","availableWhen":{"frame":["aluminium"]}},{"id":"3x6-deluxe","label":"3m × 6m deluxe","availableWhen":{"frame":["aluminium"]}}]},{"id":"kit","label":"Kit","options":[{"id":"full","label":"Full kit (print + system + carry bag + toolkit)"},{"id":"reprint","label":"Replacement canopy print only"}]}],"variantTemplate":"{frame}-{size}-{kit}","variants":{"steel-2x2-full":{"label":"Steel gazebo — 2m × 2m — full kit (print + system + carry bag + toolkit)","price":5500},"steel-2x2-reprint":{"label":"Steel gazebo — 2m × 2m — replacement canopy print only","price":2700},"steel-3x3-standard-full":{"label":"Steel gazebo — 3m × 3m standard — full kit (print + system + carry bag + toolkit)","price":6700},"steel-3x3-standard-reprint":{"label":"Steel gazebo — 3m × 3m standard — replacement canopy print only","price":4300},"steel-3x3-deluxe-full":{"label":"Steel gazebo — 3m × 3m deluxe — full kit (print + system + carry bag + toolkit)","price":7700},"steel-3x3-deluxe-reprint":{"label":"Steel gazebo — 3m × 3m deluxe — replacement canopy print only","price":4300},"aluminium-2x2-full":{"label":"Aluminium gazebo — 2m × 2m — full kit (print + system + carry bag + toolkit)","price":6500},"aluminium-2x2-reprint":{"label":"Aluminium gazebo — 2m × 2m — replacement canopy print only","price":2700},"aluminium-3x3-standard-full":{"label":"Aluminium gazebo — 3m × 3m standard — full kit (print + system + carry bag + toolkit)","price":7990},"aluminium-3x3-standard-reprint":{"label":"Aluminium gazebo — 3m × 3m standard — replacement canopy print only","price":4300},"aluminium-3x3-deluxe-full":{"label":"Aluminium gazebo — 3m × 3m deluxe — full kit (print + system + carry bag + toolkit)","price":8900},"aluminium-3x3-deluxe-reprint":{"label":"Aluminium gazebo — 3m × 3m deluxe — replacement canopy print only","price":4300},"aluminium-3x4.5-deluxe-full":{"label":"Aluminium gazebo — 3m × 4.5m deluxe — full kit (print + system + carry bag + toolkit)","price":12990},"aluminium-3x4.5-deluxe-reprint":{"label":"Aluminium gazebo — 3m × 4.5m deluxe — replacement canopy print only","price":5790},"aluminium-3x6-deluxe-full":{"label":"Aluminium gazebo — 3m × 6m deluxe — full kit (print + system + carry bag + toolkit)","price":16590},"aluminium-3x6-deluxe-reprint":{"label":"Aluminium gazebo — 3m × 6m deluxe — replacement canopy print only","price":7390}},"accessories":{"wall-2x2-half":{"label":"2m × 2m half wall","price":650,"compatibleVariants":["steel-2x2-full","steel-2x2-reprint","aluminium-2x2-full","aluminium-2x2-reprint"]},"wall-2x2-full":{"label":"2m × 2m full wall","price":1190,"compatibleVariants":["steel-2x2-full","steel-2x2-reprint","aluminium-2x2-full","aluminium-2x2-reprint"]},"wall-3x3-half":{"label":"3m × 3m half wall","price":850,"compatibleVariants":["steel-3x3-standard-full","steel-3x3-standard-reprint","steel-3x3-deluxe-full","steel-3x3-deluxe-reprint","aluminium-3x3-standard-full","aluminium-3x3-standard-reprint","aluminium-3x3-deluxe-full","aluminium-3x3-deluxe-reprint"]},"wall-3x3-full":{"label":"3m × 3m full wall","price":1650,"compatibleVariants":["steel-3x3-standard-full","steel-3x3-standard-reprint","steel-3x3-deluxe-full","steel-3x3-deluxe-reprint","aluminium-3x3-standard-full","aluminium-3x3-standard-reprint","aluminium-3x3-deluxe-full","aluminium-3x3-deluxe-reprint"]},"wall-3x4.5-full":{"label":"3m × 4.5m full wall","price":2500,"compatibleVariants":["aluminium-3x4.5-deluxe-full","aluminium-3x4.5-deluxe-reprint"]},"wall-3x6-full":{"label":"3m × 6m full wall","price":3300,"compatibleVariants":["aluminium-3x6-deluxe-full","aluminium-3x6-deluxe-reprint"]},"wall-window":{"label":"Window add-on for a wall","price":250},"wall-door":{"label":"Door with zip add-on for a wall","price":300},"rubber-weight":{"label":"Rubber weight","price":690},"sandbag-set-4":{"label":"Weight sandbag set of 4","price":680},"wheely-bag-2-3m":{"label":"Wheely bag (2m or 3m gazebo)","price":750,"compatibleVariants":["steel-2x2-full","steel-2x2-reprint","aluminium-2x2-full","aluminium-2x2-reprint","steel-3x3-standard-full","steel-3x3-standard-reprint","steel-3x3-deluxe-full","steel-3x3-deluxe-reprint","aluminium-3x3-standard-full","aluminium-3x3-standard-reprint","aluminium-3x3-deluxe-full","aluminium-3x3-deluxe-reprint"]},"wheely-bag-4-5m":{"label":"Wheely bag (4.5m gazebo)","price":900,"compatibleVariants":["aluminium-3x4.5-deluxe-full","aluminium-3x4.5-deluxe-reprint"]},"wheely-bag-6m":{"label":"Wheely bag (6m gazebo)","price":990,"compatibleVariants":["aluminium-3x6-deluxe-full","aluminium-3x6-deluxe-reprint"]}},"artwork":{"ready":{"label":"My artwork is ready","fee":0},"check":{"label":"Please check my artwork","fee":75},"design":{"label":"I need help with the design","fee":250}}},"fields":[{"id":"variant","type":"select","label":"Which gazebo would you like?","shortLabel":"Gazebo","options":[{"id":"steel-2x2-full","label":"Steel gazebo — 2m × 2m — full kit (print + system + carry bag + toolkit)"},{"id":"steel-2x2-reprint","label":"Steel gazebo — 2m × 2m — replacement canopy print only"},{"id":"steel-3x3-standard-full","label":"Steel gazebo — 3m × 3m standard — full kit (print + system + carry bag + toolkit)"},{"id":"steel-3x3-standard-reprint","label":"Steel gazebo — 3m × 3m standard — replacement canopy print only"},{"id":"steel-3x3-deluxe-full","label":"Steel gazebo — 3m × 3m deluxe — full kit (print + system + carry bag + toolkit)"},{"id":"steel-3x3-deluxe-reprint","label":"Steel gazebo — 3m × 3m deluxe — replacement canopy print only"},{"id":"aluminium-2x2-full","label":"Aluminium gazebo — 2m × 2m — full kit (print + system + carry bag + toolkit)"},{"id":"aluminium-2x2-reprint","label":"Aluminium gazebo — 2m × 2m — replacement canopy print only"},{"id":"aluminium-3x3-standard-full","label":"Aluminium gazebo — 3m × 3m standard — full kit (print + system + carry bag + toolkit)"},{"id":"aluminium-3x3-standard-reprint","label":"Aluminium gazebo — 3m × 3m standard — replacement canopy print only"},{"id":"aluminium-3x3-deluxe-full","label":"Aluminium gazebo — 3m × 3m deluxe — full kit (print + system + carry bag + toolkit)"},{"id":"aluminium-3x3-deluxe-reprint","label":"Aluminium gazebo — 3m × 3m deluxe — replacement canopy print only"},{"id":"aluminium-3x4.5-deluxe-full","label":"Aluminium gazebo — 3m × 4.5m deluxe — full kit (print + system + carry bag + toolkit)"},{"id":"aluminium-3x4.5-deluxe-reprint","label":"Aluminium gazebo — 3m × 4.5m deluxe — replacement canopy print only"},{"id":"aluminium-3x6-deluxe-full","label":"Aluminium gazebo — 3m × 6m deluxe — full kit (print + system + carry bag + toolkit)"},{"id":"aluminium-3x6-deluxe-reprint","label":"Aluminium gazebo — 3m × 6m deluxe — replacement canopy print only"}]},{"id":"quantity","type":"number","label":"How many?","shortLabel":"Quantity","default":1,"min":1,"step":1,"required":true},{"id":"artwork","type":"select","label":"What is happening with the design?","shortLabel":"Artwork","default":"ready","options":[{"id":"ready","label":"My artwork is ready"},{"id":"check","label":"Please check my artwork"},{"id":"design","label":"I need help with the design"}]},{"id":"file","type":"file","label":"Artwork file","help":"PDF or high-resolution PNG/JPG works best."}]}$cd$::jsonb,
  '2026-09-qsc-14b',
  $pd${"strategy":"SUPPLIER_MARGIN","marginRate":0.5,"vatBasis":"excl_vat","sourceName":"Banner and Flag Online — End User Price List","sourceUrl":"https://www.bannerandflagonline.co.za/wp-content/uploads/2026/08/End-User-Price_11-August-2026.pdf","sourceDate":"2026-08-11","minQuantity":1,"variantAxes":[{"id":"frame","label":"Frame","options":[{"id":"steel","label":"Steel"},{"id":"aluminium","label":"Aluminium"}]},{"id":"size","label":"Size","options":[{"id":"2x2","label":"2m × 2m"},{"id":"3x3-standard","label":"3m × 3m standard"},{"id":"3x3-deluxe","label":"3m × 3m deluxe"},{"id":"3x4.5-deluxe","label":"3m × 4.5m deluxe","availableWhen":{"frame":["aluminium"]}},{"id":"3x6-deluxe","label":"3m × 6m deluxe","availableWhen":{"frame":["aluminium"]}}]},{"id":"kit","label":"Kit","options":[{"id":"full","label":"Full kit (print + system + carry bag + toolkit)"},{"id":"reprint","label":"Replacement canopy print only"}]}],"variantTemplate":"{frame}-{size}-{kit}","variants":{"steel-2x2-full":{"label":"Steel gazebo — 2m × 2m — full kit (print + system + carry bag + toolkit)","referencePrice":2750},"steel-2x2-reprint":{"label":"Steel gazebo — 2m × 2m — replacement canopy print only","referencePrice":1350},"steel-3x3-standard-full":{"label":"Steel gazebo — 3m × 3m standard — full kit (print + system + carry bag + toolkit)","referencePrice":3350},"steel-3x3-standard-reprint":{"label":"Steel gazebo — 3m × 3m standard — replacement canopy print only","referencePrice":2150},"steel-3x3-deluxe-full":{"label":"Steel gazebo — 3m × 3m deluxe — full kit (print + system + carry bag + toolkit)","referencePrice":3850},"steel-3x3-deluxe-reprint":{"label":"Steel gazebo — 3m × 3m deluxe — replacement canopy print only","referencePrice":2150},"aluminium-2x2-full":{"label":"Aluminium gazebo — 2m × 2m — full kit (print + system + carry bag + toolkit)","referencePrice":3250},"aluminium-2x2-reprint":{"label":"Aluminium gazebo — 2m × 2m — replacement canopy print only","referencePrice":1350},"aluminium-3x3-standard-full":{"label":"Aluminium gazebo — 3m × 3m standard — full kit (print + system + carry bag + toolkit)","referencePrice":3995},"aluminium-3x3-standard-reprint":{"label":"Aluminium gazebo — 3m × 3m standard — replacement canopy print only","referencePrice":2150},"aluminium-3x3-deluxe-full":{"label":"Aluminium gazebo — 3m × 3m deluxe — full kit (print + system + carry bag + toolkit)","referencePrice":4450},"aluminium-3x3-deluxe-reprint":{"label":"Aluminium gazebo — 3m × 3m deluxe — replacement canopy print only","referencePrice":2150},"aluminium-3x4.5-deluxe-full":{"label":"Aluminium gazebo — 3m × 4.5m deluxe — full kit (print + system + carry bag + toolkit)","referencePrice":6495},"aluminium-3x4.5-deluxe-reprint":{"label":"Aluminium gazebo — 3m × 4.5m deluxe — replacement canopy print only","referencePrice":2895},"aluminium-3x6-deluxe-full":{"label":"Aluminium gazebo — 3m × 6m deluxe — full kit (print + system + carry bag + toolkit)","referencePrice":8295},"aluminium-3x6-deluxe-reprint":{"label":"Aluminium gazebo — 3m × 6m deluxe — replacement canopy print only","referencePrice":3695}},"accessories":{"wall-2x2-half":{"label":"2m × 2m half wall","referencePrice":325,"compatibleVariants":["steel-2x2-full","steel-2x2-reprint","aluminium-2x2-full","aluminium-2x2-reprint"]},"wall-2x2-full":{"label":"2m × 2m full wall","referencePrice":595,"compatibleVariants":["steel-2x2-full","steel-2x2-reprint","aluminium-2x2-full","aluminium-2x2-reprint"]},"wall-3x3-half":{"label":"3m × 3m half wall","referencePrice":425,"compatibleVariants":["steel-3x3-standard-full","steel-3x3-standard-reprint","steel-3x3-deluxe-full","steel-3x3-deluxe-reprint","aluminium-3x3-standard-full","aluminium-3x3-standard-reprint","aluminium-3x3-deluxe-full","aluminium-3x3-deluxe-reprint"]},"wall-3x3-full":{"label":"3m × 3m full wall","referencePrice":825,"compatibleVariants":["steel-3x3-standard-full","steel-3x3-standard-reprint","steel-3x3-deluxe-full","steel-3x3-deluxe-reprint","aluminium-3x3-standard-full","aluminium-3x3-standard-reprint","aluminium-3x3-deluxe-full","aluminium-3x3-deluxe-reprint"]},"wall-3x4.5-full":{"label":"3m × 4.5m full wall","referencePrice":1250,"compatibleVariants":["aluminium-3x4.5-deluxe-full","aluminium-3x4.5-deluxe-reprint"]},"wall-3x6-full":{"label":"3m × 6m full wall","referencePrice":1650,"compatibleVariants":["aluminium-3x6-deluxe-full","aluminium-3x6-deluxe-reprint"]},"wall-window":{"label":"Window add-on for a wall","referencePrice":125},"wall-door":{"label":"Door with zip add-on for a wall","referencePrice":150},"rubber-weight":{"label":"Rubber weight","referencePrice":345},"sandbag-set-4":{"label":"Weight sandbag set of 4","referencePrice":340},"wheely-bag-2-3m":{"label":"Wheely bag (2m or 3m gazebo)","referencePrice":375,"compatibleVariants":["steel-2x2-full","steel-2x2-reprint","aluminium-2x2-full","aluminium-2x2-reprint","steel-3x3-standard-full","steel-3x3-standard-reprint","steel-3x3-deluxe-full","steel-3x3-deluxe-reprint","aluminium-3x3-standard-full","aluminium-3x3-standard-reprint","aluminium-3x3-deluxe-full","aluminium-3x3-deluxe-reprint"]},"wheely-bag-4-5m":{"label":"Wheely bag (4.5m gazebo)","referencePrice":450,"compatibleVariants":["aluminium-3x4.5-deluxe-full","aluminium-3x4.5-deluxe-reprint"]},"wheely-bag-6m":{"label":"Wheely bag (6m gazebo)","referencePrice":495,"compatibleVariants":["aluminium-3x6-deluxe-full","aluminium-3x6-deluxe-reprint"]}},"artwork":{"ready":{"label":"My artwork is ready","fee":0},"check":{"label":"Please check my artwork","fee":75},"design":{"label":"I need help with the design","fee":250}}}$pd$::jsonb,
  'published',
  21
from public.tenants t
join commerce.products p on p.tenant_id=t.id and p.slug='gazebos'
where t.slug='quick-solution'
on conflict (tenant_id, source_key) do update
set product_id=excluded.product_id,
    customer_definition=excluded.customer_definition,
    pricing_version=excluded.pricing_version,
    pricing_definition=excluded.pricing_definition,
    status='published',
    sort_order=excluded.sort_order,
    updated_at=now();

-- ── Quick Photo Session ──────────────────────────────────────────────
insert into commerce.products (
  tenant_id, slug, name, description, currency, availability, status, source_system, source_ref
)
select
  t.id,
  'photo-session',
  'Quick Photo Session',
  'A fast, no-fuss photo session at Quick Solution Café.',
  'ZAR',
  'available',
  'published',
  'quick_solution',
  'photo-session'
from public.tenants t
where t.slug='quick-solution'
  and not exists (
    select 1 from commerce.products p where p.tenant_id=t.id and p.slug='photo-session'
  );

update commerce.products p
set name='Quick Photo Session',
    description='A fast, no-fuss photo session at Quick Solution Café.',
    availability='available',
    status='published',
    source_system='quick_solution',
    source_ref='photo-session',
    updated_at=now()
from public.tenants t
where p.tenant_id=t.id and t.slug='quick-solution' and p.slug='photo-session';

insert into commerce.service_product_configs (
  tenant_id, product_id, source_key, customer_definition, pricing_version, pricing_definition, status, sort_order
)
select
  t.id,
  p.id,
  'photo-session',
  $cd${"id":"photo-session","name":"Quick Photo Session","shortName":"Photo Session","category":"Photo & Video","description":"A fast, no-fuss photo session at Quick Solution Café.","plainDescription":"Book the 30-minute session with 7 edited photos included. Other durations or extras are quoted before you book.","image":"/qs12/product-photography-video.webp","keywords":["photo session","quick photos","headshot","id photo","photography special"],"popular":true,"active":true,"serviceType":"media","channels":{"storefront":true,"guided":true,"pos":true,"quote":true,"advanced":false},"guidedJourneyId":"photo-session-guided","nextActionLabel":"Send request","pricing":{"strategy":"PHOTOGRAPHY_SESSION","sessions":{"30min-7edits":{"label":"30-minute session — 7 edited photos included","durationMinutes":30,"includedEdits":7,"price":449},"custom":{"label":"A different duration or scope","durationMinutes":null,"includedEdits":null,"price":null}},"extraEditRate":null,"deliverables":{}},"fields":[{"id":"session","type":"select","label":"Which session would you like?","shortLabel":"Session","default":"30min-7edits","options":[{"id":"30min-7edits","label":"30-minute session — 7 edited photos included"},{"id":"custom","label":"A different duration or scope — quote me"}]},{"id":"extraEdits","type":"number","label":"Extra edited photos beyond what is included?","shortLabel":"Extra edits","default":0,"min":0,"step":1},{"id":"preferredDate","type":"date","label":"Preferred date","shortLabel":"Preferred date","default":""},{"id":"preferredTime","type":"time","label":"Preferred start time","shortLabel":"Preferred time","default":""},{"id":"file","type":"file","label":"Reference / moodboard","help":"Optional. Upload an image or PDF reference if it helps explain the look you want."}]}$cd$::jsonb,
  '2026-09-qsc-14c',
  $pd${"strategy":"PHOTOGRAPHY_SESSION","sessions":{"30min-7edits":{"label":"30-minute session — 7 edited photos included","durationMinutes":30,"includedEdits":7,"price":449},"custom":{"label":"A different duration or scope","durationMinutes":null,"includedEdits":null,"price":null}},"extraEditRate":null,"deliverables":{}}$pd$::jsonb,
  'published',
  6
from public.tenants t
join commerce.products p on p.tenant_id=t.id and p.slug='photo-session'
where t.slug='quick-solution'
on conflict (tenant_id, source_key) do update
set product_id=excluded.product_id,
    customer_definition=excluded.customer_definition,
    pricing_version=excluded.pricing_version,
    pricing_definition=excluded.pricing_definition,
    status='published',
    sort_order=excluded.sort_order,
    updated_at=now();

commit;
