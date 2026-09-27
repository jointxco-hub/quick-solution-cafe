-- CAFE-GUEST-01I: Lamination, the second product on the generic PER_UNIT strategy.
--
-- Adds ONE product, 'lamination', in exactly the seeded pattern CAFE-GUEST-01H
-- used for Scan, with these deliberate decisions:
--
--   PRICE IS BLOCKED. No verified standalone Lamination price exists anywhere in
--   the project (the only "lamination" in the catalogue is a finish fee inside a
--   whole Business Cards order, which is not a per-sheet price), so none is
--   invented. pricing.unitPrice and pricing.maxUnits are 0, which the PER_UNIT
--   contract (commerce._qs_validate_per_unit_definition, CAFE-GUEST-01F)
--   rejects: the server cannot price it and the admin save (CAFE-GUEST-01G)
--   refuses to save it live until the business enters a real price and a real
--   maximum in /admin. It is inserted as the admin's own "not live" state leaves
--   a product - config status 'draft', product status 'draft', availability
--   'unavailable', customer_definition.active false - so the public catalogue
--   (published + available only) never returns it.
--
--   ONE UNIT = ONE PHYSICAL SHEET LAMINATED ONCE. Not a page: a sheet printed on
--   both sides is still one unit. The runtime price input is { units }; nothing
--   here reads or writes configuration.quantity.
--
--   NO SIZE MODEL. No supported lamination size exists in the project, so none is
--   invented; and PER_UNIT has one unitPrice, no per-option prices. If the
--   business prices by size this product cannot express it - that is a design
--   decision for before it goes live, not something this migration hacks around.
--
--   CHANNELS are decided, not copied: pos true (Cafe staff laminate items a
--   walk-in customer hands over); storefront, guided, advanced and quote false
--   (the storefront cannot take in the item or hand it back).
--
--   NO FILE FIELD: the item is physical, so there is nothing to upload.
--
-- pricing_definition is exactly the PER_UNIT contract, and
-- customer_definition.pricing is the same four keys (the mirror the admin save
-- enforces). minUnits 1 is structural (laminating zero sheets is not a service).
--
-- Insert-if-absent only: never overwrites a product or a price that already
-- exists, so a later admin edit is never reverted by a re-run. It touches no other
-- product (Scan included) and creates no function, grant or table.

begin;

do $preflight$
begin
  if not exists (select 1 from public.tenants t where t.slug = 'quick-solution')
     or to_regprocedure('commerce._qs_validate_per_unit_definition(jsonb)') is null
     or to_regprocedure('public.admin_update_quick_solution_product(text,text,jsonb,jsonb,text)') is null then
    raise exception
      'CAFE_GUEST_01I_MIGRATION_PRECONDITION: the quick-solution tenant, commerce._qs_validate_per_unit_definition (01F) and the PER_UNIT-aware admin save (01G) must exist';
  end if;
end
$preflight$;

insert into commerce.products (
  tenant_id, slug, name, description, currency, availability, status, source_system, source_ref
)
select
  t.id,
  'lamination',
  'Lamination',
  'Sheets laminated by our team at the Café.',
  'ZAR',
  'unavailable',
  'draft',
  'quick_solution',
  'lamination'
from public.tenants t
where t.slug = 'quick-solution'
  and not exists (
    select 1
    from commerce.products p
    where p.tenant_id = t.id and p.slug = 'lamination'
  );

insert into commerce.service_product_configs (
  tenant_id, product_id, source_key, customer_definition,
  pricing_version, pricing_definition, status, sort_order
)
select
  t.id,
  p.id,
  'lamination',
  $customer${
    "id": "lamination",
    "name": "Lamination",
    "shortName": "Lamination",
    "category": "Quick Print",
    "description": "Sheets laminated by our team at the Café.",
    "plainDescription": "Bring your sheets and we will laminate them for you.",
    "keywords": ["laminate", "laminating", "lamination", "sheet", "sheets"],
    "popular": false,
    "active": false,
    "channels": {"storefront": false, "guided": false, "pos": true, "quote": false, "advanced": false},
    "pricing": {"strategy": "PER_UNIT", "unitPrice": 0, "minUnits": 1, "maxUnits": 0},
    "fields": [
      {"id": "units", "type": "number", "label": "How many sheets need laminating?", "shortLabel": "Sheets to laminate", "suffix": "sheets", "help": "Count each sheet once, even if it is printed on both sides.", "min": 1, "step": 1, "required": true}
    ]
  }$customer$::jsonb,
  '2026-09-qsc-16',
  $definition${"strategy": "PER_UNIT", "unitPrice": 0, "minUnits": 1, "maxUnits": 0}$definition$::jsonb,
  'draft',
  23
from public.tenants t
join commerce.products p
  on p.tenant_id = t.id
 and p.slug = 'lamination'
where t.slug = 'quick-solution'
on conflict (tenant_id, source_key) do nothing;

commit;
