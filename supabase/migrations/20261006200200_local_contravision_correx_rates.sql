-- Owner-confirmed local cost and approved Correx A0 allowance. Staging model.
begin;

create or replace function commerce.qs_calculate_price(p_tenant_id uuid, p_product_key text, p_configuration jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $function$
declare
  v_result jsonb;
  v_width numeric;
  v_height numeric;
  v_lines jsonb;
  v_quantity numeric;
begin
  if trim(p_product_key)='correx-boards' then
    begin
      v_quantity := coalesce((p_configuration->>'quantity')::numeric,1);
    exception when others then
      raise exception using errcode='22023',message='Enter a whole number of boards between 1 and 10000.';
    end;
    if v_quantity<1 or v_quantity>10000 or v_quantity<>trunc(v_quantity) then
      raise exception using errcode='22023',message='Enter a whole number of boards between 1 and 10000.';
    end if;
    if coalesce(p_configuration->>'sides','single')<>'single'
       or coalesce(p_configuration->>'mounting','none')<>'none'
       or coalesce(p_configuration->>'installation','supply')<>'supply'
       or p_configuration ?| array['width','height','size'] then
      raise exception using errcode='22023',message='Custom sizes, double sides and mounting need a Shop Signs quote.';
    end if;
  end if;
  if trim(p_product_key)='contravision' then
    begin
      v_width := (p_configuration->>'width')::numeric;
      v_height := (p_configuration->>'height')::numeric;
    exception when others then
      raise exception using errcode='22023',message='Enter valid width and height.';
    end;
    if v_width is null or v_height is null or v_width<0.1 or v_height<0.1 or v_width>20 or v_height>20 then
      raise exception using errcode='22023',message='Width and height must be between 0.1 and 20 metres.';
    end if;
    if coalesce(p_configuration->>'finishing','print-only') <> 'print-only'
       or coalesce(p_configuration->>'installation','supply') <> 'supply' then
      raise exception using errcode='22023',message='Installation or shaped finishing needs a separate quote.';
    end if;
  end if;
  v_result := commerce.qs_calculate_price_catalogue_base(p_tenant_id,p_product_key,p_configuration);
  if v_result->'snapshot'->>'pricingStrategy'='ENQUIRY'
     and v_result->'metrics'->>'serviceType'='print-signage' then
    v_lines := jsonb_build_array(
      jsonb_build_object('label','Service request','text','Print / signage requirements captured'),
      jsonb_build_object('label','Pricing','text','Confirmed after specifications and fulfilment review')
    );
    v_result := jsonb_set(v_result,'{lines}',v_lines);
    v_result := jsonb_set(v_result,'{snapshot,calculation,lines}',v_lines);
  end if;
  return v_result;
end $function$;

update commerce.service_product_configs c set
 customer_definition='{"id":"contravision","name":"Contravision Window Printing","shortName":"Contravision","category":"Signs & Large Format","description":"Full-colour perforated window vinyl, supplied as a rectangular print for one panel.","plainDescription":"Enter one panel’s width and height. Print only, minimum 1 m² billed. Shaped trimming and installation need a separate quote.","active":true,"popular":false,"keywords":["contravision","window branding","one way vision"],"channels":{"storefront":true,"guided":true,"pos":true,"quote":true},"guidedJourneyId":"contravision-guided","nextActionLabel":"Continue to collection","pricingVersion":"2026-10-contravision-local-02","pricing":{"strategy":"PER_AREA","baseRate":300,"minimumBillableArea":1,"unit":"m²"},"fields":[{"id":"width","type":"number","label":"Finished width","suffix":"metres","default":1,"min":0.1,"max":20,"step":0.01,"required":true},{"id":"height","type":"number","label":"Finished height","suffix":"metres","default":1,"min":0.1,"max":20,"step":0.01,"required":true},{"id":"material","type":"select","label":"Material","default":"standard","options":[{"id":"standard","label":"Perforated one-way-vision vinyl","multiplier":1}]},{"id":"finishing","type":"select","label":"Supply format","default":"print-only","options":[{"id":"print-only","label":"Rectangular print only — no fitting","fee":0}]},{"id":"artwork","type":"select","label":"What about the design?","default":"ready","options":[{"id":"ready","label":"My artwork is ready","fee":0},{"id":"check","label":"Please check my artwork","fee":75},{"id":"design","label":"I need design help","fee":250}]},{"id":"turnaround","type":"select","label":"Turnaround","default":"standard","options":[{"id":"standard","label":"Standard — timing confirmed after artwork review","multiplier":1}]},{"id":"file","type":"file","label":"Artwork or reference","help":"Upload a PDF, image or photo of the installation area."}],"productPage":{"headline":"Print your window branding","intro":"Print only. Vehicle contour cutting, fitting and installation are quoted separately.","showStartingPrice":true},"media":{"hero":"/qs-catalogue/contravision-v1.webp","gallery":[]}}'::jsonb,
 pricing_definition='{"strategy":"PER_AREA","baseRate":300,"minimumBillableArea":1,"materials":{"standard":{"multiplier":1}},"finishing":{"print-only":{"fee":0}},"artwork":{"ready":{"fee":0},"check":{"fee":75},"design":{"fee":250}},"turnaround":{"standard":{"multiplier":1}}}'::jsonb,
 pricing_version='2026-10-contravision-local-02',
 operations_definition=coalesce(c.operations_definition,'{}'::jsonb)-'sourceUrl' || '{"sourceName":"Owner-confirmed local merchant (name pending)","checkedAt":"2026-10-06","supplierCost":150,"vatBasis":"no_supplier_vat","vatRate":0,"costBasis":150,"marginRate":0.5,"modelRate":300,"model":"supplier cost / (1 - gross margin)","supplierPriceConfirmed":true,"supplierTermsConfirmed":false,"rollout":"staging-model","scope":"R150/m² and no supplier VAT confirmed by owner. Rectangular print only; no fitting, shaped trimming or protective laminate assumed. 1m² minimum is Café policy. Merchant name, usable panel width, lead time, minimum and collection/freight arrangements remain to be recorded."}'::jsonb,
 updated_at=now()
from public.tenants t where c.tenant_id=t.id and t.slug='quick-solution' and c.source_key='contravision';
update commerce.products p set description='Full-colour perforated window vinyl, supplied as a rectangular print for one panel.',updated_at=now()
from public.tenants t where p.tenant_id=t.id and t.slug='quick-solution' and p.slug='contravision';

update commerce.service_product_configs c set
 customer_definition='{"id":"correx-boards","name":"Correx Boards","shortName":"Correx","category":"Signs & Large Format","description":"Single-sided printed Correx boards for notices, directions and promotions.","plainDescription":"Choose a standard size and quantity. Single-sided print, board only. Custom sizes, double-sided printing, eyelets and mounting need a Shop Signs quote.","active":true,"popular":false,"keywords":["correx","boards","signs"],"channels":{"storefront":true,"guided":true,"advanced":true,"pos":false,"quote":true},"guidedJourneyId":"correx-boards-guided","nextActionLabel":"Continue to collection","pricingVersion":"2026-10-correx-local-02","pricing":{"strategy":"SUPPLIER_MARGIN","minQuantity":1,"variants":{"a3":{"label":"A3 · 297 × 420 mm · single-sided, unmounted","price":87.5},"a2":{"label":"A2 · 420 × 594 mm · single-sided, unmounted","price":175},"a1":{"label":"A1 · 594 × 841 mm · single-sided, unmounted","price":350},"a0":{"label":"A0 · 841 × 1189 mm · single-sided, unmounted","price":700}},"accessories":{},"artwork":{"ready":{"label":"Print-ready artwork","fee":0},"check":{"label":"Artwork check","fee":75},"design":{"label":"Design help","fee":250}}},"fields":[{"id":"variant","type":"select","label":"Board size","default":"a3","options":[{"id":"a3","label":"A3 · 297 × 420 mm"},{"id":"a2","label":"A2 · 420 × 594 mm"},{"id":"a1","label":"A1 · 594 × 841 mm"},{"id":"a0","label":"A0 · 841 × 1189 mm"}]},{"id":"quantity","type":"number","label":"How many?","default":1,"min":1,"max":10000,"step":1,"required":true},{"id":"artwork","type":"select","label":"What about the design?","default":"ready","options":[{"id":"ready","label":"My artwork is ready"},{"id":"check","label":"Please check my artwork"},{"id":"design","label":"I need design help"}]},{"id":"brief","type":"textarea","label":"Anything we should know?","placeholder":"Intended use, deadline, measurements or finishing requirements."},{"id":"file","type":"file","label":"Artwork or reference","help":"Upload a PDF, image or photo of the installation area."}],"productPage":{"headline":"Choose your Correx board","intro":"Standard sizes, single-sided printing, supplied without mounting. Ask for a Shop Signs quote for custom sizes, double sides or fitting.","showStartingPrice":true},"media":{"hero":"/qs-catalogue/correx-boards-v1.webp","gallery":[]}}'::jsonb,
 pricing_definition='{"strategy":"SUPPLIER_MARGIN","marginRate":0.5,"minQuantity":1,"sourceName":"Owner-approved A0 cost allowance; local merchant name pending","defaultPricingMode":"cost_margin","vatBasis":"excl_vat","vatRate":0,"variants":{"a3":{"label":"A3 · 297 × 420 mm · single-sided, unmounted","pricingMode":"cost_margin","supplierCost":43.75,"referencePrice":43.75},"a2":{"label":"A2 · 420 × 594 mm · single-sided, unmounted","pricingMode":"cost_margin","supplierCost":87.5,"referencePrice":87.5},"a1":{"label":"A1 · 594 × 841 mm · single-sided, unmounted","pricingMode":"cost_margin","supplierCost":175,"referencePrice":175},"a0":{"label":"A0 · 841 × 1189 mm · single-sided, unmounted","pricingMode":"cost_margin","supplierCost":350,"referencePrice":350}},"accessories":{},"artwork":{"ready":{"label":"Print-ready artwork","fee":0},"check":{"label":"Artwork check","fee":75},"design":{"label":"Design help","fee":250}}}'::jsonb,
 pricing_version='2026-10-correx-local-02',
 operations_definition=coalesce(c.operations_definition,'{}'::jsonb)-'sourceUrl' || '{"sourceName":"Same owner-referenced local merchant (name pending)","checkedAt":"2026-10-06","reportedA0Price":200,"reportedA0PriceConfirmed":false,"a0CostAllowance":350,"vatBasis":"owner_cost_allowance_no_vat_uplift","marginRate":0.5,"derivedCostAllowances":{"a3":43.75,"a2":87.5,"a1":175,"a0":350},"model":"A0 cost allowance / 2^(paper-size index), then / (1 - gross margin)","rollout":"owner-approved-staging-model","supplierPriceConfirmed":false,"scope":"Owner directed R350 A0 cost allowance despite tentative R200 supplier recollection. Other sizes are derived internal allowances, not merchant quotations. Single-sided print, unmounted. Confirm thickness, cut yield, minimums and fulfilment. Custom sizes/double sides/eyelets/installation require the Shop Signs quote flow."}'::jsonb,
 updated_at=now()
from public.tenants t where c.tenant_id=t.id and t.slug='quick-solution' and c.source_key='correx-boards';
update commerce.products p set description='Single-sided printed Correx boards for notices, directions and promotions.',updated_at=now()
from public.tenants t where p.tenant_id=t.id and t.slug='quick-solution' and p.slug='correx-boards';

update commerce.service_product_configs c set
 customer_definition='{"id":"rigid-signage","name":"Shop Signs & Rigid Signage","shortName":"Shop Signs & Rigid Signage","category":"Signs & Large Format","description":"Configure a printed sign, frame and installation request.","plainDescription":"Configure a printed sign, frame and installation request. Configure your request; we confirm the quote before payment.","keywords":["rigid signage","shop signs & rigid signage"],"active":true,"popular":false,"serviceType":"print-signage","channels":{"storefront":true,"guided":true,"advanced":false,"pos":false,"quote":true},"guidedJourneyId":"rigid-signage-guided","nextActionLabel":"Request a quote","pricingVersion":"2026-10-catalogue-01","pricing":{"strategy":"ENQUIRY","quoteRequired":true},"fields":[{"id":"material","type":"select","label":"Sign material","default":"unsure","options":[{"id":"unsure","label":"Recommend the right material"},{"id":"correx","label":"Correx — custom size, double-sided or mounting"},{"id":"chromadek","label":"Chromadek steel"},{"id":"acm","label":"Aluminium composite"},{"id":"abs","label":"ABS plastic"},{"id":"pvc-frame","label":"Stretched PVC on a frame"}]},{"id":"width","type":"number","label":"Finished width","suffix":"metres","default":1,"min":0.1,"max":20,"step":0.01,"required":true},{"id":"height","type":"number","label":"Finished height","suffix":"metres","default":1,"min":0.1,"max":20,"step":0.01,"required":true},{"id":"quantity","type":"number","label":"How many?","default":1,"min":1,"max":10000,"step":1,"required":true},{"id":"frame","type":"select","label":"Frame","default":"none","options":[{"id":"none","label":"No frame"},{"id":"steel","label":"Steel frame"},{"id":"aluminium","label":"Aluminium frame"},{"id":"unsure","label":"Please advise"}]},{"id":"installation","type":"select","label":"Installation","default":"supply","options":[{"id":"supply","label":"Supply only"},{"id":"install","label":"Install for me — quote after checking site"}]},{"id":"site","type":"textarea","label":"Installation site / area","placeholder":"Area, wall or fence, mounting height and access. Add a photo below."},{"id":"artwork","type":"select","label":"What about the design?","default":"ready","options":[{"id":"ready","label":"My artwork is ready"},{"id":"check","label":"Please check my artwork"},{"id":"design","label":"I need design help"}]},{"id":"brief","type":"textarea","label":"Anything we should know?","placeholder":"Intended use, deadline, measurements or finishing requirements."},{"id":"file","type":"file","label":"Artwork or reference","help":"Upload a PDF, image or photo of the installation area."}],"productPage":{"headline":"Shop Signs & Rigid Signage","intro":"Configure a printed sign, frame and installation request.","showStartingPrice":false}}'::jsonb,
 pricing_definition='{"strategy":"ENQUIRY","quoteRequired":true,"serviceType":"print-signage"}'::jsonb,
 pricing_version='2026-10-catalogue-01',
 
 updated_at=now()
from public.tenants t where c.tenant_id=t.id and t.slug='quick-solution' and c.source_key='rigid-signage';
update commerce.products p set description='Configure a printed sign, frame and installation request.',updated_at=now()
from public.tenants t where p.tenant_id=t.id and t.slug='quick-solution' and p.slug='rigid-signage';

update commerce.service_product_configs c set customer_definition=jsonb_set(customer_definition,'{media}','{"hero":"/qs-catalogue/flyers-v1.webp","gallery":[]}'::jsonb), updated_at=now() from public.tenants t where c.tenant_id=t.id and t.slug='quick-solution' and c.source_key='flyers';

update commerce.service_product_configs c set customer_definition=jsonb_set(customer_definition,'{media}','{"hero":"/qs-catalogue/pull-up-banners-v1.webp","gallery":[]}'::jsonb), updated_at=now() from public.tenants t where c.tenant_id=t.id and t.slug='quick-solution' and c.source_key='pull-up-banners';

commit;
