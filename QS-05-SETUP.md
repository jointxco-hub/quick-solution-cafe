# QS-05 — Quick Points admin

This patch turns the **Quick Points** tab into a working fulfilment-network manager.

## Included

- Live Quick Points admin inside `#admin`.
- Create and edit tenant-owned café / Quick Point records.
- Live / Coming soon / Inactive states.
- Collection and drop-off controls.
- Service capability toggles.
- Collection fee, contact details, address, coordinates and display order.
- Optional **Easy Locate business reference** for cross-system identity without copying Easy Locate's business record into XOS.
- Existing point slugs stay stable.
- A point type is protected once historical orders have used it.
- XOS prevents staff from disabling the last active café collection location.
- Active points immediately feed the storefront and Guided Order Quick Point selector.
- New orders now snapshot the chosen fulfilment point in `service_orders.source_metadata.fulfilmentPointSnapshot` so later location edits do not erase what the customer originally selected.
- Micro-fix: zero blockers now displays **Job checks** instead of contradictory **Needs attention**.

## Staging

Already applied to Joint X XOS Staging as:

`20260913183706_qs_05_quick_points_admin`

Do **not** run it manually against staging again.

## Acceptance already completed

- Authenticated admin list RPC returned the existing `Quick Solution Café · Location 001` record.
- A temporary Quick Point create was tested inside a transaction and rolled back successfully.
- Checkout fulfilment snapshot creation was tested inside a transaction and rolled back successfully.
- No fake Quick Point was persisted.

## Apply locally

Copy this patch into your existing project, then run:

```powershell
npm run dev
```

Open `#admin` and select **Quick Points**.

Suggested acceptance:
1. Confirm the existing café loads.
2. Click **Add Quick Point**.
3. Create one real partner or keep the test point as `Coming soon` if you are not ready to publish it.
4. Confirm an active Quick Point appears on the storefront and in Guided Order collection choices.
5. Switch it to `Inactive` and confirm it disappears from customer choices while remaining in Admin.

After acceptance:

```powershell
git add .
git commit -m "QS-05 manage Quick Points"
git push
```
