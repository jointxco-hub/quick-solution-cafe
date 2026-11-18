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

## QS integration progress — 18 Nov 2026 (STAGING ONLY)

- Staging project `tijiamrfnxrbitafiflj`: `public.xlab_our_work` has opt-in QS fields, admin-only write RLS and a selective public read policy requiring `is_active` and publication to at least one site.
- New `public.qs_published_work` view uses `WITH (security_invoker = true)` and returns only `id,title,client,category,summary,cover_image,video_url,video_thumbnail,qs_featured,qs_sort_order`, filtering `is_active AND show_on_qs`. Anon/public SELECT only; no user writes to the view.
- Rollback-only staging tests passed: opted-in active QS record visible, inactive record hidden, non-QS record hidden, no anon update grant.
- Four real client video project metadata records created in staging **as unpublished drafts**: Afro Nubian, Cronynizer, Dr Kokakora hoodie and QS Events JAI. All `is_active=false`, `show_on_qs=false`, video URLs empty. Nothing public yet.
- QS homepage branch uses `src/lib/qsPublishedWork.js` + `FeaturedWork.jsx` to fetch the shared view rather than the temporary static seed. It does not send any user/session or admin key, uses HTTPS media sources and hides the showcase when no published records exist.
- Existing QS app backend URL/key are used by default, with optional `VITE_QS_WORK_SUPABASE_URL` and `VITE_QS_WORK_SUPABASE_PUBLISHABLE_KEY` if separately configured. Preview environment must point to the **same staging project containing the view**, else no published content will load. Only publishable/anon client key; no secret role keys.
- GitHub Actions on the integration branch: production build and shared-work focused tests passed after correcting a transient adapter syntax issue. Legacy checkout/delivery-info failures still make the broad suite fail; treat independently. Browser QA and live preview acceptance remain.
- Vercel preview creation currently blocked by Hobby daily 100 deployment limit (API 402). **No preview deployed, no production release.**
- Full uploaded videos remain in original conversation assets; generated posters and short previews remain in local media package. They have **not** been hosted in a public CDN or placed into Supabase Storage.

### Production readiness gates
1. Review and apply equivalent RLS hardening and QS additions to the production Supabase project using the project's approved migration workflow; do not merge frontend first.
2. Confirm X LAB admin and X1 regressions with real staging accounts. Verify full public read and read-only view behavior; inspect any X LAB client-side queries using `show_on_xlab` for backwards compatibility.
3. Test QS preview with staging `VITE_SUPABASE_URL` + publishable key and a temporary approved test record; unpublish it again.
4. Upload approved posters/videos using existing X LAB media uploader or vetted video host. Verify CDN playback and source rights, portrait/landscape layouts, mobile data performance.
5. Run QS browser QA, review existing five legacy test failures, then deploy after release approval.

### Staging public feed SQL (reference, do not blindly rerun in production)
```sql
drop policy if exists "Published portfolio read" on public.xlab_our_work;
create policy "Published portfolio read" on public.xlab_our_work for select to anon, authenticated
using (is_active = true and (show_on_xlab = true or show_on_x1 = true or show_on_qs = true));

create or replace view public.qs_published_work with (security_invoker = true) as
select id, title, client, category,
       coalesce(nullif(qs_summary, ''), description, '') as summary,
       cover_image, video_url, video_thumbnail, qs_featured, qs_sort_order
from public.xlab_our_work
where is_active = true and show_on_qs = true;
revoke all on public.qs_published_work from public, anon, authenticated;
grant select on public.qs_published_work to anon, authenticated;
```
