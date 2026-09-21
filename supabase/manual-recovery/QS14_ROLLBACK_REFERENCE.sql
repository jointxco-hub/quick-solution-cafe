-- =====================================================================
-- MANUAL RECOVERY REFERENCE — NOT AN EXECUTABLE MIGRATION.
-- This file lives outside supabase/migrations/ on purpose and is never
-- picked up by `supabase db push` / `migration up`. It is a manual
-- reference only, to be pasted into Supabase Studio by a human if the
-- QS-14 migrations need to be reverted.
-- =====================================================================
--
-- Captured read-only from the linked staging project tijiamrfnxrbitafiflj
-- ("Joint X XOS Staging") on 2026-09-21, via `pg_get_functiondef`, BEFORE
-- any of the three QS-14 migrations
-- (20260921090000_qs14_catalog_margin_photography.sql,
--  20260921090500_qs14_catalog_data.sql,
--  20260921120000_qs14_checkout_guards_and_supplier_rules.sql)
-- were applied. Each CREATE OR REPLACE FUNCTION below is the exact live
-- pre-QS14 body, verified word-for-word (after stripping only
-- PostgreSQL's own cosmetic re-serialization: dollar-quote tag style
-- $$ vs $function$, explicit ::text casts on literal defaults, and
-- incidental whitespace) against the last migration file that had
-- defined each function before QS-14:
--   commerce.qs_calculate_price        <- 20260917184200_qs_13_4_3_document_instruction_pricing_validation.sql
--   commerce.qs_calculate_price_legacy <- 20260913155351_qs_03_quick_solution_foundation.sql (original qs_calculate_price, later renamed)
--   public.admin_update_quick_solution_product   <- 20260913164013_qs_03_1_admin_catalog.sql
--   public.create_quick_solution_cart_order      <- 20260917154500_qs_13_3_multi_item_cart_order.sql
--   public.create_quick_solution_order           <- 20260913193609_qs_08_payfast_payment_foundation.sql
--   public.create_quick_solution_service_request <- 20260915213000_qs12_media_services.sql
-- No unexplained differences were found in any of the six.
--
-- Restores all six functions to this exact pre-QS14 state, and drops
-- the one genuinely new function this PR introduces
-- (commerce._qs_derive_customer_pricing_mirror, which did not exist
-- before QS-14).
--
-- Data rollback (the QS-14 catalogue rows this migration adds) is NOT
-- included here — see the PR discussion for the tenant-scoped DELETE
-- statements for the flags/gazebos/photo-session product rows.
-- =====================================================================

begin;

-- commerce.qs_calculate_price
CREATE OR REPLACE FUNCTION commerce.qs_calculate_price(p_tenant_id uuid, p_product_key text, p_configuration jsonb)
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

  return commerce.qs_calculate_price_legacy(
    p_tenant_id,
    p_product_key,
    v_configuration
  );
end
$function$;

-- commerce.qs_calculate_price_legacy
CREATE OR REPLACE FUNCTION commerce.qs_calculate_price_legacy(p_tenant_id uuid, p_product_key text, p_configuration jsonb)
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
  v_total numeric := 0;
  v_summary text := '';
  v_lines jsonb := '[]'::jsonb;
  v_metrics jsonb := '{}'::jsonb;

  v_width numeric;
  v_height numeric;
  v_raw_area numeric;
  v_billable_area numeric;
  v_base numeric;
  v_service_fees numeric;
  v_turn_mult numeric;

  v_pages integer;
  v_copies integer;
  v_rate numeric;
  v_side_mult numeric;
  v_finish_fee numeric;
  v_printed_pages numeric;

  v_quantity integer;
  v_unit numeric;
  v_discount numeric;

  v_material text;
  v_finishing text;
  v_artwork text;
  v_turnaround text;
  v_print_mode text;
  v_sides text;
  v_finish text;
  v_stock text;
  v_garment text;
  v_front text;
  v_back text;
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

  if v_strategy = 'PER_AREA' then
    begin
      v_width := (p_configuration->>'width')::numeric;
      v_height := (p_configuration->>'height')::numeric;
    exception when others then
      raise exception using errcode = '22023', message = 'Width and height must be valid numbers.';
    end;

    if v_width <= 0 or v_height <= 0 or v_width > 20 or v_height > 20 then
      raise exception using errcode = '22023', message = 'Banner dimensions are outside the supported range.';
    end if;

    v_material := coalesce(nullif(p_configuration->>'material',''), 'standard');
    v_finishing := coalesce(nullif(p_configuration->>'finishing',''), 'hem-eyelets');
    v_artwork := coalesce(nullif(p_configuration->>'artwork',''), 'ready');
    v_turnaround := coalesce(nullif(p_configuration->>'turnaround',''), 'standard');

    if not coalesce((v_pricing->'materials') ? v_material, false)
       or not coalesce((v_pricing->'finishing') ? v_finishing, false)
       or not coalesce((v_pricing->'artwork') ? v_artwork, false)
       or not coalesce((v_pricing->'turnaround') ? v_turnaround, false) then
      raise exception using errcode = '22023', message = 'One or more banner options are invalid.';
    end if;

    v_raw_area := v_width * v_height;
    v_billable_area := greatest(v_raw_area, coalesce((v_pricing->>'minimumBillableArea')::numeric, 0));
    v_base := v_billable_area
      * coalesce((v_pricing->>'baseRate')::numeric, 0)
      * coalesce((v_pricing->'materials'->v_material->>'multiplier')::numeric, 1);
    v_service_fees :=
      coalesce((v_pricing->'finishing'->v_finishing->>'fee')::numeric, 0) +
      coalesce((v_pricing->'artwork'->v_artwork->>'fee')::numeric, 0);
    v_turn_mult := coalesce((v_pricing->'turnaround'->v_turnaround->>'multiplier')::numeric, 1);
    v_total := round((v_base + v_service_fees) * v_turn_mult, 2);
    v_summary := to_char(v_raw_area, 'FM999990.00') || 'm² actual · ' ||
                 to_char(v_billable_area, 'FM999990.00') || 'm² billable';
    v_lines := jsonb_build_array(
      jsonb_build_object('label','Print + material','value',round(v_base,2)),
      jsonb_build_object('label','Finishing + artwork','value',round(v_service_fees,2)),
      jsonb_build_object('label','Turnaround','text',v_turnaround)
    );
    v_metrics := jsonb_build_object('rawArea',v_raw_area,'billableArea',v_billable_area);

  elsif v_strategy = 'PER_PAGE' then
    begin
      v_pages := greatest(coalesce((p_configuration->>'pages')::integer, 1), 1);
      v_copies := greatest(coalesce((p_configuration->>'copies')::integer, 1), 1);
    exception when others then
      raise exception using errcode = '22023', message = 'Pages and copies must be whole numbers.';
    end;

    if v_pages > 1000 or v_copies > 500 then
      raise exception using errcode = '22023', message = 'Document quantity is outside the supported range.';
    end if;

    v_print_mode := coalesce(nullif(p_configuration->>'printMode',''), 'bw');
    v_sides := coalesce(nullif(p_configuration->>'sides',''), 'single');
    v_finish := coalesce(nullif(p_configuration->>'finish',''), 'none');

    if not coalesce((v_pricing->'rates') ? v_print_mode, false)
       or not coalesce((v_pricing->'sides') ? v_sides, false)
       or not coalesce((v_pricing->'finishes') ? v_finish, false) then
      raise exception using errcode = '22023', message = 'One or more document options are invalid.';
    end if;

    v_rate := coalesce((v_pricing->'rates'->v_print_mode->>'rate')::numeric, 0);
    v_side_mult := coalesce((v_pricing->'sides'->v_sides->>'multiplier')::numeric, 1);
    v_finish_fee := coalesce((v_pricing->'finishes'->v_finish->>'fee')::numeric, 0);
    v_printed_pages := v_pages * v_copies;
    v_base := v_printed_pages * v_rate * v_side_mult;
    v_service_fees := v_finish_fee * v_copies;
    v_total := round(v_base + v_service_fees, 2);
    v_summary := v_pages::text || ' page' || case when v_pages = 1 then '' else 's' end ||
                 ' × ' || v_copies::text || ' cop' || case when v_copies = 1 then 'y' else 'ies' end;
    v_lines := jsonb_build_array(
      jsonb_build_object('label',v_print_mode,'value',round(v_base,2)),
      jsonb_build_object('label',v_sides,'text',case when v_sides='double' then 'paper-saving option' else 'standard' end),
      jsonb_build_object('label',v_finish,'value',round(v_service_fees,2))
    );
    v_metrics := jsonb_build_object('pages',v_pages,'copies',v_copies,'printedPages',v_printed_pages);

  elsif v_strategy = 'TIERED' then
    v_quantity := greatest(coalesce(nullif(p_configuration->>'quantity','')::integer, 100), 1);
    v_stock := coalesce(nullif(p_configuration->>'stock',''), 'standard');
    v_finish := coalesce(nullif(p_configuration->>'finish',''), 'standard');
    v_artwork := coalesce(nullif(p_configuration->>'artwork',''), 'ready');

    if not coalesce((v_pricing->'quantities') ? v_quantity::text, false)
       or not coalesce((v_pricing->'stock') ? v_stock, false)
       or not coalesce((v_pricing->'finishes') ? v_finish, false)
       or not coalesce((v_pricing->'artwork') ? v_artwork, false) then
      raise exception using errcode = '22023', message = 'One or more business-card options are invalid.';
    end if;

    v_base :=
      coalesce((v_pricing->'quantities'->v_quantity::text->>'total')::numeric, 0) *
      coalesce((v_pricing->'stock'->v_stock->>'multiplier')::numeric, 1);
    v_service_fees :=
      coalesce((v_pricing->'finishes'->v_finish->>'fee')::numeric, 0) +
      coalesce((v_pricing->'artwork'->v_artwork->>'fee')::numeric, 0);
    v_total := round(v_base + v_service_fees, 2);
    v_summary := v_quantity::text || ' cards · ' || v_stock;
    v_lines := jsonb_build_array(
      jsonb_build_object('label','Cards','value',round(v_base,2)),
      jsonb_build_object('label',v_finish,'value',coalesce((v_pricing->'finishes'->v_finish->>'fee')::numeric,0)),
      jsonb_build_object('label',v_artwork,'value',coalesce((v_pricing->'artwork'->v_artwork->>'fee')::numeric,0))
    );
    v_metrics := jsonb_build_object('quantity',v_quantity);

  elsif v_strategy = 'CONFIGURABLE' then
    begin
      v_quantity := greatest(coalesce((p_configuration->>'quantity')::integer, 1), 1);
    exception when others then
      raise exception using errcode = '22023', message = 'Quantity must be a whole number.';
    end;

    if v_quantity > 250 then
      raise exception using errcode = '22023', message = 'T-shirt quantity is outside the supported range.';
    end if;

    v_garment := coalesce(nullif(p_configuration->>'garment',''), 'jointx-220');
    v_front := coalesce(nullif(p_configuration->>'frontPrint',''), 'a4');
    v_back := coalesce(nullif(p_configuration->>'backPrint',''), 'none');
    v_artwork := coalesce(nullif(p_configuration->>'artwork',''), 'ready');

    if not coalesce((v_pricing->'garments') ? v_garment, false)
       or not coalesce((v_pricing->'frontPrint') ? v_front, false)
       or not coalesce((v_pricing->'backPrint') ? v_back, false)
       or not coalesce((v_pricing->'artwork') ? v_artwork, false) then
      raise exception using errcode = '22023', message = 'One or more T-shirt options are invalid.';
    end if;

    v_unit :=
      coalesce((v_pricing->'garments'->v_garment->>'unitFee')::numeric,0) +
      coalesce((v_pricing->'frontPrint'->v_front->>'unitFee')::numeric,0) +
      coalesce((v_pricing->'backPrint'->v_back->>'unitFee')::numeric,0);

    v_discount := case when v_quantity >= 25 then 0.90 when v_quantity >= 10 then 0.95 else 1 end;
    v_base := v_unit * v_quantity * v_discount;
    v_service_fees := coalesce((v_pricing->'artwork'->v_artwork->>'fee')::numeric,0);
    v_total := round(v_base + v_service_fees, 2);
    v_summary := v_quantity::text || ' shirt' || case when v_quantity=1 then '' else 's' end || ' · ' || v_garment;
    v_lines := jsonb_build_array(
      jsonb_build_object('label','Garment + print','value',round(v_base,2)),
      jsonb_build_object('label','Artwork support','value',round(v_service_fees,2)),
      jsonb_build_object('label','Quantity pricing','text',
        case when v_discount < 1 then round((1-v_discount)*100)::text || '% quantity saving' else 'standard' end)
    );
    v_metrics := jsonb_build_object('quantity',v_quantity,'unit',v_unit,'discount',v_discount);

  else
    raise exception using errcode = '22023', message = 'Unsupported pricing strategy.';
  end if;

  return jsonb_build_object(
    'productId', v_product_id,
    'productKey', p_product_key,
    'productName', v_product_name,
    'total', v_total,
    'summary', v_summary,
    'lines', v_lines,
    'metrics', v_metrics,
    'snapshot', jsonb_build_object(
      'pricingVersion', v_pricing_version,
      'productKey', p_product_key,
      'productName', v_product_name,
      'pricingStrategy', v_strategy,
      'configuration', p_configuration,
      'pricingDefinition', v_pricing,
      'calculation', jsonb_build_object(
        'lines', v_lines,
        'metrics', v_metrics,
        'total', v_total
      ),
      'capturedAt', now()
    )
  );
end
$function$;

-- public.admin_update_quick_solution_product
CREATE OR REPLACE FUNCTION public.admin_update_quick_solution_product(p_tenant_slug text, p_product_key text, p_customer_definition jsonb, p_pricing_definition jsonb, p_expected_pricing_version text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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

  if p_expected_pricing_version is null
     or v_config.pricing_version <> p_expected_pricing_version then
    raise exception using errcode = '40001', message = 'This product changed after you opened it. Reload before saving.';
  end if;

  v_strategy := upper(coalesce(p_pricing_definition->>'strategy',''));
  if v_strategy not in ('PER_AREA','PER_PAGE','TIERED','CONFIGURABLE') then
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

  return jsonb_build_object(
    'ok', true,
    'productKey', trim(p_product_key),
    'pricingVersion', v_new_version
  );
end
$function$;

-- public.create_quick_solution_cart_order
CREATE OR REPLACE FUNCTION public.create_quick_solution_cart_order(p_tenant_slug text, p_items jsonb, p_customer_name text, p_customer_email text DEFAULT NULL::text, p_customer_phone text DEFAULT NULL::text, p_fulfilment_type text DEFAULT 'cafe'::text, p_fulfilment_point_id uuid DEFAULT NULL::uuid, p_delivery_address jsonb DEFAULT NULL::jsonb, p_customer_notes text DEFAULT NULL::text, p_idempotency_key text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$;

-- public.create_quick_solution_order
CREATE OR REPLACE FUNCTION public.create_quick_solution_order(p_tenant_slug text, p_product_key text, p_configuration jsonb, p_customer_name text, p_customer_email text DEFAULT NULL::text, p_customer_phone text DEFAULT NULL::text, p_fulfilment_type text DEFAULT 'cafe'::text, p_fulfilment_point_id uuid DEFAULT NULL::uuid, p_delivery_address jsonb DEFAULT NULL::jsonb, p_customer_notes text DEFAULT NULL::text, p_idempotency_key text DEFAULT NULL::text)
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
  v_subtotal numeric;
  v_fulfilment_fee numeric := 0;
  v_total numeric;
  v_fulfilment_type text;
  v_point commerce.fulfilment_points;
  v_email text;
  v_phone text;
  v_upload_token text;
  v_payment_token text;
  v_tracking jsonb;
  v_fulfilment_snapshot jsonb := null;
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

    select soi.id into v_order_item_id
    from commerce.service_order_items soi
    where soi.order_id = v_existing.id
    order by soi.created_at asc
    limit 1;

    return jsonb_build_object(
      'ok', true, 'replayed', true,
      'orderId', v_existing.id, 'orderItemId', v_order_item_id,
      'orderNumber', v_existing.order_number,
      'subtotal', v_existing.subtotal,
      'fulfilmentFee', v_existing.fulfilment_fee,
      'totalAmount', v_existing.total_amount,
      'status', v_existing.status,
      'paymentStatus', v_existing.payment_status,
      'uploadToken', v_upload_token,
      'uploadTokenExpiresAt', now() + interval '24 hours',
      'paymentToken', v_payment_token,
      'paymentTokenExpiresAt', now() + interval '7 days',
      'trackingToken', v_tracking->>'token',
      'trackingTokenExpiresAt', v_tracking->>'expiresAt'
    );
  end if;

  v_price := commerce.qs_calculate_price(v_tenant_id, trim(p_product_key), p_configuration);
  v_product_id := (v_price->>'productId')::uuid;
  v_product_name := v_price->>'productName';
  v_subtotal := (v_price->>'total')::numeric;
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

  v_total := round(v_subtotal + v_fulfilment_fee, 2);
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
      'channel','storefront',
      'deliveryFeeStatus', case when v_fulfilment_type='delivery' then 'pending_confirmation' else 'not_required' end,
      'fulfilmentPointSnapshot', v_fulfilment_snapshot
    ),
    encode(extensions.digest(v_upload_token, 'sha256'), 'hex'),
    now() + interval '24 hours',
    encode(extensions.digest(v_payment_token, 'sha256'), 'hex'),
    now() + interval '7 days'
  ) returning id into v_order_id;

  insert into commerce.service_order_items (
    order_id, tenant_id, product_id, product_key, product_name, quantity,
    configuration, pricing_snapshot, line_total
  ) values (
    v_order_id, v_tenant_id, v_product_id, trim(p_product_key), v_product_name, 1,
    p_configuration, v_price->'snapshot', v_subtotal
  ) returning id into v_order_item_id;

  v_tracking := commerce.qs_issue_tracking_token(v_order_id);

  return jsonb_build_object(
    'ok', true, 'replayed', false,
    'orderId', v_order_id, 'orderItemId', v_order_item_id,
    'orderNumber', v_order_number,
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
$function$;

-- public.create_quick_solution_service_request
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
      'quoteRequired',true,
      'uploadToken',v_upload_token,
      'uploadTokenExpiresAt',now()+interval '24 hours'
    );
  end if;

  v_price := commerce.qs_calculate_price(
    v_tenant_id,
    trim(p_product_key),
    p_configuration
  );

  if upper(coalesce(v_price->'snapshot'->>'pricingStrategy','')) <> 'ENQUIRY' then
    raise exception using errcode='22023', message='This product is not configured as a service enquiry.';
  end if;

  v_product_id := (v_price->>'productId')::uuid;
  v_product_name := v_price->>'productName';
  v_order_number := commerce.qs_generate_order_number();
  v_upload_token := encode(extensions.gen_random_bytes(32), 'hex');

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
    0,
    0,
    0,
    'unpaid',
    trim(p_idempotency_key),
    nullif(trim(coalesce(p_customer_notes,'')), ''),
    jsonb_build_object(
      'channel','storefront',
      'requestType','media_service',
      'quoteRequired',true,
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
    0
  )
  returning id into v_order_item_id;

  return jsonb_build_object(
    'ok',true,
    'replayed',false,
    'orderId',v_order_id,
    'orderItemId',v_order_item_id,
    'orderNumber',v_order_number,
    'subtotal',0,
    'fulfilmentFee',0,
    'totalAmount',0,
    'status','submitted',
    'paymentStatus','unpaid',
    'quoteRequired',true,
    'uploadToken',v_upload_token,
    'uploadTokenExpiresAt',now()+interval '24 hours'
  );
end
$function$;

drop function if exists commerce._qs_derive_customer_pricing_mirror(jsonb);

commit;
