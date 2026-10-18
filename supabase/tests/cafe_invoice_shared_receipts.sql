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
 execute 'set local role authenticated';
 state:=public.qs_staff_payment_state(o);
 if (state->>'reviewRequired')::boolean then raise exception 'Fresh invoice unexpectedly blocked: %',state; end if;
 result:=public.qs_opps_record_staff_payment(linked,'cash',total,null,key); receipt_id:=(result->>'receiptId')::uuid;
 state:=public.qs_staff_payment_state(o);
 if (state->>'reviewRequired')::boolean or (state->>'invoicePaid')::numeric<>total or (state->>'balanceDue')::numeric<>0 then
   raise exception 'Shared balances disagree: %',state;end if;
 result:=public.qs_reconcile_invoice_receipts(o);
 result:=public.qs_opps_record_staff_payment(linked,'cash',total,null,key);
 if not (result->>'replayed')::boolean then raise exception 'Retry not replayed';end if;
 execute 'reset role';
 select count(*) into n from public.invoice_payments where invoice_id=inv and qs_payment_id=receipt_id;
 if n<>1 or public.invoice_balance_due(inv)<>0 then raise exception 'Duplicate/missing invoice receipt';end if;
 if (select count(*) from public.transactions where qs_service_order_id=o)<>1 then raise exception 'Finance duplicate';end if;
 if (select count(*) from commerce.service_order_payments where service_order_id=o and status='completed')<>1 then raise exception 'Original receipt duplicate';end if;
 begin update public.opps_invoices set total=opps_invoices.total+1 where id=inv;raise exception 'Invoice price changed after receipt';
 exception when raise_exception then if sqlerrm<>'Shared Cafe invoice receipts require review before changing this invoice' then raise;end if;end;
 begin update public.invoice_payments set amount=amount+1 where invoice_id=inv;raise exception 'Invoice projection edited';
 exception when raise_exception then if sqlerrm<>'Shared Cafe receipts require an audited correction; invoice projections cannot be edited or deleted' then raise;end if;end;
 begin
   perform public.record_manual_invoice_payment(inv,total,'DUPLICATE',now(),'eft',null,gen_random_uuid()::text);
   raise exception 'Second invoice payment accepted';
 exception when raise_exception then if sqlerrm not like '%cannot accept payment%' then raise;end if;end;
end $$;
rollback;
select 'Invoice-first linked Cash: one receipt, one Finance row, one invoice row, matching balances and retries; rolled back' result;
