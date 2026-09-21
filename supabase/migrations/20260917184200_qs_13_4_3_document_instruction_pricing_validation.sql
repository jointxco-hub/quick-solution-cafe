-- QS-13.4.3
-- Server-side validation and pricing parity for progressive document print instructions.
-- Staging-first. Production must not be touched until this is verified.

create or replace function commerce.qs_count_page_spec(p_spec text)
returns integer
language plpgsql
immutable
set search_path = ''
as $function$
declare
  v_part text;
  v_match text[];
  v_from integer;
  v_to integer;
  v_count integer := 0;
begin
  if nullif(btrim(p_spec), '') is null then
    raise exception using errcode = '22023', message = 'Choose the pages to print.';
  end if;

  for v_part in
    select btrim(value)
    from regexp_split_to_table(p_spec, ',') as value
  loop
    if v_part ~ '^[0-9]+$' then
      v_from := v_part::integer;
      if v_from < 1 or v_from > 1000 then
        raise exception using errcode = '22023', message = 'Page numbers must be between 1 and 1000.';
      end if;
      v_count := v_count + 1;
    elsif v_part ~ '^[0-9]+[[:space:]]*-[[:space:]]*[0-9]+$' then
      v_match := regexp_match(v_part, '^([0-9]+)[[:space:]]*-[[:space:]]*([0-9]+)$');
      v_from := v_match[1]::integer;
      v_to := v_match[2]::integer;
      if v_from < 1 or v_to < v_from or v_to > 1000 then
        raise exception using errcode = '22023', message = 'Page ranges must run forward between 1 and 1000.';
      end if;
      v_count := v_count + (v_to - v_from + 1);
    else
      raise exception using errcode = '22023', message = 'Use page numbers separated by commas, with ranges like 1-4.';
    end if;

    if v_count > 1000 then
      raise exception using errcode = '22023', message = 'Document quantity is outside the supported range.';
    end if;
  end loop;

  if v_count < 1 then
    raise exception using errcode = '22023', message = 'Choose at least one page to print.';
  end if;

  return v_count;
end
$function$;

create or replace function commerce.qs_normalize_document_configuration(p_configuration jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $function$
declare
  v_instructions jsonb;
  v_instruction jsonb;
  v_selection text;
  v_source_pages integer;
  v_selected_pages integer;
  v_total_pages integer := 0;
  v_copies integer;
  v_count integer;
begin
  if p_configuration is null or jsonb_typeof(p_configuration) is distinct from 'object' then
    raise exception using errcode = '22023', message = 'Configuration must be a JSON object.';
  end if;

  v_instructions := p_configuration->'documentInstructions';
  if jsonb_typeof(v_instructions) is distinct from 'array' then
    raise exception using errcode = '22023', message = 'Document print instructions are required.';
  end if;

  v_count := jsonb_array_length(v_instructions);
  if v_count < 1 or v_count > 25 then
    raise exception using errcode = '22023', message = 'Add between 1 and 25 documents to this print item.';
  end if;

  for v_instruction in select value from jsonb_array_elements(v_instructions)
  loop
    if jsonb_typeof(v_instruction) is distinct from 'object' then
      raise exception using errcode = '22023', message = 'Each document needs valid print instructions.';
    end if;

    v_selection := lower(coalesce(nullif(v_instruction->>'selection', ''), 'all'));

    if v_selection = 'all' then
      begin
        v_source_pages := (v_instruction->>'sourcePages')::integer;
      exception when others then
        raise exception using errcode = '22023', message = 'Add the page count for each document you want printed in full.';
      end;

      if v_source_pages < 1 or v_source_pages > 1000 then
        raise exception using errcode = '22023', message = 'Document page counts must be between 1 and 1000.';
      end if;
      v_selected_pages := v_source_pages;
    elsif v_selection = 'specific' then
      v_selected_pages := commerce.qs_count_page_spec(v_instruction->>'pagesSpec');
    else
      raise exception using errcode = '22023', message = 'Document page selection is invalid.';
    end if;

    v_total_pages := v_total_pages + v_selected_pages;
    if v_total_pages > 1000 then
      raise exception using errcode = '22023', message = 'Document quantity is outside the supported range.';
    end if;
  end loop;

  begin
    v_copies := greatest(coalesce((p_configuration->>'copies')::integer, 1), 1);
  exception when others then
    raise exception using errcode = '22023', message = 'Copies must be a whole number.';
  end;

  if v_copies > 500 then
    raise exception using errcode = '22023', message = 'Document quantity is outside the supported range.';
  end if;

  return jsonb_set(
    jsonb_set(
      jsonb_set(p_configuration, '{pages}', to_jsonb(v_total_pages), true),
      '{documentPlanValid}', 'true'::jsonb, true
    ),
    '{serverCalculatedPages}', to_jsonb(v_total_pages), true
  );
end
$function$;

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

  return commerce.qs_calculate_price_legacy(
    p_tenant_id,
    p_product_key,
    v_configuration
  );
end
$function$;
