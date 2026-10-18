-- Supplier catalogue expansion. Verified on Joint X XOS Staging only.
-- Additive: existing product rows and pricing are preserved.
begin;

CREATE OR REPLACE FUNCTION commerce.qs_calculate_price_catalogue_base(p_tenant_id uuid, p_product_key text, p_configuration jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_product_id uuid;
  v_product_name text;
  v_pricing_version text;
  v_pricing jsonb;
  v_strategy text;
  v_configuration jsonb := p_configuration;
begin
  if p_configuration is null or jsonb_typeof(p_configuration) is distinct from 'object' then
    raise exception using errcode = '22023', message = 'Configuration must be a JSON object.';
  end if;

  select p.id, p.name, c.pricing_version, c.pricing_definition
    into v_product_id, v_product_name, v_pricing_version, v_pricing
  from commerce.service_product_configs c
  join commerce.products p
    on p.id = c.product_id
   and p.tenant_id = c.tenant_id
  where c.tenant_id = p_tenant_id
    and c.source_key = trim(p_product_key)
    and c.status = 'published'
    and p.status = 'published'
    and p.availability = 'available'
  limit 1;

  if v_product_id is null then
    raise exception using errcode = '22023', message = 'Product is not available.';
  end if;

  v_strategy := upper(coalesce(v_pricing->>'strategy', ''));

  if trim(p_product_key) = 'a4-print' and v_strategy = 'PER_PAGE' then
    v_configuration := commerce.qs_normalize_document_configuration(p_configuration);
  end if;

  if v_strategy = 'ENQUIRY' then
    return jsonb_build_object(
      'productId', v_product_id,
      'productKey', trim(p_product_key),
      'productName', v_product_name,
      'total', 0,
      'summary', 'Quote after review',
      'lines', jsonb_build_array(
        jsonb_build_object('label','Service request','text','Photo / video brief captured'),
        jsonb_build_object('label','Pricing','text','Confirmed after crew, location and scope review')
      ),
      'metrics', jsonb_build_object(
        'quoteRequired', true,
        'serviceType', coalesce(v_pricing->>'serviceType','service')
      ),
      'snapshot', jsonb_build_object(
        'pricingVersion', v_pricing_version,
        'productKey', trim(p_product_key),
        'productName', v_product_name,
        'pricingStrategy', v_strategy,
        'configuration', v_configuration,
        'pricingDefinition', v_pricing,
        'calculation', jsonb_build_object(
          'lines', jsonb_build_array(
            jsonb_build_object('label','Service request','text','Photo / video brief captured'),
            jsonb_build_object('label','Pricing','text','Confirmed after crew, location and scope review')
          ),
          'metrics', jsonb_build_object('quoteRequired',true),
          'total', 0
        ),
        'capturedAt', now()
      )
    );
  end if;

  if v_strategy = 'SUPPLIER_MARGIN' then
    declare
      v_variant_id text;
      v_variant jsonb;
      v_quantity integer;
      v_min_quantity integer;
      v_quantity_step integer;
      v_margin numeric;
      v_reference numeric;
      v_unit_selling numeric := 0;
      v_variant_total numeric;
      v_accessories_total numeric := 0;
      v_accessory_ids jsonb;
      v_accessory_id text;
      v_accessory jsonb;
      v_acc_reference numeric;
      v_acc_selling numeric;
      v_acc_compatible jsonb;
      v_artwork_id text;
      v_artwork jsonb;
      v_artwork_fee numeric := 0;
      v_quote_required boolean := false;
      v_lines jsonb := '[]'::jsonb;
    begin
      v_variant_id := nullif(trim(coalesce(v_configuration->>'variant','')), '');
      if v_variant_id is null or not coalesce((v_pricing->'variants') ? v_variant_id, false) then
        raise exception using errcode = '22023', message = 'Choose a valid option.';
      end if;
      v_variant := v_pricing->'variants'->v_variant_id;

      -- Per-variant minQuantity/quantityStep override the product-level
      -- default (e.g. single-sided flags: minQuantity 2, step 2 - "must
      -- be bought in pairs of 2"). A variant with no override falls back
      -- to the product default (minQuantity 1, step 1 unless set).
      v_min_quantity := greatest(coalesce(
        (v_variant->>'minQuantity')::integer,
        (v_pricing->>'minQuantity')::integer,
        1
      ), 1);
      v_quantity_step := greatest(coalesce((v_variant->>'quantityStep')::integer, 1), 1);

      begin
        v_quantity := coalesce((v_configuration->>'quantity')::integer, v_min_quantity);
      exception when others then
        raise exception using errcode = '22023', message = 'Quantity must be a whole number.';
      end;
      if v_quantity < v_min_quantity then
        raise exception using errcode = '22023', message = format('Minimum quantity for this option is %s.', v_min_quantity);
      end if;
      if v_quantity > 500 then
        raise exception using errcode = '22023', message = 'Quantity is outside the supported range.';
      end if;
      if v_quantity_step > 1 and mod(v_quantity - v_min_quantity, v_quantity_step) <> 0 then
        raise exception using errcode = '22023',
          message = format('This option must be ordered in multiples of %s (minimum %s).', v_quantity_step, v_min_quantity);
      end if;

      v_margin := coalesce((v_pricing->>'marginRate')::numeric, 0.5);
      if v_margin < 0 or v_margin >= 1 then
        raise exception using errcode = '22023', message = 'Pricing configuration is invalid.';
      end if;

      v_reference := nullif(v_variant->>'referencePrice','')::numeric;
      if v_reference is null then
        v_quote_required := true;
      else
        v_unit_selling := round(v_reference / (1 - v_margin), 2);
      end if;
      v_variant_total := v_unit_selling * v_quantity;

      v_accessory_ids := coalesce(v_configuration->'accessories', '[]'::jsonb);
      if jsonb_typeof(v_accessory_ids) is distinct from 'array' then
        raise exception using errcode = '22023', message = 'Accessory selection is invalid.';
      end if;

      for v_accessory_id in select jsonb_array_elements_text(v_accessory_ids) loop
        if not coalesce((v_pricing->'accessories') ? v_accessory_id, false) then
          raise exception using errcode = '22023', message = 'One or more accessories are invalid.';
        end if;
        v_accessory := v_pricing->'accessories'->v_accessory_id;

        -- compatibleVariants: an explicit allow-list of variant ids this
        -- accessory may be paired with (e.g. a wall/wheely-bag sized for
        -- one gazebo frame size only). Omitted or empty means universal
        -- - matches the Flags accessories, which the source document
        -- shows shared across every flag design/size/kit combination.
        v_acc_compatible := v_accessory->'compatibleVariants';
        if v_acc_compatible is not null
           and jsonb_typeof(v_acc_compatible) = 'array'
           and jsonb_array_length(v_acc_compatible) > 0
           and not (v_acc_compatible ? v_variant_id)
        then
          raise exception using errcode = '22023',
            message = format('%s is not available for the selected option.', coalesce(v_accessory->>'label', v_accessory_id));
        end if;

        v_acc_reference := nullif(v_accessory->>'referencePrice','')::numeric;
        if v_acc_reference is null then
          v_quote_required := true;
        else
          v_acc_selling := round(v_acc_reference / (1 - v_margin), 2);
          v_accessories_total := v_accessories_total + v_acc_selling;
          v_lines := v_lines || jsonb_build_array(
            jsonb_build_object('label', coalesce(v_accessory->>'label', v_accessory_id), 'value', v_acc_selling)
          );
        end if;
      end loop;

      v_artwork_id := nullif(trim(coalesce(v_configuration->>'artwork','')), '');
      if v_artwork_id is not null then
        if not coalesce((v_pricing->'artwork') ? v_artwork_id, false) then
          raise exception using errcode = '22023', message = 'Artwork option is invalid.';
        end if;
        v_artwork := v_pricing->'artwork'->v_artwork_id;
        v_artwork_fee := nullif(v_artwork->>'fee','')::numeric;
        if v_artwork_fee is null then
          v_quote_required := true;
          v_artwork_fee := 0;
        elsif v_artwork_fee > 0 then
          v_lines := v_lines || jsonb_build_array(
            jsonb_build_object('label', coalesce(v_artwork->>'label', v_artwork_id), 'value', v_artwork_fee)
          );
        end if;
      end if;

      if v_quote_required then
        return jsonb_build_object(
          'productId', v_product_id,
          'productKey', trim(p_product_key),
          'productName', v_product_name,
          'total', 0,
          'summary', 'Quote required',
          'lines', jsonb_build_array(jsonb_build_object('label','Pricing','text','One or more selected options need a quote')),
          'metrics', jsonb_build_object('quoteRequired', true, 'quantity', v_quantity),
          'snapshot', jsonb_build_object(
            'pricingVersion', v_pricing_version,
            'productKey', trim(p_product_key),
            'productName', v_product_name,
            'pricingStrategy', v_strategy,
            'configuration', v_configuration,
            'pricingDefinition', v_pricing,
            'calculation', jsonb_build_object('lines', '[]'::jsonb, 'metrics', jsonb_build_object('quoteRequired',true), 'total', 0),
            'capturedAt', now()
          )
        );
      end if;

      v_lines := jsonb_build_array(
        jsonb_build_object('label', coalesce(v_variant->>'label', v_variant_id), 'value', round(v_variant_total,2))
      ) || v_lines;

      return jsonb_build_object(
        'productId', v_product_id,
        'productKey', trim(p_product_key),
        'productName', v_product_name,
        'total', round(v_variant_total + v_accessories_total + v_artwork_fee, 2),
        'summary', coalesce(v_variant->>'label', v_variant_id) || ' × ' || v_quantity::text,
        'lines', v_lines,
        'metrics', jsonb_build_object('quantity', v_quantity, 'unitPrice', v_unit_selling, 'quoteRequired', false),
        'snapshot', jsonb_build_object(
          'pricingVersion', v_pricing_version,
          'productKey', trim(p_product_key),
          'productName', v_product_name,
          'pricingStrategy', v_strategy,
          'configuration', v_configuration,
          'pricingDefinition', v_pricing,
          'calculation', jsonb_build_object(
            'lines', v_lines,
            'metrics', jsonb_build_object('quantity',v_quantity,'quoteRequired',false),
            'total', round(v_variant_total + v_accessories_total + v_artwork_fee, 2)
          ),
          'capturedAt', now()
        )
      );
    end;
  end if;

  if v_strategy = 'PHOTOGRAPHY_SESSION' then
    declare
      v_session_id text;
      v_session jsonb;
      v_extra_edits integer;
      v_extra_edit_rate numeric;
      v_deliverable_ids jsonb;
      v_deliverable_id text;
      v_deliverable jsonb;
      v_deliverable_price numeric;
      v_quote_required boolean := false;
      v_total numeric := 0;
      v_lines jsonb := '[]'::jsonb;
      v_session_price numeric;
    begin
      v_session_id := coalesce(nullif(trim(coalesce(v_configuration->>'session','')), ''), '30min-7edits');
      if not coalesce((v_pricing->'sessions') ? v_session_id, false) then
        raise exception using errcode = '22023', message = 'Choose a valid session option.';
      end if;
      v_session := v_pricing->'sessions'->v_session_id;

      begin
        v_extra_edits := greatest(coalesce((v_configuration->>'extraEdits')::integer, 0), 0);
      exception when others then
        raise exception using errcode = '22023', message = 'Extra edited photos must be a whole number.';
      end;
      if v_extra_edits > 500 then
        raise exception using errcode = '22023', message = 'Extra edited photos is outside the supported range.';
      end if;

      v_session_price := nullif(v_session->>'price','')::numeric;
      if v_session_price is null then
        v_quote_required := true;
      else
        v_total := v_total + v_session_price;
        v_lines := v_lines || jsonb_build_array(jsonb_build_object('label', coalesce(v_session->>'label', v_session_id), 'value', v_session_price));
      end if;

      if v_extra_edits > 0 then
        v_extra_edit_rate := nullif(v_pricing->>'extraEditRate','')::numeric;
        if v_extra_edit_rate is null then
          v_quote_required := true;
        else
          v_total := v_total + (v_extra_edits * v_extra_edit_rate);
          v_lines := v_lines || jsonb_build_array(jsonb_build_object(
            'label', v_extra_edits::text || ' extra edited photo' || case when v_extra_edits = 1 then '' else 's' end,
            'value', round(v_extra_edits * v_extra_edit_rate, 2)
          ));
        end if;
      end if;

      v_deliverable_ids := coalesce(v_configuration->'deliverables', '[]'::jsonb);
      if jsonb_typeof(v_deliverable_ids) is distinct from 'array' then
        raise exception using errcode = '22023', message = 'Deliverable selection is invalid.';
      end if;

      for v_deliverable_id in select jsonb_array_elements_text(v_deliverable_ids) loop
        if not coalesce((v_pricing->'deliverables') ? v_deliverable_id, false) then
          raise exception using errcode = '22023', message = 'One or more deliverables are invalid.';
        end if;
        v_deliverable := v_pricing->'deliverables'->v_deliverable_id;
        v_deliverable_price := nullif(v_deliverable->>'price','')::numeric;
        if v_deliverable_price is null then
          v_quote_required := true;
        else
          v_total := v_total + v_deliverable_price;
          v_lines := v_lines || jsonb_build_array(jsonb_build_object('label', coalesce(v_deliverable->>'label', v_deliverable_id), 'value', v_deliverable_price));
        end if;
      end loop;

      if v_quote_required then
        return jsonb_build_object(
          'productId', v_product_id,
          'productKey', trim(p_product_key),
          'productName', v_product_name,
          'total', 0,
          'summary', 'Quote required',
          'lines', jsonb_build_array(jsonb_build_object('label','Pricing','text','One or more selected options need a quote')),
          'metrics', jsonb_build_object('quoteRequired', true, 'sessionId', v_session_id, 'extraEdits', v_extra_edits),
          'snapshot', jsonb_build_object(
            'pricingVersion', v_pricing_version,
            'productKey', trim(p_product_key),
            'productName', v_product_name,
            'pricingStrategy', v_strategy,
            'configuration', v_configuration,
            'pricingDefinition', v_pricing,
            'calculation', jsonb_build_object('lines', '[]'::jsonb, 'metrics', jsonb_build_object('quoteRequired',true), 'total', 0),
            'capturedAt', now()
          )
        );
      end if;

      return jsonb_build_object(
        'productId', v_product_id,
        'productKey', trim(p_product_key),
        'productName', v_product_name,
        'total', round(v_total, 2),
        'summary', coalesce(v_session->>'label', v_session_id),
        'lines', v_lines,
        'metrics', jsonb_build_object(
          'quoteRequired', false, 'sessionId', v_session_id,
          'durationMinutes', v_session->>'durationMinutes', 'includedEdits', v_session->>'includedEdits',
          'extraEdits', v_extra_edits
        ),
        'snapshot', jsonb_build_object(
          'pricingVersion', v_pricing_version,
          'productKey', trim(p_product_key),
          'productName', v_product_name,
          'pricingStrategy', v_strategy,
          'configuration', v_configuration,
          'pricingDefinition', v_pricing,
          'calculation', jsonb_build_object('lines', v_lines, 'metrics', jsonb_build_object('quoteRequired',false), 'total', round(v_total,2)),
          'capturedAt', now()
        )
      );
    end;
  end if;

  -- CAFE-GUEST-01F: neutral PER_UNIT strategy. The arithmetic and every
  -- validation live in commerce._qs_price_per_unit; this only wraps its result
  -- in the same envelope every other strategy returns.
  if v_strategy = 'PER_UNIT' then
    declare
      v_per_unit jsonb;
    begin
      v_per_unit := commerce._qs_price_per_unit(v_pricing, v_configuration);

      return jsonb_build_object(
        'productId', v_product_id,
        'productKey', trim(p_product_key),
        'productName', v_product_name,
        'total', v_per_unit -> 'total',
        'summary', v_per_unit ->> 'summary',
        'lines', v_per_unit -> 'lines',
        'metrics', v_per_unit -> 'metrics',
        'snapshot', jsonb_build_object(
          'pricingVersion', v_pricing_version,
          'productKey', trim(p_product_key),
          'productName', v_product_name,
          'pricingStrategy', v_strategy,
          'configuration', v_configuration,
          'pricingDefinition', v_pricing,
          'calculation', jsonb_build_object(
            'lines', v_per_unit -> 'lines',
            'metrics', v_per_unit -> 'metrics',
            'total', v_per_unit -> 'total'
          ),
          'capturedAt', now()
        )
      );
    end;
  end if;

  return commerce.qs_calculate_price_legacy(
    p_tenant_id,
    p_product_key,
    v_configuration
  );
end
$function$;

-- Preserve all existing strategy calculations. Only the new print-only
-- Contravision input contract and non-media enquiry wording are changed.
create or replace function commerce.qs_calculate_price(p_tenant_id uuid, p_product_key text, p_configuration jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $function$
declare
  v_result jsonb;
  v_width numeric;
  v_height numeric;
  v_lines jsonb;
begin
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
-- Both functions live in the non-exposed commerce schema and are called by
-- existing authorised RPCs. Do not grant a new public execution route.
revoke all on function commerce.qs_calculate_price_catalogue_base(uuid,text,jsonb) from public,anon,authenticated;


insert into commerce.products (tenant_id,slug,name,description,currency,availability,status,source_system,source_ref)
select t.id,'flyers','Flyers','Printed flyers for local promotions and events.','ZAR','available','published','quick_solution','flyers'
from public.tenants t where t.slug='quick-solution'
and not exists (select 1 from commerce.products p where p.tenant_id=t.id and p.slug='flyers');
insert into commerce.service_product_configs (tenant_id,product_id,source_key,customer_definition,pricing_version,pricing_definition,status,sort_order,operations_definition)
select t.id,p.id,'flyers','{"id":"flyers","name":"Flyers","shortName":"Flyers","category":"Business Essentials","description":"Printed flyers for local promotions and events.","plainDescription":"Printed flyers for local promotions and events. Configure your request; we confirm the quote before payment.","keywords":["flyers","flyers"],"active":true,"popular":false,"serviceType":"print-signage","channels":{"storefront":true,"guided":true,"advanced":false,"pos":false,"quote":true},"guidedJourneyId":"flyers-guided","nextActionLabel":"Request a quote","pricingVersion":"2026-10-catalogue-01","pricing":{"strategy":"ENQUIRY","quoteRequired":true},"fields":[{"id":"size","type":"select","label":"Which size?","default":"a5","options":[{"id":"a5","label":"A5"},{"id":"a6","label":"A6"},{"id":"a4","label":"A4"}]},{"id":"sides","type":"select","label":"Printed sides","default":"single","options":[{"id":"single","label":"Single sided"},{"id":"double","label":"Double sided"}]},{"id":"quantity","type":"number","label":"How many?","default":500,"min":1,"max":10000,"step":1,"required":true},{"id":"artwork","type":"select","label":"What about the design?","default":"ready","options":[{"id":"ready","label":"My artwork is ready"},{"id":"check","label":"Please check my artwork"},{"id":"design","label":"I need design help"}]},{"id":"brief","type":"textarea","label":"Anything we should know?","placeholder":"Intended use, deadline, measurements or finishing requirements."},{"id":"file","type":"file","label":"Artwork or reference","help":"Upload a PDF, image or photo of the installation area."}],"productPage":{"headline":"Flyers","intro":"Printed flyers for local promotions and events.","showStartingPrice":false}}'::jsonb,'2026-10-catalogue-01','{"strategy":"ENQUIRY","quoteRequired":true,"serviceType":"print-signage"}'::jsonb,'published',150,'{"rollout":"quote-first","checkedAt":"2026-10-06","priceConfirmed":false,"supplierCandidates":["Flyerz","Printulu"],"scope":"Confirm matching specifications, delivered cost and installation before quoting."}'::jsonb
from public.tenants t join commerce.products p on p.tenant_id=t.id and p.slug='flyers'
where t.slug='quick-solution' and not exists (select 1 from commerce.service_product_configs c where c.tenant_id=t.id and c.source_key='flyers');


insert into commerce.products (tenant_id,slug,name,description,currency,availability,status,source_system,source_ref)
select t.id,'correx-boards','Correx Boards','Lightweight boards for business notices, directions and promotions.','ZAR','available','published','quick_solution','correx-boards'
from public.tenants t where t.slug='quick-solution'
and not exists (select 1 from commerce.products p where p.tenant_id=t.id and p.slug='correx-boards');
insert into commerce.service_product_configs (tenant_id,product_id,source_key,customer_definition,pricing_version,pricing_definition,status,sort_order,operations_definition)
select t.id,p.id,'correx-boards','{"id":"correx-boards","name":"Correx Boards","shortName":"Correx Boards","category":"Signs & Large Format","description":"Lightweight boards for business notices, directions and promotions.","plainDescription":"Lightweight boards for business notices, directions and promotions. Configure your request; we confirm the quote before payment.","keywords":["correx boards","correx boards"],"active":true,"popular":false,"serviceType":"print-signage","channels":{"storefront":true,"guided":true,"advanced":false,"pos":false,"quote":true},"guidedJourneyId":"correx-boards-guided","nextActionLabel":"Request a quote","pricingVersion":"2026-10-catalogue-01","pricing":{"strategy":"ENQUIRY","quoteRequired":true},"fields":[{"id":"size","type":"select","label":"Which size?","default":"a2","options":[{"id":"a2","label":"A2"},{"id":"a1","label":"A1"},{"id":"custom","label":"Custom — describe measurements below"}]},{"id":"sides","type":"select","label":"Printed sides","default":"single","options":[{"id":"single","label":"Single sided"},{"id":"double","label":"Double sided"}]},{"id":"quantity","type":"number","label":"How many?","default":1,"min":1,"max":10000,"step":1,"required":true},{"id":"mounting","type":"select","label":"Mounting","default":"none","options":[{"id":"none","label":"Board only"},{"id":"eyelets","label":"Eyelets — confirm in quote"}]},{"id":"artwork","type":"select","label":"What about the design?","default":"ready","options":[{"id":"ready","label":"My artwork is ready"},{"id":"check","label":"Please check my artwork"},{"id":"design","label":"I need design help"}]},{"id":"brief","type":"textarea","label":"Anything we should know?","placeholder":"Intended use, deadline, measurements or finishing requirements."},{"id":"file","type":"file","label":"Artwork or reference","help":"Upload a PDF, image or photo of the installation area."}],"productPage":{"headline":"Correx Boards","intro":"Lightweight boards for business notices, directions and promotions.","showStartingPrice":false}}'::jsonb,'2026-10-catalogue-01','{"strategy":"ENQUIRY","quoteRequired":true,"serviceType":"print-signage"}'::jsonb,'published',151,'{"rollout":"quote-first","checkedAt":"2026-10-06","priceConfirmed":false,"supplierCandidates":["Flyerz","Printulu"],"scope":"Confirm matching specifications, delivered cost and installation before quoting."}'::jsonb
from public.tenants t join commerce.products p on p.tenant_id=t.id and p.slug='correx-boards'
where t.slug='quick-solution' and not exists (select 1 from commerce.service_product_configs c where c.tenant_id=t.id and c.source_key='correx-boards');


insert into commerce.products (tenant_id,slug,name,description,currency,availability,status,source_system,source_ref)
select t.id,'pull-up-banners','Pull-up Banners','Portable printed displays for shops, events and presentations.','ZAR','available','published','quick_solution','pull-up-banners'
from public.tenants t where t.slug='quick-solution'
and not exists (select 1 from commerce.products p where p.tenant_id=t.id and p.slug='pull-up-banners');
insert into commerce.service_product_configs (tenant_id,product_id,source_key,customer_definition,pricing_version,pricing_definition,status,sort_order,operations_definition)
select t.id,p.id,'pull-up-banners','{"id":"pull-up-banners","name":"Pull-up Banners","shortName":"Pull-up Banners","category":"Flags & Events","description":"Portable printed displays for shops, events and presentations.","plainDescription":"Portable printed displays for shops, events and presentations. Configure your request; we confirm the quote before payment.","keywords":["pull up banners","pull-up banners"],"active":true,"popular":false,"serviceType":"print-signage","channels":{"storefront":true,"guided":true,"advanced":false,"pos":false,"quote":true},"guidedJourneyId":"pull-up-banners-guided","nextActionLabel":"Request a quote","pricingVersion":"2026-10-catalogue-01","pricing":{"strategy":"ENQUIRY","quoteRequired":true},"fields":[{"id":"kit","type":"select","label":"What do you need?","default":"complete","options":[{"id":"complete","label":"Complete printed kit with stand"},{"id":"reprint","label":"Replacement print — match my existing stand"}]},{"id":"style","type":"select","label":"Stand type","default":"economy","options":[{"id":"economy","label":"Economy"},{"id":"deluxe","label":"Deluxe"}]},{"id":"quantity","type":"number","label":"How many?","default":1,"min":1,"max":10000,"step":1,"required":true},{"id":"artwork","type":"select","label":"What about the design?","default":"ready","options":[{"id":"ready","label":"My artwork is ready"},{"id":"check","label":"Please check my artwork"},{"id":"design","label":"I need design help"}]},{"id":"brief","type":"textarea","label":"Anything we should know?","placeholder":"Intended use, deadline, measurements or finishing requirements."},{"id":"file","type":"file","label":"Artwork or reference","help":"Upload a PDF, image or photo of the installation area."}],"productPage":{"headline":"Pull-up Banners","intro":"Portable printed displays for shops, events and presentations.","showStartingPrice":false}}'::jsonb,'2026-10-catalogue-01','{"strategy":"ENQUIRY","quoteRequired":true,"serviceType":"print-signage"}'::jsonb,'published',152,'{"rollout":"quote-first","checkedAt":"2026-10-06","priceConfirmed":false,"supplierCandidates":["Flyerz","Printulu"],"scope":"Confirm matching specifications, delivered cost and installation before quoting."}'::jsonb
from public.tenants t join commerce.products p on p.tenant_id=t.id and p.slug='pull-up-banners'
where t.slug='quick-solution' and not exists (select 1 from commerce.service_product_configs c where c.tenant_id=t.id and c.source_key='pull-up-banners');


insert into commerce.products (tenant_id,slug,name,description,currency,availability,status,source_system,source_ref)
select t.id,'car-magnets','Car Magnets','Removable printed vehicle advertising magnets.','ZAR','available','published','quick_solution','car-magnets'
from public.tenants t where t.slug='quick-solution'
and not exists (select 1 from commerce.products p where p.tenant_id=t.id and p.slug='car-magnets');
insert into commerce.service_product_configs (tenant_id,product_id,source_key,customer_definition,pricing_version,pricing_definition,status,sort_order,operations_definition)
select t.id,p.id,'car-magnets','{"id":"car-magnets","name":"Car Magnets","shortName":"Car Magnets","category":"Signs & Large Format","description":"Removable printed vehicle advertising magnets.","plainDescription":"Removable printed vehicle advertising magnets. Configure your request; we confirm the quote before payment.","keywords":["car magnets","car magnets"],"active":true,"popular":false,"serviceType":"print-signage","channels":{"storefront":true,"guided":true,"advanced":false,"pos":false,"quote":true},"guidedJourneyId":"car-magnets-guided","nextActionLabel":"Request a quote","pricingVersion":"2026-10-catalogue-01","pricing":{"strategy":"ENQUIRY","quoteRequired":true},"fields":[{"id":"size","type":"select","label":"Magnet size","default":"500x300","options":[{"id":"500x300","label":"500 × 300 mm"},{"id":"custom","label":"Custom — describe below"}]},{"id":"quantity","type":"number","label":"How many sets of two?","default":1,"min":1,"max":10000,"step":1,"required":true},{"id":"artwork","type":"select","label":"What about the design?","default":"ready","options":[{"id":"ready","label":"My artwork is ready"},{"id":"check","label":"Please check my artwork"},{"id":"design","label":"I need design help"}]},{"id":"brief","type":"textarea","label":"Anything we should know?","placeholder":"Intended use, deadline, measurements or finishing requirements."},{"id":"file","type":"file","label":"Artwork or reference","help":"Upload a PDF, image or photo of the installation area."}],"productPage":{"headline":"Car Magnets","intro":"Removable printed vehicle advertising magnets.","showStartingPrice":false}}'::jsonb,'2026-10-catalogue-01','{"strategy":"ENQUIRY","quoteRequired":true,"serviceType":"print-signage"}'::jsonb,'published',153,'{"rollout":"quote-first","checkedAt":"2026-10-06","priceConfirmed":false,"supplierCandidates":["Flyerz","Printulu"],"scope":"Confirm matching specifications, delivered cost and installation before quoting."}'::jsonb
from public.tenants t join commerce.products p on p.tenant_id=t.id and p.slug='car-magnets'
where t.slug='quick-solution' and not exists (select 1 from commerce.service_product_configs c where c.tenant_id=t.id and c.source_key='car-magnets');


insert into commerce.products (tenant_id,slug,name,description,currency,availability,status,source_system,source_ref)
select t.id,'posters','Posters','Posters for events, shop offers and displays.','ZAR','available','published','quick_solution','posters'
from public.tenants t where t.slug='quick-solution'
and not exists (select 1 from commerce.products p where p.tenant_id=t.id and p.slug='posters');
insert into commerce.service_product_configs (tenant_id,product_id,source_key,customer_definition,pricing_version,pricing_definition,status,sort_order,operations_definition)
select t.id,p.id,'posters','{"id":"posters","name":"Posters","shortName":"Posters","category":"Business Essentials","description":"Posters for events, shop offers and displays.","plainDescription":"Posters for events, shop offers and displays. Configure your request; we confirm the quote before payment.","keywords":["posters","posters"],"active":true,"popular":false,"serviceType":"print-signage","channels":{"storefront":true,"guided":true,"advanced":false,"pos":false,"quote":true},"guidedJourneyId":"posters-guided","nextActionLabel":"Request a quote","pricingVersion":"2026-10-catalogue-01","pricing":{"strategy":"ENQUIRY","quoteRequired":true},"fields":[{"id":"size","type":"select","label":"Poster size","default":"a3","options":[{"id":"a3","label":"A3"},{"id":"a2","label":"A2"},{"id":"a1","label":"A1"}]},{"id":"quantity","type":"number","label":"How many?","default":1,"min":1,"max":10000,"step":1,"required":true},{"id":"artwork","type":"select","label":"What about the design?","default":"ready","options":[{"id":"ready","label":"My artwork is ready"},{"id":"check","label":"Please check my artwork"},{"id":"design","label":"I need design help"}]},{"id":"brief","type":"textarea","label":"Anything we should know?","placeholder":"Intended use, deadline, measurements or finishing requirements."},{"id":"file","type":"file","label":"Artwork or reference","help":"Upload a PDF, image or photo of the installation area."}],"productPage":{"headline":"Posters","intro":"Posters for events, shop offers and displays.","showStartingPrice":false}}'::jsonb,'2026-10-catalogue-01','{"strategy":"ENQUIRY","quoteRequired":true,"serviceType":"print-signage"}'::jsonb,'published',154,'{"rollout":"quote-first","checkedAt":"2026-10-06","priceConfirmed":false,"supplierCandidates":["Flyerz","Printulu"],"scope":"Confirm matching specifications, delivered cost and installation before quoting."}'::jsonb
from public.tenants t join commerce.products p on p.tenant_id=t.id and p.slug='posters'
where t.slug='quick-solution' and not exists (select 1 from commerce.service_product_configs c where c.tenant_id=t.id and c.source_key='posters');


insert into commerce.products (tenant_id,slug,name,description,currency,availability,status,source_system,source_ref)
select t.id,'rigid-signage','Shop Signs & Rigid Signage','Configure a printed sign, frame and installation request.','ZAR','available','published','quick_solution','rigid-signage'
from public.tenants t where t.slug='quick-solution'
and not exists (select 1 from commerce.products p where p.tenant_id=t.id and p.slug='rigid-signage');
insert into commerce.service_product_configs (tenant_id,product_id,source_key,customer_definition,pricing_version,pricing_definition,status,sort_order,operations_definition)
select t.id,p.id,'rigid-signage','{"id":"rigid-signage","name":"Shop Signs & Rigid Signage","shortName":"Shop Signs & Rigid Signage","category":"Signs & Large Format","description":"Configure a printed sign, frame and installation request.","plainDescription":"Configure a printed sign, frame and installation request. Configure your request; we confirm the quote before payment.","keywords":["rigid signage","shop signs & rigid signage"],"active":true,"popular":false,"serviceType":"print-signage","channels":{"storefront":true,"guided":true,"advanced":false,"pos":false,"quote":true},"guidedJourneyId":"rigid-signage-guided","nextActionLabel":"Request a quote","pricingVersion":"2026-10-catalogue-01","pricing":{"strategy":"ENQUIRY","quoteRequired":true},"fields":[{"id":"material","type":"select","label":"Sign material","default":"unsure","options":[{"id":"unsure","label":"Recommend the right material"},{"id":"chromadek","label":"Chromadek steel"},{"id":"acm","label":"Aluminium composite"},{"id":"abs","label":"ABS plastic"},{"id":"pvc-frame","label":"Stretched PVC on a frame"}]},{"id":"width","type":"number","label":"Finished width","suffix":"metres","default":1,"min":0.1,"max":20,"step":0.01,"required":true},{"id":"height","type":"number","label":"Finished height","suffix":"metres","default":1,"min":0.1,"max":20,"step":0.01,"required":true},{"id":"quantity","type":"number","label":"How many?","default":1,"min":1,"max":10000,"step":1,"required":true},{"id":"frame","type":"select","label":"Frame","default":"none","options":[{"id":"none","label":"No frame"},{"id":"steel","label":"Steel frame"},{"id":"aluminium","label":"Aluminium frame"},{"id":"unsure","label":"Please advise"}]},{"id":"installation","type":"select","label":"Installation","default":"supply","options":[{"id":"supply","label":"Supply only"},{"id":"install","label":"Install for me — quote after checking site"}]},{"id":"site","type":"textarea","label":"Installation site / area","placeholder":"Area, wall or fence, mounting height and access. Add a photo below."},{"id":"artwork","type":"select","label":"What about the design?","default":"ready","options":[{"id":"ready","label":"My artwork is ready"},{"id":"check","label":"Please check my artwork"},{"id":"design","label":"I need design help"}]},{"id":"brief","type":"textarea","label":"Anything we should know?","placeholder":"Intended use, deadline, measurements or finishing requirements."},{"id":"file","type":"file","label":"Artwork or reference","help":"Upload a PDF, image or photo of the installation area."}],"productPage":{"headline":"Shop Signs & Rigid Signage","intro":"Configure a printed sign, frame and installation request.","showStartingPrice":false}}'::jsonb,'2026-10-catalogue-01','{"strategy":"ENQUIRY","quoteRequired":true,"serviceType":"print-signage"}'::jsonb,'published',155,'{"rollout":"quote-first","checkedAt":"2026-10-06","priceConfirmed":false,"supplierCandidates":["Flyerz","Printulu"],"scope":"Confirm matching specifications, delivered cost and installation before quoting."}'::jsonb
from public.tenants t join commerce.products p on p.tenant_id=t.id and p.slug='rigid-signage'
where t.slug='quick-solution' and not exists (select 1 from commerce.service_product_configs c where c.tenant_id=t.id and c.source_key='rigid-signage');


insert into commerce.products (tenant_id,slug,name,description,currency,availability,status,source_system,source_ref)
select t.id,'folded-leaflets','Folded Leaflets & Menus','Folded menus, brochures and service leaflets.','ZAR','available','published','quick_solution','folded-leaflets'
from public.tenants t where t.slug='quick-solution'
and not exists (select 1 from commerce.products p where p.tenant_id=t.id and p.slug='folded-leaflets');
insert into commerce.service_product_configs (tenant_id,product_id,source_key,customer_definition,pricing_version,pricing_definition,status,sort_order,operations_definition)
select t.id,p.id,'folded-leaflets','{"id":"folded-leaflets","name":"Folded Leaflets & Menus","shortName":"Folded Leaflets & Menus","category":"Business Essentials","description":"Folded menus, brochures and service leaflets.","plainDescription":"Folded menus, brochures and service leaflets. Configure your request; we confirm the quote before payment.","keywords":["folded leaflets","folded leaflets & menus"],"active":true,"popular":false,"serviceType":"print-signage","channels":{"storefront":true,"guided":true,"advanced":false,"pos":false,"quote":true},"guidedJourneyId":"folded-leaflets-guided","nextActionLabel":"Request a quote","pricingVersion":"2026-10-catalogue-01","pricing":{"strategy":"ENQUIRY","quoteRequired":true},"fields":[{"id":"size","type":"select","label":"Which size?","default":"a5","options":[{"id":"a5","label":"A5"},{"id":"a6","label":"A6"},{"id":"a4","label":"A4"}]},{"id":"fold","type":"select","label":"Fold","default":"half","options":[{"id":"half","label":"Half fold"},{"id":"three","label":"Three panels"},{"id":"unsure","label":"Please advise"}]},{"id":"quantity","type":"number","label":"How many?","default":500,"min":1,"max":10000,"step":1,"required":true},{"id":"artwork","type":"select","label":"What about the design?","default":"ready","options":[{"id":"ready","label":"My artwork is ready"},{"id":"check","label":"Please check my artwork"},{"id":"design","label":"I need design help"}]},{"id":"brief","type":"textarea","label":"Anything we should know?","placeholder":"Intended use, deadline, measurements or finishing requirements."},{"id":"file","type":"file","label":"Artwork or reference","help":"Upload a PDF, image or photo of the installation area."}],"productPage":{"headline":"Folded Leaflets & Menus","intro":"Folded menus, brochures and service leaflets.","showStartingPrice":false}}'::jsonb,'2026-10-catalogue-01','{"strategy":"ENQUIRY","quoteRequired":true,"serviceType":"print-signage"}'::jsonb,'published',156,'{"rollout":"quote-first","checkedAt":"2026-10-06","priceConfirmed":false,"supplierCandidates":["Flyerz","Printulu"],"scope":"Confirm matching specifications, delivered cost and installation before quoting."}'::jsonb
from public.tenants t join commerce.products p on p.tenant_id=t.id and p.slug='folded-leaflets'
where t.slug='quick-solution' and not exists (select 1 from commerce.service_product_configs c where c.tenant_id=t.id and c.source_key='folded-leaflets');


insert into commerce.products (tenant_id,slug,name,description,currency,availability,status,source_system,source_ref)
select t.id,'booklets','Booklets','Printed booklets for programmes, catalogues and information.','ZAR','available','published','quick_solution','booklets'
from public.tenants t where t.slug='quick-solution'
and not exists (select 1 from commerce.products p where p.tenant_id=t.id and p.slug='booklets');
insert into commerce.service_product_configs (tenant_id,product_id,source_key,customer_definition,pricing_version,pricing_definition,status,sort_order,operations_definition)
select t.id,p.id,'booklets','{"id":"booklets","name":"Booklets","shortName":"Booklets","category":"Business Essentials","description":"Printed booklets for programmes, catalogues and information.","plainDescription":"Printed booklets for programmes, catalogues and information. Configure your request; we confirm the quote before payment.","keywords":["booklets","booklets"],"active":true,"popular":false,"serviceType":"print-signage","channels":{"storefront":true,"guided":true,"advanced":false,"pos":false,"quote":true},"guidedJourneyId":"booklets-guided","nextActionLabel":"Request a quote","pricingVersion":"2026-10-catalogue-01","pricing":{"strategy":"ENQUIRY","quoteRequired":true},"fields":[{"id":"size","type":"select","label":"Which size?","default":"a5","options":[{"id":"a5","label":"A5"},{"id":"a6","label":"A6"},{"id":"a4","label":"A4"}]},{"id":"pages","type":"number","label":"Total pages including cover","default":8,"min":4,"step":4},{"id":"quantity","type":"number","label":"How many?","default":100,"min":1,"max":10000,"step":1,"required":true},{"id":"artwork","type":"select","label":"What about the design?","default":"ready","options":[{"id":"ready","label":"My artwork is ready"},{"id":"check","label":"Please check my artwork"},{"id":"design","label":"I need design help"}]},{"id":"brief","type":"textarea","label":"Anything we should know?","placeholder":"Intended use, deadline, measurements or finishing requirements."},{"id":"file","type":"file","label":"Artwork or reference","help":"Upload a PDF, image or photo of the installation area."}],"productPage":{"headline":"Booklets","intro":"Printed booklets for programmes, catalogues and information.","showStartingPrice":false}}'::jsonb,'2026-10-catalogue-01','{"strategy":"ENQUIRY","quoteRequired":true,"serviceType":"print-signage"}'::jsonb,'published',157,'{"rollout":"quote-first","checkedAt":"2026-10-06","priceConfirmed":false,"supplierCandidates":["Flyerz","Printulu"],"scope":"Confirm matching specifications, delivered cost and installation before quoting."}'::jsonb
from public.tenants t join commerce.products p on p.tenant_id=t.id and p.slug='booklets'
where t.slug='quick-solution' and not exists (select 1 from commerce.service_product_configs c where c.tenant_id=t.id and c.source_key='booklets');


insert into commerce.products (tenant_id,slug,name,description,currency,availability,status,source_system,source_ref)
select t.id,'notepads','Branded Notepads','Branded tear-off pads for business use.','ZAR','available','published','quick_solution','notepads'
from public.tenants t where t.slug='quick-solution'
and not exists (select 1 from commerce.products p where p.tenant_id=t.id and p.slug='notepads');
insert into commerce.service_product_configs (tenant_id,product_id,source_key,customer_definition,pricing_version,pricing_definition,status,sort_order,operations_definition)
select t.id,p.id,'notepads','{"id":"notepads","name":"Branded Notepads","shortName":"Branded Notepads","category":"Business Essentials","description":"Branded tear-off pads for business use.","plainDescription":"Branded tear-off pads for business use. Configure your request; we confirm the quote before payment.","keywords":["notepads","branded notepads"],"active":true,"popular":false,"serviceType":"print-signage","channels":{"storefront":true,"guided":true,"advanced":false,"pos":false,"quote":true},"guidedJourneyId":"notepads-guided","nextActionLabel":"Request a quote","pricingVersion":"2026-10-catalogue-01","pricing":{"strategy":"ENQUIRY","quoteRequired":true},"fields":[{"id":"sheets","type":"select","label":"Sheets per pad","default":"25","options":[{"id":"25","label":"25"},{"id":"50","label":"50"}]},{"id":"quantity","type":"number","label":"How many?","default":1,"min":1,"max":10000,"step":1,"required":true},{"id":"artwork","type":"select","label":"What about the design?","default":"ready","options":[{"id":"ready","label":"My artwork is ready"},{"id":"check","label":"Please check my artwork"},{"id":"design","label":"I need design help"}]},{"id":"brief","type":"textarea","label":"Anything we should know?","placeholder":"Intended use, deadline, measurements or finishing requirements."},{"id":"file","type":"file","label":"Artwork or reference","help":"Upload a PDF, image or photo of the installation area."}],"productPage":{"headline":"Branded Notepads","intro":"Branded tear-off pads for business use.","showStartingPrice":false}}'::jsonb,'2026-10-catalogue-01','{"strategy":"ENQUIRY","quoteRequired":true,"serviceType":"print-signage"}'::jsonb,'published',158,'{"rollout":"quote-first","checkedAt":"2026-10-06","priceConfirmed":false,"supplierCandidates":["Flyerz","Printulu"],"scope":"Confirm matching specifications, delivered cost and installation before quoting."}'::jsonb
from public.tenants t join commerce.products p on p.tenant_id=t.id and p.slug='notepads'
where t.slug='quick-solution' and not exists (select 1 from commerce.service_product_configs c where c.tenant_id=t.id and c.source_key='notepads');


insert into commerce.products (tenant_id,slug,name,description,currency,availability,status,source_system,source_ref)
select t.id,'presentation-folders','Presentation Folders','Printed folders for proposals and business documents.','ZAR','available','published','quick_solution','presentation-folders'
from public.tenants t where t.slug='quick-solution'
and not exists (select 1 from commerce.products p where p.tenant_id=t.id and p.slug='presentation-folders');
insert into commerce.service_product_configs (tenant_id,product_id,source_key,customer_definition,pricing_version,pricing_definition,status,sort_order,operations_definition)
select t.id,p.id,'presentation-folders','{"id":"presentation-folders","name":"Presentation Folders","shortName":"Presentation Folders","category":"Business Essentials","description":"Printed folders for proposals and business documents.","plainDescription":"Printed folders for proposals and business documents. Configure your request; we confirm the quote before payment.","keywords":["presentation folders","presentation folders"],"active":true,"popular":false,"serviceType":"print-signage","channels":{"storefront":true,"guided":true,"advanced":false,"pos":false,"quote":true},"guidedJourneyId":"presentation-folders-guided","nextActionLabel":"Request a quote","pricingVersion":"2026-10-catalogue-01","pricing":{"strategy":"ENQUIRY","quoteRequired":true},"fields":[{"id":"quantity","type":"number","label":"How many?","default":1,"min":1,"max":10000,"step":1,"required":true},{"id":"artwork","type":"select","label":"What about the design?","default":"ready","options":[{"id":"ready","label":"My artwork is ready"},{"id":"check","label":"Please check my artwork"},{"id":"design","label":"I need design help"}]},{"id":"brief","type":"textarea","label":"Anything we should know?","placeholder":"Intended use, deadline, measurements or finishing requirements."},{"id":"file","type":"file","label":"Artwork or reference","help":"Upload a PDF, image or photo of the installation area."}],"productPage":{"headline":"Presentation Folders","intro":"Printed folders for proposals and business documents.","showStartingPrice":false}}'::jsonb,'2026-10-catalogue-01','{"strategy":"ENQUIRY","quoteRequired":true,"serviceType":"print-signage"}'::jsonb,'published',159,'{"rollout":"quote-first","checkedAt":"2026-10-06","priceConfirmed":false,"supplierCandidates":["Flyerz","Printulu"],"scope":"Confirm matching specifications, delivered cost and installation before quoting."}'::jsonb
from public.tenants t join commerce.products p on p.tenant_id=t.id and p.slug='presentation-folders'
where t.slug='quick-solution' and not exists (select 1 from commerce.service_product_configs c where c.tenant_id=t.id and c.source_key='presentation-folders');


insert into commerce.products (tenant_id,slug,name,description,currency,availability,status,source_system,source_ref)
select t.id,'calendars','Branded Calendars','Calendars produced to order for your business or campaign.','ZAR','available','published','quick_solution','calendars'
from public.tenants t where t.slug='quick-solution'
and not exists (select 1 from commerce.products p where p.tenant_id=t.id and p.slug='calendars');
insert into commerce.service_product_configs (tenant_id,product_id,source_key,customer_definition,pricing_version,pricing_definition,status,sort_order,operations_definition)
select t.id,p.id,'calendars','{"id":"calendars","name":"Branded Calendars","shortName":"Branded Calendars","category":"Business Essentials","description":"Calendars produced to order for your business or campaign.","plainDescription":"Calendars produced to order for your business or campaign. Configure your request; we confirm the quote before payment.","keywords":["calendars","branded calendars"],"active":true,"popular":false,"serviceType":"print-signage","channels":{"storefront":true,"guided":true,"advanced":false,"pos":false,"quote":true},"guidedJourneyId":"calendars-guided","nextActionLabel":"Request a quote","pricingVersion":"2026-10-catalogue-01","pricing":{"strategy":"ENQUIRY","quoteRequired":true},"fields":[{"id":"format","type":"select","label":"Calendar format","default":"tent","options":[{"id":"tent","label":"Desk tent"},{"id":"wall","label":"Wall"},{"id":"fridge","label":"Fridge"},{"id":"wiro","label":"Wiro bound"},{"id":"deskpad","label":"Desk pad"}]},{"id":"year","type":"number","label":"Calendar year","default":2027,"min":2026,"max":2100,"step":1},{"id":"quantity","type":"number","label":"How many?","default":1,"min":1,"max":10000,"step":1,"required":true},{"id":"artwork","type":"select","label":"What about the design?","default":"ready","options":[{"id":"ready","label":"My artwork is ready"},{"id":"check","label":"Please check my artwork"},{"id":"design","label":"I need design help"}]},{"id":"brief","type":"textarea","label":"Anything we should know?","placeholder":"Intended use, deadline, measurements or finishing requirements."},{"id":"file","type":"file","label":"Artwork or reference","help":"Upload a PDF, image or photo of the installation area."}],"productPage":{"headline":"Branded Calendars","intro":"Calendars produced to order for your business or campaign.","showStartingPrice":false}}'::jsonb,'2026-10-catalogue-01','{"strategy":"ENQUIRY","quoteRequired":true,"serviceType":"print-signage"}'::jsonb,'published',160,'{"rollout":"quote-first","checkedAt":"2026-10-06","priceConfirmed":false,"supplierCandidates":["Flyerz","Printulu"],"scope":"Confirm matching specifications, delivered cost and installation before quoting."}'::jsonb
from public.tenants t join commerce.products p on p.tenant_id=t.id and p.slug='calendars'
where t.slug='quick-solution' and not exists (select 1 from commerce.service_product_configs c where c.tenant_id=t.id and c.source_key='calendars');


insert into commerce.products (tenant_id,slug,name,description,currency,availability,status,source_system,source_ref)
select t.id,'contravision-installation','Contravision with Installation','Printed window branding with fitting assessed and quoted separately.','ZAR','available','published','quick_solution','contravision-installation'
from public.tenants t where t.slug='quick-solution'
and not exists (select 1 from commerce.products p where p.tenant_id=t.id and p.slug='contravision-installation');
insert into commerce.service_product_configs (tenant_id,product_id,source_key,customer_definition,pricing_version,pricing_definition,status,sort_order,operations_definition)
select t.id,p.id,'contravision-installation','{"id":"contravision-installation","name":"Contravision with Installation","shortName":"Contravision with Installation","category":"Signs & Large Format","description":"Printed window branding with fitting assessed and quoted separately.","plainDescription":"Printed window branding with fitting assessed and quoted separately. Configure your request; we confirm the quote before payment.","keywords":["contravision installation","contravision with installation"],"active":true,"popular":false,"serviceType":"print-signage","channels":{"storefront":true,"guided":true,"advanced":false,"pos":false,"quote":true},"guidedJourneyId":"contravision-installation-guided","nextActionLabel":"Request a quote","pricingVersion":"2026-10-catalogue-01","pricing":{"strategy":"ENQUIRY","quoteRequired":true},"fields":[{"id":"width","type":"number","label":"Finished width","suffix":"metres","default":1,"min":0.1,"max":20,"step":0.01,"required":true},{"id":"height","type":"number","label":"Finished height","suffix":"metres","default":1,"min":0.1,"max":20,"step":0.01,"required":true},{"id":"application","type":"select","label":"Where will it go?","default":"vehicle","options":[{"id":"vehicle","label":"Vehicle rear window"},{"id":"shop","label":"Shop window or door"}]},{"id":"site","type":"textarea","label":"Vehicle / site details","placeholder":"Vehicle model or installation address; attach a window photo."},{"id":"artwork","type":"select","label":"What about the design?","default":"ready","options":[{"id":"ready","label":"My artwork is ready"},{"id":"check","label":"Please check my artwork"},{"id":"design","label":"I need design help"}]},{"id":"brief","type":"textarea","label":"Anything we should know?","placeholder":"Intended use, deadline, measurements or finishing requirements."},{"id":"file","type":"file","label":"Artwork or reference","help":"Upload a PDF, image or photo of the installation area."}],"productPage":{"headline":"Contravision with Installation","intro":"Printed window branding with fitting assessed and quoted separately.","showStartingPrice":false}}'::jsonb,'2026-10-catalogue-01','{"strategy":"ENQUIRY","quoteRequired":true,"serviceType":"print-signage"}'::jsonb,'published',161,'{"rollout":"quote-first","checkedAt":"2026-10-06","priceConfirmed":false,"supplierCandidates":["Flyerz","Printulu"],"scope":"Confirm matching specifications, delivered cost and installation before quoting."}'::jsonb
from public.tenants t join commerce.products p on p.tenant_id=t.id and p.slug='contravision-installation'
where t.slug='quick-solution' and not exists (select 1 from commerce.service_product_configs c where c.tenant_id=t.id and c.source_key='contravision-installation');


insert into commerce.products (tenant_id,slug,name,description,currency,availability,status,source_system,source_ref)
select t.id,'contravision','Contravision Window Printing','Full-colour perforated window vinyl, supplied as a rectangular print for one panel.','ZAR','available','published','quick_solution','contravision'
from public.tenants t where t.slug='quick-solution'
and not exists (select 1 from commerce.products p where p.tenant_id=t.id and p.slug='contravision');
insert into commerce.service_product_configs (tenant_id,product_id,source_key,customer_definition,pricing_version,pricing_definition,status,sort_order,operations_definition)
select t.id,p.id,'contravision','{"id":"contravision","name":"Contravision Window Printing","shortName":"Contravision","category":"Signs & Large Format","description":"Full-colour perforated window vinyl, supplied as a rectangular print for one panel.","plainDescription":"Enter one panel’s width and height. Print only, minimum 1 m² billed. Shaped trimming and installation need a separate quote.","active":true,"popular":false,"keywords":["contravision","window branding","one way vision"],"channels":{"storefront":true,"guided":true,"pos":true,"quote":true},"guidedJourneyId":"contravision-guided","nextActionLabel":"Continue to collection","pricingVersion":"2026-10-contravision-01","pricing":{"strategy":"PER_AREA","baseRate":414,"minimumBillableArea":1,"unit":"m²"},"fields":[{"id":"width","type":"number","label":"Finished width","suffix":"metres","default":1,"min":0.1,"max":20,"step":0.01,"required":true},{"id":"height","type":"number","label":"Finished height","suffix":"metres","default":1,"min":0.1,"max":20,"step":0.01,"required":true},{"id":"material","type":"select","label":"Material","default":"standard","options":[{"id":"standard","label":"Perforated one-way-vision vinyl","multiplier":1}]},{"id":"finishing","type":"select","label":"Supply format","default":"print-only","options":[{"id":"print-only","label":"Rectangular print only — no fitting","fee":0}]},{"id":"artwork","type":"select","label":"What about the design?","default":"ready","options":[{"id":"ready","label":"My artwork is ready","fee":0},{"id":"check","label":"Please check my artwork","fee":75},{"id":"design","label":"I need design help","fee":250}]},{"id":"turnaround","type":"select","label":"Turnaround","default":"standard","options":[{"id":"standard","label":"Standard — timing confirmed after artwork review","multiplier":1}]},{"id":"file","type":"file","label":"Artwork or reference","help":"Upload a PDF, image or photo of the installation area."}],"productPage":{"headline":"Print your window branding","intro":"Print only. Vehicle contour cutting, fitting and installation are quoted separately.","showStartingPrice":true}}'::jsonb,'2026-10-contravision-01','{"strategy":"PER_AREA","baseRate":414,"minimumBillableArea":1,"materials":{"standard":{"multiplier":1}},"finishing":{"print-only":{"fee":0}},"artwork":{"ready":{"fee":0},"check":{"fee":75},"design":{"fee":250}},"turnaround":{"standard":{"multiplier":1}}}'::jsonb,'published',162,'{"sourceName":"AdverTech public printing-services price","sourceUrl":"https://www.adver-tech.co.za/product-category/printing-services/","checkedAt":"2026-10-06","supplierCost":180,"vatBasis":"excl_vat","vatRate":0.15,"marginRate":0.5,"costBasis":207,"modelRate":414,"model":"supplier cost including VAT / (1 - gross margin)","rollout":"staging-model","supplierTermsConfirmed":false,"scope":"Rectangular print only, one panel. 1m² minimum is Café policy, not a verified supplier minimum. No fitting, contour cutting, installation, guaranteed lead time or supplier freight included. Reconfirm supplier width/lamination/minimum and delivered cost before production rollout."}'::jsonb
from public.tenants t join commerce.products p on p.tenant_id=t.id and p.slug='contravision'
where t.slug='quick-solution' and not exists (select 1 from commerce.service_product_configs c where c.tenant_id=t.id and c.source_key='contravision');

CREATE OR REPLACE FUNCTION public.create_quick_solution_service_request(p_tenant_slug text, p_product_key text, p_configuration jsonb, p_customer_name text, p_customer_email text DEFAULT NULL::text, p_customer_phone text DEFAULT NULL::text, p_service_location jsonb DEFAULT NULL::jsonb, p_customer_notes text DEFAULT NULL::text, p_idempotency_key text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_tenant_id uuid;
  v_order_id uuid;
  v_order_item_id uuid;
  v_existing commerce.service_orders;
  v_order_number text;
  v_price jsonb;
  v_product_id uuid;
  v_product_name text;
  v_email text;
  v_phone text;
  v_upload_token text;
  v_strategy text;
  v_subtotal numeric;
  v_quote_required boolean;
begin
  select t.id into v_tenant_id
  from public.tenants t
  where t.slug=lower(trim(p_tenant_slug))
    and t.status='active'
    and exists (
      select 1
      from public.tenant_capabilities tc
      where tc.tenant_id=t.id
        and tc.capability_key='quick_solution'
        and tc.enabled=true
    )
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode='22023', message='Quick Solution storefront is not active.';
  end if;

  if length(trim(coalesce(p_idempotency_key,''))) < 8 then
    raise exception using errcode='22023', message='Request idempotency key is required.';
  end if;

  if length(trim(coalesce(p_customer_name,''))) < 2 then
    raise exception using errcode='22023', message='Customer name is required.';
  end if;

  v_email := nullif(lower(trim(coalesce(p_customer_email,''))), '');
  v_phone := nullif(trim(coalesce(p_customer_phone,'')), '');

  if v_email is null and v_phone is null then
    raise exception using errcode='22023', message='Provide an email address or phone number.';
  end if;

  if v_email is not null and position('@' in v_email) < 2 then
    raise exception using errcode='22023', message='Email address is not valid.';
  end if;

  if v_phone is not null
     and length(regexp_replace(v_phone, '[^0-9+]', '', 'g')) < 7 then
    raise exception using errcode='22023', message='Phone number is not valid.';
  end if;

  select * into v_existing
  from commerce.service_orders so
  where so.tenant_id=v_tenant_id
    and so.idempotency_key=trim(p_idempotency_key)
  limit 1;

  if v_existing.id is not null then
    v_upload_token := encode(extensions.gen_random_bytes(32), 'hex');

    update commerce.service_orders
    set upload_token_hash=encode(extensions.digest(v_upload_token,'sha256'),'hex'),
        upload_token_expires_at=now()+interval '24 hours'
    where id=v_existing.id;

    select soi.id into v_order_item_id
    from commerce.service_order_items soi
    where soi.order_id=v_existing.id
    order by soi.created_at asc
    limit 1;

    return jsonb_build_object(
      'ok',true,
      'replayed',true,
      'orderId',v_existing.id,
      'orderItemId',v_order_item_id,
      'orderNumber',v_existing.order_number,
      'subtotal',v_existing.subtotal,
      'fulfilmentFee',v_existing.fulfilment_fee,
      'totalAmount',v_existing.total_amount,
      'status',v_existing.status,
      'paymentStatus',v_existing.payment_status,
      'quoteRequired', coalesce((v_existing.source_metadata->>'quoteRequired')::boolean, true),
      'uploadToken',v_upload_token,
      'uploadTokenExpiresAt',now()+interval '24 hours'
    );
  end if;

  v_price := commerce.qs_calculate_price(
    v_tenant_id,
    trim(p_product_key),
    p_configuration
  );

  v_strategy := upper(coalesce(v_price->'snapshot'->>'pricingStrategy',''));
  if v_strategy not in ('ENQUIRY','PHOTOGRAPHY_SESSION') then
    raise exception using errcode='22023', message='This product is not configured as a service enquiry.';
  end if;

  v_product_id := (v_price->>'productId')::uuid;
  v_product_name := v_price->>'productName';
  v_order_number := commerce.qs_generate_order_number();
  v_upload_token := encode(extensions.gen_random_bytes(32), 'hex');

  -- ENQUIRY always reports quoteRequired:true/total:0 (unchanged).
  -- PHOTOGRAPHY_SESSION reports a real total only when every chosen
  -- component (session, extra edits, deliverables) is priced; a real
  -- price here does NOT mean payment happens now — this RPC never
  -- mints a PayFast token for any strategy, so recording a real amount
  -- only lets staff see the quoted figure while following up to
  -- confirm and arrange payment separately.
  v_quote_required := coalesce((v_price->'metrics'->>'quoteRequired')::boolean, true);
  v_subtotal := case when v_quote_required then 0 else coalesce((v_price->>'total')::numeric, 0) end;

  insert into commerce.service_orders (
    tenant_id,
    order_number,
    status,
    customer_name,
    customer_email,
    customer_phone,
    fulfilment_type,
    fulfilment_point_id,
    delivery_address,
    subtotal,
    fulfilment_fee,
    total_amount,
    payment_status,
    idempotency_key,
    customer_notes,
    source_metadata,
    upload_token_hash,
    upload_token_expires_at
  ) values (
    v_tenant_id,
    v_order_number,
    'submitted',
    trim(p_customer_name),
    v_email,
    v_phone,
    'service',
    null,
    case
      when p_service_location is not null
       and jsonb_typeof(p_service_location)='object'
      then p_service_location
      else null
    end,
    v_subtotal,
    0,
    v_subtotal,
    'unpaid',
    trim(p_idempotency_key),
    nullif(trim(coalesce(p_customer_notes,'')), ''),
    jsonb_build_object(
      'channel','storefront',
      'requestType', case when v_price->'metrics'->>'serviceType'='print-signage' then 'print_signage' when v_strategy = 'PHOTOGRAPHY_SESSION' then 'photography_session' else 'media_service' end,
      'quoteRequired', v_quote_required,
      'quoteStatus','pending_review',
      'serviceLocation',p_service_location
    ),
    encode(extensions.digest(v_upload_token,'sha256'),'hex'),
    now()+interval '24 hours'
  )
  returning id into v_order_id;

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
    trim(p_product_key),
    v_product_name,
    1,
    p_configuration,
    v_price->'snapshot',
    v_subtotal
  )
  returning id into v_order_item_id;

  return jsonb_build_object(
    'ok',true,
    'replayed',false,
    'orderId',v_order_id,
    'orderItemId',v_order_item_id,
    'orderNumber',v_order_number,
    'subtotal',v_subtotal,
    'fulfilmentFee',0,
    'totalAmount',v_subtotal,
    'status','submitted',
    'paymentStatus','unpaid',
    'quoteRequired', v_quote_required,
    'uploadToken',v_upload_token,
    'uploadTokenExpiresAt',now()+interval '24 hours'
  );
end
$function$;

commit;
