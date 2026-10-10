-- Run only on the staging/throwaway database. Every fixture is rolled back.
begin;
do $$
declare owner_id uuid; counter_id uuid; tenant uuid; outsider uuid:=gen_random_uuid(); endpoint text:='https://fcm.googleapis.com/fcm/send/qs-rollback-test'; sub jsonb; result jsonb; sid uuid; order_id uuid; n integer;
begin
 if has_function_privilege('anon','public.qs_staff_push(text,text,jsonb,text)','execute') then raise exception 'Anonymous can subscribe'; end if;
 if has_function_privilege('authenticated','public.qs_push_server_config()','execute') or has_function_privilege('authenticated','public.qs_push_claim()','execute') then raise exception 'Staff can access sender secrets'; end if;
 if has_table_privilege('authenticated','public.qs_push_subscriptions','select') then raise exception 'Direct subscription table is exposed'; end if;
 select id into tenant from public.tenants where slug='quick-solution';
 select auth_user_id into owner_id from public.tenant_memberships where tenant_id=tenant and status='active' and tenant_role in ('owner','admin') limit 1;
 select auth_user_id into counter_id from public.tenant_memberships where tenant_id=tenant and status='active' and tenant_role='counter_staff' limit 1;
 if owner_id is null or counter_id is null then raise exception 'Staging test needs admin and counter_staff personas'; end if;
 perform set_config('request.jwt.claim.sub',outsider::text,true);
 begin perform public.qs_staff_push('config','admin'); raise exception 'Outsider admitted'; exception when insufficient_privilege then null; end;
 perform set_config('request.jwt.claim.sub',counter_id::text,true);
 begin perform public.qs_staff_push('config','admin'); raise exception 'Counter staff admitted to admin'; exception when insufficient_privilege then null; end;
 result:=public.qs_staff_push('config','counter');
 if length(result->>'publicKey')<>87 or result ? 'privateKey' or result ? 'dispatchSecret' then raise exception 'Invalid client config'; end if;
 sub:=jsonb_build_object('endpoint',endpoint,'keys',jsonb_build_object('p256dh',repeat('A',87),'auth',repeat('B',22)));
 result:=public.qs_staff_push('subscribe','counter',sub);
 if not (result->>'enabled')::boolean then raise exception 'Subscription failed'; end if;
 select id into sid from public.qs_push_subscriptions where app='counter' and qs_push_subscriptions.endpoint='https://fcm.googleapis.com/fcm/send/qs-rollback-test';
 -- Exercise the real order trigger, payment/ready dedup and generic payloads.
 insert into commerce.service_orders(tenant_id,order_number,customer_name,idempotency_key) values(tenant,'QS-PUSH-ROLLBACK','PRIVATE NAME MUST NOT LEAK',gen_random_uuid()::text) returning id into order_id;
 update commerce.service_orders set payment_status='paid' where id=order_id;
 update commerce.service_orders set status='ready' where id=order_id;
 update commerce.service_orders set status='ready',payment_status='paid' where id=order_id;
 select count(*) into n from commerce.qs_push_deliveries where subscription_id=sid;
 if n<>3 then raise exception 'Expected 3 distinct events, got %',n; end if;
 if exists(select 1 from commerce.qs_push_deliveries where subscription_id=sid and payload::text like '%PRIVATE NAME%') then raise exception 'Customer details leaked'; end if;
 -- Only the owner of a browser subscription can disable it.
 perform set_config('request.jwt.claim.sub',owner_id::text,true);
 perform public.qs_staff_push('unsubscribe','counter',null,endpoint);
 if not exists(select 1 from public.qs_push_subscriptions where id=sid) then raise exception 'Other staff disabled subscription'; end if;
 perform set_config('request.jwt.claim.sub',counter_id::text,true);
 perform public.qs_staff_push('unsubscribe','counter',null,endpoint);
 if exists(select 1 from public.qs_push_subscriptions where id=sid) then raise exception 'Unsubscribe failed'; end if;
 if exists(select 1 from commerce.qs_push_deliveries where subscription_id=sid) then raise exception 'Unsubscribe did not clear pending alerts'; end if;
end $$;
rollback;
