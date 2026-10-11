-- Staging-only behavioural verification. All activity changes are rolled back.
begin;
do $$
declare t uuid; a uuid; b uuid; member_id uuid; o uuid; f uuid; other_file uuid; w jsonb; first_at text;
begin
  select id into t from public.tenants where slug='quick-solution' and status='active';
  select auth_user_id into a from public.tenant_memberships where tenant_id=t and status='active' and tenant_role in ('owner','admin') and auth_user_id is not null limit 1;
  select auth_user_id into b from public.tenant_memberships where tenant_id=t and status='active' and tenant_role in ('owner','admin') and auth_user_id is not null and auth_user_id<>a limit 1;
  select auth_user_id into member_id from public.tenant_memberships where tenant_id=t and status='active' and tenant_role not in ('owner','admin') and auth_user_id is not null limit 1;
  select so.id,sf.id into o,f from commerce.service_orders so join commerce.service_order_files sf on sf.order_id=so.id where so.tenant_id=t and so.status not in ('completed','cancelled') and sf.status='uploaded' limit 1;
  if a is null or b is null or member_id is null or o is null then raise exception 'Staging fixtures missing'; end if;
  perform set_config('request.jwt.claim.sub',a::text,true);
  w:=public.qs_staff_order_workspace('quick-solution');
  if not (w ? o::text) or jsonb_array_length(w->o::text->'items')=0 then raise exception 'Order workspace missing'; end if;
  if w::text like '%storage_path%' or w::text like '%storage_bucket%' then raise exception 'Storage paths leaked into workspace'; end if;
  perform public.qs_staff_order_activity(o,'viewed');
  select created_at::text into first_at from commerce.qs_order_activity where order_id=o and actor_id=a and event='viewed';
  perform public.qs_staff_order_activity(o,'viewed');
  if (select count(*) from commerce.qs_order_activity where order_id=o and actor_id=a and event='viewed')<>1 or first_at<>(select created_at::text from commerce.qs_order_activity where order_id=o and actor_id=a and event='viewed') then raise exception 'View is not idempotent'; end if;
  perform public.qs_staff_order_activity(o,'acknowledged');
  perform set_config('request.jwt.claim.sub',b::text,true);
  perform public.qs_staff_order_activity(o,'acknowledged');
  if (select actor_id from commerce.qs_order_activity where order_id=o and event='acknowledged')<>a then raise exception 'Acknowledgement overwritten'; end if;
  w:=public.qs_staff_order_file(o,f);
  if w->>'bucket'<>'uploads' then raise exception 'Authorized file lookup failed'; end if;
  select id into other_file from commerce.service_order_files where order_id<>o limit 1;
  begin
    perform public.qs_staff_order_file(o,other_file); raise exception 'Mismatched file allowed';
  exception when insufficient_privilege then null; end;
  update commerce.service_order_files set status='deleted' where id=f;
  begin
    perform public.qs_staff_order_file(o,f); raise exception 'Deleted file allowed';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub',member_id::text,true);
  begin
    perform public.qs_staff_order_workspace('quick-solution'); raise exception 'Counter role escalated';
  exception when insufficient_privilege then null; end;
  begin
    perform public.qs_staff_order_activity(o,'viewed'); raise exception 'Counter role activity allowed';
  exception when insufficient_privilege then null; end;
  begin
    perform public.qs_staff_order_file(o,f); raise exception 'Counter role file allowed';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
  begin
    perform public.qs_staff_order_workspace('quick-solution'); raise exception 'Non-member allowed';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub','',true);
  begin
    perform public.qs_staff_order_workspace('quick-solution'); raise exception 'Anonymous allowed';
  exception when insufficient_privilege then null; end;
  if has_function_privilege('anon','public.qs_staff_order_workspace(text)','EXECUTE') or has_table_privilege('authenticated','commerce.qs_order_activity','INSERT') then raise exception 'Public grants too broad'; end if;
end $$;
rollback;
select 'workspace, views, first-operator acknowledgement, file ownership, deleted files and role boundaries passed; all test writes rolled back' as verification;
