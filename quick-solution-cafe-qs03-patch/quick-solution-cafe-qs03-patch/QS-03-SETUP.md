# QS-03 — Supabase order intake foundation

QS-03 moves Quick Solution from a local catalogue prototype to a staging-backed storefront.

## Already applied to Joint X XOS Staging

The migration `20260913155351_qs_03_quick_solution_foundation.sql` is already applied to Supabase project **Joint X XOS Staging** (`tijiamrfnxrbitafiflj`). Do not re-run it manually against that same staging project.

The staging database now has:

- a dedicated `quick-solution` tenant for Location 001;
- four published service products: PVC Banner, Document Printing, Business Cards and Printed T-shirt;
- server-side canonical pricing for `PER_AREA`, `PER_PAGE`, `TIERED` and `CONFIGURABLE` products;
- `commerce.service_orders` and `commerce.service_order_items` for safe storefront intake;
- immutable JSON pricing snapshots on each submitted item;
- `commerce.fulfilment_points`, with Location 001 seeded as the first collection point;
- RPC-only public access. The browser does not receive direct write access to the commerce tables.

The OPPS handoff is intentionally **not automatic yet**. QS-03 stores the order safely first. A later phase will map approved Quick Solution jobs into the canonical OPPS order/production model.

## Apply this patch to your one working folder

Copy the contents of this patch over the existing project root:

`Quick-Solution-Cafe/`

Do not create a `v1.6` project folder. Git is now the version history.

## Create `.env.local`

Create a file called `.env.local` in the project root. Use:

```env
VITE_SUPABASE_URL=https://tijiamrfnxrbitafiflj.supabase.co
VITE_SUPABASE_PUBLISHABLE_KEY=sb_publishable_OsHRZWMCvbR7O175TJRY8w_E5hLght8
VITE_QS_TENANT_SLUG=quick-solution
```

The publishable key is intentionally a browser-safe public key. Never put service-role or secret keys in Vite environment variables.

Restart Vite after creating or editing `.env.local`:

```powershell
npm run dev
```

## What to test

1. Open the storefront and confirm the footer says `Live staging catalogue`.
2. Start with **Print homework or notes** or **Print my CV or forms**.
3. Complete the Guided flow.
4. On the review step, add a name and either phone/WhatsApp or email.
5. Choose Café collection and create the order.
6. Confirm that a real `QS-...` order number appears.

The backend recalculates the price before storing the order. The browser's estimate is not trusted as the authoritative total.

## Current intentional limitations

- Guided ordering is the live QS-03 submission path. Full Options is still a configuration/estimate path.
- The file picker currently records the selected filename only. The actual file bytes are **not uploaded yet**. The staging confirmation offers a WhatsApp bridge for the file.
- Location 001 is live in the fulfilment model. Real community Quick Points have not been seeded until their business/location details are confirmed.
- The existing `#admin` catalogue editor still writes to localStorage. Remote Product Admin persistence is a later step.
- Delivery addresses can be captured, but the delivery fee is marked for confirmation instead of inventing a price.

## Commit after testing

```powershell
git add .
git commit -m "QS-03 Supabase order intake foundation"
git push
```

## Next

QS-03.1 should add private file uploads and order-file linking, followed by real Quick Point selection / Easy Locate references. After that, QS-04 can implement the explicit OPPS handoff.
