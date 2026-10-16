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
 -- Browser/API requests run as authenticated, not the database owner.
 execute 'set local role authenticated';
 result:=public.qs_opps_record_staff_payment(linked,'cash',paid,null,key);
 execute 'reset role';
 receipt_id:=(result->>'receiptId')::uuid;
 select id into tx_id from public.transactions where qs_service_order_id=o;
 if tx_id is null then raise exception 'Finance projection missing'; end if;
 state:=public.qs_staff_payment_state(o);
 if (state->>'reviewRequired')::boolean or (state->>'balanceDue')::numeric<>0 or (state->>'oppsPaid')::numeric<>paid then raise exception 'Shared balances differ: %',state; end if;
 if (select deposit_paid from public.orders where id=linked)<>paid then raise exception 'OPPS order projection differs'; end if;
 result:=public.qs_record_staff_payment(o,'cash',paid,null,key);
 if not (result->>'replayed')::boolean or (result->>'receiptId')::uuid<>receipt_id then raise exception 'Cross-app retry did not reuse receipt'; end if;
 begin perform public.qs_opps_record_staff_payment(linked,'cash',paid,null,gen_random_uuid()); raise exception 'Duplicate accepted';
 exception when raise_exception then if sqlerrm='Duplicate accepted' then raise; end if; end;
 if (select count(*) from commerce.service_order_payments where service_order_id=o and status='completed')<>1
 or (select count(*) from public.transactions where order_id=linked or qs_service_order_id=o)<>1 then raise exception 'Duplicate financial record'; end if;

end $$;
rollback;
select 'Shared authenticated Cash, cross-app retry and duplicate rejection passed; rolled back' as result;
