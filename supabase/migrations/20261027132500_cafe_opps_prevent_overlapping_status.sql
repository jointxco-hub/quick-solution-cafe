create or replace function public.update_cafe_opps_handoff(p_id uuid,p_status text)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_tenant uuid; v_old text; v_order uuid; v_number text;
begin
  select id into v_tenant from public.tenants where slug='quick-solution' and status='active';
  if auth.uid() is null or v_tenant is null or
     not public.has_tenant_capability(v_tenant,'cafe.counter.operate') then
    raise exception using errcode='42501',message='Counter access required';
  end if;
  select status,canonical_order_id,source_number into v_old,v_order,v_number
  from public.cafe_opps_handoffs where id=p_id and tenant_id=v_tenant for update;
  if not found then raise exception using errcode='22023',message='Handoff not found'; end if;
  if exists (select 1 from commerce.service_orders so where so.tenant_id=v_tenant
    and so.status <> 'cancelled' and (so.opps_order_id=v_order or so.order_number=v_number)) then
    raise exception using errcode='22023',
      message='Already in Café orders. Use the original Café fulfillment workflow.';
  end if;
  if v_old=p_status then return jsonb_build_object('id',p_id,'status',v_old); end if;
  if not ((v_old='received' and p_status='in_production')
       or (v_old='in_production' and p_status='ready')
       or (v_old='ready' and p_status='collected')) then
    raise exception using errcode='22023',message='Invalid fulfillment transition';
  end if;
  update public.cafe_opps_handoffs set status=p_status,updated_at=now()
    where id=p_id and tenant_id=v_tenant;
  return jsonb_build_object('id',p_id,'status',p_status);
end; $$;
revoke all on function public.update_cafe_opps_handoff(uuid,text) from public,anon;
grant execute on function public.update_cafe_opps_handoff(uuid,text) to authenticated;