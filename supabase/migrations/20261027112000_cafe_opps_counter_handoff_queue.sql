-- Staging: fulfillment tickets are distinct from commerce sales and invoices.
create or replace function public.list_cafe_opps_handoffs()
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_tenant uuid;
begin
  select id into v_tenant from public.tenants where slug='quick-solution' and status='active';
  if auth.uid() is null or v_tenant is null or
     not public.has_tenant_capability(v_tenant,'cafe.counter.operate') then
    raise exception using errcode='42501',message='Counter access required';
  end if;
  return jsonb_build_object('items',coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',h.id,'number',h.source_number,'customer',h.customer_name,
      'sourceType',h.source_type,'status',h.status,
      'createdAt',h.created_at) order by h.created_at desc)
    from public.cafe_opps_handoffs h where h.tenant_id=v_tenant
  ),'[]'::jsonb));
end; $$;
revoke all on function public.list_cafe_opps_handoffs() from public,anon;
grant execute on function public.list_cafe_opps_handoffs() to authenticated;

create or replace function public.update_cafe_opps_handoff(p_id uuid,p_status text)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_tenant uuid; v_old text;
begin
  select id into v_tenant from public.tenants where slug='quick-solution' and status='active';
  if auth.uid() is null or v_tenant is null or
     not public.has_tenant_capability(v_tenant,'cafe.counter.operate') then
    raise exception using errcode='42501',message='Counter access required';
  end if;
  select status into v_old from public.cafe_opps_handoffs
    where id=p_id and tenant_id=v_tenant for update;
  if not found then raise exception using errcode='22023',message='Handoff not found'; end if;
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
