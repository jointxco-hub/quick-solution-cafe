-- PRODUCTION QUICK SOLUTION RECONCILIATION.
--
-- Brings production (slhcvyeuqsduaglddqdb) up to the same current-main object shape that
-- staging (tijiamrfnxrbitafiflj) already has, closing the gap documented in the read-only
-- production lineage audit: production's commerce.* tables/RPC layer diverged from an
-- undocumented, live-only "Layer A" foundation (qs10_opps_production_*, no git provenance
-- anywhere) plus a later partial graft of qs11/14/16/17's catalog content ("Layer B"). It never
-- received qs_03 through qs_09, qs12, qs13, or any CAFE-GUEST-01*/CAFE-ACCESS work.
--
-- This migration is NOT a replay of that history (several of those files, notably
-- qs_03_quick_solution_foundation.sql, would silently overwrite production's live, currently
-- called create_quick_solution_order/cart_order/service_request with a stale pre-current body -
-- a real behavior regression hiding inside what looks like a schema catch-up). Instead every
-- object below is the CURRENT, final body/shape, extracted directly from a live instance of this
-- repo's own migration history (a disposable local cluster built by the existing
-- supabase/tests/harness/run-local-sql-tests.ps1, which replays every migration through
-- 20260927120000 and passes 24/24 tests) via pg_get_functiondef()/information_schema, not
-- retyped by hand.
--
-- Must run BEFORE 20260927150000_qs_canonical_tracking_subsystem_restoration.sql: that
-- migration's get_quick_solution_tracking declares a variable of type
-- commerce.service_order_handoffs (created below), which PL/pgSQL must resolve at CREATE
-- FUNCTION time, not merely at call time - so this table has to exist first. The three
-- create_quick_solution_* RPCs below call commerce.qs_issue_tracking_token/
-- qs_generate_order_number only as plain function calls (not composite-type declarations), so
-- they compile here even though those don't exist yet; they will not successfully return an
-- order until the tracking migration has also run. Also run BEFORE CAFE-ACCESS-01..04 / the
-- security patch (neither depends on anything here, but the documented production rollout
-- order puts this reconciliation first).
--
-- Explicitly, deliberately NOT touched by this migration - preserved exactly as they are live on
-- production today: quote_quick_solution_staff_item, get_quick_solution_opps_items,
-- get_quick_solution_operations_profile, is_opps_staff(), is_opps_workspace_tenant(),
-- has_tenant_permission(). Also explicitly not touched: mirror_opps_order_to_xlab_orders() /
-- _mirror_opps_order_row() - Café repo's own qs_04a defines a DIFFERENT body for the trigger
-- function (one that skips mirroring source='quick_solution' orders); production's live version
-- has no such exemption and mirrors them today (proven: the two historical quick_solution
-- orders both have a linked xlab_orders row). Taking qs_04a's version here would be a real,
-- unwanted behavior change to a live, general-purpose (not Quick-Solution-specific) OPPS/X LAB
-- integration point. It is left exactly as-is.

do $preflight$
begin
  if to_regclass('commerce.service_orders') is null then
    raise exception 'QS_RECONCILIATION_PRECONDITION: commerce.service_orders must exist';
  end if;
  if to_regclass('commerce.service_order_handoffs') is not null then
    raise exception 'QS_RECONCILIATION_PRECONDITION: commerce.service_order_handoffs already exists - this migration must not run twice';
  end if;
end
$preflight$;

-- ── commerce.service_orders: the two columns CAFE-GUEST-01A added ───────────────────────────
alter table commerce.service_orders
  add column channel text not null default 'storefront',
  add column created_by uuid;
alter table commerce.service_orders
  add constraint service_orders_channel_check check (channel = any (array['storefront'::text,'counter'::text]));

-- ── commerce.service_order_items: the one column qs_13_3 (multi-item cart order) added -
--    discovered during the rehearsal (create_quick_solution_cart_order writes it), reported
--    rather than silently absorbed, same as qs_calculate_price and qs_count_page_spec above ──
alter table commerce.service_order_items add column client_item_key text;

-- ── commerce.service_order_files (qs_03_1) - discovered during the rehearsal
--    (commerce.qs_build_opps_handoff_preview checks it before allowing a handoff), reported
--    rather than silently absorbed, unchanged since qs_03_1 (confirmed against current main) ──
create table commerce.service_order_files (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  order_id uuid not null references commerce.service_orders(id) on delete cascade,
  order_item_id uuid not null references commerce.service_order_items(id) on delete cascade,
  storage_bucket text not null default 'uploads' check (storage_bucket = 'uploads'),
  storage_path text not null,
  original_filename text not null,
  mime_type text,
  byte_size bigint not null check (byte_size > 0 and byte_size <= 20971520),
  status text not null default 'uploaded' check (status in ('uploaded','deleted')),
  uploaded_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (storage_bucket, storage_path)
);

-- ── commerce.service_order_handoffs (qs_04a..qs_04c_1, cafe_guest_01x/01y, security patch) ──
create table commerce.service_order_handoffs (
  id uuid primary key default gen_random_uuid(),
  service_order_id uuid not null unique references commerce.service_orders(id) on delete cascade,
  source_tenant_id uuid not null references public.tenants(id) on delete restrict,
  target_tenant_id uuid not null references public.tenants(id) on delete restrict,
  mapping_version text not null default 'qs-opps-v1',
  status text not null default 'previewed' check (status = any (array['previewed','blocked','ready','sending','sent','failed'])),
  preview_payload jsonb not null default '{}'::jsonb,
  blockers jsonb not null default '[]'::jsonb,
  warnings jsonb not null default '[]'::jsonb,
  opps_order_id uuid references public.orders(id) on delete set null,
  idempotency_key text not null unique,
  last_previewed_at timestamptz,
  last_previewed_by uuid,
  sent_at timestamptz,
  failure_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index idx_qs_handoffs_status on commerce.service_order_handoffs (status, updated_at desc);
create index idx_qs_handoffs_target_tenant on commerce.service_order_handoffs (target_tenant_id, status, updated_at desc);
create trigger trg_qs_service_order_handoffs_updated_at before update on commerce.service_order_handoffs for each row execute function handle_updated_at();

-- ── commerce.service_order_cancellations (cafe_guest_01v) ───────────────────────────────────
create table commerce.service_order_cancellations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  service_order_id uuid not null unique references commerce.service_orders(id) on delete restrict,
  cancelled_by uuid not null,
  cancelled_at timestamptz not null default now(),
  reason text not null check (reason = btrim(reason) and char_length(reason) between 3 and 300 and reason !~ '[[:cntrl:]]'),
  prior_status text not null,
  prior_payment_status text not null,
  order_total numeric not null,
  outstanding_at_cancel numeric not null
);
create index idx_qs_cancellations_tenant_time on commerce.service_order_cancellations (tenant_id, cancelled_at desc);
-- trg_qs_cancellation_no_truncate / trg_qs_cancellation_no_update_delete are created further
-- below, after commerce.qs_guard_service_order_cancellation_append_only() exists (it is defined
-- in the FUNCTIONS section of this same file, not yet at this point).

-- ── commerce.service_order_payments (cafe_guest_01q) ────────────────────────────────────────
create table commerce.service_order_payments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  service_order_id uuid not null references commerce.service_orders(id) on delete cascade,
  provider text not null default 'payfast' check (provider = any (array['payfast','cash','card'])),
  status text not null default 'pending' check (status = any (array['pending','completed','failed','cancelled'])),
  amount numeric not null check (amount > 0),
  pf_payment_id text,
  raw_itn jsonb,
  initiated_at timestamptz not null default now(),
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  recorded_by uuid,
  idempotency_key text,
  constraint service_order_payments_counter_recorded_check check (
    provider not in ('cash','card') or (status = 'completed' and recorded_by is not null and idempotency_key is not null and completed_at is not null)
  )
);
create index idx_qs_service_order_payments_order on commerce.service_order_payments (service_order_id, created_at desc);
create unique index uq_qs_service_order_payments_pf on commerce.service_order_payments (provider, pf_payment_id) where (pf_payment_id is not null);
create unique index uq_qs_service_order_payments_idempotency on commerce.service_order_payments (tenant_id, idempotency_key) where (idempotency_key is not null);
create unique index uq_qs_service_order_payments_one_counter_payment on commerce.service_order_payments (service_order_id) where (provider in ('cash','card') and status='completed');
create trigger trg_qs_service_order_payments_updated_at before update on commerce.service_order_payments for each row execute function handle_updated_at();

-- ── commerce.fulfilment_point_external_links (qs_06) ────────────────────────────────────────
create table commerce.fulfilment_point_external_links (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  fulfilment_point_id uuid not null references commerce.fulfilment_points(id) on delete cascade,
  provider text not null check (provider = 'easy_locate'),
  external_id text not null,
  external_slug text not null,
  canonical_url text not null,
  status text not null default 'verified' check (status = any (array['verified','stale'])),
  public_snapshot jsonb not null default '{}'::jsonb,
  source_updated_at timestamptz,
  verified_at timestamptz not null default now(),
  verified_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (fulfilment_point_id, provider),
  unique (provider, external_id)
);
create index idx_fulfilment_external_links_tenant on commerce.fulfilment_point_external_links (tenant_id, provider, status);
create trigger trg_fulfilment_point_external_links_updated_at before update on commerce.fulfilment_point_external_links for each row execute function handle_updated_at();

-- ══════════ FUNCTIONS (current, final bodies - verbatim from the proven-passing local cluster) ══════════
-- ── commerce.qs_calculate_price: REPLACE, not merely add. Production's live copy
--    (Layer B) predates PER_UNIT support; current main's dispatcher has an inline PER_UNIT
--    branch production never received. Needed to satisfy the rehearsal proof that
--    create_quick_solution_order succeeds for PER_UNIT (and every other current strategy),
--    not just the two helpers originally scoped. Discovered during the rehearsal itself,
--    reported rather than silently absorbed: this is the ONLY additional replace beyond
--    the previously approved list.
CREATE OR REPLACE FUNCTION commerce.qs_calculate_price(p_tenant_id uuid, p_product_key text, p_configuration jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_product_id uuid;
  v_product_name text;
  v_pricing_version text;
  v_pricing jsonb;
  v_strategy text;
  v_configuration jsonb := p_configuration;
begin
  if p_configuration is null or jsonb_typeof(p_configuration) is distinct from 'object' then
    raise exception using errcode = '22023', message = 'Configuration must be a JSON object.';
  end if;

  select p.id, p.name, c.pricing_version, c.pricing_definition
    into v_product_id, v_product_name, v_pricing_version, v_pricing
  from commerce.service_product_configs c
  join commerce.products p
    on p.id = c.product_id
   and p.tenant_id = c.tenant_id
  where c.tenant_id = p_tenant_id
    and c.source_key = trim(p_product_key)
    and c.status = 'published'
    and p.status = 'published'
    and p.availability = 'available'
  limit 1;

  if v_product_id is null then
    raise exception using errcode = '22023', message = 'Product is not available.';
  end if;

  v_strategy := upper(coalesce(v_pricing->>'strategy', ''));

  if trim(p_product_key) = 'a4-print' and v_strategy = 'PER_PAGE' then
    v_configuration := commerce.qs_normalize_document_configuration(p_configuration);
  end if;

  if v_strategy = 'ENQUIRY' then
    return jsonb_build_object(
      'productId', v_product_id,
      'productKey', trim(p_product_key),
      'productName', v_product_name,
      'total', 0,
      'summary', 'Quote after review',
      'lines', jsonb_build_array(
        jsonb_build_object('label','Service request','text','Photo / video brief captured'),
        jsonb_build_object('label','Pricing','text','Confirmed after crew, location and scope review')
      ),
      'metrics', jsonb_build_object(
        'quoteRequired', true,
        'serviceType', coalesce(v_pricing->>'serviceType','service')
      ),
      'snapshot', jsonb_build_object(
        'pricingVersion', v_pricing_version,
        'productKey', trim(p_product_key),
        'productName', v_product_name,
        'pricingStrategy', v_strategy,
        'configuration', v_configuration,
        'pricingDefinition', v_pricing,
        'calculation', jsonb_build_object(
          'lines', jsonb_build_array(
            jsonb_build_object('label','Service request','text','Photo / video brief captured'),
            jsonb_build_object('label','Pricing','text','Confirmed after crew, location and scope review')
          ),
          'metrics', jsonb_build_object('quoteRequired',true),
          'total', 0
        ),
        'capturedAt', now()
      )
    );
  end if;

  if v_strategy = 'SUPPLIER_MARGIN' then
    declare
      v_variant_id text;
      v_variant jsonb;
      v_quantity integer;
      v_min_quantity integer;
      v_quantity_step integer;
      v_margin numeric;
      v_reference numeric;
      v_unit_selling numeric := 0;
      v_variant_total numeric;
      v_accessories_total numeric := 0;
      v_accessory_ids jsonb;
      v_accessory_id text;
      v_accessory jsonb;
      v_acc_reference numeric;
      v_acc_selling numeric;
      v_acc_compatible jsonb;
      v_artwork_id text;
      v_artwork jsonb;
      v_artwork_fee numeric := 0;
      v_quote_required boolean := false;
      v_lines jsonb := '[]'::jsonb;
    begin
      v_variant_id := nullif(trim(coalesce(v_configuration->>'variant','')), '');
      if v_variant_id is null or not coalesce((v_pricing->'variants') ? v_variant_id, false) then
        raise exception using errcode = '22023', message = 'Choose a valid option.';
      end if;
      v_variant := v_pricing->'variants'->v_variant_id;

      -- Per-variant minQuantity/quantityStep override the product-level
      -- default (e.g. single-sided flags: minQuantity 2, step 2 - "must
      -- be bought in pairs of 2"). A variant with no override falls back
      -- to the product default (minQuantity 1, step 1 unless set).
      v_min_quantity := greatest(coalesce(
        (v_variant->>'minQuantity')::integer,
        (v_pricing->>'minQuantity')::integer,
        1
      ), 1);
      v_quantity_step := greatest(coalesce((v_variant->>'quantityStep')::integer, 1), 1);

      begin
        v_quantity := coalesce((v_configuration->>'quantity')::integer, v_min_quantity);
      exception when others then
        raise exception using errcode = '22023', message = 'Quantity must be a whole number.';
      end;
      if v_quantity < v_min_quantity then
        raise exception using errcode = '22023', message = format('Minimum quantity for this option is %s.', v_min_quantity);
      end if;
      if v_quantity > 500 then
        raise exception using errcode = '22023', message = 'Quantity is outside the supported range.';
      end if;
      if v_quantity_step > 1 and mod(v_quantity - v_min_quantity, v_quantity_step) <> 0 then
        raise exception using errcode = '22023',
          message = format('This option must be ordered in multiples of %s (minimum %s).', v_quantity_step, v_min_quantity);
      end if;

      v_margin := coalesce((v_pricing->>'marginRate')::numeric, 0.5);
      if v_margin < 0 or v_margin >= 1 then
        raise exception using errcode = '22023', message = 'Pricing configuration is invalid.';
      end if;

      v_reference := nullif(v_variant->>'referencePrice','')::numeric;
      if v_reference is null then
        v_quote_required := true;
      else
        v_unit_selling := round(v_reference / (1 - v_margin), 2);
      end if;
      v_variant_total := v_unit_selling * v_quantity;

      v_accessory_ids := coalesce(v_configuration->'accessories', '[]'::jsonb);
      if jsonb_typeof(v_accessory_ids) is distinct from 'array' then
        raise exception using errcode = '22023', message = 'Accessory selection is invalid.';
      end if;

      for v_accessory_id in select jsonb_array_elements_text(v_accessory_ids) loop
        if not coalesce((v_pricing->'accessories') ? v_accessory_id, false) then
          raise exception using errcode = '22023', message = 'One or more accessories are invalid.';
        end if;
        v_accessory := v_pricing->'accessories'->v_accessory_id;

        -- compatibleVariants: an explicit allow-list of variant ids this
        -- accessory may be paired with (e.g. a wall/wheely-bag sized for
        -- one gazebo frame size only). Omitted or empty means universal
        -- - matches the Flags accessories, which the source document
        -- shows shared across every flag design/size/kit combination.
        v_acc_compatible := v_accessory->'compatibleVariants';
        if v_acc_compatible is not null
           and jsonb_typeof(v_acc_compatible) = 'array'
           and jsonb_array_length(v_acc_compatible) > 0
           and not (v_acc_compatible ? v_variant_id)
        then
          raise exception using errcode = '22023',
            message = format('%s is not available for the selected option.', coalesce(v_accessory->>'label', v_accessory_id));
        end if;

        v_acc_reference := nullif(v_accessory->>'referencePrice','')::numeric;
        if v_acc_reference is null then
          v_quote_required := true;
        else
          v_acc_selling := round(v_acc_reference / (1 - v_margin), 2);
          v_accessories_total := v_accessories_total + v_acc_selling;
          v_lines := v_lines || jsonb_build_array(
            jsonb_build_object('label', coalesce(v_accessory->>'label', v_accessory_id), 'value', v_acc_selling)
          );
        end if;
      end loop;

      v_artwork_id := nullif(trim(coalesce(v_configuration->>'artwork','')), '');
      if v_artwork_id is not null then
        if not coalesce((v_pricing->'artwork') ? v_artwork_id, false) then
          raise exception using errcode = '22023', message = 'Artwork option is invalid.';
        end if;
        v_artwork := v_pricing->'artwork'->v_artwork_id;
        v_artwork_fee := nullif(v_artwork->>'fee','')::numeric;
        if v_artwork_fee is null then
          v_quote_required := true;
          v_artwork_fee := 0;
        elsif v_artwork_fee > 0 then
          v_lines := v_lines || jsonb_build_array(
            jsonb_build_object('label', coalesce(v_artwork->>'label', v_artwork_id), 'value', v_artwork_fee)
          );
        end if;
      end if;

      if v_quote_required then
        return jsonb_build_object(
          'productId', v_product_id,
          'productKey', trim(p_product_key),
          'productName', v_product_name,
          'total', 0,
          'summary', 'Quote required',
          'lines', jsonb_build_array(jsonb_build_object('label','Pricing','text','One or more selected options need a quote')),
          'metrics', jsonb_build_object('quoteRequired', true, 'quantity', v_quantity),
          'snapshot', jsonb_build_object(
            'pricingVersion', v_pricing_version,
            'productKey', trim(p_product_key),
            'productName', v_product_name,
            'pricingStrategy', v_strategy,
            'configuration', v_configuration,
            'pricingDefinition', v_pricing,
            'calculation', jsonb_build_object('lines', '[]'::jsonb, 'metrics', jsonb_build_object('quoteRequired',true), 'total', 0),
            'capturedAt', now()
          )
        );
      end if;

      v_lines := jsonb_build_array(
        jsonb_build_object('label', coalesce(v_variant->>'label', v_variant_id), 'value', round(v_variant_total,2))
      ) || v_lines;

      return jsonb_build_object(
        'productId', v_product_id,
        'productKey', trim(p_product_key),
        'productName', v_product_name,
        'total', round(v_variant_total + v_accessories_total + v_artwork_fee, 2),
        'summary', coalesce(v_variant->>'label', v_variant_id) || ' × ' || v_quantity::text,
        'lines', v_lines,
        'metrics', jsonb_build_object('quantity', v_quantity, 'unitPrice', v_unit_selling, 'quoteRequired', false),
        'snapshot', jsonb_build_object(
          'pricingVersion', v_pricing_version,
          'productKey', trim(p_product_key),
          'productName', v_product_name,
          'pricingStrategy', v_strategy,
          'configuration', v_configuration,
          'pricingDefinition', v_pricing,
          'calculation', jsonb_build_object(
            'lines', v_lines,
            'metrics', jsonb_build_object('quantity',v_quantity,'quoteRequired',false),
            'total', round(v_variant_total + v_accessories_total + v_artwork_fee, 2)
          ),
          'capturedAt', now()
        )
      );
    end;
  end if;

  if v_strategy = 'PHOTOGRAPHY_SESSION' then
    declare
      v_session_id text;
      v_session jsonb;
      v_extra_edits integer;
      v_extra_edit_rate numeric;
      v_deliverable_ids jsonb;
      v_deliverable_id text;
      v_deliverable jsonb;
      v_deliverable_price numeric;
      v_quote_required boolean := false;
      v_total numeric := 0;
      v_lines jsonb := '[]'::jsonb;
      v_session_price numeric;
    begin
      v_session_id := coalesce(nullif(trim(coalesce(v_configuration->>'session','')), ''), '30min-7edits');
      if not coalesce((v_pricing->'sessions') ? v_session_id, false) then
        raise exception using errcode = '22023', message = 'Choose a valid session option.';
      end if;
      v_session := v_pricing->'sessions'->v_session_id;

      begin
        v_extra_edits := greatest(coalesce((v_configuration->>'extraEdits')::integer, 0), 0);
      exception when others then
        raise exception using errcode = '22023', message = 'Extra edited photos must be a whole number.';
      end;
      if v_extra_edits > 500 then
        raise exception using errcode = '22023', message = 'Extra edited photos is outside the supported range.';
      end if;

      v_session_price := nullif(v_session->>'price','')::numeric;
      if v_session_price is null then
        v_quote_required := true;
      else
        v_total := v_total + v_session_price;
        v_lines := v_lines || jsonb_build_array(jsonb_build_object('label', coalesce(v_session->>'label', v_session_id), 'value', v_session_price));
      end if;

      if v_extra_edits > 0 then
        v_extra_edit_rate := nullif(v_pricing->>'extraEditRate','')::numeric;
        if v_extra_edit_rate is null then
          v_quote_required := true;
        else
          v_total := v_total + (v_extra_edits * v_extra_edit_rate);
          v_lines := v_lines || jsonb_build_array(jsonb_build_object(
            'label', v_extra_edits::text || ' extra edited photo' || case when v_extra_edits = 1 then '' else 's' end,
            'value', round(v_extra_edits * v_extra_edit_rate, 2)
          ));
        end if;
      end if;

      v_deliverable_ids := coalesce(v_configuration->'deliverables', '[]'::jsonb);
      if jsonb_typeof(v_deliverable_ids) is distinct from 'array' then
        raise exception using errcode = '22023', message = 'Deliverable selection is invalid.';
      end if;

      for v_deliverable_id in select jsonb_array_elements_text(v_deliverable_ids) loop
        if not coalesce((v_pricing->'deliverables') ? v_deliverable_id, false) then
          raise exception using errcode = '22023', message = 'One or more deliverables are invalid.';
        end if;
        v_deliverable := v_pricing->'deliverables'->v_deliverable_id;
        v_deliverable_price := nullif(v_deliverable->>'price','')::numeric;
        if v_deliverable_price is null then
          v_quote_required := true;
        else
          v_total := v_total + v_deliverable_price;
          v_lines := v_lines || jsonb_build_array(jsonb_build_object('label', coalesce(v_deliverable->>'label', v_deliverable_id), 'value', v_deliverable_price));
        end if;
      end loop;

      if v_quote_required then
        return jsonb_build_object(
          'productId', v_product_id,
          'productKey', trim(p_product_key),
          'productName', v_product_name,
          'total', 0,
          'summary', 'Quote required',
          'lines', jsonb_build_array(jsonb_build_object('label','Pricing','text','One or more selected options need a quote')),
          'metrics', jsonb_build_object('quoteRequired', true, 'sessionId', v_session_id, 'extraEdits', v_extra_edits),
          'snapshot', jsonb_build_object(
            'pricingVersion', v_pricing_version,
            'productKey', trim(p_product_key),
            'productName', v_product_name,
            'pricingStrategy', v_strategy,
            'configuration', v_configuration,
            'pricingDefinition', v_pricing,
            'calculation', jsonb_build_object('lines', '[]'::jsonb, 'metrics', jsonb_build_object('quoteRequired',true), 'total', 0),
            'capturedAt', now()
          )
        );
      end if;

      return jsonb_build_object(
        'productId', v_product_id,
        'productKey', trim(p_product_key),
        'productName', v_product_name,
        'total', round(v_total, 2),
        'summary', coalesce(v_session->>'label', v_session_id),
        'lines', v_lines,
        'metrics', jsonb_build_object(
          'quoteRequired', false, 'sessionId', v_session_id,
          'durationMinutes', v_session->>'durationMinutes', 'includedEdits', v_session->>'includedEdits',
          'extraEdits', v_extra_edits
        ),
        'snapshot', jsonb_build_object(
          'pricingVersion', v_pricing_version,
          'productKey', trim(p_product_key),
          'productName', v_product_name,
          'pricingStrategy', v_strategy,
          'configuration', v_configuration,
          'pricingDefinition', v_pricing,
          'calculation', jsonb_build_object('lines', v_lines, 'metrics', jsonb_build_object('quoteRequired',false), 'total', round(v_total,2)),
          'capturedAt', now()
        )
      );
    end;
  end if;

  -- CAFE-GUEST-01F: neutral PER_UNIT strategy. The arithmetic and every
  -- validation live in commerce._qs_price_per_unit; this only wraps its result
  -- in the same envelope every other strategy returns.
  if v_strategy = 'PER_UNIT' then
    declare
      v_per_unit jsonb;
    begin
      v_per_unit := commerce._qs_price_per_unit(v_pricing, v_configuration);

      return jsonb_build_object(
        'productId', v_product_id,
        'productKey', trim(p_product_key),
        'productName', v_product_name,
        'total', v_per_unit -> 'total',
        'summary', v_per_unit ->> 'summary',
        'lines', v_per_unit -> 'lines',
        'metrics', v_per_unit -> 'metrics',
        'snapshot', jsonb_build_object(
          'pricingVersion', v_pricing_version,
          'productKey', trim(p_product_key),
          'productName', v_product_name,
          'pricingStrategy', v_strategy,
          'configuration', v_configuration,
          'pricingDefinition', v_pricing,
          'calculation', jsonb_build_object(
            'lines', v_per_unit -> 'lines',
            'metrics', v_per_unit -> 'metrics',
            'total', v_per_unit -> 'total'
          ),
          'capturedAt', now()
        )
      );
    end;
  end if;

  return commerce.qs_calculate_price_legacy(
    p_tenant_id,
    p_product_key,
    v_configuration
  );
end
$function$;

revoke all on function commerce.qs_calculate_price(uuid,text,jsonb) from public, anon, authenticated, service_role;
grant execute on function commerce.qs_calculate_price(uuid,text,jsonb) to authenticated, service_role;

CREATE OR REPLACE FUNCTION commerce._qs_counter_business_day(p_at timestamp with time zone)
 RETURNS TABLE(business_date date, day_start timestamp with time zone, day_end timestamp with time zone)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select d.business_date,
         d.business_date::timestamp at time zone 'Africa/Johannesburg',
         (d.business_date + 1)::timestamp at time zone 'Africa/Johannesburg'
  from (select (p_at at time zone 'Africa/Johannesburg')::date as business_date) d
$function$

;

CREATE OR REPLACE FUNCTION commerce._qs_counter_business_day_of(p_date date)
 RETURNS TABLE(business_date date, day_start timestamp with time zone, day_end timestamp with time zone)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select d.business_date, d.day_start, d.day_end
  from commerce._qs_counter_business_day((p_date::timestamp at time zone 'Africa/Johannesburg')) d
$function$

;

CREATE OR REPLACE FUNCTION commerce._qs_counter_cancel_block(p_order commerce.service_orders)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_handoff text;
begin
  if p_order.status = 'cancelled' then return 'already_cancelled'; end if;

  if p_order.payment_status in ('paid', 'refunded')
     or exists (
       select 1 from commerce.service_order_payments p
       where p.service_order_id = p_order.id and p.tenant_id = p_order.tenant_id and p.status = 'completed'
     ) then
    return 'has_payment';
  end if;

  if p_order.payment_status = 'pending'
     or exists (
       select 1 from commerce.service_order_payments p
       where p.service_order_id = p_order.id and p.tenant_id = p_order.tenant_id and p.status = 'pending'
     ) then
    return 'payment_in_progress';
  end if;

  select h.status into v_handoff from commerce.service_order_handoffs h where h.service_order_id = p_order.id limit 1;
  if p_order.opps_order_id is not null or v_handoff in ('sending', 'sent') then return 'sent_to_production'; end if;

  if p_order.status = 'draft' then return 'not_cancellable'; end if;
  if p_order.status <> 'submitted' then return 'in_progress'; end if;

  if p_order.payment_status not in ('unpaid', 'failed') then return 'not_payable_state'; end if;

  if p_order.total_amount <= 0
     or round(p_order.total_amount - commerce._qs_order_amount_paid(p_order.id), 2) <= 0 then
    return 'nothing_outstanding';
  end if;
  return null;
end
$function$

;

CREATE OR REPLACE FUNCTION commerce._qs_counter_cashup(p_tenant_id uuid, p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_day record;
  v_pay record;
  v_orders record;
  v_unpaid record;
begin
  select * into v_day from commerce._qs_counter_business_day_of(p_date);

  -- money received on the day: one query yields the rows AND every figure made from them
  with pay as (
    select
      p.id,
      p.service_order_id,
      p.provider,
      p.amount,
      p.completed_at,
      so.order_number,
      so.customer_name,
      so.total_amount,
      so.created_at as order_created_at
    from commerce.service_order_payments p
    join commerce.service_orders so
      on so.id = p.service_order_id
     and so.tenant_id = p.tenant_id
    where p.tenant_id = p_tenant_id
      and so.channel = 'counter'
      and p.status = 'completed'
      and p.completed_at >= v_day.day_start
      and p.completed_at < v_day.day_end
  )
  select
    coalesce(jsonb_agg(
      jsonb_build_object(
        'paymentId', pay.id,
        'orderId', pay.service_order_id,
        'orderNumber', pay.order_number,
        'customerName', pay.customer_name,
        'method', pay.provider,
        'amount', pay.amount,
        'paidAt', pay.completed_at,
        'orderTotal', pay.total_amount,
        'orderCreatedAt', pay.order_created_at
      )
      order by pay.completed_at desc, pay.id desc
    ) filter (where pay.provider in ('cash', 'card')), '[]'::jsonb) as rows,
    count(*) filter (where pay.provider = 'cash') as cash_count,
    coalesce(sum(pay.amount) filter (where pay.provider = 'cash'), 0) as cash_amount,
    count(*) filter (where pay.provider = 'card') as card_count,
    coalesce(sum(pay.amount) filter (where pay.provider = 'card'), 0) as card_amount,
    count(*) filter (where pay.provider not in ('cash', 'card')) as other_count,
    coalesce(sum(pay.amount) filter (where pay.provider not in ('cash', 'card')), 0) as other_amount,
    count(distinct pay.service_order_id) filter (where pay.provider in ('cash', 'card')) as paid_orders
  into v_pay
  from pay;

  -- orders that ORIGINATED on the day
  select count(*) as created_today
  into v_orders
  from commerce.service_orders so
  where so.tenant_id = p_tenant_id
    and so.channel = 'counter'
    and so.created_at >= v_day.day_start
    and so.created_at < v_day.day_end;

  -- ... of those, the ones still unpaid NOW: what is outstanding, never counted as received
  select
    count(*) as n,
    coalesce(sum(u.outstanding), 0) as amount,
    coalesce(jsonb_agg(u.summary order by u.created_at desc, u.id desc), '[]'::jsonb) as orders
  into v_unpaid
  from (
    select
      so.id,
      so.created_at,
      greatest(round(so.total_amount - commerce._qs_order_amount_paid(so.id), 2), 0) as outstanding,
      jsonb_build_object(
        'orderId', so.id,
        'orderNumber', so.order_number,
        'createdAt', so.created_at,
        'status', so.status,
        'paymentStatus', so.payment_status,
        'customerName', so.customer_name,
        'customerEmail', so.customer_email,
        'customerPhone', so.customer_phone,
        'totalAmount', so.total_amount,
        'outstanding', greatest(round(so.total_amount - commerce._qs_order_amount_paid(so.id), 2), 0),
        'items', coalesce((
          select jsonb_agg(
                   jsonb_build_object(
                     'productKey', i.product_key,
                     'productName', i.product_name,
                     'quantity', i.quantity,
                     'configuration', i.configuration,
                     'lineTotal', i.line_total
                   )
                   order by i.created_at, i.id
                 )
          from commerce.service_order_items i
          where i.order_id = so.id
            and i.tenant_id = so.tenant_id
        ), '[]'::jsonb)
      ) as summary
    from commerce.service_orders so
    where so.tenant_id = p_tenant_id
      and so.channel = 'counter'
      and so.created_at >= v_day.day_start
      and so.created_at < v_day.day_end
      and so.payment_status = 'unpaid'
      and so.status <> 'cancelled'
  ) u;

  return jsonb_build_object(
    'businessDate', v_day.business_date,
    'timezone', 'Africa/Johannesburg',
    'orders', jsonb_build_object(
      'createdToday', v_orders.created_today,
      'paidToday', v_pay.paid_orders,
      'unpaidToday', v_unpaid.n
    ),
    'takings', jsonb_build_object(
      'cash', jsonb_build_object('count', v_pay.cash_count, 'amount', v_pay.cash_amount),
      'card', jsonb_build_object('count', v_pay.card_count, 'amount', v_pay.card_amount),
      'total', jsonb_build_object('count', v_pay.cash_count + v_pay.card_count, 'amount', v_pay.cash_amount + v_pay.card_amount)
    ),
    'otherMethods', jsonb_build_object('count', v_pay.other_count, 'amount', v_pay.other_amount),
    'unpaid', jsonb_build_object('count', v_unpaid.n, 'amount', v_unpaid.amount, 'orders', v_unpaid.orders),
    'payments', v_pay.rows
  );
end
$function$

;

CREATE OR REPLACE FUNCTION commerce._qs_counter_payment_block(p_order commerce.service_orders)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_handoff text;
begin
  if p_order.payment_status = 'paid' then return 'already_paid'; end if;
  if p_order.payment_status <> 'unpaid' or p_order.status in ('draft', 'cancelled', 'completed') then return 'not_payable'; end if;

  select h.status into v_handoff from commerce.service_order_handoffs h where h.service_order_id = p_order.id limit 1;
  if p_order.opps_order_id is not null or v_handoff in ('sending', 'sent') then return 'sent_to_production'; end if;

  if p_order.total_amount <= 0
     or round(p_order.total_amount - commerce._qs_order_amount_paid(p_order.id), 2) <= 0 then
    return 'nothing_outstanding';
  end if;
  return null;
end
$function$

;

CREATE OR REPLACE FUNCTION commerce._qs_order_amount_paid(p_order_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(sum(p.amount), 0)
  from commerce.service_order_payments p
  where p.service_order_id = p_order_id
    and p.status = 'completed'
$function$

;

CREATE OR REPLACE FUNCTION commerce._qs_price_per_unit(p_pricing jsonb, p_configuration jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare
  v_unit_price numeric;
  v_min_units numeric;
  v_max_units numeric;
  v_type text;
  v_text text;
  v_units numeric;
  v_total numeric;
begin
  -- The definition is always validated before the unit count.
  perform commerce._qs_validate_per_unit_definition(p_pricing);

  v_unit_price := (p_pricing ->> 'unitPrice')::numeric;
  v_min_units := (p_pricing ->> 'minUnits')::numeric;
  v_max_units := (p_pricing ->> 'maxUnits')::numeric;

  v_type := coalesce(jsonb_typeof(p_configuration -> 'units'), 'null');

  if v_type = 'null' then
    raise exception using errcode = '22023', message = 'Units are required.';
  elsif v_type = 'number' then
    v_units := (p_configuration ->> 'units')::numeric;
    if v_units <> trunc(v_units) then
      raise exception using errcode = '22023', message = 'Units must be a whole number.';
    end if;
  elsif v_type = 'string' then
    v_text := p_configuration ->> 'units';
    if v_text !~ '^(0|[1-9][0-9]*)$' then
      raise exception using errcode = '22023', message = 'Units must be a whole number.';
    end if;
    if length(v_text) > 9 then
      raise exception using errcode = '22023', message = 'Units are outside the supported range.';
    end if;
    v_units := v_text::numeric;
  else
    raise exception using errcode = '22023', message = 'Units must be a whole number.';
  end if;

  if v_units < v_min_units or v_units > v_max_units then
    raise exception using errcode = '22023', message = 'Units are outside the supported range.';
  end if;

  v_total := round(v_units * v_unit_price, 2);

  return jsonb_build_object(
    'total', v_total,
    'summary', v_units::bigint::text || ' × ' || to_char(v_unit_price, 'FM9999999990.00'),
    'lines', jsonb_build_array(jsonb_build_object('label', 'Units', 'value', v_total)),
    'metrics', jsonb_build_object('units', v_units::bigint, 'unitPrice', v_unit_price)
  );
end
$function$

;

CREATE OR REPLACE FUNCTION commerce._qs_product_channel_enabled(p_tenant_id uuid, p_product_key text, p_channel text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce((
    select
      case p_channel
        when 'storefront' then
          case coalesce(jsonb_typeof(c.customer_definition -> 'channels' -> 'storefront'), 'null')
            when 'null' then true
            when 'boolean' then (c.customer_definition -> 'channels' ->> 'storefront')::boolean
            else false
          end
        when 'counter' then
          case coalesce(jsonb_typeof(c.customer_definition -> 'channels' -> 'pos'), 'null')
            when 'boolean' then (c.customer_definition -> 'channels' ->> 'pos')::boolean
            else false
          end
        else false
      end
    from commerce.service_product_configs c
    where c.tenant_id = p_tenant_id
      and c.source_key = trim(p_product_key)
    limit 1
  ), false)
$function$

;

CREATE OR REPLACE FUNCTION commerce._qs_product_counter_sellable(p_tenant_id uuid, p_product_key text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce((
    select true
    from commerce.service_product_configs c
    join commerce.products p
      on p.id = c.product_id
     and p.tenant_id = c.tenant_id
    where c.tenant_id = p_tenant_id
      and c.source_key = trim(p_product_key)
      and c.status = 'published'
      and p.status = 'published'
      and p.availability = 'available'
      and commerce._qs_product_channel_enabled(c.tenant_id, c.source_key, 'counter')
      and case coalesce(jsonb_typeof(c.customer_definition -> 'active'), 'null')
            when 'null' then true
            when 'boolean' then (c.customer_definition ->> 'active')::boolean
            else false
          end
    limit 1
  ), false)
$function$

;

CREATE OR REPLACE FUNCTION commerce._qs_sync_opps_payment_ledger(p_service_order_id uuid, p_opps_order_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_order commerce.service_orders;
  v_opps_order public.orders;
  v_count integer;
  v_amount numeric;
  v_completed_at timestamptz;
  v_single_provider text;
  v_method text;
  v_note text;
  v_total_paid numeric;
begin
  if p_service_order_id is null or p_opps_order_id is null then
    return;
  end if;

  select * into v_order from commerce.service_orders where id = p_service_order_id;
  select * into v_opps_order from public.orders where id = p_opps_order_id;
  if v_order.id is null or v_opps_order.id is null then
    return;
  end if;

  select count(*), sum(amount), max(completed_at)
  into v_count, v_amount, v_completed_at
  from commerce.service_order_payments
  where service_order_id = p_service_order_id and status = 'completed';

  if coalesce(v_count, 0) > 0 then
    if v_count = 1 then
      select provider into v_single_provider
      from commerce.service_order_payments
      where service_order_id = p_service_order_id and status = 'completed'
      limit 1;
    else
      v_single_provider := null;
    end if;

    v_method := case v_single_provider when 'cash' then 'cash' when 'card' then 'card' else 'other' end;
    v_note := case
      when v_count = 1 then format('Quick Solution Café %s payment for order %s.', v_single_provider, v_order.order_number)
      else format('Quick Solution Café payments for order %s: %s completed payments totalling %s.', v_order.order_number, v_count, v_amount)
    end;

    insert into public.transactions (
      type, order_id, order_number, client_name, amount, payment_method, payment_status,
      payment_date, notes, source
    ) values (
      'income', p_opps_order_id, v_order.order_number, v_order.customer_name, v_amount, v_method, 'completed',
      coalesce(v_completed_at, now())::date, v_note, 'quick_solution'
    )
    on conflict (order_id) do nothing;
  end if;

  select coalesce(sum(t.amount), 0)
  into v_total_paid
  from public.transactions t
  where t.order_id = p_opps_order_id and t.type = 'income' and t.payment_status = 'completed';

  update public.orders
  set deposit_paid = v_total_paid,
      payment_status = case when v_total_paid > 0 and v_total_paid + 0.005 >= v_opps_order.total_amount then 'paid' else 'pending' end,
      updated_at = now()
  where id = p_opps_order_id;
end
$function$

;

CREATE OR REPLACE FUNCTION commerce._qs_validate_per_unit_definition(p_pricing jsonb)
 RETURNS void
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare
  v_unit_price numeric;
  v_min_units numeric;
  v_max_units numeric;
begin
  if jsonb_typeof(p_pricing) is distinct from 'object'
     or jsonb_typeof(p_pricing -> 'unitPrice') is distinct from 'number'
     or jsonb_typeof(p_pricing -> 'minUnits') is distinct from 'number'
     or jsonb_typeof(p_pricing -> 'maxUnits') is distinct from 'number' then
    raise exception using errcode = '22023', message = 'Pricing configuration is invalid.';
  end if;

  v_unit_price := (p_pricing ->> 'unitPrice')::numeric;
  v_min_units := (p_pricing ->> 'minUnits')::numeric;
  v_max_units := (p_pricing ->> 'maxUnits')::numeric;

  if v_unit_price <= 0
     or v_unit_price > 100000
     or v_unit_price <> round(v_unit_price, 2)
     or v_min_units <> trunc(v_min_units)
     or v_max_units <> trunc(v_max_units)
     or v_min_units < 1
     or v_max_units < v_min_units
     or v_max_units > 10000 then
    raise exception using errcode = '22023', message = 'Pricing configuration is invalid.';
  end if;
end
$function$

;

CREATE OR REPLACE FUNCTION commerce.qs_build_opps_handoff_preview(p_service_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_order commerce.service_orders;
  v_source_tenant public.tenants;
  v_target_tenant public.tenants;
  v_point commerce.fulfilment_points;
  v_items jsonb := '[]'::jsonb;
  v_file_urls jsonb := '[]'::jsonb;
  v_files jsonb := '[]'::jsonb;
  v_blockers jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_ready boolean := false;
  v_fulfillment_type text;
  v_payment_status text;
  v_apply_shipping boolean := false;
  v_is_counter boolean;
  v_has_contact boolean;
begin
  select * into v_order from commerce.service_orders so where so.id=p_service_order_id limit 1;
  if v_order.id is null then
    raise exception using errcode='22023', message='Quick Solution order was not found.';
  end if;

  select * into v_source_tenant from public.tenants t where t.id=v_order.tenant_id limit 1;
  if v_source_tenant.slug <> 'quick-solution' then
    raise exception using errcode='22023', message='Order is not a Quick Solution order.';
  end if;

  select * into v_target_tenant from public.tenants t where t.slug='quick-solution' and t.status='active' limit 1;
  if v_target_tenant.id is null then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('code','TARGET_TENANT_MISSING','message','Quick Solution OPPS tenant is not active.'));
  end if;
  if v_order.status in ('cancelled','completed') then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('code','ORDER_CLOSED','message','Closed Quick Solution orders cannot be handed to OPPS.'));
  end if;
  if v_order.opps_order_id is not null then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('code','ALREADY_HANDED_OFF','message','This Quick Solution order is already linked to an OPPS order.','oppsOrderId',v_order.opps_order_id));
  end if;
  if not exists (select 1 from commerce.service_order_items soi where soi.order_id=v_order.id) then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('code','NO_ORDER_ITEMS','message','The order has no order items.'));
  end if;

  -- CAFE-GUEST-01X: a genuine staff-created counter/walk-in order (channel = 'counter', the trusted,
  -- server-set marker from CAFE-GUEST-01A/01M) may have no contact details; a storefront customer order
  -- still must. This is decided by the channel alone, never inferred from contact data being absent.
  v_is_counter := v_order.channel = 'counter';
  v_has_contact := nullif(trim(coalesce(v_order.customer_email,'')),'') is not null
                 or nullif(trim(coalesce(v_order.customer_phone,'')),'') is not null;
  if not v_has_contact then
    if v_is_counter then
      v_warnings := v_warnings || jsonb_build_array(jsonb_build_object('code','COUNTER_GUEST_NO_CONTACT','message','No phone or email was given; this is a Café counter walk-in and OPPS will receive it as a guest order with no contact details.'));
    else
      v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('code','NO_CUSTOMER_CONTACT','message','A phone number or email address is required.'));
    end if;
  end if;

  if exists (
    select 1 from commerce.service_order_items soi
    where soi.order_id=v_order.id
      and nullif(trim(coalesce(soi.configuration->>'fileName','')),'') is not null
      and not exists (
        select 1 from commerce.service_order_files sof
        where sof.order_item_id=soi.id and sof.status='uploaded'
      )
  ) then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('code','EXPECTED_FILE_MISSING','message','At least one order item names a customer file but no private upload is linked.'));
  end if;
  if v_order.payment_status <> 'paid' then
    v_warnings := v_warnings || jsonb_build_array(jsonb_build_object('code','PAYMENT_NOT_PAID','message','The Quick Solution order is not marked paid. OPPS may receive it for review, but staff should control production release.'));
  end if;

  if v_order.fulfilment_type in ('cafe','quick_point') then
    v_fulfillment_type := 'collection'; v_apply_shipping := false;
  elsif v_order.fulfilment_type='delivery' then
    v_fulfillment_type := 'courier'; v_apply_shipping := true;
    if v_order.delivery_address is null then
      v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('code','DELIVERY_ADDRESS_MISSING','message','Delivery orders require a delivery address.'));
    end if;
  else
    v_fulfillment_type := 'service_only'; v_apply_shipping := false;
  end if;

  v_payment_status := case v_order.payment_status when 'paid' then 'paid' when 'failed' then 'failed' when 'cancelled' then 'cancelled' else 'pending' end;

  if v_order.fulfilment_point_id is not null then
    select * into v_point from commerce.fulfilment_points fp
    where fp.id=v_order.fulfilment_point_id and fp.tenant_id=v_order.tenant_id limit 1;
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'name', soi.product_name,
      'quantity', greatest(coalesce(public.safe_numeric(soi.configuration->>'quantity'), soi.quantity, 1), 1),
      'price', case when greatest(coalesce(public.safe_numeric(soi.configuration->>'quantity'), soi.quantity, 1),1) > 0
                    then round(soi.line_total / greatest(coalesce(public.safe_numeric(soi.configuration->>'quantity'), soi.quantity, 1),1), 2)
                    else soi.line_total end,
      'line_total', soi.line_total,
      'line_id', soi.id::text,
      'line_role', 'product',
      'source', 'quick_solution',
      'category', coalesce(c.customer_definition->>'category','Quick Solution'),
      'price_breakdown', jsonb_build_object('mode','quick_solution_snapshot','pricing_version',soi.pricing_snapshot->>'pricingVersion','calculation',coalesce(soi.pricing_snapshot->'calculation','{}'::jsonb)),
      'quick_solution', jsonb_build_object('service_order_item_id',soi.id,'product_key',soi.product_key,'configuration',soi.configuration,'pricing_version',soi.pricing_snapshot->>'pricingVersion','file_refs',coalesce(soi.file_refs,'[]'::jsonb))
    ) order by soi.created_at
  ), '[]'::jsonb)
  into v_items
  from commerce.service_order_items soi
  left join commerce.service_product_configs c on c.tenant_id=soi.tenant_id and c.source_key=soi.product_key
  where soi.order_id=v_order.id;

  select
    coalesce(jsonb_agg(jsonb_build_object('id', sof.id,'orderItemId', sof.order_item_id,'name', sof.original_filename,'mimeType', sof.mime_type,'byteSize', sof.byte_size,'bucket', sof.storage_bucket,'path', sof.storage_path,'privateUri', 'private-upload://' || sof.storage_bucket || '/' || sof.storage_path) order by sof.uploaded_at), '[]'::jsonb),
    coalesce(jsonb_agg(to_jsonb('private-upload://' || sof.storage_bucket || '/' || sof.storage_path) order by sof.uploaded_at), '[]'::jsonb)
  into v_files, v_file_urls
  from commerce.service_order_files sof
  where sof.order_id=v_order.id and sof.status='uploaded';

  v_ready := jsonb_array_length(v_blockers)=0;

  return jsonb_build_object(
    'mappingVersion','qs-opps-v1','ready',v_ready,'blockers',v_blockers,'warnings',v_warnings,
    'sourceOrder',jsonb_build_object('id',v_order.id,'orderNumber',v_order.order_number,'tenantId',v_order.tenant_id,'tenantSlug',v_source_tenant.slug,'status',v_order.status,'paymentStatus',v_order.payment_status,'submittedAt',v_order.submitted_at),
    'proposedOppsOrder',jsonb_build_object(
      'tenant_id',v_target_tenant.id,'order_number',v_order.order_number,'client_name',v_order.customer_name,'client_email',v_order.customer_email,'client_phone',v_order.customer_phone,
      'status','confirmed','pipeline_stage','received','priority','normal','source','quick_solution','products',v_items,'total_amount',v_order.total_amount,
      'deposit_paid',case when v_order.payment_status='paid' then v_order.total_amount else 0 end,'payment_status',v_payment_status,'fulfillment_type',v_fulfillment_type,
      'apply_shipping_fee',v_apply_shipping,'shipping_fee',v_order.fulfilment_fee,'shipping_address',case when v_order.fulfilment_type='delivery' then v_order.delivery_address else null end,
      'shipping_method',case when v_order.fulfilment_type='quick_point' then 'Quick Point collection' when v_order.fulfilment_type='cafe' then 'Quick Solution Café collection' when v_order.fulfilment_type='delivery' then 'Quick Solution delivery' else null end,
      'file_urls',v_file_urls,'special_instructions',v_order.customer_notes,'portal_show_files',false,'account_show_files',false,
      'source_metadata',jsonb_build_object('quick_solution',jsonb_build_object('service_order_id',v_order.id,'service_order_number',v_order.order_number,'mapping_version','qs-opps-v1','fulfilment_type',v_order.fulfilment_type,'fulfilment_point',case when v_point.id is null then null else jsonb_build_object('id',v_point.id,'slug',v_point.slug,'name',v_point.name,'kind',v_point.kind) end,'pricing_total',v_order.total_amount,'files',v_files,'channel',v_order.channel,'guestContact',(v_is_counter and not v_has_contact)))
    )
  );
end
$function$

;

CREATE OR REPLACE FUNCTION commerce.qs_calculate_price_legacy(p_tenant_id uuid, p_product_key text, p_configuration jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_product_id uuid;
  v_product_name text;
  v_pricing_version text;
  v_pricing jsonb;
  v_strategy text;
  v_total numeric := 0;
  v_summary text := '';
  v_lines jsonb := '[]'::jsonb;
  v_metrics jsonb := '{}'::jsonb;

  v_width numeric;
  v_height numeric;
  v_raw_area numeric;
  v_billable_area numeric;
  v_base numeric;
  v_service_fees numeric;
  v_turn_mult numeric;

  v_pages integer;
  v_copies integer;
  v_rate numeric;
  v_side_mult numeric;
  v_finish_fee numeric;
  v_printed_pages numeric;

  v_quantity integer;
  v_unit numeric;
  v_discount numeric;

  v_material text;
  v_finishing text;
  v_artwork text;
  v_turnaround text;
  v_print_mode text;
  v_sides text;
  v_finish text;
  v_stock text;
  v_garment text;
  v_front text;
  v_back text;
begin
  if p_configuration is null or jsonb_typeof(p_configuration) is distinct from 'object' then
    raise exception using errcode = '22023', message = 'Configuration must be a JSON object.';
  end if;

  select p.id, p.name, c.pricing_version, c.pricing_definition
  into v_product_id, v_product_name, v_pricing_version, v_pricing
  from commerce.service_product_configs c
  join commerce.products p
    on p.id = c.product_id
   and p.tenant_id = c.tenant_id
  where c.tenant_id = p_tenant_id
    and c.source_key = trim(p_product_key)
    and c.status = 'published'
    and p.status = 'published'
    and p.availability = 'available'
  limit 1;

  if v_product_id is null then
    raise exception using errcode = '22023', message = 'Product is not available.';
  end if;

  v_strategy := upper(coalesce(v_pricing->>'strategy', ''));

  if v_strategy = 'PER_AREA' then
    begin
      v_width := (p_configuration->>'width')::numeric;
      v_height := (p_configuration->>'height')::numeric;
    exception when others then
      raise exception using errcode = '22023', message = 'Width and height must be valid numbers.';
    end;

    if v_width <= 0 or v_height <= 0 or v_width > 20 or v_height > 20 then
      raise exception using errcode = '22023', message = 'Banner dimensions are outside the supported range.';
    end if;

    v_material := coalesce(nullif(p_configuration->>'material',''), 'standard');
    v_finishing := coalesce(nullif(p_configuration->>'finishing',''), 'hem-eyelets');
    v_artwork := coalesce(nullif(p_configuration->>'artwork',''), 'ready');
    v_turnaround := coalesce(nullif(p_configuration->>'turnaround',''), 'standard');

    if not coalesce((v_pricing->'materials') ? v_material, false)
       or not coalesce((v_pricing->'finishing') ? v_finishing, false)
       or not coalesce((v_pricing->'artwork') ? v_artwork, false)
       or not coalesce((v_pricing->'turnaround') ? v_turnaround, false) then
      raise exception using errcode = '22023', message = 'One or more banner options are invalid.';
    end if;

    v_raw_area := v_width * v_height;
    v_billable_area := greatest(v_raw_area, coalesce((v_pricing->>'minimumBillableArea')::numeric, 0));
    v_base := v_billable_area
      * coalesce((v_pricing->>'baseRate')::numeric, 0)
      * coalesce((v_pricing->'materials'->v_material->>'multiplier')::numeric, 1);
    v_service_fees :=
      coalesce((v_pricing->'finishing'->v_finishing->>'fee')::numeric, 0) +
      coalesce((v_pricing->'artwork'->v_artwork->>'fee')::numeric, 0);
    v_turn_mult := coalesce((v_pricing->'turnaround'->v_turnaround->>'multiplier')::numeric, 1);
    v_total := round((v_base + v_service_fees) * v_turn_mult, 2);
    v_summary := to_char(v_raw_area, 'FM999990.00') || 'm² actual · ' ||
                 to_char(v_billable_area, 'FM999990.00') || 'm² billable';
    v_lines := jsonb_build_array(
      jsonb_build_object('label','Print + material','value',round(v_base,2)),
      jsonb_build_object('label','Finishing + artwork','value',round(v_service_fees,2)),
      jsonb_build_object('label','Turnaround','text',v_turnaround)
    );
    v_metrics := jsonb_build_object('rawArea',v_raw_area,'billableArea',v_billable_area);

  elsif v_strategy = 'PER_PAGE' then
    begin
      v_pages := greatest(coalesce((p_configuration->>'pages')::integer, 1), 1);
      v_copies := greatest(coalesce((p_configuration->>'copies')::integer, 1), 1);
    exception when others then
      raise exception using errcode = '22023', message = 'Pages and copies must be whole numbers.';
    end;

    if v_pages > 1000 or v_copies > 500 then
      raise exception using errcode = '22023', message = 'Document quantity is outside the supported range.';
    end if;

    v_print_mode := coalesce(nullif(p_configuration->>'printMode',''), 'bw');
    v_sides := coalesce(nullif(p_configuration->>'sides',''), 'single');
    v_finish := coalesce(nullif(p_configuration->>'finish',''), 'none');

    if not coalesce((v_pricing->'rates') ? v_print_mode, false)
       or not coalesce((v_pricing->'sides') ? v_sides, false)
       or not coalesce((v_pricing->'finishes') ? v_finish, false) then
      raise exception using errcode = '22023', message = 'One or more document options are invalid.';
    end if;

    v_rate := coalesce((v_pricing->'rates'->v_print_mode->>'rate')::numeric, 0);
    v_side_mult := coalesce((v_pricing->'sides'->v_sides->>'multiplier')::numeric, 1);
    v_finish_fee := coalesce((v_pricing->'finishes'->v_finish->>'fee')::numeric, 0);
    v_printed_pages := v_pages * v_copies;
    v_base := v_printed_pages * v_rate * v_side_mult;
    v_service_fees := v_finish_fee * v_copies;
    v_total := round(v_base + v_service_fees, 2);
    v_summary := v_pages::text || ' page' || case when v_pages = 1 then '' else 's' end ||
                 ' × ' || v_copies::text || ' cop' || case when v_copies = 1 then 'y' else 'ies' end;
    v_lines := jsonb_build_array(
      jsonb_build_object('label',v_print_mode,'value',round(v_base,2)),
      jsonb_build_object('label',v_sides,'text',case when v_sides='double' then 'paper-saving option' else 'standard' end),
      jsonb_build_object('label',v_finish,'value',round(v_service_fees,2))
    );
    v_metrics := jsonb_build_object('pages',v_pages,'copies',v_copies,'printedPages',v_printed_pages);

  elsif v_strategy = 'TIERED' then
    v_quantity := greatest(coalesce(nullif(p_configuration->>'quantity','')::integer, 100), 1);
    v_stock := coalesce(nullif(p_configuration->>'stock',''), 'standard');
    v_finish := coalesce(nullif(p_configuration->>'finish',''), 'standard');
    v_artwork := coalesce(nullif(p_configuration->>'artwork',''), 'ready');

    if not coalesce((v_pricing->'quantities') ? v_quantity::text, false)
       or not coalesce((v_pricing->'stock') ? v_stock, false)
       or not coalesce((v_pricing->'finishes') ? v_finish, false)
       or not coalesce((v_pricing->'artwork') ? v_artwork, false) then
      raise exception using errcode = '22023', message = 'One or more business-card options are invalid.';
    end if;

    v_base :=
      coalesce((v_pricing->'quantities'->v_quantity::text->>'total')::numeric, 0) *
      coalesce((v_pricing->'stock'->v_stock->>'multiplier')::numeric, 1);
    v_service_fees :=
      coalesce((v_pricing->'finishes'->v_finish->>'fee')::numeric, 0) +
      coalesce((v_pricing->'artwork'->v_artwork->>'fee')::numeric, 0);
    v_total := round(v_base + v_service_fees, 2);
    v_summary := v_quantity::text || ' cards · ' || v_stock;
    v_lines := jsonb_build_array(
      jsonb_build_object('label','Cards','value',round(v_base,2)),
      jsonb_build_object('label',v_finish,'value',coalesce((v_pricing->'finishes'->v_finish->>'fee')::numeric,0)),
      jsonb_build_object('label',v_artwork,'value',coalesce((v_pricing->'artwork'->v_artwork->>'fee')::numeric,0))
    );
    v_metrics := jsonb_build_object('quantity',v_quantity);

  elsif v_strategy = 'CONFIGURABLE' then
    begin
      v_quantity := greatest(coalesce((p_configuration->>'quantity')::integer, 1), 1);
    exception when others then
      raise exception using errcode = '22023', message = 'Quantity must be a whole number.';
    end;

    if v_quantity > 250 then
      raise exception using errcode = '22023', message = 'T-shirt quantity is outside the supported range.';
    end if;

    v_garment := coalesce(nullif(p_configuration->>'garment',''), 'jointx-220');
    v_front := coalesce(nullif(p_configuration->>'frontPrint',''), 'a4');
    v_back := coalesce(nullif(p_configuration->>'backPrint',''), 'none');
    v_artwork := coalesce(nullif(p_configuration->>'artwork',''), 'ready');

    if not coalesce((v_pricing->'garments') ? v_garment, false)
       or not coalesce((v_pricing->'frontPrint') ? v_front, false)
       or not coalesce((v_pricing->'backPrint') ? v_back, false)
       or not coalesce((v_pricing->'artwork') ? v_artwork, false) then
      raise exception using errcode = '22023', message = 'One or more T-shirt options are invalid.';
    end if;

    v_unit :=
      coalesce((v_pricing->'garments'->v_garment->>'unitFee')::numeric,0) +
      coalesce((v_pricing->'frontPrint'->v_front->>'unitFee')::numeric,0) +
      coalesce((v_pricing->'backPrint'->v_back->>'unitFee')::numeric,0);

    v_discount := case when v_quantity >= 25 then 0.90 when v_quantity >= 10 then 0.95 else 1 end;
    v_base := v_unit * v_quantity * v_discount;
    v_service_fees := coalesce((v_pricing->'artwork'->v_artwork->>'fee')::numeric,0);
    v_total := round(v_base + v_service_fees, 2);
    v_summary := v_quantity::text || ' shirt' || case when v_quantity=1 then '' else 's' end || ' · ' || v_garment;
    v_lines := jsonb_build_array(
      jsonb_build_object('label','Garment + print','value',round(v_base,2)),
      jsonb_build_object('label','Artwork support','value',round(v_service_fees,2)),
      jsonb_build_object('label','Quantity pricing','text',
        case when v_discount < 1 then round((1-v_discount)*100)::text || '% quantity saving' else 'standard' end)
    );
    v_metrics := jsonb_build_object('quantity',v_quantity,'unit',v_unit,'discount',v_discount);

  else
    raise exception using errcode = '22023', message = 'Unsupported pricing strategy.';
  end if;

  return jsonb_build_object(
    'productId', v_product_id,
    'productKey', p_product_key,
    'productName', v_product_name,
    'total', v_total,
    'summary', v_summary,
    'lines', v_lines,
    'metrics', v_metrics,
    'snapshot', jsonb_build_object(
      'pricingVersion', v_pricing_version,
      'productKey', p_product_key,
      'productName', v_product_name,
      'pricingStrategy', v_strategy,
      'configuration', p_configuration,
      'pricingDefinition', v_pricing,
      'calculation', jsonb_build_object(
        'lines', v_lines,
        'metrics', v_metrics,
        'total', v_total
      ),
      'capturedAt', now()
    )
  );
end
$function$

;

CREATE OR REPLACE FUNCTION commerce.qs_generate_order_number()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_candidate text;
  v_try integer := 0;
begin
  loop
    v_try := v_try + 1;
    v_candidate :=
      'QS-' ||
      to_char(clock_timestamp() at time zone 'Africa/Johannesburg', 'YYMMDD') ||
      '-' ||
      upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 4));

    exit when not exists (
      select 1
      from commerce.service_orders so
      where so.order_number = v_candidate
    );

    if v_try >= 10 then
      raise exception 'Could not allocate Quick Solution order number.';
    end if;
  end loop;

  return v_candidate;
end
$function$

;

CREATE OR REPLACE FUNCTION commerce.qs_guard_easy_locate_business_ref()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if coalesce(auth.role(),'')='service_role'
     or session_user in ('postgres','supabase_admin') then
    return new;
  end if;

  if tg_op='INSERT' then
    new.easy_locate_business_ref := null;
    return new;
  end if;

  if new.easy_locate_business_ref is distinct from old.easy_locate_business_ref then
    new.easy_locate_business_ref := old.easy_locate_business_ref;
  end if;

  return new;
end
$function$

;

CREATE OR REPLACE FUNCTION commerce.qs_guard_service_order_cancellation_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  raise exception using errcode = '23514',
    message = 'SERVICE_ORDER_CANCELLATION_APPEND_ONLY: a cancellation record cannot be changed or removed.';
end
$function$

;

CREATE OR REPLACE FUNCTION commerce.qs_guard_service_order_item_channel()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_order_tenant uuid;
  v_order_channel text;
begin
  if tg_op = 'UPDATE'
     and new.order_id is not distinct from old.order_id
     and new.tenant_id is not distinct from old.tenant_id
     and new.product_key is not distinct from old.product_key then
    return new;
  end if;

  select so.tenant_id, so.channel
    into v_order_tenant, v_order_channel
  from commerce.service_orders so
  where so.id = new.order_id;

  if not found then
    raise exception using errcode = '23503',
      message = 'SERVICE_ORDER_ITEM_ORDER_NOT_FOUND: The order for this item does not exist.';
  end if;

  if v_order_tenant is distinct from new.tenant_id then
    raise exception using errcode = '23514',
      message = 'SERVICE_ORDER_ITEM_TENANT_MISMATCH: An order item must belong to the same tenant as its order.';
  end if;

  if not commerce._qs_product_channel_enabled(new.tenant_id, new.product_key, v_order_channel) then
    raise exception using errcode = '22023',
      message = 'PRODUCT_NOT_AVAILABLE_FOR_CHANNEL: This product is not available through this sales channel.';
  end if;

  return new;
end
$function$

;

CREATE OR REPLACE FUNCTION commerce.qs_guard_service_order_origin()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if new.channel is distinct from old.channel then
    raise exception using errcode = '23514',
      message = 'SERVICE_ORDER_CHANNEL_IMMUTABLE: The sales channel of an order cannot be changed.';
  end if;

  if new.tenant_id is distinct from old.tenant_id then
    raise exception using errcode = '23514',
      message = 'SERVICE_ORDER_TENANT_IMMUTABLE: The tenant of an order cannot be changed.';
  end if;

  return new;
end
$function$

;

CREATE OR REPLACE FUNCTION commerce.qs_normalize_document_configuration(p_configuration jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare
  v_instructions jsonb;
  v_instruction jsonb;
  v_selection text;
  v_source_pages integer;
  v_selected_pages integer;
  v_total_pages integer := 0;
  v_copies integer;
  v_count integer;
begin
  if p_configuration is null or jsonb_typeof(p_configuration) is distinct from 'object' then
    raise exception using errcode = '22023', message = 'Configuration must be a JSON object.';
  end if;

  v_instructions := p_configuration->'documentInstructions';
  if jsonb_typeof(v_instructions) is distinct from 'array' then
    raise exception using errcode = '22023', message = 'Document print instructions are required.';
  end if;

  v_count := jsonb_array_length(v_instructions);
  if v_count < 1 or v_count > 25 then
    raise exception using errcode = '22023', message = 'Add between 1 and 25 documents to this print item.';
  end if;

  for v_instruction in select value from jsonb_array_elements(v_instructions)
  loop
    if jsonb_typeof(v_instruction) is distinct from 'object' then
      raise exception using errcode = '22023', message = 'Each document needs valid print instructions.';
    end if;

    v_selection := lower(coalesce(nullif(v_instruction->>'selection', ''), 'all'));

    if v_selection = 'all' then
      begin
        v_source_pages := (v_instruction->>'sourcePages')::integer;
      exception when others then
        raise exception using errcode = '22023', message = 'Add the page count for each document you want printed in full.';
      end;

      if v_source_pages < 1 or v_source_pages > 1000 then
        raise exception using errcode = '22023', message = 'Document page counts must be between 1 and 1000.';
      end if;
      v_selected_pages := v_source_pages;
    elsif v_selection = 'specific' then
      v_selected_pages := commerce.qs_count_page_spec(v_instruction->>'pagesSpec');
    else
      raise exception using errcode = '22023', message = 'Document page selection is invalid.';
    end if;

    v_total_pages := v_total_pages + v_selected_pages;
    if v_total_pages > 1000 then
      raise exception using errcode = '22023', message = 'Document quantity is outside the supported range.';
    end if;
  end loop;

  begin
    v_copies := greatest(coalesce((p_configuration->>'copies')::integer, 1), 1);
  exception when others then
    raise exception using errcode = '22023', message = 'Copies must be a whole number.';
  end;

  if v_copies > 500 then
    raise exception using errcode = '22023', message = 'Document quantity is outside the supported range.';
  end if;

  return jsonb_set(
    jsonb_set(
      jsonb_set(p_configuration, '{pages}', to_jsonb(v_total_pages), true),
      '{documentPlanValid}', 'true'::jsonb, true
    ),
    '{serverCalculatedPages}', to_jsonb(v_total_pages), true
  );
end
$function$

;

CREATE OR REPLACE FUNCTION public.admin_get_quick_solution_catalog(p_tenant_slug text DEFAULT 'quick-solution'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_tenant_id uuid;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Staff sign-in is required.';
  end if;

  select t.id into v_tenant_id
  from public.tenants t
  where t.slug = lower(trim(p_tenant_slug))
    and t.status = 'active'
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode = '22023', message = 'Quick Solution tenant was not found.';
  end if;

  if not public.has_tenant_capability(v_tenant_id, 'cafe.operations.manage') then
    raise exception using errcode = '42501', message = 'You do not have access to Quick Solution Product Admin.';
  end if;

  return jsonb_build_object(
    'tenant', (
      select jsonb_build_object('id',t.id,'slug',t.slug,'name',t.name)
      from public.tenants t where t.id=v_tenant_id
    ),
    'products', coalesce((
      select jsonb_agg(
        c.customer_definition ||
        jsonb_build_object(
          'id', c.source_key,
          'commerceProductId', p.id,
          'name', p.name,
          'description', coalesce(p.description, c.customer_definition->>'description'),
          'pricingVersion', c.pricing_version,
          'pricingDefinition', c.pricing_definition
        )
        order by c.sort_order, p.name
      )
      from commerce.service_product_configs c
      join commerce.products p
        on p.id=c.product_id and p.tenant_id=c.tenant_id
      where c.tenant_id=v_tenant_id
        and c.status <> 'archived'
    ), '[]'::jsonb)
  );
end
$function$

;

CREATE OR REPLACE FUNCTION public.admin_get_quick_solution_fulfilment_points(p_tenant_slug text DEFAULT 'quick-solution'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_tenant_id uuid;
begin
  if auth.uid() is null then
    raise exception using errcode='42501', message='Staff sign-in is required.';
  end if;

  select t.id into v_tenant_id
  from public.tenants t
  where t.slug=lower(trim(p_tenant_slug))
    and t.status='active'
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode='22023', message='Quick Solution tenant was not found.';
  end if;

  if not public.has_tenant_capability(v_tenant_id, 'cafe.operations.manage') then
    raise exception using errcode='42501', message='You do not have access to Quick Solution fulfilment points.';
  end if;

  return jsonb_build_object(
    'tenantId', v_tenant_id,
    'points', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', fp.id,
          'slug', fp.slug,
          'name', fp.name,
          'kind', fp.kind,
          'status', fp.status,
          'address', fp.address,
          'contactPhone', fp.contact_phone,
          'contactEmail', fp.contact_email,
          'easyLocateBusinessRef', fp.easy_locate_business_ref,
          'easyLocateLink',
            case when el.id is null then null
            else jsonb_build_object(
              'id', el.id,
              'provider', el.provider,
              'externalId', el.external_id,
              'externalSlug', el.external_slug,
              'canonicalUrl', el.canonical_url,
              'status', el.status,
              'business', el.public_snapshot,
              'sourceUpdatedAt', el.source_updated_at,
              'verifiedAt', el.verified_at
            ) end,
          'latitude', fp.latitude,
          'longitude', fp.longitude,
          'collectionEnabled', fp.collection_enabled,
          'dropoffEnabled', fp.dropoff_enabled,
          'services', fp.services,
          'feeAmount', fp.fee_amount,
          'openingHours', fp.opening_hours,
          'sortOrder', fp.sort_order,
          'createdAt', fp.created_at,
          'updatedAt', fp.updated_at,
          'orderCount', (
            select count(*)
            from commerce.service_orders so
            where so.fulfilment_point_id=fp.id
          )
        )
        order by
          case fp.kind when 'cafe' then 0 else 1 end,
          fp.sort_order,
          fp.name
      )
      from commerce.fulfilment_points fp
      left join commerce.fulfilment_point_external_links el
        on el.fulfilment_point_id=fp.id
       and el.tenant_id=fp.tenant_id
       and el.provider='easy_locate'
      where fp.tenant_id=v_tenant_id
    ), '[]'::jsonb)
  );
end
$function$

;

CREATE OR REPLACE FUNCTION public.admin_list_quick_solution_opps_handoffs(p_tenant_slug text DEFAULT 'quick-solution'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_tenant_id uuid;
begin
  if auth.uid() is null then
    raise exception using errcode='42501', message='Staff sign-in is required.';
  end if;

  select t.id into v_tenant_id
  from public.tenants t
  where t.slug=lower(trim(p_tenant_slug))
    and t.status='active'
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode='22023', message='Quick Solution tenant was not found.';
  end if;

  if not public.has_tenant_capability(v_tenant_id, 'cafe.operations.manage') then
    raise exception using errcode='42501', message='You do not have access to Quick Solution handoffs.';
  end if;

  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'serviceOrderId', so.id,
        'orderNumber', so.order_number,
        'customerName', so.customer_name,
        'totalAmount', so.total_amount,
        'paymentStatus', so.payment_status,
        'serviceStatus', so.status,
        'submittedAt', so.submitted_at,
        'oppsOrderId', so.opps_order_id,
        'handoffStatus', coalesce(h.status,'not_previewed'),
        'mappingVersion', h.mapping_version,
        'lastPreviewedAt', h.last_previewed_at,
        'sentAt', h.sent_at,
        'blockers', coalesce(h.blockers,'[]'::jsonb),
        'warnings', coalesce(h.warnings,'[]'::jsonb),
        'previewPayload',
          case
            when h.id is null then null
            else h.preview_payload
          end
      )
      order by so.submitted_at desc
    )
    from commerce.service_orders so
    left join commerce.service_order_handoffs h
      on h.service_order_id=so.id
    where so.tenant_id=v_tenant_id
  ), '[]'::jsonb);
end
$function$

;

CREATE OR REPLACE FUNCTION public.admin_preview_quick_solution_opps_handoff(p_service_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_preview jsonb;
  v_source_tenant_id uuid;
  v_target_tenant_id uuid;
  v_status text;
  v_idempotency_key text;
  v_existing_handoff_status text;
  v_existing_opps_order_id uuid;
  v_existing_preview jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode='42501', message='Staff sign-in is required.';
  end if;

  select so.tenant_id
  into v_source_tenant_id
  from commerce.service_orders so
  where so.id=p_service_order_id
  limit 1;

  if v_source_tenant_id is null then
    raise exception using errcode='22023', message='Quick Solution order was not found.';
  end if;

  if not public.has_tenant_capability(v_source_tenant_id, 'cafe.operations.manage') then
    raise exception using errcode='42501', message='You do not have access to this Quick Solution order.';
  end if;

  select h.status, h.opps_order_id, h.preview_payload
  into v_existing_handoff_status, v_existing_opps_order_id, v_existing_preview
  from commerce.service_order_handoffs h
  where h.service_order_id=p_service_order_id
  limit 1;

  if v_existing_handoff_status='sent'
     and v_existing_opps_order_id is not null
     and v_existing_preview is not null
     and jsonb_typeof(v_existing_preview)='object' then
    return v_existing_preview;
  end if;

  v_preview := commerce.qs_build_opps_handoff_preview(p_service_order_id);
  v_target_tenant_id := (v_preview->'proposedOppsOrder'->>'tenant_id')::uuid;
  v_status := case when coalesce((v_preview->>'ready')::boolean,false) then 'ready' else 'blocked' end;
  v_idempotency_key := 'quick-solution:opps:' || p_service_order_id::text;

  insert into commerce.service_order_handoffs (
    service_order_id,
    source_tenant_id,
    target_tenant_id,
    mapping_version,
    status,
    preview_payload,
    blockers,
    warnings,
    idempotency_key,
    last_previewed_at,
    last_previewed_by
  )
  values (
    p_service_order_id,
    v_source_tenant_id,
    v_target_tenant_id,
    'qs-opps-v1',
    v_status,
    v_preview,
    coalesce(v_preview->'blockers','[]'::jsonb),
    coalesce(v_preview->'warnings','[]'::jsonb),
    v_idempotency_key,
    now(),
    auth.uid()
  )
  on conflict (service_order_id) do update
  set target_tenant_id=excluded.target_tenant_id,
      mapping_version=excluded.mapping_version,
      status=case
        when commerce.service_order_handoffs.status='sent' then 'sent'
        else excluded.status
      end,
      preview_payload=case
        when commerce.service_order_handoffs.status='sent'
          then commerce.service_order_handoffs.preview_payload
        else excluded.preview_payload
      end,
      blockers=case
        when commerce.service_order_handoffs.status='sent'
          then commerce.service_order_handoffs.blockers
        else excluded.blockers
      end,
      warnings=case
        when commerce.service_order_handoffs.status='sent'
          then commerce.service_order_handoffs.warnings
        else excluded.warnings
      end,
      idempotency_key=excluded.idempotency_key,
      last_previewed_at=case
        when commerce.service_order_handoffs.status='sent'
          then commerce.service_order_handoffs.last_previewed_at
        else excluded.last_previewed_at
      end,
      last_previewed_by=case
        when commerce.service_order_handoffs.status='sent'
          then commerce.service_order_handoffs.last_previewed_by
        else excluded.last_previewed_by
      end,
      failure_message=case
        when commerce.service_order_handoffs.status='sent'
          then commerce.service_order_handoffs.failure_message
        else null
      end;

  return v_preview;
end
$function$

;

CREATE OR REPLACE FUNCTION public.admin_send_quick_solution_order_to_opps(p_service_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_service_order commerce.service_orders;
  v_preview jsonb;
  v_proposed jsonb;
  v_ready boolean;
  v_target_tenant_id uuid;
  v_existing_opps_id uuid;
  v_existing_source_service_order_id text;
  v_opps_order_id uuid;
  v_handoff_id uuid;
  v_idempotency_key text;
  v_file_urls text[] := '{}'::text[];
begin
  select so.*
  into v_service_order
  from commerce.service_orders so
  where so.id = p_service_order_id
  for update;

  if v_service_order.id is null then
    raise exception using errcode='22023', message='Quick Solution order was not found.';
  end if;

  if current_user <> 'service_role' then
    if auth.uid() is null then
      raise exception using errcode='42501', message='Staff sign-in is required.';
    end if;

    if not public.has_tenant_capability(v_service_order.tenant_id, 'cafe.operations.manage') then
      raise exception using errcode='42501', message='You do not have access to this Quick Solution order.';
    end if;
  end if;

  if v_service_order.opps_order_id is not null then
    if exists (
      select 1
      from public.orders o
      where o.id = v_service_order.opps_order_id
        and o.tenant_id = v_service_order.tenant_id
        and o.source = 'quick_solution'
    ) then
      perform commerce._qs_sync_opps_payment_ledger(v_service_order.id, v_service_order.opps_order_id);
      return jsonb_build_object(
        'ok', true,
        'replayed', true,
        'serviceOrderId', v_service_order.id,
        'orderNumber', v_service_order.order_number,
        'oppsOrderId', v_service_order.opps_order_id,
        'handoffStatus', 'sent'
      );
    end if;

    raise exception using errcode='P0001', message='Quick Solution backlink points to an invalid OPPS order.';
  end if;

  v_preview := commerce.qs_build_opps_handoff_preview(v_service_order.id);
  v_ready := coalesce((v_preview->>'ready')::boolean, false);

  if not v_ready then
    v_target_tenant_id := nullif(v_preview->'proposedOppsOrder'->>'tenant_id','')::uuid;
    v_idempotency_key := 'quick-solution:opps:' || v_service_order.id::text;

    if v_target_tenant_id is not null then
      insert into commerce.service_order_handoffs (
        service_order_id, source_tenant_id, target_tenant_id, mapping_version,
        status, preview_payload, blockers, warnings, idempotency_key,
        last_previewed_at, last_previewed_by
      )
      values (
        v_service_order.id, v_service_order.tenant_id, v_target_tenant_id,
        coalesce(v_preview->>'mappingVersion','qs-opps-v1'),
        'blocked', v_preview,
        coalesce(v_preview->'blockers','[]'::jsonb),
        coalesce(v_preview->'warnings','[]'::jsonb),
        v_idempotency_key, now(), auth.uid()
      )
      on conflict (service_order_id) do update
      set status = case when commerce.service_order_handoffs.status='sent' then 'sent' else 'blocked' end,
          preview_payload = excluded.preview_payload,
          blockers = excluded.blockers,
          warnings = excluded.warnings,
          last_previewed_at = excluded.last_previewed_at,
          last_previewed_by = excluded.last_previewed_by,
          failure_message = null;
    end if;

    return jsonb_build_object(
      'ok', false,
      'replayed', false,
      'serviceOrderId', v_service_order.id,
      'orderNumber', v_service_order.order_number,
      'handoffStatus', 'blocked',
      'blockers', coalesce(v_preview->'blockers','[]'::jsonb),
      'warnings', coalesce(v_preview->'warnings','[]'::jsonb)
    );
  end if;

  v_proposed := v_preview->'proposedOppsOrder';
  v_target_tenant_id := (v_proposed->>'tenant_id')::uuid;
  v_idempotency_key := 'quick-solution:opps:' || v_service_order.id::text;

  select h.id, h.opps_order_id
  into v_handoff_id, v_existing_opps_id
  from commerce.service_order_handoffs h
  where h.service_order_id = v_service_order.id
  for update;

  if v_existing_opps_id is not null
     and exists (
       select 1 from public.orders o
       where o.id=v_existing_opps_id
         and o.tenant_id=v_target_tenant_id
         and o.source='quick_solution'
     ) then
    update commerce.service_orders
    set opps_order_id=v_existing_opps_id,
        status=case when status='submitted' then 'accepted' else status end,
        source_metadata=coalesce(source_metadata,'{}'::jsonb) ||
          jsonb_build_object(
            'oppsHandoff',
            jsonb_build_object(
              'status','sent',
              'oppsOrderId',v_existing_opps_id,
              'mappingVersion',coalesce(v_preview->>'mappingVersion','qs-opps-v1')
            )
          )
    where id=v_service_order.id;

    perform commerce._qs_sync_opps_payment_ledger(v_service_order.id, v_existing_opps_id);

    return jsonb_build_object(
      'ok', true,
      'replayed', true,
      'serviceOrderId', v_service_order.id,
      'orderNumber', v_service_order.order_number,
      'oppsOrderId', v_existing_opps_id,
      'handoffStatus', 'sent'
    );
  end if;

  select o.id,
         o.source_metadata->'quick_solution'->>'service_order_id'
  into v_existing_opps_id, v_existing_source_service_order_id
  from public.orders o
  where o.tenant_id=v_target_tenant_id
    and o.order_number=v_service_order.order_number
  limit 1;

  if v_existing_opps_id is not null then
    if v_existing_source_service_order_id = v_service_order.id::text
       and exists (
         select 1 from public.orders o
         where o.id=v_existing_opps_id and o.source='quick_solution'
       ) then

      insert into commerce.service_order_handoffs (
        service_order_id, source_tenant_id, target_tenant_id, mapping_version,
        status, preview_payload, blockers, warnings, opps_order_id,
        idempotency_key, last_previewed_at, last_previewed_by, sent_at
      )
      values (
        v_service_order.id, v_service_order.tenant_id, v_target_tenant_id,
        coalesce(v_preview->>'mappingVersion','qs-opps-v1'),
        'sent', v_preview, '[]'::jsonb,
        coalesce(v_preview->'warnings','[]'::jsonb), v_existing_opps_id,
        v_idempotency_key, now(), auth.uid(), now()
      )
      on conflict (service_order_id) do update
      set status='sent',
          preview_payload=excluded.preview_payload,
          blockers='[]'::jsonb,
          warnings=excluded.warnings,
          opps_order_id=excluded.opps_order_id,
          sent_at=coalesce(commerce.service_order_handoffs.sent_at, now()),
          failure_message=null;

      update commerce.service_orders
      set opps_order_id=v_existing_opps_id,
          status=case when status='submitted' then 'accepted' else status end,
          source_metadata=coalesce(source_metadata,'{}'::jsonb) ||
            jsonb_build_object(
              'oppsHandoff',
              jsonb_build_object(
                'status','sent',
                'oppsOrderId',v_existing_opps_id,
                'mappingVersion',coalesce(v_preview->>'mappingVersion','qs-opps-v1')
              )
            )
      where id=v_service_order.id;

      perform commerce._qs_sync_opps_payment_ledger(v_service_order.id, v_existing_opps_id);

      return jsonb_build_object(
        'ok', true,
        'replayed', true,
        'recovered', true,
        'serviceOrderId', v_service_order.id,
        'orderNumber', v_service_order.order_number,
        'oppsOrderId', v_existing_opps_id,
        'handoffStatus', 'sent'
      );
    end if;

    raise exception using errcode='23505',
      message='An OPPS order already uses this Quick Solution order number but is not linked to this source order.';
  end if;

  insert into commerce.service_order_handoffs (
    service_order_id, source_tenant_id, target_tenant_id, mapping_version,
    status, preview_payload, blockers, warnings, idempotency_key,
    last_previewed_at, last_previewed_by
  )
  values (
    v_service_order.id, v_service_order.tenant_id, v_target_tenant_id,
    coalesce(v_preview->>'mappingVersion','qs-opps-v1'),
    'sending', v_preview, '[]'::jsonb,
    coalesce(v_preview->'warnings','[]'::jsonb),
    v_idempotency_key, now(), auth.uid()
  )
  on conflict (service_order_id) do update
  set target_tenant_id=excluded.target_tenant_id,
      mapping_version=excluded.mapping_version,
      status='sending',
      preview_payload=excluded.preview_payload,
      blockers='[]'::jsonb,
      warnings=excluded.warnings,
      idempotency_key=excluded.idempotency_key,
      last_previewed_at=excluded.last_previewed_at,
      last_previewed_by=excluded.last_previewed_by,
      failure_message=null
  returning id into v_handoff_id;

  select coalesce(array_agg(f.value), '{}'::text[])
  into v_file_urls
  from jsonb_array_elements_text(coalesce(v_proposed->'file_urls','[]'::jsonb)) f(value);

  begin
    insert into public.orders (
      tenant_id,
      order_number,
      client_name,
      client_email,
      client_phone,
      status,
      priority,
      products,
      total_amount,
      deposit_paid,
      special_instructions,
      file_urls,
      source,
      pipeline_stage,
      portal_show_files,
      account_show_files,
      fulfillment_type,
      apply_shipping_fee,
      shipping_fee,
      payment_status,
      shipping_address,
      shipping_method,
      checkout_idempotency_key,
      source_metadata
    ) values (
      v_target_tenant_id,
      v_proposed->>'order_number',
      v_proposed->>'client_name',
      nullif(v_proposed->>'client_email',''),
      nullif(v_proposed->>'client_phone',''),
      coalesce(v_proposed->>'status','confirmed'),
      coalesce(v_proposed->>'priority','normal'),
      coalesce(v_proposed->'products','[]'::jsonb),
      coalesce((v_proposed->>'total_amount')::numeric,0),
      coalesce((v_proposed->>'deposit_paid')::numeric,0),
      nullif(v_proposed->>'special_instructions',''),
      v_file_urls,
      'quick_solution',
      coalesce(v_proposed->>'pipeline_stage','received'),
      false,
      false,
      coalesce(v_proposed->>'fulfillment_type','service_only'),
      coalesce((v_proposed->>'apply_shipping_fee')::boolean,false),
      coalesce((v_proposed->>'shipping_fee')::numeric,0),
      coalesce(v_proposed->>'payment_status','pending'),
      v_proposed->'shipping_address',
      nullif(v_proposed->>'shipping_method',''),
      v_idempotency_key,
      coalesce(v_proposed->'source_metadata','{}'::jsonb)
    )
    returning id into v_opps_order_id;
  exception when others then
    update commerce.service_order_handoffs
    set status='failed',
        failure_message=sqlerrm
    where id=v_handoff_id;

    return jsonb_build_object(
      'ok', false,
      'replayed', false,
      'serviceOrderId', v_service_order.id,
      'orderNumber', v_service_order.order_number,
      'handoffStatus', 'failed',
      'error', sqlerrm
    );
  end;

  update commerce.service_orders
  set opps_order_id=v_opps_order_id,
      status=case when status='submitted' then 'accepted' else status end,
      source_metadata=coalesce(source_metadata,'{}'::jsonb) ||
        jsonb_build_object(
          'oppsHandoff',
          jsonb_build_object(
            'status','sent',
            'oppsOrderId',v_opps_order_id,
            'mappingVersion',coalesce(v_preview->>'mappingVersion','qs-opps-v1'),
            'sentAt',now()
          )
        )
  where id=v_service_order.id;

  update commerce.service_order_handoffs
  set status='sent',
      opps_order_id=v_opps_order_id,
      sent_at=now(),
      failure_message=null
  where id=v_handoff_id;

  perform commerce._qs_sync_opps_payment_ledger(v_service_order.id, v_opps_order_id);

  return jsonb_build_object(
    'ok', true,
    'replayed', false,
    'serviceOrderId', v_service_order.id,
    'orderNumber', v_service_order.order_number,
    'oppsOrderId', v_opps_order_id,
    'handoffStatus', 'sent',
    'warnings', coalesce(v_preview->'warnings','[]'::jsonb)
  );
end
$function$

;

CREATE OR REPLACE FUNCTION public.admin_update_quick_solution_product(p_tenant_slug text, p_product_key text, p_customer_definition jsonb, p_pricing_definition jsonb, p_expected_pricing_version text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_tenant_id uuid;
  v_config commerce.service_product_configs;
  v_product_name text;
  v_description text;
  v_active boolean;
  v_strategy text;
  v_new_version text;
  v_customer_definition jsonb;
  v_customer_mirror jsonb;
  v_pricing_definition jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Staff sign-in is required.';
  end if;

  select t.id into v_tenant_id
  from public.tenants t
  where t.slug=lower(trim(p_tenant_slug)) and t.status='active'
  limit 1;
  if v_tenant_id is null then
    raise exception using errcode = '22023', message = 'Quick Solution tenant was not found.';
  end if;

  if not public.has_tenant_capability(v_tenant_id, 'cafe.operations.manage') then
    raise exception using errcode = '42501', message = 'You do not have access to Quick Solution Product Admin.';
  end if;

  if jsonb_typeof(p_customer_definition) is distinct from 'object'
     or jsonb_typeof(p_pricing_definition) is distinct from 'object' then
    raise exception using errcode = '22023', message = 'Product definitions must be JSON objects.';
  end if;

  select * into v_config
  from commerce.service_product_configs c
  where c.tenant_id=v_tenant_id and c.source_key=trim(p_product_key)
  limit 1;
  if v_config.id is null then
    raise exception using errcode = '22023', message = 'Product was not found.';
  end if;

  if p_expected_pricing_version is null or v_config.pricing_version <> p_expected_pricing_version then
    raise exception using errcode = '40001', message = 'This product changed after you opened it. Reload before saving.';
  end if;

  v_strategy := upper(coalesce(p_pricing_definition->>'strategy',''));
  if v_strategy not in ('PER_AREA','PER_PAGE','TIERED','CONFIGURABLE','SUPPLIER_MARGIN','PHOTOGRAPHY_SESSION','PER_UNIT') then
    raise exception using errcode = '22023', message = 'Pricing strategy is not supported.';
  end if;

  v_product_name := left(trim(coalesce(p_customer_definition->>'name','')), 160);
  v_description := nullif(trim(coalesce(p_customer_definition->>'description', p_customer_definition->>'plainDescription','')), '');
  v_active := coalesce((p_customer_definition->>'active')::boolean, true);
  if length(v_product_name) < 2 then
    raise exception using errcode = '22023', message = 'Product name is required.';
  end if;

  v_customer_definition := p_customer_definition;
  if v_strategy in ('SUPPLIER_MARGIN','PHOTOGRAPHY_SESSION') then
    v_customer_mirror := commerce._qs_derive_customer_pricing_mirror(p_pricing_definition);
    if v_customer_mirror is not null then
      v_customer_definition := jsonb_set(v_customer_definition, '{pricing}', v_customer_mirror, true);
    end if;
  end if;

  v_pricing_definition := p_pricing_definition;
  if v_strategy = 'PER_UNIT' then
    perform commerce._qs_validate_per_unit_definition(p_pricing_definition);
    v_pricing_definition := jsonb_build_object(
      'strategy', 'PER_UNIT',
      'unitPrice', p_pricing_definition -> 'unitPrice',
      'minUnits', p_pricing_definition -> 'minUnits',
      'maxUnits', p_pricing_definition -> 'maxUnits'
    );
    v_customer_definition := jsonb_set(v_customer_definition, '{pricing}', v_pricing_definition, true);
  end if;

  v_new_version := 'qsc-' || to_char(clock_timestamp() at time zone 'Africa/Johannesburg','YYYYMMDD-HH24MISS') || '-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,4));

  update commerce.service_product_configs c
  set customer_definition=v_customer_definition,
      pricing_definition=v_pricing_definition,
      pricing_version=v_new_version,
      status=case when v_active then 'published' else 'draft' end,
      updated_at=now()
  where c.id=v_config.id;

  update commerce.products p
  set name=v_product_name,
      description=v_description,
      status=case when v_active then 'published' else 'draft' end,
      availability=case when v_active then 'available' else 'unavailable' end,
      updated_at=now()
  where p.id=v_config.product_id and p.tenant_id=v_tenant_id;

  return jsonb_build_object('ok', true, 'productKey', trim(p_product_key), 'pricingVersion', v_new_version);
end
$function$

;

CREATE OR REPLACE FUNCTION public.admin_upsert_quick_solution_fulfilment_point(p_tenant_slug text, p_point_id uuid, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_tenant_id uuid;
  v_existing commerce.fulfilment_points;
  v_point_id uuid;
  v_name text;
  v_slug text;
  v_kind text;
  v_status text;
  v_address jsonb;
  v_contact_phone text;
  v_contact_email text;
  v_easy_ref text;
  v_lat numeric;
  v_lng numeric;
  v_collection boolean;
  v_dropoff boolean;
  v_services text[];
  v_fee numeric;
  v_opening_hours jsonb;
  v_sort integer;
begin
  if auth.uid() is null then
    raise exception using errcode='42501', message='Staff sign-in is required.';
  end if;

  select t.id into v_tenant_id
  from public.tenants t
  where t.slug=lower(trim(p_tenant_slug))
    and t.status='active'
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode='22023', message='Quick Solution tenant was not found.';
  end if;

  if not public.has_tenant_capability(v_tenant_id, 'cafe.operations.manage') then
    raise exception using errcode='42501', message='You do not have access to Quick Solution fulfilment points.';
  end if;

  if p_payload is null or jsonb_typeof(p_payload) is distinct from 'object' then
    raise exception using errcode='22023', message='Quick Point details must be a JSON object.';
  end if;

  if p_point_id is not null then
    select * into v_existing
    from commerce.fulfilment_points fp
    where fp.id=p_point_id
      and fp.tenant_id=v_tenant_id
    for update;

    if v_existing.id is null then
      raise exception using errcode='22023', message='Quick Point was not found.';
    end if;
  end if;

  v_name := left(trim(coalesce(p_payload->>'name','')), 160);
  if length(v_name) < 2 then
    raise exception using errcode='22023', message='Quick Point name is required.';
  end if;

  v_kind := lower(trim(coalesce(
    case when p_point_id is not null then v_existing.kind else null end,
    p_payload->>'kind',
    'quick_point'
  )));

  if v_kind not in ('cafe','quick_point') then
    raise exception using errcode='22023', message='Point type must be café or Quick Point.';
  end if;

  if p_point_id is not null
     and v_existing.kind is distinct from v_kind
     and exists (select 1 from commerce.service_orders so where so.fulfilment_point_id=v_existing.id) then
    raise exception using errcode='22023', message='Point type cannot change after orders have used this location.';
  end if;

  v_status := lower(trim(coalesce(p_payload->>'status', case when p_point_id is null then 'active' else v_existing.status end, 'active')));
  if v_status not in ('active','inactive','coming_soon') then
    raise exception using errcode='22023', message='Point status is not supported.';
  end if;

  v_collection := coalesce((p_payload->>'collectionEnabled')::boolean, true);
  v_dropoff := coalesce((p_payload->>'dropoffEnabled')::boolean, false);
  if not v_collection and not v_dropoff then
    raise exception using errcode='22023', message='Enable collection, drop-off, or both.';
  end if;

  v_address := coalesce(p_payload->'address','{}'::jsonb);
  if jsonb_typeof(v_address) is distinct from 'object' then
    raise exception using errcode='22023', message='Address must be a JSON object.';
  end if;

  v_contact_phone := nullif(left(trim(coalesce(p_payload->>'contactPhone','')), 80),'');
  v_contact_email := nullif(left(lower(trim(coalesce(p_payload->>'contactEmail',''))), 180),'');
  if v_contact_email is not null and position('@' in v_contact_email) < 2 then
    raise exception using errcode='22023', message='Contact email is not valid.';
  end if;

  v_easy_ref := nullif(left(trim(coalesce(p_payload->>'easyLocateBusinessRef','')), 240),'');
  v_lat := nullif(p_payload->>'latitude','')::numeric;
  v_lng := nullif(p_payload->>'longitude','')::numeric;

  if v_lat is not null and (v_lat < -90 or v_lat > 90) then
    raise exception using errcode='22023', message='Latitude must be between -90 and 90.';
  end if;
  if v_lng is not null and (v_lng < -180 or v_lng > 180) then
    raise exception using errcode='22023', message='Longitude must be between -180 and 180.';
  end if;

  v_fee := greatest(coalesce(nullif(p_payload->>'feeAmount','')::numeric,0),0);
  v_sort := coalesce(nullif(p_payload->>'sortOrder','')::integer, 100);

  v_opening_hours := coalesce(p_payload->'openingHours','{}'::jsonb);
  if jsonb_typeof(v_opening_hours) is distinct from 'object' then
    raise exception using errcode='22023', message='Opening hours must be a JSON object.';
  end if;

  select coalesce(array_agg(value order by ordinality), '{}'::text[])
  into v_services
  from jsonb_array_elements_text(coalesce(p_payload->'services','[]'::jsonb)) with ordinality t(value, ordinality)
  where length(trim(value)) between 1 and 80;

  if p_point_id is null then
    v_slug := regexp_replace(lower(v_name), '[^a-z0-9]+', '-', 'g');
    v_slug := regexp_replace(v_slug, '(^-+|-+$)', '', 'g');
    if length(v_slug) < 2 then
      v_slug := 'quick-point-' || lower(substr(replace(gen_random_uuid()::text,'-',''),1,6));
    end if;

    if exists (
      select 1 from commerce.fulfilment_points fp
      where fp.tenant_id=v_tenant_id and fp.slug=v_slug
    ) then
      v_slug := left(v_slug, 90) || '-' || lower(substr(replace(gen_random_uuid()::text,'-',''),1,4));
    end if;

    insert into commerce.fulfilment_points (
      tenant_id, slug, name, kind, status, address,
      contact_phone, contact_email, easy_locate_business_ref,
      latitude, longitude, collection_enabled, dropoff_enabled,
      services, fee_amount, opening_hours, sort_order
    )
    values (
      v_tenant_id, v_slug, v_name, v_kind, v_status, v_address,
      v_contact_phone, v_contact_email, v_easy_ref,
      v_lat, v_lng, v_collection, v_dropoff,
      coalesce(v_services,'{}'::text[]), v_fee, v_opening_hours, v_sort
    )
    returning id into v_point_id;
  else
    v_point_id := v_existing.id;
    v_slug := v_existing.slug;

    if v_existing.kind='cafe'
       and (v_status <> 'active' or v_collection=false)
       and not exists (
         select 1
         from commerce.fulfilment_points fp
         where fp.tenant_id=v_tenant_id
           and fp.id <> v_existing.id
           and fp.kind='cafe'
           and fp.status='active'
           and fp.collection_enabled=true
       ) then
      raise exception using errcode='22023', message='Keep at least one active café collection location.';
    end if;

    update commerce.fulfilment_points fp
    set name=v_name,
        kind=v_kind,
        status=v_status,
        address=v_address,
        contact_phone=v_contact_phone,
        contact_email=v_contact_email,
        easy_locate_business_ref=v_easy_ref,
        latitude=v_lat,
        longitude=v_lng,
        collection_enabled=v_collection,
        dropoff_enabled=v_dropoff,
        services=coalesce(v_services,'{}'::text[]),
        fee_amount=v_fee,
        opening_hours=v_opening_hours,
        sort_order=v_sort,
        updated_at=now()
    where fp.id=v_existing.id
      and fp.tenant_id=v_tenant_id;
  end if;

  return (
    select jsonb_build_object(
      'ok', true,
      'point', jsonb_build_object(
        'id', fp.id,
        'slug', fp.slug,
        'name', fp.name,
        'kind', fp.kind,
        'status', fp.status,
        'address', fp.address,
        'contactPhone', fp.contact_phone,
        'contactEmail', fp.contact_email,
        'easyLocateBusinessRef', fp.easy_locate_business_ref,
        'latitude', fp.latitude,
        'longitude', fp.longitude,
        'collectionEnabled', fp.collection_enabled,
        'dropoffEnabled', fp.dropoff_enabled,
        'services', fp.services,
        'feeAmount', fp.fee_amount,
        'openingHours', fp.opening_hours,
        'sortOrder', fp.sort_order,
        'updatedAt', fp.updated_at
      )
    )
    from commerce.fulfilment_points fp
    where fp.id=v_point_id
  );
end
$function$

;

CREATE OR REPLACE FUNCTION public.cancel_quick_solution_counter_order(p_order_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_actor uuid;
  v_tenant_id uuid;
  v_reason text;
  v_order commerce.service_orders;
  v_existing commerce.service_order_cancellations;
  v_block text;
  v_outstanding numeric;
  v_at timestamptz;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception using errcode = '42501', message = 'Staff sign-in is required.';
  end if;

  select t.id
  into v_tenant_id
  from public.tenants t
  where t.slug = 'quick-solution'
    and t.status = 'active'
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode = '22023', message = 'Quick Solution tenant was not found.';
  end if;

  if not public.has_tenant_capability(v_tenant_id, 'cafe.operations.manage') then
    raise exception using errcode = '42501', message = 'Only a Quick Solution admin or owner can cancel a counter order.';
  end if;

  if not exists (
    select 1
    from public.tenant_capabilities tc
    where tc.tenant_id = v_tenant_id
      and tc.capability_key = 'quick_solution'
      and tc.enabled = true
  ) then
    raise exception using errcode = '22023', message = 'Quick Solution counter is not active.';
  end if;

  v_reason := btrim(coalesce(p_reason, ''));
  if char_length(v_reason) < 3 then
    raise exception using errcode = '22023', message = 'A reason for the cancellation is required.';
  end if;
  if char_length(v_reason) > 300 then
    raise exception using errcode = '22023', message = 'The cancellation reason is too long.';
  end if;
  if v_reason ~ '[[:cntrl:]]' then
    raise exception using errcode = '22023', message = 'The cancellation reason is not valid.';
  end if;
  if p_order_id is null then
    raise exception using errcode = '22023', message = 'Counter order was not found.';
  end if;

  -- the same order row lock the counter payment takes: a payment and a cancel of one order cannot both win
  select so.*
  into v_order
  from commerce.service_orders so
  where so.id = p_order_id
    and so.tenant_id = v_tenant_id
    and so.channel = 'counter'
  for update;

  if v_order.id is null then
    raise exception using errcode = '22023', message = 'Counter order was not found.';
  end if;

  v_block := commerce._qs_counter_cancel_block(v_order);

  if v_block = 'already_cancelled' then
    select c.* into v_existing
    from commerce.service_order_cancellations c
    where c.service_order_id = v_order.id;
    if v_existing.id is not null and v_existing.cancelled_by = v_actor and v_existing.reason = v_reason then
      return jsonb_build_object(
        'ok', true,
        'replayed', true,
        'orderId', v_order.id,
        'orderNumber', v_order.order_number,
        'status', 'cancelled',
        'cancelledAt', v_existing.cancelled_at,
        'reason', v_existing.reason
      );
    end if;
    raise exception using errcode = '22023', message = 'This order is already cancelled.';
  elsif v_block = 'has_payment' then
    raise exception using errcode = '22023', message = 'This order has a payment and cannot be cancelled.';
  elsif v_block = 'payment_in_progress' then
    raise exception using errcode = '22023', message = 'A payment for this order is still in progress, so it cannot be cancelled.';
  elsif v_block = 'sent_to_production' then
    raise exception using errcode = '22023', message = 'This order has already been sent to production and cannot be cancelled here.';
  elsif v_block = 'in_progress' then
    raise exception using errcode = '22023', message = 'This order is already being worked on and cannot be cancelled here.';
  elsif v_block = 'nothing_outstanding' then
    raise exception using errcode = '22023', message = 'This order has nothing outstanding to cancel.';
  elsif v_block is not null then
    raise exception using errcode = '22023', message = 'This order cannot be cancelled.';
  end if;

  v_outstanding := greatest(round(v_order.total_amount - commerce._qs_order_amount_paid(v_order.id), 2), 0);
  v_at := clock_timestamp();

  update commerce.service_orders
  set status = 'cancelled',
      updated_at = now()
  where id = v_order.id;

  insert into commerce.service_order_cancellations (
    tenant_id, service_order_id, cancelled_by, cancelled_at, reason, prior_status, prior_payment_status, order_total, outstanding_at_cancel
  )
  values (
    v_tenant_id, v_order.id, v_actor, v_at, v_reason, v_order.status, v_order.payment_status, v_order.total_amount, v_outstanding
  );

  return jsonb_build_object(
    'ok', true,
    'replayed', false,
    'orderId', v_order.id,
    'orderNumber', v_order.order_number,
    'status', 'cancelled',
    'cancelledAt', v_at,
    'reason', v_reason
  );
end
$function$

;

CREATE OR REPLACE FUNCTION public.create_quick_solution_cart_order(p_tenant_slug text, p_items jsonb, p_customer_name text, p_customer_email text DEFAULT NULL::text, p_customer_phone text DEFAULT NULL::text, p_fulfilment_type text DEFAULT 'cafe'::text, p_fulfilment_point_id uuid DEFAULT NULL::uuid, p_delivery_address jsonb DEFAULT NULL::jsonb, p_customer_notes text DEFAULT NULL::text, p_idempotency_key text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_tenant_id uuid;
  v_order_id uuid;
  v_existing commerce.service_orders;
  v_order_number text;
  v_subtotal numeric := 0;
  v_fulfilment_fee numeric := 0;
  v_total numeric := 0;
  v_fulfilment_type text;
  v_point commerce.fulfilment_points;
  v_email text;
  v_phone text;
  v_upload_token text;
  v_payment_token text;
  v_tracking jsonb;
  v_fulfilment_snapshot jsonb := null;
  v_item jsonb;
  v_price jsonb;
  v_product_id uuid;
  v_product_name text;
  v_product_key text;
  v_configuration jsonb;
  v_client_item_key text;
  v_priced_items jsonb := '[]'::jsonb;
  v_response_items jsonb := '[]'::jsonb;
  v_order_item_id uuid;
  v_count integer;
begin
  select t.id into v_tenant_id
  from public.tenants t
  where t.slug = lower(trim(p_tenant_slug))
    and t.status = 'active'
    and exists (
      select 1 from public.tenant_capabilities tc
      where tc.tenant_id = t.id
        and tc.capability_key = 'quick_solution'
        and tc.enabled = true
    )
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode = '22023', message = 'Quick Solution storefront is not active.';
  end if;

  if length(trim(coalesce(p_idempotency_key,''))) < 8 then
    raise exception using errcode = '22023', message = 'Order idempotency key is required.';
  end if;

  if length(trim(coalesce(p_customer_name,''))) < 2 then
    raise exception using errcode = '22023', message = 'Customer name is required.';
  end if;

  if p_items is null or jsonb_typeof(p_items) is distinct from 'array' then
    raise exception using errcode = '22023', message = 'Cart items must be an array.';
  end if;

  v_count := jsonb_array_length(p_items);
  if v_count < 1 then
    raise exception using errcode = '22023', message = 'Add at least one item to the order.';
  end if;
  if v_count > 25 then
    raise exception using errcode = '22023', message = 'This order has too many items. Split it into smaller orders.';
  end if;

  v_email := nullif(lower(trim(coalesce(p_customer_email,''))), '');
  v_phone := nullif(trim(coalesce(p_customer_phone,'')), '');

  if v_email is null and v_phone is null then
    raise exception using errcode = '22023', message = 'Provide an email address or phone number.';
  end if;
  if v_email is not null and position('@' in v_email) < 2 then
    raise exception using errcode = '22023', message = 'Email address is not valid.';
  end if;
  if v_phone is not null and length(regexp_replace(v_phone, '[^0-9+]', '', 'g')) < 7 then
    raise exception using errcode = '22023', message = 'Phone number is not valid.';
  end if;

  select * into v_existing
  from commerce.service_orders so
  where so.tenant_id = v_tenant_id
    and so.idempotency_key = trim(p_idempotency_key)
  limit 1;

  if v_existing.id is not null then
    v_upload_token := encode(extensions.gen_random_bytes(32), 'hex');
    v_payment_token := encode(extensions.gen_random_bytes(32), 'hex');
    v_tracking := commerce.qs_issue_tracking_token(v_existing.id);

    update commerce.service_orders
    set upload_token_hash = encode(extensions.digest(v_upload_token, 'sha256'), 'hex'),
        upload_token_expires_at = now() + interval '24 hours',
        payment_token_hash = encode(extensions.digest(v_payment_token, 'sha256'), 'hex'),
        payment_token_expires_at = now() + interval '7 days'
    where id = v_existing.id;

    select coalesce(jsonb_agg(jsonb_build_object(
      'clientItemKey', soi.client_item_key,
      'orderItemId', soi.id,
      'productKey', soi.product_key,
      'productName', soi.product_name,
      'lineTotal', soi.line_total
    ) order by soi.created_at, soi.id), '[]'::jsonb)
    into v_response_items
    from commerce.service_order_items soi
    where soi.order_id = v_existing.id;

    return jsonb_build_object(
      'ok', true,
      'replayed', true,
      'orderId', v_existing.id,
      'orderNumber', v_existing.order_number,
      'items', v_response_items,
      'subtotal', v_existing.subtotal,
      'fulfilmentFee', v_existing.fulfilment_fee,
      'totalAmount', v_existing.total_amount,
      'status', v_existing.status,
      'paymentStatus', v_existing.payment_status,
      'deliveryFeeStatus', coalesce(v_existing.source_metadata->>'deliveryFeeStatus','not_required'),
      'uploadToken', v_upload_token,
      'uploadTokenExpiresAt', now() + interval '24 hours',
      'paymentToken', v_payment_token,
      'paymentTokenExpiresAt', now() + interval '7 days',
      'trackingToken', v_tracking->>'token',
      'trackingTokenExpiresAt', v_tracking->>'expiresAt'
    );
  end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    if jsonb_typeof(v_item) is distinct from 'object' then
      raise exception using errcode = '22023', message = 'Every cart item must be an object.';
    end if;

    v_product_key := trim(coalesce(v_item->>'productKey',''));
    v_client_item_key := trim(coalesce(v_item->>'clientItemKey',''));
    v_configuration := coalesce(v_item->'configuration','{}'::jsonb);

    if v_product_key = '' then
      raise exception using errcode = '22023', message = 'Every cart item needs a product key.';
    end if;
    if length(v_client_item_key) < 8 then
      raise exception using errcode = '22023', message = 'Every cart item needs a stable item key.';
    end if;
    if jsonb_typeof(v_configuration) is distinct from 'object' then
      raise exception using errcode = '22023', message = 'Every cart item configuration must be an object.';
    end if;
    if exists (
      select 1
      from jsonb_array_elements(v_priced_items) x
      where x->>'clientItemKey' = v_client_item_key
    ) then
      raise exception using errcode = '22023', message = 'Duplicate cart item key.';
    end if;

    v_price := commerce.qs_calculate_price(v_tenant_id, v_product_key, v_configuration);

    -- Checkout protection (mixed carts): reject the WHOLE cart order if
    -- ANY single line needs a quote, or is a PHOTOGRAPHY_SESSION at all
    -- (even fully priced - see create_quick_solution_order's matching
    -- comment) - a partially-priced or photography-containing cart must
    -- never check out with that line riding along for free, or with
    -- payment standing in for a booking confirmation it doesn't cover.
    if coalesce((v_price->'metrics'->>'quoteRequired')::boolean, false)
       or upper(coalesce(v_price->'snapshot'->>'pricingStrategy','')) = 'PHOTOGRAPHY_SESSION'
    then
      raise exception using errcode = '22023',
        message = format('%s needs a quote before it can be ordered. Please use the request-a-quote flow, or remove it from this order.', coalesce(v_price->>'productName', v_product_key));
    end if;

    v_product_id := (v_price->>'productId')::uuid;
    v_product_name := v_price->>'productName';
    v_subtotal := v_subtotal + (v_price->>'total')::numeric;

    v_priced_items := v_priced_items || jsonb_build_array(jsonb_build_object(
      'clientItemKey', v_client_item_key,
      'productId', v_product_id,
      'productKey', v_product_key,
      'productName', v_product_name,
      'configuration', v_configuration,
      'pricingSnapshot', v_price->'snapshot',
      'lineTotal', (v_price->>'total')::numeric
    ));
  end loop;

  v_fulfilment_type := lower(trim(coalesce(p_fulfilment_type,'cafe')));

  if v_fulfilment_type in ('cafe','quick_point') then
    if p_fulfilment_point_id is null then
      if v_fulfilment_type = 'quick_point' then
        raise exception using errcode = '22023', message = 'Choose a Quick Point.';
      end if;

      select * into v_point
      from commerce.fulfilment_points fp
      where fp.tenant_id = v_tenant_id
        and fp.kind = 'cafe'
        and fp.status = 'active'
        and fp.collection_enabled = true
      order by fp.sort_order, fp.created_at
      limit 1;
    else
      select * into v_point
      from commerce.fulfilment_points fp
      where fp.id = p_fulfilment_point_id
        and fp.tenant_id = v_tenant_id
        and fp.kind = v_fulfilment_type
        and fp.status = 'active'
        and fp.collection_enabled = true
      limit 1;
    end if;

    if v_point.id is null then
      raise exception using errcode = '22023', message = 'Selected collection point is not available.';
    end if;

    v_fulfilment_fee := coalesce(v_point.fee_amount,0);
    v_fulfilment_snapshot := jsonb_build_object(
      'id', v_point.id,
      'slug', v_point.slug,
      'name', v_point.name,
      'kind', v_point.kind,
      'address', v_point.address,
      'contactPhone', v_point.contact_phone,
      'easyLocateBusinessRef', v_point.easy_locate_business_ref,
      'latitude', v_point.latitude,
      'longitude', v_point.longitude,
      'services', v_point.services,
      'feeAmount', v_point.fee_amount
    );
  elsif v_fulfilment_type = 'delivery' then
    if p_delivery_address is null or jsonb_typeof(p_delivery_address) is distinct from 'object' then
      raise exception using errcode = '22023', message = 'Delivery address is required.';
    end if;
    v_fulfilment_fee := 0;
  else
    raise exception using errcode = '22023', message = 'Unsupported fulfilment type.';
  end if;

  v_subtotal := round(v_subtotal,2);
  v_total := round(v_subtotal + v_fulfilment_fee,2);
  v_order_number := commerce.qs_generate_order_number();
  v_upload_token := encode(extensions.gen_random_bytes(32), 'hex');
  v_payment_token := encode(extensions.gen_random_bytes(32), 'hex');

  insert into commerce.service_orders (
    tenant_id, order_number, status, customer_name, customer_email, customer_phone,
    fulfilment_type, fulfilment_point_id, delivery_address, subtotal, fulfilment_fee,
    total_amount, payment_status, idempotency_key, customer_notes, source_metadata,
    upload_token_hash, upload_token_expires_at,
    payment_token_hash, payment_token_expires_at
  ) values (
    v_tenant_id, v_order_number, 'submitted', trim(p_customer_name), v_email, v_phone,
    v_fulfilment_type,
    case when v_fulfilment_type in ('cafe','quick_point') then v_point.id else null end,
    case when v_fulfilment_type='delivery' then p_delivery_address else null end,
    v_subtotal, v_fulfilment_fee, v_total, 'unpaid', trim(p_idempotency_key),
    nullif(trim(coalesce(p_customer_notes,'')), ''),
    jsonb_build_object(
      'channel','storefront_cart',
      'itemCount', v_count,
      'deliveryFeeStatus', case when v_fulfilment_type='delivery' then 'pending_confirmation' else 'not_required' end,
      'fulfilmentPointSnapshot', v_fulfilment_snapshot
    ),
    encode(extensions.digest(v_upload_token, 'sha256'), 'hex'),
    now() + interval '24 hours',
    encode(extensions.digest(v_payment_token, 'sha256'), 'hex'),
    now() + interval '7 days'
  ) returning id into v_order_id;

  for v_item in select value from jsonb_array_elements(v_priced_items)
  loop
    insert into commerce.service_order_items (
      order_id, tenant_id, product_id, product_key, product_name, quantity,
      configuration, pricing_snapshot, line_total, client_item_key
    ) values (
      v_order_id,
      v_tenant_id,
      (v_item->>'productId')::uuid,
      v_item->>'productKey',
      v_item->>'productName',
      1,
      v_item->'configuration',
      v_item->'pricingSnapshot',
      (v_item->>'lineTotal')::numeric,
      v_item->>'clientItemKey'
    ) returning id into v_order_item_id;

    v_response_items := v_response_items || jsonb_build_array(jsonb_build_object(
      'clientItemKey', v_item->>'clientItemKey',
      'orderItemId', v_order_item_id,
      'productKey', v_item->>'productKey',
      'productName', v_item->>'productName',
      'lineTotal', (v_item->>'lineTotal')::numeric
    ));
  end loop;

  v_tracking := commerce.qs_issue_tracking_token(v_order_id);

  return jsonb_build_object(
    'ok', true,
    'replayed', false,
    'orderId', v_order_id,
    'orderNumber', v_order_number,
    'items', v_response_items,
    'subtotal', v_subtotal,
    'fulfilmentFee', v_fulfilment_fee,
    'totalAmount', v_total,
    'status', 'submitted',
    'paymentStatus', 'unpaid',
    'deliveryFeeStatus', case when v_fulfilment_type='delivery' then 'pending_confirmation' else 'not_required' end,
    'uploadToken', v_upload_token,
    'uploadTokenExpiresAt', now() + interval '24 hours',
    'paymentToken', v_payment_token,
    'paymentTokenExpiresAt', now() + interval '7 days',
    'trackingToken', v_tracking->>'token',
    'trackingTokenExpiresAt', v_tracking->>'expiresAt'
  );
end
$function$

;

CREATE OR REPLACE FUNCTION public.create_quick_solution_counter_order(p_idempotency_key text, p_product_key text, p_configuration jsonb, p_customer_name text DEFAULT NULL::text, p_customer_email text DEFAULT NULL::text, p_customer_phone text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  c_walk_in constant text := 'Walk-in';
  v_actor uuid;
  v_tenant_id uuid;
  v_key text;
  v_stored_key text;
  v_product_key text;
  v_name text;
  v_email text;
  v_phone text;
  v_existing commerce.service_orders;
  v_item commerce.service_order_items;
  v_price jsonb;
  v_strategy text;
  v_product_id uuid;
  v_product_name text;
  v_subtotal numeric;
  v_point_id uuid;
  v_order_id uuid;
  v_order_number text;
  v_created_at timestamptz;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception using errcode = '42501', message = 'Staff sign-in is required.';
  end if;

  select t.id
  into v_tenant_id
  from public.tenants t
  where t.slug = 'quick-solution'
    and t.status = 'active'
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode = '22023', message = 'Quick Solution tenant was not found.';
  end if;

  if not public.has_tenant_capability(v_tenant_id, 'cafe.counter.operate') then
    raise exception using errcode = '42501', message = 'You do not have access to the Quick Solution counter.';
  end if;

  if not exists (
    select 1
    from public.tenant_capabilities tc
    where tc.tenant_id = v_tenant_id
      and tc.capability_key = 'quick_solution'
      and tc.enabled = true
  ) then
    raise exception using errcode = '22023', message = 'Quick Solution counter is not active.';
  end if;

  -- input
  v_key := trim(coalesce(p_idempotency_key, ''));
  if length(v_key) < 8 then
    raise exception using errcode = '22023', message = 'Order idempotency key is required.';
  end if;
  if length(v_key) > 128 then
    raise exception using errcode = '22023', message = 'Order idempotency key is not valid.';
  end if;

  v_product_key := trim(coalesce(p_product_key, ''));
  v_name := nullif(trim(coalesce(p_customer_name, '')), '');
  v_email := nullif(lower(trim(coalesce(p_customer_email, ''))), '');
  v_phone := nullif(trim(coalesce(p_customer_phone, '')), '');

  if v_name is not null and (length(v_name) < 2 or length(v_name) > 160) then
    raise exception using errcode = '22023', message = 'Customer name is not valid.';
  end if;
  if v_email is not null and position('@' in v_email) < 2 then
    raise exception using errcode = '22023', message = 'Email address is not valid.';
  end if;
  if v_phone is not null and length(regexp_replace(v_phone, '[^0-9+]', '', 'g')) < 7 then
    raise exception using errcode = '22023', message = 'Phone number is not valid.';
  end if;
  v_name := coalesce(v_name, c_walk_in);

  -- idempotency: scoped to this actor, serialized per key, enforced by the unique constraint
  v_stored_key := 'counter:' || v_actor::text || ':' || v_key;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_tenant_id::text || '|' || v_stored_key, 0));

  select so.*
  into v_existing
  from commerce.service_orders so
  where so.tenant_id = v_tenant_id
    and so.idempotency_key = v_stored_key
  limit 1;

  if v_existing.id is not null then
    select i.*
    into v_item
    from commerce.service_order_items i
    where i.order_id = v_existing.id
    order by i.created_at, i.id
    limit 1;

    if v_existing.channel is distinct from 'counter'
       or v_existing.created_by is distinct from v_actor
       or v_item.id is null
       or v_item.product_key is distinct from v_product_key
       or v_item.configuration is distinct from p_configuration
       or v_existing.customer_name is distinct from v_name
       or v_existing.customer_email is distinct from v_email
       or v_existing.customer_phone is distinct from v_phone then
      raise exception using errcode = '23505', message = 'This idempotency key was already used for a different order request.';
    end if;

    return jsonb_build_object(
      'ok', true,
      'replayed', true,
      'orderId', v_existing.id,
      'orderNumber', v_existing.order_number,
      'status', v_existing.status,
      'paymentStatus', v_existing.payment_status,
      'channel', v_existing.channel,
      'createdAt', v_existing.created_at,
      'customerName', v_existing.customer_name,
      'customerEmail', v_existing.customer_email,
      'customerPhone', v_existing.customer_phone,
      'productKey', v_item.product_key,
      'productName', v_item.product_name,
      'configuration', v_item.configuration,
      'lineTotal', v_item.line_total,
      'subtotal', v_existing.subtotal,
      'fulfilmentFee', v_existing.fulfilment_fee,
      'totalAmount', v_existing.total_amount
    );
  end if;

  -- the product: it must exist, and be counter-sellable by the one shared rule
  if not exists (
    select 1
    from commerce.service_product_configs c
    where c.tenant_id = v_tenant_id
      and c.source_key = v_product_key
  ) then
    raise exception using errcode = '22023', message = 'Product was not found.';
  end if;

  if not commerce._qs_product_counter_sellable(v_tenant_id, v_product_key) then
    raise exception using errcode = '22023', message = 'Product is not available for the counter.';
  end if;

  -- the authoritative server price (validates the configuration too)
  v_price := commerce.qs_calculate_price(v_tenant_id, v_product_key, p_configuration);
  v_strategy := upper(coalesce(v_price -> 'snapshot' ->> 'pricingStrategy', ''));

  -- same protection as the storefront checkout: a quote-required item, or a photography
  -- session, is never a payable order. There is no counter path for request-style services yet.
  if coalesce((v_price -> 'metrics' ->> 'quoteRequired')::boolean, false)
     or v_strategy = 'PHOTOGRAPHY_SESSION' then
    raise exception using errcode = '22023',
      message = format('%s needs a quote before it can be ordered. Please use the request-a-quote flow.', coalesce(v_price ->> 'productName', v_product_key));
  end if;

  -- OPPS reads configuration.quantity as a quantity override: refuse it wherever the product
  -- does not itself define a quantity option.
  if p_configuration ? 'quantity' and v_strategy in ('PER_UNIT', 'PER_PAGE', 'PER_AREA') then
    raise exception using errcode = '22023', message = 'Quantity is not an option for this product.';
  end if;

  v_product_id := (v_price ->> 'productId')::uuid;
  v_product_name := v_price ->> 'productName';
  v_subtotal := (v_price ->> 'total')::numeric;

  select fp.id
  into v_point_id
  from commerce.fulfilment_points fp
  where fp.tenant_id = v_tenant_id
    and fp.kind = 'cafe'
    and fp.status = 'active'
    and fp.collection_enabled = true
  order by fp.sort_order, fp.created_at
  limit 1;

  v_order_number := commerce.qs_generate_order_number();

  insert into commerce.service_orders (
    tenant_id,
    order_number,
    status,
    customer_name,
    customer_email,
    customer_phone,
    fulfilment_type,
    fulfilment_point_id,
    subtotal,
    fulfilment_fee,
    total_amount,
    payment_status,
    idempotency_key,
    source_metadata,
    channel,
    created_by
  ) values (
    v_tenant_id,
    v_order_number,
    'submitted',
    v_name,
    v_email,
    v_phone,
    'cafe',
    v_point_id,
    v_subtotal,
    0,
    v_subtotal,
    'unpaid',
    v_stored_key,
    jsonb_build_object('channel', 'counter', 'deliveryFeeStatus', 'not_required'),
    'counter',
    v_actor
  )
  returning id, created_at into v_order_id, v_created_at;

  insert into commerce.service_order_items (
    order_id,
    tenant_id,
    product_id,
    product_key,
    product_name,
    quantity,
    configuration,
    pricing_snapshot,
    line_total
  ) values (
    v_order_id,
    v_tenant_id,
    v_product_id,
    v_product_key,
    v_product_name,
    1,
    p_configuration,
    v_price -> 'snapshot',
    v_subtotal
  );

  return jsonb_build_object(
    'ok', true,
    'replayed', false,
    'orderId', v_order_id,
    'orderNumber', v_order_number,
    'status', 'submitted',
    'paymentStatus', 'unpaid',
    'channel', 'counter',
    'createdAt', v_created_at,
    'customerName', v_name,
    'customerEmail', v_email,
    'customerPhone', v_phone,
    'productKey', v_product_key,
    'productName', v_product_name,
    'configuration', p_configuration,
    'lineTotal', v_subtotal,
    'subtotal', v_subtotal,
    'fulfilmentFee', 0,
    'totalAmount', v_subtotal
  );
end
$function$

;

CREATE OR REPLACE FUNCTION public.create_quick_solution_order(p_tenant_slug text, p_product_key text, p_configuration jsonb, p_customer_name text, p_customer_email text DEFAULT NULL::text, p_customer_phone text DEFAULT NULL::text, p_fulfilment_type text DEFAULT 'cafe'::text, p_fulfilment_point_id uuid DEFAULT NULL::uuid, p_delivery_address jsonb DEFAULT NULL::jsonb, p_customer_notes text DEFAULT NULL::text, p_idempotency_key text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_tenant_id uuid;
  v_order_id uuid;
  v_existing commerce.service_orders;
  v_order_number text;
  v_price jsonb;
  v_product_id uuid;
  v_product_name text;
  v_subtotal numeric;
  v_fulfilment_fee numeric := 0;
  v_total numeric;
  v_fulfilment_type text;
  v_point commerce.fulfilment_points;
  v_email text;
  v_phone text;
begin
  select t.id
  into v_tenant_id
  from public.tenants t
  where t.slug = lower(trim(p_tenant_slug))
    and t.status = 'active'
    and exists (
      select 1
      from public.tenant_capabilities tc
      where tc.tenant_id = t.id
        and tc.capability_key = 'quick_solution'
        and tc.enabled = true
    )
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode = '22023', message = 'Quick Solution storefront is not active.';
  end if;

  if length(trim(coalesce(p_idempotency_key,''))) < 8 then
    raise exception using errcode = '22023', message = 'Order idempotency key is required.';
  end if;

  if length(trim(coalesce(p_customer_name,''))) < 2 then
    raise exception using errcode = '22023', message = 'Customer name is required.';
  end if;

  v_email := nullif(lower(trim(coalesce(p_customer_email,''))), '');
  v_phone := nullif(trim(coalesce(p_customer_phone,'')), '');

  if v_email is null and v_phone is null then
    raise exception using errcode = '22023', message = 'Provide an email address or phone number.';
  end if;

  if v_email is not null and position('@' in v_email) < 2 then
    raise exception using errcode = '22023', message = 'Email address is not valid.';
  end if;

  if v_phone is not null and length(regexp_replace(v_phone, '[^0-9+]', '', 'g')) < 7 then
    raise exception using errcode = '22023', message = 'Phone number is not valid.';
  end if;

  select *
  into v_existing
  from commerce.service_orders so
  where so.tenant_id = v_tenant_id
    and so.idempotency_key = trim(p_idempotency_key)
  limit 1;

  if v_existing.id is not null then
    return jsonb_build_object(
      'ok', true,
      'replayed', true,
      'orderId', v_existing.id,
      'orderNumber', v_existing.order_number,
      'subtotal', v_existing.subtotal,
      'fulfilmentFee', v_existing.fulfilment_fee,
      'totalAmount', v_existing.total_amount,
      'status', v_existing.status
    );
  end if;

  v_price := commerce.qs_calculate_price(v_tenant_id, trim(p_product_key), p_configuration);

  -- Checkout protection: an item that needs a quote can never be paid
  -- for here - it must go through
  -- public.create_quick_solution_service_request instead, which never
  -- mints a payment token. PHOTOGRAPHY_SESSION is blocked from this
  -- path outright, even when fully priced (quoteRequired:false) -
  -- letting a priced session through PayFast here would let payment
  -- itself imply the appointment is confirmed, which is exactly what
  -- routing every photography booking through the service-request/
  -- manual-confirmation flow is meant to prevent.
  if coalesce((v_price->'metrics'->>'quoteRequired')::boolean, false)
     or upper(coalesce(v_price->'snapshot'->>'pricingStrategy','')) = 'PHOTOGRAPHY_SESSION'
  then
    raise exception using errcode = '22023',
      message = format('%s needs a quote before it can be ordered. Please use the request-a-quote flow.', coalesce(v_price->>'productName', trim(p_product_key)));
  end if;

  v_product_id := (v_price->>'productId')::uuid;
  v_product_name := v_price->>'productName';
  v_subtotal := (v_price->>'total')::numeric;

  v_fulfilment_type := lower(trim(coalesce(p_fulfilment_type,'cafe')));

  if v_fulfilment_type in ('cafe','quick_point') then
    if p_fulfilment_point_id is null then
      if v_fulfilment_type = 'quick_point' then
        raise exception using errcode = '22023', message = 'Choose a Quick Point.';
      end if;

      select *
      into v_point
      from commerce.fulfilment_points fp
      where fp.tenant_id = v_tenant_id
        and fp.kind = 'cafe'
        and fp.status = 'active'
        and fp.collection_enabled = true
      order by fp.sort_order, fp.created_at
      limit 1;
    else
      select *
      into v_point
      from commerce.fulfilment_points fp
      where fp.id = p_fulfilment_point_id
        and fp.tenant_id = v_tenant_id
        and fp.kind = v_fulfilment_type
        and fp.status = 'active'
        and fp.collection_enabled = true
      limit 1;
    end if;

    if v_point.id is null then
      raise exception using errcode = '22023', message = 'Selected collection point is not available.';
    end if;

    v_fulfilment_fee := coalesce(v_point.fee_amount,0);

  elsif v_fulfilment_type = 'delivery' then
    if p_delivery_address is null or jsonb_typeof(p_delivery_address) is distinct from 'object' then
      raise exception using errcode = '22023', message = 'Delivery address is required.';
    end if;
    v_fulfilment_fee := 0;
  else
    raise exception using errcode = '22023', message = 'Unsupported fulfilment type.';
  end if;

  v_total := round(v_subtotal + v_fulfilment_fee, 2);
  v_order_number := commerce.qs_generate_order_number();

  insert into commerce.service_orders (
    tenant_id,
    order_number,
    status,
    customer_name,
    customer_email,
    customer_phone,
    fulfilment_type,
    fulfilment_point_id,
    delivery_address,
    subtotal,
    fulfilment_fee,
    total_amount,
    payment_status,
    idempotency_key,
    customer_notes,
    source_metadata
  ) values (
    v_tenant_id,
    v_order_number,
    'submitted',
    trim(p_customer_name),
    v_email,
    v_phone,
    v_fulfilment_type,
    case when v_fulfilment_type in ('cafe','quick_point') then v_point.id else null end,
    case when v_fulfilment_type='delivery' then p_delivery_address else null end,
    v_subtotal,
    v_fulfilment_fee,
    v_total,
    'unpaid',
    trim(p_idempotency_key),
    nullif(trim(coalesce(p_customer_notes,'')), ''),
    jsonb_build_object(
      'channel','storefront',
      'deliveryFeeStatus', case when v_fulfilment_type='delivery' then 'pending_confirmation' else 'not_required' end
    )
  )
  returning id into v_order_id;

  insert into commerce.service_order_items (
    order_id,
    tenant_id,
    product_id,
    product_key,
    product_name,
    quantity,
    configuration,
    pricing_snapshot,
    line_total
  ) values (
    v_order_id,
    v_tenant_id,
    v_product_id,
    trim(p_product_key),
    v_product_name,
    1,
    p_configuration,
    v_price->'snapshot',
    v_subtotal
  );

  return jsonb_build_object(
    'ok', true,
    'replayed', false,
    'orderId', v_order_id,
    'orderNumber', v_order_number,
    'subtotal', v_subtotal,
    'fulfilmentFee', v_fulfilment_fee,
    'totalAmount', v_total,
    'status', 'submitted',
    'deliveryFeeStatus', case when v_fulfilment_type='delivery' then 'pending_confirmation' else 'not_required' end
  );
end
$function$

;

CREATE OR REPLACE FUNCTION public.create_quick_solution_service_request(p_tenant_slug text, p_product_key text, p_configuration jsonb, p_customer_name text, p_customer_email text DEFAULT NULL::text, p_customer_phone text DEFAULT NULL::text, p_service_location jsonb DEFAULT NULL::jsonb, p_customer_notes text DEFAULT NULL::text, p_idempotency_key text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_tenant_id uuid;
  v_order_id uuid;
  v_order_item_id uuid;
  v_existing commerce.service_orders;
  v_order_number text;
  v_price jsonb;
  v_product_id uuid;
  v_product_name text;
  v_email text;
  v_phone text;
  v_upload_token text;
  v_strategy text;
  v_subtotal numeric;
  v_quote_required boolean;
begin
  select t.id into v_tenant_id
  from public.tenants t
  where t.slug=lower(trim(p_tenant_slug))
    and t.status='active'
    and exists (
      select 1
      from public.tenant_capabilities tc
      where tc.tenant_id=t.id
        and tc.capability_key='quick_solution'
        and tc.enabled=true
    )
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode='22023', message='Quick Solution storefront is not active.';
  end if;

  if length(trim(coalesce(p_idempotency_key,''))) < 8 then
    raise exception using errcode='22023', message='Request idempotency key is required.';
  end if;

  if length(trim(coalesce(p_customer_name,''))) < 2 then
    raise exception using errcode='22023', message='Customer name is required.';
  end if;

  v_email := nullif(lower(trim(coalesce(p_customer_email,''))), '');
  v_phone := nullif(trim(coalesce(p_customer_phone,'')), '');

  if v_email is null and v_phone is null then
    raise exception using errcode='22023', message='Provide an email address or phone number.';
  end if;

  if v_email is not null and position('@' in v_email) < 2 then
    raise exception using errcode='22023', message='Email address is not valid.';
  end if;

  if v_phone is not null
     and length(regexp_replace(v_phone, '[^0-9+]', '', 'g')) < 7 then
    raise exception using errcode='22023', message='Phone number is not valid.';
  end if;

  select * into v_existing
  from commerce.service_orders so
  where so.tenant_id=v_tenant_id
    and so.idempotency_key=trim(p_idempotency_key)
  limit 1;

  if v_existing.id is not null then
    v_upload_token := encode(extensions.gen_random_bytes(32), 'hex');

    update commerce.service_orders
    set upload_token_hash=encode(extensions.digest(v_upload_token,'sha256'),'hex'),
        upload_token_expires_at=now()+interval '24 hours'
    where id=v_existing.id;

    select soi.id into v_order_item_id
    from commerce.service_order_items soi
    where soi.order_id=v_existing.id
    order by soi.created_at asc
    limit 1;

    return jsonb_build_object(
      'ok',true,
      'replayed',true,
      'orderId',v_existing.id,
      'orderItemId',v_order_item_id,
      'orderNumber',v_existing.order_number,
      'subtotal',v_existing.subtotal,
      'fulfilmentFee',v_existing.fulfilment_fee,
      'totalAmount',v_existing.total_amount,
      'status',v_existing.status,
      'paymentStatus',v_existing.payment_status,
      'quoteRequired', coalesce((v_existing.source_metadata->>'quoteRequired')::boolean, true),
      'uploadToken',v_upload_token,
      'uploadTokenExpiresAt',now()+interval '24 hours'
    );
  end if;

  v_price := commerce.qs_calculate_price(
    v_tenant_id,
    trim(p_product_key),
    p_configuration
  );

  v_strategy := upper(coalesce(v_price->'snapshot'->>'pricingStrategy',''));
  if v_strategy not in ('ENQUIRY','PHOTOGRAPHY_SESSION') then
    raise exception using errcode='22023', message='This product is not configured as a service enquiry.';
  end if;

  v_product_id := (v_price->>'productId')::uuid;
  v_product_name := v_price->>'productName';
  v_order_number := commerce.qs_generate_order_number();
  v_upload_token := encode(extensions.gen_random_bytes(32), 'hex');

  -- ENQUIRY always reports quoteRequired:true/total:0 (unchanged).
  -- PHOTOGRAPHY_SESSION reports a real total only when every chosen
  -- component (session, extra edits, deliverables) is priced; a real
  -- price here does NOT mean payment happens now — this RPC never
  -- mints a PayFast token for any strategy, so recording a real amount
  -- only lets staff see the quoted figure while following up to
  -- confirm and arrange payment separately.
  v_quote_required := coalesce((v_price->'metrics'->>'quoteRequired')::boolean, true);
  v_subtotal := case when v_quote_required then 0 else coalesce((v_price->>'total')::numeric, 0) end;

  insert into commerce.service_orders (
    tenant_id,
    order_number,
    status,
    customer_name,
    customer_email,
    customer_phone,
    fulfilment_type,
    fulfilment_point_id,
    delivery_address,
    subtotal,
    fulfilment_fee,
    total_amount,
    payment_status,
    idempotency_key,
    customer_notes,
    source_metadata,
    upload_token_hash,
    upload_token_expires_at
  ) values (
    v_tenant_id,
    v_order_number,
    'submitted',
    trim(p_customer_name),
    v_email,
    v_phone,
    'service',
    null,
    case
      when p_service_location is not null
       and jsonb_typeof(p_service_location)='object'
      then p_service_location
      else null
    end,
    v_subtotal,
    0,
    v_subtotal,
    'unpaid',
    trim(p_idempotency_key),
    nullif(trim(coalesce(p_customer_notes,'')), ''),
    jsonb_build_object(
      'channel','storefront',
      'requestType', case when v_strategy = 'PHOTOGRAPHY_SESSION' then 'photography_session' else 'media_service' end,
      'quoteRequired', v_quote_required,
      'quoteStatus','pending_review',
      'serviceLocation',p_service_location
    ),
    encode(extensions.digest(v_upload_token,'sha256'),'hex'),
    now()+interval '24 hours'
  )
  returning id into v_order_id;

  insert into commerce.service_order_items (
    order_id,
    tenant_id,
    product_id,
    product_key,
    product_name,
    quantity,
    configuration,
    pricing_snapshot,
    line_total
  ) values (
    v_order_id,
    v_tenant_id,
    v_product_id,
    trim(p_product_key),
    v_product_name,
    1,
    p_configuration,
    v_price->'snapshot',
    v_subtotal
  )
  returning id into v_order_item_id;

  return jsonb_build_object(
    'ok',true,
    'replayed',false,
    'orderId',v_order_id,
    'orderItemId',v_order_item_id,
    'orderNumber',v_order_number,
    'subtotal',v_subtotal,
    'fulfilmentFee',0,
    'totalAmount',v_subtotal,
    'status','submitted',
    'paymentStatus','unpaid',
    'quoteRequired', v_quote_required,
    'uploadToken',v_upload_token,
    'uploadTokenExpiresAt',now()+interval '24 hours'
  );
end
$function$

;

CREATE OR REPLACE FUNCTION public.get_quick_solution_catalog(p_tenant_slug text DEFAULT 'quick-solution'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_tenant_id uuid;
begin
  select t.id
  into v_tenant_id
  from public.tenants t
  where t.slug = lower(trim(p_tenant_slug))
    and t.status = 'active'
    and exists (
      select 1
      from public.tenant_capabilities tc
      where tc.tenant_id = t.id
        and tc.capability_key = 'quick_solution'
        and tc.enabled = true
    )
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode = '22023', message = 'Quick Solution storefront is not active.';
  end if;

  return jsonb_build_object(
    'tenant', (
      select jsonb_build_object('id',t.id,'slug',t.slug,'name',t.name)
      from public.tenants t
      where t.id = v_tenant_id
    ),
    'products', coalesce((
      select jsonb_agg(
        c.customer_definition ||
        jsonb_build_object(
          'id', c.source_key,
          'commerceProductId', p.id,
          'name', p.name,
          'description', coalesce(p.description, c.customer_definition->>'description'),
          'pricingVersion', c.pricing_version
        )
        order by c.sort_order, p.name
      )
      from commerce.service_product_configs c
      join commerce.products p
        on p.id = c.product_id
       and p.tenant_id = c.tenant_id
      where c.tenant_id = v_tenant_id
        and c.status = 'published'
        and p.status = 'published'
        and p.availability = 'available'
        and case coalesce(jsonb_typeof(c.customer_definition -> 'channels' -> 'storefront'), 'null')
              when 'null' then true
              when 'boolean' then (c.customer_definition -> 'channels' ->> 'storefront')::boolean
              else false
            end
    ), '[]'::jsonb),
    'fulfilmentPoints', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', fp.id,
          'slug', fp.slug,
          'name', fp.name,
          'kind', fp.kind,
          'address', fp.address,
          'easyLocateBusinessRef', fp.easy_locate_business_ref,
          'easyLocateLink',
            case
              when el.id is null or el.status <> 'verified' then null
              else jsonb_build_object(
                'externalId', el.external_id,
                'externalSlug', el.external_slug,
                'canonicalUrl', el.canonical_url,
                'status', el.status,
                'verifiedAt', el.verified_at,
                'business', jsonb_strip_nulls(jsonb_build_object(
                  'id', el.public_snapshot->>'id',
                  'slug', el.public_snapshot->>'slug',
                  'name', el.public_snapshot->>'name',
                  'categories', coalesce(el.public_snapshot->'categories','[]'::jsonb),
                  'services', coalesce(el.public_snapshot->'services','[]'::jsonb),
                  'locationArea', el.public_snapshot->>'locationArea',
                  'locationExtension', el.public_snapshot->>'locationExtension',
                  'verificationLevel', el.public_snapshot->>'verificationLevel',
                  'claimed', coalesce((el.public_snapshot->>'claimed')::boolean,false)
                ))
              )
            end,
          'latitude', fp.latitude,
          'longitude', fp.longitude,
          'collectionEnabled', fp.collection_enabled,
          'dropoffEnabled', fp.dropoff_enabled,
          'services', fp.services,
          'feeAmount', fp.fee_amount,
          'openingHours', fp.opening_hours
        )
        order by
          case fp.kind when 'cafe' then 0 else 1 end,
          fp.sort_order,
          fp.name
      )
      from commerce.fulfilment_points fp
      left join commerce.fulfilment_point_external_links el
        on el.fulfilment_point_id=fp.id
       and el.tenant_id=fp.tenant_id
       and el.provider='easy_locate'
      where fp.tenant_id = v_tenant_id
        and fp.status = 'active'
        and fp.collection_enabled = true
    ), '[]'::jsonb)
  );
end
$function$

;

CREATE OR REPLACE FUNCTION public.get_quick_solution_counter_cashup(p_business_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_tenant_id uuid;
  v_today date;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Staff sign-in is required.';
  end if;

  select t.id
  into v_tenant_id
  from public.tenants t
  where t.slug = 'quick-solution'
    and t.status = 'active'
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode = '22023', message = 'Quick Solution tenant was not found.';
  end if;

  if not public.has_tenant_capability(v_tenant_id, 'cafe.counter.operate') then
    raise exception using errcode = '42501', message = 'You do not have access to the Quick Solution counter.';
  end if;

  if not exists (
    select 1
    from public.tenant_capabilities tc
    where tc.tenant_id = v_tenant_id
      and tc.capability_key = 'quick_solution'
      and tc.enabled = true
  ) then
    raise exception using errcode = '22023', message = 'Quick Solution counter is not active.';
  end if;

  -- the date, strictly
  if p_business_date is null then
    raise exception using errcode = '22023', message = 'Business date is required.';
  end if;
  if p_business_date in (date 'infinity', date '-infinity') or p_business_date < date '2000-01-01' then
    raise exception using errcode = '22023', message = 'Business date is not valid.';
  end if;
  select d.business_date into v_today from commerce._qs_counter_business_day(now()) d;
  if p_business_date > v_today then
    raise exception using errcode = '22023', message = 'Cash-up date cannot be in the future.';
  end if;

  return commerce._qs_counter_cashup(v_tenant_id, p_business_date);
end
$function$

;

CREATE OR REPLACE FUNCTION public.get_quick_solution_counter_cashup_today()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_tenant_id uuid;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Staff sign-in is required.';
  end if;

  select t.id
  into v_tenant_id
  from public.tenants t
  where t.slug = 'quick-solution'
    and t.status = 'active'
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode = '22023', message = 'Quick Solution tenant was not found.';
  end if;

  if not public.has_tenant_capability(v_tenant_id, 'cafe.counter.operate') then
    raise exception using errcode = '42501', message = 'You do not have access to the Quick Solution counter.';
  end if;

  if not exists (
    select 1
    from public.tenant_capabilities tc
    where tc.tenant_id = v_tenant_id
      and tc.capability_key = 'quick_solution'
      and tc.enabled = true
  ) then
    raise exception using errcode = '22023', message = 'Quick Solution counter is not active.';
  end if;

  return commerce._qs_counter_cashup(v_tenant_id, (select d.business_date from commerce._qs_counter_business_day(now()) d));
end
$function$

;

CREATE OR REPLACE FUNCTION public.get_quick_solution_counter_catalog()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_tenant_id uuid;
  v_tenant jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Staff sign-in is required.';
  end if;

  select t.id, jsonb_build_object('slug', t.slug, 'name', t.name)
  into v_tenant_id, v_tenant
  from public.tenants t
  where t.slug = 'quick-solution'
    and t.status = 'active'
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode = '22023', message = 'Quick Solution tenant was not found.';
  end if;

  if not public.has_tenant_capability(v_tenant_id, 'cafe.counter.operate') then
    raise exception using errcode = '42501', message = 'You do not have access to the Quick Solution counter.';
  end if;

  if not exists (
    select 1
    from public.tenant_capabilities tc
    where tc.tenant_id = v_tenant_id
      and tc.capability_key = 'quick_solution'
      and tc.enabled = true
  ) then
    raise exception using errcode = '22023', message = 'Quick Solution counter is not active.';
  end if;

  return jsonb_build_object(
    'tenant', v_tenant,
    'products', coalesce((
      select jsonb_agg(
        (c.customer_definition - 'pricingDefinition' - 'pricing_definition' - 'commerceProductId') ||
        jsonb_build_object(
          'id', c.source_key,
          'name', p.name,
          'description', coalesce(p.description, c.customer_definition ->> 'description'),
          'pricingVersion', c.pricing_version
        )
        order by c.sort_order, p.name
      )
      from commerce.service_product_configs c
      join commerce.products p
        on p.id = c.product_id
       and p.tenant_id = c.tenant_id
      where c.tenant_id = v_tenant_id
        and commerce._qs_product_counter_sellable(c.tenant_id, c.source_key)
    ), '[]'::jsonb)
  );
end
$function$

;

CREATE OR REPLACE FUNCTION public.get_quick_solution_counter_order(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_tenant_id uuid;
  v_order commerce.service_orders;
  v_paid numeric;
  v_outstanding numeric;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Staff sign-in is required.';
  end if;

  select t.id
  into v_tenant_id
  from public.tenants t
  where t.slug = 'quick-solution'
    and t.status = 'active'
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode = '22023', message = 'Quick Solution tenant was not found.';
  end if;

  if not public.has_tenant_capability(v_tenant_id, 'cafe.counter.operate') then
    raise exception using errcode = '42501', message = 'You do not have access to the Quick Solution counter.';
  end if;

  if not exists (
    select 1
    from public.tenant_capabilities tc
    where tc.tenant_id = v_tenant_id
      and tc.capability_key = 'quick_solution'
      and tc.enabled = true
  ) then
    raise exception using errcode = '22023', message = 'Quick Solution counter is not active.';
  end if;

  select so.*
  into v_order
  from commerce.service_orders so
  where so.id = p_order_id
    and so.tenant_id = v_tenant_id
    and so.channel = 'counter';

  if v_order.id is null then
    raise exception using errcode = '22023', message = 'Counter order was not found.';
  end if;

  v_paid := commerce._qs_order_amount_paid(v_order.id);
  v_outstanding := greatest(round(v_order.total_amount - v_paid, 2), 0);

  return jsonb_build_object(
    'orderId', v_order.id,
    'orderNumber', v_order.order_number,
    'createdAt', v_order.created_at,
    'status', v_order.status,
    'paymentStatus', v_order.payment_status,
    'customerName', v_order.customer_name,
    'customerEmail', v_order.customer_email,
    'customerPhone', v_order.customer_phone,
    'subtotal', v_order.subtotal,
    'fulfilmentFee', v_order.fulfilment_fee,
    'totalAmount', v_order.total_amount,
    'amountPaid', v_paid,
    'outstanding', v_outstanding,
    'paymentAllowed', commerce._qs_counter_payment_block(v_order) is null,
    'items', coalesce((
      select jsonb_agg(
               jsonb_build_object(
                 'productKey', i.product_key,
                 'productName', i.product_name,
                 'quantity', i.quantity,
                 'configuration', i.configuration,
                 'lineTotal', i.line_total
               )
               order by i.created_at, i.id
             )
      from commerce.service_order_items i
      where i.order_id = v_order.id
        and i.tenant_id = v_order.tenant_id
    ), '[]'::jsonb),
    'payments', coalesce((
      select jsonb_agg(
               jsonb_build_object(
                 'paymentId', p.id,
                 'method', p.provider,
                 'amount', p.amount,
                 'paidAt', p.completed_at
               )
               order by p.completed_at, p.id
             )
      from commerce.service_order_payments p
      where p.service_order_id = v_order.id
        and p.tenant_id = v_order.tenant_id
        and p.status = 'completed'
    ), '[]'::jsonb)
  );
end
$function$

;

CREATE OR REPLACE FUNCTION public.get_quick_solution_counter_order_cancel_check(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_tenant_id uuid;
  v_order commerce.service_orders;
  v_permitted boolean;
  v_block text;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Staff sign-in is required.';
  end if;

  select t.id
  into v_tenant_id
  from public.tenants t
  where t.slug = 'quick-solution'
    and t.status = 'active'
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode = '22023', message = 'Quick Solution tenant was not found.';
  end if;

  if not public.has_tenant_capability(v_tenant_id, 'cafe.counter.operate') then
    raise exception using errcode = '42501', message = 'You do not have access to the Quick Solution counter.';
  end if;

  if not exists (
    select 1
    from public.tenant_capabilities tc
    where tc.tenant_id = v_tenant_id
      and tc.capability_key = 'quick_solution'
      and tc.enabled = true
  ) then
    raise exception using errcode = '22023', message = 'Quick Solution counter is not active.';
  end if;

  select so.*
  into v_order
  from commerce.service_orders so
  where so.id = p_order_id
    and so.tenant_id = v_tenant_id
    and so.channel = 'counter';

  if v_order.id is null then
    raise exception using errcode = '22023', message = 'Counter order was not found.';
  end if;

  v_permitted := public.has_tenant_capability(v_tenant_id, 'cafe.operations.manage');
  v_block := commerce._qs_counter_cancel_block(v_order);

  return jsonb_build_object(
    'orderId', v_order.id,
    'permitted', v_permitted,
    'cancellable', v_block is null,
    'block', v_block
  );
end
$function$

;

CREATE OR REPLACE FUNCTION public.list_quick_solution_cancelled_counter_orders()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_tenant_id uuid;
  v_result record;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Staff sign-in is required.';
  end if;

  select t.id
  into v_tenant_id
  from public.tenants t
  where t.slug = 'quick-solution'
    and t.status = 'active'
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode = '22023', message = 'Quick Solution tenant was not found.';
  end if;

  if not public.has_tenant_capability(v_tenant_id, 'cafe.operations.manage') then
    raise exception using errcode = '42501', message = 'Only a Quick Solution admin or owner can view cancelled counter orders.';
  end if;

  if not exists (
    select 1
    from public.tenant_capabilities tc
    where tc.tenant_id = v_tenant_id
      and tc.capability_key = 'quick_solution'
      and tc.enabled = true
  ) then
    raise exception using errcode = '22023', message = 'Quick Solution counter is not active.';
  end if;

  with cancelled as (
    select
      so.id,
      so.order_number,
      so.created_at,
      so.customer_name,
      so.customer_email,
      so.customer_phone,
      c.cancelled_at,
      c.reason,
      c.prior_status,
      c.prior_payment_status,
      c.order_total,
      c.outstanding_at_cancel,
      (select u.full_name from public.users u where u.auth_user_id = c.cancelled_by limit 1) as cancelled_by_name
    from commerce.service_order_cancellations c
    join commerce.service_orders so
      on so.id = c.service_order_id
     and so.tenant_id = c.tenant_id
    where c.tenant_id = v_tenant_id
      and so.channel = 'counter'
  ),
  recent as (
    select * from cancelled order by cancelled_at desc, id desc limit 100
  )
  select
    (select count(*) from cancelled) as n,
    count(*) as shown,
    coalesce(jsonb_agg(
      jsonb_build_object(
        'orderId', r.id,
        'orderNumber', r.order_number,
        'createdAt', r.created_at,
        'cancelledAt', r.cancelled_at,
        'reason', r.reason,
        'cancelledBy', r.cancelled_by_name,
        'priorStatus', r.prior_status,
        'priorPaymentStatus', r.prior_payment_status,
        'totalAmount', r.order_total,
        'outstandingAtCancel', r.outstanding_at_cancel,
        'customerName', r.customer_name,
        'customerEmail', r.customer_email,
        'customerPhone', r.customer_phone,
        'items', coalesce((
          select jsonb_agg(
                   jsonb_build_object(
                     'productKey', i.product_key,
                     'productName', i.product_name,
                     'quantity', i.quantity,
                     'configuration', i.configuration,
                     'lineTotal', i.line_total
                   )
                   order by i.created_at, i.id
                 )
          from commerce.service_order_items i
          where i.order_id = r.id
            and i.tenant_id = v_tenant_id
        ), '[]'::jsonb)
      )
      order by r.cancelled_at desc, r.id desc
    ), '[]'::jsonb) as orders
  into v_result
  from recent r;

  return jsonb_build_object(
    'count', v_result.n,
    'shown', v_result.shown,
    'limit', 100,
    'orders', v_result.orders
  );
end
$function$

;

CREATE OR REPLACE FUNCTION public.list_quick_solution_counter_orders_today()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_tenant_id uuid;
  v_day record;
  v_orders jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Staff sign-in is required.';
  end if;

  select t.id
  into v_tenant_id
  from public.tenants t
  where t.slug = 'quick-solution'
    and t.status = 'active'
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode = '22023', message = 'Quick Solution tenant was not found.';
  end if;

  if not public.has_tenant_capability(v_tenant_id, 'cafe.counter.operate') then
    raise exception using errcode = '42501', message = 'You do not have access to the Quick Solution counter.';
  end if;

  if not exists (
    select 1
    from public.tenant_capabilities tc
    where tc.tenant_id = v_tenant_id
      and tc.capability_key = 'quick_solution'
      and tc.enabled = true
  ) then
    raise exception using errcode = '22023', message = 'Quick Solution counter is not active.';
  end if;

  select * into v_day from commerce._qs_counter_business_day(now());

  select coalesce(jsonb_agg(o.summary order by o.created_at desc, o.id desc), '[]'::jsonb)
  into v_orders
  from (
    select
      so.id,
      so.created_at,
      jsonb_build_object(
        'orderId', so.id,
        'orderNumber', so.order_number,
        'createdAt', so.created_at,
        'status', so.status,
        'paymentStatus', so.payment_status,
        'customerName', so.customer_name,
        'customerEmail', so.customer_email,
        'customerPhone', so.customer_phone,
        'totalAmount', so.total_amount,
        'items', coalesce((
          select jsonb_agg(
                   jsonb_build_object(
                     'productKey', i.product_key,
                     'productName', i.product_name,
                     'quantity', i.quantity,
                     'configuration', i.configuration,
                     'lineTotal', i.line_total
                   )
                   order by i.created_at, i.id
                 )
          from commerce.service_order_items i
          where i.order_id = so.id
            and i.tenant_id = so.tenant_id
        ), '[]'::jsonb)
      ) as summary
    from commerce.service_orders so
    where so.tenant_id = v_tenant_id
      and so.channel = 'counter'
      and so.created_at >= v_day.day_start
      and so.created_at < v_day.day_end
  ) o;

  return jsonb_build_object(
    'businessDate', v_day.business_date,
    'timezone', 'Africa/Johannesburg',
    'orders', v_orders
  );
end
$function$

;

CREATE OR REPLACE FUNCTION public.list_quick_solution_unpaid_counter_orders()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_tenant_id uuid;
  v_today date;
  v_result record;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Staff sign-in is required.';
  end if;

  select t.id
  into v_tenant_id
  from public.tenants t
  where t.slug = 'quick-solution'
    and t.status = 'active'
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode = '22023', message = 'Quick Solution tenant was not found.';
  end if;

  if not public.has_tenant_capability(v_tenant_id, 'cafe.counter.operate') then
    raise exception using errcode = '42501', message = 'You do not have access to the Quick Solution counter.';
  end if;

  if not exists (
    select 1
    from public.tenant_capabilities tc
    where tc.tenant_id = v_tenant_id
      and tc.capability_key = 'quick_solution'
      and tc.enabled = true
  ) then
    raise exception using errcode = '22023', message = 'Quick Solution counter is not active.';
  end if;

  select d.business_date into v_today from commerce._qs_counter_business_day(now()) d;

  with owing as (
    select
      so.id,
      so.order_number,
      so.created_at,
      so.status,
      so.payment_status,
      so.customer_name,
      so.customer_email,
      so.customer_phone,
      so.total_amount,
      paid.amount as amount_paid,
      greatest(round(so.total_amount - paid.amount, 2), 0) as outstanding,
      od.business_date as order_date
    from commerce.service_orders so
    cross join lateral (select commerce._qs_order_amount_paid(so.id) as amount) paid
    cross join lateral commerce._qs_counter_business_day(so.created_at) od
    where so.tenant_id = v_tenant_id
      and so.channel = 'counter'
      and so.status not in ('draft', 'cancelled')
      and so.payment_status in ('unpaid', 'pending', 'failed')
  )
  select
    count(*) as n,
    coalesce(sum(o.outstanding), 0) as outstanding_total,
    coalesce(jsonb_agg(
      jsonb_build_object(
        'orderId', o.id,
        'orderNumber', o.order_number,
        'createdAt', o.created_at,
        'orderDate', o.order_date,
        'ageDays', v_today - o.order_date,
        'status', o.status,
        'paymentStatus', o.payment_status,
        'customerName', o.customer_name,
        'customerEmail', o.customer_email,
        'customerPhone', o.customer_phone,
        'totalAmount', o.total_amount,
        'amountPaid', o.amount_paid,
        'outstanding', o.outstanding,
        'items', coalesce((
          select jsonb_agg(
                   jsonb_build_object(
                     'productKey', i.product_key,
                     'productName', i.product_name,
                     'quantity', i.quantity,
                     'configuration', i.configuration,
                     'lineTotal', i.line_total
                   )
                   order by i.created_at, i.id
                 )
          from commerce.service_order_items i
          where i.order_id = o.id
            and i.tenant_id = v_tenant_id
        ), '[]'::jsonb)
      )
      order by o.created_at, o.id
    ), '[]'::jsonb) as orders
  into v_result
  from owing o
  where o.outstanding > 0;

  return jsonb_build_object(
    'businessDate', v_today,
    'timezone', 'Africa/Johannesburg',
    'count', v_result.n,
    'outstandingTotal', v_result.outstanding_total,
    'orders', v_result.orders
  );
end
$function$

;

CREATE OR REPLACE FUNCTION public.record_quick_solution_counter_payment(p_order_id uuid, p_method text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_actor uuid;
  v_tenant_id uuid;
  v_key text;
  v_stored_key text;
  v_order commerce.service_orders;
  v_existing commerce.service_order_payments;
  v_block text;
  v_amount numeric;
  v_paid numeric;
  v_payment_id uuid;
  v_paid_at timestamptz;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception using errcode = '42501', message = 'Staff sign-in is required.';
  end if;

  select t.id
  into v_tenant_id
  from public.tenants t
  where t.slug = 'quick-solution'
    and t.status = 'active'
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode = '22023', message = 'Quick Solution tenant was not found.';
  end if;

  if not public.has_tenant_capability(v_tenant_id, 'cafe.counter.operate') then
    raise exception using errcode = '42501', message = 'You do not have access to the Quick Solution counter.';
  end if;

  if not exists (
    select 1
    from public.tenant_capabilities tc
    where tc.tenant_id = v_tenant_id
      and tc.capability_key = 'quick_solution'
      and tc.enabled = true
  ) then
    raise exception using errcode = '22023', message = 'Quick Solution counter is not active.';
  end if;

  -- input: exactly the two supported methods, no mapping, no case folding
  if p_method is null or p_method not in ('cash', 'card') then
    raise exception using errcode = '22023', message = 'Payment method is not supported.';
  end if;
  v_key := trim(coalesce(p_idempotency_key, ''));
  if length(v_key) < 8 then
    raise exception using errcode = '22023', message = 'Payment idempotency key is required.';
  end if;
  if length(v_key) > 128 then
    raise exception using errcode = '22023', message = 'Payment idempotency key is not valid.';
  end if;
  if p_order_id is null then
    raise exception using errcode = '22023', message = 'Counter order was not found.';
  end if;

  -- serialize on the key, then on the order (always in this order, so two callers cannot deadlock)
  v_stored_key := 'counter-payment:' || v_actor::text || ':' || v_key;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_tenant_id::text || '|' || v_stored_key, 0));

  select so.*
  into v_order
  from commerce.service_orders so
  where so.id = p_order_id
    and so.tenant_id = v_tenant_id
    and so.channel = 'counter'
  for update;

  -- a retry of a payment this actor already recorded returns the original, whatever the order looks like now
  select p.*
  into v_existing
  from commerce.service_order_payments p
  where p.tenant_id = v_tenant_id
    and p.idempotency_key = v_stored_key;

  if v_existing.id is not null then
    if v_existing.service_order_id is distinct from p_order_id
       or v_existing.provider is distinct from p_method
       or v_existing.recorded_by is distinct from v_actor then
      raise exception using errcode = '23505', message = 'This payment key was already used for a different payment request.';
    end if;
    return jsonb_build_object(
      'ok', true,
      'replayed', true,
      'alreadyPaid', false,
      'orderId', v_existing.service_order_id,
      'orderNumber', v_order.order_number,
      'paymentId', v_existing.id,
      'method', v_existing.provider,
      'amount', v_existing.amount,
      'paidAt', v_existing.completed_at,
      'paymentStatus', v_order.payment_status,
      'totalAmount', v_order.total_amount,
      'amountPaid', commerce._qs_order_amount_paid(v_order.id),
      'outstanding', greatest(round(v_order.total_amount - commerce._qs_order_amount_paid(v_order.id), 2), 0)
    );
  end if;

  if v_order.id is null then
    raise exception using errcode = '22023', message = 'Counter order was not found.';
  end if;

  v_block := commerce._qs_counter_payment_block(v_order);
  if v_block = 'already_paid' then
    return jsonb_build_object(
      'ok', false,
      'reason', 'already_paid',
      'orderId', v_order.id,
      'orderNumber', v_order.order_number,
      'paymentStatus', v_order.payment_status
    );
  elsif v_block = 'sent_to_production' then
    raise exception using errcode = '22023', message = 'This order has already been sent to production and cannot take a counter payment.';
  elsif v_block = 'nothing_outstanding' then
    raise exception using errcode = '22023', message = 'This order has nothing outstanding.';
  elsif v_block is not null then
    raise exception using errcode = '22023', message = 'This order cannot take a payment.';
  end if;

  -- the server decides the amount: everything still outstanding
  v_amount := round(v_order.total_amount - commerce._qs_order_amount_paid(v_order.id), 2);
  v_paid_at := clock_timestamp();

  insert into commerce.service_order_payments (
    tenant_id, service_order_id, provider, status, amount, initiated_at, completed_at, recorded_by, idempotency_key
  )
  values (
    v_tenant_id, v_order.id, p_method, 'completed', v_amount, v_paid_at, v_paid_at, v_actor, v_stored_key
  )
  returning id into v_payment_id;

  v_paid := commerce._qs_order_amount_paid(v_order.id);
  if round(v_order.total_amount - v_paid, 2) <> 0 then
    raise exception using errcode = '22023', message = 'The recorded amount does not settle the order.';
  end if;

  update commerce.service_orders
  set payment_status = 'paid',
      source_metadata = coalesce(source_metadata, '{}'::jsonb) ||
        jsonb_build_object('payment', jsonb_build_object('provider', p_method, 'status', 'paid', 'paidAt', v_paid_at)),
      updated_at = now()
  where id = v_order.id;

  return jsonb_build_object(
    'ok', true,
    'replayed', false,
    'alreadyPaid', false,
    'orderId', v_order.id,
    'orderNumber', v_order.order_number,
    'paymentId', v_payment_id,
    'method', p_method,
    'amount', v_amount,
    'paidAt', v_paid_at,
    'paymentStatus', 'paid',
    'totalAmount', v_order.total_amount,
    'amountPaid', v_paid,
    'outstanding', 0
  );
end
$function$

;


-- ── get_quick_solution_staff_catalog refresh, verbatim from OPPS-committed source
--    (opps-xos-2-7c-test-order-hygiene: supabase/migrations/20260915130000_qs10_staff_new_order_rpc.sql) ──
CREATE OR REPLACE FUNCTION "public"."get_quick_solution_staff_catalog"("p_tenant_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_slug text;
begin
  if auth.uid() is null then
    raise exception using
      errcode = '42501',
      message = 'Staff sign-in is required.';
  end if;

  select t.slug
  into v_slug
  from public.tenants t
  where t.id = p_tenant_id
    and t.status = 'active'
  limit 1;

  if v_slug is distinct from 'quick-solution' then
    raise exception using
      errcode = '22023',
      message = 'Quick Solution workspace was not found.';
  end if;

  if not public.has_tenant_permission(
    p_tenant_id,
    'orders.write'
  ) then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to create Quick Solution orders.';
  end if;

  return jsonb_build_object(
    'tenantId', p_tenant_id,
    'products', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', c.source_key,
          'commerceProductId', p.id,
          'name', p.name,
          'description', coalesce(
            p.description,
            c.customer_definition->>'description'
          ),
          'pricingVersion', c.pricing_version,
          'customerDefinition', c.customer_definition,
          'operationsDefinition', c.operations_definition
        )
        order by c.sort_order, p.name
      )
      from commerce.service_product_configs c
      join commerce.products p
        on p.id = c.product_id
       and p.tenant_id = c.tenant_id
      where c.tenant_id = p_tenant_id
        and c.status = 'published'
        and p.status = 'published'
        and p.availability = 'available'
    ), '[]'::jsonb)
  );
end
$$;

create or replace function commerce.qs_count_page_spec(p_spec text)
 returns integer
 language plpgsql
 immutable
 set search_path to ''
as $function$
declare
  v_part text;
  v_match text[];
  v_from integer;
  v_to integer;
  v_count integer := 0;
begin
  if nullif(btrim(p_spec), '') is null then
    raise exception using errcode = '22023', message = 'Choose the pages to print.';
  end if;

  for v_part in
    select btrim(value)
    from regexp_split_to_table(p_spec, ',') as value
  loop
    if v_part ~ '^[0-9]+$' then
      v_from := v_part::integer;
      if v_from < 1 or v_from > 1000 then
        raise exception using errcode = '22023', message = 'Page numbers must be between 1 and 1000.';
      end if;
      v_count := v_count + 1;
    elsif v_part ~ '^[0-9]+[[:space:]]*-[[:space:]]*[0-9]+$' then
      v_match := regexp_match(v_part, '^([0-9]+)[[:space:]]*-[[:space:]]*([0-9]+)$');
      v_from := v_match[1]::integer;
      v_to := v_match[2]::integer;
      if v_from < 1 or v_to < v_from or v_to > 1000 then
        raise exception using errcode = '22023', message = 'Page ranges must run forward between 1 and 1000.';
      end if;
      v_count := v_count + (v_to - v_from + 1);
    else
      raise exception using errcode = '22023', message = 'Use page numbers separated by commas, with ranges like 1-4.';
    end if;

    if v_count > 1000 then
      raise exception using errcode = '22023', message = 'Document quantity is outside the supported range.';
    end if;
  end loop;

  if v_count < 1 then
    raise exception using errcode = '22023', message = 'Choose at least one page to print.';
  end if;

  return v_count;
end
$function$;

-- ══════════ GRANTS (current, matching the roles actually granted on the proven-passing cluster) ══════════
revoke all on function commerce.qs_count_page_spec(text) from public, anon, authenticated, service_role;
grant execute on function commerce.qs_count_page_spec(text) to anon, authenticated, service_role;
revoke all on function commerce.qs_guard_easy_locate_business_ref() from public, anon, authenticated, service_role;
grant execute on function commerce.qs_guard_easy_locate_business_ref() to anon, authenticated, service_role;
revoke all on function commerce.qs_normalize_document_configuration(jsonb) from public, anon, authenticated, service_role;
grant execute on function commerce.qs_normalize_document_configuration(jsonb) to anon, authenticated, service_role;

revoke all on function public.admin_get_quick_solution_catalog(text) from public, anon, authenticated, service_role;
grant execute on function public.admin_get_quick_solution_catalog(text) to authenticated, service_role;
revoke all on function public.admin_get_quick_solution_fulfilment_points(text) from public, anon, authenticated, service_role;
grant execute on function public.admin_get_quick_solution_fulfilment_points(text) to authenticated, service_role;
revoke all on function public.admin_list_quick_solution_opps_handoffs(text) from public, anon, authenticated, service_role;
grant execute on function public.admin_list_quick_solution_opps_handoffs(text) to authenticated;
revoke all on function public.admin_preview_quick_solution_opps_handoff(uuid) from public, anon, authenticated, service_role;
grant execute on function public.admin_preview_quick_solution_opps_handoff(uuid) to authenticated, service_role;
revoke all on function public.admin_send_quick_solution_order_to_opps(uuid) from public, anon, authenticated, service_role;
grant execute on function public.admin_send_quick_solution_order_to_opps(uuid) to authenticated, service_role;
revoke all on function public.admin_update_quick_solution_product(text,text,jsonb,jsonb,text) from public, anon, authenticated, service_role;
grant execute on function public.admin_update_quick_solution_product(text,text,jsonb,jsonb,text) to authenticated, service_role;
revoke all on function public.admin_upsert_quick_solution_fulfilment_point(text,uuid,jsonb) from public, anon, authenticated, service_role;
grant execute on function public.admin_upsert_quick_solution_fulfilment_point(text,uuid,jsonb) to authenticated, service_role;
revoke all on function public.cancel_quick_solution_counter_order(uuid,text) from public, anon, authenticated, service_role;
grant execute on function public.cancel_quick_solution_counter_order(uuid,text) to authenticated;
revoke all on function public.create_quick_solution_cart_order(text,jsonb,text,text,text,text,uuid,jsonb,text,text) from public, anon, authenticated, service_role;
grant execute on function public.create_quick_solution_cart_order(text,jsonb,text,text,text,text,uuid,jsonb,text,text) to anon, authenticated, service_role;
revoke all on function public.create_quick_solution_counter_order(text,text,jsonb,text,text,text) from public, anon, authenticated, service_role;
grant execute on function public.create_quick_solution_counter_order(text,text,jsonb,text,text,text) to authenticated;
revoke all on function public.create_quick_solution_order(text,text,jsonb,text,text,text,text,uuid,jsonb,text,text) from public, anon, authenticated, service_role;
grant execute on function public.create_quick_solution_order(text,text,jsonb,text,text,text,text,uuid,jsonb,text,text) to anon, authenticated, service_role;
revoke all on function public.create_quick_solution_service_request(text,text,jsonb,text,text,text,jsonb,text,text) from public, anon, authenticated, service_role;
grant execute on function public.create_quick_solution_service_request(text,text,jsonb,text,text,text,jsonb,text,text) to anon, authenticated, service_role;
revoke all on function public.get_quick_solution_catalog(text) from public, anon, authenticated, service_role;
grant execute on function public.get_quick_solution_catalog(text) to anon, authenticated, service_role;
revoke all on function public.get_quick_solution_counter_cashup(date) from public, anon, authenticated, service_role;
grant execute on function public.get_quick_solution_counter_cashup(date) to authenticated;
revoke all on function public.get_quick_solution_counter_cashup_today() from public, anon, authenticated, service_role;
grant execute on function public.get_quick_solution_counter_cashup_today() to authenticated;
revoke all on function public.get_quick_solution_counter_catalog() from public, anon, authenticated, service_role;
grant execute on function public.get_quick_solution_counter_catalog() to authenticated;
revoke all on function public.get_quick_solution_counter_order(uuid) from public, anon, authenticated, service_role;
grant execute on function public.get_quick_solution_counter_order(uuid) to authenticated;
revoke all on function public.get_quick_solution_counter_order_cancel_check(uuid) from public, anon, authenticated, service_role;
grant execute on function public.get_quick_solution_counter_order_cancel_check(uuid) to authenticated;
revoke all on function public.list_quick_solution_cancelled_counter_orders() from public, anon, authenticated, service_role;
grant execute on function public.list_quick_solution_cancelled_counter_orders() to authenticated;
revoke all on function public.list_quick_solution_counter_orders_today() from public, anon, authenticated, service_role;
grant execute on function public.list_quick_solution_counter_orders_today() to authenticated;
revoke all on function public.list_quick_solution_unpaid_counter_orders() from public, anon, authenticated, service_role;
grant execute on function public.list_quick_solution_unpaid_counter_orders() to authenticated;
revoke all on function public.record_quick_solution_counter_payment(uuid,text,text) from public, anon, authenticated, service_role;
grant execute on function public.record_quick_solution_counter_payment(uuid,text,text) to authenticated;

-- ── the get_quick_solution_staff_catalog refresh (OPPS-committed source, qs10_staff_new_order_rpc.sql) ──
revoke all on function public.get_quick_solution_staff_catalog(uuid) from public, anon, authenticated, service_role;
grant execute on function public.get_quick_solution_staff_catalog(uuid) to authenticated;

-- ══════════ qs_guard_* trigger bindings ══════════
create trigger trg_qs_guard_easy_locate_business_ref before insert or update of easy_locate_business_ref on commerce.fulfilment_points for each row execute function commerce.qs_guard_easy_locate_business_ref();
create trigger trg_qs_guard_service_order_item_channel before insert or update of order_id, tenant_id, product_key on commerce.service_order_items for each row execute function commerce.qs_guard_service_order_item_channel();
create trigger trg_qs_guard_service_order_origin before update of channel, tenant_id on commerce.service_orders for each row execute function commerce.qs_guard_service_order_origin();
create trigger trg_qs_cancellation_no_truncate before truncate on commerce.service_order_cancellations for each statement execute function commerce.qs_guard_service_order_cancellation_append_only();
create trigger trg_qs_cancellation_no_update_delete before delete or update on commerce.service_order_cancellations for each row execute function commerce.qs_guard_service_order_cancellation_append_only();
