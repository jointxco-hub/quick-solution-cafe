# Cross-site Our Work integration — existing infrastructure first

## Audit conclusion (15 November 2026)

X LAB already has an **Admin > Our Work** editor in `jointxco-hub/x-lab/src/pages/admin/AdminOurWork.jsx`. The canonical project data used by the X1 admin is `xlab_our_work` (see `src/pages/admin/AdminX1Site.jsx`), which selects active records where `show_on_x1 = true`. X LAB already exposes `show_on_xlab` and `show_on_x1`, `x1_featured`, `x1_sort_order`, `x1_summary`, `x1_process`, `x1_results`, and `x1_addons`. It has cover image upload/compression, image galleries, video upload or URLs, video thumbnails, and project publishing controls. Its Lookbook and page-template sections already render case studies.

**Do not implement the previously proposed separate projects, project_media, project_channels, or project_appearances CMS tables unless a concrete gap cannot be addressed safely by extending the existing schema.** Avoid duplicate admin interfaces or migrating/re-uploading existing project media.

## Recommended minimal change

1. Confirm the deployed `xlab_our_work` schema and RLS/public read policies in staging. The GitHub code establishes intended usage, not confirmed production database contents.
2. Extend the existing `xlab_our_work` row with opt-in Quick Solution visibility (`show_on_qs`, default false) and only genuinely needed QS overrides (`qs_featured`, `qs_sort_order`, `qs_summary`, and optionally `qs_cta_target`). Prefer an existing flexible JSON field if that is already the supported pattern, rather than proliferating columns.
3. Add a small **Quick Solution** publishing subsection to X LAB Admin > Our Work alongside X LAB and X1. Do not create a second project editor.
4. QS consumes a **public, published-only** read interface returning approved projects/media. It must never use credentials with write privileges. Respect the existing tenant/brand authorization model; do not relax RLS to make the integration work.
5. Preserve original media dimensions and allow per-site thumbnail/focal-point overrides. Existing gallery arrays and video thumbnail paths may suffice; verify before changing storage.
6. Maintain truthful credits/relationships and publication permissions for Uber Eats, Netflix, Cue Corner/Miss SA, Brandon Dhludhlu and Leta Mbulu.

## QS draft status

This PR contains a **temporary static seed** in `src/data/workProjects.js` and a responsive QS display component. It does not persist projects or upload media and **must not become another source of truth**. During integration, replace it with an adapter for approved `xlab_our_work` public records, with safe placeholders only when records/media have not been approved. Remove the static duplicate records once the shared feed is verified.

## Validation before merge

- Confirm X LAB admin still edits one canonical record for X LAB/X1/QS.
- Verify X1 case-study filters and fallback remain unchanged.
- Check QS only shows `show_on_qs` and active/approved projects.
- Test RLS as anon, authenticated customer and staff.
- Confirm portrait/square/landscape video/image behavior and mobile performance.
- Run QS tests/build; X LAB regression tests for Our Work, page templates and X1.
- Do not alter production until staging passes.
