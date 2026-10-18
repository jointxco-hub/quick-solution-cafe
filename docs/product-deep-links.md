# Product and section links

Public canonical routes are `/products/<catalogue-id>` and `/shop`. Existing `/configure/<id>` links canonicalize to `/products/<id>#configure` without a reload. Product IDs remain the catalogue keys; changing a product name does not change its link.

Supported product anchors: `#configure` (pricing and ordering), `#delivery`, `#payment`, `#returns`, and `#artwork` when artwork guidance exists. Supporting accordions open automatically for incoming links. The product sharing area offers a section selector and Copy link, with a selectable-link fallback if clipboard permission is unavailable. Share on WhatsApp opens the recipient chooser with the selected product/section URL. WhatsApp help continues to open the Café conversation. Links use the current origin, so staging links remain staging links.

Public URLs contain navigation only. Basket/configuration, uploaded files, contact details and payment tokens are not encoded in shared links. Existing admin, counter, tracking and payment-return ownership is preserved. No database changes.

Product detail waits for the catalogue fetch to settle before showing the configurator, preventing a first interaction being reset when remote definitions replace fallback definitions. Fetch errors retain the existing local catalogue fallback. Missing, inactive or non-storefront products display the not-found screen without substituting another product.

## Verification

- Production build succeeds; full Node suite: 796 passed, 8 skipped.
- Added URL round-trip, configure alias, malformed URL and reserved-route tests.
- Staging browser checks: direct vinyl link; payment accordion expanded and positioned at 100px below viewport top; refresh retains product/section; Copy link places exact document ordering URL on clipboard; Back/Forward restores product and Shop; document configure alias canonicalizes; configurator scroll reaches 100px below top after render; unknown product resolves to not found.
- Shared vinyl link followed through all four guided steps, Add to order, and View basket: one vinyl item, R350. Checkout form available. No order submitted or payment initiated.
- Phone Safari verification remains a user acceptance check. Browser checks used desktop Chrome; no mobile viewport claim.

## Acceptance steps

1. Open a product link in a fresh phone tab, refresh and confirm the same product remains open.
2. Choose Pricing & ordering in the sharing area, Copy link, then paste/open it in a new tab. Confirm the ordering section is visible.
3. Repeat with Payment and Collection & delivery; confirm the correct accordion opens.
4. Navigate Back to Shop, open another product, then use browser Back/Forward.
5. Add an item, open the basket and continue to checkout. Check the item/total before submitting any real order.

This change is prepared on `feat/cafe-product-deep-links` for staging; production promotion is separate.
