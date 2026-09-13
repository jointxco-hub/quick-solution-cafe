# QS-04A — OPPS handoff boundary

This patch is source-control only. The migration has already been applied to Joint X XOS Staging.

## Adds
- `quick_solution` as a valid OPPS order source.
- A guard so Quick Solution OPPS orders do not auto-mirror into X LAB.
- `commerce.service_order_handoffs` as the idempotent handoff ledger.
- A deterministic Quick Solution -> OPPS preview mapper.
- Staff RPCs for previewing/listing handoffs.
- Explicit tenant-access grants for Quick Solution in OPPS.

## Acceptance state
- `QS-260913-199B` -> READY, with private file mapped.
- `QS-260913-DBF4` -> BLOCKED: expected file missing.
- `QS-260913-D941` -> BLOCKED: expected file missing.
- All three are unpaid, which is a warning, not a blocker.

## Source-control step
Copy these files into the existing Quick-Solution-Cafe project. Do not re-run the migration on staging; it is already applied as `20260913174927_qs_04a_opps_handoff_boundary`.
