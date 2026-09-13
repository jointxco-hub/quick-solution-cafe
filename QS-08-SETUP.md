# QS-08 — PayFast payment foundation

## What is already live on XOS Staging

- `20260913193609_qs_08_payfast_payment_foundation`
- `20260913193947_qs_08_delivery_payment_guard`
- Edge Function `quick-solution-payfast` version 2
- Shared `payfast-notify` version 19 now routes `custom_str2=quick_solution` into the Quick Solution payment reconciler.

The database now:
- issues a separate 32-byte payment token per Quick Solution order,
- stores only the SHA-256 token hash,
- derives the amount from the canonical service order,
- records PayFast attempts separately,
- rejects amount mismatches,
- updates the Quick Solution order and linked OPPS order when payment completes,
- removes the `PAYMENT_NOT_PAID` handoff warning after reconciliation,
- blocks PayFast for delivery orders until the delivery fee is confirmed.

## UI patch

Run this once from the Quick-Solution-Cafe project root:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\apply-qs08-ui.ps1
```

Then:

```powershell
npm run dev
```

The confirmation screen gains:
- `Pay securely with PayFast`
- `Check payment`
- paid/unpaid status
- delivery-payment guard copy

Orders Admin also changes timestamps to:
- `Today 12:53`
- `Yesterday 16:08`
- older items: compact date only
- full dates remain available as hover/technical metadata

## Safety note

Opening a PayFast URL does not itself charge anything, but the existing staging PayFast environment may point at sandbox or live credentials. The returned payment URL contains a `sandbox` flag in the backend response. Only complete an actual payment when you intend to test that environment.

## Source control

The shared `payfast-notify` function belongs to the wider XOS payment perimeter and was updated directly in staging to version 19. This Quick Solution patch records the new Quick Solution-specific function and migrations; it does not duplicate the shared PayFast handler source into this repo.
