-- Issue #106 · Staging first: OPPS-to-Café fulfillment tickets are NOT sales.
-- Never insert into commerce.service_orders or touch invoice balances/payment records.
create table if not exists public.cafe_opps_handoffs (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  source_type text not null check (source_type in ('invoice', 'order')),
  source_id uuid not null,
  canonical_order_id uuid,
  source_number text not null,
  customer_name text,
  status text not null default 'received' check (status in ('received','in_production','ready','collected','cancelled')),
  created_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id,source_type,source_id)
);
create unique index if not exists cafe_opps_handoffs_canonical_order_uniq
  on public.cafe_opps_handoffs(tenant_id,canonical_order_id)
  where canonical_order_id is not null;
create index if not exists cafe_opps_handoffs_queue_idx
  on public.cafe_opps_handoffs(tenant_id,created_at desc);
alter table public.cafe_opps_handoffs enable row level security;
revoke all on public.cafe_opps_handoffs from public, anon, authenticated;

-- This records a fulfillment request only; never a new purchase/payment.
create or replace function public.send_opps_work_to_cafe(p_source_type text, p_source_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare
  v_tenant uuid;
  v_number text;
  v_customer text;
  v_status text;
  v_order_id uuid;
  v_ticket public.cafe_opps_handoffs%rowtype;
begin
  if auth.uid() is null then
    raise exception using errcode='42501', message='Staff sign-in required';
  end if;
  select id into v_tenant from public.tenants where slug='quick-solution' and status='active';
  if v_tenant is null or not public.has_tenant_capability(v_tenant,'cafe.operations.manage') then
    raise exception using errcode='42501', message='Café admin permission required';
  end if;
  if p_source_type not in ('invoice','order') or p_source_id is null then
    raise exception using errcode='22023', message='Invalid OPPS source';
  end if;

  if p_source_type='invoice' then
    select i.invoice_number, i.customer_name, i.status, i.source_order_id
      into v_number,v_customer,v_status,v_order_id
    from public.opps_invoices i where i.id=p_source_id and i.tenant_id=v_tenant;
    if not found or v_status in ('draft','void','cancelled') then
      raise exception using errcode='22023', message='Invoice not eligible for handoff';
    end if;
  else
    select o.order_number,o.client_name,o.status,o.id
      into v_number,v_customer,v_status,v_order_id
    from public.orders o where o.id=p_source_id and o.tenant_id=v_tenant
      and coalesce(o.is_archived,false)=false;
    if not found or v_status in ('cancelled','canceled','void') then
      raise exception using errcode='22023', message='Order not eligible for handoff';
    end if;
  end if;

  -- Production-like test data in staging must never become actionable work.
  if coalesce(v_number,'') ~* '(test|staging|race|overlap)'
    or coalesce(v_customer,'') ~* '(do not fulfil|do not fulfill|test|staging|race|overlap)' then
    raise exception using errcode='22023', message='Test records are excluded from Café fulfillment';
  end if;

  -- Existing Café storefront/counter orders already have their own fulfillment workflow.
  -- A linked OPPS order or invoice must never create a second fulfillment ticket.
  if exists (
    select 1 from commerce.service_orders so
    where so.tenant_id=v_tenant
      and (so.opps_order_id=v_order_id
        or so.order_number=v_number)
      and so.status <> 'cancelled'
  ) then
    raise exception using errcode='22023',
      message='This job is already a Café sale. Use its existing fulfillment workflow.';
  end if;

  -- Avoid creating a second ticket for an invoice whose OPPS order was already handed over.
  select * into v_ticket from public.cafe_opps_handoffs h
    where h.tenant_id=v_tenant
      and ((h.source_type=p_source_type and h.source_id=p_source_id)
        or (v_order_id is not null and h.canonical_order_id=v_order_id))
    order by h.created_at asc limit 1;
  if found then
    return jsonb_build_object('id',v_ticket.id,'status',v_ticket.status,'alreadyExists',true);
  end if;

  insert into public.cafe_opps_handoffs
    (tenant_id,source_type,source_id,canonical_order_id,source_number,customer_name,created_by)
  values (v_tenant,p_source_type,p_source_id,v_order_id,coalesce(v_number,'—'),v_customer,auth.uid())
  on conflict do nothing
  returning * into v_ticket;
  if v_ticket.id is null then
    select * into v_ticket from public.cafe_opps_handoffs h
      where h.tenant_id=v_tenant
        and ((h.source_type=p_source_type and h.source_id=p_source_id)
          or (v_order_id is not null and h.canonical_order_id=v_order_id))
      limit 1;
    return jsonb_build_object('id',v_ticket.id,'status',v_ticket.status,'alreadyExists',true);
  end if;
  return jsonb_build_object('id',v_ticket.id,'status',v_ticket.status,'alreadyExists',false);
end;
$$;
revoke all on function public.send_opps_work_to_cafe(text,uuid) from public,anon;
grant execute on function public.send_opps_work_to_cafe(text,uuid) to authenticated;
