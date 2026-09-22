-- QS-17B: Product Hub content AND curated Quick Presets for flags and
-- gazebos.
--
-- ── STAGING ONLY ────────────────────────────────────────────────────
-- Do not apply this migration to production until someone has confirmed
-- the flags/gazebos base commerce.products/service_product_configs rows
-- actually exist there (per instruction: "QS-17B remains staging-only
-- until the underlying Flags/Gazebos base catalogue rows exist in
-- production. Do NOT create missing production base rows as part of
-- this task."). This migration does NOT create those base rows - it
-- only augments an EXISTING, already-published row's customer_definition,
-- exactly like QS-17A does for the other three products. The preflight
-- check below enforces this operationally: it raises and aborts
-- (transaction rolls back, nothing partially applied) rather than
-- silently doing nothing if the base row it expects is not there -
-- confirmed 20260921090500_qs14_catalog_data.sql DOES insert flags/
-- gazebos with status:'published', but which environment(s) that
-- migration has actually been run against was not independently
-- re-verified for this change (out of scope - this migration's own
-- preflight check is the actual production-safety gate, not an
-- assumption made here).
--
-- ── What this changes ──────────────────────────────────────────────
-- Purely additive JSONB merge onto the EXISTING customer_definition row
-- for each product - adds 'media' and 'productPage' (which now also
-- carries 'presets'). Every other existing key (id, name, pricing,
-- fields, channels, guidedJourneyId, ...) is left completely untouched
-- - same `||` merge safety reasoning as QS-16/QS-17A. Does not touch
-- pricing_definition and does not change any price.
--
-- ── Presets ─────────────────────────────────────────────────────────
-- Every preset.config.variant below is copied verbatim from the exact
-- variant keys already in THIS SAME migration file's own predecessor
-- (20260921090500_qs14_catalog_data.sql) - none invented. See that
-- file for the full variant/accessory/artwork catalogue each preset
-- resolves against.
--
-- No documented default/"most popular" style exists for either product
-- (checked: customer_definition.popular is false for both, no `default`
-- key on either's `variant` field) - so every preset name is fully
-- explicit about style/frame rather than implying a house default that
-- was never actually decided:
--   - Flags: every preset names "Telescopic" explicitly. Telescopic was
--     chosen as the illustrative/reference style (listed first among
--     the three styles, the most generic/common flag type) - a QS-17
--     judgment call, not a recovered business rule; CONFIRMED by the
--     business - keep Telescopic, every preset name says so explicitly,
--     never implied as a hidden default for generic "Flag" wording.
--   - Gazebos: frame is explicit in every preset name already (Steel/
--     Aluminium), matching the given example names directly - except
--     "3x3 Aluminium Deluxe Gazebo", where the brief's own example name
--     ("3x3 Deluxe Gazebo") did not specify a frame and both steel and
--     aluminium have a deluxe 3x3 variant. Chose aluminium (the frame
--     that also carries the larger deluxe sizes, i.e. the more
--     "premium" line in this catalogue's structure) - also a QS-17
--     judgment call; CONFIRMED by the business - keep the "3×3
--     Aluminium Deluxe Gazebo" as the deluxe preset (that confirmation
--     named which preset to keep, not a mandated casing; the
--     customer-facing name below uses the QS-17 review's exact copy
--     spec, "Complete kit").
--
-- ── artwork: null, not 'ready' ───────────────────────────────────────
-- A preset configures the PHYSICAL PRODUCT (variant/quantity), not
-- whether the customer's artwork happens to be ready - a preset named
-- "3m Telescopic Flag — Complete kit" must mean exactly that product
-- setup, not silently "...+ customer definitely has artwork ready."
-- Investigated before choosing null specifically: simply omitting the
-- `artwork` key does NOT achieve this - src/lib/pricing.js's
-- getDefaultConfig() merges {...fieldDefaults, ...preset}, and the
-- artwork field itself has default:'ready', so an absent key still
-- resolves to 'ready' via the field's own default (true for every
-- entry into the configurator, not preset-specific). An EXPLICIT
-- artwork: null DOES override that default (the key is present, so the
-- merge copies null over it) and is JSON-safe. Confirmed safe on BOTH
-- sides of the actual pricing authority, not just the client estimate:
--   - Client (src/lib/pricing.js priceSupplierMargin): `config.artwork
--     ? ... : null` - falsy/absent artwork contributes fee 0, never
--     forces quote-required.
--   - Server (commerce.qs_calculate_price, THIS repo,
--     20260921090000_qs14_catalog_margin_photography.sql lines 207-227):
--     `v_artwork_id := nullif(trim(coalesce(v_configuration->>'artwork','')), '')`
--     resolves JSON null (or an absent key) to SQL NULL identically,
--     then skips the whole artwork-pricing block - its own comment
--     states exactly this is intentional: "Optional; defaults to no fee
--     when omitted, so it never forces quote-required unless the
--     customer explicitly picks an artwork option that isn't priced
--     yet." Guided mode then genuinely asks the artwork question with
--     nothing pre-selected (verified against FieldControl.jsx's
--     ChoiceButtons, which shows no option "selected" when value is
--     null); Advanced mode's plain <select> has one disclosed, purely
--     cosmetic quirk (the browser visually highlights the first option
--     with nothing actually chosen yet) that resolves the moment the
--     customer touches the dropdown and does not affect price either way.
--
-- NOT APPLIED YET, STAGING ONLY WHEN IT IS - written for review only,
-- per instruction.

begin;

do $qs17b_preflight$
begin
  if not exists (
    select 1
    from public.tenants t
    join commerce.service_product_configs c on c.tenant_id = t.id
    where t.slug = 'quick-solution'
      and c.source_key = 'flags'
      and c.status = 'published'
  ) then
    raise exception 'QS17B prerequisite missing: quick-solution flags catalogue row (expected from QS-14, staging only until confirmed live in this environment)';
  end if;

  if not exists (
    select 1
    from public.tenants t
    join commerce.service_product_configs c on c.tenant_id = t.id
    where t.slug = 'quick-solution'
      and c.source_key = 'gazebos'
      and c.status = 'published'
  ) then
    raise exception 'QS17B prerequisite missing: quick-solution gazebos catalogue row (expected from QS-14, staging only until confirmed live in this environment)';
  end if;
end
$qs17b_preflight$;

update commerce.service_product_configs c
set customer_definition = c.customer_definition || jsonb_build_object(
  -- No dedicated flag photography exists yet (documented pre-QS-17
  -- decision - see LEGACY_IMAGE_FALLBACK's comment in
  -- src/lib/productContent.js). No hero here rather than reusing an
  -- unrelated photo - resolveProductMedia() falls through to
  -- ProductScene, exactly as it already does today.
  'media', jsonb_build_object('gallery', jsonb_build_array()),
  'productPage', jsonb_build_object(
    'headline', 'Telescopic, Shark Fin and Curved flags for shopfronts, stands and events',
    'intro', 'Choose the flag style, size, sides and whether you need the full kit or just a replacement print.',
    'useCases', jsonb_build_array(
      jsonb_build_object('label', 'Shopfronts'),
      jsonb_build_object('label', 'Stands'),
      jsonb_build_object('label', 'Events')
    ),
    'highlights', jsonb_build_array(
      jsonb_build_object('label', 'Telescopic, Shark Fin or Curved styles'),
      jsonb_build_object('label', '2m, 3m or 4m sizes'),
      jsonb_build_object('label', 'Single or double-sided printing'),
      jsonb_build_object('label', 'Full kit or replacement print only')
    ),
    'configPreview', jsonb_build_array('artwork'),
    'showStartingPrice', false,
    'presets', jsonb_build_array(
      jsonb_build_object(
        'id', 'flag-2m-telescopic-full',
        'name', '2m Telescopic Flag — Complete kit',
        'description', 'A ready-to-use 2m telescopic flag with stand, spike and single-sided print. Single-sided flags are supplied in pairs of 2.',
        'config', jsonb_build_object('variant', 'telescopic-2m-ss-full', 'quantity', 2, 'artwork', null)
      ),
      jsonb_build_object(
        'id', 'flag-3m-telescopic-full',
        'name', '3m Telescopic Flag — Complete kit',
        'description', 'A ready-to-use 3m telescopic flag with stand, spike and single-sided print. Single-sided flags are supplied in pairs of 2.',
        'config', jsonb_build_object('variant', 'telescopic-3m-ss-full', 'quantity', 2, 'artwork', null)
      ),
      jsonb_build_object(
        'id', 'flag-3m-telescopic-double-full',
        'name', '3m Double-Sided Telescopic Flag — Complete kit',
        'description', 'A ready-to-use 3m telescopic flag, printed on both sides, with stand and spike.',
        'config', jsonb_build_object('variant', 'telescopic-3m-ds-full', 'quantity', 1, 'artwork', null)
      ),
      jsonb_build_object(
        'id', 'flag-4m-telescopic-full',
        'name', '4m Telescopic Flag — Complete kit',
        'description', 'A ready-to-use 4m telescopic flag with stand, spike and single-sided print. Single-sided flags are supplied in pairs of 2.',
        'config', jsonb_build_object('variant', 'telescopic-4m-ss-full', 'quantity', 2, 'artwork', null)
      ),
      jsonb_build_object(
        'id', 'flag-3m-telescopic-reprint',
        'name', 'Replacement print — 3m Telescopic Flag',
        'description', 'A replacement single-sided print only, for an existing 3m telescopic flag stand. Supplied in pairs of 2.',
        'config', jsonb_build_object('variant', 'telescopic-3m-ss-reprint', 'quantity', 2, 'artwork', null)
      )
    )
  )
),
updated_at = now()
from public.tenants t
where c.tenant_id = t.id
  and t.slug = 'quick-solution'
  and c.source_key = 'flags';

update commerce.service_product_configs c
set customer_definition = c.customer_definition || jsonb_build_object(
  'media', jsonb_build_object(
    'hero', '/qs11/event-gazebo.webp',
    'gallery', jsonb_build_array()
  ),
  'productPage', jsonb_build_object(
    'headline', 'Branded steel and aluminium gazebos for markets, activations and events',
    'intro', 'Choose the frame, size and whether you need the full kit or just a replacement canopy print.',
    'useCases', jsonb_build_array(
      jsonb_build_object('label', 'Markets'),
      jsonb_build_object('label', 'Activations'),
      jsonb_build_object('label', 'Events')
    ),
    'highlights', jsonb_build_array(
      jsonb_build_object('label', 'Steel or aluminium frames'),
      jsonb_build_object('label', '2×2m up to 3×6m sizes'),
      jsonb_build_object('label', 'Full kit or replacement canopy print only'),
      jsonb_build_object('label', 'Optional walls and weights')
    ),
    'configPreview', jsonb_build_array('artwork'),
    'showStartingPrice', false,
    'presets', jsonb_build_array(
      jsonb_build_object(
        'id', 'gazebo-2x2-steel-full',
        'name', '2×2 Steel Gazebo — Complete kit',
        'description', 'A ready-to-use 2m × 2m steel-frame gazebo with printed canopy, frame and carry bag.',
        'config', jsonb_build_object('variant', 'steel-2x2-full', 'quantity', 1, 'artwork', null)
      ),
      jsonb_build_object(
        'id', 'gazebo-3x3-steel-standard-full',
        'name', '3×3 Steel Gazebo — Complete kit',
        'description', 'A ready-to-use 3m × 3m standard steel-frame gazebo with printed canopy, frame and carry bag.',
        'config', jsonb_build_object('variant', 'steel-3x3-standard-full', 'quantity', 1, 'artwork', null)
      ),
      jsonb_build_object(
        'id', 'gazebo-3x3-aluminium-standard-full',
        'name', '3×3 Aluminium Gazebo — Complete kit',
        'description', 'A ready-to-use 3m × 3m standard aluminium-frame gazebo with printed canopy, frame and carry bag.',
        'config', jsonb_build_object('variant', 'aluminium-3x3-standard-full', 'quantity', 1, 'artwork', null)
      ),
      jsonb_build_object(
        'id', 'gazebo-3x3-aluminium-deluxe-full',
        'name', '3×3 Aluminium Deluxe Gazebo — Complete kit',
        'description', 'A ready-to-use 3m × 3m deluxe aluminium-frame gazebo with printed canopy, frame and carry bag.',
        'config', jsonb_build_object('variant', 'aluminium-3x3-deluxe-full', 'quantity', 1, 'artwork', null)
      ),
      jsonb_build_object(
        'id', 'gazebo-3x3-steel-standard-reprint',
        'name', 'Replacement canopy print — 3×3 Steel Standard Gazebo',
        'description', 'A replacement canopy print only, for an existing 3m × 3m standard steel-frame gazebo.',
        'config', jsonb_build_object('variant', 'steel-3x3-standard-reprint', 'quantity', 1, 'artwork', null)
      )
    )
  )
),
updated_at = now()
from public.tenants t
where c.tenant_id = t.id
  and t.slug = 'quick-solution'
  and c.source_key = 'gazebos';

commit;

-- Manual verification (run in Studio, STAGING ONLY, after applying):
--
--   select c.source_key, c.customer_definition->'media', c.customer_definition->'productPage'
--   from commerce.service_product_configs c
--   join public.tenants t on t.id = c.tenant_id
--   where t.slug = 'quick-solution' and c.source_key in ('flags', 'gazebos');
--
-- Then spot-check at least one preset end-to-end against the real
-- server-side pricing function (read-only, does not place an order) -
-- artwork:null matches what the presets actually store (see the
-- "artwork: null, not 'ready'" note above):
--
--   select commerce.qs_calculate_price(
--     (select id from commerce.service_product_configs c join public.tenants t on t.id = c.tenant_id where t.slug = 'quick-solution' and c.source_key = 'flags'),
--     '{"variant":"telescopic-2m-ss-full","quantity":2,"artwork":null}'::jsonb
--   );
--
-- Expect a real, non-quote-required price (R1,980 for that specific
-- call) - if this raises or returns quote-required, do not consider the
-- flags presets ready even if the client-side estimate above looked
-- fine, since commerce.qs_calculate_price is the actual checkout
-- authority.
