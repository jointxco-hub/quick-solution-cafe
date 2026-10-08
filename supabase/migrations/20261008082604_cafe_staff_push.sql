-- Staff opt-in push. No customer names, contact details or amounts in payloads.
create table public.qs_push_subscriptions (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 tenant_id uuid not null references public.tenants(id),
 app text not null check(app in ('admin','counter')),
 endpoint text not null check(length(endpoint) between 20 and 2048),
 subscription jsonb not null,
 created_at timestamptz not null default now(),
 unique(endpoint,app)
);
alter table public.qs_push_subscriptions enable row level security;
revoke all on public.qs_push_subscriptions from anon,authenticated;
grant all on public.qs_push_subscriptions to service_role;

create table commerce.qs_push_deliveries (
 id uuid primary key default gen_random_uuid(),
 subscription_id uuid not null references public.qs_push_subscriptions(id) on delete cascade,
 event_key text not null,
 payload jsonb not null,
 attempts integer not null default 0,
 available_at timestamptz not null default now(),
 sent_at timestamptz,
 created_at timestamptz not null default now(),
 unique(subscription_id,event_key)
);
alter table commerce.qs_push_deliveries enable row level security;
revoke all on commerce.qs_push_deliveries from public,anon,authenticated;
create index qs_push_pending on commerce.qs_push_deliveries(available_at) where sent_at is null and attempts < 5;

-- Only this private helper reads the project-specific VAPID and dispatch secrets.
create function commerce.qs_push_config() returns jsonb language sql security definer set search_path='' as $$
 select coalesce((select decrypted_secret::jsonb from vault.decrypted_secrets where name='qs_staff_push_config' limit 1),'{}'::jsonb);
$$;
revoke all on function commerce.qs_push_config() from public,anon,authenticated;

create function public.qs_staff_push(p_action text,p_app text,p_subscription jsonb default null,p_endpoint text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_tenant uuid; v_cap text; v_id uuid; v_config jsonb; v_endpoint text;
begin
 if auth.uid() is null then raise exception 'Staff sign-in is required.' using errcode='42501'; end if;
 if p_app not in ('admin','counter') or p_app is null then raise exception 'Invalid app.'; end if;
 select id into v_tenant from public.tenants where slug='quick-solution' and status='active';
 v_cap:=case p_app when 'admin' then 'cafe.operations.manage' else 'cafe.counter.operate' end;
 -- Disabling remains possible after membership revocation.
 if p_action='unsubscribe' then
  delete from public.qs_push_subscriptions where user_id=auth.uid() and app=p_app and endpoint=p_endpoint;
  return jsonb_build_object('enabled',false);
 end if;
 if v_tenant is null or not public.has_tenant_capability(v_tenant,v_cap) or not exists(
  select 1 from public.tenant_capabilities where tenant_id=v_tenant and capability_key='quick_solution' and enabled=true
 ) then raise exception 'You do not have access to this café app.' using errcode='42501'; end if;
 v_config:=commerce.qs_push_config();
 if p_action='config' then
  if coalesce(v_config->>'publicKey','')='' then raise exception 'Café notifications are not configured yet.'; end if;
  return jsonb_build_object('publicKey',v_config->>'publicKey');
 end if;
 if p_action='subscribe' then
  v_endpoint:=p_subscription->>'endpoint';
  -- Prevent the push sender being used for arbitrary HTTP requests.
  if v_endpoint is null or v_endpoint !~ '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9-]+\.notify\.windows\.com)/'
   or length(v_endpoint)>2048 or coalesce(p_subscription->'keys'->>'p256dh','') !~ '^[A-Za-z0-9_-]{80,100}={0,2}$'
   or coalesce(p_subscription->'keys'->>'auth','') !~ '^[A-Za-z0-9_-]{20,30}={0,2}$'
  then raise exception 'Invalid push subscription.'; end if;
  if (select count(*) from public.qs_push_subscriptions where user_id=auth.uid())>=20 and not exists(select 1 from public.qs_push_subscriptions where endpoint=v_endpoint and app=p_app and user_id=auth.uid()) then raise exception 'Too many devices. Disable alerts on an old device first.'; end if;
  -- A shared device transfers ownership on deliberate opt-in; discard old pending deliveries.
  delete from commerce.qs_push_deliveries where subscription_id in (select id from public.qs_push_subscriptions where endpoint=v_endpoint and app=p_app and user_id<>auth.uid());
  insert into public.qs_push_subscriptions(user_id,tenant_id,app,endpoint,subscription)
   values(auth.uid(),v_tenant,p_app,v_endpoint,p_subscription)
   on conflict(endpoint,app) do update set user_id=excluded.user_id,tenant_id=excluded.tenant_id,subscription=excluded.subscription;
  return jsonb_build_object('enabled',true);
 end if;
 select id into v_id from public.qs_push_subscriptions where user_id=auth.uid() and tenant_id=v_tenant and app=p_app and endpoint=p_endpoint;
 if p_action='status' then return jsonb_build_object('enabled',v_id is not null); end if;
 if p_action='test' then
  if v_id is null then raise exception 'Enable notifications first.'; end if;
  if exists(select 1 from commerce.qs_push_deliveries where subscription_id=v_id and event_key like 'test:%' and created_at>now()-interval '1 minute') then raise exception 'Wait a minute before sending another test.'; end if;
  insert into commerce.qs_push_deliveries(subscription_id,event_key,payload) values(v_id,'test:'||gen_random_uuid(),jsonb_build_object('app',p_app,'title','Café test notification','body','Alerts are working on this device.','tag','cafe-test'));
  return jsonb_build_object('queued',true);
 end if;
 raise exception 'Unknown notification action.';
end; $$;
revoke all on function public.qs_staff_push(text,text,jsonb,text) from public,anon;
grant execute on function public.qs_staff_push(text,text,jsonb,text) to authenticated;

create function commerce.qs_queue_order_push() returns trigger language plpgsql security definer set search_path='' as $$
declare v_event text; v_title text; v_key text;
begin
 if new.tenant_id <> (select id from public.tenants where slug='quick-solution') then return new; end if;
 if TG_OP='INSERT' then
  if new.status='draft' then return new; end if;
  v_event:='new'; v_title:='New café order';
 elsif new.payment_status='paid' and old.payment_status is distinct from 'paid' then
  v_event:='paid'; v_title:='Café payment received';
 elsif new.status='ready' and old.status is distinct from 'ready' then
  v_event:='ready'; v_title:='Café order ready for collection';
 elsif old.status='draft' and new.status='submitted' then
  v_event:='new'; v_title:='New café order';
 else return new;
 end if;
 v_key:=new.id::text||':'||v_event;
 insert into commerce.qs_push_deliveries(subscription_id,event_key,payload)
 select s.id,v_key,jsonb_build_object('app',s.app,'title',v_title,'body','Open the café app to review.','tag',v_key)
 from public.qs_push_subscriptions s where s.tenant_id=new.tenant_id
 on conflict(subscription_id,event_key) do nothing;
 return new;
end; $$;
revoke all on function commerce.qs_queue_order_push() from public,anon,authenticated;
create trigger qs_staff_order_push after insert or update of status,payment_status on commerce.service_orders for each row execute function commerce.qs_queue_order_push();

-- Service-role only. Membership is checked AGAIN immediately before dispatch.
create function public.qs_push_claim() returns jsonb language plpgsql security definer set search_path='' as $$
declare v_rows jsonb;
begin
 delete from public.qs_push_subscriptions s where not exists (
  select 1 from public.tenant_memberships m join public.tenants t on t.id=m.tenant_id
  join public.tenant_capabilities tc on tc.tenant_id=t.id and tc.capability_key='quick_solution' and tc.enabled
  where m.auth_user_id=s.user_id and m.tenant_id=s.tenant_id and m.status='active' and t.status='active' and t.slug='quick-solution'
  and (m.tenant_role in ('owner','admin') or (s.app='counter' and m.tenant_role in ('member','counter_staff')))
 );
 with claimed as (
  select id from commerce.qs_push_deliveries where sent_at is null and attempts<5 and available_at<=now() order by available_at limit 50 for update skip locked
 ), updated as (
  update commerce.qs_push_deliveries d set attempts=d.attempts+1,available_at=now()+interval '2 minutes'*power(2,d.attempts)
  from claimed c where d.id=c.id returning d.*
 ) select coalesce(jsonb_agg(jsonb_build_object('id',d.id,'subscriptionId',s.id,'subscription',s.subscription,'payload',d.payload)),'[]'::jsonb) into v_rows
 from updated d join public.qs_push_subscriptions s on s.id=d.subscription_id;
 return v_rows;
end; $$;
create function public.qs_push_finish(p_id uuid,p_expired boolean default false) returns void language plpgsql security definer set search_path='' as $$
begin
 if p_expired then delete from public.qs_push_subscriptions where id=(select subscription_id from commerce.qs_push_deliveries where id=p_id);
 else update commerce.qs_push_deliveries set sent_at=now() where id=p_id; end if;
end; $$;
create function public.qs_push_server_config() returns jsonb language sql security definer set search_path='' as $$ select commerce.qs_push_config(); $$;
revoke all on function public.qs_push_claim() from public,anon,authenticated;
revoke all on function public.qs_push_finish(uuid,boolean) from public,anon,authenticated;
revoke all on function public.qs_push_server_config() from public,anon,authenticated;
grant execute on function public.qs_push_claim(),public.qs_push_finish(uuid,boolean),public.qs_push_server_config() to service_role;

-- No hardcoded keys or project URL. No calls until Vault is configured.
create function commerce.qs_push_wake() returns void language plpgsql security definer set search_path='' as $$
declare cfg jsonb;
begin
 cfg:=commerce.qs_push_config();
 if cfg->>'url' is null or cfg->>'dispatchSecret' is null then return; end if;
 perform net.http_post(url:=(cfg->>'url')||'/functions/v1/quick-solution-push',headers:=jsonb_build_object('Content-Type','application/json','x-qs-dispatch',cfg->>'dispatchSecret'),body:='{"action":"dispatch"}'::jsonb);
 delete from commerce.qs_push_deliveries where created_at<now()-interval '7 days';
end; $$;
revoke all on function commerce.qs_push_wake() from public,anon,authenticated;
select cron.schedule('qs-staff-push-dispatch','* * * * *','select commerce.qs_push_wake()');
