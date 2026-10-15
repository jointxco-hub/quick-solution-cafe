begin;
set local statement_timeout='15s';
set local lock_timeout='3s';
do $$
declare tenant uuid; actor uuid; o uuid; linked uuid; paid numeric; result jsonb; state jsonb;
  key uuid:=gen_random_uuid(); receipt_id uuid; tx_id uuid; unpaid uuid; unpaid_link uuid; invoice_id uuid; member_id uuid;
begin
 select id into tenant from public.tenants where slug='quick-solution' and status='active';
 select auth_user_id into actor from public.tenant_memberships where tenant_id=tenant and status='active'
   and tenant_role in ('owner','admin') and auth_user_id is not null limit 1;
 if actor is null then raise exception 'Staff fixture unavailable'; end if;
 perform set_config('request.jwt.claim.sub',actor::text,true);
 if not public.has_tenant_permission(tenant,'payments.manage') then raise exception 'Payment permission fixture missing'; end if;
 result:=public.create_quick_solution_counter_order(gen_random_uuid()::text,'scan','{"units":1}'::jsonb);
 o:=(result->>'orderId')::uuid;
 select total_amount into paid from commerce.service_orders where id=o;
 result:=public.admin_send_quick_solution_order_to_opps(o); linked:=(result->>'oppsOrderId')::uuid;
 if linked is null then raise exception 'Handoff fixture failed: %',result; end if;
 state:=public.qs_opps_staff_payment_state(linked);
 if (state->>'orderId')::uuid<>o or (state->>'balanceDue')::numeric<>paid then raise exception 'Wrong linked payment state: %',state; end if;

 begin perform public.qs_opps_record_staff_payment(linked,'eft',paid,null,gen_random_uuid()); raise exception 'Missing reference accepted';
 exception when raise_exception then if sqlerrm<>'Verified EFT reference required' then raise; end if; end;
 execute 'set local role authenticated';
 result:=public.qs_opps_record_staff_payment(linked,'eft',paid,'verified-bank-test',key);
 execute 'reset role';
 if (result->'payment'->>'balanceDue')::numeric<>0 or (result->'payment'->>'oppsPaid')::numeric<>paid then raise exception 'EFT balances differ'; end if;
 select auth_user_id into member_id from public.tenant_memberships where tenant_id=tenant and tenant_role in ('manager','finance','counter_staff') and status='active' and auth_user_id is not null limit 1;
 if member_id is not null then
   perform set_config('request.jwt.claim.sub',member_id::text,true);
   if public.has_tenant_permission(tenant,'payments.manage') then perform public.qs_opps_staff_payment_state(linked); end if;
 end if;
 perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
 begin perform public.qs_opps_staff_payment_state(linked); raise exception 'Nonmember read'; exception when insufficient_privilege then null; end;
 begin perform public.qs_opps_record_staff_payment(linked,'eft',paid,'verified-bank-test',key); raise exception 'Nonmember replay'; exception when insufficient_privilege then null; end;
 perform set_config('request.jwt.claim.sub','',true);
 begin perform public.qs_opps_staff_payment_state(linked); raise exception 'Anonymous read'; exception when insufficient_privilege then null; end;
 if has_function_privilege('anon','public.qs_opps_record_staff_payment(uuid,text,numeric,text,uuid)','execute') or has_function_privilege('authenticated','commerce.qs_payment_service_order_for_opps(uuid)','execute') then raise exception 'Invalid grants'; end if;
end $$;
rollback;
select 'EFT verification, balances, staff access, unauthorized replay and grants passed; rolled back' as result;
