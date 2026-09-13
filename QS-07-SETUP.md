# QS-07 — Customer fulfilment selection + Easy Locate autocomplete

This phase makes the fulfilment network customer-facing and cleans up the staging acceptance data.

## Staging changes already applied

Migration already live on Joint X XOS Staging:

`20260913190841_qs_07_customer_fulfilment_choices`

It does two important things:

1. Separates **Bhungane Porcupine Enterprise** from the main Quick Solution café. Bhungane is now its own active `quick_point` and keeps the existing verified Easy Locate link.
2. The public Quick Solution catalogue now exposes a **safe verified Easy Locate snapshot** for customer-facing fulfilment choices. Private/admin-only data is not exposed.

The main café is deliberately left unlinked after the repair. In Quick Points Admin, search `joint` and link **Joint X Quick Solution Cafe** to Location 001.

## UI changes

- Easy Locate business search now auto-completes while staff type (280ms debounce, 2-character minimum).
- Old search responses cannot overwrite newer typed searches.
- Browser autofill is disabled for the Easy Locate search field.
- Long business descriptions are clamped to 4 lines.
- Guided ordering now shows actual café / Quick Point cards rather than a plain select menu.
- Verified Quick Points show Easy Locate identity, area, categories, collection fee and a `View on Easy Locate` link.
- Collection fees are included in the browser's estimated order total and shown separately in the summary.
- Storefront Quick Point section shows real verified local identity when available.

## Acceptance already run

A transaction-only customer order was created against the new Bhungane Quick Point and rolled back. It correctly used:

- fulfilment type: `quick_point`
- point: `Bhungane Porcupine Enterprise`
- area snapshot: `Riverside View · Extension 70`
- collection fee: `R0`
- order total: `R2.00` for the 1-page B&W test print

No acceptance order was persisted.

## Apply locally

Copy the patch files into the existing Quick-Solution-Cafe repo, then run:

```powershell
npm run dev
```

Acceptance checks:

1. `#admin` → Quick Points → choose Location 001 → Find business → type `jo`. Results should update automatically without pressing Search.
2. Link `Joint X Quick Solution Cafe` to Location 001.
3. Confirm Bhungane is a separate Quick Point and still shows its verified Easy Locate link.
4. Storefront → Guided order → fulfilment step → choose `Quick Point` → Bhungane should appear as a card with Easy Locate identity and `Free collection`.
5. `View on Easy Locate` should open the exact linked business listing.
