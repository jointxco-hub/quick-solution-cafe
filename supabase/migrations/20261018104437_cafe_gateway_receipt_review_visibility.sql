-- Keep captured gateway receipts visible when a legacy projection requires review.
-- Invoice callbacks retain only the existing fee metadata allowlist.
create or replace function commerce.qs_apply_invoice_payfast_payment(
 p_invoice_id uuid,p_order_id uuid,p_amount numeric,p_pf_payment_id text,p_raw_itn jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare o commerce.service_orders; inv public.opps_invoices; result jsonb; payment_id uuid;
begin
 if coalesce(auth.role(),'')<>'service_role' and session_user not in ('postgres','supabase_admin') then
  raise exception using errcode='42501',message='Trusted backend access is required.';
 end if;
 select * into o from commerce.service_orders where id=p_order_id for update;
 select * into inv from public.opps_invoices where id=p_invoice_id for update;
 if o.id is null or inv.id is null or inv.source_order_id is distinct from o.opps_order_id
   or inv.tenant_id is distinct from o.tenant_id then
  return jsonb_build_object('ok',false,'reason','CAFE_INVOICE_LINK_REVIEW_REQUIRED');
 end if;
 if (select count(*) from commerce.service_orders where opps_order_id=o.opps_order_id and tenant_id=o.tenant_id)<>1
   or not exists(select 1 from public.orders where id=o.opps_order_id and tenant_id=o.tenant_id and source='quick_solution') then
  return jsonb_build_object('ok',false,'reason','CAFE_INVOICE_LINK_REVIEW_REQUIRED');
 end if;
 if inv.status='void' then return jsonb_build_object('ok',false,'reason','INVOICE_VOID'); end if;
 if nullif(btrim(p_pf_payment_id),'') is null then return jsonb_build_object('ok',false,'reason','PF_PAYMENT_ID_REQUIRED'); end if;
 if p_amount is null or p_amount<=0 then return jsonb_build_object('ok',false,'reason','AMOUNT_INVALID'); end if;
 select ip.id into payment_id from public.invoice_payments ip join commerce.service_order_payments r on r.id=ip.qs_payment_id
  where ip.invoice_id=inv.id and r.service_order_id=o.id and r.provider='payfast' and r.pf_payment_id=btrim(p_pf_payment_id);
 if payment_id is not null then
  return jsonb_build_object('ok',true,'replayed',true,'payment_id',payment_id,'amount_paid',public.invoice_amount_paid(inv.id),
   'balance_due',public.invoice_balance_due(inv.id),'payment_status',public.invoice_payment_status(inv.id));
 end if;
 if public.invoice_payment_status(inv.id)='paid' or public.invoice_balance_due(inv.id)<=0 then
  return jsonb_build_object('ok',true,'ignored',true,'reason','INVOICE_ALREADY_PAID',
   'amount_paid',public.invoice_amount_paid(inv.id),'balance_due',public.invoice_balance_due(inv.id),'payment_status',public.invoice_payment_status(inv.id));
 end if;
 -- A Cafe invoice cannot independently accept a partial settlement of its order.
 if round(p_amount,2) is distinct from o.total_amount or inv.total is distinct from o.total_amount or inv.currency_code is distinct from 'ZAR' then
  return jsonb_build_object('ok',false,'reason','CAFE_INVOICE_AMOUNT_REVIEW_REQUIRED','expected',o.total_amount,'received',round(p_amount,2));
 end if;
 result:=commerce.qs_apply_payfast_payment(o.id,p_amount,p_pf_payment_id,jsonb_strip_nulls(jsonb_build_object(
  'amount_fee',p_raw_itn->>'amount_fee','amount_net',p_raw_itn->>'amount_net')));
 if not coalesce((result->>'ok')::boolean,false) then return result; end if;
 select ip.id into payment_id from public.invoice_payments ip join commerce.service_order_payments r on r.id=ip.qs_payment_id
  where ip.invoice_id=inv.id and r.service_order_id=o.id and r.provider='payfast' and r.pf_payment_id=btrim(p_pf_payment_id);
 return result||jsonb_build_object('payment_id',payment_id,'amount_paid',public.invoice_amount_paid(inv.id),
  'balance_due',public.invoice_balance_due(inv.id),'payment_status',public.invoice_payment_status(inv.id));
end $$;
revoke all on function commerce.qs_apply_invoice_payfast_payment(uuid,uuid,numeric,text,jsonb) from public,anon,authenticated;


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
  if coalesce((o.source_metadata->'paymentProjectionReview'->>'required')::boolean,false) then
    problems:=problems || '"gateway_projection_review_required"'::jsonb;
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

