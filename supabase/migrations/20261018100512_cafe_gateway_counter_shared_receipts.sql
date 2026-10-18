-- Preserve existing gateway/counter entry points while sharing original receipt projections.
CREATE OR REPLACE FUNCTION commerce.qs_apply_payfast_payment(p_order_id uuid, p_amount numeric, p_pf_payment_id text, p_raw_itn jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
      'ok',false,
      'reason','amount_mismatch',
      'expected',v_expected,
      'received',round(p_amount,2)
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
      'ok',true,
      'duplicate',v_existing_payment.id is not null,
      'ignored',true,
      'paymentStatus','paid',
      'orderId',v_order.id,
      'orderNumber',v_order.order_number
    );
  end if;

  if v_existing_payment.id is null then
    insert into commerce.service_order_payments (
      tenant_id, service_order_id, provider, status, amount,
      pf_payment_id, raw_itn, completed_at, staff_reference
    )
    values (
      v_order.tenant_id, v_order.id, 'payfast', 'completed', v_expected,
      trim(p_pf_payment_id), coalesce(p_raw_itn,'{}'::jsonb), now(), trim(p_pf_payment_id)
    );
  else
    update commerce.service_order_payments
    set status='completed',
        staff_reference=trim(p_pf_payment_id),
        amount=v_expected,
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
            'provider','payfast',
            'status','paid',
            'paidAt',now(),
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
                '{warnings}',
                v_clean_warnings,
                true
              ),
              '{proposedOppsOrder,payment_status}',
              to_jsonb('paid'::text),
              true
            ),
            '{proposedOppsOrder,deposit_paid}',
            to_jsonb(v_expected),
            true
          ),
        updated_at=now()
    where service_order_id=v_order.id;
  end if;

  -- Capture is authoritative even if an older linked invoice/Finance row needs review.
  -- A projection failure must not discard a validated gateway receipt after funds moved.
  begin
    perform commerce.qs_project_manual_receipt(v_order.id);
  exception when others then
    update commerce.service_orders set source_metadata=coalesce(source_metadata,'{}'::jsonb)
      || jsonb_build_object('paymentProjectionReview',jsonb_build_object('required',true,'reason',sqlerrm,'at',now()))
      where id=v_order.id;
    return jsonb_build_object('ok',true,'duplicate',false,'ignored',false,'paymentStatus','paid',
      'orderId',v_order.id,'orderNumber',v_order.order_number,'amount',v_expected,'projectionReviewRequired',true);
  end;

  return jsonb_build_object(
    'ok',true,
    'duplicate',false,
    'ignored',false,
    'paymentStatus','paid',
    'orderId',v_order.id,
    'orderNumber',v_order.order_number,
    'amount',v_expected
  );
end
$function$;

-- Trusted gateway entry uses the same service-order-first lock as staff entry.
-- Other invoice sources retain their existing PayFast implementation below.
create or replace function commerce.qs_apply_invoice_payfast_payment(
 p_invoice_id uuid,p_order_id uuid,p_amount numeric,p_pf_payment_id text,p_raw_itn jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare o commerce.service_orders; inv public.opps_invoices; result jsonb; payment_id uuid;
begin
 if coalesce(auth.role(),'')<>'service_role' and session_user not in ('postgres','supabase_admin') then
  raise exception using errcode='42501',message='Trusted backend access is required.';
 end if;
 select * into o from commerce.service_orders where id=p_order_id for update;
 select * into inv from public.opps_invoices where id=p_invoice_id for update;
 if o.id is null or inv.id is null or inv.source_order_id is distinct from o.opps_order_id
   or inv.tenant_id is distinct from o.tenant_id then
  return jsonb_build_object('ok',false,'reason','CAFE_INVOICE_LINK_REVIEW_REQUIRED');
 end if;
 if inv.status='void' then return jsonb_build_object('ok',false,'reason','INVOICE_VOID'); end if;
 if nullif(btrim(p_pf_payment_id),'') is null then return jsonb_build_object('ok',false,'reason','PF_PAYMENT_ID_REQUIRED'); end if;
 if p_amount is null or p_amount<=0 then return jsonb_build_object('ok',false,'reason','AMOUNT_INVALID'); end if;
 select ip.id into payment_id from public.invoice_payments ip join commerce.service_order_payments r on r.id=ip.qs_payment_id
  where ip.invoice_id=inv.id and r.service_order_id=o.id and r.provider='payfast' and r.pf_payment_id=btrim(p_pf_payment_id);
 if payment_id is not null then
  return jsonb_build_object('ok',true,'replayed',true,'payment_id',payment_id,'amount_paid',public.invoice_amount_paid(inv.id),
   'balance_due',public.invoice_balance_due(inv.id),'payment_status',public.invoice_payment_status(inv.id));
 end if;
 if public.invoice_payment_status(inv.id)='paid' or public.invoice_balance_due(inv.id)<=0 then
  return jsonb_build_object('ok',true,'ignored',true,'reason','INVOICE_ALREADY_PAID',
   'amount_paid',public.invoice_amount_paid(inv.id),'balance_due',public.invoice_balance_due(inv.id),'payment_status',public.invoice_payment_status(inv.id));
 end if;
 -- A Cafe invoice cannot independently accept a partial settlement of its order.
 if round(p_amount,2) is distinct from o.total_amount or inv.total is distinct from o.total_amount or inv.currency_code is distinct from 'ZAR' then
  return jsonb_build_object('ok',false,'reason','CAFE_INVOICE_AMOUNT_REVIEW_REQUIRED','expected',o.total_amount,'received',round(p_amount,2));
 end if;
 result:=commerce.qs_apply_payfast_payment(o.id,p_amount,p_pf_payment_id,p_raw_itn);
 if not coalesce((result->>'ok')::boolean,false) then return result; end if;
 select ip.id into payment_id from public.invoice_payments ip join commerce.service_order_payments r on r.id=ip.qs_payment_id
  where ip.invoice_id=inv.id and r.service_order_id=o.id and r.provider='payfast' and r.pf_payment_id=btrim(p_pf_payment_id);
 return result||jsonb_build_object('payment_id',payment_id,'amount_paid',public.invoice_amount_paid(inv.id),
  'balance_due',public.invoice_balance_due(inv.id),'payment_status',public.invoice_payment_status(inv.id));
end $$;
revoke all on function commerce.qs_apply_invoice_payfast_payment(uuid,uuid,numeric,text,jsonb) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION public.apply_invoice_payfast_payment(p_invoice_id uuid, p_amount numeric, p_pf_payment_id text, p_raw_itn jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_invoice          public.opps_invoices%rowtype;
  v_cafe_order_id uuid;
  v_amount           numeric(14,2);
  v_ref              text := nullif(btrim(p_pf_payment_id), '');
  v_existing_id      uuid;
  v_row_id           uuid;
  v_balance          numeric(14,2);
  v_status_before    text;
  v_status_after     text;
  v_new_status       text;
  v_effective_status text;
begin
  -- Resolve before the legacy invoice lock to avoid inverse lock order.
  select o.id into v_cafe_order_id from commerce.service_orders o join public.opps_invoices i
    on i.source_order_id=o.opps_order_id and i.tenant_id=o.tenant_id where i.id=p_invoice_id;
  if v_cafe_order_id is not null then
    return commerce.qs_apply_invoice_payfast_payment(p_invoice_id,v_cafe_order_id,p_amount,p_pf_payment_id,p_raw_itn);
  end if;
  if v_ref is null then
    -- A COMPLETE ITN with no pf_payment_id cannot be deduplicated safely —
    -- refuse rather than risk folding it twice or never telling a
    -- legitimate retry apart from a fresh payment.
    return jsonb_build_object('ok', false, 'reason', 'PF_PAYMENT_ID_REQUIRED');
  end if;
  if p_amount is null or p_amount <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'AMOUNT_INVALID');
  end if;
  v_amount := round(p_amount, 2);

  -- ── lock: see ATOMICITY note in 20260913110000. ─────────────────────
  select * into v_invoice from public.opps_invoices where id = p_invoice_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'INVOICE_NOT_FOUND');
  end if;
  if v_invoice.status = 'void' then
    return jsonb_build_object('ok', false, 'reason', 'INVOICE_VOID');
  end if;

  -- ── idempotent replay: same (invoice, pf_payment_id) -> original result,
  --    no second payment, no second activity row. PayFast's own ITN can
  --    and does retry.
  select id into v_existing_id
  from public.invoice_payments
  where invoice_id = p_invoice_id and source = 'payfast' and reference = v_ref
  limit 1;
  if v_existing_id is not null then
    return jsonb_build_object(
      'ok', true, 'replayed', true, 'payment_id', v_existing_id,
      'amount_paid', public.invoice_amount_paid(p_invoice_id),
      'balance_due', public.invoice_balance_due(p_invoice_id),
      'payment_status', public.invoice_payment_status(p_invoice_id)
    );
  end if;

  -- ── already fully settled: never fold in a second, genuinely-distinct
  --    completed PayFast session against an invoice with nothing left
  --    owing (two tabs, a very late notification, a manual payment
  --    recorded meanwhile, ...). Diagnosed separately from the
  --    overpayment case below because it is a calmer, more specific
  --    situation for reconciliation to read. ──────────────────────────
  v_balance       := public.invoice_balance_due(p_invoice_id);
  v_status_before := public.invoice_payment_status(p_invoice_id);
  if v_status_before = 'paid' or v_balance <= 0 then
    return jsonb_build_object(
      'ok', true, 'ignored', true, 'reason', 'INVOICE_ALREADY_PAID',
      'amount_paid', public.invoice_amount_paid(p_invoice_id),
      'balance_due', v_balance, 'payment_status', v_status_before
    );
  end if;

  -- ── OVERPAYMENT POLICY: reject/quarantine, do not record, do not
  --    clamp. See 20260913110000's header comment for the full
  --    reasoning. ───────────────────────────────────────────────────
  if v_amount > v_balance + 0.02 then
    -- Narrow, safe dedupe: PayFast (or a manual replay) resubmitting the
    -- SAME rejected pf_payment_id must not pile up a fresh identical
    -- activity row on every retry. Concurrency safety comes from the
    -- invoice FOR UPDATE lock already held above (this whole function
    -- runs under it) — no new unique index or second ledger table is
    -- needed for that. Deliberately does NOT touch accepted-payment
    -- idempotency, which is a separate, already-indexed path
    -- (invoice_payments_payfast_ref_once).
    if not exists (
      select 1 from public.opps_invoice_activity
      where invoice_id = p_invoice_id
        and activity_type = 'invoice_payment_rejected'
        and metadata->>'reference' = v_ref
        and metadata->>'reason' = 'INVOICE_PAYMENT_OVERPAYMENT_REJECTED'
    ) then
      -- No raw_itn / signature stored here — attempted amount, the balance
      -- at decision time, and the PayFast reference are all reconciliation
      -- needs; the ITN's own signature has already served its one purpose
      -- (validated at the edge-function layer before this RPC is ever
      -- called) and has no further use once durably logged.
      insert into public.opps_invoice_activity (
        invoice_id, tenant_id, activity_type, activity_label, activity_note,
        from_status, to_status, metadata, created_by
      ) values (
        p_invoice_id, v_invoice.tenant_id,
        'invoice_payment_rejected', 'PayFast payment rejected — exceeds balance',
        format('payfast %s exceeds outstanding balance %s · pf_payment_id %s',
               to_char(v_amount, 'FM999999999990.00'), to_char(v_balance, 'FM999999999990.00'), v_ref),
        v_invoice.status, v_invoice.status,
        jsonb_strip_nulls(jsonb_build_object(
          'reason',          'INVOICE_PAYMENT_OVERPAYMENT_REJECTED',
          'amount_received', v_amount,
          'balance_due',     v_balance,
          'reference',       v_ref
        )),
        null
      );
    end if;
    return jsonb_build_object(
      'ok', false, 'reason', 'INVOICE_PAYMENT_OVERPAYMENT_REJECTED',
      'expected_max', v_balance, 'received', v_amount
    );
  end if;

  -- Metadata is a small allowlist, never the raw ITN. `signature` (and
  -- everything else PayFast sends) is dropped here regardless of what the
  -- caller passes as p_raw_itn — the same "no raw_itn / signature stored"
  -- guarantee the rejected-overpayment path above already gives, now
  -- applied to the accepted path too. Only fields with standalone
  -- reconciliation value and no existing canonical column are kept:
  -- amount/pf_payment_id/invoice_id already have their own columns above,
  -- so payment_status, item_name and m_payment_id are redundant with them
  -- and are deliberately left out; amount_fee/amount_net are PayFast's own
  -- fee breakdown and are not captured anywhere else in this schema.
  -- ── valid amount (exact, or a genuine partial ≤ balance): record it ──
  insert into public.invoice_payments (
    tenant_id, invoice_id, amount, paid_at, method, reference, source, order_id, created_by, metadata
  ) values (
    v_invoice.tenant_id, p_invoice_id, v_amount, now(), 'payfast', v_ref, 'payfast',
    v_invoice.source_order_id, null,
    jsonb_strip_nulls(jsonb_build_object(
      'recorded_via', 'apply_invoice_payfast_payment',
      'payfast_amount_fee', nullif(p_raw_itn->>'amount_fee', '')::numeric,
      'payfast_amount_net', nullif(p_raw_itn->>'amount_net', '')::numeric
    ))
  )
  on conflict (invoice_id, reference) where source = 'payfast' and reference is not null
    do nothing
  returning id into v_row_id;

  -- lost a race to a concurrent identical ITN retry -> treat as replay,
  -- not a second payment / second activity row.
  if v_row_id is null then
    select id into v_row_id
    from public.invoice_payments
    where invoice_id = p_invoice_id and source = 'payfast' and reference = v_ref
    limit 1;
    return jsonb_build_object(
      'ok', true, 'replayed', true, 'payment_id', v_row_id,
      'amount_paid', public.invoice_amount_paid(p_invoice_id),
      'balance_due', public.invoice_balance_due(p_invoice_id),
      'payment_status', public.invoice_payment_status(p_invoice_id)
    );
  end if;

  -- trg_invoice_payments_refresh_cache has now recomputed
  -- opps_invoices.amount_paid / balance_due from the ledger.

  -- ── compat status mirror — identical safe-transition rules to
  --    record_manual_invoice_payment (never overwrites draft / void /
  --    exported / imported_to_zoho).
  v_status_after     := public.invoice_payment_status(p_invoice_id);
  v_effective_status := v_invoice.status;
  if v_invoice.status in ('approved', 'partially_paid') then
    v_new_status := case v_status_after
                      when 'paid'    then 'paid'
                      when 'partial' then 'partially_paid'
                      else null
                    end;
  elsif v_invoice.status = 'overdue' and v_status_after = 'paid' then
    v_new_status := 'paid';
  end if;
  if v_new_status is not null and v_new_status is distinct from v_invoice.status then
    update public.opps_invoices set status = v_new_status where id = p_invoice_id;
    v_effective_status := v_new_status;
  end if;

  -- ── canonical payment audit event (same transaction) ────────────
  -- created_by is NULL: this is a customer-initiated, webhook-reconciled
  -- payment, not a staff action.
  insert into public.opps_invoice_activity (
    invoice_id, tenant_id, activity_type, activity_label, activity_note,
    from_status, to_status, metadata, created_by
  ) values (
    p_invoice_id, v_invoice.tenant_id,
    'invoice_payment_recorded', 'Payment recorded',
    format('payfast %s · pf_payment_id %s', to_char(v_amount, 'FM999999999990.00'), v_ref),
    v_invoice.status, v_effective_status,
    jsonb_strip_nulls(jsonb_build_object(
      'payment_id',     v_row_id,
      'amount',         v_amount,
      'source',         'payfast',
      'method',         'payfast',
      'reference',      v_ref,
      'payment_status', v_status_after,
      'amount_paid',    public.invoice_amount_paid(p_invoice_id),
      'balance_due',    public.invoice_balance_due(p_invoice_id)
    )),
    null
  );

  return jsonb_build_object(
    'ok', true, 'replayed', false, 'payment_id', v_row_id,
    'amount_paid', public.invoice_amount_paid(p_invoice_id),
    'balance_due', public.invoice_balance_due(p_invoice_id),
    'payment_status', v_status_after
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.record_quick_solution_counter_payment(p_order_id uuid, p_method text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_actor uuid;
  v_tenant_id uuid;
  v_key text;
  v_stored_key text;
  v_order commerce.service_orders;
  v_existing commerce.service_order_payments;
  v_block text;
  v_amount numeric;
  v_paid numeric;
  v_payment_id uuid;
  v_paid_at timestamptz;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception using errcode = '42501', message = 'Staff sign-in is required.';
  end if;

  select t.id
  into v_tenant_id
  from public.tenants t
  where t.slug = 'quick-solution'
    and t.status = 'active'
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode = '22023', message = 'Quick Solution tenant was not found.';
  end if;

  if not public.has_tenant_capability(v_tenant_id, 'cafe.counter.operate') then
    raise exception using errcode = '42501', message = 'You do not have access to the Quick Solution counter.';
  end if;

  if not exists (
    select 1
    from public.tenant_capabilities tc
    where tc.tenant_id = v_tenant_id
      and tc.capability_key = 'quick_solution'
      and tc.enabled = true
  ) then
    raise exception using errcode = '22023', message = 'Quick Solution counter is not active.';
  end if;

  -- input: exactly the two supported methods, no mapping, no case folding
  if p_method is null or p_method not in ('cash', 'card') then
    raise exception using errcode = '22023', message = 'Payment method is not supported.';
  end if;
  v_key := trim(coalesce(p_idempotency_key, ''));
  if length(v_key) < 8 then
    raise exception using errcode = '22023', message = 'Payment idempotency key is required.';
  end if;
  if length(v_key) > 128 then
    raise exception using errcode = '22023', message = 'Payment idempotency key is not valid.';
  end if;
  if p_order_id is null then
    raise exception using errcode = '22023', message = 'Counter order was not found.';
  end if;

  -- serialize on the key, then on the order (always in this order, so two callers cannot deadlock)
  v_stored_key := 'counter-payment:' || v_actor::text || ':' || v_key;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_tenant_id::text || '|' || v_stored_key, 0));

  select so.*
  into v_order
  from commerce.service_orders so
  where so.id = p_order_id
    and so.tenant_id = v_tenant_id
    and (
      so.channel = 'counter'
      or exists (
        select 1 from commerce.service_order_payments p
        where p.service_order_id = so.id
          and p.provider = 'counter'
          and p.status = 'pending'
      )
    )
  for update;

  -- a retry of a payment this actor already recorded returns the original, whatever the order looks like now
  select p.*
  into v_existing
  from commerce.service_order_payments p
  where p.tenant_id = v_tenant_id
    and p.idempotency_key = v_stored_key;

  if v_existing.id is not null then
    if v_existing.service_order_id is distinct from p_order_id
       or v_existing.provider is distinct from p_method
       or v_existing.recorded_by is distinct from v_actor then
      raise exception using errcode = '23505', message = 'This payment key was already used for a different payment request.';
    end if;
    return jsonb_build_object(
      'ok', true,
      'replayed', true,
      'alreadyPaid', false,
      'orderId', v_existing.service_order_id,
      'orderNumber', v_order.order_number,
      'paymentId', v_existing.id,
      'method', v_existing.provider,
      'amount', v_existing.amount,
      'paidAt', v_existing.completed_at,
      'paymentStatus', v_order.payment_status,
      'totalAmount', v_order.total_amount,
      'amountPaid', commerce._qs_order_amount_paid(v_order.id),
      'outstanding', greatest(round(v_order.total_amount - commerce._qs_order_amount_paid(v_order.id), 2), 0)
    );
  end if;

  if v_order.id is null then
    raise exception using errcode = '22023', message = 'Counter order was not found.';
  end if;

  v_block := commerce._qs_counter_payment_block(v_order);
  if v_block = 'already_paid' then
    return jsonb_build_object(
      'ok', false,
      'reason', 'already_paid',
      'orderId', v_order.id,
      'orderNumber', v_order.order_number,
      'paymentStatus', v_order.payment_status
    );
  elsif v_block = 'sent_to_production' then
    raise exception using errcode = '22023', message = 'This order has already been sent to production and cannot take a counter payment.';
  elsif v_block = 'nothing_outstanding' then
    raise exception using errcode = '22023', message = 'This order has nothing outstanding.';
  elsif v_block is not null then
    raise exception using errcode = '22023', message = 'This order cannot take a payment.';
  end if;

  -- the server decides the amount: everything still outstanding
  v_amount := round(v_order.total_amount - commerce._qs_order_amount_paid(v_order.id), 2);
  v_paid_at := clock_timestamp();

  insert into commerce.service_order_payments (
    tenant_id, service_order_id, provider, status, amount, initiated_at, completed_at, recorded_by, idempotency_key
  )
  values (
    v_tenant_id, v_order.id, p_method, 'completed', v_amount, v_paid_at, v_paid_at, v_actor, v_stored_key
  )
  returning id into v_payment_id;

  v_paid := commerce._qs_order_amount_paid(v_order.id);
  if round(v_order.total_amount - v_paid, 2) <> 0 then
    raise exception using errcode = '22023', message = 'The recorded amount does not settle the order.';
  end if;

  update commerce.service_order_payments
  set status = 'cancelled', updated_at = now()
  where service_order_id = v_order.id
    and provider = 'counter'
    and status = 'pending';

  update commerce.service_orders
  set payment_status = 'paid',
      source_metadata = coalesce(source_metadata, '{}'::jsonb) ||
        jsonb_build_object('payment', jsonb_build_object('provider', p_method, 'status', 'paid', 'paidAt', v_paid_at)),
      updated_at = now()
  where id = v_order.id;

  perform commerce.qs_project_manual_receipt(v_order.id);

  return jsonb_build_object(
    'ok', true,
    'replayed', false,
    'alreadyPaid', false,
    'orderId', v_order.id,
    'orderNumber', v_order.order_number,
    'paymentId', v_payment_id,
    'method', p_method,
    'amount', v_amount,
    'paidAt', v_paid_at,
    'paymentStatus', 'paid',
    'totalAmount', v_order.total_amount,
    'amountPaid', v_paid,
    'outstanding', 0
  );
end
$function$;
