-- Staging slice: receipt identity across Café, Finance and one linked invoice.
-- Original receipts remain commerce.service_order_payments. Invoice rows are projections.
alter table public.invoice_payments add column qs_payment_id uuid references commerce.service_order_payments(id);
create unique index invoice_payments_qs_receipt_once on public.invoice_payments(qs_payment_id) where qs_payment_id is not null;
create index if not exists opps_invoices_source_order_lookup on public.opps_invoices(source_order_id,tenant_id) where source_order_id is not null;

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

-- Exact receipt matching prevents forged money; direct ledger rows for Café are refused.
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
     or r.status<>'completed' or new.source<>'order_sync' or new.amount is distinct from r.amount
     or new.method is distinct from r.provider or new.reference is distinct from r.staff_reference
     or new.paid_at is distinct from r.completed_at or new.order_id is distinct from inv.source_order_id
     or inv.status in ('draft','void') then raise exception 'Invalid Cafe invoice receipt projection'; end if;
 end if;
 return new;
end $$;
revoke all on function public.qs_guard_invoice_receipt() from public,anon,authenticated;

-- A receipt-bearing invoice cannot be detached, repriced or voided outside correction review.
create or replace function public.qs_guard_invoice_receipt_link() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.invoice_payments where invoice_id=old.id and qs_payment_id is not null)
   and (new.id is distinct from old.id or new.source_order_id is distinct from old.source_order_id
     or new.tenant_id is distinct from old.tenant_id or new.total is distinct from old.total
     or new.currency_code is distinct from old.currency_code or new.status in ('void','draft')) then
   raise exception 'Shared Cafe invoice receipts require review before changing this invoice';
 end if;
 return new;
end $$;
revoke all on function public.qs_guard_invoice_receipt_link() from public,anon,authenticated;
create trigger qs_guard_invoice_receipt_link before update on public.opps_invoices
for each row execute function public.qs_guard_invoice_receipt_link();

create or replace function commerce.qs_project_invoice_receipts(p_order_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare o commerce.service_orders; inv public.opps_invoices; issues jsonb; r commerce.service_order_payments; row_id uuid;
begin
 select * into o from commerce.service_orders where id=p_order_id for update;
 if o.id is null then raise exception 'Cafe order unavailable'; end if;
 if o.opps_order_id is null then return; end if;
 -- Serialize all receipt writers on the service order before locking the invoice.
 perform 1 from public.opps_invoices where source_order_id=o.opps_order_id and tenant_id=o.tenant_id order by id for update;
 issues:=commerce.qs_invoice_payment_issues(o.id)-'invoice_projection_missing';
 if jsonb_array_length(issues)>0 then raise exception 'Linked invoice requires reconciliation: %',issues; end if;
 select * into inv from public.opps_invoices where source_order_id=o.opps_order_id and tenant_id=o.tenant_id and status<>'void';
 if inv.id is null then return; end if;
 if (select coalesce(sum(amount),0) from commerce.service_order_payments where service_order_id=o.id and status='completed')>inv.total then
   raise exception 'Cafe receipts exceed the invoice total';
 end if;
 for r in select * from commerce.service_order_payments where service_order_id=o.id and tenant_id=o.tenant_id and status='completed' order by completed_at,id loop
   if not exists(select 1 from public.invoice_payments where qs_payment_id=r.id and invoice_id=inv.id) then
     insert into public.invoice_payments(tenant_id,invoice_id,amount,paid_at,method,reference,source,order_id,qs_payment_id,created_by,metadata)
     values(o.tenant_id,inv.id,r.amount,r.completed_at,r.provider,r.staff_reference,'order_sync',o.opps_order_id,r.id,r.recorded_by,
       jsonb_build_object('recorded_via','cafe_shared_receipt','service_order_id',o.id)) returning id into row_id;
     insert into public.opps_invoice_activity(invoice_id,tenant_id,activity_type,activity_label,metadata,created_by)
       values(inv.id,o.tenant_id,'invoice_payment_recorded','Shared Cafe receipt linked',
       jsonb_build_object('payment_id',row_id,'receipt_id',r.id,'amount',r.amount,'source','order_sync'),auth.uid());
   end if;
 end loop;
 update public.opps_invoices set status=case when public.invoice_payment_status(inv.id)='paid' then 'paid'
   when public.invoice_payment_status(inv.id)='partial' then 'partially_paid' else status end,updated_by=auth.uid()
   where id=inv.id and status in ('approved','partially_paid','overdue');
end $$;
revoke all on function commerce.qs_project_invoice_receipts(uuid) from public,anon,authenticated;

-- Preserve existing finance behavior; invoice projection is in the same transaction.
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
  perform commerce.qs_project_invoice_receipts(o.id);
end $$;
revoke all on function commerce.qs_project_manual_receipt(uuid) from public,anon,authenticated;


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
      problems:=problems||commerce.qs_invoice_payment_issues(o.id);
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

-- Explicit receipt synchronization can be retried without creating a payment.
create or replace function public.qs_reconcile_invoice_receipts(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare state jsonb;
begin
 state:=public.qs_staff_payment_state(p_order_id);
 perform 1 from commerce.service_orders where id=p_order_id for update;
 state:=public.qs_staff_payment_state(p_order_id);
 if jsonb_array_length((state->'issues')-'invoice_projection_missing')>0 then
   raise exception 'Payment records need reconciliation first';
 end if;
 perform commerce.qs_project_invoice_receipts(p_order_id);
 return public.qs_staff_payment_state(p_order_id);
end $$;
revoke all on function public.qs_reconcile_invoice_receipts(uuid) from public,anon;
grant execute on function public.qs_reconcile_invoice_receipts(uuid) to authenticated;

-- Invoice entry delegates to the same checked full-balance writer, under the same lock.
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

create or replace function public.record_manual_invoice_payment(
  p_invoice_id    uuid,
  p_amount        numeric,
  p_reference     text        default null,
  p_paid_at       timestamptz default now(),
  p_method        text        default 'eft',
  p_note          text        default null,
  p_operation_key text        default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public
as $$
declare
  v_invoice       public.opps_invoices%rowtype;
  v_user_id       uuid := auth.uid();
  v_amount        numeric(14,2);
  v_ref           text := nullif(btrim(p_reference), '');
  v_opkey         text := nullif(btrim(p_operation_key), '');
  v_note          text := nullif(btrim(coalesce(p_note, '')), '');
  v_method        text := lower(nullif(btrim(p_method), ''));
  v_paid_at       timestamptz := coalesce(p_paid_at, now());
  v_existing      public.invoice_payments%rowtype;
  v_paid          numeric(14,2);
  v_total         numeric(14,2);
  v_row_id        uuid;
  v_status_after     text;
  v_new_status       text;
  v_effective_status text;
  v_proof_count      integer := 0;
  v_has_unreconciled boolean := false;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'INVOICE_PAYMENT_AUTH_REQUIRED';
  end if;

  if exists(select 1 from public.opps_invoices i join public.orders o on o.id=i.source_order_id
    where i.id=p_invoice_id and o.source='quick_solution') then
    return commerce.qs_record_invoice_payment(p_invoice_id,p_amount,p_reference,p_paid_at,p_method,p_note,p_operation_key);
  end if;

  select * into v_invoice from public.opps_invoices where id = p_invoice_id for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'INVOICE_NOT_FOUND';
  end if;

  if not public.can_access_tenant(v_invoice.tenant_id)
     or not (public.is_app_admin() or public.user_finance_level() in (1, 2))
  then
    raise exception using errcode = 'P0001', message = 'INVOICE_PAYMENT_ACCESS_DENIED';
  end if;

  if v_invoice.status = 'draft' then
    raise exception using errcode = 'P0001', message = 'INVOICE_PAYMENT_INVOICE_NOT_APPROVED';
  end if;
  if v_invoice.status = 'void' then
    raise exception using errcode = 'P0001', message = 'INVOICE_PAYMENT_INVOICE_VOID';
  end if;

  if p_amount is null then
    raise exception using errcode = 'P0001', message = 'INVOICE_PAYMENT_AMOUNT_REQUIRED';
  end if;
  v_amount := round(p_amount, 2);
  if v_amount <= 0 then
    raise exception using errcode = 'P0001', message = 'INVOICE_PAYMENT_AMOUNT_INVALID';
  end if;
  if v_amount <> round(p_amount, 6) then
    raise exception using errcode = 'P0001', message = 'INVOICE_PAYMENT_AMOUNT_PRECISION';
  end if;

  -- a stable client operation key is mandatory (reuse it across retries);
  -- the external reference stays optional and is never fabricated.
  if v_opkey is null then
    raise exception using errcode = 'P0001',
      message = 'INVOICE_PAYMENT_OPERATION_KEY_REQUIRED: a stable client operation key is required and must be reused on retry';
  end if;

  -- ── (1) operation-key match: the retry-safe replay path ─────────
  select * into v_existing
  from public.invoice_payments
  where invoice_id = p_invoice_id and source = 'manual' and client_operation_key = v_opkey
  limit 1;
  if found then
    perform public._assert_manual_payment_matches(v_existing, v_amount, v_paid_at, v_method, v_ref, v_opkey);
    v_proof_count := public._link_staged_payment_attachments(p_invoice_id, v_opkey, v_existing.id, v_invoice.tenant_id);
    return jsonb_build_object(
      'ok', true, 'replayed', true, 'payment_id', v_existing.id,
      'proof_linked', v_proof_count,
      'projection', public._invoice_payment_projection(p_invoice_id));
  end if;

  -- ── (2) reference reused by a DIFFERENT operation → hard conflict ─
  -- (never a silent replay, never a proof attach onto an unrelated row)
  if v_ref is not null and exists (
    select 1 from public.invoice_payments
    where invoice_id = p_invoice_id and source = 'manual' and reference = v_ref
  ) then
    raise exception using errcode = 'P0001',
      message = 'INVOICE_PAYMENT_IDEMPOTENCY_CONFLICT: this reference is already recorded on this invoice under a different operation — reload before recording another payment';
  end if;

  -- ── cross-source safeguard (fail closed on a missing bridge) ────
  if v_invoice.source_order_id is not null then
    begin
      select exists (
        select 1
        from public.xlab_payments xp
        join public.xlab_orders xo on xp.order_id = xo.id
        where xp.status = 'completed'
          and (
            -- xlab_orders.opps_order_id is TEXT; source_order_id is UUID.
            xo.opps_order_id = v_invoice.source_order_id::text
            or (xo.opps_order_number is not null
                and xo.opps_order_number = (select order_number from public.orders where id = v_invoice.source_order_id))
          )
          and not exists (
            select 1 from public.invoice_payments ip
            where ip.invoice_id = p_invoice_id and ip.xlab_payment_id = xp.id
          )
      ) into v_has_unreconciled;
    exception when undefined_table or undefined_column then
      raise exception using errcode = 'P0001',
        message = 'INVOICE_PAYMENT_BRIDGE_SCHEMA_MISSING: the order/payment bridge schema needed to check for existing platform payments on this order-linked invoice is absent or incompatible — resolve the sync schema before recording a manual payment';
    end;
    if v_has_unreconciled then
      raise exception using errcode = 'P0001',
        message = 'INVOICE_PAYMENT_UNRECONCILED_ORDER_PAYMENT: the linked order has a completed platform payment not yet folded into this invoice — run the linked-order reconciliation first, then record only the outstanding amount';
    end if;
  end if;

  -- ── overpayment guard (ledger-derived, ±R0.02 tolerance) ────────
  v_paid  := public.invoice_amount_paid(p_invoice_id);
  v_total := round(coalesce(v_invoice.total, 0), 2);
  if v_paid + v_amount > v_total + 0.02 then
    raise exception using errcode = 'P0001',
      message = format('INVOICE_PAYMENT_OVERPAYMENT: %s already recorded + %s would exceed the invoice total %s',
                       v_paid, v_amount, v_total);
  end if;

  -- ── insert the one auditable ledger row ────────────────────────
  begin
    insert into public.invoice_payments (
      invoice_id, amount, paid_at, method, reference, source, order_id,
      created_by, client_operation_key, metadata
    ) values (
      p_invoice_id, v_amount, v_paid_at,
      coalesce(v_method, 'eft'), v_ref, 'manual',
      v_invoice.source_order_id, v_user_id, v_opkey,
      jsonb_strip_nulls(jsonb_build_object(
        'note', v_note, 'recorded_via', 'record_manual_invoice_payment'
      ))
    )
    returning id into v_row_id;
  exception when unique_violation then
    -- a concurrent request won a race. Identify the ACTUAL conflicting
    -- row and validate it before returning replayed=true.
    select * into v_existing
    from public.invoice_payments
    where invoice_id = p_invoice_id and source = 'manual' and client_operation_key = v_opkey
    limit 1;
    if v_existing.id is not null then
      perform public._assert_manual_payment_matches(v_existing, v_amount, v_paid_at, v_method, v_ref, v_opkey);
      v_proof_count := public._link_staged_payment_attachments(p_invoice_id, v_opkey, v_existing.id, v_invoice.tenant_id);
      return jsonb_build_object(
        'ok', true, 'replayed', true, 'payment_id', v_existing.id,
        'proof_linked', v_proof_count,
        'projection', public._invoice_payment_projection(p_invoice_id));
    end if;
    if v_ref is not null and exists (
      select 1 from public.invoice_payments
      where invoice_id = p_invoice_id and source = 'manual' and reference = v_ref
    ) then
      raise exception using errcode = 'P0001',
        message = 'INVOICE_PAYMENT_IDEMPOTENCY_CONFLICT: this reference is already recorded on this invoice under a different operation';
    end if;
    raise;  -- unknown unique_violation → propagate
  end;

  -- ── compat status mirror (safe payment-cycle transitions only) ──
  v_status_after     := public.invoice_payment_status(p_invoice_id);
  v_effective_status := v_invoice.status;
  if v_invoice.status in ('approved', 'partially_paid') then
    v_new_status := case v_status_after
                      when 'paid'    then 'paid'
                      when 'partial' then 'partially_paid'
                      else null
                    end;
  elsif v_invoice.status = 'overdue' and v_status_after = 'paid' then
    v_new_status := 'paid';
  end if;
  if v_new_status is not null and v_new_status is distinct from v_invoice.status then
    update public.opps_invoices
       set status = v_new_status, updated_by = v_user_id
     where id = p_invoice_id;
    v_effective_status := v_new_status;
  end if;

  -- ── link staged proof-of-payment files (same transaction) ───────
  v_proof_count := public._link_staged_payment_attachments(p_invoice_id, v_opkey, v_row_id, v_invoice.tenant_id);

  -- ── canonical payment audit event (same transaction) ───────────
  insert into public.opps_invoice_activity (
    invoice_id, tenant_id, activity_type, activity_label, activity_note,
    from_status, to_status, metadata, created_by
  ) values (
    p_invoice_id, v_invoice.tenant_id,
    'invoice_payment_recorded', 'Payment recorded',
    format('%s %s%s',
           coalesce(v_method, 'eft'),
           to_char(v_amount, 'FM999999999990.00'),
           case when v_ref is not null then ' · ref ' || v_ref else '' end),
    v_invoice.status,
    v_effective_status,
    jsonb_strip_nulls(jsonb_build_object(
      'payment_id',     v_row_id,
      'amount',         v_amount,
      'source',         'manual',
      'method',         coalesce(v_method, 'eft'),
      'reference',      v_ref,
      'operation_key',  v_opkey,
      'paid_at',        v_paid_at,
      'note',           v_note,
      'actor',          v_user_id,
      'proof_count',    v_proof_count,
      'payment_status', v_status_after,
      'amount_paid',    public.invoice_amount_paid(p_invoice_id),
      'balance_due',    public.invoice_balance_due(p_invoice_id)
    )),
    v_user_id
  );

  return jsonb_build_object(
    'ok', true, 'replayed', false, 'payment_id', v_row_id,
    'proof_linked', v_proof_count,
    'projection', public._invoice_payment_projection(p_invoice_id));
end;
$$;

revoke all on function public.record_manual_invoice_payment(uuid, numeric, text, timestamptz, text, text, text) from public, anon;
grant execute on function public.record_manual_invoice_payment(uuid, numeric, text, timestamptz, text, text, text) to authenticated;

