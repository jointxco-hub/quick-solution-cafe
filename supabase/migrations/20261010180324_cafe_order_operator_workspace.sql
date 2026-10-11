-- Shared operator history; no client-supplied actor, time or storage path.
create table commerce.qs_order_activity (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references commerce.service_orders(id) on delete cascade,
  actor_id uuid not null references auth.users(id),
  actor_name text not null,
  event text not null check (event in ('viewed', 'acknowledged')),
  created_at timestamptz not null default now(),
  unique (order_id, actor_id, event)
);
create unique index qs_order_one_acknowledgement on commerce.qs_order_activity(order_id) where event='acknowledged';
alter table commerce.qs_order_activity enable row level security;
revoke all on commerce.qs_order_activity from public, anon, authenticated;
comment on table commerce.qs_order_activity is 'Private activity history. Access only through tenant-capability checked staff RPCs.';

create function public.qs_staff_order_workspace(p_tenant_slug text default 'quick-solution')
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_tenant uuid;
begin
  select id into v_tenant from public.tenants where slug=lower(trim(p_tenant_slug)) and status='active';
  if auth.uid() is null or not coalesce(public.has_tenant_capability(v_tenant,'cafe.operations.manage'),false) then
    raise exception using errcode='42501',message='You do not have access to these orders.';
  end if;
  return coalesce((select jsonb_object_agg(o.id,jsonb_build_object(
    'channel',o.channel,
    'items',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'productKey',i.product_key,'name',i.product_name,'quantity',i.quantity,'configuration',i.configuration,'total',i.line_total,'product',coalesce(c.customer_definition,'{}'::jsonb)||jsonb_build_object('id',i.product_key)) order by i.created_at,i.id)
      from commerce.service_order_items i left join commerce.service_product_configs c on c.product_id=i.product_id and c.tenant_id=i.tenant_id where i.order_id=o.id and i.tenant_id=v_tenant),'[]'::jsonb),
    'files',coalesce((select jsonb_agg(jsonb_build_object('id',f.id,'name',f.original_filename,'mime',f.mime_type,'size',f.byte_size) order by f.created_at,f.id) from commerce.service_order_files f where f.order_id=o.id and f.tenant_id=v_tenant and f.status='uploaded'),'[]'::jsonb),
    'activity',coalesce((select jsonb_agg(jsonb_build_object('actorId',a.actor_id,'name',a.actor_name,'event',a.event,'at',a.created_at) order by a.created_at,a.id) from commerce.qs_order_activity a where a.order_id=o.id),'[]'::jsonb)
  )) from commerce.service_orders o where o.tenant_id=v_tenant),'{}'::jsonb);
end $$;

create function public.qs_staff_order_activity(p_order_id uuid,p_event text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_order commerce.service_orders%rowtype; v_name text;
begin
  select * into v_order from commerce.service_orders where id=p_order_id for update;
  if auth.uid() is null or not coalesce(public.has_tenant_capability(v_order.tenant_id,'cafe.operations.manage'),false) then
    raise exception using errcode='42501',message='You do not have access to this order.';
  end if;
  if p_event is null or p_event not in ('viewed','acknowledged') then raise exception 'Invalid activity.'; end if;
  if p_event='acknowledged' and v_order.status in ('cancelled','completed') then raise exception 'This order is closed.'; end if;
  select left(coalesce(nullif(trim(raw_user_meta_data->>'full_name'),''),nullif(trim(raw_user_meta_data->>'name'),''),nullif(split_part(email,'@',1),''),'Staff'),120) into v_name from auth.users where id=auth.uid();
  -- First view per operator and first acknowledgement per order are immutable.
  -- Concurrent acknowledgements return the original operator, never overwrite them.
  insert into commerce.qs_order_activity(order_id,actor_id,actor_name,event)
    values(p_order_id,auth.uid(),coalesce(v_name,'Staff'),p_event) on conflict do nothing;
  return (select coalesce(jsonb_agg(jsonb_build_object('actorId',a.actor_id,'name',a.actor_name,'event',a.event,'at',a.created_at) order by a.created_at,a.id),'[]'::jsonb) from commerce.qs_order_activity a where order_id=p_order_id);
end $$;

create function public.qs_staff_order_file(p_order_id uuid,p_file_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_tenant uuid; v_result jsonb;
begin
  select tenant_id into v_tenant from commerce.service_orders where id=p_order_id;
  if auth.uid() is null or not coalesce(public.has_tenant_capability(v_tenant,'cafe.operations.manage'),false) then
    raise exception using errcode='42501',message='You do not have access to this file.';
  end if;
  select jsonb_build_object('bucket',storage_bucket,'path',storage_path,'name',original_filename,'mime',mime_type) into v_result
    from commerce.service_order_files where id=p_file_id and order_id=p_order_id and tenant_id=v_tenant and status='uploaded';
  if v_result is null then raise exception using errcode='42501',message='File unavailable.'; end if;
  return v_result;
end $$;
revoke all on function public.qs_staff_order_workspace(text), public.qs_staff_order_activity(uuid,text), public.qs_staff_order_file(uuid,uuid) from public,anon;
grant execute on function public.qs_staff_order_workspace(text), public.qs_staff_order_activity(uuid,text), public.qs_staff_order_file(uuid,uuid) to authenticated;
