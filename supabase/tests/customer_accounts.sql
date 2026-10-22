-- Run after the account migration. All identities, orders and payment attempts roll back.
begin;
create function public._test_customer_call(p_role text,p_claims jsonb,p_sql text) returns jsonb
language plpgsql as $$
declare result jsonb;
begin
  perform set_config('request.jwt.claims',p_claims::text,true);
  execute format('set local role %I',p_role);
  execute p_sql into result;
  execute 'reset role';
  return jsonb_build_object('ok',true,'result',result);
exception when others then
  execute 'reset role';
  return jsonb_build_object('ok',false,'code',sqlstate,'error',sqlerrm);
end $$;
do $$
declare
  a uuid:=extensions.gen_random_uuid(); b uuid:=extensions.gen_random_uuid();
  sa uuid:=extensions.gen_random_uuid(); sb uuid:=extensions.gen_random_uuid();
  oid uuid:=extensions.gen_random_uuid(); guest uuid:=extensions.gen_random_uuid(); cross_tenant uuid;
  tid uuid; pid uuid; ca jsonb; cb jsonb; result jsonb; detail jsonb; token text; original text:='guest-secret-accounts-test';
  stamp text:=replace(extensions.gen_random_uuid()::text,'-','');
begin
  select id into tid from public.tenants where slug='quick-solution' and status='active';
  select product_id into pid from commerce.service_product_configs where tenant_id=tid and source_key='vinyl-stickers';
  if pid is null then raise exception 'Missing vinyl fixture product'; end if;
  insert into auth.users(id,aud,role,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
    values(a,'authenticated','authenticated','accounts-a-'||stamp||'@example.invalid',now(),'{}','{}',now(),now()),
    (b,'authenticated','authenticated','accounts-b-'||stamp||'@example.invalid',now(),'{}','{}',now(),now());
  insert into auth.sessions(id,user_id,created_at,updated_at) values(sa,a,now(),now()),(sb,b,now(),now());
  ca:=jsonb_build_object('sub',a,'role','authenticated','email','accounts-a-'||stamp||'@example.invalid','session_id',sa,'amr',jsonb_build_array(jsonb_build_object('method','otp')));
  cb:=jsonb_build_object('sub',b,'role','authenticated','email','accounts-b-'||stamp||'@example.invalid','session_id',sb,'amr',jsonb_build_array(jsonb_build_object('method','magiclink')));

  result:=public._test_customer_call('anon','{}','select public.qs_customer_orders()');
  if result->>'code'<>'42501' then raise exception 'Anonymous orders access allowed: %',result; end if;
  result:=public._test_customer_call('authenticated',jsonb_set(ca,'{amr}','[{"method":"password"}]'),'select public.qs_customer_orders()');
  if result->>'code'<>'42501' then raise exception 'Autoconfirmed password accepted as mailbox proof: %',result; end if;
  result:=public._test_customer_call('authenticated',jsonb_set(ca,'{session_id}',to_jsonb(extensions.gen_random_uuid())),'select public.qs_customer_orders()');
  if result->>'code'<>'42501' then raise exception 'Revoked/missing session allowed: %',result; end if;

  -- Simulate the same authenticated insert context as the existing checkout RPCs.
  perform set_config('request.jwt.claims',ca::text,true);
  insert into commerce.service_orders(id,tenant_id,order_number,customer_name,customer_email,idempotency_key,total_amount,subtotal,status,payment_status,channel,payment_token_hash,payment_token_expires_at)
    values(oid,tid,'TEST-ACCOUNT-'||stamp,'TEST DO NOT FULFIL','accounts-a-'||stamp||'@example.invalid','account-'||stamp,350,350,'submitted','unpaid','storefront',encode(extensions.digest(original,'sha256'),'hex'),now()+interval '1 day');
  if not exists(select 1 from commerce.service_order_customers where order_id=oid and user_id=a and tenant_id=tid) then raise exception 'Signed-in checkout did not attach owner'; end if;
  insert into commerce.service_order_items(tenant_id,order_id,product_id,product_key,product_name,quantity,configuration,pricing_snapshot,line_total)
    values(tid,oid,pid,'vinyl-stickers','TEST vinyl',1,'{}','{}',350);
  result:=public._test_customer_call('authenticated',ca,'select public.qs_customer_orders()');
  if not (result->>'ok')::boolean or jsonb_array_length(result->'result'->'orders')<>1 then raise exception 'Owner list failed %',result; end if;
  result:=public._test_customer_call('authenticated',cb,'select public.qs_customer_orders()');
  if jsonb_array_length(result->'result'->'orders')<>0 then raise exception 'Account B can list A orders'; end if;
  result:=public._test_customer_call('authenticated',cb,format('select public.qs_customer_order(%L)',oid));
  if result->>'code'<>'42501' then raise exception 'Account B can read A %',result; end if;
  result:=public._test_customer_call('authenticated',cb,format('select public.qs_customer_payment_session(%L)',oid));
  if result->>'code'<>'42501' then raise exception 'Account B can pay A %',result; end if;
  result:=public._test_customer_call('authenticated',cb,format('select public.qs_customer_link_order(%L,%L)',oid,original));
  if result->>'code'<>'42501' then raise exception 'Account B can claim A %',result; end if;
  result:=public._test_customer_call('authenticated',ca,format('select public.qs_customer_order(%L)',oid));
  detail:=result->'result';
  if (detail->'payment'->>'balanceDue')::numeric<>350 or not (detail->'payment'->>'canPay')::boolean then raise exception 'Owner detail failed %',result; end if;
  if detail::text like '%customer_notes%' or detail::text like '%oppsPaid%' or detail::text like '%source_metadata%' then raise exception 'Internal fields leaked'; end if;
  result:=public._test_customer_call('authenticated',ca,format('select public.qs_customer_payment_session(%L)',oid));
  token:=result->'result'->>'paymentToken';
  if length(token)<>64 then raise exception 'Account payment session failed %',result; end if;
  if (select payment_token_hash from commerce.service_orders where id=oid)<>encode(extensions.digest(original,'sha256'),'hex') then raise exception 'Guest token rotated'; end if;
  result:=public._test_customer_call('service_role','{"role":"service_role"}',format('select public.qs_get_quick_solution_payment_status(%L,%L)',oid,token));
  if not (result->'result'->>'ok')::boolean then raise exception 'Account token rejected by gateway status %',result; end if;
  result:=public._test_customer_call('service_role','{"role":"service_role"}',format('select public.qs_begin_quick_solution_payment(%L,%L)',oid,token));
  if not (result->'result'->>'ok')::boolean then raise exception 'Account gateway init rejected %',result; end if;
  perform public._test_customer_call('service_role','{"role":"service_role"}',format('select public.qs_begin_quick_solution_payment(%L,%L)',oid,token));
  if (select count(*) from commerce.service_order_payments where service_order_id=oid)<>1 then raise exception 'Payment retry duplicated attempt'; end if;
  if exists(select 1 from commerce.service_order_payments where service_order_id=oid and status='completed') then raise exception 'Init created money'; end if;
  update commerce.customer_payment_sessions set expires_at=now()-interval '1 minute' where order_id=oid;
  result:=public._test_customer_call('service_role','{"role":"service_role"}',format('select public.qs_get_quick_solution_payment_status(%L,%L)',oid,token));
  if (result->'result'->>'ok')::boolean then raise exception 'Expired account token accepted'; end if;
  result:=public._test_customer_call('service_role','{"role":"service_role"}',format('select public.qs_get_quick_solution_payment_status(%L,%L)',oid,original));
  if not (result->'result'->>'ok')::boolean then raise exception 'Existing guest token broken'; end if;

  perform set_config('request.jwt.claims','{}',true);
  insert into commerce.service_orders(id,tenant_id,order_number,customer_name,customer_email,idempotency_key,total_amount,subtotal,status,payment_status,channel,payment_token_hash,payment_token_expires_at)
    values(guest,tid,'TEST-GUEST-'||stamp,'TEST DO NOT FULFIL','accounts-a-'||stamp||'@example.invalid','guest-'||stamp,350,350,'submitted','unpaid','storefront',encode(extensions.digest(original,'sha256'),'hex'),now()+interval '1 day');
  if exists(select 1 from commerce.service_order_customers where order_id=guest) then raise exception 'Guest attached automatically'; end if;
  update commerce.service_orders set payment_token_hash=null,payment_token_expires_at=null where id=guest;
  result:=public._test_customer_call('authenticated',ca,format('select public.qs_customer_link_order(%L,%L)',guest,'wrong'));
  if result->>'code'<>'42501' then raise exception 'Null payment secret allowed guest claim'; end if;
  update commerce.service_orders set payment_token_hash=encode(extensions.digest(original,'sha256'),'hex'),payment_token_expires_at=now()+interval '1 day' where id=guest;
  result:=public._test_customer_call('authenticated',ca,format('select public.qs_customer_link_order(%L,%L)',guest,'wrong'));
  if result->>'code'<>'42501' then raise exception 'Guest claimed without secret'; end if;
  result:=public._test_customer_call('authenticated',ca,format('select public.qs_customer_link_order(%L,%L)',guest,original));
  if not (result->>'ok')::boolean then raise exception 'Valid guest claim failed %',result; end if;
  result:=public._test_customer_call('authenticated',ca,format('select public.qs_customer_link_order(%L,%L)',guest,original));
  if not (result->>'ok')::boolean or (select count(*) from commerce.service_order_customers where order_id=guest)<>1 then raise exception 'Guest claim not idempotent'; end if;
  result:=public._test_customer_call('authenticated',ca,format('select public.qs_customer_link_tracking(%L,%L)','TEST-GUEST-'||stamp,original));
  if not (result->>'ok')::boolean then raise exception 'Owned tracking-link claim failed'; end if;

  perform set_config('request.jwt.claims','{}',true);
  select id into cross_tenant from public.tenants where slug<>'quick-solution' and status='active' limit 1;
  if cross_tenant is null then raise exception 'Missing cross-tenant fixture'; end if;
  insert into commerce.service_orders(tenant_id,order_number,customer_name,customer_email,idempotency_key,channel,payment_token_hash,payment_token_expires_at)
    values(cross_tenant,'TEST-OTHER-'||stamp,'TEST DO NOT FULFIL','accounts-a-'||stamp||'@example.invalid','other-'||stamp,'storefront',encode(extensions.digest(original,'sha256'),'hex'),now()+interval '1 day') returning id into cross_tenant;
  result:=public._test_customer_call('authenticated',ca,format('select public.qs_customer_link_order(%L,%L)',cross_tenant,original));
  if result->>'code'<>'42501' then raise exception 'Cross-tenant order claimed'; end if;

  result:=public._test_customer_call('authenticated',cb,format('with changed as (update commerce.service_orders set payment_token_hash=%L where id=%L returning id) select to_jsonb(changed) from changed',repeat('b',64),oid));
  if result->>'ok'='true' then raise exception 'Direct customer order mutation allowed'; end if;
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  update commerce.service_orders set status='cancelled' where id=oid;
  result:=public._test_customer_call('authenticated',ca,format('select public.qs_customer_payment_session(%L)',oid));
  if result->>'ok'='true' then raise exception 'Cancelled order payment session created'; end if;
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  update commerce.service_orders set status='submitted',payment_status='paid' where id=oid;
  result:=public._test_customer_call('authenticated',ca,format('select public.qs_customer_order(%L)',oid));
  if not (result->'result'->'payment'->>'reviewRequired')::boolean or result->'result'->'payment'->'balanceDue'<>'null'::jsonb then raise exception 'Inconsistent paid flag did not block balance'; end if;

  if has_table_privilege('authenticated','commerce.service_order_customers','SELECT') or has_table_privilege('anon','commerce.customer_payment_sessions','SELECT')
    or has_function_privilege('authenticated','commerce.qs_customer_payment_snapshot(uuid)','EXECUTE')
    or has_function_privilege('authenticated','commerce.qs_valid_customer_payment_token(uuid,text)','EXECUTE') then raise exception 'Private helper/table grants leaked'; end if;
  raise notice 'Account identity, ownership, isolation, guest claim, payment session, retry and grants passed';
end $$;
rollback;
