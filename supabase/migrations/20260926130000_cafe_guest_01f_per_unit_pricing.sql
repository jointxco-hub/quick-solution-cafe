-- CAFE-GUEST-01F: neutral PER_UNIT pricing strategy (server).
--
--   total = units x unitPrice
--
-- a fixed price per validated whole number of service units. A pricing
-- primitive only: no product is created or changed, nothing is published, and
-- there is no Scan or Lamination product yet (those will consume this).
--
-- Pricing definition (service_product_configs.pricing_definition), and the
-- identical customer-safe mirror in customer_definition.pricing (selling price
-- and unit limits only - the same convention as PER_AREA's baseRate):
--   { "strategy": "PER_UNIT", "unitPrice": <n>, "minUnits": <n>, "maxUnits": <n> }
--     unitPrice  JSON number, > 0, <= 100000, in whole cents (at most two
--                decimal places) so the total is exact and needs no rounding
--     minUnits   JSON integer >= 1
--     maxUnits   JSON integer >= minUnits and <= 10000
--   Any other shape: 'Pricing configuration is invalid.' (22023). There are no
--   tiers, minimum charge, setup fee, discount or variants.
--
-- Configuration: { "units": <n> } - the key is `units`, NOT `quantity`. The
-- OPPS handoff reads configuration.quantity as a product-quantity override
-- (line quantity, unit price = line_total / quantity) and TIERED /
-- CONFIGURABLE / SUPPLIER_MARGIN already give `quantity` their own meaning;
-- `units`, `unitPrice`, `minUnits` and `maxUnits` are used nowhere else.
-- A PER_UNIT order line keeps service_order_items.quantity = 1, and the
-- returned metrics never contain `quantity`.
--   units is required, and is either a JSON number that is a whole number, or
--   a string of plain digits (no sign, decimal point, exponent, spaces or
--   leading zeros - number inputs deliver strings). More than nine digits, or a
--   value outside [minUnits, maxUnits], is out of range. Nothing is clamped,
--   defaulted or rounded.
--
-- Errors (SQLSTATE 22023; the client mirror src/lib/perUnitPricing.js uses the
-- identical messages): 'Pricing configuration is invalid.', 'Units are
-- required.', 'Units must be a whole number.', 'Units are outside the
-- supported range.'
--
-- Money: total = round(units * unitPrice, 2). With whole-cent unit prices this
-- is exact, so it cannot differ from the client's integer-cent arithmetic.
--
-- commerce.qs_calculate_price below is the latest previous definition
-- (20260921120000_qs14_checkout_guards_and_supplier_rules.sql) copied exactly,
-- with ONE addition: the PER_UNIT dispatch block before its final delegation
-- to commerce.qs_calculate_price_legacy. Every existing strategy is
-- unchanged, and the static tests prove that by removing the block and
-- comparing the rest.
--
-- Not changed here: the admin save path. The client's buildPricingDefinition
-- and public.admin_update_quick_solution_product (whose staff gate belongs
-- with the CAFE-ACCESS work) accept PER_UNIT through CAFE-GUEST-01G
-- (20260926140000_cafe_guest_01g_admin_per_unit_support.sql), which reuses
-- commerce._qs_validate_per_unit_definition below as the single definition rule.

do $preflight$
begin
  if to_regprocedure('commerce.qs_calculate_price(uuid,text,jsonb)') is null
     or to_regprocedure('commerce.qs_calculate_price_legacy(uuid,text,jsonb)') is null then
    raise exception
      'CAFE_GUEST_01F_MIGRATION_PRECONDITION: commerce.qs_calculate_price and commerce.qs_calculate_price_legacy must exist';
  end if;
end
$preflight$;

-- The one place the PER_UNIT pricing-definition rule lives. Called by
-- commerce._qs_price_per_unit at price time, and by the admin save
-- (CAFE-GUEST-01G) so a malformed definition can never be stored.
create or replace function commerce._qs_validate_per_unit_definition(
  p_pricing jsonb
)
returns void
language plpgsql
immutable
set search_path = ''
as $function$
declare
  v_unit_price numeric;
  v_min_units numeric;
  v_max_units numeric;
begin
  if jsonb_typeof(p_pricing) is distinct from 'object'
     or jsonb_typeof(p_pricing -> 'unitPrice') is distinct from 'number'
     or jsonb_typeof(p_pricing -> 'minUnits') is distinct from 'number'
     or jsonb_typeof(p_pricing -> 'maxUnits') is distinct from 'number' then
    raise exception using errcode = '22023', message = 'Pricing configuration is invalid.';
  end if;

  v_unit_price := (p_pricing ->> 'unitPrice')::numeric;
  v_min_units := (p_pricing ->> 'minUnits')::numeric;
  v_max_units := (p_pricing ->> 'maxUnits')::numeric;

  if v_unit_price <= 0
     or v_unit_price > 100000
     or v_unit_price <> round(v_unit_price, 2)
     or v_min_units <> trunc(v_min_units)
     or v_max_units <> trunc(v_max_units)
     or v_min_units < 1
     or v_max_units < v_min_units
     or v_max_units > 10000 then
    raise exception using errcode = '22023', message = 'Pricing configuration is invalid.';
  end if;
end
$function$;

revoke all on function commerce._qs_validate_per_unit_definition(jsonb)
  from public, anon, authenticated, service_role;

comment on function commerce._qs_validate_per_unit_definition(jsonb) is
  'CAFE-GUEST-01F/G: the PER_UNIT pricing-definition rule (unitPrice > 0, <= 100000, whole cents; minUnits >= 1; maxUnits >= minUnits, <= 10000). Internal.';

create or replace function commerce._qs_price_per_unit(
  p_pricing jsonb,
  p_configuration jsonb
)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $function$
declare
  v_unit_price numeric;
  v_min_units numeric;
  v_max_units numeric;
  v_type text;
  v_text text;
  v_units numeric;
  v_total numeric;
begin
  -- The definition is always validated before the unit count.
  perform commerce._qs_validate_per_unit_definition(p_pricing);

  v_unit_price := (p_pricing ->> 'unitPrice')::numeric;
  v_min_units := (p_pricing ->> 'minUnits')::numeric;
  v_max_units := (p_pricing ->> 'maxUnits')::numeric;

  v_type := coalesce(jsonb_typeof(p_configuration -> 'units'), 'null');

  if v_type = 'null' then
    raise exception using errcode = '22023', message = 'Units are required.';
  elsif v_type = 'number' then
    v_units := (p_configuration ->> 'units')::numeric;
    if v_units <> trunc(v_units) then
      raise exception using errcode = '22023', message = 'Units must be a whole number.';
    end if;
  elsif v_type = 'string' then
    v_text := p_configuration ->> 'units';
    if v_text !~ '^(0|[1-9][0-9]*)$' then
      raise exception using errcode = '22023', message = 'Units must be a whole number.';
    end if;
    if length(v_text) > 9 then
      raise exception using errcode = '22023', message = 'Units are outside the supported range.';
    end if;
    v_units := v_text::numeric;
  else
    raise exception using errcode = '22023', message = 'Units must be a whole number.';
  end if;

  if v_units < v_min_units or v_units > v_max_units then
    raise exception using errcode = '22023', message = 'Units are outside the supported range.';
  end if;

  v_total := round(v_units * v_unit_price, 2);

  return jsonb_build_object(
    'total', v_total,
    'summary', v_units::bigint::text || ' × ' || to_char(v_unit_price, 'FM9999999990.00'),
    'lines', jsonb_build_array(jsonb_build_object('label', 'Units', 'value', v_total)),
    'metrics', jsonb_build_object('units', v_units::bigint, 'unitPrice', v_unit_price)
  );
end
$function$;

revoke all on function commerce._qs_price_per_unit(jsonb, jsonb)
  from public, anon, authenticated, service_role;

comment on function commerce._qs_price_per_unit(jsonb, jsonb) is
  'CAFE-GUEST-01F: neutral PER_UNIT arithmetic and validation (total = units x unitPrice). Internal: called only by commerce.qs_calculate_price.';

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

revoke all on function commerce.qs_calculate_price(uuid,text,jsonb)
  from public, anon, authenticated;
