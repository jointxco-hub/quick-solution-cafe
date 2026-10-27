-- Issue #106: separate, read-only OPPS work queue for authorized Café operators.
-- Apply to a verified staging database first. No payment or fulfillment writes.
create or replace function public.list_cafe_opps_work_queue()
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_items jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Staff sign-in is required.';
  end if;

  select t.id into v_tenant_id
  from public.tenants t
  where t.slug = 'quick-solution' and t.status = 'active'
  limit 1;

  if v_tenant_id is null or not public.has_tenant_capability(v_tenant_id, 'cafe.counter.operate') then
    raise exception using errcode = '42501', message = 'Counter access is required.';
  end if;

  select coalesce(jsonb_agg(x.item order by x.created_at desc, x.source_id desc), '[]'::jsonb)
  into v_items
  from (
    select i.id as source_id, i.created_at,
      jsonb_build_object(
        'sourceType','invoice', 'sourceId',i.id, 'number',i.invoice_number,
        'customerName',i.customer_name, 'status',i.status,
        'total',i.total, 'balanceDue',i.balance_due,
        'paymentStatus',case when i.balance_due <= 0 then 'paid' else 'unpaid' end,
        'paymentEligible',false, 'handoffStatus',coalesce((select h.status from public.cafe_opps_handoffs h where h.tenant_id=v_tenant_id and ((h.source_type='invoice' and h.source_id=i.id) or (i.source_order_id is not null and h.canonical_order_id=i.source_order_id)) order by h.created_at limit 1),'not_sent')
      ) as item
    from public.opps_invoices i
    where i.tenant_id = v_tenant_id
      and i.status not in ('draft','void','cancelled')
    union all
    select o.id as source_id, o.created_at,
      jsonb_build_object(
        'sourceType','order', 'sourceId',o.id, 'number',o.order_number,
        'customerName',o.client_name, 'status',o.status,
        'total',o.total_amount, 'balanceDue',null,
        'paymentStatus',coalesce(o.payment_status,'unknown'),
        'paymentEligible',false, 'handoffStatus',coalesce((select h.status from public.cafe_opps_handoffs h where h.tenant_id=v_tenant_id and ((h.source_type='order' and h.source_id=o.id) or h.canonical_order_id=o.id) order by h.created_at limit 1),'not_sent')
      ) as item
    from public.orders o
    where o.tenant_id = v_tenant_id
      and coalesce(o.is_archived,false) = false
  ) x;

  return jsonb_build_object('items',v_items);
end;
$$;

revoke all on function public.list_cafe_opps_work_queue() from public, anon;
grant execute on function public.list_cafe_opps_work_queue() to authenticated;
