# Café shared payments and customer accounts

## Approved direction

Keep guest checkout. Add a lightweight verified customer account for order history,
tracking, paying the original outstanding order and receipts. Build payment consistency
before enabling customer payment resumption or staff cash/EFT recording on all orders.

## Verified baseline, 12 October 2026

Inspected Café main d36cf744 and OPPS main 079c1b03 plus staging database definitions.
No production financial records changed.

- Café balances read completed commerce.service_order_payments.
- commerce._qs_sync_opps_payment_ledger copies an aggregate into public.transactions
  at production handoff. It uses ON CONFLICT(order_id) DO NOTHING.
- public.transactions has a unique order_id index. It is currently an order-level
  aggregate, not a multiple-receipt ledger. Do not remove the index as an incidental fix.
- OPPS OrderDrawer creates, edits and deletes transactions directly. Its payment
  projection updates only the OPPS order; it does not update Café receipts.
- OPPS invoices separately use invoice_payments and record_manual_invoice_payment.
  Its cross-source guard checks X LAB payments, not Café payments.
- The staging audit found a linked order with Café paid 0 / OPPS paid 14, and a
  paid Café-only order with 60 received. These are staging observations, not live losses.
- Tracking and payment tokens are separate. Tracking currently displays payment
  status but does not provide a verified customer-account ownership relationship.

## Implementation contract

1. Assign each real receipt a stable identity; retries retain that identity. Keep
   financial reporting projections distinguishable from original receipts.
2. Route Café and OPPS actions for Café-originated payments through the same
   server-side service. Check tenant, actor capability, currency, amount and order
   state under a shared order lock. No client-computed paid flag is authoritative.
3. Record cash received or verified EFT, reference, actor and server timestamp.
   Checkout payment intent is not receipt. EFT proof alone is not verification.
4. Publish Café income to OPPS Finance independently of production handoff.
   Later handoff links the existing financial projection, never adds a second receipt.
5. Replace editable/deletable projections for Café payments with audited correction
   operations; include the OPPS invoice entry point in duplicate/overpayment guards.
6. Reconcile legacy discrepancies explicitly. Never add both existing totals or
   automatically overwrite manual entries. Keep unresolved records blocked for review.
7. Collection, customer balance, OPPS order and linked invoice must consume the same
   settled amount. Cash-up preserves original method/date; reversals stay auditable.

## Delivery sequence

First: shared receipt/projection schema and atomic write service, with OPPS integration.
Second: Café Record payment UI and collection flow, then staging device verification.
Third: customer account ownership, My orders and original-order payment resumption.

Account sign-in uses the existing auth system, without granting staff membership.
Historical guest orders require verified ownership; names, arbitrary supplied email,
phone and order number alone are insufficient. Keep secure guest links. Do not store
staff credentials in a new customer auth implementation. Validate configured email/
OAuth delivery and redirect settings before choosing the first sign-in method.

## Required acceptance checks

- Cash/EFT recorded from either staff UI appears once, with equal balances everywhere.
- Paid Café-only job appears in Finance without entering the production queue.
- Subsequent production handoff cannot duplicate its receipt.
- Retry, concurrent staff entry and gateway callback cannot double-settle an order.
- Existing invoice/Café receipts block duplicate manual payment.
- Corrections/reversals propagate with an audit trail; no direct projection edits.
- Partial, outstanding, cancelled, refunded and cross-tenant cases fail safely.
- Account A cannot read, claim or pay using account B's authorization.
- Guest checkout remains available; return-to-pay uses the original order.
- Release audit findings are reviewed rather than silently repaired.

Status: staging manual-payment implementation below supersedes the read-only checkpoint.
Customer accounts are not implemented.

## Read-only implementation checkpoint

Added qs_staff_payment_state and an Admin Payment record panel. The function is deployed
to staging only. It exposes receipt history and compares linked balances without adding
them together. Missing links, mismatches, unsupported invoice reconciliation and inconsistent
paid flags return a null balance plus review reasons. This is read-only and does not yet
guard existing payment writes, record cash/EFT, reconcile receipts, or implement accounts.
Staging SQL verification checks staff/nonmember/anonymous access and balance behavior.
Authenticated SECURITY DEFINER access is intentional, with tenant capability checks, revoked
anonymous access and fixed empty search_path. No financial rows were changed.

## Manual-payment staging checkpoint, 13 October 2026

Café Admin now records the full outstanding balance as Cash or verified EFT. EFT requires
bank reference and explicit verification. The atomic service stores actor, receipt identity,
time and reference, and creates the OPPS Finance projection without creating a production job.
Retries reuse the receipt. Later production handoff links the same Finance row. Direct
staff edits to managed projections and duplicate invoice receipts are blocked.

The quick-job flow from PR22 is included in this branch so a settled eligible job can move
from ready to collected in the same preview. Production remains unchanged.

Verified in rollback-only staging SQL: Cash/EFT, reference validation, retry identity,
changed retry rejection, duplicate rejection, Finance before production, actual handoff
reusing the Finance row, direct-edit protection, invoice duplicate guard, unauthorized
replay, and ready/collected. Component tests cover explicit receipt confirmation, stable
retry keys after network failure, EFT requirements and review/closed controls.

Remaining gates: linked invoices and legacy discrepancies require reconciliation; OPPS's
independent payment form is not yet routed through this service. Existing counter/gateway
payment paths are not migrated by this slice. Pending PayFast attempts block manual receipt.
Partial payments, audited corrections/reversals, concurrency integration testing, customer
accounts and device acceptance remain outstanding. Keep PR24 draft and staging-only.

Security advisor review: the new authenticated SECURITY DEFINER warning is intentional.
The entry point performs tenant capability authorization before reads/replays, uses an empty
search_path, and denies anonymous execution. Internal projection/trigger functions are revoked.
Final local suite: 789 passed, 8 skipped; production build passed.


## OPPS shared-entry checkpoint, 15 October 2026

The companion OPPS branch `feat/cafe-shared-payment-entry` routes Café-originated
orders to the same receipt writer. A server-side OPPS order resolver checks the
active Quick Solution tenant and `payments.manage`; it does not trust a browser
Café order/tenant link. Existing Café operations access stays supported. This grants
no new operational role: OPPS payment operators use their existing payment authority.

Independent direct Finance income writes for Café orders are rejected, including
legacy rows and new rows that omit the source marker. OPPS shows the original
receipt record and removes edit/delete actions for those orders. Price differences
between linked orders now block collection alongside legacy receipt/invoice issues.

Applied the shared-entry and permission-alignment migrations to staging only.
Bounded rollback SQL verified OPPS authenticated Cash/EFT, cross-app replay identity,
one Finance row, equal balances, missing EFT reference, unauthorized read/replay,
function grants, price mismatch and invoice conflicts. Independent Finance receipt
insert was rejected. The full connector test stalled; it was split into bounded
checks. Direct edit/delete execution is not claimed by this checkpoint.

OPPS component tests cover confirmation, EFT reference, rapid double submission,
stable retry identity, review/closed/paid/error states and query refresh. The
focused OPPS suite passed 63 tests, Café receipt UI passed 3 tests, and OPPS build
passed. Operator device acceptance of OPPS entry remains pending. No production
financial records were changed. Linked-invoice settlement, corrections/reversals,
partial payments and gateway concurrency remain release gates; PR24 stays draft.

## Invoice receipt identity checkpoint, 16 October 2026

The shared receipt remains the original financial record. `invoice_payments.qs_payment_id`
identifies its invoice projection, with one invoice row per receipt and no second Finance
income. Café/OPPS payment entry projects into one approved, matching ZAR invoice in the
same transaction. Invoice Cash/EFT entry delegates to the same full-balance writer,
retains invoice finance authorization plus tenant payment permission, and preserves the
ordinary invoice implementation for all other sources. Existing proof linking is reused.
The original receipt retains its server timestamp and actor; requested date/note are audit
context. New historical entries are refused rather than silently backdated; existing
receipt replays remain allowed on later dates.

A payment recorded before invoice creation offers **Sync existing invoice receipts** in
both order payment panels. This is an explicit, authorized, idempotent projection operation;
it does not create money. It is offered only for a missing invoice projection with no
other issues. Equal legacy Finance totals without a managed receipt identity, independent
invoice receipts, multiple invoices, draft/void invoices, price/currency differences and
inconsistent paid flags remain review-blocked. Receipt-bearing invoices cannot be detached,
repriced or voided through ordinary edits, and invoice projections are immutable.

Staging rollback checks passed for linked Cash, invoice-entry EFT, required EFT reference,
full-balance enforcement, retry/changed-retry rejection, one original/Finance/invoice row,
equal balances, receipt-before-invoice sync, currency/draft/multiple-invoice conflicts,
independent invoice receipt rejection, nonmember denial, private-helper grants, and ordinary
invoice partial-payment regression. All test receipt rows were rolled back. No production
schema or financial records changed. Cash/EFT and automatic refresh mobile acceptance from
15 October remain valid; invoice-linked device acceptance is still pending.

Security review: private helpers are revoked from authenticated/anon/PUBLIC; the checked
`qs_reconcile_invoice_receipts` endpoint intentionally runs SECURITY DEFINER with an empty
search_path. Its [authenticated-definer advisor warning](https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable)
was reviewed with tenant access and execution-grant tests. Existing unrelated advisor findings
were not changed by this slice.

Still staging-only/draft: linked-invoice mobile and multi-session concurrency acceptance,
gateway/counter writer integration, partial Café receipts, audited correction/reversal flows,
and explicit legacy reconciliation remain release work. Customer accounts follow payment
consistency; they are not part of this checkpoint.

Current focused verification: Café 8 tests and build passed; OPPS 60 focused payment/proof
and component tests plus build passed. The invoice-row edit and receipt-bearing invoice
repricing guards were executed successfully in rollback tests. Direct receipt deletion and
actual concurrent multi-session execution are not claimed by this checkpoint.
