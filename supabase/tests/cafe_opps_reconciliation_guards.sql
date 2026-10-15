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

 update public.orders set total_amount=paid+1 where id=linked;
 state:=public.qs_opps_staff_payment_state(linked);
 if not (state->'issues' ? 'order_total_mismatch') then raise exception 'Mismatch missed'; end if;
 begin perform public.qs_opps_record_staff_payment(linked,'cash',paid,null,key); raise exception 'Mismatched price accepted'; exception when raise_exception then if sqlerrm<>'Payment records need reconciliation first' then raise; end if; end;
 update public.orders set total_amount=paid where id=linked;
 insert into public.opps_invoices(tenant_id,invoice_number,customer_name,invoice_date,source_order_id,total,status)
 values(tenant,'TEST-'||gen_random_uuid(),'Rollback payment guard',current_date,linked,paid,'approved');
 begin perform public.qs_opps_record_staff_payment(linked,'cash',paid,null,key); raise exception 'Linked invoice accepted'; exception when raise_exception then if sqlerrm<>'Payment records need reconciliation first' then raise; end if; end;
end $$;
rollback;
select 'Price drift and linked-invoice duplicate guards passed; rolled back' as result;
