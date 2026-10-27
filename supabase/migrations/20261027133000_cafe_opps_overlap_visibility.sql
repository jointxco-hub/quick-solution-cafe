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
      'createdAt',h.created_at,
      'existingCafeSale',exists (select 1 from commerce.service_orders so where so.tenant_id=h.tenant_id and so.status <> 'cancelled' and (so.opps_order_id=h.canonical_order_id or so.order_number=h.source_number))) order by h.created_at desc)
    from public.cafe_opps_handoffs h where h.tenant_id=v_tenant
  ),'[]'::jsonb));
end; $$;
revoke all on function public.list_cafe_opps_handoffs() from public,anon;
grant execute on function public.list_cafe_opps_handoffs() to authenticated;

