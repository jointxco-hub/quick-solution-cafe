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
 begin perform public.record_manual_invoice_payment(inv,total,null,now(),'eft',null,key::text);raise exception 'Missing EFT ref accepted';
 exception when raise_exception then if sqlerrm<>'Verified EFT reference required' then raise;end if;end;
 begin perform public.record_manual_invoice_payment(inv,total/2,'STAGING-EFT',now(),'eft',null,key::text);raise exception 'Partial accepted';
 exception when raise_exception then if sqlerrm<>'Record the full current outstanding balance' then raise;end if;end;
 begin perform public.record_manual_invoice_payment(inv,total,'STAGING-EFT',now()-interval '10 days','eft',null,key::text);raise exception 'Backdated receipt accepted';
 exception when raise_exception then if sqlerrm<>'INVOICE_PAYMENT_CAFE_CURRENT_DATE_REQUIRED' then raise;end if;end;
 result:=public.record_manual_invoice_payment(inv,total,'STAGING-EFT',now(),'eft','Rollback only',key::text);
 if not (result->>'ok')::boolean or (result->'projection'->>'balance_due')::numeric<>0 then raise exception 'Invoice EFT failed: %',result;end if;
 result:=public.record_manual_invoice_payment(inv,total,'STAGING-EFT',now(),'eft','Rollback only',key::text);
 if not (result->>'replayed')::boolean then raise exception 'Invoice EFT retry duplicated';end if;
 begin perform public.record_manual_invoice_payment(inv,total,'CHANGED',now(),'eft',null,key::text);raise exception 'Changed retry accepted';
 exception when raise_exception then if sqlerrm<>'Payment retry details differ from the saved receipt' then raise;end if;end;
 state:=public.qs_staff_payment_state(o);
 if (state->>'balanceDue')::numeric<>0 or (state->>'cafePaid')::numeric<>total or (state->>'oppsPaid')::numeric<>total or (state->>'invoicePaid')::numeric<>total then raise exception 'Balances disagree: %',state;end if;
 execute 'reset role';
 if (select count(*) from public.invoice_payments where invoice_id=inv)<>1 or (select count(*) from public.transactions where qs_service_order_id=o)<>1 then raise exception 'Duplicate projection';end if;
 -- Unrelated invoices retain their existing payment behavior.
 insert into public.opps_invoices(tenant_id,invoice_number,customer_name,invoice_date,total,status)
 values(tenant,'TEST-'||gen_random_uuid(),'Rollback ordinary invoice',current_date,10,'approved') returning id into inv;
 execute 'set local role authenticated';
 result:=public.record_manual_invoice_payment(inv,3,null,now(),'cash',null,gen_random_uuid()::text);
 if (result->'projection'->>'balance_due')::numeric<>7 then raise exception 'Ordinary partial behavior changed';end if;
 execute 'reset role';
end $$;
rollback;
select 'Invoice EFT entry, references, retry identity, shared balances and ordinary partial regression passed; rolled back' result;
