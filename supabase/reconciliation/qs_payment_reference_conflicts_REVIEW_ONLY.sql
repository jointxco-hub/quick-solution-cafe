-- REVIEW DRAFT — NOT A MIGRATION. DO NOT APPLY TO STAGING/PRODUCTION.
-- This file belongs in supabase/reconciliation until an isolated v8
-- restore test and Supabase CLI-generated migration file are complete.
-- Grounded in 20261018100512_cafe_gateway_counter_shared_receipts.sql.
-- The Quick Solution PayFast Edge Function PR #51 expects its response
-- contract; deploy this database change first, after separate approval.
-- WARNING: This adds tables and replaces a payment-capture function.
-- This review draft is not compatible with v7's experimental conflict table.

-- Make ownership, security grants, function replacement and all tables
-- atomic: an error must not leave a partially exposed review API.
BEGIN;
SET LOCAL statement_timeout='60s';
SET LOCAL lock_timeout='5s';

DO $prerequisites$
BEGIN
  IF to_regclass('commerce.service_orders') IS NULL
     OR to_regclass('commerce.service_order_payments') IS NULL
     OR to_regprocedure(
       'commerce.qs_apply_payfast_payment(uuid,numeric,text,jsonb)'
     ) IS NULL
     OR to_regprocedure(
       'commerce.qs_project_manual_receipt(uuid)'
     ) IS NULL
     OR to_regclass('commerce.payment_reference_conflicts') IS NOT NULL
     OR to_regclass('commerce.payment_reference_conflict_claims') IS NOT NULL
  THEN
    RAISE EXCEPTION 'QS_PAYMENT_CONFLICT_MIGRATION_PREREQUISITES_FAILED';
  END IF;
END
$prerequisites$;

CREATE TABLE commerce.payment_reference_conflicts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES public.tenants(id),
    service_order_id uuid NOT NULL REFERENCES commerce.service_orders(id),
    accepted_receipt_id uuid NULL REFERENCES commerce.service_order_payments(id),
    provider text NOT NULL DEFAULT 'payfast'
        CHECK (provider='payfast'),
    conflicting_payment_id text NOT NULL
        CHECK (
            length(conflicting_payment_id) BETWEEN 1 AND 512
            AND conflicting_payment_id=btrim(conflicting_payment_id)
        ),
    expected_amount numeric(12,2) NOT NULL CHECK(expected_amount>0),
    reported_amount numeric(12,2) NOT NULL CHECK(reported_amount>0),
    reason text NOT NULL CHECK (
        reason IN (
            'different_payment_reference_for_paid_order',
            'amount_mismatch',
            'reference_already_used',
            'cross_order_claim'
        )
    ),
    verification_status text NOT NULL DEFAULT 'unverified'
        CHECK (verification_status IN ('unverified','verified')),
    review_status text NOT NULL DEFAULT 'needs_review'
        CHECK (review_status IN ('needs_review','under_investigation','resolved')),
    occurrence_count integer NOT NULL DEFAULT 1 CHECK(occurrence_count>=1),
    reopened_count integer NOT NULL DEFAULT 0 CHECK(reopened_count>=0),
    last_claimed_service_order_id uuid NOT NULL REFERENCES commerce.service_orders(id),
    last_reported_amount numeric(12,2) NOT NULL CHECK(last_reported_amount>0),
    first_seen_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    last_seen_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (last_seen_at>=first_seen_at),
    CONSTRAINT payment_reference_conflicts_global_reference
        UNIQUE (provider, conflicting_payment_id)
);

CREATE TABLE commerce.payment_reference_conflict_claims (
    conflict_id uuid NOT NULL
        REFERENCES commerce.payment_reference_conflicts(id) ON DELETE RESTRICT,
    tenant_id uuid NOT NULL REFERENCES public.tenants(id),
    service_order_id uuid NOT NULL REFERENCES commerce.service_orders(id),
    reported_amount numeric(12,2) NOT NULL CHECK(reported_amount>0),
    reason text NOT NULL CHECK (
        reason IN (
            'different_payment_reference_for_paid_order',
            'amount_mismatch',
            'reference_already_used',
            'cross_order_claim'
        )
    ),
    occurrence_count integer NOT NULL DEFAULT 1 CHECK(occurrence_count>=1),
    first_seen_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    last_seen_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK(last_seen_at>=first_seen_at),
    PRIMARY KEY(conflict_id,service_order_id,reported_amount)
);

CREATE INDEX payment_reference_conflicts_review
ON commerce.payment_reference_conflicts (tenant_id,review_status,first_seen_at DESC);

CREATE INDEX payment_reference_conflict_claims_tenant_order
ON commerce.payment_reference_conflict_claims
    (tenant_id,service_order_id,first_seen_at DESC);

ALTER TABLE commerce.payment_reference_conflicts ENABLE ROW LEVEL SECURITY;
ALTER TABLE commerce.payment_reference_conflict_claims ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON commerce.payment_reference_conflicts
    FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON commerce.payment_reference_conflict_claims
    FROM PUBLIC,anon,authenticated,service_role;

COMMENT ON TABLE commerce.payment_reference_conflicts IS
  'Gateway reference evidence, not receipts/revenue. Global PayFast reference uniqueness; no customer ITN payload. Staff verification pending.';
COMMENT ON TABLE commerce.payment_reference_conflict_claims IS
  'Scoped claim evidence per order and reported amount for one globally unique gateway payment ID.';

-- SECURITY INVOKER inherits the trusted owner of the existing recorder.
-- No direct client or service-role EXECUTE grants are provided.
CREATE FUNCTION commerce.qs_record_payment_reference_exception(
    p_order_id uuid,
    p_reported_amount numeric,
    p_payment_id text,
    p_reason text
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO ''
AS $helper$
DECLARE
    v_order commerce.service_orders;
    v_receipt_id uuid;
    v_conflict_id uuid;
    v_reference text := btrim(coalesce(p_payment_id,''));
    v_amount numeric(12,2) := round(p_reported_amount,2);
    v_reopen_status text;
BEGIN
    IF p_order_id IS NULL OR p_reported_amount IS NULL
       OR p_reported_amount<=0
       OR v_reference='' OR length(v_reference)>512
       OR p_reason NOT IN (
          'different_payment_reference_for_paid_order',
          'amount_mismatch',
          'reference_already_used'
       )
    THEN
        RAISE EXCEPTION 'INVALID_REFERENCE_EXCEPTION_ARGUMENTS';
    END IF;

    SELECT * INTO v_order
    FROM commerce.service_orders
    WHERE id=p_order_id
    FOR UPDATE;

    IF v_order.id IS NULL THEN
        RAISE EXCEPTION 'REFERENCE_EXCEPTION_ORDER_NOT_FOUND';
    END IF;

    SELECT id INTO v_receipt_id
    FROM commerce.service_order_payments
    WHERE service_order_id=v_order.id
      AND provider='payfast'
      AND status='completed'
    ORDER BY completed_at,id
    LIMIT 1;

    INSERT INTO commerce.payment_reference_conflicts(
        tenant_id,service_order_id,accepted_receipt_id,
        provider,conflicting_payment_id,expected_amount,
        reported_amount,reason,last_claimed_service_order_id,
        last_reported_amount
    ) VALUES (
        v_order.tenant_id,v_order.id,v_receipt_id,
        'payfast',v_reference,round(v_order.total_amount,2),
        v_amount,p_reason,v_order.id,v_amount
    )
    ON CONFLICT ON CONSTRAINT payment_reference_conflicts_global_reference
    DO UPDATE SET
        occurrence_count=commerce.payment_reference_conflicts.occurrence_count+1,
        last_seen_at=clock_timestamp(),
        last_claimed_service_order_id=EXCLUDED.service_order_id,
        last_reported_amount=EXCLUDED.reported_amount,
        reason=CASE
          WHEN commerce.payment_reference_conflicts.service_order_id
               <> EXCLUDED.service_order_id THEN 'cross_order_claim'
          WHEN commerce.payment_reference_conflicts.reason='cross_order_claim'
               THEN 'cross_order_claim'
          ELSE EXCLUDED.reason
        END,
        review_status=CASE
          WHEN commerce.payment_reference_conflicts.review_status='resolved'
            THEN 'needs_review'
          ELSE commerce.payment_reference_conflicts.review_status
        END,
        reopened_count=commerce.payment_reference_conflicts.reopened_count+
          CASE WHEN commerce.payment_reference_conflicts.review_status='resolved'
               THEN 1 ELSE 0 END
    RETURNING id,review_status INTO v_conflict_id,v_reopen_status;

    INSERT INTO commerce.payment_reference_conflict_claims(
        conflict_id,tenant_id,service_order_id,reported_amount,reason
    ) VALUES (
        v_conflict_id,v_order.tenant_id,v_order.id,v_amount,p_reason
    )
    ON CONFLICT(conflict_id,service_order_id,reported_amount)
    DO UPDATE SET
        occurrence_count=
          commerce.payment_reference_conflict_claims.occurrence_count+1,
        last_seen_at=clock_timestamp(),
        reason=EXCLUDED.reason;

    -- No writes to service_order_payments, invoices or Finance are permitted
    -- anywhere in this helper.
END
$helper$;

REVOKE ALL ON FUNCTION commerce.qs_record_payment_reference_exception(
    uuid,numeric,text,text
) FROM PUBLIC,anon,authenticated,service_role;

-- This is the current gateway recorder, with only the already-paid,
-- mismatched-amount, and cross-order-reference branches changed.

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

  -- The order lock is the canonical receipt/Finance serialization boundary.
  -- An unfamiliar or mismatched gateway reference is *evidence*, not a
  -- second accepted receipt. Durable evidence is written before HTTP ack.
  select * into v_existing_payment
  from commerce.service_order_payments p
  where p.provider='payfast'
    and p.pf_payment_id=trim(p_pf_payment_id)
  limit 1;

  -- A reference previously quarantined as an exception must not later
  -- become an accepted receipt for another order. The global exception
  -- uniqueness constraint also serializes competing cross-order claims.
  if exists (
    select 1 from commerce.payment_reference_conflicts c
    where c.provider='payfast'
      and c.conflicting_payment_id=trim(p_pf_payment_id)
  ) then
    perform commerce.qs_record_payment_reference_exception(
      v_order.id,p_amount,trim(p_pf_payment_id),'reference_already_used'
    );
    return jsonb_build_object(
      'ok',true,'ignored',true,'duplicate',false,
      'conflictRecorded',true,'requiresReview',true,
      'reason','reference_already_used',
      'paymentStatus',v_order.payment_status,
      'orderId',v_order.id,'orderNumber',v_order.order_number
    );
  end if;

  if v_existing_payment.id is not null
     and v_existing_payment.service_order_id <> v_order.id then
    perform commerce.qs_record_payment_reference_exception(
      v_order.id,p_amount,trim(p_pf_payment_id),'reference_already_used'
    );
    return jsonb_build_object(
      'ok',true,'ignored',true,'duplicate',false,
      'conflictRecorded',true,'requiresReview',true,
      'reason','reference_already_used',
      'paymentStatus',v_order.payment_status,
      'orderId',v_order.id,'orderNumber',v_order.order_number
    );
  end if;

  if round(p_amount,2) <> v_expected then
    perform commerce.qs_record_payment_reference_exception(
      v_order.id,p_amount,trim(p_pf_payment_id),'amount_mismatch'
    );
    return jsonb_build_object(
      'ok',true,'ignored',true,'duplicate',false,
      'conflictRecorded',true,'requiresReview',true,
      'reason','amount_mismatch',
      'expected',v_expected,'received',round(p_amount,2),
      'paymentStatus',v_order.payment_status,
      'orderId',v_order.id,'orderNumber',v_order.order_number
    );
  end if;

  if v_order.payment_status='paid' then
    if v_existing_payment.id is not null
       and v_existing_payment.status='completed' then
      return jsonb_build_object(
        'ok',true,'duplicate',true,'ignored',true,
        'paymentStatus','paid',
        'orderId',v_order.id,'orderNumber',v_order.order_number
      );
    end if;
    perform commerce.qs_record_payment_reference_exception(
      v_order.id,p_amount,trim(p_pf_payment_id),
      'different_payment_reference_for_paid_order'
    );
    return jsonb_build_object(
      'ok',true,'ignored',true,'duplicate',false,
      'conflictRecorded',true,'requiresReview',true,
      'reason','different_payment_reference_for_paid_order',
      'paymentStatus','paid',
      'orderId',v_order.id,'orderNumber',v_order.order_number
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

-- Preserve original RPC authorization. This non-public function remains
-- service-role only; its public service-role wrapper is unchanged.
REVOKE ALL ON FUNCTION commerce.qs_apply_payfast_payment(uuid,numeric,text,jsonb)
    FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION commerce.qs_apply_payfast_payment(uuid,numeric,text,jsonb)
    TO service_role;

-- Staff read contract: tenant membership alone is insufficient.
-- Reuses the exact capability/permission checks in qs_staff_payment_state.
CREATE FUNCTION public.qs_staff_payment_conflicts(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $read$
DECLARE
    v_order commerce.service_orders;
    v_items jsonb := '[]'::jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Staff sign-in is required.';
    END IF;
    SELECT so.* INTO v_order
    FROM commerce.service_orders so
    JOIN public.tenants t ON t.id=so.tenant_id
    WHERE so.id=p_order_id AND t.slug='quick-solution'
      AND t.status='active';

    IF v_order.id IS NULL OR NOT (
      public.has_tenant_capability(v_order.tenant_id,'cafe.operations.manage')
      OR public.has_tenant_permission(v_order.tenant_id,'payments.manage')
    ) THEN
        RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Order is unavailable.';
    END IF;

    SELECT coalesce(jsonb_agg(
        jsonb_build_object(
            'reference',c.conflicting_payment_id,
            'reason',c.reason,
            'reportedAmount',cl.reported_amount,
            'expectedAmount',v_order.total_amount,
            'occurrences',cl.occurrence_count,
            'reviewStatus',c.review_status,
            'verificationStatus',c.verification_status,
            'firstSeenAt',cl.first_seen_at,
            'lastSeenAt',cl.last_seen_at,
            'crossOrderClaim',c.reason='cross_order_claim'
        ) ORDER BY cl.first_seen_at DESC,c.conflicting_payment_id
    ),'[]'::jsonb) INTO v_items
    FROM commerce.payment_reference_conflict_claims cl
    JOIN commerce.payment_reference_conflicts c ON c.id=cl.conflict_id
    WHERE cl.service_order_id=v_order.id
      AND cl.tenant_id=v_order.tenant_id;

    RETURN jsonb_build_object(
        'orderId',v_order.id,
        'orderNumber',v_order.order_number,
        'reviewRequired',coalesce(
          (SELECT bool_or(c.review_status<>'resolved')
           FROM commerce.payment_reference_conflict_claims cl
           JOIN commerce.payment_reference_conflicts c
             ON c.id=cl.conflict_id
           WHERE cl.service_order_id=v_order.id
             AND cl.tenant_id=v_order.tenant_id
          ),false),
        'conflicts',v_items
    );
END
$read$;

REVOKE ALL ON FUNCTION public.qs_staff_payment_conflicts(uuid)
    FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.qs_staff_payment_conflicts(uuid)
    TO authenticated;

COMMENT ON FUNCTION public.qs_staff_payment_conflicts(uuid) IS
    'Staff-only tenant-scoped PayFast conflict evidence. Does not disclose full ITN data or reallocate payments.';

-- Open-case queue filtered by the claim's tenant (not merely the
-- original conflict's tenant), so cross-order claims remain visible.
CREATE FUNCTION public.qs_staff_payment_conflict_queue(
    p_tenant_id uuid,
    p_limit integer DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $queue$
DECLARE
    v_items jsonb := '[]'::jsonb;
BEGIN
    IF auth.uid() IS NULL
       OR p_tenant_id IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM public.tenants
           WHERE id=p_tenant_id AND slug='quick-solution'
             AND status='active'
       )
       OR NOT (
         public.has_tenant_capability(p_tenant_id,'cafe.operations.manage')
         OR public.has_tenant_permission(p_tenant_id,'payments.manage')
       )
    THEN
        RAISE EXCEPTION USING ERRCODE='42501',
            MESSAGE='Payment conflict queue is unavailable.';
    END IF;

    SELECT coalesce(jsonb_agg(row_data ORDER BY row_data->>'firstSeenAt' DESC),
      '[]'::jsonb) INTO v_items
    FROM (
      SELECT jsonb_build_object(
        'orderId',cl.service_order_id,
        'orderNumber',so.order_number,
        'reference',c.conflicting_payment_id,
        'reason',c.reason,
        'reportedAmount',cl.reported_amount,
        'expectedAmount',so.total_amount,
        'occurrences',cl.occurrence_count,
        'reviewStatus',c.review_status,
        'verificationStatus',c.verification_status,
        'firstSeenAt',cl.first_seen_at,
        'lastSeenAt',cl.last_seen_at,
        'crossOrderClaim',c.reason='cross_order_claim'
      ) AS row_data
      FROM commerce.payment_reference_conflict_claims cl
      JOIN commerce.payment_reference_conflicts c ON c.id=cl.conflict_id
      JOIN commerce.service_orders so ON so.id=cl.service_order_id
      WHERE cl.tenant_id=p_tenant_id
        AND so.tenant_id=p_tenant_id
        AND c.review_status IN ('needs_review','under_investigation')
      ORDER BY cl.first_seen_at DESC
      LIMIT least(greatest(coalesce(p_limit,50),1),100)
    ) items;

    RETURN jsonb_build_object('tenantId',p_tenant_id,'items',v_items);
END
$queue$;

REVOKE ALL ON FUNCTION public.qs_staff_payment_conflict_queue(uuid,integer)
    FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.qs_staff_payment_conflict_queue(uuid,integer)
    TO authenticated;

COMMENT ON FUNCTION public.qs_staff_payment_conflict_queue(uuid,integer) IS
    'Staff-only open PayFast exception queue. Tenant-scoped by claim and order, never by the original conflict owner alone.';

-- Database hygiene / accidental exposure checks for review.
DO $verify$
BEGIN
    IF NOT EXISTS(
      SELECT 1 FROM pg_class
      WHERE oid='commerce.payment_reference_conflicts'::regclass
        AND relrowsecurity
    )
    OR NOT EXISTS(
      SELECT 1 FROM pg_class
      WHERE oid='commerce.payment_reference_conflict_claims'::regclass
        AND relrowsecurity
    )
    OR has_table_privilege(
      'authenticated','commerce.payment_reference_conflicts','SELECT'
    )
    OR has_table_privilege(
      'anon','commerce.payment_reference_conflict_claims','SELECT'
    )
    OR has_function_privilege(
      'anon','public.qs_staff_payment_conflicts(uuid)','EXECUTE'
    )
    OR has_function_privilege(
      'anon','public.qs_staff_payment_conflict_queue(uuid,integer)','EXECUTE'
    )
    OR has_function_privilege(
      'authenticated',
      'commerce.qs_record_payment_reference_exception(uuid,numeric,text,text)',
      'EXECUTE'
    )
    THEN
      RAISE EXCEPTION 'QS_PAYMENT_CONFLICT_SECURITY_VERIFICATION_FAILED';
    END IF;
END
$verify$;

COMMIT;
