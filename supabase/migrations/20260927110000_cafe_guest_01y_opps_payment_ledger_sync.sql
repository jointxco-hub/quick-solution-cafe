-- CAFE-GUEST-01Y: a Quick Solution order handed to OPPS carries its actual payment into the OPPS
-- payment ledger (public.transactions), so the order's Paid flag can never disagree with what OPPS's own
-- Payments tab shows.
--
-- THE BUG. public.admin_send_quick_solution_order_to_opps (QS-04B) has always written
-- public.orders.payment_status/deposit_paid straight from the handoff preview's mapping of the Quick
-- Solution order's OWN payment_status - a plain string copy, never anything written to OPPS's payment
-- ledger. OPPS's Payments tab does not read payment_status or deposit_paid at all: it computes "Total Paid"
-- and "Balance" from SUM(amount) of public.transactions rows (type = 'income', payment_status =
-- 'completed') linked to the order. With zero such rows, the tab correctly shows "No payments recorded" /
-- Total Paid R0 / the full balance outstanding - while the order header, reading the copied payment_status,
-- says Paid. Two representations of the same fact, fed from two different places, free to disagree. This
-- affects every channel the handoff serves (counter cash/card AND storefront PayFast), not only counter
-- orders: neither channel has ever written a transactions row.
--
-- THE FIX HAS TWO PARTS, run together, atomically, every time a Quick Solution order is (re)sent to OPPS
-- (fresh send, recovered send, or a pure replay of an already-sent order):
--
--   1. IMPORT. commerce._qs_sync_opps_payment_ledger(service_order_id, opps_order_id) reads
--      commerce.service_order_payments (the ONE source of truth for what was actually paid in Quick
--      Solution, already used by the Café-side ledger helpers) and, only when at least one COMPLETED
--      payment exists, inserts exactly one public.transactions row for it: `type='income'`,
--      `payment_status='completed'`, `amount` = the sum of completed payments (currently always exactly one:
--      neither the counter nor the storefront/PayFast path supports more than one completed payment per
--      order today), `payment_method` mapped from the Café provider - 'cash'/'card' pass straight through
--      (transactions.payment_method allows them natively); PayFast, and anything else the ledger might one
--      day carry, becomes 'other' (transactions.payment_method has no 'payfast' value), with the real
--      provider and, for a single payment, its detail kept in `notes` - nothing is fabricated, nothing is
--      silently reclassified as cash or card when it was not. `source = 'quick_solution'` marks provenance,
--      matching public.orders.source. Never inserted for an order with zero completed Café payments -
--      requirement 5 is therefore structural, not a branch that could be forgotten.
--
--      IDEMPOTENT BY THE EXISTING SCHEMA, NOT A NEW ONE: public.transactions already carries a plain UNIQUE
--      INDEX on order_id (transactions_order_id_unique) - at most one transaction row per order, of any
--      kind, already the rule this table lives under. The insert is `on conflict (order_id) do nothing`, so
--      a retry, a replay, or a second handoff attempt can never create a duplicate payment; it also means a
--      transaction someone already entered for that order manually is never overwritten. tenant_id is left
--      for the existing trg_transactions_tenant trigger to fill in from order_id, so tenant isolation for the
--      new row is enforced exactly as it already is for every other transaction, not re-implemented here.
--
--   2. REPROJECT. The order's own payment_status/deposit_paid are then set FROM the ledger just read (the
--      same SUM used above, re-read from public.transactions so a pre-existing manual entry counts too, not
--      only what step 1 just inserted): 'paid' only when that sum covers the order's total_amount, 'pending'
--      otherwise (also public.orders' only two ledger-derived states) - the copied-string path is removed
--      entirely, so the two representations cannot drift apart: whatever the ledger says is now the only
--      thing that decides Paid. An order with a smaller completed sum than its total (a partial payment, if
--      the Café model ever allows one - it does not today) reports that ACTUAL amount as deposit_paid and
--      stays 'pending', never forced to 'paid' (requirement 6). An order with zero completed payments reports
--      deposit_paid = 0 and 'pending' (never 'paid') - fixing exactly the bug reported on a real order that
--      had been marked paid with an empty ledger.
--
-- WHERE IT RUNS: the sync call is added to every success path of admin_send_quick_solution_order_to_opps -
-- the pure replay (already linked, verified), the two recovery paths (an existing OPPS order verified by
-- backlink or by order_number), and the fresh insert - so calling it again on an order already sent, or on
-- one being sent for the first time, both leave payment_status/deposit_paid exactly reprojected from the
-- ledger. Nothing else in that function changes: the blocked-handoff path, the reason/authorization checks,
-- the order/handoff-row writes and the idempotency key are all untouched.
--
-- SCOPE: applies to every source = 'quick_solution' order this function sends, whichever channel it
-- originated on. commerce.service_order_payments already holds both cash/card (CAFE-GUEST-01Q) and PayFast
-- rows, so the storefront/PayFast path gains the identical fix, not a separate one - and gains it only in
-- the direction of MORE consistency (a ledger row and a correctly reprojected Paid flag where there was
-- none), never in a way that changes what a storefront order looks like today (its own PayFast-side
-- public.orders update from QS-08's ITN handler is untouched, and this only ever runs at Café->OPPS send
-- time, which a storefront order already reaches through this exact function).
--
-- DEPENDENCY: QS-04B (public.admin_send_quick_solution_order_to_opps), the QS-08/CAFE-GUEST-01Q payment
-- ledger (commerce.service_order_payments), and public.transactions with its existing order_id unique index
-- and tenant-assignment trigger.

do $preflight$
begin
  if to_regprocedure('public.admin_send_quick_solution_order_to_opps(uuid)') is null then
    raise exception 'CAFE_GUEST_01Y_MIGRATION_PRECONDITION: QS-04B''s admin_send_quick_solution_order_to_opps must exist';
  end if;
  if to_regclass('commerce.service_order_payments') is null or to_regclass('public.transactions') is null then
    raise exception 'CAFE_GUEST_01Y_MIGRATION_PRECONDITION: the Cafe payment ledger and OPPS transactions table must exist';
  end if;
  if not exists (
    select 1 from pg_indexes where schemaname = 'public' and tablename = 'transactions' and indexname = 'transactions_order_id_unique'
  ) then
    raise exception 'CAFE_GUEST_01Y_MIGRATION_PRECONDITION: transactions_order_id_unique must exist for the idempotent import to be safe';
  end if;
end
$preflight$;

-- ── the one sync rule: import the Cafe payment, then reproject the order's Paid flag from the ledger ──
create or replace function commerce._qs_sync_opps_payment_ledger(p_service_order_id uuid, p_opps_order_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order commerce.service_orders;
  v_opps_order public.orders;
  v_count integer;
  v_amount numeric;
  v_completed_at timestamptz;
  v_single_provider text;
  v_method text;
  v_note text;
  v_total_paid numeric;
begin
  if p_service_order_id is null or p_opps_order_id is null then
    return;
  end if;

  select * into v_order from commerce.service_orders where id = p_service_order_id;
  select * into v_opps_order from public.orders where id = p_opps_order_id;
  if v_order.id is null or v_opps_order.id is null then
    return;
  end if;

  select count(*), sum(amount), max(completed_at)
  into v_count, v_amount, v_completed_at
  from commerce.service_order_payments
  where service_order_id = p_service_order_id and status = 'completed';

  if coalesce(v_count, 0) > 0 then
    if v_count = 1 then
      select provider into v_single_provider
      from commerce.service_order_payments
      where service_order_id = p_service_order_id and status = 'completed'
      limit 1;
    else
      v_single_provider := null;
    end if;

    v_method := case v_single_provider when 'cash' then 'cash' when 'card' then 'card' else 'other' end;
    v_note := case
      when v_count = 1 then format('Quick Solution Café %s payment for order %s.', v_single_provider, v_order.order_number)
      else format('Quick Solution Café payments for order %s: %s completed payments totalling %s.', v_order.order_number, v_count, v_amount)
    end;

    insert into public.transactions (
      type, order_id, order_number, client_name, amount, payment_method, payment_status,
      payment_date, notes, source
    ) values (
      'income', p_opps_order_id, v_order.order_number, v_order.customer_name, v_amount, v_method, 'completed',
      coalesce(v_completed_at, now())::date, v_note, 'quick_solution'
    )
    on conflict (order_id) do nothing;
  end if;

  select coalesce(sum(t.amount), 0)
  into v_total_paid
  from public.transactions t
  where t.order_id = p_opps_order_id and t.type = 'income' and t.payment_status = 'completed';

  update public.orders
  set deposit_paid = v_total_paid,
      payment_status = case when v_total_paid > 0 and v_total_paid + 0.005 >= v_opps_order.total_amount then 'paid' else 'pending' end,
      updated_at = now()
  where id = p_opps_order_id;
end
$$;

revoke all on function commerce._qs_sync_opps_payment_ledger(uuid, uuid) from public, anon, authenticated;

comment on function commerce._qs_sync_opps_payment_ledger(uuid, uuid) is
  'CAFE-GUEST-01Y: imports the Quick Solution order''s completed Café payment(s) into public.transactions (idempotent via the existing order_id unique index; never for a zero-payment order; never overwrites a pre-existing manual entry), then sets public.orders.payment_status/deposit_paid FROM that same ledger sum - so the order''s Paid flag and OPPS''s Payments tab can never disagree. Internal.';

-- ── the send RPC: identical to QS-04B, with the sync call added at every success return ────────────
create or replace function public.admin_send_quick_solution_order_to_opps(
  p_service_order_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_service_order commerce.service_orders;
  v_preview jsonb;
  v_proposed jsonb;
  v_ready boolean;
  v_target_tenant_id uuid;
  v_existing_opps_id uuid;
  v_existing_source_service_order_id text;
  v_opps_order_id uuid;
  v_handoff_id uuid;
  v_idempotency_key text;
  v_file_urls text[] := '{}'::text[];
begin
  select so.*
  into v_service_order
  from commerce.service_orders so
  where so.id = p_service_order_id
  for update;

  if v_service_order.id is null then
    raise exception using errcode='22023', message='Quick Solution order was not found.';
  end if;

  if current_user <> 'service_role' then
    if auth.uid() is null then
      raise exception using errcode='42501', message='Staff sign-in is required.';
    end if;

    if not public.is_app_admin()
       and not (public.is_opps_staff() and public.can_access_tenant(v_service_order.tenant_id)) then
      raise exception using errcode='42501', message='You do not have access to this Quick Solution order.';
    end if;
  end if;

  if v_service_order.opps_order_id is not null then
    if exists (
      select 1
      from public.orders o
      where o.id = v_service_order.opps_order_id
        and o.tenant_id = v_service_order.tenant_id
        and o.source = 'quick_solution'
    ) then
      perform commerce._qs_sync_opps_payment_ledger(v_service_order.id, v_service_order.opps_order_id);
      return jsonb_build_object(
        'ok', true,
        'replayed', true,
        'serviceOrderId', v_service_order.id,
        'orderNumber', v_service_order.order_number,
        'oppsOrderId', v_service_order.opps_order_id,
        'handoffStatus', 'sent'
      );
    end if;

    raise exception using errcode='P0001', message='Quick Solution backlink points to an invalid OPPS order.';
  end if;

  v_preview := commerce.qs_build_opps_handoff_preview(v_service_order.id);
  v_ready := coalesce((v_preview->>'ready')::boolean, false);

  if not v_ready then
    v_target_tenant_id := nullif(v_preview->'proposedOppsOrder'->>'tenant_id','')::uuid;
    v_idempotency_key := 'quick-solution:opps:' || v_service_order.id::text;

    if v_target_tenant_id is not null then
      insert into commerce.service_order_handoffs (
        service_order_id, source_tenant_id, target_tenant_id, mapping_version,
        status, preview_payload, blockers, warnings, idempotency_key,
        last_previewed_at, last_previewed_by
      )
      values (
        v_service_order.id, v_service_order.tenant_id, v_target_tenant_id,
        coalesce(v_preview->>'mappingVersion','qs-opps-v1'),
        'blocked', v_preview,
        coalesce(v_preview->'blockers','[]'::jsonb),
        coalesce(v_preview->'warnings','[]'::jsonb),
        v_idempotency_key, now(), auth.uid()
      )
      on conflict (service_order_id) do update
      set status = case when commerce.service_order_handoffs.status='sent' then 'sent' else 'blocked' end,
          preview_payload = excluded.preview_payload,
          blockers = excluded.blockers,
          warnings = excluded.warnings,
          last_previewed_at = excluded.last_previewed_at,
          last_previewed_by = excluded.last_previewed_by,
          failure_message = null;
    end if;

    return jsonb_build_object(
      'ok', false,
      'replayed', false,
      'serviceOrderId', v_service_order.id,
      'orderNumber', v_service_order.order_number,
      'handoffStatus', 'blocked',
      'blockers', coalesce(v_preview->'blockers','[]'::jsonb),
      'warnings', coalesce(v_preview->'warnings','[]'::jsonb)
    );
  end if;

  v_proposed := v_preview->'proposedOppsOrder';
  v_target_tenant_id := (v_proposed->>'tenant_id')::uuid;
  v_idempotency_key := 'quick-solution:opps:' || v_service_order.id::text;

  select h.id, h.opps_order_id
  into v_handoff_id, v_existing_opps_id
  from commerce.service_order_handoffs h
  where h.service_order_id = v_service_order.id
  for update;

  if v_existing_opps_id is not null
     and exists (
       select 1 from public.orders o
       where o.id=v_existing_opps_id
         and o.tenant_id=v_target_tenant_id
         and o.source='quick_solution'
     ) then
    update commerce.service_orders
    set opps_order_id=v_existing_opps_id,
        status=case when status='submitted' then 'accepted' else status end,
        source_metadata=coalesce(source_metadata,'{}'::jsonb) ||
          jsonb_build_object(
            'oppsHandoff',
            jsonb_build_object(
              'status','sent',
              'oppsOrderId',v_existing_opps_id,
              'mappingVersion',coalesce(v_preview->>'mappingVersion','qs-opps-v1')
            )
          )
    where id=v_service_order.id;

    perform commerce._qs_sync_opps_payment_ledger(v_service_order.id, v_existing_opps_id);

    return jsonb_build_object(
      'ok', true,
      'replayed', true,
      'serviceOrderId', v_service_order.id,
      'orderNumber', v_service_order.order_number,
      'oppsOrderId', v_existing_opps_id,
      'handoffStatus', 'sent'
    );
  end if;

  select o.id,
         o.source_metadata->'quick_solution'->>'service_order_id'
  into v_existing_opps_id, v_existing_source_service_order_id
  from public.orders o
  where o.tenant_id=v_target_tenant_id
    and o.order_number=v_service_order.order_number
  limit 1;

  if v_existing_opps_id is not null then
    if v_existing_source_service_order_id = v_service_order.id::text
       and exists (
         select 1 from public.orders o
         where o.id=v_existing_opps_id and o.source='quick_solution'
       ) then

      insert into commerce.service_order_handoffs (
        service_order_id, source_tenant_id, target_tenant_id, mapping_version,
        status, preview_payload, blockers, warnings, opps_order_id,
        idempotency_key, last_previewed_at, last_previewed_by, sent_at
      )
      values (
        v_service_order.id, v_service_order.tenant_id, v_target_tenant_id,
        coalesce(v_preview->>'mappingVersion','qs-opps-v1'),
        'sent', v_preview, '[]'::jsonb,
        coalesce(v_preview->'warnings','[]'::jsonb), v_existing_opps_id,
        v_idempotency_key, now(), auth.uid(), now()
      )
      on conflict (service_order_id) do update
      set status='sent',
          preview_payload=excluded.preview_payload,
          blockers='[]'::jsonb,
          warnings=excluded.warnings,
          opps_order_id=excluded.opps_order_id,
          sent_at=coalesce(commerce.service_order_handoffs.sent_at, now()),
          failure_message=null;

      update commerce.service_orders
      set opps_order_id=v_existing_opps_id,
          status=case when status='submitted' then 'accepted' else status end,
          source_metadata=coalesce(source_metadata,'{}'::jsonb) ||
            jsonb_build_object(
              'oppsHandoff',
              jsonb_build_object(
                'status','sent',
                'oppsOrderId',v_existing_opps_id,
                'mappingVersion',coalesce(v_preview->>'mappingVersion','qs-opps-v1')
              )
            )
      where id=v_service_order.id;

      perform commerce._qs_sync_opps_payment_ledger(v_service_order.id, v_existing_opps_id);

      return jsonb_build_object(
        'ok', true,
        'replayed', true,
        'recovered', true,
        'serviceOrderId', v_service_order.id,
        'orderNumber', v_service_order.order_number,
        'oppsOrderId', v_existing_opps_id,
        'handoffStatus', 'sent'
      );
    end if;

    raise exception using errcode='23505',
      message='An OPPS order already uses this Quick Solution order number but is not linked to this source order.';
  end if;

  insert into commerce.service_order_handoffs (
    service_order_id, source_tenant_id, target_tenant_id, mapping_version,
    status, preview_payload, blockers, warnings, idempotency_key,
    last_previewed_at, last_previewed_by
  )
  values (
    v_service_order.id, v_service_order.tenant_id, v_target_tenant_id,
    coalesce(v_preview->>'mappingVersion','qs-opps-v1'),
    'sending', v_preview, '[]'::jsonb,
    coalesce(v_preview->'warnings','[]'::jsonb),
    v_idempotency_key, now(), auth.uid()
  )
  on conflict (service_order_id) do update
  set target_tenant_id=excluded.target_tenant_id,
      mapping_version=excluded.mapping_version,
      status='sending',
      preview_payload=excluded.preview_payload,
      blockers='[]'::jsonb,
      warnings=excluded.warnings,
      idempotency_key=excluded.idempotency_key,
      last_previewed_at=excluded.last_previewed_at,
      last_previewed_by=excluded.last_previewed_by,
      failure_message=null
  returning id into v_handoff_id;

  select coalesce(array_agg(f.value), '{}'::text[])
  into v_file_urls
  from jsonb_array_elements_text(coalesce(v_proposed->'file_urls','[]'::jsonb)) f(value);

  begin
    insert into public.orders (
      tenant_id,
      order_number,
      client_name,
      client_email,
      client_phone,
      status,
      priority,
      products,
      total_amount,
      deposit_paid,
      special_instructions,
      file_urls,
      source,
      pipeline_stage,
      portal_show_files,
      account_show_files,
      fulfillment_type,
      apply_shipping_fee,
      shipping_fee,
      payment_status,
      shipping_address,
      shipping_method,
      checkout_idempotency_key,
      source_metadata
    ) values (
      v_target_tenant_id,
      v_proposed->>'order_number',
      v_proposed->>'client_name',
      nullif(v_proposed->>'client_email',''),
      nullif(v_proposed->>'client_phone',''),
      coalesce(v_proposed->>'status','confirmed'),
      coalesce(v_proposed->>'priority','normal'),
      coalesce(v_proposed->'products','[]'::jsonb),
      coalesce((v_proposed->>'total_amount')::numeric,0),
      coalesce((v_proposed->>'deposit_paid')::numeric,0),
      nullif(v_proposed->>'special_instructions',''),
      v_file_urls,
      'quick_solution',
      coalesce(v_proposed->>'pipeline_stage','received'),
      false,
      false,
      coalesce(v_proposed->>'fulfillment_type','service_only'),
      coalesce((v_proposed->>'apply_shipping_fee')::boolean,false),
      coalesce((v_proposed->>'shipping_fee')::numeric,0),
      coalesce(v_proposed->>'payment_status','pending'),
      v_proposed->'shipping_address',
      nullif(v_proposed->>'shipping_method',''),
      v_idempotency_key,
      coalesce(v_proposed->'source_metadata','{}'::jsonb)
    )
    returning id into v_opps_order_id;
  exception when others then
    update commerce.service_order_handoffs
    set status='failed',
        failure_message=sqlerrm
    where id=v_handoff_id;

    return jsonb_build_object(
      'ok', false,
      'replayed', false,
      'serviceOrderId', v_service_order.id,
      'orderNumber', v_service_order.order_number,
      'handoffStatus', 'failed',
      'error', sqlerrm
    );
  end;

  update commerce.service_orders
  set opps_order_id=v_opps_order_id,
      status=case when status='submitted' then 'accepted' else status end,
      source_metadata=coalesce(source_metadata,'{}'::jsonb) ||
        jsonb_build_object(
          'oppsHandoff',
          jsonb_build_object(
            'status','sent',
            'oppsOrderId',v_opps_order_id,
            'mappingVersion',coalesce(v_preview->>'mappingVersion','qs-opps-v1'),
            'sentAt',now()
          )
        )
  where id=v_service_order.id;

  update commerce.service_order_handoffs
  set status='sent',
      opps_order_id=v_opps_order_id,
      sent_at=now(),
      failure_message=null
  where id=v_handoff_id;

  perform commerce._qs_sync_opps_payment_ledger(v_service_order.id, v_opps_order_id);

  return jsonb_build_object(
    'ok', true,
    'replayed', false,
    'serviceOrderId', v_service_order.id,
    'orderNumber', v_service_order.order_number,
    'oppsOrderId', v_opps_order_id,
    'handoffStatus', 'sent',
    'warnings', coalesce(v_preview->'warnings','[]'::jsonb)
  );
end
$$;

revoke all on function public.admin_send_quick_solution_order_to_opps(uuid) from public, anon;
grant execute on function public.admin_send_quick_solution_order_to_opps(uuid) to authenticated, service_role;

comment on function public.admin_send_quick_solution_order_to_opps(uuid) is
  'QS-04B/CAFE-GUEST-01Y canonical idempotent Quick Solution -> OPPS creation. Refuses blocked handoffs, creates one public.orders row, stores backlinks on both sides, replays the same OPPS order on repeated calls, and imports the order''s completed Café payment into public.transactions (idempotent, never fabricated) so payment_status/deposit_paid are always reprojected from that ledger, never a copied string.';
