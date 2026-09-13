# QS-04C Setup — OPPS Handoff UI + subtle visual polish

## What this patch adds
1. **Admin handoff queue UI** inside Product Admin:
   - list Quick Solution orders
   - preview canonical OPPS payload
   - show blockers / warnings
   - send clean orders to OPPS
   - quick follow-up buttons to open the OPPS app and copy the OPPS order ID
2. **Storefront polish**:
   - subtle visual story rail
   - product card artwork panels so the site feels lighter and less text-heavy

## Files in this patch
- `src/admin/AdminOppsHandoffPanel.jsx`
- `src/admin/AdminProductManager.jsx`
- `src/components/SubtleStoryRail.jsx`
- `src/components/ProductScene.jsx`
- `src/components/ProductCard.jsx`
- `src/components/Icon.jsx`
- `src/lib/supabaseApi.js`
- `src/App.jsx`
- `src/main.jsx`
- `src/styles/qs04c.css`

## Apply steps
Copy the patch files into the matching paths in your repo, then run:

```powershell
npm run dev
```

## Optional env
If you want the “Open OPPS app” button to use a different base URL, add:

```env
VITE_OPPS_APP_URL=https://ops.jointx.co.za
```

## Backend dependency
This UI expects the earlier backend phases to already exist:
- `admin_list_quick_solution_opps_handoffs`
- `admin_preview_quick_solution_opps_handoff`
- `admin_send_quick_solution_order_to_opps`
