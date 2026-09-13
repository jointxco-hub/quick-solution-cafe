-- QS-08.3: service-role bridge for Quick Solution PayFast ITN reconciliation.
-- Already applied to Joint X XOS Staging as 20260913200817_qs_08_3_itn_payment_bridge.

create or replace function public.qs_apply_quick_solution_payment(
  p_order_id uuid,
  p_amount numeric,
  p_pf_payment_id text,
  p_raw_itn jsonb default '{}'::jsonb
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select commerce.qs_apply_payfast_payment(
    p_order_id,
    p_amount,
    p_pf_payment_id,
    p_raw_itn
  );
$$;

revoke all on function public.qs_apply_quick_solution_payment(uuid,numeric,text,jsonb) from public, anon, authenticated;
grant execute on function public.qs_apply_quick_solution_payment(uuid,numeric,text,jsonb) to service_role;

create or replace function public.qs_record_quick_solution_payment_status(
  p_order_id uuid,
  p_status text,
  p_raw_itn jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status text;
  v_updated integer := 0;
begin
  if coalesce(auth.role(),'') <> 'service_role'
     and session_user not in ('postgres','supabase_admin') then
    raise exception using errcode='42501', message='Trusted backend access is required.';
  end if;

  v_status := lower(trim(coalesce(p_status,'')));
  if v_status not in ('failed','cancelled') then
    return jsonb_build_object('ok',false,'reason','unsupported_status');
  end if;

  update commerce.service_order_payments
  set status=v_status,
      raw_itn=coalesce(p_raw_itn,'{}'::jsonb),
      updated_at=now()
  where service_order_id=p_order_id
    and provider='payfast'
    and status='pending';
  get diagnostics v_updated = row_count;

  return jsonb_build_object('ok',true,'status',v_status,'updated',v_updated);
end
$$;

revoke all on function public.qs_record_quick_solution_payment_status(uuid,text,jsonb) from public, anon, authenticated;
grant execute on function public.qs_record_quick_solution_payment_status(uuid,text,jsonb) to service_role;
