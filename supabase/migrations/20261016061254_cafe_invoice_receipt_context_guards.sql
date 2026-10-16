-- Preserve receipt actor attribution and refuse silently backdated shared entries.
create or replace function public.qs_guard_invoice_receipt() returns trigger
language plpgsql security definer set search_path='' as $$
declare inv public.opps_invoices; r commerce.service_order_payments; service_id uuid;
begin
 if tg_op<>'INSERT' and (old.qs_payment_id is not null or exists(select 1 from public.opps_invoices i join commerce.service_orders o on o.opps_order_id=i.source_order_id and o.tenant_id=i.tenant_id where i.id=old.invoice_id)) then
   raise exception 'Shared Cafe receipts require an audited correction; invoice projections cannot be edited or deleted';
 end if;
 select * into inv from public.opps_invoices where id=case when tg_op='DELETE' then old.invoice_id else new.invoice_id end;
 select id into service_id from commerce.service_orders where opps_order_id=inv.source_order_id and tenant_id=inv.tenant_id;
 if tg_op='DELETE' then
   if service_id is not null then raise exception 'Cafe invoice receipts require reconciliation'; end if;
   return old;
 end if;
 if service_id is not null or new.qs_payment_id is not null
   or exists(select 1 from public.orders where id=inv.source_order_id and source='quick_solution') then
   if new.qs_payment_id is null or tg_op<>'INSERT' then
     raise exception using errcode='42501',message='Record this Cafe payment through the shared receipt service';
   end if;
   select * into r from commerce.service_order_payments where id=new.qs_payment_id;
   if r.id is null or r.service_order_id is distinct from service_id or r.tenant_id is distinct from inv.tenant_id
     or r.status<>'completed' or new.created_by is distinct from r.recorded_by or new.source<>'order_sync' or new.amount is distinct from r.amount
     or new.method is distinct from r.provider or new.reference is distinct from r.staff_reference
     or new.paid_at is distinct from r.completed_at or new.order_id is distinct from inv.source_order_id
     or inv.status in ('draft','void') then raise exception 'Invalid Cafe invoice receipt projection'; end if;
 end if;
 return new;
end $$;
revoke all on function public.qs_guard_invoice_receipt() from public,anon,authenticated;

create or replace function commerce.qs_record_invoice_payment(
 p_invoice_id uuid,p_amount numeric,p_reference text,p_paid_at timestamptz,p_method text,p_note text,p_operation_key text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare inv public.opps_invoices; service_id uuid; key uuid; result jsonb; row_id uuid; proof integer; op text:=nullif(btrim(p_operation_key),'');
begin
 if auth.uid() is null then raise exception using errcode='42501',message='Staff sign-in is required'; end if;
 select * into inv from public.opps_invoices where id=p_invoice_id;
 if inv.id is null or not public.can_access_tenant(inv.tenant_id)
   or not (public.is_app_admin() or public.user_finance_level() in (1,2)) then
   raise exception using errcode='42501',message='Invoice payment access denied';
 end if;
 service_id:=commerce.qs_payment_service_order_for_opps(inv.source_order_id);
 perform 1 from commerce.service_orders where id=service_id for update;
 select * into inv from public.opps_invoices where id=p_invoice_id for update;
 if inv.source_order_id is distinct from (select opps_order_id from commerce.service_orders where id=service_id)
   or inv.tenant_id is distinct from (select tenant_id from commerce.service_orders where id=service_id)
   or inv.status is null or inv.status in ('draft','void') then raise exception 'Invoice link or approval requires review'; end if;
 if op is null then raise exception 'INVOICE_PAYMENT_OPERATION_KEY_REQUIRED'; end if;
 if length(op)>200 then raise exception 'Invoice payment operation key is too long'; end if;
 begin key:=op::uuid; exception when invalid_text_representation then key:=md5('cafe-invoice:'||inv.id::text||':'||op)::uuid; end;
 -- This slice records money received now. Historical entry needs the correction workflow.
 -- Replays of an existing receipt remain valid on later dates.
 if p_paid_at is not null and (p_paid_at at time zone 'UTC')::date not in
   ((now() at time zone 'UTC')::date,(now() at time zone 'Africa/Johannesburg')::date)
   and not exists(select 1 from commerce.service_order_payments
     where service_order_id=service_id and idempotency_key='staff-receipt:'||auth.uid()::text||':'||key::text) then
   raise exception 'INVOICE_PAYMENT_CAFE_CURRENT_DATE_REQUIRED';
 end if;
 result:=public.qs_record_staff_payment(service_id,lower(btrim(p_method)),p_amount,p_reference,key);
 select id into row_id from public.invoice_payments where invoice_id=inv.id and qs_payment_id=(result->>'receiptId')::uuid;
 if row_id is null then raise exception 'Shared invoice receipt projection missing'; end if;
 proof:=public._link_staged_payment_attachments(inv.id,op,row_id,inv.tenant_id);
 -- Store the requested date/note as context; the shared receipt keeps its server timestamp.
 if not (result->>'replayed')::boolean then
   insert into public.opps_invoice_activity(invoice_id,tenant_id,activity_type,activity_label,activity_note,metadata,created_by)
   values(inv.id,inv.tenant_id,'cafe_invoice_payment_entry','Payment recorded through shared Cafe service',nullif(btrim(p_note),''),
     jsonb_build_object('payment_id',row_id,'receipt_id',result->>'receiptId','operation_key',op,'requested_paid_at',p_paid_at,'proof_count',proof),auth.uid());
 end if;
 return jsonb_build_object('ok',true,'replayed',(result->>'replayed')::boolean,'payment_id',row_id,'proof_linked',proof,
   'projection',public._invoice_payment_projection(inv.id));
end $$;
revoke all on function commerce.qs_record_invoice_payment(uuid,numeric,text,timestamptz,text,text,text) from public,anon,authenticated;

