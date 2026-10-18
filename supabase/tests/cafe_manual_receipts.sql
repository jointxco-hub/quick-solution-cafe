begin;
do $$
declare t uuid; a uuid; o uuid; k uuid:=gen_random_uuid(); result jsonb; amount numeric; tx uuid; linked uuid; eft_order uuid; invoice uuid;
begin
 select id into t from public.tenants where slug='quick-solution' and status='active';
 select auth_user_id into a from public.tenant_memberships where tenant_id=t and status='active' and tenant_role in ('owner','admin') and auth_user_id is not null limit 1;
 perform set_config('request.jwt.claim.sub',a::text,true);
 result:=public.create_quick_solution_counter_order(gen_random_uuid()::text,'scan','{"units":1}'::jsonb);
 o:=(result->>'orderId')::uuid;
 select total_amount into amount from commerce.service_orders where id=o;
 if o is null then raise exception 'Order fixture missing'; end if;

 begin perform public.qs_record_staff_payment(o,'cash',amount+1,null,gen_random_uuid()); raise exception 'Overpayment accepted'; exception when raise_exception then if sqlerrm<>'Record the full current outstanding balance' then raise; end if; end;
 insert into commerce.service_order_payments(tenant_id,service_order_id,provider,status,amount) values(t,o,'payfast','pending',amount);
 begin perform public.qs_record_staff_payment(o,'cash',amount,null,gen_random_uuid()); raise exception 'Pending gateway accepted'; exception when raise_exception then if sqlerrm not like 'An online payment is pending.%' then raise; end if; end;
 delete from commerce.service_order_payments where service_order_id=o and provider='payfast' and status='pending';
 result:=public.qs_record_staff_payment(o,'cash',amount,null,k);
 if (result->>'replayed')::boolean then raise exception 'First receipt replayed'; end if;
 select id into tx from public.transactions where qs_service_order_id=o;
 if tx is null or (select tr.amount from public.transactions tr where id=tx)<>amount then raise exception 'Finance receipt missing'; end if;
 if (select opps_order_id from commerce.service_orders where id=o) is not null then raise exception 'Payment created production job'; end if;
 result:=public.qs_record_staff_payment(o,'cash',amount,null,k);
 if not (result->>'replayed')::boolean then raise exception 'Retry failed'; end if;
 begin perform public.qs_record_staff_payment(o,'cash',amount+1,null,k); raise exception 'Changed retry accepted'; exception when raise_exception then if sqlerrm='Changed retry accepted' then raise; end if; end;
 begin perform public.qs_record_staff_payment(o,'cash',amount,null,gen_random_uuid()); raise exception 'Duplicate accepted'; exception when raise_exception then if sqlerrm='Duplicate accepted' then raise; end if; end;
 result:=public.admin_send_quick_solution_order_to_opps(o);
 linked:=(result->>'oppsOrderId')::uuid;
 if linked is null then raise exception 'Handoff failed: %', result; end if;
 if (select count(*) from public.transactions where qs_service_order_id=o or order_id=linked)<>1 then raise exception 'Duplicate Finance receipt after handoff'; end if;
 if (select order_id from public.transactions where id=tx)<>linked then raise exception 'Original Finance receipt not linked'; end if;
 if (public.qs_staff_payment_state(o)->>'reviewRequired')::boolean then raise exception 'Paid balances mismatch'; end if;
 insert into public.opps_invoices(tenant_id,invoice_number,customer_name,invoice_date,source_order_id,total,status)
 values(t,'TEST-'||gen_random_uuid(),'Rollback receipt test',current_date,linked,amount,'approved') returning id into invoice;
 begin
   insert into public.invoice_payments(tenant_id,invoice_id,amount,method,source,order_id,created_by,client_operation_key)
   values(t,invoice,amount,'eft','manual',linked,a,gen_random_uuid()::text);
   raise exception 'Duplicate invoice receipt accepted';
 exception when raise_exception then
   if sqlerrm not like 'Cafe receipt already exists.%' then raise; end if;
 end;
 begin
   execute 'set local role authenticated';
   update public.transactions set amount=public.transactions.amount+1 where id=tx;
   raise exception 'Direct projection edit accepted';
 exception when insufficient_privilege then null;
 end;
 execute 'reset role';
 result:=public.create_quick_solution_counter_order(gen_random_uuid()::text,'scan','{"units":1}'::jsonb);
 eft_order:=(result->>'orderId')::uuid;
 begin perform public.qs_record_staff_payment(eft_order,'eft',amount,null,gen_random_uuid()); raise exception 'EFT without reference'; exception when raise_exception then if sqlerrm='EFT without reference' then raise; end if; end;
 perform public.qs_record_staff_payment(eft_order,'eft',amount,'rollback-test',gen_random_uuid());
 perform public.qs_staff_quick_job(eft_order,'ready');
 result:=public.qs_staff_quick_job(eft_order,'collected');
 if result->>'status'<>'completed' then raise exception 'Paid collection failed'; end if;
 if (select count(*) from commerce.service_order_payments where service_order_id=o and status='completed')<>1 then raise exception 'Duplicate receipt'; end if;
 perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
 begin perform public.qs_record_staff_payment(o,'cash',amount,null,k); raise exception 'Unauthorized replay'; exception when insufficient_privilege then null; end;
 if has_function_privilege('anon','public.qs_record_staff_payment(uuid,text,numeric,text,uuid)','execute') then raise exception 'Anonymous grant'; end if;
end $$;
rollback;
select 'Cash/EFT, retry, Finance before handoff, same-row handoff and paid collection passed; rolled back' as result;
