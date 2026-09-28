-- PRODUCTION RECONCILIATION: restores exactly the 7 canonical Quick Solution PayFast
-- RPCs that public.quick-solution-payfast (init) and production's already-live
-- payfast-notify dormant Quick Solution branch depend on:
--   1. commerce.qs_begin_payfast_payment(uuid,text)
--   2. commerce.qs_get_payment_status(uuid,text)
--   3. commerce.qs_apply_payfast_payment(uuid,numeric,text,jsonb)
--   4. public.qs_begin_quick_solution_payment(uuid,text)
--   5. public.qs_get_quick_solution_payment_status(uuid,text)
--   6. public.qs_apply_quick_solution_payment(uuid,numeric,text,jsonb)
--   7. public.qs_record_quick_solution_payment_status(uuid,text,jsonb)
--
-- WHY THIS FILE EXISTS, SEPARATELY FROM THE 6 STAGING MIGRATIONS IT DRAWS FROM:
-- none of the 6 (20260913193609_qs_08_payfast_payment_foundation,
-- 20260913193947_qs_08_delivery_payment_guard,
-- 20260913195406/195416_qs_08_2_public_payment_rpc_bridge,
-- 20260913200459/200817_qs_08_3_itn_payment_bridge, and the two never-committed
-- 20260913200542_qs_08_3_payfast_itn_bridge / 20260913200552_qs_08_3_payfast_noncomplete_bridge)
-- have a ledger row on production, and applying any of them verbatim would be unsafe or
-- wrong for one of three reasons:
--   - 20260913193609 also does `create or replace function public.create_quick_solution_order`
--     with a body dated before the later quoteRequired/PHOTOGRAPHY_SESSION checkout-protection
--     guard that production's live create_quick_solution_order already carries (hash
--     d24745c4792c9cc549f9bfab34ac70ba, confirmed unchanged by this file - see the assertions
--     below). Re-applying that copy would silently regress a live, currently-used function
--     (the Guided single-item checkout path still calls it).
--   - 20260913193609 also creates commerce.service_order_payments and two columns on
--     commerce.service_orders that ALREADY exist on production (added by an earlier
--     reconciliation step) - and production's live table is a SUPERSET of what this file
--     would create (it already allows provider IN ('payfast','cash','card') for the Counter
--     cash/card path, plus a counter-payment completeness check constraint this file's
--     'payfast'-only definition never had). Re-running that DDL is unnecessary; this file
--     does not touch commerce.service_orders or commerce.service_order_payments at all.
--   - 20260913200542 and 20260913200552 were never committed to git on any branch - they
--     exist only as applied ledger rows on staging - and they define an abandoned, parallel
--     naming (qs_apply_quick_solution_payfast_payment, qs_record_quick_solution_payfast_
--     noncomplete) that production's already-live payfast-notify dormant branch does NOT call
--     and that git's own consolidated historical record never carried forward. Restoring them
--     would create dead, confusing duplicate RPCs and is explicitly out of scope here.
--
-- This file restores ONLY the 7 functions above, each copied byte-for-byte (function body,
-- language, volatility, security, search_path) from whichever of the 6 staging migrations last
-- defined it, with no logic changes:
--   #1 commerce.qs_begin_payfast_payment      <- 20260913193947 (the FINAL body; supersedes
--                                                 20260913193609's own initial version of the
--                                                 same function, which is not restored on its own)
--   #2 commerce.qs_get_payment_status          <- 20260913193609
--   #3 commerce.qs_apply_payfast_payment       <- 20260913193609
--   #4 public.qs_begin_quick_solution_payment  <- 20260913195406/195416
--   #5 public.qs_get_quick_solution_payment_status <- 20260913195406/195416
--   #6 public.qs_apply_quick_solution_payment  <- 20260913200459/200817 (canonical - matches
--                                                 production's already-live payfast-notify
--                                                 dormant branch and git's consolidated record)
--   #7 public.qs_record_quick_solution_payment_status <- 20260913200459/200817 (canonical, same)
--
-- create_quick_solution_order is NOT mentioned, NOT replaced, and explicitly asserted
-- unchanged both before and after (same pattern as the earlier upload-authorization
-- restoration). No table or column DDL is included - both are already satisfied on
-- production, confirmed by the preflight below. Deploying the quick-solution-payfast Edge
-- Function, and any Edge Function change at all, is explicitly out of scope for this file.

do $preflight$
declare
  v_create_order_hash text;
begin
  if to_regclass('commerce.service_order_payments') is null then
    raise exception 'QS_PAYFAST_RPCS_PRECONDITION: commerce.service_order_payments does not exist';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'commerce' and table_name = 'service_orders' and column_name = 'payment_token_hash'
  ) then
    raise exception 'QS_PAYFAST_RPCS_PRECONDITION: commerce.service_orders.payment_token_hash does not exist';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'commerce' and table_name = 'service_orders' and column_name = 'payment_token_expires_at'
  ) then
    raise exception 'QS_PAYFAST_RPCS_PRECONDITION: commerce.service_orders.payment_token_expires_at does not exist';
  end if;

  if to_regprocedure('commerce.qs_build_opps_handoff_preview(uuid)') is null then
    raise exception 'QS_PAYFAST_RPCS_PRECONDITION: commerce.qs_build_opps_handoff_preview(uuid) does not exist';
  end if;

  if to_regclass('commerce.service_order_handoffs') is null then
    raise exception 'QS_PAYFAST_RPCS_PRECONDITION: commerce.service_order_handoffs does not exist';
  end if;

  -- None of the 7 target functions may already exist - this is a pure restoration, not a
  -- replace, and an unexpected pre-existing copy would mean this file's assumptions are stale.
  if to_regprocedure('commerce.qs_begin_payfast_payment(uuid,text)') is not null
     or to_regprocedure('commerce.qs_get_payment_status(uuid,text)') is not null
     or to_regprocedure('commerce.qs_apply_payfast_payment(uuid,numeric,text,jsonb)') is not null
     or to_regprocedure('public.qs_begin_quick_solution_payment(uuid,text)') is not null
     or to_regprocedure('public.qs_get_quick_solution_payment_status(uuid,text)') is not null
     or to_regprocedure('public.qs_apply_quick_solution_payment(uuid,numeric,text,jsonb)') is not null
     or to_regprocedure('public.qs_record_quick_solution_payment_status(uuid,text,jsonb)') is not null then
    raise exception 'QS_PAYFAST_RPCS_PRECONDITION: one or more of the 7 target functions already exists - aborting';
  end if;

  -- The explicit guard this file exists to honour: create_quick_solution_order's current
  -- production body is pinned to the hash captured during the pre-apply safety review
  -- (2026-09-28). If it differs, something else has already changed that function since
  -- that review and this migration must not proceed on a stale assumption.
  select md5(p.prosrc) into v_create_order_hash
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'create_quick_solution_order';

  if v_create_order_hash is distinct from 'd24745c4792c9cc549f9bfab34ac70ba' then
    raise exception 'QS_PAYFAST_RPCS_PRECONDITION: public.create_quick_solution_order hash is % (expected d24745c4792c9cc549f9bfab34ac70ba) - this migration must not run against a changed body without re-review', v_create_order_hash;
  end if;
end
$preflight$;

-- ── #1 commerce.qs_begin_payfast_payment ─────────────────────────────────
-- Final body, from 20260913193947_qs_08_delivery_payment_guard (supersedes
-- 20260913193609's own initial version of the same function).
create or replace function commerce.qs_begin_payfast_payment(
  p_order_id uuid,
  p_payment_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order commerce.service_orders;
  v_payment_id uuid;
begin
  if coalesce(auth.role(),'') <> 'service_role'
     and session_user not in ('postgres','supabase_admin') then
    raise exception using errcode='42501', message='Trusted backend access is required.';
  end if;

  select * into v_order
  from commerce.service_orders so
  where so.id=p_order_id
  for update;

  if v_order.id is null then
    return jsonb_build_object('ok',false,'reason','not_available');
  end if;

  if v_order.payment_token_hash is null
     or v_order.payment_token_expires_at is null
     or v_order.payment_token_expires_at <= now()
     or encode(extensions.digest(coalesce(p_payment_token,''), 'sha256'),'hex') <> v_order.payment_token_hash then
    return jsonb_build_object('ok',false,'reason','not_available');
  end if;

  if v_order.payment_status='paid' then
    return jsonb_build_object(
      'ok',true,'alreadyPaid',true,'orderId',v_order.id,
      'orderNumber',v_order.order_number,'amount',v_order.total_amount,'paymentStatus','paid'
    );
  end if;

  if v_order.status in ('cancelled','completed') or v_order.total_amount <= 0 then
    return jsonb_build_object('ok',false,'reason','not_available');
  end if;

  if v_order.fulfilment_type='delivery'
     and coalesce(v_order.source_metadata->>'deliveryFeeStatus','pending_confirmation') <> 'confirmed' then
    return jsonb_build_object('ok',false,'reason','delivery_fee_pending');
  end if;

  select p.id into v_payment_id
  from commerce.service_order_payments p
  where p.service_order_id=v_order.id
    and p.status='pending'
    and p.initiated_at > now() - interval '20 minutes'
  order by p.initiated_at desc
  limit 1;

  if v_payment_id is null then
    insert into commerce.service_order_payments (
      tenant_id, service_order_id, provider, status, amount
    )
    values (
      v_order.tenant_id, v_order.id, 'payfast', 'pending', v_order.total_amount
    )
    returning id into v_payment_id;
  end if;

  return jsonb_build_object(
    'ok',true,'alreadyPaid',false,'paymentIntentId',v_payment_id,
    'orderId',v_order.id,'orderNumber',v_order.order_number,'amount',v_order.total_amount,
    'customerName',v_order.customer_name,'customerEmail',v_order.customer_email,
    'customerPhone',v_order.customer_phone,'paymentStatus',v_order.payment_status
  );
end
$$;

revoke all on function commerce.qs_begin_payfast_payment(uuid,text) from public, anon, authenticated;
grant execute on function commerce.qs_begin_payfast_payment(uuid,text) to service_role;

-- ── #2 commerce.qs_get_payment_status ────────────────────────────────────
-- From 20260913193609_qs_08_payfast_payment_foundation.
create or replace function commerce.qs_get_payment_status(
  p_order_id uuid,
  p_payment_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order commerce.service_orders;
  v_completed_at timestamptz;
begin
  if coalesce(auth.role(),'') <> 'service_role'
     and session_user not in ('postgres','supabase_admin') then
    raise exception using errcode='42501', message='Trusted backend access is required.';
  end if;

  select * into v_order
  from commerce.service_orders so
  where so.id=p_order_id
  limit 1;

  if v_order.id is null
     or v_order.payment_token_hash is null
     or v_order.payment_token_expires_at is null
     or v_order.payment_token_expires_at <= now()
     or encode(extensions.digest(coalesce(p_payment_token,''), 'sha256'),'hex') <> v_order.payment_token_hash then
    return jsonb_build_object('ok',false,'reason','not_available');
  end if;

  select p.completed_at into v_completed_at
  from commerce.service_order_payments p
  where p.service_order_id=v_order.id
    and p.status='completed'
  order by p.completed_at desc nulls last, p.created_at desc
  limit 1;

  return jsonb_build_object(
    'ok',true,'orderId',v_order.id,'orderNumber',v_order.order_number,
    'amount',v_order.total_amount,'paymentStatus',v_order.payment_status,
    'paid',v_order.payment_status='paid','paidAt',v_completed_at
  );
end
$$;

revoke all on function commerce.qs_get_payment_status(uuid,text) from public, anon, authenticated;
grant execute on function commerce.qs_get_payment_status(uuid,text) to service_role;

-- ── #3 commerce.qs_apply_payfast_payment ─────────────────────────────────
-- From 20260913193609_qs_08_payfast_payment_foundation.
create or replace function commerce.qs_apply_payfast_payment(
  p_order_id uuid,
  p_amount numeric,
  p_pf_payment_id text,
  p_raw_itn jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order commerce.service_orders;
  v_expected numeric;
  v_existing_payment commerce.service_order_payments;
  v_preview jsonb;
  v_handoff_status text;
  v_clean_warnings jsonb := '[]'::jsonb;
begin
  if coalesce(auth.role(),'') <> 'service_role'
     and session_user not in ('postgres','supabase_admin') then
    raise exception using errcode='42501', message='Trusted backend access is required.';
  end if;

  if p_order_id is null
     or nullif(trim(coalesce(p_pf_payment_id,'')),'') is null
     or p_amount is null
     or p_amount <= 0 then
    return jsonb_build_object('ok',false,'reason','invalid_args');
  end if;

  select * into v_order
  from commerce.service_orders so
  where so.id=p_order_id
  for update;

  if v_order.id is null then
    return jsonb_build_object('ok',false,'reason','not_found');
  end if;

  v_expected := round(v_order.total_amount,2);
  if round(p_amount,2) <> v_expected then
    return jsonb_build_object(
      'ok',false,'reason','amount_mismatch','expected',v_expected,'received',round(p_amount,2)
    );
  end if;

  select * into v_existing_payment
  from commerce.service_order_payments p
  where p.provider='payfast'
    and p.pf_payment_id=trim(p_pf_payment_id)
  limit 1;

  if v_existing_payment.id is not null
     and v_existing_payment.service_order_id <> v_order.id then
    return jsonb_build_object('ok',false,'reason','duplicate_provider_reference');
  end if;

  if v_order.payment_status='paid' then
    return jsonb_build_object(
      'ok',true,'duplicate',v_existing_payment.id is not null,'ignored',true,
      'paymentStatus','paid','orderId',v_order.id,'orderNumber',v_order.order_number
    );
  end if;

  if v_existing_payment.id is null then
    insert into commerce.service_order_payments (
      tenant_id, service_order_id, provider, status, amount,
      pf_payment_id, raw_itn, completed_at
    )
    values (
      v_order.tenant_id, v_order.id, 'payfast', 'completed', v_expected,
      trim(p_pf_payment_id), coalesce(p_raw_itn,'{}'::jsonb), now()
    );
  else
    update commerce.service_order_payments
    set status='completed', amount=v_expected,
        raw_itn=coalesce(p_raw_itn,'{}'::jsonb),
        completed_at=coalesce(completed_at,now())
    where id=v_existing_payment.id;
  end if;

  update commerce.service_order_payments
  set status='cancelled'
  where service_order_id=v_order.id
    and provider='payfast'
    and status='pending'
    and pf_payment_id is null;

  update commerce.service_orders
  set payment_status='paid',
      source_metadata=coalesce(source_metadata,'{}'::jsonb) ||
        jsonb_build_object(
          'payment',
          jsonb_build_object(
            'provider','payfast','status','paid','paidAt',now(),
            'pfPaymentId',trim(p_pf_payment_id)
          )
        ),
      updated_at=now()
  where id=v_order.id;

  if v_order.opps_order_id is not null then
    update public.orders
    set payment_status='paid',
        deposit_paid=greatest(coalesce(deposit_paid,0),v_expected),
        updated_at=now()
    where id=v_order.opps_order_id
      and tenant_id=v_order.tenant_id;
  end if;

  select h.status into v_handoff_status
  from commerce.service_order_handoffs h
  where h.service_order_id=v_order.id
  limit 1;

  if v_handoff_status is not null and v_handoff_status <> 'sent' then
    v_preview := commerce.qs_build_opps_handoff_preview(v_order.id);

    update commerce.service_order_handoffs
    set status=case when coalesce((v_preview->>'ready')::boolean,false) then 'ready' else 'blocked' end,
        preview_payload=v_preview,
        blockers=coalesce(v_preview->'blockers','[]'::jsonb),
        warnings=coalesce(v_preview->'warnings','[]'::jsonb),
        last_previewed_at=now(),
        failure_message=null
    where service_order_id=v_order.id;
  elsif v_handoff_status='sent' then
    select coalesce(
      jsonb_agg(item) filter (where item->>'code' is distinct from 'PAYMENT_NOT_PAID'),
      '[]'::jsonb
    )
    into v_clean_warnings
    from commerce.service_order_handoffs h
    left join lateral jsonb_array_elements(coalesce(h.warnings,'[]'::jsonb)) item on true
    where h.service_order_id=v_order.id;

    update commerce.service_order_handoffs
    set warnings=v_clean_warnings,
        preview_payload=
          jsonb_set(
            jsonb_set(
              jsonb_set(
                coalesce(preview_payload,'{}'::jsonb),
                '{warnings}',v_clean_warnings,true
              ),
              '{proposedOppsOrder,payment_status}',to_jsonb('paid'::text),true
            ),
            '{proposedOppsOrder,deposit_paid}',to_jsonb(v_expected),true
          ),
        updated_at=now()
    where service_order_id=v_order.id;
  end if;

  return jsonb_build_object(
    'ok',true,'duplicate',false,'ignored',false,'paymentStatus','paid',
    'orderId',v_order.id,'orderNumber',v_order.order_number,'amount',v_expected
  );
end
$$;

revoke all on function commerce.qs_apply_payfast_payment(uuid,numeric,text,jsonb) from public, anon, authenticated;
grant execute on function commerce.qs_apply_payfast_payment(uuid,numeric,text,jsonb) to service_role;

-- ── #4 public.qs_begin_quick_solution_payment ────────────────────────────
-- From 20260913195406/195416_qs_08_2_public_payment_rpc_bridge.
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

-- ── #5 public.qs_get_quick_solution_payment_status ───────────────────────
-- From 20260913195406/195416_qs_08_2_public_payment_rpc_bridge.
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

-- ── #6 public.qs_apply_quick_solution_payment ────────────────────────────
-- From 20260913200459/200817_qs_08_3_itn_payment_bridge (canonical - matches
-- production's already-live payfast-notify dormant branch and git's consolidated
-- record; NOT the abandoned qs_apply_quick_solution_payfast_payment naming).
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

-- ── #7 public.qs_record_quick_solution_payment_status ────────────────────
-- From 20260913200459/200817_qs_08_3_itn_payment_bridge (canonical - matches
-- production's already-live payfast-notify dormant branch and git's consolidated
-- record; NOT the abandoned qs_record_quick_solution_payfast_noncomplete naming).
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

  return jsonb_build_object(
    'ok',true,
    'status',v_status,
    'updated',v_updated
  );
end
$$;

revoke all on function public.qs_record_quick_solution_payment_status(uuid,text,jsonb) from public, anon, authenticated;
grant execute on function public.qs_record_quick_solution_payment_status(uuid,text,jsonb) to service_role;

-- ── postflight: exactly 7 functions created, create_quick_solution_order and every
--    preserved production function untouched ───────────────────────────────────────
do $postflight$
declare
  v_create_order_hash text;
  v_hash text;
begin
  if to_regprocedure('commerce.qs_begin_payfast_payment(uuid,text)') is null then
    raise exception 'QS_PAYFAST_RPCS_POSTFLIGHT: commerce.qs_begin_payfast_payment(uuid,text) was not created';
  end if;
  if to_regprocedure('commerce.qs_get_payment_status(uuid,text)') is null then
    raise exception 'QS_PAYFAST_RPCS_POSTFLIGHT: commerce.qs_get_payment_status(uuid,text) was not created';
  end if;
  if to_regprocedure('commerce.qs_apply_payfast_payment(uuid,numeric,text,jsonb)') is null then
    raise exception 'QS_PAYFAST_RPCS_POSTFLIGHT: commerce.qs_apply_payfast_payment(uuid,numeric,text,jsonb) was not created';
  end if;
  if to_regprocedure('public.qs_begin_quick_solution_payment(uuid,text)') is null then
    raise exception 'QS_PAYFAST_RPCS_POSTFLIGHT: public.qs_begin_quick_solution_payment(uuid,text) was not created';
  end if;
  if to_regprocedure('public.qs_get_quick_solution_payment_status(uuid,text)') is null then
    raise exception 'QS_PAYFAST_RPCS_POSTFLIGHT: public.qs_get_quick_solution_payment_status(uuid,text) was not created';
  end if;
  if to_regprocedure('public.qs_apply_quick_solution_payment(uuid,numeric,text,jsonb)') is null then
    raise exception 'QS_PAYFAST_RPCS_POSTFLIGHT: public.qs_apply_quick_solution_payment(uuid,numeric,text,jsonb) was not created';
  end if;
  if to_regprocedure('public.qs_record_quick_solution_payment_status(uuid,text,jsonb)') is null then
    raise exception 'QS_PAYFAST_RPCS_POSTFLIGHT: public.qs_record_quick_solution_payment_status(uuid,text,jsonb) was not created';
  end if;

  -- The two abandoned-naming functions must never appear as a side effect of this file.
  if to_regprocedure('public.qs_apply_quick_solution_payfast_payment(uuid,numeric,text,jsonb)') is not null then
    raise exception 'QS_PAYFAST_RPCS_POSTFLIGHT: abandoned public.qs_apply_quick_solution_payfast_payment unexpectedly exists';
  end if;
  if to_regprocedure('public.qs_record_quick_solution_payfast_noncomplete(uuid,text,jsonb)') is not null then
    raise exception 'QS_PAYFAST_RPCS_POSTFLIGHT: abandoned public.qs_record_quick_solution_payfast_noncomplete unexpectedly exists';
  end if;

  select md5(p.prosrc) into v_create_order_hash
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'create_quick_solution_order';
  if v_create_order_hash is distinct from 'd24745c4792c9cc549f9bfab34ac70ba' then
    raise exception 'QS_PAYFAST_RPCS_POSTFLIGHT: public.create_quick_solution_order hash changed to % during this migration - it must remain d24745c4792c9cc549f9bfab34ac70ba', v_create_order_hash;
  end if;

  -- All previously preserved production function hashes remain unchanged.
  for v_hash in
    select case when md5(p.prosrc) = expected.h then 'ok' else
      'QS_PAYFAST_RPCS_POSTFLIGHT: ' || p.proname || ' hash changed to ' || md5(p.prosrc) || ' (expected ' || expected.h || ')'
    end
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    join (values
      ('quote_quick_solution_staff_item','1cd53b781299a0f9f38da1dd8e8787b9'),
      ('get_quick_solution_opps_items','2c379738c970f44a6f7d13adb29fb9cd'),
      ('get_quick_solution_operations_profile','3e89740cb4533da46c47429a7400ccd0'),
      ('is_opps_staff','2767717a6fd60a202ba30343438e6f4e'),
      ('is_opps_workspace_tenant','0edde73cde7c0d15c452bf6e82a75f84'),
      ('has_tenant_permission','138d1867582099cb9580e43ee5e415ae'),
      ('mirror_opps_order_to_xlab_orders','3719be954339c2efe5905179f613a8ed'),
      ('_mirror_opps_order_row','aeab499b1755aad73ad5be16d3c915c6')
    ) as expected(fn, h) on expected.fn = p.proname
    where n.nspname = 'public'
  loop
    if v_hash <> 'ok' then
      raise exception '%', v_hash;
    end if;
  end loop;
end
$postflight$;
