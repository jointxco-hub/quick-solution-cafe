# Café order workspace — staging review

Implemented in PR 21, on top of the unified staff app. Backend deployed only to XOS staging (`tijiamrfnxrbitafiflj`). Production rollout requires the migration and `quick-solution-order-file` Edge Function before merging the UI.

- Order rows show product imagery, including configured flag style, service name, quantity and sales channel. Multiple items show a count; detail shows all items.
- Opening an order explicitly records the authenticated operator's first view. Automatic handoff previews do not. History begins at rollout; “No recorded views” makes no claim about older activity.
- “I’ll handle this” records one shared acknowledgement with authenticated operator and server time. A second operator cannot replace the original acknowledgement. Closed orders cannot be acknowledged. This does not change production or payment status.
- Documents are available before expanding technical details. PDF/raster image files have Open / print and Download; office documents download for opening in a suitable app. Print uses the browser/viewer or the device Share → Print menu; this is not silent printer integration.
- File lookup uses the caller's existing Café operations capability and exact order/file relationship. Private files receive 120-second signed URLs only after authorization. Deleted files and unrelated order/file pairs are denied. The Edge Function uses `verify_jwt=false` because it validates the bearer token with Auth explicitly before any lookup. Service/anon tokens are rejected. Storage is not made public.
- Menus dismiss on outside pointer/focus and Escape. Counter secondary selection uses the same muted green as its main selection. Corrected a pre-existing undefined section reference on Admin sign-in.

Validation: 778 automated tests passed, 8 skipped, 0 failed; production build passed. Rolled-back staging SQL verifies workspace loading, idempotent views, first-operator acknowledgement, matching private-file access, deleted-file denial, non-admin/non-member/anonymous denial, and restricted grants. Edge handler tests verify authorization before signing, expiry, server-resolved paths, forced office-document download and failure handling. Security advisor flags the private no-policy activity table and authenticated security-definer RPCs by design; direct table grants are revoked, RPCs explicitly enforce tenant capability, and search paths are fixed.

Device review:
1. Open the preview Orders page and check service thumbnails, including a configured flag order.
2. Open a test order. Team activity should show your name/time. On another signed-in device, refresh Orders and confirm shared history.
3. Tap “I’ll handle this”; another operator should see the original acknowledgement after refresh.
4. Open an attached PDF/image and print from its viewer; download an office document. Confirm normal return to the same order in the installed app.
5. Open each menu, then tap outside; verify Escape on desktop and unchanged Counter sale/payment navigation.

Still planned: local quick-job completion/collection workflow, operator greeting/counts, expenses, PVC/vinyl/DTF catalogue/pricing work and analytics. Existing OPPS handoff remains available. No production finance changes are included here.
