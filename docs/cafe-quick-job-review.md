# Café quick jobs — staging review

Admin Orders now offers Handle at Café for café-collection orders containing only a4-print, scan, a4-lamination and a3-lamination. This applies to storefront and Counter orders; empty, mixed/complex, delivery/Quick Point, cancelled and OPPS-linked jobs are excluded by the server.

Mark ready asks for confirmation after work is finished. Mark collected asks for handover confirmation and is permitted only once completed ledger payments cover the total and payment is not pending, failed, cancelled or refunded. A paid label without ledger settlement does not suffice. This workflow never records money or changes payment status.

Both actions record authenticated operator and server time in Team activity. Repeated actions preserve the first record and never regress a completed order. The order lock serializes with existing payment, cancellation and OPPS send operations. A ready job may still be escalated to OPPS; once linked, local actions are refused. Completed jobs cannot be handed off.

Backend: public.qs_staff_quick_job(uuid,text), protected by cafe.operations.manage and the Café tenant. Existing activity RPC only accepts viewed/acknowledged and cannot forge ready/collected events. Direct table grants stay revoked. The advisor's authenticated SECURITY DEFINER notice is intentional; capability checks and empty search_path remain explicit.

Validation: 783 existing tests pass, 8 skipped; build passes. Staging SQL checks create temporary orders/payments, exercise role boundaries, mixed/empty/delivery/closed/linked eligibility, unpaid/partial/refunded payment gates, first-actor retries and closed handoff, then roll all changes back. Migration is applied to staging only.

Device review:
1. Open an unpaid simple café-collection order. Mark ready, confirm, and check the list status and Team activity.
2. Verify Mark collected stays disabled while money is outstanding.
3. On a settled test order, mark ready then collected. Verify Completed, operator/time, and absence of Send to OPPS.
4. Open a vinyl/banner or already handed-off job and verify no local fulfilment controls.

Production requires migration 20261011112610_cafe_quick_job_fulfilment.sql before merging. No production changes in this stage.
