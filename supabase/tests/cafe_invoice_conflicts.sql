begin;
set local statement_timeout='15s';
set local lock_timeout='3s';
do $$
declare tenant uuid; actor uuid; o uuid; linked uuid; inv uuid; total numeric; result jsonb; state jsonb;
 key uuid:=gen_random_uuid(); receipt_id uuid; n integer; candidate record;
begin
 select id into tenant from public.tenants where slug='quick-solution' and status='active';
 for candidate in select m.auth_user_id,u.email from public.tenant_memberships m join auth.users u on u.id=m.auth_user_id
   where m.tenant_id=tenant and m.status='active' and m.tenant_role in ('owner','admin') loop
   perform set_config('request.jwt.claim.sub',candidate.auth_user_id::text,true);
   perform set_config('request.jwt.claims',jsonb_build_object('sub',candidate.auth_user_id,'email',candidate.email,'role','authenticated')::text,true);
   if public.is_app_admin() or public.user_finance_level() in (1,2) then actor:=candidate.auth_user_id;exit;end if;
 end loop;
 if actor is null then raise exception 'Authorized invoice staff fixture unavailable'; end if;
 result:=public.create_quick_solution_counter_order(gen_random_uuid()::text,'scan','{"units":1}'::jsonb);
 o:=(result->>'orderId')::uuid;
 select total_amount into total from commerce.service_orders where id=o;
 result:=public.admin_send_quick_solution_order_to_opps(o);linked:=(result->>'oppsOrderId')::uuid;
 insert into public.opps_invoices(tenant_id,invoice_number,customer_name,invoice_date,source_order_id,total,status)
 values(tenant,'TEST-'||gen_random_uuid(),'Rollback shared invoice',current_date,linked,total,'approved') returning id into inv;
 -- Different currency blocks payment and synchronization.
 update public.opps_invoices set currency_code='USD' where id=inv;
 state:=public.qs_staff_payment_state(o);
 if not (state->'issues' ? 'invoice_total_or_currency_mismatch') then raise exception 'Currency mismatch missed';end if;
 begin perform public.qs_reconcile_invoice_receipts(o);raise exception 'Currency mismatch synced';
 exception when raise_exception then if sqlerrm<>'Payment records need reconciliation first' then raise;end if;end;
 update public.opps_invoices set currency_code='ZAR',status='draft' where id=inv;
 state:=public.qs_staff_payment_state(o);
 if not (state->'issues' ? 'invoice_not_approved') then raise exception 'Draft invoice missed';end if;
 update public.opps_invoices set status='approved' where id=inv;
 -- A competing invoice blocks both entry points.
 insert into public.opps_invoices(tenant_id,invoice_number,customer_name,invoice_date,source_order_id,total,status)
 values(tenant,'TEST-'||gen_random_uuid(),'Rollback competing invoice',current_date,linked,total,'approved');
 state:=public.qs_staff_payment_state(o);
 if not (state->'issues' ? 'multiple_linked_invoices') then raise exception 'Competing invoice missed';end if;
 begin perform public.qs_opps_record_staff_payment(linked,'cash',total,null,key);raise exception 'Competing invoice paid';
 exception when raise_exception then if sqlerrm<>'Payment records need reconciliation first' then raise;end if;end;
 begin perform public.record_manual_invoice_payment(inv,total,'CONFLICT',now(),'eft',null,key::text);raise exception 'Competing invoice entered';
 exception when raise_exception then if sqlerrm<>'Payment records need reconciliation first' then raise;end if;end;
 -- Independent invoice ledger insertion must not manufacture a Café receipt.
 begin
 insert into public.invoice_payments(invoice_id,amount,paid_at,method,source,order_id) values(inv,total,now(),'cash','manual',linked);
 raise exception 'Independent invoice receipt accepted';
 exception when insufficient_privilege then null;end;
end $$;
rollback;
select 'Invoice currency, draft, multiple-link and independent receipt guards passed; rolled back' result;
