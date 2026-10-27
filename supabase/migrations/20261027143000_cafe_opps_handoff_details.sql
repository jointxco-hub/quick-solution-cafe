-- Authorized Café fulfillment detail. No storage URLs, paths, or client-private file content.
-- File downloads must be brokered separately through verified signed URLs.
create or replace function public.get_cafe_opps_handoff_detail(p_handoff_id uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare
  v_tenant uuid;
  v_h public.cafe_opps_handoffs%rowtype;
  v_order uuid;
  v_notes jsonb;
  v_lines jsonb;
  v_files jsonb;
begin
  select id into v_tenant from public.tenants where slug='quick-solution' and status='active';
  if auth.uid() is null or v_tenant is null or
    not public.has_tenant_capability(v_tenant,'cafe.counter.operate') then
    raise exception using errcode='42501', message='Counter access required';
  end if;
  select * into v_h from public.cafe_opps_handoffs
    where id=p_handoff_id and tenant_id=v_tenant;
  if not found then
    raise exception using errcode='22023', message='Handoff not found';
  end if;
  v_order := v_h.canonical_order_id;
  if v_h.source_type='order' then
    select jsonb_strip_nulls(jsonb_build_object(
      'notes',o.notes,'specialInstructions',o.special_instructions,
      'productionNote',o.production_internal_note,'deliveryNote',o.delivery_note))
      into v_notes from public.orders o where o.id=v_h.source_id and o.tenant_id=v_tenant;
    v_lines := '[]'::jsonb;
  else
    select jsonb_strip_nulls(jsonb_build_object(
      'notes',i.notes,'deliveryInstructions',i.delivery_instructions))
      into v_notes from public.opps_invoices i where i.id=v_h.source_id and i.tenant_id=v_tenant;
    select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'name',li.item_name,'description',li.item_description,
      'quantity',li.quantity,'unit',li.unit,
      'specifications',li.specifications)) order by li.line_number),'[]'::jsonb)
      into v_lines from public.opps_invoice_items li
      where li.invoice_id=v_h.source_id and li.tenant_id=v_tenant;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('name',f.file_name,'type',f.file_type,'id',f.id)
        order by f.created_at),'[]'::jsonb)
    into v_files from public.client_file_links f
    where v_order is not null and f.linked_order_id=v_order and f.tenant_id=v_tenant;
  return jsonb_build_object(
    'id',v_h.id,'number',v_h.source_number,'customer',v_h.customer_name,
    'status',v_h.status,'sourceType',v_h.source_type,
    'notes',coalesce(v_notes,'{}'::jsonb),'items',coalesce(v_lines,'[]'::jsonb),
    'files',coalesce(v_files,'[]'::jsonb),
    'downloadsAvailable',false,
    'sourceOrderId',v_order);
end; $$;
revoke all on function public.get_cafe_opps_handoff_detail(uuid) from public,anon;
grant execute on function public.get_cafe_opps_handoff_detail(uuid) to authenticated;
