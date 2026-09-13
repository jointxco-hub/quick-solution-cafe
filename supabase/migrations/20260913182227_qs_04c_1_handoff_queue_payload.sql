-- QS-04C.1: enrich the staff handoff queue with its stored preview payload.
-- This lets sent orders render the exact pre-send OPPS payload without rebuilding a preview
-- that would now correctly report ALREADY_HANDED_OFF.

create or replace function public.admin_list_quick_solution_opps_handoffs(
  p_tenant_slug text default 'quick-solution'
)
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

  if not public.is_app_admin()
     and not (public.is_opps_staff() and public.can_access_tenant(v_tenant_id)) then
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
$$;

revoke all on function public.admin_list_quick_solution_opps_handoffs(text) from public, anon, authenticated;
grant execute on function public.admin_list_quick_solution_opps_handoffs(text) to authenticated;
