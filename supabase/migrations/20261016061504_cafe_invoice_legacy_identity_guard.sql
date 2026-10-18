-- Equal legacy totals do not prove the same receipt. Keep them review-blocked.
create or replace function commerce.qs_invoice_payment_issues(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare o commerce.service_orders; i public.opps_invoices; ids uuid[]; issues jsonb:='[]';
begin
 select * into o from commerce.service_orders where id=p_order_id;
 if o.opps_order_id is null then return issues; end if;
 select array_agg(id) into ids from public.opps_invoices where source_order_id=o.opps_order_id and tenant_id=o.tenant_id and status is distinct from 'void';
 if coalesce(cardinality(ids),0)>1 then return '["multiple_linked_invoices"]'::jsonb; end if;
 if exists(select 1 from public.invoice_payments ip join public.opps_invoices inv on inv.id=ip.invoice_id
   where inv.source_order_id=o.opps_order_id and (inv.tenant_id is distinct from o.tenant_id or inv.status='void')) then
   issues:=issues||'"invoice_reconciliation_required"'::jsonb;
 end if;
 if coalesce(cardinality(ids),0)=0 then return issues; end if;
 select * into i from public.opps_invoices where id=ids[1];
 if exists(select 1 from commerce.service_order_payments where service_order_id=o.id and status='completed')
   and not exists(select 1 from public.transactions where qs_service_order_id=o.id and order_id=o.opps_order_id
     and tenant_id=o.tenant_id and type='income' and payment_status='completed') then
   issues:=issues||'"finance_receipt_identity_missing"'::jsonb;
 end if;
 if i.total is distinct from o.total_amount or i.currency_code is distinct from 'ZAR' then
   issues:=issues||'"invoice_total_or_currency_mismatch"'::jsonb;
 end if;
 if i.status is null or i.status in ('draft','void') then issues:=issues||'"invoice_not_approved"'::jsonb; end if;
 -- Matching totals alone are insufficient: every invoice row must identify its original receipt.
 if exists(select 1 from public.invoice_payments ip left join commerce.service_order_payments r on r.id=ip.qs_payment_id
   where ip.invoice_id=i.id and (r.id is null or r.service_order_id<>o.id or r.tenant_id<>o.tenant_id
     or r.status<>'completed' or ip.tenant_id<>o.tenant_id or ip.order_id is distinct from o.opps_order_id
     or ip.source<>'order_sync' or ip.amount is distinct from r.amount or ip.method is distinct from r.provider
     or ip.paid_at is distinct from r.completed_at or ip.reference is distinct from r.staff_reference)) then
   issues:=issues||'"invoice_reconciliation_required"'::jsonb;
 end if;
 if exists(select 1 from commerce.service_order_payments r where r.service_order_id=o.id and r.status='completed'
   and not exists(select 1 from public.invoice_payments ip where ip.invoice_id=i.id and ip.qs_payment_id=r.id)) then
   issues:=issues||'"invoice_projection_missing"'::jsonb;
 end if;
 if i.status='paid' and public.invoice_amount_paid(i.id)<coalesce(i.total,0) then
   issues:=issues||'"invoice_paid_status_without_receipts"'::jsonb;
 end if;
 return issues;
end $$;
revoke all on function commerce.qs_invoice_payment_issues(uuid) from public,anon,authenticated;

