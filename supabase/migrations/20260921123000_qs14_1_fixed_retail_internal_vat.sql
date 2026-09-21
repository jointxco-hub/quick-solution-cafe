-- QS-14.1 — fixed retail pricing + internal VAT costing
--
-- No schema changes.
-- Existing customer prices are frozen as FIXED retail prices.
-- Existing supplier reference prices are copied to supplierCost (staff-only).
-- referencePrice remains the pricing-engine basis used by QS-14's verified
-- server calculator; the admin UI keeps it derived from the selected mode:
--   fixed       -> referencePrice = fixedPrice * (1 - marginRate)
--   cost_margin -> referencePrice = VAT-adjusted supplierCost
--   quote       -> referencePrice = null
--
-- This keeps the existing server-side checkout guards and customer-safe
-- pricing mirror unchanged while fully decoupling retail price from supplier cost.

begin;

with target as (
  select
    c.id,
    c.customer_definition,
    c.pricing_definition,
    coalesce((c.pricing_definition->>'marginRate')::numeric, 0.5) as margin_rate
  from commerce.service_product_configs c
  where upper(coalesce(c.pricing_definition->>'strategy','')) = 'SUPPLIER_MARGIN'
),
rebuilt as (
  select
    t.id,
    t.pricing_definition
      || jsonb_build_object(
        'defaultPricingMode', 'fixed',
        'vatRate', coalesce(t.pricing_definition->'vatRate', to_jsonb(0.15::numeric)),
        'variants', coalesce((
          select jsonb_object_agg(
            e.key,
            e.value || jsonb_build_object(
              'supplierCost', e.value->'referencePrice',
              'pricingMode',
                case
                  when t.customer_definition->'pricing'->'variants'->e.key->'price' is null
                    or t.customer_definition->'pricing'->'variants'->e.key->'price' = 'null'::jsonb
                  then 'quote'
                  else 'fixed'
                end,
              'fixedPrice', t.customer_definition->'pricing'->'variants'->e.key->'price',
              'referencePrice',
                case
                  when t.customer_definition->'pricing'->'variants'->e.key->'price' is null
                    or t.customer_definition->'pricing'->'variants'->e.key->'price' = 'null'::jsonb
                  then 'null'::jsonb
                  else to_jsonb(
                    round(
                      (t.customer_definition->'pricing'->'variants'->e.key->>'price')::numeric
                      * (1 - t.margin_rate),
                      2
                    )
                  )
                end
            )
          )
          from jsonb_each(coalesce(t.pricing_definition->'variants','{}'::jsonb)) e
        ), '{}'::jsonb),
        'accessories', coalesce((
          select jsonb_object_agg(
            e.key,
            e.value || jsonb_build_object(
              'supplierCost', e.value->'referencePrice',
              'pricingMode',
                case
                  when t.customer_definition->'pricing'->'accessories'->e.key->'price' is null
                    or t.customer_definition->'pricing'->'accessories'->e.key->'price' = 'null'::jsonb
                  then 'quote'
                  else 'fixed'
                end,
              'fixedPrice', t.customer_definition->'pricing'->'accessories'->e.key->'price',
              'referencePrice',
                case
                  when t.customer_definition->'pricing'->'accessories'->e.key->'price' is null
                    or t.customer_definition->'pricing'->'accessories'->e.key->'price' = 'null'::jsonb
                  then 'null'::jsonb
                  else to_jsonb(
                    round(
                      (t.customer_definition->'pricing'->'accessories'->e.key->>'price')::numeric
                      * (1 - t.margin_rate),
                      2
                    )
                  )
                end
            )
          )
          from jsonb_each(coalesce(t.pricing_definition->'accessories','{}'::jsonb)) e
        ), '{}'::jsonb)
      ) as next_pricing
  from target t
)
update commerce.service_product_configs c
set pricing_definition = r.next_pricing,
    customer_definition = jsonb_set(
      c.customer_definition,
      '{pricing}',
      commerce._qs_derive_customer_pricing_mirror(r.next_pricing),
      true
    ),
    updated_at = now()
from rebuilt r
where c.id = r.id;

commit;
