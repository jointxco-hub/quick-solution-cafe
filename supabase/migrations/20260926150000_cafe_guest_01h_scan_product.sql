-- CAFE-GUEST-01H: Scan, the first product on the generic PER_UNIT strategy.
--
-- Adds ONE product, 'scan' (Document Scanning), in the same seeded pattern as
-- QS-11 (vinyl stickers), with these deliberate decisions:
--
--   PRICE IS BLOCKED. No verified Scan price exists anywhere in the project and
--   none is invented. pricing.unitPrice and pricing.maxUnits are 0, which the
--   PER_UNIT contract (commerce._qs_validate_per_unit_definition, CAFE-GUEST-01F)
--   rejects: the server cannot price it, and the admin save (CAFE-GUEST-01G)
--   refuses to save it live until the business enters a real price and a real
--   maximum in /admin. The product is inserted exactly as the admin's own
--   "not live" state leaves a product - config status 'draft', product status
--   'draft', availability 'unavailable', customer_definition.active false - so
--   the public catalogue (published + available only) does not return it.
--
--   ONE UNIT = ONE PAGE SCANNED (one side of one sheet, counted once), matching
--   the other document product (a4-print counts pages). The runtime price input
--   is { units }; nothing here reads or writes configuration.quantity.
--
--   CHANNELS are decided, not copied: pos true (Cafe staff scan a walk-in
--   customer's paper documents); storefront, guided, advanced and quote false
--   (the storefront cannot take in originals or deliver the scanned output).
--
--   NO FILE FIELD: the originals are physical, so there is nothing to upload.
--
-- pricing_definition is exactly the PER_UNIT contract - { strategy, unitPrice,
-- minUnits, maxUnits } - and customer_definition.pricing is the same four keys,
-- the mirror the admin save enforces. minUnits 1 is structural (a scan of zero
-- pages is not a scan); maxUnits is the business's to state.
--
-- Insert-if-absent only: this never overwrites a product or a price that
-- already exists (a later admin edit is never reverted by a re-run). It does not
-- touch any other product, and does not create Lamination.

begin;

do $preflight$
begin
  if not exists (select 1 from public.tenants t where t.slug = 'quick-solution')
     or to_regprocedure('commerce._qs_validate_per_unit_definition(jsonb)') is null
     or to_regprocedure('public.admin_update_quick_solution_product(text,text,jsonb,jsonb,text)') is null then
    raise exception
      'CAFE_GUEST_01H_MIGRATION_PRECONDITION: the quick-solution tenant, commerce._qs_validate_per_unit_definition (01F) and the PER_UNIT-aware admin save (01G) must exist';
  end if;
end
$preflight$;

insert into commerce.products (
  tenant_id, slug, name, description, currency, availability, status, source_system, source_ref
)
select
  t.id,
  'scan',
  'Document Scanning',
  'Paper documents scanned by our team at the Café.',
  'ZAR',
  'unavailable',
  'draft',
  'quick_solution',
  'scan'
from public.tenants t
where t.slug = 'quick-solution'
  and not exists (
    select 1
    from commerce.products p
    where p.tenant_id = t.id and p.slug = 'scan'
  );

insert into commerce.service_product_configs (
  tenant_id, product_id, source_key, customer_definition,
  pricing_version, pricing_definition, status, sort_order
)
select
  t.id,
  p.id,
  'scan',
  $customer${
    "id": "scan",
    "name": "Document Scanning",
    "shortName": "Scanning",
    "category": "Quick Print",
    "description": "Paper documents scanned by our team at the Café.",
    "plainDescription": "Bring your paper documents and we will scan them for you, priced per page scanned.",
    "keywords": ["scan", "scanning", "document", "documents", "paper"],
    "popular": false,
    "active": false,
    "channels": {"storefront": false, "guided": false, "pos": true, "quote": false, "advanced": false},
    "pricing": {"strategy": "PER_UNIT", "unitPrice": 0, "minUnits": 1, "maxUnits": 0},
    "fields": [
      {"id": "units", "type": "number", "label": "How many pages need scanning?", "shortLabel": "Pages to scan", "suffix": "pages", "help": "Count each page once: one side of a sheet is one page.", "min": 1, "step": 1, "required": true}
    ]
  }$customer$::jsonb,
  '2026-09-qsc-15',
  $definition${"strategy": "PER_UNIT", "unitPrice": 0, "minUnits": 1, "maxUnits": 0}$definition$::jsonb,
  'draft',
  22
from public.tenants t
join commerce.products p
  on p.tenant_id = t.id
 and p.slug = 'scan'
where t.slug = 'quick-solution'
on conflict (tenant_id, source_key) do nothing;

commit;
