begin;
set local statement_timeout='20s';
set local lock_timeout='3s';
do $$
declare tenant uuid; o uuid; linked uuid; inv uuid; total numeric; result jsonb; state jsonb;
 candidate record; provider_ref text:='TEST-PF-'||gen_random_uuid();
begin
 select id into tenant from public.tenants where slug='quick-solution' and status='active';
 for candidate in select m.auth_user_id,u.email from public.tenant_memberships m join auth.users u on u.id=m.auth_user_id
   where m.tenant_id=tenant and m.status='active' and m.tenant_role in ('owner','admin') loop
   perform set_config('request.jwt.claim.sub',candidate.auth_user_id::text,true);
   perform set_config('request.jwt.claims',jsonb_build_object('sub',candidate.auth_user_id,'email',candidate.email,'role','authenticated')::text,true);
   if public.is_app_admin() or public.user_finance_level() in (1,2) then exit;end if;
 end loop;
 result:=public.create_quick_solution_counter_order(gen_random_uuid()::text,'scan','{"units":1}'::jsonb);
 o:=(result->>'orderId')::uuid;
 select total_amount into total from commerce.service_orders where id=o;
 result:=public.admin_send_quick_solution_order_to_opps(o);linked:=(result->>'oppsOrderId')::uuid;
 insert into public.opps_invoices(tenant_id,invoice_number,customer_name,invoice_date,source_order_id,total,status)
 values(tenant,'TEST-'||gen_random_uuid(),'Rollback PayFast compatibility',current_date,linked,total,'approved') returning id into inv;
 result:=public.apply_invoice_payfast_payment(inv,total,provider_ref,'{"amount_fee":"0.50","amount_net":"4.50","signature":"TEST-SECRET"}');
 if not coalesce((result->>'ok')::boolean,false) or (result->>'balance_due')::numeric<>0 then raise exception 'Gateway settlement failed: %',result;end if;
 if exists(select 1 from commerce.service_order_payments where service_order_id=o and raw_itn ? 'signature') then raise exception 'Invoice callback retained raw signature';end if;
 result:=public.apply_invoice_payfast_payment(inv,total,provider_ref,'{}');
 if not coalesce((result->>'replayed')::boolean,false) then raise exception 'Gateway retry not replayed: %',result;end if;
 result:=public.apply_invoice_payfast_payment(inv,total,provider_ref||'-distinct','{}');
 if not coalesce((result->>'ignored')::boolean,false) then raise exception 'Settled invoice accepted another callback';end if;
 state:=public.qs_staff_payment_state(o);
 if (state->>'reviewRequired')::boolean or (state->>'balanceDue')::numeric<>0 then raise exception 'Shared gateway state disagrees: %',state;end if;
 if (select count(*) from commerce.service_order_payments where service_order_id=o and status='completed')<>1
 or (select count(*) from public.transactions where qs_service_order_id=o)<>1
 or (select count(*) from public.invoice_payments where invoice_id=inv and qs_payment_id is not null)<>1 then raise exception 'Gateway duplicate/missing projection';end if;
 begin perform public.qs_record_staff_payment(o,'cash',total,null,gen_random_uuid());raise exception 'Staff payment after gateway accepted';
 exception when raise_exception then if sqlerrm<>'This order cannot accept payment' then raise;end if;end;
 -- Counter entry before handoff publishes Finance once, then handoff links it.
 result:=public.create_quick_solution_counter_order(gen_random_uuid()::text,'scan','{"units":1}'::jsonb);o:=(result->>'orderId')::uuid;
 result:=public.record_quick_solution_counter_payment(o,'cash',gen_random_uuid()::text);
 if not coalesce((result->>'ok')::boolean,false) or (select count(*) from public.transactions where qs_service_order_id=o)<>1 then raise exception 'Counter projection missing: %',result;end if;
 result:=public.admin_send_quick_solution_order_to_opps(o);
 if (select count(*) from public.transactions where qs_service_order_id=o)<>1 then raise exception 'Handoff duplicated counter income';end if;
 -- An already-captured payment survives a draft/legacy projection conflict and is review-blocked.
 result:=public.create_quick_solution_counter_order(gen_random_uuid()::text,'scan','{"units":1}'::jsonb);o:=(result->>'orderId')::uuid;
 select total_amount into total from commerce.service_orders where id=o;
 result:=public.admin_send_quick_solution_order_to_opps(o);linked:=(result->>'oppsOrderId')::uuid;
 insert into public.opps_invoices(tenant_id,invoice_number,customer_name,invoice_date,source_order_id,total,status)
 values(tenant,'TEST-'||gen_random_uuid(),'Rollback gateway projection review',current_date,linked,total,'draft') returning id into inv;
 result:=commerce.qs_apply_payfast_payment(o,total,'TEST-PF-REVIEW-'||gen_random_uuid(),'{}');
 state:=public.qs_staff_payment_state(o);
 if not coalesce((result->>'projectionReviewRequired')::boolean,false)
 or not (state->'issues' ? 'gateway_projection_review_required')
 or (select count(*) from commerce.service_order_payments where service_order_id=o and status='completed')<>1 then raise exception 'Captured receipt review missing: % / %',result,state;end if;
 if exists(select 1 from public.invoice_payments where invoice_id=inv) then raise exception 'Draft invoice received projection';end if;
 -- Ordinary invoices retain partial PayFast settlement, without creating Cafe money.
 insert into public.opps_invoices(tenant_id,invoice_number,customer_name,invoice_date,total,status)
 values(tenant,'TEST-'||gen_random_uuid(),'Rollback ordinary invoice',current_date,10,'approved') returning id into inv;
 result:=public.apply_invoice_payfast_payment(inv,3,'TEST-ORDINARY-'||gen_random_uuid(),'{}');
 if not coalesce((result->>'ok')::boolean,false) or public.invoice_balance_due(inv)<>7 then raise exception 'Ordinary partial gateway behavior changed: %',result;end if;
 if has_function_privilege('authenticated','commerce.qs_apply_invoice_payfast_payment(uuid,uuid,numeric,text,jsonb)','execute')
 or has_function_privilege('anon','commerce.qs_apply_invoice_payfast_payment(uuid,uuid,numeric,text,jsonb)','execute') then raise exception 'Gateway private helper exposed';end if;
end $$;
rollback;
select 'PASS: invoice PayFast capture/retry, one original/Finance/invoice, staff duplicate blocked; counter Finance before handoff remains single; rolled back' result;
