-- QS-08.2: public service-role bridge for Quick Solution payment RPCs.
-- Already applied to Joint X XOS Staging as 20260913195416_qs_08_2_public_payment_rpc_bridge.

create or replace function public.qs_begin_quick_solution_payment(
  p_order_id uuid,
  p_payment_token text
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select commerce.qs_begin_payfast_payment(p_order_id, p_payment_token);
$$;

revoke all on function public.qs_begin_quick_solution_payment(uuid,text) from public, anon, authenticated;
grant execute on function public.qs_begin_quick_solution_payment(uuid,text) to service_role;

create or replace function public.qs_get_quick_solution_payment_status(
  p_order_id uuid,
  p_payment_token text
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select commerce.qs_get_payment_status(p_order_id, p_payment_token);
$$;

revoke all on function public.qs_get_quick_solution_payment_status(uuid,text) from public, anon, authenticated;
grant execute on function public.qs_get_quick_solution_payment_status(uuid,text) to service_role;
