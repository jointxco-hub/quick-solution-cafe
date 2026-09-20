-- QS-14: supplier-margin catalogue (Flags, Gazebos) and configurable
-- photography session pricing.
--
-- ── Why a new commerce.qs_calculate_price, not a parallel calculator ──
-- Per the project brief: OPPS/shared commerce data is the source of
-- truth, and this must not become a separate competing pricing system.
-- commerce.qs_calculate_price already re-reads the LIVE, published
-- pricing_definition from commerce.service_product_configs on every
-- call and is the only thing any order-creation RPC trusts for a total
-- (confirmed by source audit: no RPC accepts a client-supplied price).
-- This migration follows the exact "rename current impl, wrap it"
-- convention already used twice (qs12_media_services wrapped the
-- foundation version; qs_13_4_3 wrapped qs12's) - the strategy dispatch
-- below IS the qs_13_4_3 body, with two new elsif branches inserted
-- before the final delegation to commerce.qs_calculate_price_legacy.
--
-- ── SUPPLIER_MARGIN strategy ───────────────────────────────────────
-- For flags/gazebos/banners/signage sourced from a supplier reference
-- price. GROSS margin, not markup: selling = reference / (1 - margin).
-- pricing_definition shape:
--   { "strategy":"SUPPLIER_MARGIN", "marginRate":0.5, "vatBasis":"excl_vat",
--     "sourceName":"...", "sourceUrl":"...", "sourceDate":"2026-08-11",
--     "minQuantity":1,
--     "variants": { "<id>": {"label":"...", "referencePrice": <number|null>}, ... },
--     "accessories": { "<id>": {"label":"...", "referencePrice": <number|null>}, ... } }
-- A null referencePrice on any chosen variant/accessory makes the whole
-- line quote-required (never zero/free - matches the photography rule
-- below, applied generically). Margin, reference prices and source
-- metadata are staff-only: get_quick_solution_catalog (the public
-- RPC) never returns pricing_definition, only customer_definition -
-- this was already true before this migration and is unchanged by it.
--
-- ── PHOTOGRAPHY_SESSION strategy ───────────────────────────────────
-- Only one price is approved: R449 for a 30-minute session including 7
-- edited photos. Every other duration, extra edited photos, and every
-- deliverable is unapproved (price: null) until the business supplies a
-- real rate - this migration does not invent one, including not
-- inferring an hourly rate by doubling the special. A null price on the
-- chosen session, on requested extra edits, or on any requested
-- deliverable, makes the whole request quote-required: total is
-- reported as 0 but always paired with quoteRequired:true / summary
-- "Quote required", the same convention ENQUIRY already uses - never a
-- bare zero that could read as free. Submitted through
-- create_quick_solution_service_request (extended below to also accept
-- this strategy, not just ENQUIRY) rather than the paid order RPC -
-- this repo's order RPC mints a PayFast token; the service-request RPC
-- never does, for any strategy. Keeping photography sessions on that
-- path is what actually satisfies "payment must not imply an
-- appointment is confirmed", without touching payment code at all: a
-- confirmed price is recorded on the order for staff to follow up and
-- arrange payment/confirmation separately.

begin;

create or replace function commerce.qs_calculate_price(p_tenant_id uuid, p_product_key text, p_configuration jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
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

      v_min_quantity := greatest(coalesce((v_pricing->>'minQuantity')::integer, 1), 1);
      begin
        v_quantity := coalesce((v_configuration->>'quantity')::integer, v_min_quantity);
      exception when others then
        raise exception using errcode = '22023', message = 'Quantity must be a whole number.';
      end;
      if v_quantity < v_min_quantity then
        raise exception using errcode = '22023', message = format('Minimum quantity is %s.', v_min_quantity);
      end if;
      if v_quantity > 500 then
        raise exception using errcode = '22023', message = 'Quantity is outside the supported range.';
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

      -- Artwork/setup: a flat Joint X service fee (not supplier-sourced,
      -- so margin is not applied to it — same convention as PER_AREA's
      -- artwork fee). Optional; defaults to no fee when omitted, so it
      -- never forces quote-required unless the customer explicitly
      -- picks an artwork option that isn't priced yet.
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

  return commerce.qs_calculate_price_legacy(
    p_tenant_id,
    p_product_key,
    v_configuration
  );
end
$function$;

-- ── Admin editor: allow the two new strategies to be saved ──────────
create or replace function public.admin_update_quick_solution_product(
  p_tenant_slug text,
  p_product_key text,
  p_customer_definition jsonb,
  p_pricing_definition jsonb,
  p_expected_pricing_version text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_config commerce.service_product_configs;
  v_product_name text;
  v_description text;
  v_active boolean;
  v_strategy text;
  v_new_version text;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Staff sign-in is required.';
  end if;

  select t.id into v_tenant_id
  from public.tenants t
  where t.slug=lower(trim(p_tenant_slug)) and t.status='active'
  limit 1;
  if v_tenant_id is null then
    raise exception using errcode = '22023', message = 'Quick Solution tenant was not found.';
  end if;

  if not public.is_app_admin()
     and not (public.is_opps_staff() and public.can_access_tenant(v_tenant_id)) then
    raise exception using errcode = '42501', message = 'You do not have access to Quick Solution Product Admin.';
  end if;

  if jsonb_typeof(p_customer_definition) is distinct from 'object'
     or jsonb_typeof(p_pricing_definition) is distinct from 'object' then
    raise exception using errcode = '22023', message = 'Product definitions must be JSON objects.';
  end if;

  select * into v_config
  from commerce.service_product_configs c
  where c.tenant_id=v_tenant_id and c.source_key=trim(p_product_key)
  limit 1;
  if v_config.id is null then
    raise exception using errcode = '22023', message = 'Product was not found.';
  end if;

  if p_expected_pricing_version is null or v_config.pricing_version <> p_expected_pricing_version then
    raise exception using errcode = '40001', message = 'This product changed after you opened it. Reload before saving.';
  end if;

  v_strategy := upper(coalesce(p_pricing_definition->>'strategy',''));
  if v_strategy not in ('PER_AREA','PER_PAGE','TIERED','CONFIGURABLE','SUPPLIER_MARGIN','PHOTOGRAPHY_SESSION') then
    raise exception using errcode = '22023', message = 'Pricing strategy is not supported.';
  end if;

  v_product_name := left(trim(coalesce(p_customer_definition->>'name','')), 160);
  v_description := nullif(trim(coalesce(p_customer_definition->>'description', p_customer_definition->>'plainDescription','')), '');
  v_active := coalesce((p_customer_definition->>'active')::boolean, true);
  if length(v_product_name) < 2 then
    raise exception using errcode = '22023', message = 'Product name is required.';
  end if;

  v_new_version := 'qsc-' || to_char(clock_timestamp() at time zone 'Africa/Johannesburg','YYYYMMDD-HH24MISS') || '-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,4));

  update commerce.service_product_configs c
  set customer_definition=p_customer_definition,
      pricing_definition=p_pricing_definition,
      pricing_version=v_new_version,
      status=case when v_active then 'published' else 'draft' end,
      updated_at=now()
  where c.id=v_config.id;

  update commerce.products p
  set name=v_product_name,
      description=v_description,
      status=case when v_active then 'published' else 'draft' end,
      availability=case when v_active then 'available' else 'unavailable' end,
      updated_at=now()
  where p.id=v_config.product_id and p.tenant_id=v_tenant_id;

  return jsonb_build_object('ok', true, 'productKey', trim(p_product_key), 'pricingVersion', v_new_version);
end
$$;

-- ── Service-request RPC: accept PHOTOGRAPHY_SESSION alongside ENQUIRY ─
-- Same function otherwise; the only changes are the strategy check
-- (line ~loosened below) and using the real computed price instead of
-- hardcoded 0 when the strategy is priced (PHOTOGRAPHY_SESSION with no
-- quote-required component). ENQUIRY behaviour (always 0, always
-- quoteRequired) is completely unchanged.
create or replace function public.create_quick_solution_service_request(
  p_tenant_slug text,
  p_product_key text,
  p_configuration jsonb,
  p_customer_name text,
  p_customer_email text default null,
  p_customer_phone text default null,
  p_service_location jsonb default null,
  p_customer_notes text default null,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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
      'requestType', case when v_strategy = 'PHOTOGRAPHY_SESSION' then 'photography_session' else 'media_service' end,
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
$$;

commit;
