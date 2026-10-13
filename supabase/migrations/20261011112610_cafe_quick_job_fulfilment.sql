-- Local quick jobs share the order lock used by payment, cancellation and OPPS handoff.
-- Payment/ledger rows are never written here. Existing activity RPC cannot forge these events.
alter table commerce.qs_order_activity drop constraint qs_order_activity_event_check;
alter table commerce.qs_order_activity add constraint qs_order_activity_event_check
  check(event in ('viewed','acknowledged','quick_ready','quick_collected'));

create function public.qs_staff_quick_job(p_order_id uuid, p_action text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  o commerce.service_orders%rowtype;
  reason text;
  outstanding numeric;
  locally_ready boolean;
  locally_collected boolean;
  next_action text;
  actor_name text;
begin
  select * into o from commerce.service_orders where id=p_order_id for update;
  if auth.uid() is null or o.id is null or not coalesce(public.has_tenant_capability(o.tenant_id,'cafe.operations.manage'),false) then
    raise exception using errcode='42501',message='You do not have access to this order.';
  end if;
  if p_action is not null and p_action not in ('ready','collected') then raise exception 'Invalid quick-job action.'; end if;
  select exists(select 1 from commerce.qs_order_activity where order_id=o.id and event='quick_ready'),
    exists(select 1 from commerce.qs_order_activity where order_id=o.id and event='quick_collected')
    into locally_ready,locally_collected;
  outstanding:=greatest(round(o.total_amount-commerce._qs_order_amount_paid(o.id),2),0);
  if not exists(select 1 from public.tenants where id=o.tenant_id and slug='quick-solution' and status='active') then
    reason:='This order is not a Café job.';
  elsif o.opps_order_id is not null or exists(select 1 from commerce.service_order_handoffs where service_order_id=o.id and status in ('sending','sent')) then
    reason:='Manage this job in OPPS.';
  elsif o.fulfilment_type<>'cafe' then
    reason:='Use OPPS for delivery or Quick Point orders.';
  elsif not exists(select 1 from commerce.service_order_items where order_id=o.id)
    or exists(select 1 from commerce.service_order_items where order_id=o.id and (tenant_id<>o.tenant_id or product_key not in ('a4-print','scan','a4-lamination','a3-lamination'))) then
    reason:='Use OPPS for configured or mixed production jobs.';
  elsif o.status='submitted' then next_action:='ready';
  elsif o.status='ready' and locally_ready then next_action:='collected';
  elsif o.status='completed' and locally_collected then next_action:=null;
  else reason:='This order is not available for local fulfilment.';
  end if;

  if p_action is not null then
    if reason is not null then raise exception '%',reason; end if;
    -- Retries never regress status or rewrite the original operator/time.
    if not ((p_action='ready' and locally_ready) or (p_action='collected' and locally_collected)) then
      if p_action is distinct from next_action then raise exception 'Refresh the order before taking this action.'; end if;
      if p_action='collected' and (outstanding>0 or o.payment_status in ('refunded','cancelled','pending','failed')) then
        raise exception 'Settle payment before handing over this order.';
      end if;
      select left(coalesce(nullif(trim(raw_user_meta_data->>'full_name'),''),nullif(trim(raw_user_meta_data->>'name'),''),nullif(split_part(email,'@',1),''),'Staff'),120)
        into actor_name from auth.users where id=auth.uid();
      insert into commerce.qs_order_activity(order_id,actor_id,actor_name,event)
        values(o.id,auth.uid(),coalesce(actor_name,'Staff'),case p_action when 'ready' then 'quick_ready' else 'quick_collected' end);
      update commerce.service_orders set status=case p_action when 'ready' then 'ready' else 'completed' end,updated_at=now()
        where id=o.id returning * into o;
      next_action:=case p_action when 'ready' then 'collected' else null end;
    end if;
  end if;
  return jsonb_build_object('eligible',reason is null,'reason',reason,'status',o.status,'nextAction',next_action,
    'outstanding',outstanding,'canCollect',outstanding=0 and o.payment_status not in ('refunded','cancelled','pending','failed'),
    'channel',o.channel);
end $$;
revoke all on function public.qs_staff_quick_job(uuid,text) from public,anon;
grant execute on function public.qs_staff_quick_job(uuid,text) to authenticated;
