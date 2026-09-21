-- QS-14.1.1 — server-authoritative supplier pricing modes
begin;

create or replace function commerce._qs_supplier_entry_engine_reference(
  p_pricing_definition jsonb,
  p_entry jsonb
)
returns numeric
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_margin numeric;
  v_vat_rate numeric;
  v_vat_basis text;
  v_mode text;
  v_fixed numeric;
  v_supplier numeric;
begin
  v_margin := coalesce(nullif(p_pricing_definition->>'marginRate','')::numeric, 0.5);
  if v_margin < 0 or v_margin >= 1 then
    raise exception using errcode='22023', message='Pricing configuration is invalid.';
  end if;

  v_mode := lower(nullif(trim(coalesce(p_entry->>'pricingMode','')), ''));
  if v_mode is null then
    v_mode := lower(nullif(trim(coalesce(p_pricing_definition->>'defaultPricingMode','')), ''));
  end if;

  if v_mode is null then
    return nullif(p_entry->>'referencePrice','')::numeric;
  end if;

  if v_mode = 'quote' then
    return null;
  end if;

  if v_mode = 'fixed' then
    v_fixed := nullif(p_entry->>'fixedPrice','')::numeric;
    if v_fixed is null or v_fixed <= 0 then return null; end if;
    return round(v_fixed * (1 - v_margin), 2);
  end if;

  if v_mode = 'cost_margin' then
    v_supplier := nullif(p_entry->>'supplierCost','')::numeric;
    if v_supplier is null or v_supplier <= 0 then return null; end if;

    v_vat_rate := coalesce(nullif(p_pricing_definition->>'vatRate','')::numeric, 0.15);
    if v_vat_rate < 0 or v_vat_rate > 1 then
      raise exception using errcode='22023', message='Internal VAT configuration is invalid.';
    end if;

    v_vat_basis := lower(coalesce(nullif(trim(p_pricing_definition->>'vatBasis'), ''), 'excl_vat'));
    if v_vat_basis not in ('excl_vat','incl_vat') then
      raise exception using errcode='22023', message='Supplier VAT basis is invalid.';
    end if;

    return round(case when v_vat_basis='excl_vat' then v_supplier * (1 + v_vat_rate) else v_supplier end, 2);
  end if;

  raise exception using errcode='22023', message='Pricing mode is invalid.';
end
$$;

create or replace function commerce._qs_supplier_entry_customer_price(
  p_pricing_definition jsonb,
  p_entry jsonb
)
returns numeric
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_margin numeric;
  v_mode text;
  v_reference numeric;
  v_fixed numeric;
begin
  v_margin := coalesce(nullif(p_pricing_definition->>'marginRate','')::numeric, 0.5);
  if v_margin < 0 or v_margin >= 1 then
    raise exception using errcode='22023', message='Pricing configuration is invalid.';
  end if;

  v_mode := lower(nullif(trim(coalesce(p_entry->>'pricingMode','')), ''));
  if v_mode is null then
    v_mode := lower(nullif(trim(coalesce(p_pricing_definition->>'defaultPricingMode','')), ''));
  end if;

  if v_mode = 'fixed' then
    v_fixed := nullif(p_entry->>'fixedPrice','')::numeric;
    return case when v_fixed is null or v_fixed <= 0 then null else round(v_fixed,2) end;
  end if;

  if v_mode = 'quote' then return null; end if;

  v_reference := commerce._qs_supplier_entry_engine_reference(p_pricing_definition, p_entry);
  if v_reference is null then return null; end if;

  return round(v_reference / (1 - v_margin), 2);
end
$$;

create or replace function commerce._qs_normalize_supplier_pricing_definition(
  p_pricing_definition jsonb
)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_strategy text;
  v_variants jsonb := '{}'::jsonb;
  v_accessories jsonb := '{}'::jsonb;
  v_key text;
  v_val jsonb;
  v_reference numeric;
begin
  if p_pricing_definition is null or jsonb_typeof(p_pricing_definition) is distinct from 'object' then
    raise exception using errcode='22023', message='Pricing definition must be a JSON object.';
  end if;

  v_strategy := upper(coalesce(p_pricing_definition->>'strategy',''));
  if v_strategy <> 'SUPPLIER_MARGIN' then return p_pricing_definition; end if;

  for v_key, v_val in select * from jsonb_each(coalesce(p_pricing_definition->'variants','{}'::jsonb)) loop
    v_reference := commerce._qs_supplier_entry_engine_reference(p_pricing_definition, v_val);
    v_variants := v_variants || jsonb_build_object(
      v_key,
      jsonb_set(v_val, '{referencePrice}', coalesce(to_jsonb(v_reference), 'null'::jsonb), true)
    );
  end loop;

  for v_key, v_val in select * from jsonb_each(coalesce(p_pricing_definition->'accessories','{}'::jsonb)) loop
    v_reference := commerce._qs_supplier_entry_engine_reference(p_pricing_definition, v_val);
    v_accessories := v_accessories || jsonb_build_object(
      v_key,
      jsonb_set(v_val, '{referencePrice}', coalesce(to_jsonb(v_reference), 'null'::jsonb), true)
    );
  end loop;

  return p_pricing_definition || jsonb_build_object('variants', v_variants, 'accessories', v_accessories);
end
$$;

create or replace function commerce._qs_derive_customer_pricing_mirror(p_pricing_definition jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_strategy text;
  v_variants jsonb := '{}'::jsonb;
  v_accessories jsonb := '{}'::jsonb;
  v_key text;
  v_val jsonb;
  v_price numeric;
begin
  v_strategy := upper(coalesce(p_pricing_definition->>'strategy',''));

  if v_strategy = 'SUPPLIER_MARGIN' then
    for v_key, v_val in select * from jsonb_each(coalesce(p_pricing_definition->'variants','{}'::jsonb)) loop
      v_price := commerce._qs_supplier_entry_customer_price(p_pricing_definition, v_val);
      v_variants := v_variants || jsonb_build_object(v_key, jsonb_build_object(
        'label', v_val->>'label', 'price', v_price,
        'minQuantity', v_val->'minQuantity', 'quantityStep', v_val->'quantityStep'
      ));
    end loop;

    for v_key, v_val in select * from jsonb_each(coalesce(p_pricing_definition->'accessories','{}'::jsonb)) loop
      v_price := commerce._qs_supplier_entry_customer_price(p_pricing_definition, v_val);
      v_accessories := v_accessories || jsonb_build_object(v_key, jsonb_build_object(
        'label', v_val->>'label', 'price', v_price,
        'compatibleVariants', v_val->'compatibleVariants'
      ));
    end loop;

    return jsonb_build_object(
      'strategy','SUPPLIER_MARGIN',
      'minQuantity',coalesce(p_pricing_definition->'minQuantity','1'::jsonb),
      'variantAxes',coalesce(p_pricing_definition->'variantAxes','[]'::jsonb),
      'variantTemplate',p_pricing_definition->'variantTemplate',
      'variants',v_variants,'accessories',v_accessories,
      'artwork',coalesce(p_pricing_definition->'artwork','{}'::jsonb)
    );
  end if;

  if v_strategy='PHOTOGRAPHY_SESSION' then return p_pricing_definition; end if;
  return null;
end
$$;

create or replace function commerce._qs_normalize_supplier_pricing_before_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if upper(coalesce(new.pricing_definition->>'strategy',''))='SUPPLIER_MARGIN' then
    new.pricing_definition := commerce._qs_normalize_supplier_pricing_definition(new.pricing_definition);
  end if;
  return new;
end
$$;

drop trigger if exists qs_normalize_supplier_pricing_before_write on commerce.service_product_configs;
create trigger qs_normalize_supplier_pricing_before_write
before insert or update of pricing_definition on commerce.service_product_configs
for each row execute function commerce._qs_normalize_supplier_pricing_before_write();

with normalized as (
  select c.id, commerce._qs_normalize_supplier_pricing_definition(c.pricing_definition) as pricing_definition
  from commerce.service_product_configs c
  where upper(coalesce(c.pricing_definition->>'strategy',''))='SUPPLIER_MARGIN'
)
update commerce.service_product_configs c
set pricing_definition=n.pricing_definition,
    customer_definition=jsonb_set(c.customer_definition,'{pricing}',commerce._qs_derive_customer_pricing_mirror(n.pricing_definition),true),
    updated_at=now()
from normalized n
where c.id=n.id;

commit;
