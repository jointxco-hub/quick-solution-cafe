-- QS-14 follow-up: server-side checkout protection, supplier ordering
-- rules, and admin-side selling-price regeneration.
--
-- ── 1. Checkout protection (money-safety fix) ──────────────────────
-- commerce.qs_calculate_price already reports metrics.quoteRequired
-- for any line that can't be fully priced (SUPPLIER_MARGIN with an
-- unpriced variant/accessory, PHOTOGRAPHY_SESSION with an unapproved
-- session/extra-edits/deliverable). Neither
-- public.create_quick_solution_order NOR
-- public.create_quick_solution_cart_order ever checked that flag -
-- both took v_price->>'total' at face value, so an unpriced item could
-- be submitted through the PAID order path (which mints a PayFast
-- token) and would silently charge R0 for it - in a mixed cart, every
-- OTHER item still charges correctly while the unpriced one rides
-- along for free. Both RPCs now reject any item whose
-- metrics.quoteRequired is true, with a clear error naming the
-- product. This does not touch
-- public.create_quick_solution_service_request, which is exactly the
-- flow quote-required items are supposed to go through and continues
-- to accept them (ENQUIRY always did; PHOTOGRAPHY_SESSION since the
-- previous migration).
--
-- ── 2. Supplier ordering rules (SUPPLIER_MARGIN) ───────────────────
-- Single-sided Telescopic/Shark Fin/Curved flags "must be bought in
-- pairs of 2" per the source price list - encoded per-variant as
-- minQuantity/quantityStep on the variant itself (falling back to the
-- product-level minQuantity, step 1, when a variant doesn't override
-- it), validated the same way an out-of-range width/height already is
-- for PER_AREA. Accessories can now declare compatibleVariants (an
-- explicit allow-list, e.g. a gazebo wall/wheely-bag sized for one
-- frame size only) - omitted/empty means universal, matching how the
-- Flags accessories (Cross base, Ground spike, etc.) apply to every
-- flag variant per the source document.
--
-- ── 3. Admin-side selling-price regeneration ───────────────────────
-- admin_update_quick_solution_product previously stored whatever
-- customer_definition the client submitted verbatim. For
-- SUPPLIER_MARGIN/PHOTOGRAPHY_SESSION that customer_definition.pricing
-- block is a customer-SAFE MIRROR (pre-computed selling prices only,
-- never referencePrice/marginRate) - trusting the client to keep that
-- mirror in sync with the real pricing_definition it just edited is
-- exactly the kind of drift/spoofing risk a "customer-safe mirror"
-- exists to prevent. The server now derives that mirror itself from
-- the saved pricing_definition (selling = reference / (1 - margin),
-- same formula as qs_calculate_price) for these two strategies,
-- discarding whatever pricing.variants/accessories/sessions the client
-- sent and replacing it with a freshly computed one - the client can
-- still edit labels, quantity rules and every other customer_definition
-- field, just not hand-roll the price mirror. Every other existing
-- strategy (PER_AREA/PER_PAGE/TIERED/CONFIGURABLE) is unchanged.

begin;

-- ---------------------------------------------------------------------
-- commerce.qs_calculate_price — add minQuantity/quantityStep and
-- accessory compatibleVariants validation to the SUPPLIER_MARGIN
-- branch. Everything else in this function is unchanged from the
-- previous migration.
-- ---------------------------------------------------------------------
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

  return commerce.qs_calculate_price_legacy(
    p_tenant_id,
    p_product_key,
    v_configuration
  );
end
$function$;

-- ---------------------------------------------------------------------
-- Checkout protection: reject quoteRequired items in the paid order
-- path. Everything else in these two functions is unchanged.
-- ---------------------------------------------------------------------
create or replace function public.create_quick_solution_order(
  p_tenant_slug text,
  p_product_key text,
  p_configuration jsonb,
  p_customer_name text,
  p_customer_email text default null,
  p_customer_phone text default null,
  p_fulfilment_type text default 'cafe',
  p_fulfilment_point_id uuid default null,
  p_delivery_address jsonb default null,
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
  v_existing commerce.service_orders;
  v_order_number text;
  v_price jsonb;
  v_product_id uuid;
  v_product_name text;
  v_subtotal numeric;
  v_fulfilment_fee numeric := 0;
  v_total numeric;
  v_fulfilment_type text;
  v_point commerce.fulfilment_points;
  v_email text;
  v_phone text;
begin
  select t.id
  into v_tenant_id
  from public.tenants t
  where t.slug = lower(trim(p_tenant_slug))
    and t.status = 'active'
    and exists (
      select 1
      from public.tenant_capabilities tc
      where tc.tenant_id = t.id
        and tc.capability_key = 'quick_solution'
        and tc.enabled = true
    )
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode = '22023', message = 'Quick Solution storefront is not active.';
  end if;

  if length(trim(coalesce(p_idempotency_key,''))) < 8 then
    raise exception using errcode = '22023', message = 'Order idempotency key is required.';
  end if;

  if length(trim(coalesce(p_customer_name,''))) < 2 then
    raise exception using errcode = '22023', message = 'Customer name is required.';
  end if;

  v_email := nullif(lower(trim(coalesce(p_customer_email,''))), '');
  v_phone := nullif(trim(coalesce(p_customer_phone,'')), '');

  if v_email is null and v_phone is null then
    raise exception using errcode = '22023', message = 'Provide an email address or phone number.';
  end if;

  if v_email is not null and position('@' in v_email) < 2 then
    raise exception using errcode = '22023', message = 'Email address is not valid.';
  end if;

  if v_phone is not null and length(regexp_replace(v_phone, '[^0-9+]', '', 'g')) < 7 then
    raise exception using errcode = '22023', message = 'Phone number is not valid.';
  end if;

  select *
  into v_existing
  from commerce.service_orders so
  where so.tenant_id = v_tenant_id
    and so.idempotency_key = trim(p_idempotency_key)
  limit 1;

  if v_existing.id is not null then
    return jsonb_build_object(
      'ok', true,
      'replayed', true,
      'orderId', v_existing.id,
      'orderNumber', v_existing.order_number,
      'subtotal', v_existing.subtotal,
      'fulfilmentFee', v_existing.fulfilment_fee,
      'totalAmount', v_existing.total_amount,
      'status', v_existing.status
    );
  end if;

  v_price := commerce.qs_calculate_price(v_tenant_id, trim(p_product_key), p_configuration);

  -- Checkout protection: an item that needs a quote can never be paid
  -- for here - it must go through
  -- public.create_quick_solution_service_request instead, which never
  -- mints a payment token. PHOTOGRAPHY_SESSION is blocked from this
  -- path outright, even when fully priced (quoteRequired:false) -
  -- letting a priced session through PayFast here would let payment
  -- itself imply the appointment is confirmed, which is exactly what
  -- routing every photography booking through the service-request/
  -- manual-confirmation flow is meant to prevent.
  if coalesce((v_price->'metrics'->>'quoteRequired')::boolean, false)
     or upper(coalesce(v_price->'snapshot'->>'pricingStrategy','')) = 'PHOTOGRAPHY_SESSION'
  then
    raise exception using errcode = '22023',
      message = format('%s needs a quote before it can be ordered. Please use the request-a-quote flow.', coalesce(v_price->>'productName', trim(p_product_key)));
  end if;

  v_product_id := (v_price->>'productId')::uuid;
  v_product_name := v_price->>'productName';
  v_subtotal := (v_price->>'total')::numeric;

  v_fulfilment_type := lower(trim(coalesce(p_fulfilment_type,'cafe')));

  if v_fulfilment_type in ('cafe','quick_point') then
    if p_fulfilment_point_id is null then
      if v_fulfilment_type = 'quick_point' then
        raise exception using errcode = '22023', message = 'Choose a Quick Point.';
      end if;

      select *
      into v_point
      from commerce.fulfilment_points fp
      where fp.tenant_id = v_tenant_id
        and fp.kind = 'cafe'
        and fp.status = 'active'
        and fp.collection_enabled = true
      order by fp.sort_order, fp.created_at
      limit 1;
    else
      select *
      into v_point
      from commerce.fulfilment_points fp
      where fp.id = p_fulfilment_point_id
        and fp.tenant_id = v_tenant_id
        and fp.kind = v_fulfilment_type
        and fp.status = 'active'
        and fp.collection_enabled = true
      limit 1;
    end if;

    if v_point.id is null then
      raise exception using errcode = '22023', message = 'Selected collection point is not available.';
    end if;

    v_fulfilment_fee := coalesce(v_point.fee_amount,0);

  elsif v_fulfilment_type = 'delivery' then
    if p_delivery_address is null or jsonb_typeof(p_delivery_address) is distinct from 'object' then
      raise exception using errcode = '22023', message = 'Delivery address is required.';
    end if;
    v_fulfilment_fee := 0;
  else
    raise exception using errcode = '22023', message = 'Unsupported fulfilment type.';
  end if;

  v_total := round(v_subtotal + v_fulfilment_fee, 2);
  v_order_number := commerce.qs_generate_order_number();

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
    source_metadata
  ) values (
    v_tenant_id,
    v_order_number,
    'submitted',
    trim(p_customer_name),
    v_email,
    v_phone,
    v_fulfilment_type,
    case when v_fulfilment_type in ('cafe','quick_point') then v_point.id else null end,
    case when v_fulfilment_type='delivery' then p_delivery_address else null end,
    v_subtotal,
    v_fulfilment_fee,
    v_total,
    'unpaid',
    trim(p_idempotency_key),
    nullif(trim(coalesce(p_customer_notes,'')), ''),
    jsonb_build_object(
      'channel','storefront',
      'deliveryFeeStatus', case when v_fulfilment_type='delivery' then 'pending_confirmation' else 'not_required' end
    )
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
  );

  return jsonb_build_object(
    'ok', true,
    'replayed', false,
    'orderId', v_order_id,
    'orderNumber', v_order_number,
    'subtotal', v_subtotal,
    'fulfilmentFee', v_fulfilment_fee,
    'totalAmount', v_total,
    'status', 'submitted',
    'deliveryFeeStatus', case when v_fulfilment_type='delivery' then 'pending_confirmation' else 'not_required' end
  );
end
$$;

create or replace function public.create_quick_solution_cart_order(
  p_tenant_slug text,
  p_items jsonb,
  p_customer_name text,
  p_customer_email text default null,
  p_customer_phone text default null,
  p_fulfilment_type text default 'cafe',
  p_fulfilment_point_id uuid default null,
  p_delivery_address jsonb default null,
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
  v_existing commerce.service_orders;
  v_order_number text;
  v_subtotal numeric := 0;
  v_fulfilment_fee numeric := 0;
  v_total numeric := 0;
  v_fulfilment_type text;
  v_point commerce.fulfilment_points;
  v_email text;
  v_phone text;
  v_upload_token text;
  v_payment_token text;
  v_tracking jsonb;
  v_fulfilment_snapshot jsonb := null;
  v_item jsonb;
  v_price jsonb;
  v_product_id uuid;
  v_product_name text;
  v_product_key text;
  v_configuration jsonb;
  v_client_item_key text;
  v_priced_items jsonb := '[]'::jsonb;
  v_response_items jsonb := '[]'::jsonb;
  v_order_item_id uuid;
  v_count integer;
begin
  select t.id into v_tenant_id
  from public.tenants t
  where t.slug = lower(trim(p_tenant_slug))
    and t.status = 'active'
    and exists (
      select 1 from public.tenant_capabilities tc
      where tc.tenant_id = t.id
        and tc.capability_key = 'quick_solution'
        and tc.enabled = true
    )
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode = '22023', message = 'Quick Solution storefront is not active.';
  end if;

  if length(trim(coalesce(p_idempotency_key,''))) < 8 then
    raise exception using errcode = '22023', message = 'Order idempotency key is required.';
  end if;

  if length(trim(coalesce(p_customer_name,''))) < 2 then
    raise exception using errcode = '22023', message = 'Customer name is required.';
  end if;

  if p_items is null or jsonb_typeof(p_items) is distinct from 'array' then
    raise exception using errcode = '22023', message = 'Cart items must be an array.';
  end if;

  v_count := jsonb_array_length(p_items);
  if v_count < 1 then
    raise exception using errcode = '22023', message = 'Add at least one item to the order.';
  end if;
  if v_count > 25 then
    raise exception using errcode = '22023', message = 'This order has too many items. Split it into smaller orders.';
  end if;

  v_email := nullif(lower(trim(coalesce(p_customer_email,''))), '');
  v_phone := nullif(trim(coalesce(p_customer_phone,'')), '');

  if v_email is null and v_phone is null then
    raise exception using errcode = '22023', message = 'Provide an email address or phone number.';
  end if;
  if v_email is not null and position('@' in v_email) < 2 then
    raise exception using errcode = '22023', message = 'Email address is not valid.';
  end if;
  if v_phone is not null and length(regexp_replace(v_phone, '[^0-9+]', '', 'g')) < 7 then
    raise exception using errcode = '22023', message = 'Phone number is not valid.';
  end if;

  select * into v_existing
  from commerce.service_orders so
  where so.tenant_id = v_tenant_id
    and so.idempotency_key = trim(p_idempotency_key)
  limit 1;

  if v_existing.id is not null then
    v_upload_token := encode(extensions.gen_random_bytes(32), 'hex');
    v_payment_token := encode(extensions.gen_random_bytes(32), 'hex');
    v_tracking := commerce.qs_issue_tracking_token(v_existing.id);

    update commerce.service_orders
    set upload_token_hash = encode(extensions.digest(v_upload_token, 'sha256'), 'hex'),
        upload_token_expires_at = now() + interval '24 hours',
        payment_token_hash = encode(extensions.digest(v_payment_token, 'sha256'), 'hex'),
        payment_token_expires_at = now() + interval '7 days'
    where id = v_existing.id;

    select coalesce(jsonb_agg(jsonb_build_object(
      'clientItemKey', soi.client_item_key,
      'orderItemId', soi.id,
      'productKey', soi.product_key,
      'productName', soi.product_name,
      'lineTotal', soi.line_total
    ) order by soi.created_at, soi.id), '[]'::jsonb)
    into v_response_items
    from commerce.service_order_items soi
    where soi.order_id = v_existing.id;

    return jsonb_build_object(
      'ok', true,
      'replayed', true,
      'orderId', v_existing.id,
      'orderNumber', v_existing.order_number,
      'items', v_response_items,
      'subtotal', v_existing.subtotal,
      'fulfilmentFee', v_existing.fulfilment_fee,
      'totalAmount', v_existing.total_amount,
      'status', v_existing.status,
      'paymentStatus', v_existing.payment_status,
      'deliveryFeeStatus', coalesce(v_existing.source_metadata->>'deliveryFeeStatus','not_required'),
      'uploadToken', v_upload_token,
      'uploadTokenExpiresAt', now() + interval '24 hours',
      'paymentToken', v_payment_token,
      'paymentTokenExpiresAt', now() + interval '7 days',
      'trackingToken', v_tracking->>'token',
      'trackingTokenExpiresAt', v_tracking->>'expiresAt'
    );
  end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    if jsonb_typeof(v_item) is distinct from 'object' then
      raise exception using errcode = '22023', message = 'Every cart item must be an object.';
    end if;

    v_product_key := trim(coalesce(v_item->>'productKey',''));
    v_client_item_key := trim(coalesce(v_item->>'clientItemKey',''));
    v_configuration := coalesce(v_item->'configuration','{}'::jsonb);

    if v_product_key = '' then
      raise exception using errcode = '22023', message = 'Every cart item needs a product key.';
    end if;
    if length(v_client_item_key) < 8 then
      raise exception using errcode = '22023', message = 'Every cart item needs a stable item key.';
    end if;
    if jsonb_typeof(v_configuration) is distinct from 'object' then
      raise exception using errcode = '22023', message = 'Every cart item configuration must be an object.';
    end if;
    if exists (
      select 1
      from jsonb_array_elements(v_priced_items) x
      where x->>'clientItemKey' = v_client_item_key
    ) then
      raise exception using errcode = '22023', message = 'Duplicate cart item key.';
    end if;

    v_price := commerce.qs_calculate_price(v_tenant_id, v_product_key, v_configuration);

    -- Checkout protection (mixed carts): reject the WHOLE cart order if
    -- ANY single line needs a quote, or is a PHOTOGRAPHY_SESSION at all
    -- (even fully priced - see create_quick_solution_order's matching
    -- comment) - a partially-priced or photography-containing cart must
    -- never check out with that line riding along for free, or with
    -- payment standing in for a booking confirmation it doesn't cover.
    if coalesce((v_price->'metrics'->>'quoteRequired')::boolean, false)
       or upper(coalesce(v_price->'snapshot'->>'pricingStrategy','')) = 'PHOTOGRAPHY_SESSION'
    then
      raise exception using errcode = '22023',
        message = format('%s needs a quote before it can be ordered. Please use the request-a-quote flow, or remove it from this order.', coalesce(v_price->>'productName', v_product_key));
    end if;

    v_product_id := (v_price->>'productId')::uuid;
    v_product_name := v_price->>'productName';
    v_subtotal := v_subtotal + (v_price->>'total')::numeric;

    v_priced_items := v_priced_items || jsonb_build_array(jsonb_build_object(
      'clientItemKey', v_client_item_key,
      'productId', v_product_id,
      'productKey', v_product_key,
      'productName', v_product_name,
      'configuration', v_configuration,
      'pricingSnapshot', v_price->'snapshot',
      'lineTotal', (v_price->>'total')::numeric
    ));
  end loop;

  v_fulfilment_type := lower(trim(coalesce(p_fulfilment_type,'cafe')));

  if v_fulfilment_type in ('cafe','quick_point') then
    if p_fulfilment_point_id is null then
      if v_fulfilment_type = 'quick_point' then
        raise exception using errcode = '22023', message = 'Choose a Quick Point.';
      end if;

      select * into v_point
      from commerce.fulfilment_points fp
      where fp.tenant_id = v_tenant_id
        and fp.kind = 'cafe'
        and fp.status = 'active'
        and fp.collection_enabled = true
      order by fp.sort_order, fp.created_at
      limit 1;
    else
      select * into v_point
      from commerce.fulfilment_points fp
      where fp.id = p_fulfilment_point_id
        and fp.tenant_id = v_tenant_id
        and fp.kind = v_fulfilment_type
        and fp.status = 'active'
        and fp.collection_enabled = true
      limit 1;
    end if;

    if v_point.id is null then
      raise exception using errcode = '22023', message = 'Selected collection point is not available.';
    end if;

    v_fulfilment_fee := coalesce(v_point.fee_amount,0);
    v_fulfilment_snapshot := jsonb_build_object(
      'id', v_point.id,
      'slug', v_point.slug,
      'name', v_point.name,
      'kind', v_point.kind,
      'address', v_point.address,
      'contactPhone', v_point.contact_phone,
      'easyLocateBusinessRef', v_point.easy_locate_business_ref,
      'latitude', v_point.latitude,
      'longitude', v_point.longitude,
      'services', v_point.services,
      'feeAmount', v_point.fee_amount
    );
  elsif v_fulfilment_type = 'delivery' then
    if p_delivery_address is null or jsonb_typeof(p_delivery_address) is distinct from 'object' then
      raise exception using errcode = '22023', message = 'Delivery address is required.';
    end if;
    v_fulfilment_fee := 0;
  else
    raise exception using errcode = '22023', message = 'Unsupported fulfilment type.';
  end if;

  v_subtotal := round(v_subtotal,2);
  v_total := round(v_subtotal + v_fulfilment_fee,2);
  v_order_number := commerce.qs_generate_order_number();
  v_upload_token := encode(extensions.gen_random_bytes(32), 'hex');
  v_payment_token := encode(extensions.gen_random_bytes(32), 'hex');

  insert into commerce.service_orders (
    tenant_id, order_number, status, customer_name, customer_email, customer_phone,
    fulfilment_type, fulfilment_point_id, delivery_address, subtotal, fulfilment_fee,
    total_amount, payment_status, idempotency_key, customer_notes, source_metadata,
    upload_token_hash, upload_token_expires_at,
    payment_token_hash, payment_token_expires_at
  ) values (
    v_tenant_id, v_order_number, 'submitted', trim(p_customer_name), v_email, v_phone,
    v_fulfilment_type,
    case when v_fulfilment_type in ('cafe','quick_point') then v_point.id else null end,
    case when v_fulfilment_type='delivery' then p_delivery_address else null end,
    v_subtotal, v_fulfilment_fee, v_total, 'unpaid', trim(p_idempotency_key),
    nullif(trim(coalesce(p_customer_notes,'')), ''),
    jsonb_build_object(
      'channel','storefront_cart',
      'itemCount', v_count,
      'deliveryFeeStatus', case when v_fulfilment_type='delivery' then 'pending_confirmation' else 'not_required' end,
      'fulfilmentPointSnapshot', v_fulfilment_snapshot
    ),
    encode(extensions.digest(v_upload_token, 'sha256'), 'hex'),
    now() + interval '24 hours',
    encode(extensions.digest(v_payment_token, 'sha256'), 'hex'),
    now() + interval '7 days'
  ) returning id into v_order_id;

  for v_item in select value from jsonb_array_elements(v_priced_items)
  loop
    insert into commerce.service_order_items (
      order_id, tenant_id, product_id, product_key, product_name, quantity,
      configuration, pricing_snapshot, line_total, client_item_key
    ) values (
      v_order_id,
      v_tenant_id,
      (v_item->>'productId')::uuid,
      v_item->>'productKey',
      v_item->>'productName',
      1,
      v_item->'configuration',
      v_item->'pricingSnapshot',
      (v_item->>'lineTotal')::numeric,
      v_item->>'clientItemKey'
    ) returning id into v_order_item_id;

    v_response_items := v_response_items || jsonb_build_array(jsonb_build_object(
      'clientItemKey', v_item->>'clientItemKey',
      'orderItemId', v_order_item_id,
      'productKey', v_item->>'productKey',
      'productName', v_item->>'productName',
      'lineTotal', (v_item->>'lineTotal')::numeric
    ));
  end loop;

  v_tracking := commerce.qs_issue_tracking_token(v_order_id);

  return jsonb_build_object(
    'ok', true,
    'replayed', false,
    'orderId', v_order_id,
    'orderNumber', v_order_number,
    'items', v_response_items,
    'subtotal', v_subtotal,
    'fulfilmentFee', v_fulfilment_fee,
    'totalAmount', v_total,
    'status', 'submitted',
    'paymentStatus', 'unpaid',
    'deliveryFeeStatus', case when v_fulfilment_type='delivery' then 'pending_confirmation' else 'not_required' end,
    'uploadToken', v_upload_token,
    'uploadTokenExpiresAt', now() + interval '24 hours',
    'paymentToken', v_payment_token,
    'paymentTokenExpiresAt', now() + interval '7 days',
    'trackingToken', v_tracking->>'token',
    'trackingTokenExpiresAt', v_tracking->>'expiresAt'
  );
end
$$;

-- ---------------------------------------------------------------------
-- Admin editor: regenerate the customer-safe selling-price mirror
-- server-side for SUPPLIER_MARGIN/PHOTOGRAPHY_SESSION instead of
-- trusting the client's customer_definition.pricing verbatim.
-- ---------------------------------------------------------------------
create or replace function commerce._qs_derive_customer_pricing_mirror(p_pricing_definition jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_strategy text;
  v_margin numeric;
  v_variants jsonb := '{}'::jsonb;
  v_accessories jsonb := '{}'::jsonb;
  v_key text;
  v_val jsonb;
  v_ref numeric;
  v_price numeric;
begin
  v_strategy := upper(coalesce(p_pricing_definition->>'strategy',''));

  if v_strategy = 'SUPPLIER_MARGIN' then
    v_margin := coalesce((p_pricing_definition->>'marginRate')::numeric, 0.5);

    for v_key, v_val in select * from jsonb_each(coalesce(p_pricing_definition->'variants','{}'::jsonb))
    loop
      v_ref := nullif(v_val->>'referencePrice','')::numeric;
      v_price := case when v_ref is null then null else round(v_ref / (1 - v_margin), 2) end;
      v_variants := v_variants || jsonb_build_object(v_key, jsonb_build_object(
        'label', v_val->>'label',
        'price', v_price,
        'minQuantity', v_val->'minQuantity',
        'quantityStep', v_val->'quantityStep'
      ));
    end loop;

    for v_key, v_val in select * from jsonb_each(coalesce(p_pricing_definition->'accessories','{}'::jsonb))
    loop
      v_ref := nullif(v_val->>'referencePrice','')::numeric;
      v_price := case when v_ref is null then null else round(v_ref / (1 - v_margin), 2) end;
      v_accessories := v_accessories || jsonb_build_object(v_key, jsonb_build_object(
        'label', v_val->>'label',
        'price', v_price,
        'compatibleVariants', v_val->'compatibleVariants'
      ));
    end loop;

    return jsonb_build_object(
      'strategy', 'SUPPLIER_MARGIN',
      'minQuantity', coalesce(p_pricing_definition->'minQuantity', '1'::jsonb),
      -- variantAxes/variantTemplate carry no cost or margin data (just
      -- axis labels and the id-composition template the guided
      -- configurator uses) - safe to mirror straight through, and
      -- REQUIRED: without this, every admin save silently dropped them
      -- from customer_definition, breaking the decomposed
      -- style/size/sides/kit configurator on the very next page load.
      'variantAxes', coalesce(p_pricing_definition->'variantAxes', '[]'::jsonb),
      'variantTemplate', p_pricing_definition->'variantTemplate',
      'variants', v_variants,
      'accessories', v_accessories,
      'artwork', coalesce(p_pricing_definition->'artwork', '{}'::jsonb)
    );
  end if;

  if v_strategy = 'PHOTOGRAPHY_SESSION' then
    -- No supplier-cost/margin concept for photography - the approved
    -- price IS the customer price, so the mirror is the definition
    -- itself (still regenerated, not trusted from the client, so a
    -- price edited in pricing_definition can't drift from what
    -- customers see).
    return p_pricing_definition;
  end if;

  return null;
end
$$;

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
  v_customer_definition jsonb;
  v_customer_mirror jsonb;
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

  -- SUPPLIER_MARGIN/PHOTOGRAPHY_SESSION: never trust the client's
  -- customer_definition.pricing mirror - regenerate it from the
  -- pricing_definition just validated above, so a stale/spoofed/
  -- out-of-sync selling-price mirror can never be saved. Every other
  -- strategy is unchanged (their customer_definition.pricing already
  -- IS the authoritative numbers, same as pricing_definition, by
  -- design - nothing to regenerate).
  v_customer_definition := p_customer_definition;
  if v_strategy in ('SUPPLIER_MARGIN','PHOTOGRAPHY_SESSION') then
    v_customer_mirror := commerce._qs_derive_customer_pricing_mirror(p_pricing_definition);
    if v_customer_mirror is not null then
      v_customer_definition := jsonb_set(v_customer_definition, '{pricing}', v_customer_mirror, true);
    end if;
  end if;

  v_new_version := 'qsc-' || to_char(clock_timestamp() at time zone 'Africa/Johannesburg','YYYYMMDD-HH24MISS') || '-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,4));

  update commerce.service_product_configs c
  set customer_definition=v_customer_definition,
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

commit;
