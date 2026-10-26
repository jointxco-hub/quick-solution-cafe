# OPPS → Café visibility: implementation contract (Issue #106)

Status: development branch; no production changes.

## Existing baseline
Shared Cash/EFT receipts and invoice projections are already live (18 October 2026). Never recreate or sum those records. The Counter Today endpoint is counter-channel scoped, so it must not be broadened silently.

## Phase 1 acceptance contract
1. Introduce a separate authorized Café Admin work queue for Café-tenant OPPS orders and standalone invoices. Keep Counter Today unchanged.
2. Server resolves tenant and permissions from authenticated identity. No client-supplied tenant, paid status, or invoice balance is trusted.
3. Return stable source IDs, source type, order/invoice number, amount, authoritative outstanding balance, payment state, production/collection state, and last-updated time.
4. A paid standalone invoice appears once with its original identity and R0 outstanding; it never offers Pay Now. The historical R90 OPPS-INV-2026-0002 is a read-only regression case.
5. Send to Café Counter is an explicit, authorized, idempotent fulfilment handoff. It creates a task reference, not a second invoice, order, receipt, or Finance entry.
6. Support retry, cross-tenant denial, revoked operator access, cancelled documents, refresh, and linked invoice/order deduplication.
7. Mobile: show status, action feedback, loading/empty/error states, and compact cards without long nested scrolling.

## Before implementing
Audit actual OPPS and Café database schemas, RLS, invoice/order queries and deployed production baseline. Decide queue source/view and whether handoff requires a new task table. Apply schema only to staging first. Verify backup/restore and read-only financial reconciliation.

## Tests / release gates
- Paid standalone invoice, unpaid standalone invoice, OPPS-created order, linked invoice/order, retry and concurrent handoff.
- Cross-tenant and unauthorized access, duplicate finance/receipt prevention, live refresh and mobile acceptance.
- No synthetic production payment or alteration to existing paid invoice.
- Separate PRs; no production deployment until verified staging acceptance.

## Phase 2 (not part of this branch's initial release)
Persisted transaction-specific QR using verified PayFast callbacks, exact outstanding amount, expiry and replay protection. No QR payment request for already-paid invoices.
