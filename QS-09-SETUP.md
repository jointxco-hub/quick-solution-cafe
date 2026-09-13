# QS-09 — secure customer order tracking

QS-09 gives Quick Solution customers a no-account tracking experience without exposing private
OPPS or customer data.

## Backend already live on XOS Staging

- `20260913202423_qs_09_secure_customer_tracking`
- `20260913202552_qs_09_staff_tracking_links`

The backend now:
- issues a dedicated 32-byte tracking token on new/replayed Quick Solution orders,
- stores only SHA-256 token hashes,
- keeps tracking tokens separate from payment/upload tokens,
- allows secure direct tracking links for 180 days,
- supports fallback lookup using the exact order number + the checkout email/WhatsApp number,
- returns customer-safe order items, payment state, fulfilment, OPPS/production progress,
  customer-facing OPPS updates, and courier fields only,
- returns `null` for wrong tokens, wrong contacts and missing orders so the public endpoint does not
  reveal which part was incorrect,
- allows signed-in Quick Solution staff to create/copy a secure customer tracking link for an
  existing service order.

### Customer stage model

Collection:
`Received → Preparing → Ready to collect → Complete`

Delivery:
`Received → Preparing → On the way → Delivered`

Before OPPS handoff the tracker stays at **Received**.
Once the canonical OPPS order exists, its status/pipeline/production detail drives the tracker.

Production detail does not collapse merch into one vague "Production" state. If OPPS staff set
`production_detail_stage` or `production_client_update`, the Quick Solution tracker surfaces that
customer-safe detail.

## Apply frontend

Copy this patch into the Quick-Solution-Cafe repository, then:

```powershell
node .\scripts\apply-qs09-tracking.mjs
npm run dev
```

## Test

### New customer order
Create a new order after QS-09 is applied. The confirmation screen should have:

`Track this order`

Opening it should take you to:

`/track?order=QS-...&token=...`

The page should automatically load without asking for contact details.

### Manual lookup
Open `/track` from the navigation and enter:
1. the exact Quick Solution order number
2. the same email or WhatsApp number used at checkout

### Staff
Admin → Orders → select an order → **Copy tracking link**.

That issues a fresh secure tracking link without invalidating previous active links.

## Vercel

`vercel.json` is included so `/track` resolves to the Vite SPA when deployed.

## Commit

```powershell
git add .
git commit -m "QS-09 secure customer order tracking"
git push
```
