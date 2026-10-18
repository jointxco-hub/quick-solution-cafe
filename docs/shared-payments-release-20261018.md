# Limited shared-payment release, 18 October 2026

Release branches start at Café main d36cf744 and OPPS main 079c1b03.
They include full-balance Cash/EFT receipt entry, invoice receipt identity/sync,
Café payment auto-refresh, and compatibility adapters for existing gateway/counter receipts.
They exclude QuickJob collection changes and the unrelated OPPS pricing, RBAC,
readiness and client-product changes from the larger staging branch.

Production is unchanged. Deployment is blocked by the Vercel connector returning
403 for team `joint-x`; no installed CLI fallback is available. Do not merge solely
to trigger an unverified deployment. The production schema must be migrated before
the new staff UIs are enabled, and production builds must use production configuration.
Never promote the staging deployment, which targets the staging database.

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
