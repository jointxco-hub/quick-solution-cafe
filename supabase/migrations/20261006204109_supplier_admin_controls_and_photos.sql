-- Customer photographs and staff pricing/configuration controls. Staging only.
begin;
create or replace function commerce._qs_area_supplier_rate(p_model jsonb)
returns numeric language plpgsql security invoker set search_path='' as $rate$
declare v_cost numeric; v_margin numeric; v_vat numeric; v_basis text;
begin
 if jsonb_typeof(p_model) is distinct from 'object'
    or jsonb_typeof(p_model->'supplierCost') is distinct from 'number'
    or jsonb_typeof(p_model->'marginRate') is distinct from 'number'
    or jsonb_typeof(p_model->'vatRate') is distinct from 'number' then
   raise exception using errcode='22023',message='Complete valid supplier cost, margin and VAT settings.';
 end if;
 v_cost:=(p_model->>'supplierCost')::numeric;
 v_margin:=(p_model->>'marginRate')::numeric;
 v_vat:=(p_model->>'vatRate')::numeric;
 v_basis:=coalesce(p_model->>'vatBasis','');
 if v_cost<=0 or v_margin<0 or v_margin>=1 or v_vat<0 or v_vat>1 or v_basis not in ('none','incl_vat','excl_vat') then
   raise exception using errcode='22023',message='Supplier cost must be positive; margin must be below 100%; choose a valid VAT basis.';
 end if;
 return round(v_cost*(case when v_basis='excl_vat' then 1+v_vat else 1 end)/(1-v_margin),2);
end $rate$;
revoke all on function commerce._qs_area_supplier_rate(jsonb) from public,anon,authenticated;

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
  v_customer_definition jsonb;
  v_customer_mirror jsonb;
  v_pricing_definition jsonb;
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

  if not public.has_tenant_capability(v_tenant_id, 'cafe.operations.manage') then
    raise exception using errcode = '42501', message = 'You do not have access to Quick Solution Product Admin.';
  end if;

  if jsonb_typeof(p_customer_definition) is distinct from 'object'
     or jsonb_typeof(p_pricing_definition) is distinct from 'object' then
    raise exception using errcode = '22023', message = 'Product definitions must be JSON objects.';
  end if;

  select * into v_config
  from commerce.service_product_configs c
  where c.tenant_id=v_tenant_id and c.source_key=trim(p_product_key)
  limit 1 for update;
  if v_config.id is null then
    raise exception using errcode = '22023', message = 'Product was not found.';
  end if;

  if p_expected_pricing_version is null or v_config.pricing_version <> p_expected_pricing_version then
    raise exception using errcode = '40001', message = 'This product changed after you opened it. Reload before saving.';
  end if;

  v_strategy := upper(coalesce(p_pricing_definition->>'strategy',''));
  if v_strategy not in ('PER_AREA','PER_PAGE','TIERED','CONFIGURABLE','SUPPLIER_MARGIN','PHOTOGRAPHY_SESSION','PER_UNIT','ENQUIRY') then
    raise exception using errcode = '22023', message = 'Pricing strategy is not supported.';
  end if;

  v_product_name := left(trim(coalesce(p_customer_definition->>'name','')), 160);
  v_description := nullif(trim(coalesce(p_customer_definition->>'description', p_customer_definition->>'plainDescription','')), '');
  v_active := coalesce((p_customer_definition->>'active')::boolean, true);
  if length(v_product_name) < 2 then
    raise exception using errcode = '22023', message = 'Product name is required.';
  end if;

  v_customer_definition := p_customer_definition - array['pricingDefinition','operationsDefinition','operations_definition','supplierCost','marginRate','referencePrice','sourceUrl'];
  if v_strategy in ('SUPPLIER_MARGIN','PHOTOGRAPHY_SESSION') then
    v_customer_mirror := commerce._qs_derive_customer_pricing_mirror(p_pricing_definition);
    if v_customer_mirror is not null then
      v_customer_definition := jsonb_set(v_customer_definition, '{pricing}', v_customer_mirror, true);
    end if;
  end if;

  v_pricing_definition := p_pricing_definition;
  if v_strategy = 'PER_UNIT' then
    perform commerce._qs_validate_per_unit_definition(p_pricing_definition);
    v_pricing_definition := jsonb_build_object(
      'strategy', 'PER_UNIT',
      'unitPrice', p_pricing_definition -> 'unitPrice',
      'minUnits', p_pricing_definition -> 'minUnits',
      'maxUnits', p_pricing_definition -> 'maxUnits'
    );
    v_customer_definition := jsonb_set(v_customer_definition, '{pricing}', v_pricing_definition, true);
  end if;

  if v_strategy = 'ENQUIRY' then
    v_pricing_definition := jsonb_build_object('strategy','ENQUIRY','quoteRequired',true,
      'serviceType',coalesce(p_customer_definition->>'serviceType','service'),
      'quoteOperations',coalesce(p_pricing_definition->'quoteOperations','{}'::jsonb));
    v_customer_definition := jsonb_set(v_customer_definition,'{pricing}','{"strategy":"ENQUIRY","quoteRequired":true}'::jsonb,true);
  end if;
  if trim(p_product_key)='contravision' and v_strategy='PER_AREA' then
    if p_pricing_definition ? 'areaSupplier' then
      v_pricing_definition := jsonb_set(v_pricing_definition,'{baseRate}',to_jsonb(commerce._qs_area_supplier_rate(p_pricing_definition->'areaSupplier')),true);
    end if;
    if jsonb_typeof(v_pricing_definition->'baseRate') is distinct from 'number'
       or (v_pricing_definition->>'baseRate')::numeric<=0
       or jsonb_typeof(v_pricing_definition->'minimumBillableArea') is distinct from 'number'
       or (v_pricing_definition->>'minimumBillableArea')::numeric<=0 then
      raise exception using errcode='22023',message='Contravision needs a positive selling rate and minimum billable area.';
    end if;
    v_customer_definition := jsonb_set(v_customer_definition,'{pricing}',jsonb_build_object(
      'strategy','PER_AREA','baseRate',v_pricing_definition->'baseRate',
      'minimumBillableArea',v_pricing_definition->'minimumBillableArea','unit','m²'),true);
  end if;

  v_new_version := 'qsc-' || to_char(clock_timestamp() at time zone 'Africa/Johannesburg','YYYYMMDD-HH24MISS') || '-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,4));

  update commerce.service_product_configs c
  set customer_definition=v_customer_definition,
      pricing_definition=v_pricing_definition,
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
$function$
;

update commerce.service_product_configs c set customer_definition=jsonb_set(c.customer_definition,'{media}','{"hero":"/qs-catalogue/car-magnets-v1.webp","gallery":[]}'::jsonb,true),updated_at=now()
from public.tenants t where c.tenant_id=t.id and t.slug='quick-solution' and c.source_key='car-magnets';

update commerce.service_product_configs c set customer_definition=jsonb_set(c.customer_definition,'{media}','{"hero":"/qs-catalogue/posters-v1.webp","gallery":[]}'::jsonb,true),updated_at=now()
from public.tenants t where c.tenant_id=t.id and t.slug='quick-solution' and c.source_key='posters';

update commerce.service_product_configs c set customer_definition=jsonb_set(c.customer_definition,'{media}','{"hero":"/qs-catalogue/rigid-signage-v1.webp","gallery":[]}'::jsonb,true),updated_at=now()
from public.tenants t where c.tenant_id=t.id and t.slug='quick-solution' and c.source_key='rigid-signage';

update commerce.service_product_configs c set pricing_definition=jsonb_set(c.pricing_definition,'{areaSupplier}',
 '{"supplierCost":150,"marginRate":0.5,"vatBasis":"none","vatRate":0,"sourceName":"Owner-confirmed local merchant (name pending)"}'::jsonb,true),updated_at=now()
from public.tenants t where c.tenant_id=t.id and t.slug='quick-solution' and c.source_key='contravision';
commit;
