-- QS-04B: create the canonical OPPS order from a validated Quick Solution order.
-- Idempotent: one Quick Solution service_order can create at most one OPPS order.

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

    if not public.is_app_admin()
       and not (public.is_opps_staff() and public.can_access_tenant(v_service_order.tenant_id)) then
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
  'QS-04B canonical idempotent Quick Solution -> OPPS creation. Refuses blocked handoffs, creates one public.orders row, stores backlinks on both sides, and replays the same OPPS order on repeated calls.';
