-- QS-14.1.1 verification probes. Mutating check is rolled back.
select
  commerce._qs_supplier_entry_customer_price(
    '{"strategy":"SUPPLIER_MARGIN","marginRate":0.55,"vatRate":0.15,"vatBasis":"excl_vat","defaultPricingMode":"fixed"}'::jsonb,
    '{"pricingMode":"fixed","fixedPrice":1500,"supplierCost":760,"referencePrice":750}'::jsonb
  ) as fixed_customer_price_should_be_1500,
  commerce._qs_supplier_entry_engine_reference(
    '{"strategy":"SUPPLIER_MARGIN","marginRate":0.55,"vatRate":0.15,"vatBasis":"excl_vat","defaultPricingMode":"fixed"}'::jsonb,
    '{"pricingMode":"fixed","fixedPrice":1500,"supplierCost":760,"referencePrice":750}'::jsonb
  ) as fixed_engine_reference_should_be_675,
  commerce._qs_supplier_entry_customer_price(
    '{"strategy":"SUPPLIER_MARGIN","marginRate":0.5,"vatRate":0.15,"vatBasis":"excl_vat","defaultPricingMode":"cost_margin"}'::jsonb,
    '{"pricingMode":"cost_margin","supplierCost":760,"referencePrice":1}'::jsonb
  ) as cost_margin_customer_price_should_be_1748,
  commerce._qs_supplier_entry_engine_reference(
    '{"strategy":"SUPPLIER_MARGIN","marginRate":0.5,"vatRate":0.15,"vatBasis":"excl_vat","defaultPricingMode":"cost_margin"}'::jsonb,
    '{"pricingMode":"cost_margin","supplierCost":760,"referencePrice":1}'::jsonb
  ) as cost_margin_engine_reference_should_be_874,
  commerce._qs_supplier_entry_customer_price(
    '{"strategy":"SUPPLIER_MARGIN","marginRate":0.5,"defaultPricingMode":"quote"}'::jsonb,
    '{"pricingMode":"quote","fixedPrice":9999,"supplierCost":1,"referencePrice":9999}'::jsonb
  ) as quote_customer_price_should_be_null;

select commerce._qs_derive_customer_pricing_mirror(
  '{"strategy":"SUPPLIER_MARGIN","marginRate":0.55,"vatRate":0.15,"vatBasis":"excl_vat","defaultPricingMode":"fixed","variants":{"probe":{"label":"Probe","pricingMode":"fixed","fixedPrice":1500,"supplierCost":760,"referencePrice":750}},"accessories":{},"artwork":{}}'::jsonb
)->'variants'->'probe'->>'price' as mirror_price_should_be_1500;

begin;
update commerce.service_product_configs c
set pricing_definition=jsonb_set(
  jsonb_set(
    jsonb_set(
      jsonb_set(c.pricing_definition,'{marginRate}',to_jsonb(0.55::numeric),true),
      array['variants','curved-2m-ds-full','pricingMode'],'"fixed"'::jsonb,true
    ),
    array['variants','curved-2m-ds-full','fixedPrice'],to_jsonb(1500::numeric),true
  ),
  array['variants','curved-2m-ds-full','referencePrice'],to_jsonb(9999::numeric),true
)
where c.source_key='flags' and c.tenant_id='44ceb817-1a37-4fb4-8869-0b0d90a37ab3';

select pricing_definition->'variants'->'curved-2m-ds-full'->>'referencePrice' as stored_reference_should_be_675
from commerce.service_product_configs
where source_key='flags' and tenant_id='44ceb817-1a37-4fb4-8869-0b0d90a37ab3';

select commerce.qs_calculate_price(
  '44ceb817-1a37-4fb4-8869-0b0d90a37ab3'::uuid,
  'flags',
  '{"variant":"curved-2m-ds-full","quantity":1}'::jsonb
)->>'total' as real_calculator_total_should_be_1500;
rollback;

select
  sum((lower(customer_definition::text) like '%suppliercost%')::int) as suppliercost_hits,
  sum((lower(customer_definition::text) like '%referenceprice%')::int) as referenceprice_hits,
  sum((lower(customer_definition::text) like '%marginrate%')::int) as marginrate_hits,
  sum((lower(customer_definition::text) like '%vatrate%')::int) as vatrate_hits,
  sum((lower(customer_definition::text) like '%pricingmode%')::int) as pricingmode_hits,
  sum((lower(customer_definition::text) like '%fixedprice%')::int) as fixedprice_hits
from commerce.service_product_configs
where upper(coalesce(pricing_definition->>'strategy',''))='SUPPLIER_MARGIN';
