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
 execute 'set local role authenticated';
 result:=public.qs_opps_record_staff_payment(linked,'cash',total,null,key);
 execute 'reset role';
 insert into public.opps_invoices(tenant_id,invoice_number,customer_name,invoice_date,source_order_id,total,status)
 values(tenant,'TEST-'||gen_random_uuid(),'Rollback receipt before invoice',current_date,linked,total,'approved') returning id into inv;
 execute 'set local role authenticated';
 state:=public.qs_staff_payment_state(o);
 if not (state->'issues' ? 'invoice_projection_missing') then raise exception 'Missing projection not identified';end if;
 result:=public.qs_reconcile_invoice_receipts(o);
 if (result->>'reviewRequired')::boolean or (result->>'balanceDue')::numeric<>0 then raise exception 'Receipt sync failed: %',result;end if;
 result:=public.qs_reconcile_invoice_receipts(o);
 execute 'reset role';
 if (select count(*) from public.invoice_payments where invoice_id=inv)<>1 or (select count(*) from commerce.service_order_payments where service_order_id=o and status='completed')<>1 then raise exception 'Sync created a duplicate receipt';end if;
 -- Matching amounts without a Finance receipt identity still require review.
 update public.transactions set qs_service_order_id=null where qs_service_order_id=o;
 state:=public.qs_staff_payment_state(o);
 if not (state->'issues' ? 'finance_receipt_identity_missing') then raise exception 'Legacy Finance identity missed';end if;
 begin perform public.qs_reconcile_invoice_receipts(o);raise exception 'Legacy receipt silently linked';
 exception when raise_exception then if sqlerrm<>'Payment records need reconciliation first' then raise;end if;end;
 perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
 perform set_config('request.jwt.claims','{}',true);
 execute 'set local role authenticated';
 begin perform public.qs_reconcile_invoice_receipts(o);raise exception 'Nonmember sync accepted';
 exception when insufficient_privilege then null;end;
 execute 'reset role';
 if has_function_privilege('anon','public.qs_reconcile_invoice_receipts(uuid)','execute')
 or has_function_privilege('authenticated','commerce.qs_project_invoice_receipts(uuid)','execute')
 or has_function_privilege('authenticated','commerce.qs_record_invoice_payment(uuid,numeric,text,timestamptz,text,text,text)','execute') then raise exception 'Unsafe grants';end if;
end $$;
rollback;
select 'Existing receipt sync is idempotent, creates no money, denies nonmembers and protects private helpers; rolled back' result;
