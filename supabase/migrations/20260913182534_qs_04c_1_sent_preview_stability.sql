-- QS-04C.1: sent handoffs keep their canonical pre-send preview stable.
-- A later staff preview must not overwrite the stored payload with ALREADY_HANDED_OFF.

with cleaned as (
  select
    h.id,
    coalesce(
      jsonb_agg(item) filter (where item->>'code' is distinct from 'ALREADY_HANDED_OFF'),
      '[]'::jsonb
    ) as blockers
  from commerce.service_order_handoffs h
  left join lateral jsonb_array_elements(coalesce(h.preview_payload->'blockers','[]'::jsonb)) item on true
  where h.status='sent'
  group by h.id
)
update commerce.service_order_handoffs h
set blockers = c.blockers,
    preview_payload =
      jsonb_set(
        jsonb_set(
          coalesce(h.preview_payload,'{}'::jsonb),
          '{blockers}',
          c.blockers,
          true
        ),
        '{ready}',
        to_jsonb(jsonb_array_length(c.blockers)=0),
        true
      )
from cleaned c
where h.id=c.id
  and (
    h.blockers is distinct from c.blockers
    or coalesce(h.preview_payload->'blockers','[]'::jsonb) is distinct from c.blockers
  );

create or replace function public.admin_preview_quick_solution_opps_handoff(
  p_service_order_id uuid
)
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

  if not public.is_app_admin()
     and not (public.is_opps_staff() and public.can_access_tenant(v_source_tenant_id)) then
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
