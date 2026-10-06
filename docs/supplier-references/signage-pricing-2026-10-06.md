## Current catalogue scope — owner refinement, 6 October 2026

Seven new storefront products remain: Flyers, Correx Boards, Pull-up Banners, Car Magnets, Posters, Shop Signs & Rigid Signage, and Contravision Window Printing. Folded Leaflets & Menus, Booklets, Branded Notepads, Presentation Folders, Branded Calendars and the standalone Contravision with Installation listing are archived. Historical order records are retained.

Contravision print supply remains R300/m², based on the confirmed R150/m² supplier cost with no supplier VAT. Application is an optional separately quoted add-on, not a paid print option. The product page offers a shop-window application-only request and a distinct Car Contravision vehicle quote through the signage enquiry flow. Customers should include their separate print order reference in an application request; automatic order linking is not implemented.

Car Magnets capture standard/custom size, sets of two and vehicle placement. Posters capture A3–A0/custom size, paper, finish and quantity. Shop Signs capture job type, supply versus application-only scope, material, panel dimensions, sides, frame, fitting and site/vehicle details. All three require a confirmed quote before payment. No unverified supplier rate is used for checkout. Admin configuration and controls are the next phase.

Earlier research below is retained as supplier reference; it does not describe the current live catalogue scope.

# Signage supplier research and Café rollout

Checked 6 October 2026. Public catalogue prices are references, not approved reseller quotations. No supplier has been contacted or endorsed for quality.

## Catalogue additions

Added Flyers, Pull-up Banners, Car Magnets, Posters, Shop Signs & Rigid Signage, Folded Leaflets & Menus, Booklets, Branded Notepads, Presentation Folders, Branded Calendars and Contravision with Installation as guided quote requests. Correx Boards now use standard-size supply pricing; bespoke Correx uses Shop Signs. Quote products capture specifications and artwork without presenting a zero-cost payable product. Existing media requests retain their date/location requirements. Print/signage requests use supply/site details and a distinct `print_signage` request type.

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

## Owner-confirmed local rate revision

The owner confirmed **R150/m² Contravision with no supplier VAT**. Current staging selling rate is **R300/m²** at 50% gross margin, with the disclosed 1m² minimum. The earlier AdverTech-derived R414 model is superseded; its web source remains a comparison reference. Existing artwork fees are R0 ready / R75 check / R250 design. Fitting, shaped trimming and protective laminate are not assumed included. Merchant name, usable roll width and fulfilment arrangements remain to be recorded. No supplier VAT is added; this does not determine Joint X's separate output-VAT obligations.

For Correx the owner recalled a possible R200 A0 supplier price, but explicitly directed an **R350 A0 cost allowance**. Smaller sizes use exact A-series halving factors, not rounded physical-dimension multiplication and not new merchant quotations:

| Standard size | Finished dimensions | Internal cost allowance | Selling price per board |
| --- | --- | ---: | ---: |
| A3 | 297 × 420 mm | R43.75 | R87.50 |
| A2 | 420 × 594 mm | R87.50 | R175.00 |
| A1 | 594 × 841 mm | R175.00 | R350.00 |
| A0 | 841 × 1189 mm | R350.00 | R700.00 |

Prices cover single-sided printed supply without mounting, plus artwork fees once per configured line. Custom dimensions, double sides, eyelets and installation use Shop Signs & Rigid Signage, now including Correx as a material. The standard product rejects unpriced extra specifications rather than silently ignoring them. Thickness, waste/yield and merchant minimums remain operational checks; no fabricated thickness or lead-time promise appears in the customer definition.

Correx uses the existing SUPPLIER_MARGIN admin editor in cost-margin mode; the zero VAT rate prevents a supplier-VAT uplift. Its staff cost fields are explicitly labelled as owner-approved allowances. Contravision uses the existing PER_AREA rate/minimum editor. Staff provenance is outside the public catalogue. Counter submission readiness is unchanged.

## Priority product imagery

Built-in image generation produced four matching studio product mockups. They are illustrative catalogue imagery, not photographs of fulfilled customer jobs. Final repo assets: `public/qs-catalogue/contravision-v1.webp`, `correx-boards-v1.webp`, `flyers-v1.webp` and `pull-up-banners-v1.webp`. They are wired through customer-safe `media.hero` metadata.

Prompt set: square, premium realistic studio product photography; warm off-white background; lilac/deep-green abstract print with restrained warm-red accent; centred whole product and no people, readable text, QR codes, price claims or watermarks. Subjects: white hatchback rear glass with perforated window vinyl; two unframed Correx boards showing fluted edges; a stacked A5 flyer set; and a complete upright pull-up banner with cassette, top bar and stabilising feet. Originals remain unchanged; web assets use compressed WebP derivatives.

## Alethea pricing model to build when rates are confirmed

Keep supplier selection behind the customer configuration. Give each supplier rate its material, thickness, finish, unit basis, tax basis, minimum, sheet/roll limits, freight rules, geographic coverage, validity date and source evidence.

1. Match the job specification. Reject suppliers that cannot provide its material, finish, dimensions, kit or location. Unknown costs return a quote requirement, never zero.
2. Price using the supplier's unit: area for vinyl/boards; both dimensions and permitted rotation for framed stock sizes; running length plus usable roll width for sheet stock; fixed kit variants for displays. Area alone cannot select a fitting frame. Account for joins, waste, double-sided printing and minimums.
3. Add confirmed freight, finishing, installer labour, travel and access equipment on one consistent VAT basis. Installation remains quote-based until a site assessment and installer rate are available.
4. Compare complete landed costs and supplier capability. Compute selling price as `landed cost / (1 − target gross margin) + design/service fees`, with tax treatment applied consistently. Preserve the current order's supplier reference and price snapshot; changing a rate must not reprice previous orders.
5. Let staff approve exceptions and record the reason. Promote only verified repeatable variants to instant checkout; leave bespoke/structural/illuminated work in the guided quotation flow.

This change implements guided intake, Contravision area pricing and standard-size Correx pricing. Automatic multi-supplier selection and installation pricing are deliberately deferred until the required rate data exists.

## Implementation and validation

Migration `20261006181706_supplier_catalogue_signage.sql` inserts missing products/configurations by tenant slug and preserves existing rows. It retains the previous pricing calculator in a private, non-exposed base function; the public-facing wrapper validates only the new Contravision contract and adjusts print enquiry wording. No new public RPC or direct table access is granted. The existing service-request RPC retains its signature and changes only the new request-type classification.

`scripts/build-supplier-catalogue-sql.mjs` regenerates additive catalogue data from the customer definitions into a temporary SQL file. Historical rollout tests use an explicit baseline of the original 12 products; the new catalogue suite tests the complete 25-product seed and all 13 additions.

Validation: full Node test suite and Vite production build; staging transaction tests for pricing, invalid dimensions, unpriced installation rejection, quote contracts, public supplier-data privacy and a service-request creation with no media date. Test orders are rolled back. Staging migration applied successfully; the committed catalogue, privacy checks and private delegate permissions were verified. Full suite: 766 passed, 8 skipped, no failures; production build passed. Existing security advisor findings were not expanded by this change. Production deployment is not part of the staging validation.

The follow-up migration `20261006200200_local_contravision_correx_rates.sql` updates only the two rate models, the Correx bespoke intake option and four media references. Browser/server size and quantity calculations agree; staff normalization keeps the zero-VAT cost basis. Transaction tests additionally exercise a print order and a signage request, inspect their saved records and roll back. Production remains unmodified.
