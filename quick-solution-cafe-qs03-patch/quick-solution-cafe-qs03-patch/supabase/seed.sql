insert into public.tenants (slug,name,status,settings)
select 'quick-solution','Joint X Quick Solution Café','active',
       '{"brand":"Joint X","location_code":"001","stage":"pilot"}'::jsonb
where not exists (select 1 from public.tenants where slug='quick-solution');

update public.tenants
set name='Joint X Quick Solution Café',
    status='active',
    settings = coalesce(settings,'{}'::jsonb) || '{"brand":"Joint X","location_code":"001","stage":"pilot"}'::jsonb
where slug='quick-solution';

insert into public.tenant_capabilities (tenant_id, capability_key, enabled, config)
select t.id, 'quick_solution', true,
       '{"storefront_catalog_source":"commerce","order_intake":"commerce.service_orders","opps_handoff":"pending"}'::jsonb
from public.tenants t
where t.slug='quick-solution'
  and not exists (
    select 1 from public.tenant_capabilities tc
    where tc.tenant_id=t.id and tc.capability_key='quick_solution'
  );

update public.tenant_capabilities tc
set enabled=true,
    config='{"storefront_catalog_source":"commerce","order_intake":"commerce.service_orders","opps_handoff":"pending"}'::jsonb,
    updated_at=now()
from public.tenants t
where tc.tenant_id=t.id
  and t.slug='quick-solution'
  and tc.capability_key='quick_solution';


insert into commerce.products (
  tenant_id, slug, name, description, currency, availability, status, source_system, source_ref
)
select t.id, 'pvc-banner', 'PVC Banner', 'Custom printed banners for shops, events and promotions.', 'ZAR', 'available', 'published',
       'quick_solution', 'pvc-banner'
from public.tenants t
where t.slug='quick-solution'
  and not exists (
    select 1 from commerce.products p
    where p.tenant_id=t.id and p.slug='pvc-banner'
  );

update commerce.products p
set name='PVC Banner',
    description='Custom printed banners for shops, events and promotions.',
    availability='available',
    status='published',
    source_system='quick_solution',
    source_ref='pvc-banner',
    updated_at=now()
from public.tenants t
where p.tenant_id=t.id
  and t.slug='quick-solution'
  and p.slug='pvc-banner';

insert into commerce.service_product_configs (
  tenant_id, product_id, source_key, customer_definition,
  pricing_version, pricing_definition, status, sort_order
)
select t.id, p.id, 'pvc-banner',
       '{"shortName":"Banner","category":"Signs & Large Format","description":"Custom printed banners for shops, events and promotions.","plainDescription":"Choose the size, finish and artwork help you need.","keywords":["banner","sign","vinyl","shop sign","event","large format"],"popular":true,"active":true,"channels":{"storefront":true,"guided":true,"pos":true,"quote":true},"guidedJourneyId":"banner-guided","nextActionLabel":"Continue to collection","pricing":{"strategy":"PER_AREA","baseRate":145,"minimumBillableArea":1,"unit":"m²"},"fields":[{"id":"width","type":"number","label":"How wide?","shortLabel":"Width","suffix":"metres","default":2,"min":0.1,"step":0.1,"required":true},{"id":"height","type":"number","label":"How high?","shortLabel":"Height","suffix":"metres","default":1,"min":0.1,"step":0.1,"required":true},{"id":"material","type":"select","label":"What should we print it on?","shortLabel":"Banner material","default":"standard","options":[{"id":"standard","label":"Standard PVC","helper":"Good for most indoor and outdoor jobs.","multiplier":1},{"id":"premium","label":"Premium PVC","helper":"A heavier option for a more substantial finish.","multiplier":1.25},{"id":"mesh","label":"Mesh banner","helper":"Useful where wind needs to pass through.","multiplier":1.35}]},{"id":"finishing","type":"select","label":"How should we finish the edges?","shortLabel":"Finishing","default":"hem-eyelets","options":[{"id":"none","label":"No finishing","fee":0},{"id":"eyelets","label":"Eyelets","helper":"Metal rings for tying or mounting.","fee":55},{"id":"hem","label":"Hemmed edges","helper":"Folded edges for extra strength.","fee":70},{"id":"hem-eyelets","label":"Hem + eyelets","helper":"Recommended for most outdoor banners.","fee":110}]},{"id":"artwork","type":"select","label":"What is happening with the design?","shortLabel":"Artwork","default":"ready","options":[{"id":"ready","label":"My artwork is ready","fee":0},{"id":"check","label":"Please check my artwork","fee":75},{"id":"design","label":"I need help with the design","fee":250}]},{"id":"turnaround","type":"select","label":"When do you need it?","default":"standard","options":[{"id":"standard","label":"Standard turnaround","multiplier":1},{"id":"express","label":"Express — where available","multiplier":1.2}]},{"id":"file","type":"file","label":"Artwork file","help":"Optional for now. PDF, JPG or PNG works best."}]}'::jsonb,
       '2026-09-qsc-03',
       '{"strategy":"PER_AREA","baseRate":145,"minimumBillableArea":1,"materials":{"standard":{"multiplier":1},"premium":{"multiplier":1.25},"mesh":{"multiplier":1.35}},"finishing":{"none":{"fee":0},"eyelets":{"fee":55},"hem":{"fee":70},"hem-eyelets":{"fee":110}},"artwork":{"ready":{"fee":0},"check":{"fee":75},"design":{"fee":250}},"turnaround":{"standard":{"multiplier":1},"express":{"multiplier":1.2}}}'::jsonb,
       'published', 10
from public.tenants t
join commerce.products p on p.tenant_id=t.id and p.slug='pvc-banner'
where t.slug='quick-solution'
on conflict (tenant_id, source_key) do update
set product_id=excluded.product_id,
    customer_definition=excluded.customer_definition,
    pricing_version=excluded.pricing_version,
    pricing_definition=excluded.pricing_definition,
    status='published',
    sort_order=excluded.sort_order,
    updated_at=now();


insert into commerce.products (
  tenant_id, slug, name, description, currency, availability, status, source_system, source_ref
)
select t.id, 'a4-print', 'Document Printing', 'Homework, CVs, forms and everyday documents.', 'ZAR', 'available', 'published',
       'quick_solution', 'a4-print'
from public.tenants t
where t.slug='quick-solution'
  and not exists (
    select 1 from commerce.products p
    where p.tenant_id=t.id and p.slug='a4-print'
  );

update commerce.products p
set name='Document Printing',
    description='Homework, CVs, forms and everyday documents.',
    availability='available',
    status='published',
    source_system='quick_solution',
    source_ref='a4-print',
    updated_at=now()
from public.tenants t
where p.tenant_id=t.id
  and t.slug='quick-solution'
  and p.slug='a4-print';

insert into commerce.service_product_configs (
  tenant_id, product_id, source_key, customer_definition,
  pricing_version, pricing_definition, status, sort_order
)
select t.id, p.id, 'a4-print',
       '{"shortName":"Documents","category":"Quick Print","description":"Homework, CVs, forms and everyday documents.","plainDescription":"Upload your file, choose copies and collect when ready.","keywords":["print","document","homework","school","cv","resume","form","pdf","a4","copy","photocopy"],"popular":true,"active":true,"channels":{"storefront":true,"guided":true,"pos":true,"quote":true},"guidedJourneyId":"document-guided","nextActionLabel":"Choose collection","pricing":{"strategy":"PER_PAGE"},"fields":[{"id":"file","type":"file","label":"Choose your document","help":"PDF is best. DOCX, JPG and PNG are also accepted."},{"id":"pages","type":"number","label":"How many pages are in the document?","shortLabel":"Pages","default":1,"min":1,"step":1,"required":true},{"id":"copies","type":"number","label":"How many copies do you need?","shortLabel":"Copies","default":1,"min":1,"step":1,"required":true},{"id":"printMode","type":"segmented","label":"How should we print it?","shortLabel":"Print colour","default":"bw","options":[{"id":"bw","label":"Black & white","helper":"Best for CVs, homework and forms.","rate":2},{"id":"colour","label":"Colour","helper":"Use when images or colour matter.","rate":7.5}]},{"id":"sides","type":"segmented","label":"Do you want printing on one side or both?","shortLabel":"Paper sides","default":"single","options":[{"id":"single","label":"One side","multiplier":1},{"id":"double","label":"Both sides","helper":"Uses less paper when suitable.","multiplier":0.95}]},{"id":"finish","type":"select","label":"Do you need anything else?","shortLabel":"Finish","default":"none","options":[{"id":"none","label":"Nothing else","fee":0},{"id":"staple","label":"Staple it","fee":2},{"id":"clear-sleeve","label":"Put it in a clear sleeve","fee":5}]}]}'::jsonb,
       '2026-09-qsc-03',
       '{"strategy":"PER_PAGE","rates":{"bw":{"rate":2},"colour":{"rate":7.5}},"sides":{"single":{"multiplier":1},"double":{"multiplier":0.95}},"finishes":{"none":{"fee":0},"staple":{"fee":2},"clear-sleeve":{"fee":5}}}'::jsonb,
       'published', 20
from public.tenants t
join commerce.products p on p.tenant_id=t.id and p.slug='a4-print'
where t.slug='quick-solution'
on conflict (tenant_id, source_key) do update
set product_id=excluded.product_id,
    customer_definition=excluded.customer_definition,
    pricing_version=excluded.pricing_version,
    pricing_definition=excluded.pricing_definition,
    status='published',
    sort_order=excluded.sort_order,
    updated_at=now();


insert into commerce.products (
  tenant_id, slug, name, description, currency, availability, status, source_system, source_ref
)
select t.id, 'business-cards', 'Business Cards', 'Professional cards with clear quantity-based pricing.', 'ZAR', 'available', 'published',
       'quick_solution', 'business-cards'
from public.tenants t
where t.slug='quick-solution'
  and not exists (
    select 1 from commerce.products p
    where p.tenant_id=t.id and p.slug='business-cards'
  );

update commerce.products p
set name='Business Cards',
    description='Professional cards with clear quantity-based pricing.',
    availability='available',
    status='published',
    source_system='quick_solution',
    source_ref='business-cards',
    updated_at=now()
from public.tenants t
where p.tenant_id=t.id
  and t.slug='quick-solution'
  and p.slug='business-cards';

insert into commerce.service_product_configs (
  tenant_id, product_id, source_key, customer_definition,
  pricing_version, pricing_definition, status, sort_order
)
select t.id, p.id, 'business-cards',
       '{"shortName":"Business cards","category":"Business Essentials","description":"Professional cards with clear quantity-based pricing.","plainDescription":"Choose quantity, stock and whether you need design help.","keywords":["business card","cards","company","startup","entrepreneur","brand"],"popular":true,"active":true,"channels":{"storefront":true,"guided":true,"pos":true,"quote":true},"guidedJourneyId":"business-card-guided","nextActionLabel":"Continue to collection","pricing":{"strategy":"TIERED"},"fields":[{"id":"quantity","type":"segmented","label":"How many cards do you need?","shortLabel":"Quantity","default":"100","options":[{"id":"100","label":"100","total":180},{"id":"250","label":"250","total":260},{"id":"500","label":"500","total":390},{"id":"1000","label":"1,000","total":650}]},{"id":"stock","type":"select","label":"What card feel do you want?","shortLabel":"Card stock","default":"standard","options":[{"id":"standard","label":"Standard premium stock","multiplier":1},{"id":"thick","label":"Extra-thick stock","multiplier":1.2}]},{"id":"finish","type":"select","label":"Do you want a special finish?","shortLabel":"Finish","default":"standard","options":[{"id":"standard","label":"Standard finish","fee":0},{"id":"matt","label":"Matt lamination","fee":90},{"id":"gloss","label":"Gloss lamination","fee":80}]},{"id":"artwork","type":"select","label":"Do you already have a design?","shortLabel":"Design","default":"ready","options":[{"id":"ready","label":"My design is ready","fee":0},{"id":"check","label":"Please check my design","fee":75},{"id":"design","label":"Design it for me","fee":250}]},{"id":"file","type":"file","label":"Design file","help":"Optional now. You can add it before checkout."}]}'::jsonb,
       '2026-09-qsc-03',
       '{"strategy":"TIERED","quantities":{"100":{"total":180},"250":{"total":260},"500":{"total":390},"1000":{"total":650}},"stock":{"standard":{"multiplier":1},"thick":{"multiplier":1.2}},"finishes":{"standard":{"fee":0},"matt":{"fee":90},"gloss":{"fee":80}},"artwork":{"ready":{"fee":0},"check":{"fee":75},"design":{"fee":250}}}'::jsonb,
       'published', 30
from public.tenants t
join commerce.products p on p.tenant_id=t.id and p.slug='business-cards'
where t.slug='quick-solution'
on conflict (tenant_id, source_key) do update
set product_id=excluded.product_id,
    customer_definition=excluded.customer_definition,
    pricing_version=excluded.pricing_version,
    pricing_definition=excluded.pricing_definition,
    status='published',
    sort_order=excluded.sort_order,
    updated_at=now();


insert into commerce.products (
  tenant_id, slug, name, description, currency, availability, status, source_system, source_ref
)
select t.id, 'printed-tshirt', 'Printed T-shirt', 'Bring your own garment or choose a Joint X blank.', 'ZAR', 'available', 'published',
       'quick_solution', 'printed-tshirt'
from public.tenants t
where t.slug='quick-solution'
  and not exists (
    select 1 from commerce.products p
    where p.tenant_id=t.id and p.slug='printed-tshirt'
  );

update commerce.products p
set name='Printed T-shirt',
    description='Bring your own garment or choose a Joint X blank.',
    availability='available',
    status='published',
    source_system='quick_solution',
    source_ref='printed-tshirt',
    updated_at=now()
from public.tenants t
where p.tenant_id=t.id
  and t.slug='quick-solution'
  and p.slug='printed-tshirt';

insert into commerce.service_product_configs (
  tenant_id, product_id, source_key, customer_definition,
  pricing_version, pricing_definition, status, sort_order
)
select t.id, p.id, 'printed-tshirt',
       '{"shortName":"T-shirt","category":"Clothing & Merch","description":"Bring your own garment or choose a Joint X blank.","plainDescription":"Choose the shirt, print size and quantity without print jargon.","keywords":["shirt","t-shirt","tshirt","clothing","merch","dtf","uniform"],"popular":true,"active":true,"channels":{"storefront":true,"guided":true,"pos":true,"quote":true},"guidedJourneyId":"tshirt-guided","nextActionLabel":"Continue to collection","pricing":{"strategy":"CONFIGURABLE"},"fields":[{"id":"quantity","type":"number","label":"How many shirts do you need?","shortLabel":"Quantity","default":1,"min":1,"step":1,"required":true},{"id":"garment","type":"select","label":"Which T-shirt should we use?","shortLabel":"T-shirt","default":"jointx-220","options":[{"id":"own","label":"I am bringing my own T-shirt","unitFee":0},{"id":"jointx-220","label":"Joint X premium T-shirt","helper":"220gsm","unitFee":95},{"id":"jointx-300","label":"Joint X heavyweight T-shirt","helper":"300gsm","unitFee":145}]},{"id":"frontPrint","type":"select","label":"How big should the front print be?","shortLabel":"Front print","default":"a4","options":[{"id":"none","label":"No front print","unitFee":0},{"id":"pocket","label":"Small / pocket size","unitFee":55},{"id":"a4","label":"Medium","helper":"About A4","unitFee":75},{"id":"a3","label":"Large","helper":"About A3","unitFee":95}]},{"id":"backPrint","type":"select","label":"Do you need a back print?","shortLabel":"Back print","default":"none","options":[{"id":"none","label":"No back print","unitFee":0},{"id":"a4","label":"Medium","helper":"About A4","unitFee":75},{"id":"a3","label":"Large","helper":"About A3","unitFee":95}]},{"id":"artwork","type":"select","label":"What is happening with the artwork?","shortLabel":"Artwork","default":"ready","options":[{"id":"ready","label":"My artwork is ready","fee":0},{"id":"check","label":"Please check my artwork","fee":75},{"id":"design","label":"I need help with the design","fee":250}]},{"id":"file","type":"file","label":"Artwork file","help":"PNG with a transparent background is ideal."}]}'::jsonb,
       '2026-09-qsc-03',
       '{"strategy":"CONFIGURABLE","garments":{"own":{"unitFee":0},"jointx-220":{"unitFee":95},"jointx-300":{"unitFee":145}},"frontPrint":{"none":{"unitFee":0},"pocket":{"unitFee":55},"a4":{"unitFee":75},"a3":{"unitFee":95}},"backPrint":{"none":{"unitFee":0},"a4":{"unitFee":75},"a3":{"unitFee":95}},"artwork":{"ready":{"fee":0},"check":{"fee":75},"design":{"fee":250}}}'::jsonb,
       'published', 40
from public.tenants t
join commerce.products p on p.tenant_id=t.id and p.slug='printed-tshirt'
where t.slug='quick-solution'
on conflict (tenant_id, source_key) do update
set product_id=excluded.product_id,
    customer_definition=excluded.customer_definition,
    pricing_version=excluded.pricing_version,
    pricing_definition=excluded.pricing_definition,
    status='published',
    sort_order=excluded.sort_order,
    updated_at=now();


insert into commerce.fulfilment_points (
  tenant_id, slug, name, kind, status, address, contact_phone,
  collection_enabled, dropoff_enabled, services, fee_amount, sort_order
)
select t.id, 'location-001', 'Quick Solution Café · Location 001', 'cafe', 'active',
       '{}'::jsonb, '+27754534646', true, true,
       array['print','signage','apparel','business-services'], 0, 10
from public.tenants t
where t.slug='quick-solution'
on conflict (tenant_id, slug) do update
set name=excluded.name,
    kind=excluded.kind,
    status=excluded.status,
    contact_phone=excluded.contact_phone,
    collection_enabled=true,
    dropoff_enabled=true,
    services=excluded.services,
    fee_amount=0,
    sort_order=10,
    updated_at=now();
