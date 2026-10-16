-- Staging rollback test; never records payment or changes an order.
begin;
do $$
declare tenant uuid; actor uuid; order_id uuid; state jsonb; tested integer:=0;
begin
  select id into tenant from public.tenants where slug='quick-solution' and status='active';
  select auth_user_id into actor from public.tenant_memberships
    where tenant_id=tenant and status='active' and tenant_role in ('owner','admin')
    and auth_user_id is not null limit 1;
  if actor is null then raise exception 'Staff fixture missing'; end if;
  perform set_config('request.jwt.claim.sub','',true);
  begin perform public.qs_staff_payment_state(gen_random_uuid()); raise exception 'Anonymous accepted';
    exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
  select id into order_id from commerce.service_orders where tenant_id=tenant limit 1;
  begin perform public.qs_staff_payment_state(order_id); raise exception 'Nonmember accepted';
    exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub',actor::text,true);
  for order_id in select id from commerce.service_orders where tenant_id=tenant loop
    state:=public.qs_staff_payment_state(order_id);
    if (state->>'reviewRequired')::boolean then
      if state->>'balanceDue' is not null then raise exception 'Unreconciled balance exposed'; end if;
    else
      if (state->>'balanceDue')::numeric <> greatest((state->>'total')::numeric-(state->>'cafePaid')::numeric,0) then
        raise exception 'Mirrored ledgers counted twice';
      end if;
    end if;
    tested:=tested+1;
  end loop;
  if tested=0 then raise exception 'Order fixtures missing'; end if;
  if has_function_privilege('anon','public.qs_staff_payment_state(uuid)','execute') then raise exception 'Anonymous grant'; end if;
end $$;
rollback;
select 'Staff access and reconciliation balance checks passed' as result;
