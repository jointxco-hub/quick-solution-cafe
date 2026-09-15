-- QS-11: add Vinyl Stickers & Labels to the Quick Solution service catalogue.
-- Pricing deliberately derives the current base area rate from PVC Banner so
-- Vinyl starts at the same per-m² rate. Print + cut adds a flat R100.

begin;

do $qs11_preflight$
begin
  if not exists (
    select 1
    from public.tenants t
    join commerce.service_product_configs c on c.tenant_id=t.id
    where t.slug='quick-solution'
      and c.source_key='pvc-banner'
      and c.status='published'
  ) then
    raise exception 'QS11 prerequisite missing: published Quick Solution PVC Banner config';
  end if;
end
$qs11_preflight$;

insert into commerce.products (
  tenant_id, slug, name, description, currency, availability, status, source_system, source_ref
)
select
  t.id,
  'vinyl-stickers',
  'Vinyl Stickers & Labels',
  'Custom vinyl for bottles, packaging, windows and everyday business branding.',
  'ZAR',
  'available',
  'published',
  'quick_solution',
  'vinyl-stickers'
from public.tenants t
where t.slug='quick-solution'
  and not exists (
    select 1 from commerce.products p
    where p.tenant_id=t.id and p.slug='vinyl-stickers'
  );

update commerce.products p
set name='Vinyl Stickers & Labels',
    description='Custom vinyl for bottles, packaging, windows and everyday business branding.',
    availability='available',
    status='published',
    source_system='quick_solution',
    source_ref='vinyl-stickers',
    updated_at=now()
from public.tenants t
where p.tenant_id=t.id
  and t.slug='quick-solution'
  and p.slug='vinyl-stickers';

with pvc as (
  select
    t.id as tenant_id,
    coalesce((c.pricing_definition->>'baseRate')::numeric, 350) as base_rate,
    coalesce((c.pricing_definition->>'minimumBillableArea')::numeric, 1) as min_area
  from public.tenants t
  join commerce.service_product_configs c on c.tenant_id=t.id
  where t.slug='quick-solution'
    and c.source_key='pvc-banner'
    and c.status='published'
  limit 1
)
insert into commerce.service_product_configs (
  tenant_id,
  product_id,
  source_key,
  customer_definition,
  pricing_version,
  pricing_definition,
  status,
  sort_order
)
select
  pvc.tenant_id,
  p.id,
  'vinyl-stickers',
  jsonb_build_object(
    'id','vinyl-stickers',
    'name','Vinyl Stickers & Labels',
    'shortName','Vinyl stickers',
    'category','Brand & Packaging',
    'description','Custom vinyl for bottles, packaging, windows and everyday business branding.',
    'plainDescription','Choose the size, print-only or print-and-cut, and upload your artwork.',
    'image','/qs11/product-vinyl.webp',
    'keywords',jsonb_build_array('vinyl','sticker','stickers','label','labels','bottle','packaging','perfume','food','product branding'),
    'popular',true,
    'active',true,
    'channels',jsonb_build_object('storefront',true,'guided',true,'pos',true,'quote',true),
    'guidedJourneyId','vinyl-guided',
    'nextActionLabel','Continue to collection',
    'pricing',jsonb_build_object('strategy','PER_AREA','baseRate',pvc.base_rate,'minimumBillableArea',pvc.min_area,'unit','m²'),
    'fields',jsonb_build_array(
      jsonb_build_object('id','width','type','number','label','How wide is the printed area?','shortLabel','Width','suffix','metres','default',1,'min',0.05,'step',0.05,'required',true),
      jsonb_build_object('id','height','type','number','label','How high is the printed area?','shortLabel','Height','suffix','metres','default',1,'min',0.05,'step',0.05,'required',true),
      jsonb_build_object('id','material','type','select','label','Vinyl type','shortLabel','Material','default','standard','options',jsonb_build_array(
        jsonb_build_object('id','standard','label','White self-adhesive vinyl','helper','A versatile choice for bottles, packaging, windows and smooth surfaces.','multiplier',1)
      )),
      jsonb_build_object('id','finishing','type','segmented','label','How should we finish it?','shortLabel','Finish','default','print-only','options',jsonb_build_array(
        jsonb_build_object('id','print-only','label','Print only','helper','Supplied as printed vinyl.','fee',0),
        jsonb_build_object('id','print-cut','label','Print + cut','helper','We cut the stickers / labels for you.','fee',100)
      )),
      jsonb_build_object('id','artwork','type','select','label','What is happening with the design?','shortLabel','Artwork','default','ready','options',jsonb_build_array(
        jsonb_build_object('id','ready','label','My artwork is ready','fee',0),
        jsonb_build_object('id','check','label','Please check my artwork','fee',75),
        jsonb_build_object('id','design','label','I need help with the design','fee',250)
      )),
      jsonb_build_object('id','turnaround','type','select','label','When do you need it?','default','standard','options',jsonb_build_array(
        jsonb_build_object('id','standard','label','Standard turnaround','multiplier',1),
        jsonb_build_object('id','express','label','Express — where available','multiplier',1.2)
      )),
      jsonb_build_object('id','file','type','file','label','Artwork file','help','PDF or transparent PNG is ideal. We can confirm cut lines before production.')
    )
  ),
  '2026-09-qsc-04',
  jsonb_build_object(
    'strategy','PER_AREA',
    'baseRate',pvc.base_rate,
    'minimumBillableArea',pvc.min_area,
    'materials',jsonb_build_object('standard',jsonb_build_object('multiplier',1)),
    'finishing',jsonb_build_object(
      'print-only',jsonb_build_object('fee',0),
      'print-cut',jsonb_build_object('fee',100)
    ),
    'artwork',jsonb_build_object(
      'ready',jsonb_build_object('fee',0),
      'check',jsonb_build_object('fee',75),
      'design',jsonb_build_object('fee',250)
    ),
    'turnaround',jsonb_build_object(
      'standard',jsonb_build_object('multiplier',1),
      'express',jsonb_build_object('multiplier',1.2)
    )
  ),
  'published',
  15
from pvc
join commerce.products p on p.tenant_id=pvc.tenant_id and p.slug='vinyl-stickers'
on conflict (tenant_id, source_key) do update
set product_id=excluded.product_id,
    customer_definition=excluded.customer_definition,
    pricing_version=excluded.pricing_version,
    pricing_definition=excluded.pricing_definition,
    status='published',
    sort_order=excluded.sort_order,
    updated_at=now();

commit;
