# Café Counter — iMin D4 acceptance (OPPS-106)

## Scope
**Staging only.** No new checkout, QR, settlement or order mutation required. Reuse paid sandbox Café order `QS-261118-98C6`.

## Verified in repository
- `src/counter/CounterPage.jsx` calls `window.print()` for the paid receipt. The app currently has **no native iMin printing bridge**.
- `src/counter/CounterView.jsx` only renders a receipt when the canonical server detail is fully paid, and provides **View / Print receipt** and **Next sale**.
- `reset()` clears the selected product, draft, customer and payment route, starts a fresh sale, and navigates to `sale` without marking any order paid or starting a payment.
- `src/styles/qs-counter.css` has `@media print` rules hiding the Counter shell and formatting the paper receipt. Browser/thermal size still needs inspection on the actual iMin.

## Device acceptance sequence
1. On the **iMin D4**, launch the installed Café Counter PWA (staging). Sign in as authorized Café Counter operator.
2. Open **Today's orders** → existing **PAID** `QS-261118-98C6` (R60; 2 × A3 lamination). Confirm it says **Payment confirmed**, outstanding R0, and hides payment actions.
3. Tap **View / Print receipt**, then **Print receipt** once. Record exactly what happens:
   - A: thermal paper prints readable reference, 2 × A3 lamination, R60, PayFast, and receipt date.
   - B: Android/browser print dialog appears but no printer is listed.
   - C: save-to-PDF or A4 layout only.
   - D: blank/cut-off/multiple paper pages.
   - E: button appears inert/error.
4. If A, check if using 58mm or 80mm paper and whether the columns fit without clipping. If B–E, **do not** enable QR or install unreviewed printer apps; choose supported iMin Web Print/Printer Plugin based on firmware/browser and retest.
5. Close receipt. Tap **Next sale**. Confirm blank product/customer fields and fresh order creation screen; original PAID order remains in Today's orders. **Do not submit a new order.**
6. Capture model/build, paper width, browser/PWA mode and outcome screenshots. Do not include auth tokens/credentials.

## Vendor reference
iMin official printer documentation: https://oss-sg.imin.sg/docs/en/Printer.html
- Android 11 / D4 is under the legacy V1.0/USB family in the docs.
- iMin's printer plugin is documented for printing web content from a browser; newer V2.0 firmware can also support web print without plugin.
- iMin Web Print desktop demo: https://mp.imin.sg/WebPrint/D.html
- No assertion that Android `window.print()` automatically prints to the D4 thermal hardware.

## Release
PASS requires physical receipt output plus fresh-sale reset. Do not treat desktop print preview as hardware acceptance. Existing payment remains untouched. QR issuance OFF; production unchanged.
