-- First shared writer: full outstanding Cash / verified EFT settlement.
-- Invoice-linked and mismatched legacy orders remain blocked for reconciliation.
alter table commerce.service_order_payments add column if not exists staff_reference text;
alter table public.transactions add column if not exists qs_service_order_id uuid references commerce.service_orders(id);
create unique index if not exists transactions_qs_service_order_once on public.transactions(qs_service_order_id) where qs_service_order_id is not null;

-- Finance rows produced here are projections, not independently editable receipts.
create or replace function public.qs_guard_finance_projection() returns trigger
language plpgsql set search_path='' as $$
begin
  if (case when tg_op='INSERT' then new.qs_service_order_id is not null
           when tg_op='DELETE' then old.qs_service_order_id is not null
           else old.qs_service_order_id is not null or new.qs_service_order_id is not null end)
     and current_user not in ('postgres','service_role') then
    raise exception using errcode='42501',message='Manage this receipt through the Cafe payment service.';
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;
revoke all on function public.qs_guard_finance_projection() from public,anon,authenticated;
create trigger qs_guard_finance_projection before insert or update or delete on public.transactions
for each row execute function public.qs_guard_finance_projection();

create or replace function commerce.qs_project_manual_receipt(p_order_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare o commerce.service_orders; tx public.transactions; paid numeric; method text; paid_at timestamptz;
begin
  select * into o from commerce.service_orders where id=p_order_id for update;
  if o.id is null then raise exception 'Cafe order unavailable'; end if;
  if o.opps_order_id is not null and not exists(select 1 from public.orders
    where id=o.opps_order_id and tenant_id=o.tenant_id and source='quick_solution') then
    raise exception 'Invalid OPPS order link';
  end if;
  select coalesce(sum(amount),0),max(completed_at),case when count(distinct provider)=1 then min(provider) else 'other' end
    into paid,paid_at,method from commerce.service_order_payments
    where service_order_id=o.id and tenant_id=o.tenant_id and status='completed';
  if paid<=0 then return; end if;
  select * into tx from public.transactions where qs_service_order_id=o.id for update;
  if tx.id is null and o.opps_order_id is not null then
    select * into tx from public.transactions where order_id=o.opps_order_id for update;
    if tx.id is not null then
      -- Existing rows lack receipt identity. Never assume equal amounts mean same receipt.
      raise exception 'Existing OPPS payment needs reconciliation before linking';
    end if;
  end if;
  if tx.id is null then
    insert into public.transactions(tenant_id,type,order_id,order_number,client_name,amount,
      payment_method,payment_status,payment_date,source,qs_service_order_id,notes)
    values(o.tenant_id,'income',o.opps_order_id,o.order_number,o.customer_name,paid,
      case when method in ('cash','card','eft') then method else 'other' end,'completed',
      (coalesce(paid_at,now()) at time zone 'Africa/Johannesburg')::date,
      'quick_solution',o.id,'Cafe receipt projection; manage original receipts in Cafe.');
  else
    if tx.tenant_id<>o.tenant_id or tx.type<>'income' or tx.source<>'quick_solution' then
      raise exception 'Finance receipt link needs review';
    end if;
    update public.transactions set order_id=o.opps_order_id,amount=paid,payment_status='completed',
      payment_method=case when method in ('cash','card','eft') then method else 'other' end
      where id=tx.id;
  end if;
  if o.opps_order_id is not null then
    update public.orders set deposit_paid=paid,payment_status=case when paid>=total_amount then 'paid' else 'pending' end,
      updated_at=now() where id=o.opps_order_id and tenant_id=o.tenant_id;
  end if;
end $$;
revoke all on function commerce.qs_project_manual_receipt(uuid) from public,anon,authenticated;

-- Preserve legacy handoff behavior; new managed projections reuse the original Finance row.
alter function commerce._qs_sync_opps_payment_ledger(uuid,uuid) rename to _qs_sync_opps_payment_ledger_legacy;
create function commerce._qs_sync_opps_payment_ledger(p_service_order_id uuid,p_opps_order_id uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
  if exists(select 1 from public.transactions where qs_service_order_id=p_service_order_id) then
    if not exists(select 1 from commerce.service_orders where id=p_service_order_id and opps_order_id=p_opps_order_id) then
      raise exception 'Payment handoff link mismatch';
    end if;
    perform commerce.qs_project_manual_receipt(p_service_order_id);
  else
    perform commerce._qs_sync_opps_payment_ledger_legacy(p_service_order_id,p_opps_order_id);
  end if;
end $$;
revoke all on function commerce._qs_sync_opps_payment_ledger(uuid,uuid) from public,anon,authenticated;

create or replace function public.qs_record_staff_payment(p_order_id uuid,p_method text,p_amount numeric,p_reference text,p_operation_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare o commerce.service_orders; state jsonb; receipt commerce.service_order_payments; key text; reference text:=nullif(btrim(p_reference),'');
begin
  -- Authorization precedes any receipt replay or financial data exposure.
  state:=public.qs_staff_payment_state(p_order_id);
  select * into o from commerce.service_orders where id=p_order_id for update;
  state:=public.qs_staff_payment_state(p_order_id);
  if p_operation_key is null then raise exception 'Payment operation key required'; end if;
  if p_method not in ('cash','eft') or p_method is null then raise exception 'Choose Cash or EFT'; end if;
  if p_amount is null or p_amount::text in ('NaN','Infinity','-Infinity') or p_amount<=0 or p_amount<>round(p_amount,2) then raise exception 'Enter a valid payment amount'; end if;
  if length(coalesce(reference,''))>120 then raise exception 'Payment reference is too long'; end if;
  if p_method='eft' and reference is null then raise exception 'Verified EFT reference required'; end if;
  key:='staff-receipt:'||auth.uid()::text||':'||p_operation_key::text;
  select * into receipt from commerce.service_order_payments where tenant_id=o.tenant_id and idempotency_key=key;
  if receipt.id is not null then
    if receipt.service_order_id<>o.id or receipt.amount<>p_amount or receipt.provider<>p_method or receipt.staff_reference is distinct from reference then
      raise exception 'Payment retry details differ from the saved receipt';
    end if;
    return jsonb_build_object('receiptId',receipt.id,'replayed',true,'payment',state);
  end if;
  if (state->>'reviewRequired')::boolean then raise exception 'Payment records need reconciliation first'; end if;
  if o.status in ('draft','cancelled','completed') or o.payment_status<>'unpaid' then raise exception 'This order cannot accept payment'; end if;
  if p_amount<>(state->>'balanceDue')::numeric then raise exception 'Record the full current outstanding balance'; end if;
  if exists(select 1 from commerce.service_order_payments where service_order_id=o.id and provider='payfast' and status='pending') then
    raise exception 'An online payment is pending. Resolve it before recording a manual receipt';
  end if;
  if exists(select 1 from commerce.service_order_handoffs where service_order_id=o.id and status='sending') then raise exception 'Order handoff is in progress'; end if;
  if o.opps_order_id is not null and exists(select 1 from public.transactions where order_id=o.opps_order_id and qs_service_order_id is distinct from o.id) then
    raise exception 'Existing OPPS payment needs reconciliation';
  end if;
  insert into commerce.service_order_payments(tenant_id,service_order_id,provider,status,amount,recorded_by,idempotency_key,completed_at,staff_reference)
    values(o.tenant_id,o.id,p_method,'completed',p_amount,auth.uid(),key,now(),reference) returning * into receipt;
  update commerce.service_order_payments set status='cancelled' where service_order_id=o.id and status='pending' and provider in ('eft','counter');
  update commerce.service_orders set payment_status='paid',updated_at=now() where id=o.id;
  perform commerce.qs_project_manual_receipt(o.id);
  return jsonb_build_object('receiptId',receipt.id,'replayed',false,'payment',public.qs_staff_payment_state(o.id));
end $$;
revoke all on function public.qs_record_staff_payment(uuid,text,numeric,text,uuid) from public,anon;
grant execute on function public.qs_record_staff_payment(uuid,text,numeric,text,uuid) to authenticated;

-- Serialize invoice receipts with Cafe manual receipts. Until invoice receipt identity
-- mapping is implemented, refuse competing writes for a managed Cafe order.
create or replace function public.qs_guard_invoice_receipt() returns trigger
language plpgsql security definer set search_path='' as $$
declare invoice_id uuid; service_id uuid;
begin
  invoice_id:=case when tg_op='DELETE' then old.invoice_id else new.invoice_id end;
  select so.id into service_id from commerce.service_orders so join public.opps_invoices i
    on i.source_order_id=so.opps_order_id and i.tenant_id=so.tenant_id
    where i.id=invoice_id for update of so;
  if service_id is not null and exists(select 1 from public.transactions where qs_service_order_id=service_id) then
    raise exception 'Cafe receipt already exists. Reconcile the linked invoice instead of recording another payment.';
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;
revoke all on function public.qs_guard_invoice_receipt() from public,anon,authenticated;
create trigger qs_guard_invoice_receipt before insert or update or delete on public.invoice_payments
for each row execute function public.qs_guard_invoice_receipt();
