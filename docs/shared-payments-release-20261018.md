# Limited shared-payment release, 18 October 2026

Release branches start at Café main d36cf744 and OPPS main 079c1b03.
They include full-balance Cash/EFT receipt entry, invoice receipt identity/sync,
Café payment auto-refresh, and compatibility adapters for existing gateway/counter receipts.
They exclude QuickJob collection changes and the unrelated OPPS pricing, RBAC,
readiness and client-product changes from the larger staging branch.

Production release completed on 18 October 2026. Both domains now run the shared
payment UI against production Supabase slhcvyeuqsduaglddqdb. The earlier Vercel 403
was caused by explicitly selecting team scope; authenticated default-account access
works, including deployment writes.

OPPS production had been deployed from CLI without Git metadata. Its archived
application/configuration digests identify baseline 94f8ef7 (159 matches after
Windows line-ending normalization, plus OrderDrawer content identity checked
separately). The OPPS release preserves that already-live baseline. It does not
regress production to older main 079c1b03 or add further unrelated staged features.

## Original and projected records

`commerce.service_order_payments` is the original receipt. Its stable identity maps
to one Finance aggregate (`transactions.qs_service_order_id`) and one invoice projection
per receipt (`invoice_payments.qs_payment_id`). Do not sum these copies together.
Existing ambiguous legacy entries stay review-blocked. Staff projections are immutable.

Invoice Cash/EFT delegates to the same full-balance service under a service-order-first
lock. Café invoice PayFast uses that same lock order and captures the original gateway
receipt before projecting it. Validated captured money is retained if a legacy/draft
invoice prevents projection, with a visible review flag. Invoice callback metadata uses
only the existing fee/net allowlist; ordinary invoice gateway behavior is preserved.
Existing already-settled late gateway notifications retain the prior ignore policy;
refunds and audited corrections are outside this release.

## Verification

- User desktop acceptance: invoice-first EFT QS-261018-76C0 / OPPS-INV-2026-0004,
  R350 paid once, zero due; payment-first Cash QS-261018-BB9C /
  OPPS-INV-2026-0005, R810 linked by explicit existing-receipt sync, zero due.
- Actual simultaneous staging test, service order
  0328e72e-3682-479b-8ef1-b8721ecefb1b, invoice
  bc0aa0ce-80a7-46c1-9185-2fc15095eb59: foreground backend 861600 held
  the service-order lock from 10:41:09.522 through 10:41:21.678 UTC. Invoice writer
  backend 861601 began at 10:41:09.086, slept four seconds, then waited on that lock.
  It ended at 10:41:21.701 with `This order cannot accept payment`. Final counts:
  one original receipt, one Finance row, one invoice row. Temporary pg_cron job 4
  was removed; no release test jobs remain. Fixtures are staging-only, explicitly
  labelled DO NOT FULFIL, and represent synthetic payments, not real funds.
- Earlier connector-parallel requests ran serially and are not concurrency evidence.
- Staging rollback SQL: invoice gateway capture/replay, distinct late callback ignored,
  staff-after-gateway rejection, metadata allowlist, captured receipt review on draft
  invoice conflict, ordinary invoice partial gateway payment, private helper grants,
  counter Finance before handoff and no duplicate on handoff.
- Prior rollback SQL covers shared Cash/EFT/invoice guards, permission denial,
  stable retry identity, reconciliation conflicts and existing-receipt sync.
- Café full JS suite: 792 passed, 8 skipped; build passed.
- Isolated OPPS: 37 shared-entry/invoice reliability/order-sync tests and 92
  manual-payment/proof/gateway tests passed; build passed.

Linked-invoice mobile acceptance is not claimed by the desktop screenshots. No real
PayFast charge was initiated by these SQL tests. Customer accounts, partial Café
receipts, audited corrections/reversals and automatic legacy repair are excluded.

## Release order after deployment access is restored

1. Recheck both main heads, linked projects/team and configured production database.
2. Re-run the read-only reconciliation audit; preserve discrepancies for review.
3. Apply only the nine new Café payment migrations, in filename order, to production.
   Do not use an unfiltered push from the broad OPPS staging branch. Apply migrations
   as a coordinated transaction/batch where possible so receipt guards and gateway
   adapters are not exposed independently during the rollout.
4. Build each release SHA with its own production environment, without assigning
   production aliases yet; verify build/configuration and the migration endpoints.
5. Release OPPS and Café, verify receipt reads and refresh on the live domains, then
   perform a controlled labelled acceptance order. Never record synthetic money on
   a real customer's order or trigger an actual gateway charge without authorization.
6. Roll back frontend aliases if needed. Keep original receipt records and forward
   schema safeguards; do not delete financial rows or blindly reverse migrations.

## Production outcome

- Atomic database batch: 20261018133044_cafe_shared_payments_release. The nine
  canonical migration versions were also registered in the same transaction.
  The matching no-op release marker keeps future migration history aligned.
- Café PR25 merged as cca817fad691be92322cc481d090afac1e84082c; production
  deployment dpl_7H5yV8C2iBFcjrH9eNyPGz8vqMXi is READY with cafe.jointx.co.za assigned.
- OPPS PR103 merged as c1958e1669dfa210611e7a5159c9f7a87ae28a4b; production
  deployment dpl_6EEJzDWRUvmMbTW6dtyy2Rhk6W6h is READY with ops.jointx.co.za assigned.
- Corrected OPPS live-baseline release passed 217 payment, invoice, proof,
  readiness and money tests and its production build.
- Both live HTML pages return HTTP 200. Café's served JS contains shared receipt
  read/write/sync and production DB reference, with no staging DB reference.
  OPPS main JS uses production DB reference; payment RPCs are in its lazy Orders
  module, checked separately.
- Production read-only reconciliation audit returned zero discrepancies.
- Production rollback smoke checks passed: invoice gateway capture/replay,
  counter Finance/handoff, metadata allowlist, retained capture on invoice
  conflict, ordinary partial regression, invoice EFT/replay, existing-receipt
  sync, nonmember and private-helper guards. Production has no scan catalogue
  product, so the initial scan fixture failed before any write and was replaced
  by the actual A4-print product. All synthetic order/payment tests rolled back;
  original counts remained 14 service orders / one paid order. No customer
  receipts were edited and no real gateway charge was initiated.
- Anonymous staff read/write and authenticated access to internal invoice/gateway
  helpers remain denied. Advisor delta is six intentional authenticated-definer
  endpoints, reviewed for fixed search paths and tenant authorization; other
  findings unchanged. See https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable .
- Authenticated browser/device acceptance of this production release and browser
  console/runtime telemetry are not claimed. Domain/backend/build checks passed.
