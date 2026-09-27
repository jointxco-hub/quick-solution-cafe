-- SECURITY PATCH: every Quick Solution admin RPC gated on the old
-- `is_app_admin() OR (is_opps_staff() AND can_access_tenant(tenant))` pattern is re-gated
-- on `has_tenant_capability(tenant, 'cafe.operations.manage')` instead.
--
-- ROOT CAUSE. public.is_opps_staff() was broadened, live on both staging and production, to also
-- return true for any active member of any tenant flagged 'opps_workspace' (tenant_capabilities)
-- whose tenant_role holds the 'opps.access' permission (has_tenant_permission /
-- tenant_access_role_permissions, wildcard '*' included) - a legitimate, intentional change for
-- the wider OPPS permission model, and this migration does NOT touch is_opps_staff() itself. Six
-- Quick Solution admin RPCs, all predating CAFE-ACCESS-01 and all still using the OLD gate, never
-- anticipated that broadening: because the quick-solution tenant is itself flagged 'opps_workspace'
-- with 'opps.access' granted, EVERY active member of it - not just owner/admin - now satisfies
-- is_opps_staff(), and every one of these six RPCs treats "is_opps_staff() AND can_access_tenant"
-- as sufficient staff authority. Confirmed empirically, read-only/rolled-back, against staging:
--   * admin_get_quick_solution_catalog returns the full staff pricing catalogue to a plain member.
--   * admin_update_quick_solution_product LETS a plain member rewrite a product's name and pricing
--     definition outright (proven with a real update, rolled back).
--   * admin_send_quick_solution_order_to_opps passes its own internal gate for a plain member, but
--     a SEPARATE, independent guard on public.orders ("This workspace role cannot edit orders")
--     currently stops the actual insert - a second layer that happens to catch this one, not
--     something to rely on going forward.
--   * admin_preview_quick_solution_opps_handoff, admin_get_quick_solution_fulfilment_points and
--     admin_upsert_quick_solution_fulfilment_point carry the byte-for-byte identical gate pattern
--     and are assessed as equally affected (not each individually re-proven with a live mutation,
--     to avoid unnecessary write attempts against staging beyond what was already demonstrated).
-- admin_list_quick_solution_opps_handoffs (the sibling RPC) already carries this exact fix, live,
-- uncommitted until now - this migration is what makes that fix real, in git, for every affected
-- RPC, not only the one that had already been patched by hand.
--
-- THE FIX preserves every RPC's existing signature, return shape, and OWN business logic
-- byte-for-byte; only the authorization condition changes, from three helpers with an app-admin/
-- OPPS-staff bypass to the one Cafe-owned, membership-derived primitive with none:
--   before: if not public.is_app_admin() and not (public.is_opps_staff() and public.can_access_tenant(v_tenant_id)) then
--   after:  if not public.has_tenant_capability(v_tenant_id, 'cafe.operations.manage') then
-- cafe.operations.manage is already exactly "active owner or admin of the tenant" (CAFE-ACCESS-01),
-- so: a plain member (or counter_staff, CAFE-ACCESS-04) is denied - the escalation is closed: only
-- owner/admin now pass, matching the same contract admin_list_quick_solution_opps_handoffs already
-- enforces; is_opps_staff() and is_app_admin() are not touched or narrowed anywhere - the wider OPPS
-- permission model these six RPCs never should have depended on for Cafe-specific authority is
-- simply no longer consulted by them; app-admin loses its bypass here (the same trade-off already
-- made, live, for the sibling RPC) - an app admin with no Cafe membership can no longer manage Cafe
-- product/pricing/fulfilment/handoff data through these six RPCs either, consistent with "no
-- app-admin / OPPS-staff bypass" already documented as the intended Cafe authorization contract
-- (CAFE-ACCESS-01..04's own commit messages) rather than a new restriction invented here.
-- admin_send_quick_solution_order_to_opps's existing `current_user <> 'service_role'` bypass
-- (the PayFast ITN / service-role path) is untouched.
--
-- OUT OF SCOPE, DELIBERATELY: is_opps_staff(), is_opps_workspace_tenant(), has_tenant_permission(),
-- the tenant_capabilities/tenant_access_role_permissions rows behind them, and every OTHER (non
-- Quick-Solution) caller of is_opps_staff() elsewhere in the OPPS codebase. Narrowing the shared
-- helper was explicitly rejected as the fix: it is already the canonical, live, intentionally
-- broader definition for the wider OPPS permission model, and this patch does not assume anything
-- about that model beyond "a Cafe admin RPC should not treat it as sufficient Cafe authority."
--
-- DEPENDENCY: public.has_tenant_capability (OPPS repo, CAFE-ACCESS-01..04) must exist. On the
-- database this migration targets, it already does (applied since Group A of the staging rollout);
-- production does not yet have it - see the accompanying rollout-order report. This migration must
-- never be applied anywhere has_tenant_capability does not already exist.

do $preflight$
begin
  if to_regprocedure('public.has_tenant_capability(uuid,text)') is null then
    raise exception 'QS_ADMINISTRATION_CAPABILITY_AUTHORIZATION_PRECONDITION: public.has_tenant_capability (CAFE-ACCESS-01..04) must exist before this patch is applied';
  end if;
  if to_regprocedure('public.admin_get_quick_solution_catalog(text)') is null
     or to_regprocedure('public.admin_update_quick_solution_product(text,text,jsonb,jsonb,text)') is null
     or to_regprocedure('public.admin_preview_quick_solution_opps_handoff(uuid)') is null
     or to_regprocedure('public.admin_send_quick_solution_order_to_opps(uuid)') is null
     or to_regprocedure('public.admin_get_quick_solution_fulfilment_points(text)') is null
     or to_regprocedure('public.admin_upsert_quick_solution_fulfilment_point(text,uuid,jsonb)') is null then
    raise exception 'QS_ADMINISTRATION_CAPABILITY_AUTHORIZATION_PRECONDITION: all six affected RPCs must already exist';
  end if;
end
$preflight$;

-- ── 1. admin_get_quick_solution_catalog ──────────────────────────────────
create or replace function public.admin_get_quick_solution_catalog(p_tenant_slug text default 'quick-solution')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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
$$;

revoke all on function public.admin_get_quick_solution_catalog(text) from public, anon, authenticated;
grant execute on function public.admin_get_quick_solution_catalog(text) to authenticated;

comment on function public.admin_get_quick_solution_catalog(text) is
  'SECURITY PATCH: re-gated on has_tenant_capability(tenant, ''cafe.operations.manage'') - the old is_app_admin()/is_opps_staff() gate let any member through once is_opps_staff() was broadened for the wider OPPS permission model. Body unchanged otherwise.';

-- ── 2. admin_update_quick_solution_product ───────────────────────────────
create or replace function public.admin_update_quick_solution_product(p_tenant_slug text, p_product_key text, p_customer_definition jsonb, p_pricing_definition jsonb, p_expected_pricing_version text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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
$$;

revoke all on function public.admin_update_quick_solution_product(text,text,jsonb,jsonb,text) from public, anon, authenticated;
grant execute on function public.admin_update_quick_solution_product(text,text,jsonb,jsonb,text) to authenticated;

comment on function public.admin_update_quick_solution_product(text,text,jsonb,jsonb,text) is
  'SECURITY PATCH: re-gated on has_tenant_capability(tenant, ''cafe.operations.manage''). Confirmed live, before this patch, that a plain member could rewrite a product''s name and pricing outright. Body unchanged otherwise.';

-- ── 3. admin_preview_quick_solution_opps_handoff ─────────────────────────
create or replace function public.admin_preview_quick_solution_opps_handoff(p_service_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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
$$;

revoke all on function public.admin_preview_quick_solution_opps_handoff(uuid) from public, anon, authenticated;
grant execute on function public.admin_preview_quick_solution_opps_handoff(uuid) to authenticated;

comment on function public.admin_preview_quick_solution_opps_handoff(uuid) is
  'SECURITY PATCH: re-gated on has_tenant_capability(tenant, ''cafe.operations.manage''), matching its sibling admin_send_quick_solution_order_to_opps. Body unchanged otherwise.';

-- ── 4. admin_send_quick_solution_order_to_opps ───────────────────────────
create or replace function public.admin_send_quick_solution_order_to_opps(
  p_service_order_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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
$$;

revoke all on function public.admin_send_quick_solution_order_to_opps(uuid) from public, anon;
grant execute on function public.admin_send_quick_solution_order_to_opps(uuid) to authenticated, service_role;

comment on function public.admin_send_quick_solution_order_to_opps(uuid) is
  'QS-04B/CAFE-GUEST-01Y/SECURITY PATCH: canonical idempotent Quick Solution -> OPPS creation, imports the completed Cafe payment (CAFE-GUEST-01Y), and now re-gated on has_tenant_capability(tenant, ''cafe.operations.manage'') - the old is_app_admin()/is_opps_staff() gate passed for a plain member once is_opps_staff() was broadened; a separate guard on public.orders happened to still stop the actual write, but the RPC''s own gate is now correct independent of that. The service_role bypass (PayFast ITN) is unchanged.';

-- ── 5. admin_get_quick_solution_fulfilment_points ────────────────────────
create or replace function public.admin_get_quick_solution_fulfilment_points(p_tenant_slug text default 'quick-solution')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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
$$;

revoke all on function public.admin_get_quick_solution_fulfilment_points(text) from public, anon, authenticated;
grant execute on function public.admin_get_quick_solution_fulfilment_points(text) to authenticated;

comment on function public.admin_get_quick_solution_fulfilment_points(text) is
  'SECURITY PATCH: re-gated on has_tenant_capability(tenant, ''cafe.operations.manage''). Body unchanged otherwise.';

-- ── 6. admin_upsert_quick_solution_fulfilment_point ──────────────────────
create or replace function public.admin_upsert_quick_solution_fulfilment_point(p_tenant_slug text, p_point_id uuid, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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
$$;

revoke all on function public.admin_upsert_quick_solution_fulfilment_point(text,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.admin_upsert_quick_solution_fulfilment_point(text,uuid,jsonb) to authenticated;

comment on function public.admin_upsert_quick_solution_fulfilment_point(text,uuid,jsonb) is
  'SECURITY PATCH: re-gated on has_tenant_capability(tenant, ''cafe.operations.manage''). Body unchanged otherwise.';
