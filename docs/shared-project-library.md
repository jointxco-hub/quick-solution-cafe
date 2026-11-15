# Shared Joint X project library — publishing contract

This release seeds a frontend-only project catalogue and a QS featured-work gallery. It does **not** create a new Supabase table, public API, or shared live CMS.

## Ownership and reuse

A Joint X project is created **once**, then selectively published to the consumer sites.

- **Joint X / X LAB**: deeper production case studies, business branding, capabilities, bulk/custom work
- **X1**: examples that demonstrate samples, merch, garment decoration and the X1 purchase journey
- **Quick Solution**: friendly, locally relevant proof of printing, merchandise, branding and events, with fast shop/upload CTAs

Each site should have its own heading, short description, CTA and display order, while media, job facts and project ID are shared. This avoids duplicate edits and conflicting dates or claims.

## Planned backend

When ready, create a shared, staff-managed public portfolio in Supabase with appropriate tenant/brand ownership, not tables in each website:

- `projects`: id, slug, title, client_name, production_credit, job_scope, year, project_type, verification_status, publication_status
- `project_media`: id, project_id, storage_path, mime_type, width, height, focal_point, poster_path, alt, sort_order, usage_rights
- `project_channels`: project_id, channel (qs/xlab/x1), featured, sort_order, localized_headline, localized_summary, CTA/linked product
- `project_appearances`: project_id, event_name, date, link/evidence, relationship_label
- `project_permissions`: clearance to publish media, mention brand/client names, use logos, include testimonial

Expose only publication-approved fields and public media via a narrow public read endpoint/RLS policy. Keep internal notes, costs, clients' contact details and unreleased content private. Media upload and approvals belong to authenticated staff admin. Add a reusable cache layer per site.

## Media guidance

Keep original files and derive responsive thumbnails: portrait 9:16 or 3:4, square 1:1, landscape 16:9, plus miscellaneous sizes. Use `object-fit: cover` on curated card previews with focal point metadata; use `object-fit: contain` in the future full-media viewer to avoid cutting off artwork. Video: poster, `preload=none`, user-initiated playback in initial implementation; add intersection-based muted preview only after performance tests. Avoid third-party video auto-load on mobile.

## Publication checklist

1. Confirm exact scope, source, date and who commissioned/paid for the project.
2. Confirm permission to use logos, original videos, event footage and the client's name.
3. Distinguish `work commissioned by X` from `work for a client which appeared at event Y`.
4. Add accessibility alt text/captions and aspect ratio metadata.
5. Approve per-site placement and link to the relevant service/product.
6. Preview staging mobile/desktop; publish only after review.

## QS current implementation

`src/data/workProjects.js` is temporary shared-data *shape*, **not** a shared deployed source. It deliberately exposes only three named featured projects with generic placeholder graphics, and stages two other project references without publishing them. Replace the seed with the shared API when developed, keeping IDs stable.

Check the staged claims and media permissions before production deployment.
