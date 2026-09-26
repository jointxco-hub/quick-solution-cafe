-- CAFE-GUEST-01K: finalize Scan ('scan', "Document Scanning") and make it live.
--
-- Confirmed business decision: R5 per scanned page, minimum 1 page, maximum 300
-- pages per order. 1 unit = 1 scanned page (one side of one sheet, counted once);
-- the runtime count is { units }, never configuration.quantity.
--
-- CAFE-GUEST-01H (20260926150000) created Scan not live and unpriced (unitPrice 0,
-- maxUnits 0, which the PER_UNIT contract rejects). That migration is not rewritten;
-- this forward migration moves the ONE existing row to the approved starting values:
--   pricing_definition        { strategy PER_UNIT, unitPrice 5, minUnits 1, maxUnits 300 }
--   customer_definition       pricing = the same four keys (the mirror the admin save
--                             enforces), active true; everything else - the channels
--                             above all - is left exactly as it is
--   config status             'published'
--   product                   status 'published', availability 'available'
--   pricing_version           '2026-09-qsc-18' (a stale admin copy is told to reload)
-- LIVE follows the established convention: every earlier seeded product with an
-- approved price (QS-11, QS-12, QS-14, and A4/A3 Lamination in 01J) was seeded
-- published + available + active, and there is no separate publishing step.
--
-- Scan stays counter-only: pos true; storefront, guided, advanced and quote false,
-- untouched here. The public catalogue requires channels.storefront not false, so it
-- never returns Scan even though it is live, and the storefront order-item guard
-- (CAFE-GUEST-01C) still refuses it on a storefront order.
--
-- LATER ADMIN EDITS ARE PROTECTED. The update runs only while the row is still
-- EXACTLY what 01H seeded: pricing_version '2026-09-qsc-15', config status 'draft' and
-- the pending definition. Any admin save issues a new pricing_version, so once anyone
-- has saved Scan (a new price, a new maximum, taking it offline again...) a re-run
-- matches nothing and changes nothing. The product row is updated in the SAME
-- statement, only for the row just finalized, so an admin who has since unpublished
-- Scan can never have it republished by a replay. This migration therefore also cannot
-- turn an admin-edited price back into R5. If no such row exists nothing happens.
--
-- Nothing else is touched: not A4/A3 Lamination, not the retired placeholder, not the
-- original nine products; no function, grant or table is created.
--
-- Deliberately no BEGIN/COMMIT: the Supabase CLI applies each migration file
-- atomically, and leaving them out lets the SQL contract test re-apply this file
-- inside its own rolled-back transaction.

do $preflight$
begin
  if not exists (select 1 from public.tenants t where t.slug = 'quick-solution')
     or to_regprocedure('commerce._qs_validate_per_unit_definition(jsonb)') is null
     or to_regprocedure('public.admin_update_quick_solution_product(text,text,jsonb,jsonb,text)') is null then
    raise exception
      'CAFE_GUEST_01K_MIGRATION_PRECONDITION: the quick-solution tenant, commerce._qs_validate_per_unit_definition (01F) and the PER_UNIT-aware admin save (01G) must exist';
  end if;
  -- The approved definition must itself satisfy the one shared PER_UNIT rule.
  perform commerce._qs_validate_per_unit_definition('{"strategy": "PER_UNIT", "unitPrice": 5, "minUnits": 1, "maxUnits": 300}'::jsonb);
end
$preflight$;

with finalized as (
  update commerce.service_product_configs c
  set status = 'published',
      pricing_definition = '{"strategy": "PER_UNIT", "unitPrice": 5, "minUnits": 1, "maxUnits": 300}'::jsonb,
      customer_definition = jsonb_set(
        jsonb_set(c.customer_definition, '{pricing}', '{"strategy": "PER_UNIT", "unitPrice": 5, "minUnits": 1, "maxUnits": 300}'::jsonb, true),
        '{active}', 'true'::jsonb, true
      ),
      pricing_version = '2026-09-qsc-18',
      updated_at = now()
  from public.tenants t
  where t.slug = 'quick-solution'
    and c.tenant_id = t.id
    and c.source_key = 'scan'
    and c.pricing_version = '2026-09-qsc-15'
    and c.status = 'draft'
    and c.pricing_definition = '{"strategy": "PER_UNIT", "unitPrice": 0, "minUnits": 1, "maxUnits": 0}'::jsonb
  returning c.product_id
)
update commerce.products p
set status = 'published',
    availability = 'available',
    updated_at = now()
from finalized f
where p.id = f.product_id;
