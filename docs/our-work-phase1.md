# Our Work — Phase 1 implementation contract

Status: development only. No production migration or deployment.

## Existing integration points
- `src/App.jsx`: lightweight route/view state; no React Router.
- `src/lib/navigation.js`: explicit pathname resolution for /shop and /products/:id.
- `src/components/ProductHub.jsx`: product detail page with an existing product media gallery.
- `src/components/ProofGallery.jsx`: static promotional proof content, **not** an authenticated customer-work portfolio.
- `src/admin/AdminProductManager.jsx`: existing staff authentication and admin shell.
- `src/lib/supabaseApi.js`: raw Supabase REST/RPC requests, with staff access tokens.

## Data model
- `cafe_portfolio_projects`: id UUID, tenant_id, slug (tenant-unique), title, summary, description, status (draft/published), cover_media_id nullable, featured boolean, published_at, created_at, updated_at.
- `cafe_portfolio_categories`: id UUID, tenant_id, slug, name, sort_order, enabled.
- `cafe_portfolio_project_categories`: project_id, category_id.
- `cafe_portfolio_project_products`: project_id, product_key (match existing catalogue keys).
- `cafe_portfolio_media`: id UUID, project_id, storage_path, alt_text, sort_order, mime_type, created_at.

## Security and media
- All tables tenant-scoped, with RLS enabled and policies reviewed against the existing Café staff capability model.
- Anonymous readers can access only published projects and their approved media through a server-enforced public read interface.
- Draft project media must never become public merely because the object path is known. Use private storage with short-lived signed URLs or a verified publication gate.
- Staff write/upload/delete authorization must be server-enforced, not inferred from a visible admin screen.
- Validate MIME type, image size, file size, and ownership; randomize object keys; do not expose service-role keys to the browser.
- Do not expose client identity or order details by default; only publish expressly approved content.
- Draft/unpublish must revoke public visibility; plan for cached/signed media URL expiry.

## Customer experience
- `/our-work`: public portfolio listing with offering filters and project cards.
- `/our-work/:slug`: individual project with gallery, optional case study, and links to relevant products.
- `/products/:id`: show a compact Our Work section only when published projects are linked to the current product.
- A product may link to many projects; a project may link to many products and categories.
- Gallery and full project page should share one canonical project URL; browser history and deep-link reload must work.
- Add navigation entry; preserve /shop, /configure, /admin, /counter, and /track precedence.
- Do not conflate product mockup images with evidence of completed customer jobs.

## Admin workflow
1. Open Our Work from existing staff navigation.
2. Create draft; set title, slug, category/categories, linked product(s), summary.
3. Upload multiple photos, choose cover, reorder, edit alt text.
4. Preview as customer, publish/unpublish, optionally feature.
5. Edit without changing canonical URL unless an explicit redirect is created.

## Acceptance tests
- Unlinked products and products with only draft work show no Our Work block.
- One published project linked to multiple products appears on each and in filtered listing.
- Public endpoints reject drafts, including media access.
- Unauthorized staff cannot create, edit, upload or publish.
- Admin upload failures and partial saves are recoverable.
- Deep links /our-work/:slug load directly and survive refresh; back/forward works.
- Mobile images do not stretch; thumbnails are responsive and accessible.
- Existing navigation, checkout, configurator, counter, and admin tests still pass.

## Release gate
Implement on `feature/our-work-portfolio`; review SQL/RLS and storage separately before applying any migration; run tests and preview QA before production merge.
