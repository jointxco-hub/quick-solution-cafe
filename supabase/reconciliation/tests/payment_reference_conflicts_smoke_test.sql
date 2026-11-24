-- Synthetic, rollback-only test. Run AFTER the setup and review SQL in
-- a disposable PostgreSQL 17 database. Never run on live data.
BEGIN;
SET LOCAL statement_timeout='30s';
SET LOCAL lock_timeout='5s';
SELECT set_config('request.jwt.claim.role','service_role',true);

INSERT INTO public.tenants(id,slug,status) VALUES
  ('a13674aa-0d62-499e-830d-a54079040026','quick-solution','active');

INSERT INTO public.orders(id,tenant_id) VALUES
  ('eeeeeeee-eeee-4eee-8eee-eeeeeeeeee33',
   'a13674aa-0d62-499e-830d-a54079040026'),
  ('eeeeeeee-eeee-4eee-8eee-eeeeeeeeee34',
   'a13674aa-0d62-499e-830d-a54079040026');

INSERT INTO commerce.service_orders(
  id,tenant_id,order_number,total_amount,payment_status,opps_order_id
) VALUES
  ('00000000-0000-4000-8000-000000000033',
   'a13674aa-0d62-499e-830d-a54079040026',
   'QS-SMOKE-33',60,'unpaid','eeeeeeee-eeee-4eee-8eee-eeeeeeeeee33'),
  ('00000000-0000-4000-8000-000000000034',
   'a13674aa-0d62-499e-830d-a54079040026',
   'QS-SMOKE-34',60,'unpaid','eeeeeeee-eeee-4eee-8eee-eeeeeeeeee34'),
  ('00000000-0000-4000-8000-000000000035',
   'a13674aa-0d62-499e-830d-a54079040026',
   'QS-SMOKE-35',60,'paid',NULL),
  ('00000000-0000-4000-8000-000000000036',
   'a13674aa-0d62-499e-830d-a54079040026',
   'QS-SMOKE-36',60,'unpaid',NULL);

DO $suite$
DECLARE
  a uuid := '00000000-0000-4000-8000-000000000033';
  b uuid := '00000000-0000-4000-8000-000000000034';
  c uuid := '00000000-0000-4000-8000-000000000035';
  d uuid := '00000000-0000-4000-8000-000000000036';
  r jsonb;
BEGIN
  IF NOT EXISTS(
    SELECT 1 FROM pg_class
    WHERE oid='commerce.payment_reference_conflicts'::regclass
      AND relrowsecurity
  )
  OR has_table_privilege(
    'authenticated','commerce.payment_reference_conflicts','SELECT'
  )
  OR has_table_privilege(
    'anon','commerce.payment_reference_conflict_claims','SELECT'
  )
  OR has_function_privilege(
    'authenticated',
    'commerce.qs_record_payment_reference_exception(uuid,numeric,text,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'SECURITY_CONFIGURATION_FAILED';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_class c
    WHERE c.oid IN (
      'commerce.payment_reference_conflicts'::regclass,
      'commerce.payment_reference_conflict_claims'::regclass
    ) AND pg_get_userbyid(c.relowner)<>'supabase_admin'
  )
  OR NOT EXISTS (
    SELECT 1 FROM pg_proc p
    WHERE p.oid='commerce.qs_record_payment_reference_exception(uuid,numeric,text,text)'::regprocedure
      AND pg_get_userbyid(p.proowner)='supabase_admin'
      AND NOT p.prosecdef
  ) THEN
    RAISE EXCEPTION 'OWNER_PARITY_NOT_MAINTAINED';
  END IF;
  RAISE NOTICE 'PASS: Tables are RLS-protected and helper is restricted';
  RAISE NOTICE 'PASS: Trusted recorder, private helper and tables share owner';

  -- Accepted PayFast payment is still canonical and projected only once.
  r:=commerce.qs_apply_payfast_payment(
    a,60,'SMOKE-PF-33-A','{"test":"primary"}'::jsonb
  );
  IF r->>'ok' IS DISTINCT FROM 'true'
     OR r->>'ignored' IS DISTINCT FROM 'false'
     OR r->>'duplicate' IS DISTINCT FROM 'false'
     OR (SELECT count(*) FROM commerce.service_order_payments
         WHERE service_order_id=a AND status='completed')<>1
     OR NOT EXISTS (
         SELECT 1 FROM public.orders
         WHERE id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeee33'::uuid
           AND payment_status='paid' AND deposit_paid=60
     )
  THEN RAISE EXCEPTION 'CANONICAL_ACCEPTANCE_FAILED: %',r;
  END IF;
  RAISE NOTICE 'PASS: Normal R60 payment accepted once';

  r:=commerce.qs_apply_payfast_payment(
    a,60,'SMOKE-PF-33-A','{"test":"replay"}'::jsonb
  );
  IF r->>'duplicate' IS DISTINCT FROM 'true'
     OR r->>'ignored' IS DISTINCT FROM 'true'
     OR (SELECT count(*) FROM commerce.payment_reference_conflicts)<>0
     OR (SELECT count(*) FROM commerce.service_order_payments
         WHERE service_order_id=a)<>1
  THEN RAISE EXCEPTION 'CANONICAL_REPLAY_FAILED: %',r;
  END IF;
  RAISE NOTICE 'PASS: Canonical reference replay is idempotent';

  -- Wrong amount even after the order is paid is preserved as evidence.
  r:=commerce.qs_apply_payfast_payment(
    a,61,'SMOKE-PF-33-B','{"test":"amount"}'::jsonb
  );
  IF r->>'ok' IS DISTINCT FROM 'true'
     OR r->>'conflictRecorded' IS DISTINCT FROM 'true'
     OR r->>'requiresReview' IS DISTINCT FROM 'true'
     OR r->>'reason' IS DISTINCT FROM 'amount_mismatch'
  THEN RAISE EXCEPTION 'PAID_AMOUNT_EXCEPTION_NOT_RECORDED: %',r;
  END IF;

  r:=commerce.qs_apply_payfast_payment(
    a,61,'SMOKE-PF-33-B','{"test":"amount-replayed"}'::jsonb
  );
  IF r->>'conflictRecorded' IS DISTINCT FROM 'true'
     OR NOT EXISTS (
       SELECT 1 FROM commerce.payment_reference_conflicts
       WHERE conflicting_payment_id='SMOKE-PF-33-B'
         AND occurrence_count=2 AND reported_amount=61
         AND expected_amount=60 AND review_status='needs_review'
     )
     OR NOT EXISTS (
       SELECT 1 FROM commerce.payment_reference_conflict_claims cl
       JOIN commerce.payment_reference_conflicts c ON c.id=cl.conflict_id
       WHERE c.conflicting_payment_id='SMOKE-PF-33-B'
         AND cl.service_order_id=a AND cl.occurrence_count=2
     )
  THEN RAISE EXCEPTION 'CONFLICT_REPLAY_IDEMPOTENCY_FAILED';
  END IF;
  RAISE NOTICE 'PASS: Mismatched amount preserved and repeat coalesced';

  -- A resolved case must not silently stay closed on new evidence.
  UPDATE commerce.payment_reference_conflicts
    SET review_status='resolved'
    WHERE conflicting_payment_id='SMOKE-PF-33-B';
  r:=commerce.qs_apply_payfast_payment(
    a,61,'SMOKE-PF-33-B','{"test":"reopened"}'::jsonb
  );
  IF r->>'conflictRecorded' IS DISTINCT FROM 'true'
     OR NOT EXISTS (
       SELECT 1 FROM commerce.payment_reference_conflicts
       WHERE conflicting_payment_id='SMOKE-PF-33-B'
         AND occurrence_count=3
         AND reopened_count=1
         AND review_status='needs_review'
     )
  THEN RAISE EXCEPTION 'RESOLVED_CONFLICT_NOT_REOPENED';
  END IF;
  RAISE NOTICE 'PASS: Resolved conflict reopens on next notification';

  -- A quarantined PayFast id cannot be promoted to the canonical receipt
  -- on a second, as-yet-unpaid order. Preserve its separate claim.
  r:=commerce.qs_apply_payfast_payment(
    b,60,'SMOKE-PF-33-B','{"test":"cross-order"}'::jsonb
  );
  IF r->>'conflictRecorded' IS DISTINCT FROM 'true'
     OR NOT EXISTS (
       SELECT 1 FROM commerce.payment_reference_conflicts
       WHERE conflicting_payment_id='SMOKE-PF-33-B'
         AND occurrence_count=4
         AND reason='cross_order_claim'
     )
     OR (
       SELECT count(*)
       FROM commerce.payment_reference_conflict_claims cl
       JOIN commerce.payment_reference_conflicts c ON c.id=cl.conflict_id
       WHERE c.conflicting_payment_id='SMOKE-PF-33-B'
     )<>2
     OR (SELECT payment_status FROM commerce.service_orders WHERE id=b)<>'unpaid'
     OR EXISTS (
       SELECT 1 FROM commerce.service_order_payments
       WHERE service_order_id=b
     )
  THEN RAISE EXCEPTION 'QUARANTINED_REFERENCE_WAS_ACCEPTED: %',r;
  END IF;
  RAISE NOTICE 'PASS: Cross-order claim visible; quarantined ID cannot be accepted';

  -- Separate valid payment on the second order is still accepted.
  r:=commerce.qs_apply_payfast_payment(
    b,60,'SMOKE-PF-34-A','{"test":"second-order-primary"}'::jsonb
  );
  IF r->>'ok' IS DISTINCT FROM 'true'
     OR r->>'ignored' IS DISTINCT FROM 'false'
     OR (SELECT count(*) FROM commerce.service_order_payments
         WHERE service_order_id=b)<>1
  THEN RAISE EXCEPTION 'SECOND_ORDER_VALID_PAYMENT_FAILED: %',r;
  END IF;
  RAISE NOTICE 'PASS: Second order can accept its own independent reference';

  -- Reusing a genuinely accepted first-order ID on the second order
  -- must create a review claim, not a second canonical receipt.
  r:=commerce.qs_apply_payfast_payment(
    b,60,'SMOKE-PF-33-A','{"test":"canonical-cross-order"}'::jsonb
  );
  IF r->>'conflictRecorded' IS DISTINCT FROM 'true'
     OR r->>'reason' IS DISTINCT FROM 'reference_already_used'
     OR (SELECT count(*) FROM commerce.service_order_payments
         WHERE service_order_id=b)<>1
  THEN RAISE EXCEPTION 'ACCEPTED_REFERENCE_REUSE_UNSAFE: %',r;
  END IF;
  RAISE NOTICE 'PASS: Accepted payment ID cannot be reused for another order';

  -- A paid legacy order without a PayFast receipt must not cause a
  -- helper exception or manufacture a missing receipt.
  r:=commerce.qs_apply_payfast_payment(
    c,60,'SMOKE-PF-35-UNUSUAL','{"test":"paid-no-receipt"}'::jsonb
  );
  IF r->>'conflictRecorded' IS DISTINCT FROM 'true'
     OR EXISTS (
       SELECT 1 FROM commerce.service_order_payments
       WHERE service_order_id=c
     )
  THEN RAISE EXCEPTION 'PAID_NO_RECEIPT_CASE_FAILED: %',r;
  END IF;
  RAISE NOTICE 'PASS: Paid legacy order without PayFast receipt quarantined';

  -- Wrong amount on an unpaid order is recorded and cannot be silently
  -- promoted to a receipt when repeated with a corrected amount.
  r:=commerce.qs_apply_payfast_payment(
    d,61,'SMOKE-PF-36-MISMATCH','{"test":"unpaid-amount"}'::jsonb
  );
  IF r->>'conflictRecorded' IS DISTINCT FROM 'true'
     OR r->>'reason' IS DISTINCT FROM 'amount_mismatch'
  THEN RAISE EXCEPTION 'UNPAID_AMOUNT_MISMATCH_NOT_QUARANTINED: %',r;
  END IF;
  r:=commerce.qs_apply_payfast_payment(
    d,60,'SMOKE-PF-36-MISMATCH','{"test":"corrected-after-conflict"}'::jsonb
  );
  IF r->>'conflictRecorded' IS DISTINCT FROM 'true'
     OR (SELECT payment_status FROM commerce.service_orders WHERE id=d)<>'unpaid'
     OR EXISTS (
       SELECT 1 FROM commerce.service_order_payments
       WHERE service_order_id=d
     )
  THEN RAISE EXCEPTION 'QUARANTINED_UNPAID_REFERENCE_PROMOTED: %',r;
  END IF;
  RAISE NOTICE 'PASS: Unpaid amount mismatch stays out of revenue';

  IF (SELECT count(*) FROM commerce.service_order_payments)<>2
     OR (SELECT count(*)
         FROM commerce.payment_reference_conflicts)<>4
  THEN
     RAISE EXCEPTION 'FINAL_LEDGER_COUNTS_CHANGED';
  END IF;
  RAISE NOTICE 'PASS: Two canonical receipts; four globally unique exceptions';

  -- The staff APIs must explicitly require a signed-in user.
  BEGIN
    PERFORM public.qs_staff_payment_conflicts(a);
    RAISE EXCEPTION 'STAFF_API_ALLOWED_UNSIGNED_USER';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS: Anonymous staff conflict read denied';
  END;
END
$suite$;

-- Only synthetic permissions. No real tenant membership or auth state.
SELECT set_config('request.jwt.claim.sub',
  '22222222-2222-4222-8222-222222222222',true);
SELECT set_config('test.has_capability','true',true);

DO $staff$
DECLARE
  tenant uuid := 'a13674aa-0d62-499e-830d-a54079040026';
  a uuid := '00000000-0000-4000-8000-000000000033';
  result jsonb;
BEGIN
  result:=public.qs_staff_payment_conflicts(a);
  IF result->>'reviewRequired' IS DISTINCT FROM 'true'
     OR jsonb_array_length(result->'conflicts')<>1
  THEN RAISE EXCEPTION 'STAFF_ORDER_READ_FAILED: %',result;
  END IF;

  result:=public.qs_staff_payment_conflict_queue(tenant,50);
  -- The corrected-amount replay creates a second claim for that same
  -- order and reference: claims are distinguished by reported amount.
  IF jsonb_array_length(result->'items')<>6
  THEN RAISE EXCEPTION 'TENANT_QUEUE_SCOPE_FAILED: %',result;
  END IF;
  RAISE NOTICE 'PASS: Authorized staff order read and tenant queue';

  PERFORM set_config('test.has_capability','false',true);
  BEGIN
    PERFORM public.qs_staff_payment_conflict_queue(tenant,50);
    RAISE EXCEPTION 'UNAUTHORIZED_TENANT_QUEUE_VISIBLE';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS: Tenant queue denies unauthorized signed-in user';
  END;
END
$staff$;

-- Remove *every* fixture and simulated payment.
ROLLBACK;
SELECT 'PASS: Isolated SQL smoke transaction fully rolled back' AS result;
