-- CAFE-GUEST-01J: A4 Lamination and A3 Lamination, replacing the generic 'lamination'
-- placeholder of CAFE-GUEST-01I.
--
-- Confirmed business decision: A4 is R15 per sheet, A3 is R30 per sheet, at most 100
-- sheets per order, only these two sizes for now. PER_UNIT has one unitPrice, so the
-- SIZE IS THE PRODUCT: two separate products (a4-lamination, a3-lamination), each
-- with its own price and maximum, editable independently in /admin. There is no size
-- field, no variant and no priced option. 1 unit = 1 physical sheet laminated once
-- (never a page); the runtime count is { units }, never configuration.quantity.
--
-- LIVE. Every earlier seeded product with an approved price (QS-11, QS-12, QS-14) was
-- seeded published + available + active immediately, and there is no separate
-- publishing step; the definitions here are valid, so these follow that pattern.
-- They are counter-only regardless: pos true, and storefront, guided, advanced and
-- quote false, so the public catalogue (which requires channels.storefront not false)
-- never returns them. pos means only that Cafe staff may start the service for a
-- walk-in customer.
--
-- RETIREMENT of the generic 'lamination' (CAFE-GUEST-01I, 20260926160000). That
-- migration is not rewritten (forward migrations are the pattern, and it may already
-- have been applied somewhere). If the row exists it is RETIRED, never deleted:
--   config  status 'archived'  (the admin catalogue already hides archived configs,
--                               and pricing/the public catalogue require 'published')
--   product status 'archived', availability 'unavailable'
--   customer_definition.active false and every channel false (pos included, so a
--     future counter catalogue cannot list it)
--   pricing_version suffixed '-retired', so an admin holding a stale copy is told to
--     reload before saving instead of silently re-enabling it
-- Everything else an admin may have entered on it (price, name, fields) is kept. Only
-- rows that are not already archived are touched, so re-running changes nothing more.
-- If no such row exists, nothing happens.
--
-- IDEMPOTENT. The two new products are insert-if-absent (on conflict do nothing), so a
-- re-run never overwrites a price or maximum an admin has since edited. Nothing else is
-- touched: no other product (Scan included), no function, grant or table.
--
-- Deliberately no BEGIN/COMMIT here: the Supabase CLI applies each migration file
-- atomically, and leaving them out lets the SQL contract test re-apply this file
-- inside its own rolled-back transaction.

do $preflight$
begin
  if not exists (select 1 from public.tenants t where t.slug = 'quick-solution')
     or to_regprocedure('commerce._qs_validate_per_unit_definition(jsonb)') is null
     or to_regprocedure('public.admin_update_quick_solution_product(text,text,jsonb,jsonb,text)') is null then
    raise exception
      'CAFE_GUEST_01J_MIGRATION_PRECONDITION: the quick-solution tenant, commerce._qs_validate_per_unit_definition (01F) and the PER_UNIT-aware admin save (01G) must exist';
  end if;
end
$preflight$;

-- ── retire the generic placeholder, if it exists ───────────────────────────
update commerce.service_product_configs c
set status = 'archived',
    customer_definition = jsonb_set(
      jsonb_set(c.customer_definition, '{active}', 'false'::jsonb, true),
      '{channels}',
      '{"storefront": false, "guided": false, "pos": false, "quote": false, "advanced": false}'::jsonb,
      true
    ),
    pricing_version = case when c.pricing_version like '%-retired' then c.pricing_version else c.pricing_version || '-retired' end,
    updated_at = now()
from public.tenants t
where t.slug = 'quick-solution'
  and c.tenant_id = t.id
  and c.source_key = 'lamination'
  and c.status <> 'archived';

update commerce.products p
set status = 'archived',
    availability = 'unavailable',
    updated_at = now()
from public.tenants t
where t.slug = 'quick-solution'
  and p.tenant_id = t.id
  and p.slug = 'lamination'
  and (p.status <> 'archived' or p.availability <> 'unavailable');

-- ── A4 Lamination ──────────────────────────────────────────────────────────
insert into commerce.products (
  tenant_id, slug, name, description, currency, availability, status, source_system, source_ref
)
select
  t.id,
  'a4-lamination',
  'A4 Lamination',
  'A4 sheets laminated by our team at the Café.',
  'ZAR',
  'available',
  'published',
  'quick_solution',
  'a4-lamination'
from public.tenants t
where t.slug = 'quick-solution'
  and not exists (
    select 1
    from commerce.products p
    where p.tenant_id = t.id and p.slug = 'a4-lamination'
  );

insert into commerce.service_product_configs (
  tenant_id, product_id, source_key, customer_definition,
  pricing_version, pricing_definition, status, sort_order
)
select
  t.id,
  p.id,
  'a4-lamination',
  $customer${
    "id": "a4-lamination",
    "name": "A4 Lamination",
    "shortName": "A4 Lamination",
    "category": "Quick Print",
    "description": "A4 sheets laminated by our team at the Café.",
    "plainDescription": "Bring your A4 sheets and we will laminate them for you.",
    "keywords": ["laminate", "laminating", "lamination", "a4", "sheet", "sheets"],
    "popular": false,
    "active": true,
    "channels": {"storefront": false, "guided": false, "pos": true, "quote": false, "advanced": false},
    "pricing": {"strategy": "PER_UNIT", "unitPrice": 15, "minUnits": 1, "maxUnits": 100},
    "fields": [
      {"id": "units", "type": "number", "label": "How many A4 sheets need laminating?", "shortLabel": "Sheets to laminate", "suffix": "sheets", "help": "Count each sheet once, even if it is printed on both sides.", "min": 1, "step": 1, "required": true}
    ]
  }$customer$::jsonb,
  '2026-09-qsc-17',
  $definition${"strategy": "PER_UNIT", "unitPrice": 15, "minUnits": 1, "maxUnits": 100}$definition$::jsonb,
  'published',
  24
from public.tenants t
join commerce.products p
  on p.tenant_id = t.id
 and p.slug = 'a4-lamination'
where t.slug = 'quick-solution'
on conflict (tenant_id, source_key) do nothing;

-- ── A3 Lamination ──────────────────────────────────────────────────────────
insert into commerce.products (
  tenant_id, slug, name, description, currency, availability, status, source_system, source_ref
)
select
  t.id,
  'a3-lamination',
  'A3 Lamination',
  'A3 sheets laminated by our team at the Café.',
  'ZAR',
  'available',
  'published',
  'quick_solution',
  'a3-lamination'
from public.tenants t
where t.slug = 'quick-solution'
  and not exists (
    select 1
    from commerce.products p
    where p.tenant_id = t.id and p.slug = 'a3-lamination'
  );

insert into commerce.service_product_configs (
  tenant_id, product_id, source_key, customer_definition,
  pricing_version, pricing_definition, status, sort_order
)
select
  t.id,
  p.id,
  'a3-lamination',
  $customer${
    "id": "a3-lamination",
    "name": "A3 Lamination",
    "shortName": "A3 Lamination",
    "category": "Quick Print",
    "description": "A3 sheets laminated by our team at the Café.",
    "plainDescription": "Bring your A3 sheets and we will laminate them for you.",
    "keywords": ["laminate", "laminating", "lamination", "a3", "sheet", "sheets"],
    "popular": false,
    "active": true,
    "channels": {"storefront": false, "guided": false, "pos": true, "quote": false, "advanced": false},
    "pricing": {"strategy": "PER_UNIT", "unitPrice": 30, "minUnits": 1, "maxUnits": 100},
    "fields": [
      {"id": "units", "type": "number", "label": "How many A3 sheets need laminating?", "shortLabel": "Sheets to laminate", "suffix": "sheets", "help": "Count each sheet once, even if it is printed on both sides.", "min": 1, "step": 1, "required": true}
    ]
  }$customer$::jsonb,
  '2026-09-qsc-17',
  $definition${"strategy": "PER_UNIT", "unitPrice": 30, "minUnits": 1, "maxUnits": 100}$definition$::jsonb,
  'published',
  25
from public.tenants t
join commerce.products p
  on p.tenant_id = t.id
 and p.slug = 'a3-lamination'
where t.slug = 'quick-solution'
on conflict (tenant_id, source_key) do nothing;
