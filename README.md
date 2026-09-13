# Joint X Quick Solution Café — QS-02 / V1.5

Quick Solution Café is the customer-facing convenience and branding layer of Joint X. This prototype is designed around one product catalogue powering guided customer ordering, advanced configuration, future counter POS, quotes and OPPS production.

## Run locally

```powershell
npm install
npm run dev
```

Open the local URL Vite prints in the terminal.

## Customer storefront

The default view is the storefront. V1.5 adds two deliberate ordering modes:

- **Guided** — one question at a time, plain language, large choices, guest-friendly.
- **Full options** — the complete technical configurator for experienced customers and staff.

Quick-task cards such as "Print my CV or forms" now open the guided journey rather than dropping a customer into a large form.

## XOS Product Admin prototype

Open:

```text
http://localhost:5173/#admin
```

(or use whatever port Vite gives you).

The admin prototype can:

- turn products live/off,
- control storefront / guided / POS / quote availability,
- edit customer-facing product wording,
- edit core pricing modifiers,
- save the catalogue to localStorage,
- export the current catalogue as JSON,
- reset back to the code-defined demo catalogue.

This is intentionally local-only in QS-02. Supabase persistence, permissions, audit history and tenant controls belong in the backend phase.

## Product/pricing architecture

Current pricing strategies:

- `PER_AREA` — banners / large format
- `PER_PAGE` — documents
- `TIERED` — business cards
- `CONFIGURABLE` — garments + print options

Each order calculation returns a pricing snapshot containing:

- product ID and name,
- pricing strategy,
- pricing version,
- selected configuration,
- calculation lines and metrics,
- total,
- capture timestamp.

The goal is that website, future POS, quote/invoice and OPPS production all consume the same configured item rather than reconstructing it in separate systems.

## Guided-order schema

Guided journeys are defined separately from the underlying product fields. This means the same product can be sold through different experiences without creating duplicate pricing logic.

Examples included:

- document printing,
- PVC banner,
- business cards,
- printed T-shirt.

A journey controls which questions appear on each step, while the final price still comes from the shared pricing engine.

## Brand / UX principles

- Apple/Tesla-style restraint: mostly warm white, black and neutral surfaces.
- Joint X green (`#008B72`) is the primary action colour.
- Lilac (`#D7BFFF`) is used for guidance/support states.
- Orange (`#CC3300`) is used sparingly.
- Plain-language outcome first, technical terminology second.
- Guest-friendly quick orders; account creation should be optional for low-friction jobs.
- Large touch targets, visible focus states and reduced-motion support.
- Human help remains available through WhatsApp.

## Verification performed here

- JSX/JS files were syntax-parsed with the TypeScript compiler parser.
- Default pricing calculations were executed for all four demo products.
- `npm install` was attempted in this environment but timed out before packages could be downloaded, so the full Vite production build could not be run here.

## Next phase — QS-03

Recommended next build:

1. Supabase catalogue tables + tenant ownership.
2. Product-admin persistence and role permissions.
3. Quote/order persistence with pricing snapshots.
4. Customer/contact capture without forcing accounts.
5. Fulfilment records for Café / Quick Point / local delivery.
6. OPPS handoff contract for production specs.


## V1.5 UX update
- Guided ordering is now the default entry for every product that supports it.
- Product cards and product tabs now open Guided first instead of Full options.
- Full options remains directly beside Guided and receives a one-time, subtle lilac spotlight animation so experienced customers notice it without distracting everyday users.
- The animation stops automatically, never loops, and is disabled by `prefers-reduced-motion`.
- Mode labels explain the difference: Guided = recommended; Full options = exact specs.
