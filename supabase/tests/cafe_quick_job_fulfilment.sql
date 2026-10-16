-- Staging only. Test orders, payments, activity and notification rows roll back.
begin;
do $$
declare t uuid; a uuid; b uuid; member_id uuid; product uuid; o uuid; extra uuid; state jsonb; original_at timestamptz;
begin
  select id into t from public.tenants where slug='quick-solution' and status='active';
  select auth_user_id into a from public.tenant_memberships where tenant_id=t and status='active' and tenant_role in ('owner','admin') and auth_user_id is not null limit 1;
  select auth_user_id into b from public.tenant_memberships where tenant_id=t and status='active' and tenant_role in ('owner','admin') and auth_user_id<>a limit 1;
  select auth_user_id into member_id from public.tenant_memberships where tenant_id=t and status='active' and tenant_role not in ('owner','admin') and auth_user_id is not null limit 1;
  select product_id into product from commerce.service_order_items where tenant_id=t and product_key='a4-print' limit 1;
  if a is null or b is null or member_id is null or product is null then raise exception 'Staging fixtures missing'; end if;
  insert into commerce.service_orders(tenant_id,order_number,customer_name,total_amount,subtotal,idempotency_key,channel)
    values(t,'TEST-QUICK-'||gen_random_uuid(),'Rollback quick job test',10,10,gen_random_uuid()::text,'storefront') returning id into o;
  perform set_config('request.jwt.claim.sub',a::text,true);
  if (public.qs_staff_quick_job(o)->>'eligible')::boolean then raise exception 'Empty job eligible'; end if;
  insert into commerce.service_order_items(tenant_id,order_id,product_id,product_key,product_name,line_total)
    values(t,o,product,'a4-print','Test printing',10);
  state:=public.qs_staff_quick_job(o);
  if state->>'nextAction'<>'ready' then raise exception 'Simple job not readyable'; end if;
  update commerce.service_orders set fulfilment_type='delivery' where id=o;
  if (public.qs_staff_quick_job(o)->>'eligible')::boolean then raise exception 'Delivery eligible'; end if;
  update commerce.service_orders set fulfilment_type='cafe' where id=o;
  insert into commerce.service_order_items(tenant_id,order_id,product_id,product_key,product_name,line_total)
    select t,o,product_id,'vinyl-stickers','Test complex line',0 from commerce.service_order_items where tenant_id=t and product_key='vinyl-stickers' limit 1 returning id into extra;
  if (public.qs_staff_quick_job(o)->>'eligible')::boolean then raise exception 'Mixed job eligible'; end if;
  begin perform public.qs_staff_quick_job(o,'ready'); raise exception 'Mixed mutation allowed'; exception when raise_exception then if sqlerrm='Mixed mutation allowed' then raise; end if; end;
  delete from commerce.service_order_items where id=extra;
  update commerce.service_orders set status='cancelled' where id=o;
  if (public.qs_staff_quick_job(o)->>'eligible')::boolean then raise exception 'Cancelled job eligible'; end if;
  update commerce.service_orders set status='submitted',opps_order_id=gen_random_uuid() where id=o;
  if (public.qs_staff_quick_job(o)->>'eligible')::boolean then raise exception 'Linked OPPS job eligible'; end if;
  update commerce.service_orders set opps_order_id=null where id=o;
  perform set_config('request.jwt.claim.sub',member_id::text,true);
  begin perform public.qs_staff_quick_job(o,'ready'); raise exception 'Counter member allowed'; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub','',true);
  begin perform public.qs_staff_quick_job(o); raise exception 'Anonymous allowed'; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
  begin perform public.qs_staff_quick_job(o,'ready'); raise exception 'Non-member allowed'; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub',a::text,true);
  state:=public.qs_staff_quick_job(o,'ready');
  if state->>'status'<>'ready' or (state->>'canCollect')::boolean then raise exception 'Unpaid ready state incorrect'; end if;
  select created_at into original_at from commerce.qs_order_activity where order_id=o and event='quick_ready';
  perform set_config('request.jwt.claim.sub',b::text,true);
  perform public.qs_staff_quick_job(o,'ready');
  if (select count(*) from commerce.qs_order_activity where order_id=o and event='quick_ready')<>1 or not exists(select 1 from commerce.qs_order_activity where order_id=o and event='quick_ready' and actor_id=a and created_at=original_at) then raise exception 'Retry changed actor/time'; end if;
  -- A paid flag alone is not proof; partial ledger settlement is also insufficient.
  update commerce.service_orders set payment_status='paid' where id=o;
  begin perform public.qs_staff_quick_job(o,'collected'); raise exception 'Unpaid collection allowed'; exception when raise_exception then if sqlerrm='Unpaid collection allowed' then raise; end if; end;
  insert into commerce.service_order_payments(tenant_id,service_order_id,provider,status,amount,completed_at) values(t,o,'payfast','completed',5,now());
  if (public.qs_staff_quick_job(o)->>'canCollect')::boolean then raise exception 'Partial collection allowed'; end if;
  insert into commerce.service_order_payments(tenant_id,service_order_id,provider,status,amount,completed_at) values(t,o,'payfast','completed',5,now());
  update commerce.service_orders set payment_status='refunded' where id=o;
  if (public.qs_staff_quick_job(o)->>'canCollect')::boolean then raise exception 'Refunded collection allowed'; end if;
  update commerce.service_orders set payment_status='paid' where id=o;
  state:=public.qs_staff_quick_job(o,'collected');
  if state->>'status'<>'completed' then raise exception 'Completion failed'; end if;
  perform public.qs_staff_quick_job(o,'collected');
  perform public.qs_staff_quick_job(o,'ready');
  if (select status from commerce.service_orders where id=o)<>'completed' then raise exception 'Retry regressed job'; end if;
  if (select count(*) from commerce.qs_order_activity where order_id=o and event='quick_collected')<>1 then raise exception 'Duplicate collection'; end if;
  if commerce._qs_order_amount_paid(o)<>10 or (select payment_status from commerce.service_orders where id=o)<>'paid' then raise exception 'Finance changed'; end if;
  if (commerce.qs_build_opps_handoff_preview(o)->>'ready')::boolean then raise exception 'Completed job handoff allowed'; end if;
  if has_function_privilege('anon','public.qs_staff_quick_job(uuid,text)','EXECUTE') then raise exception 'Anonymous RPC grant'; end if;
end $$;
rollback;
select 'Quick-job eligibility, role boundaries, ledger gate, immutable retries and closed handoff passed; all writes rolled back' as verification;
