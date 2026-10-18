-- Preserve OPPS payments.manage authority without granting Café operational access.
create or replace function commerce.qs_payment_service_order_for_opps(p_opps_order_id uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare service_ids uuid[]; tenant uuid;
begin
  if auth.uid() is null then raise exception using errcode='42501',message='Staff sign-in is required.'; end if;
  select o.tenant_id into tenant from public.orders o join public.tenants t on t.id=o.tenant_id
    where o.id=p_opps_order_id and o.source='quick_solution' and t.slug='quick-solution' and t.status='active';
  if tenant is null or not public.has_tenant_permission(tenant,'payments.manage') then
    raise exception using errcode='42501',message='Order payment access is unavailable.';
  end if;
  select array_agg(id) into service_ids from commerce.service_orders
    where opps_order_id=p_opps_order_id and tenant_id=tenant;
  if coalesce(cardinality(service_ids),0)<>1 then
    raise exception 'The Cafe order link needs review before recording payment.';
  end if;
  return service_ids[1];
end $$;
revoke all on function commerce.qs_payment_service_order_for_opps(uuid) from public,anon,authenticated;

-- Both staff entry points use this same reconciliation state.
-- Shared preflight for Café-originated payments. Read-only; never sums mirrored ledgers.
create or replace function public.qs_staff_payment_state(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  o commerce.service_orders;
  cafe_paid numeric := 0;
  opps_paid numeric := 0;
  invoice_paid numeric := 0;
  invoice_count integer := 0;
  problems jsonb := '[]'::jsonb;
  receipts jsonb := '[]'::jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode='42501', message='Staff sign-in is required.';
  end if;
  select so.* into o from commerce.service_orders so
    join public.tenants t on t.id=so.tenant_id
    where so.id=p_order_id and t.slug='quick-solution' and t.status='active';
  if o.id is null then
    raise exception using errcode='42501', message='Order is unavailable.';
  end if;
  if not (public.has_tenant_capability(o.tenant_id,'cafe.operations.manage')
    or public.has_tenant_permission(o.tenant_id,'payments.manage')) then
    raise exception using errcode='42501', message='Order is unavailable.';
  end if;

  select coalesce(sum(amount),0) into cafe_paid
    from commerce.service_order_payments where service_order_id=o.id
    and tenant_id=o.tenant_id and status='completed';
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'method',provider,
    'amount',amount,'receivedAt',completed_at) order by completed_at,id),'[]'::jsonb)
    into receipts from commerce.service_order_payments where service_order_id=o.id
    and tenant_id=o.tenant_id and status='completed';

  if o.opps_order_id is not null then
    if not exists(select 1 from public.orders where id=o.opps_order_id
      and tenant_id=o.tenant_id and source='quick_solution') then
      problems:=problems || '"invalid_order_link"'::jsonb;
    else
      if exists(select 1 from public.orders where id=o.opps_order_id
        and total_amount is distinct from o.total_amount) then
        problems:=problems || '"order_total_mismatch"'::jsonb;
      end if;
      select coalesce(sum(amount),0) into opps_paid from public.transactions
        where order_id=o.opps_order_id and tenant_id=o.tenant_id
        and type='income' and payment_status='completed';
      if cafe_paid <> opps_paid then
        problems:=problems || '"payment_balance_mismatch"'::jsonb;
      end if;
      select count(*) into invoice_count from public.opps_invoices
        where source_order_id=o.opps_order_id and tenant_id=o.tenant_id and status<>'void';
      select coalesce(sum(ip.amount),0) into invoice_paid from public.invoice_payments ip
        join public.opps_invoices i on i.id=ip.invoice_id and i.tenant_id=ip.tenant_id
        where i.source_order_id=o.opps_order_id and i.tenant_id=o.tenant_id;
      -- No stable Café receipt identity exists in invoice_payments yet. Even equal totals
      -- do not prove the same receipts. Block new collection until that bridge is in place.
      if invoice_count>0 or invoice_paid>0 then
        problems:=problems || '"invoice_reconciliation_required"'::jsonb;
      end if;
    end if;
  end if;
  if cafe_paid>coalesce(o.total_amount,0) then
    problems:=problems || '"overpayment_review_required"'::jsonb;
  end if;
  if o.payment_status in ('refunded','failed','cancelled') then
    problems:=problems || '"payment_status_review_required"'::jsonb;
  end if;
  if o.payment_status='paid' and cafe_paid<coalesce(o.total_amount,0) then
    problems:=problems || '"paid_status_without_receipts"'::jsonb;
  end if;
  return jsonb_build_object('orderId',o.id,'orderNumber',o.order_number,
    'total',o.total_amount,'cafePaid',cafe_paid,
    'oppsPaid',case when o.opps_order_id is not null then opps_paid else null end,
    'invoicePaid',invoice_paid,'receipts',receipts,'issues',problems,
    'reviewRequired',jsonb_array_length(problems)>0,
    'balanceDue',case when jsonb_array_length(problems)=0
      then greatest(coalesce(o.total_amount,0)-cafe_paid,0) else null end,
    'closed',o.status in ('completed','cancelled'));
end $$;
revoke all on function public.qs_staff_payment_state(uuid) from public,anon;
grant execute on function public.qs_staff_payment_state(uuid) to authenticated;
comment on function public.qs_staff_payment_state(uuid) is
  'Staff-only read preflight for Cafe payment integration. Mismatched/unsupported invoice ledgers yield no payable balance. Writes must revalidate under a shared lock; this response is not payment authorization.';
