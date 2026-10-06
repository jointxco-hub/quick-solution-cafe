# Signage supplier research and Café rollout

Checked 6 October 2026. Public catalogue prices are references, not approved reseller quotations. No supplier has been contacted or endorsed for quality.

## Catalogue additions

Added Flyers, Correx Boards, Pull-up Banners, Car Magnets, Posters, Shop Signs & Rigid Signage, Folded Leaflets & Menus, Booklets, Branded Notepads, Presentation Folders, Branded Calendars and Contravision with Installation as guided quote requests. They capture specifications and artwork without presenting a zero-cost payable product. Existing media requests retain their date/location requirements. Print/signage requests use supply/site details and a distinct `print_signage` request type.

Contravision Window Printing is a thirteenth addition with a configurable rectangular print-only price. One panel per configuration; installation and contour cutting are separate requests. Existing checkout calculates the final authoritative total and stores its pricing snapshot.

## Supplier comparison

| Supplier / source | Published reference | Modelling value | Unresolved costs |
| --- | --- | --- | --- |
| [AdverTech printing services](https://www.adver-tech.co.za/product-category/printing-services/) | Contravision R180/m² excluding VAT | Clear area-rate and tax basis | Freight, minimums, roll width, protective laminate and fitting |
| [Printsmith Contravision](https://www.printsmith.co.za/product/contravision-one-way-vision-film/) | R160/m² | Lower advertised base rate | VAT basis and comparable specification/landed cost |
| [Signmart framed Chromadek](https://signmart.co.za/product/chromadek-signs/) | Printed sheet, black steel frame and assembly: stock sizes below | Clearest framed-sign model among inspected pages | VAT, delivered cost and site-specific installation |
| [Flyerz shop](https://flyerz.co.za/shop/) | Broad print/display range | Candidate for standard repeat products | Matching variant prices, trade terms and delivery |

Signmart framed supply references, metres: 1×1 R1,750; 1.2×0.8 R1,750; 1.2×1 R2,025; 1.2×1.2 R2,075; 1.2×1.5 R2,350; 2×1 R2,850; 2.45×1.2 R3,750; 3×1.2 R4,250; 4×1.2 R6,050. Custom trimming uses the next stock size. Unframed laminated sheet is R950 per running metre at 1.2m width, minimum one metre, factory collection only. Design is additional. Sheets over 1.225m width require joins.

Price clarity does not establish the best supplier. Compare a matching job's delivered cost, workmanship, material thickness, turnaround and installation coverage before selecting one. Old PDFs and snippets with uncertain VAT are not executable rates.

## Contravision staging model

Supplier reference R180 ex VAT × 1.15 = R207 cash cost. Existing Café gross-margin convention: R207 ÷ (1 − 0.50) = **R414/m²** selling rate. This is a suggested staging rate, not a market-price finding. A 1m² minimum is a disclosed Café policy, not an asserted supplier minimum. Existing artwork fees are R0 ready / R75 check / R250 design. Freight, installation and shaped trimming are excluded. The current model uses VAT-inclusive cash cost conservatively; finance should confirm recoverable-input-VAT treatment and output-tax presentation before launch.

The existing PER_AREA admin can edit the selling rate and minimum. Supplier source/cost/margin metadata resides in staff-only `operations_definition`, outside the public catalogue. Reconfirm delivered cost and maximum workable panel width before production rollout. The 0.1–20m input range validates numeric input; it is not a promise that a seamless 20m print can be supplied. Counter visibility is a preview: existing counter submission readiness is unchanged.

## Alethea pricing model to build when rates are confirmed

Keep supplier selection behind the customer configuration. Give each supplier rate its material, thickness, finish, unit basis, tax basis, minimum, sheet/roll limits, freight rules, geographic coverage, validity date and source evidence.

1. Match the job specification. Reject suppliers that cannot provide its material, finish, dimensions, kit or location. Unknown costs return a quote requirement, never zero.
2. Price using the supplier's unit: area for vinyl/boards; both dimensions and permitted rotation for framed stock sizes; running length plus usable roll width for sheet stock; fixed kit variants for displays. Area alone cannot select a fitting frame. Account for joins, waste, double-sided printing and minimums.
3. Add confirmed freight, finishing, installer labour, travel and access equipment on one consistent VAT basis. Installation remains quote-based until a site assessment and installer rate are available.
4. Compare complete landed costs and supplier capability. Compute selling price as `landed cost / (1 − target gross margin) + design/service fees`, with tax treatment applied consistently. Preserve the current order's supplier reference and price snapshot; changing a rate must not reprice previous orders.
5. Let staff approve exceptions and record the reason. Promote only verified repeatable variants to instant checkout; leave bespoke/structural/illuminated work in the guided quotation flow.

This change implements the guided intake and the simple Contravision area model. Automatic multi-supplier selection and installation pricing are deliberately deferred until the required rate data exists.

## Implementation and validation

Migration `20261006181706_supplier_catalogue_signage.sql` inserts missing products/configurations by tenant slug and preserves existing rows. It retains the previous pricing calculator in a private, non-exposed base function; the public-facing wrapper validates only the new Contravision contract and adjusts print enquiry wording. No new public RPC or direct table access is granted. The existing service-request RPC retains its signature and changes only the new request-type classification.

`scripts/build-supplier-catalogue-sql.mjs` regenerates additive catalogue data from the customer definitions into a temporary SQL file. Historical rollout tests use an explicit baseline of the original 12 products; the new catalogue suite tests the complete 25-product seed and all 13 additions.

Validation: full Node test suite and Vite production build; staging transaction tests for pricing, invalid dimensions, unpriced installation rejection, quote contracts, public supplier-data privacy and a service-request creation with no media date. Test orders are rolled back. Staging migration applied successfully; the committed catalogue, privacy checks and private delegate permissions were verified. Full suite: 765 passed, 8 skipped, no failures; production build passed. Existing security advisor findings were not expanded by this change. Production deployment is not part of the staging validation.
