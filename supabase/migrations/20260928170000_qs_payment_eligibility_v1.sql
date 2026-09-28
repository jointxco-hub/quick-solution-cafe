-- QS Payment Eligibility v1.
--
-- Adds the backend for a configurable payment-choice layer: PayFast (only
-- once eligible AND at/above a configurable minimum, enforced server-side -
-- see #1a below, not just in the storefront UI), Pay at Counter (now also
-- operational in Counter POS - see #1b-d), EFT (real, tenant-scoped bank
-- details - see #2), and (separately, not a payment method) WhatsApp Order
-- Handoff.
--
-- Product-level payment flags (allowPayfast/allowEft/allowPayAtCounter) and
-- the tenant's payfastMinimumAmount/EFT bank details are NOT new columns -
-- they live in commerce.service_product_configs.customer_definition and
-- public.tenants.settings, both already-existing, already-flexible jsonb
-- columns. The only genuinely new schema here is two new commerce.
-- service_order_payments.provider values.
--
-- Every existing production function this file replaces is hash-pinned in
-- the preflight below to its exact current (staging-confirmed) body -
-- rehearsed here; production's own hashes must be independently
-- re-confirmed at actual deploy time, since this migration has not been
-- applied anywhere yet. The comparison strips all whitespace before
-- hashing: staging's live copy of commerce.qs_begin_payfast_payment was
-- reformatted by an earlier reconciliation pass (different line-wrapping
-- of the same jsonb_build_object calls, confirmed byte-for-byte identical
-- once whitespace is ignored - see the migration's own dev notes) and the
-- three Counter POS RPCs differ from this git checkout only by CRLF vs LF
-- line endings. A whitespace-insensitive comparison is the more correct
-- check anyway - it catches real logic drift without false-failing on
-- incidental formatting/line-ending differences.
do $preflight$
declare
  v_hash text;
begin
  if to_regclass('commerce.service_order_payments') is null then
    raise exception 'QS_PAYMENT_ELIGIBILITY_V1_PRECONDITION: commerce.service_order_payments does not exist';
  end if;
  if to_regprocedure('public.get_quick_solution_catalog(text)') is null then
    raise exception 'QS_PAYMENT_ELIGIBILITY_V1_PRECONDITION: public.get_quick_solution_catalog(text) does not exist';
  end if;
  if to_regprocedure('public.qs_get_quick_solution_payment_status(uuid,text)') is null then
    raise exception 'QS_PAYMENT_ELIGIBILITY_V1_PRECONDITION: public.qs_get_quick_solution_payment_status(uuid,text) does not exist';
  end if;

  -- The four already-live functions this file is about to replace, pinned
  -- to their exact current body (whitespace-insensitive) so this
  -- migration refuses to run against a copy that has already drifted from
  -- what was reviewed.
  for v_hash in
    select case when md5(regexp_replace(p.prosrc, '\s+', '', 'g')) = expected.h then 'ok' else
      'QS_PAYMENT_ELIGIBILITY_V1_PRECONDITION: ' || expected.schema || '.' || expected.fn || ' hash is ' || md5(regexp_replace(p.prosrc, '\s+', '', 'g')) || ' (expected ' || expected.h || ') - do not proceed on a stale assumption'
    end
    from (values
      ('commerce','qs_begin_payfast_payment','75bccb72312c013d0d1a8dd12695ba80'),
      ('public','list_quick_solution_counter_orders_today','b49539ed742d5cd281bc01c4c70812d1'),
      ('public','list_quick_solution_unpaid_counter_orders','2afc9b86aa0cc556d5f8ff9b25f34f88'),
      ('public','record_quick_solution_counter_payment','22bb17aa5718a930883f5c5904c9a375')
    ) as expected(schema, fn, h)
    join pg_proc p on p.proname = expected.fn
    join pg_namespace n on n.oid = p.pronamespace and n.nspname = expected.schema
  loop
    if v_hash <> 'ok' then
      raise exception '%', v_hash;
    end if;
  end loop;
end
$preflight$;

-- ── 1. Widen the provider check - additive only, no existing row can ever
--       violate it, since 'payfast'/'cash'/'card' remain exactly as valid
--       as before. 'eft' and 'counter' represent a customer's STATED
--       INTENT, always inserted with status='pending' by the RPC below -
--       never 'completed' for these two, so the existing counter_recorded_
--       check (which only constrains 'cash'/'card') is untouched and still
--       correct: its first branch (provider NOT IN ('cash','card')) is
--       true for 'eft'/'counter' regardless of status, exactly as it
--       already is for 'payfast'.
alter table commerce.service_order_payments drop constraint service_order_payments_provider_check;
alter table commerce.service_order_payments add constraint service_order_payments_provider_check
  check (provider = any (array['payfast','cash','card','eft','counter']));

-- ── 2. Seed (merge, never overwrite) the quick-solution tenant's payment
--       config. This migration deliberately does NOT hardcode the real EFT
--       bank details as a git-committed literal (bank account numbers do
--       not belong in source-control history, even confirmed production
--       values the business supplied directly) - it only ensures
--       payfastMinimumAmount exists and reserves the eftBankDetails shape
--       the storefront and src/lib/paymentEligibility.js's
--       isEftBankDetailsComplete() both expect (bank, accountHolder,
--       accountType, accountNumber). The four real values are applied
--       separately, directly against each environment's tenants.settings,
--       never through a file this branch commits. Until that direct
--       update is run, eftBankDetails stays empty and EFT correctly stays
--       unavailable (see isEftBankDetailsComplete) rather than showing
--       blank/placeholder details.
update public.tenants
set settings = coalesce(settings, '{}'::jsonb) || jsonb_build_object(
  'qsPayment', jsonb_build_object(
    'payfastMinimumAmount', 50.00,
    'eftBankDetails', coalesce(settings->'qsPayment'->'eftBankDetails', '{}'::jsonb)
  )
)
where slug = 'quick-solution'
  and not (coalesce(settings,'{}'::jsonb) ? 'qsPayment');

-- ── 3. Expose that config to the storefront - curated (only qsPayment,
--       never the whole settings blob) on the existing tenant object, so
--       no new round trip and no new RPC is needed for the frontend to
--       read it.
create or replace function public.get_quick_solution_catalog(p_tenant_slug text default 'quick-solution')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
begin
  select t.id
  into v_tenant_id
  from public.tenants t
  where t.slug = lower(trim(p_tenant_slug))
    and t.status = 'active'
    and exists (
      select 1
      from public.tenant_capabilities tc
      where tc.tenant_id = t.id
        and tc.capability_key = 'quick_solution'
        and tc.enabled = true
    )
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode = '22023', message = 'Quick Solution storefront is not active.';
  end if;

  return jsonb_build_object(
    'tenant', (
      select jsonb_build_object(
        'id', t.id, 'slug', t.slug, 'name', t.name,
        'paymentConfig', coalesce(t.settings->'qsPayment', '{}'::jsonb)
      )
      from public.tenants t
      where t.id = v_tenant_id
    ),
    'products', coalesce((
      select jsonb_agg(
        c.customer_definition ||
        jsonb_build_object(
          'id', c.source_key,
          'commerceProductId', p.id,
          'name', p.name,
          'description', coalesce(p.description, c.customer_definition->>'description'),
          'pricingVersion', c.pricing_version
        )
        order by c.sort_order, p.name
      )
      from commerce.service_product_configs c
      join commerce.products p
        on p.id = c.product_id
       and p.tenant_id = c.tenant_id
      where c.tenant_id = v_tenant_id
        and c.status = 'published'
        and p.status = 'published'
        and p.availability = 'available'
        and case coalesce(jsonb_typeof(c.customer_definition -> 'channels' -> 'storefront'), 'null')
              when 'null' then true
              when 'boolean' then (c.customer_definition -> 'channels' ->> 'storefront')::boolean
              else false
            end
    ), '[]'::jsonb),
    'fulfilmentPoints', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', fp.id,
          'slug', fp.slug,
          'name', fp.name,
          'kind', fp.kind,
          'address', fp.address,
          'easyLocateBusinessRef', fp.easy_locate_business_ref,
          'easyLocateLink',
            case
              when el.id is null or el.status <> 'verified' then null
              else jsonb_build_object(
                'externalId', el.external_id,
                'externalSlug', el.external_slug,
                'canonicalUrl', el.canonical_url,
                'status', el.status,
                'verifiedAt', el.verified_at,
                'business', jsonb_strip_nulls(jsonb_build_object(
                  'id', el.public_snapshot->>'id',
                  'slug', el.public_snapshot->>'slug',
                  'name', el.public_snapshot->>'name',
                  'categories', coalesce(el.public_snapshot->'categories','[]'::jsonb),
                  'services', coalesce(el.public_snapshot->'services','[]'::jsonb),
                  'locationArea', el.public_snapshot->>'locationArea',
                  'locationExtension', el.public_snapshot->>'locationExtension',
                  'verificationLevel', el.public_snapshot->>'verificationLevel',
                  'claimed', coalesce((el.public_snapshot->>'claimed')::boolean,false)
                ))
              )
            end,
          'latitude', fp.latitude,
          'longitude', fp.longitude,
          'collectionEnabled', fp.collection_enabled,
          'dropoffEnabled', fp.dropoff_enabled,
          'services', fp.services,
          'feeAmount', fp.fee_amount,
          'openingHours', fp.opening_hours
        )
        order by
          case fp.kind when 'cafe' then 0 else 1 end,
          fp.sort_order,
          fp.name
      )
      from commerce.fulfilment_points fp
      left join commerce.fulfilment_point_external_links el
        on el.fulfilment_point_id=fp.id
       and el.tenant_id=fp.tenant_id
       and el.provider='easy_locate'
      where fp.tenant_id = v_tenant_id
        and fp.status = 'active'
        and fp.collection_enabled = true
    ), '[]'::jsonb)
  );
end
$$;

-- ACL unchanged - reasserted so this file states the contract.
revoke all on function public.get_quick_solution_catalog(text) from public, anon, authenticated;
grant execute on function public.get_quick_solution_catalog(text) to anon, authenticated;

-- ── 4a. Server-authoritative PayFast eligibility. Everything else in this
--       function is byte-identical to the pinned production body above -
--       only the two new checks are inserted, after the existing delivery-
--       fee guard and before the pending-intent lookup. Eligibility is
--       derived entirely from server-held data (the tenant's own
--       payfastMinimumAmount, and each order line's own product config)
--       - this RPC's signature is unchanged (still just order id + payment
--       token), so there is no client-submitted field that could ever
--       override it. If a line's product config cannot be found at all
--       (e.g. deleted after the order was placed), this fails closed and
--       blocks PayFast rather than assuming it is still allowed.
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
  v_minimum numeric;
  v_all_allow_payfast boolean;
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

  select coalesce((t.settings->'qsPayment'->>'payfastMinimumAmount')::numeric, 50)
  into v_minimum
  from public.tenants t
  where t.id = v_order.tenant_id;

  if v_order.total_amount < v_minimum then
    return jsonb_build_object('ok',false,'reason','below_minimum','minimumAmount',v_minimum,'amount',v_order.total_amount);
  end if;

  select coalesce(bool_and(coalesce((spc.customer_definition->'paymentEligibility'->>'allowPayfast')::boolean, true)), false)
         and count(*) = (select count(*) from commerce.service_order_items where order_id = v_order.id)
  into v_all_allow_payfast
  from commerce.service_order_items soi
  join commerce.service_product_configs spc
    on spc.product_id = soi.product_id
   and spc.tenant_id = soi.tenant_id
  where soi.order_id = v_order.id;

  if not coalesce(v_all_allow_payfast, false) then
    return jsonb_build_object('ok',false,'reason','payfast_not_allowed');
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

-- ── 4b. Counter POS can now also find a storefront "pay at counter"
--       order - explicitly by its pending counter-intent row, never by
--       broadening to every storefront unpaid order. Everything else is
--       byte-identical to the pinned production body above.
create or replace function public.list_quick_solution_counter_orders_today()
returns jsonb
language plpgsql
stable security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_day record;
  v_orders jsonb;
begin
  if auth.uid() is null then
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

  select * into v_day from commerce._qs_counter_business_day(now());

  select coalesce(jsonb_agg(o.summary order by o.created_at desc, o.id desc), '[]'::jsonb)
  into v_orders
  from (
    select
      so.id,
      so.created_at,
      jsonb_build_object(
        'orderId', so.id,
        'orderNumber', so.order_number,
        'createdAt', so.created_at,
        'status', so.status,
        'paymentStatus', so.payment_status,
        'customerName', so.customer_name,
        'customerEmail', so.customer_email,
        'customerPhone', so.customer_phone,
        'totalAmount', so.total_amount,
        'items', coalesce((
          select jsonb_agg(
                   jsonb_build_object(
                     'productKey', i.product_key,
                     'productName', i.product_name,
                     'quantity', i.quantity,
                     'configuration', i.configuration,
                     'lineTotal', i.line_total
                   )
                   order by i.created_at, i.id
                 )
          from commerce.service_order_items i
          where i.order_id = so.id
            and i.tenant_id = so.tenant_id
        ), '[]'::jsonb)
      ) as summary
    from commerce.service_orders so
    where so.tenant_id = v_tenant_id
      and so.created_at >= v_day.day_start
      and so.created_at < v_day.day_end
      and (
        so.channel = 'counter'
        or exists (
          select 1 from commerce.service_order_payments p
          where p.service_order_id = so.id
            and p.provider = 'counter'
            and p.status = 'pending'
        )
      )
  ) o;

  return jsonb_build_object(
    'businessDate', v_day.business_date,
    'timezone', 'Africa/Johannesburg',
    'orders', v_orders
  );
end
$$;

revoke all on function public.list_quick_solution_counter_orders_today() from public, anon, authenticated;
grant execute on function public.list_quick_solution_counter_orders_today() to authenticated;

-- ── 4c. Same explicit widening for the aging "unpaid counter orders" list.
create or replace function public.list_quick_solution_unpaid_counter_orders()
returns jsonb
language plpgsql
stable security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_today date;
  v_result record;
begin
  if auth.uid() is null then
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

  select d.business_date into v_today from commerce._qs_counter_business_day(now()) d;

  with owing as (
    select
      so.id,
      so.order_number,
      so.created_at,
      so.status,
      so.payment_status,
      so.customer_name,
      so.customer_email,
      so.customer_phone,
      so.total_amount,
      paid.amount as amount_paid,
      greatest(round(so.total_amount - paid.amount, 2), 0) as outstanding,
      od.business_date as order_date
    from commerce.service_orders so
    cross join lateral (select commerce._qs_order_amount_paid(so.id) as amount) paid
    cross join lateral commerce._qs_counter_business_day(so.created_at) od
    where so.tenant_id = v_tenant_id
      and so.status not in ('draft', 'cancelled')
      and so.payment_status in ('unpaid', 'pending', 'failed')
      and (
        so.channel = 'counter'
        or exists (
          select 1 from commerce.service_order_payments p
          where p.service_order_id = so.id
            and p.provider = 'counter'
            and p.status = 'pending'
        )
      )
  )
  select
    count(*) as n,
    coalesce(sum(o.outstanding), 0) as outstanding_total,
    coalesce(jsonb_agg(
      jsonb_build_object(
        'orderId', o.id,
        'orderNumber', o.order_number,
        'createdAt', o.created_at,
        'orderDate', o.order_date,
        'ageDays', v_today - o.order_date,
        'status', o.status,
        'paymentStatus', o.payment_status,
        'customerName', o.customer_name,
        'customerEmail', o.customer_email,
        'customerPhone', o.customer_phone,
        'totalAmount', o.total_amount,
        'amountPaid', o.amount_paid,
        'outstanding', o.outstanding,
        'items', coalesce((
          select jsonb_agg(
                   jsonb_build_object(
                     'productKey', i.product_key,
                     'productName', i.product_name,
                     'quantity', i.quantity,
                     'configuration', i.configuration,
                     'lineTotal', i.line_total
                   )
                   order by i.created_at, i.id
                 )
          from commerce.service_order_items i
          where i.order_id = o.id
            and i.tenant_id = v_tenant_id
        ), '[]'::jsonb)
      )
      order by o.created_at, o.id
    ), '[]'::jsonb) as orders
  into v_result
  from owing o
  where o.outstanding > 0;

  return jsonb_build_object(
    'businessDate', v_today,
    'timezone', 'Africa/Johannesburg',
    'count', v_result.n,
    'outstandingTotal', v_result.outstanding_total,
    'orders', v_result.orders
  );
end
$$;

revoke all on function public.list_quick_solution_unpaid_counter_orders() from public, anon, authenticated;
grant execute on function public.list_quick_solution_unpaid_counter_orders() to authenticated;

-- ── 4d. record_quick_solution_counter_payment can now also settle a
--       storefront "pay at counter" order, found the same explicit way.
--       The actual cash/card payment still completes through exactly the
--       same mechanism as any other counter payment (a real completed
--       cash/card row, server-decided amount, the same idempotency-key
--       serialization and _qs_counter_payment_block gate) - nothing about
--       that mechanism changes. commerce._qs_order_amount_paid only ever
--       sums status='completed' rows (unchanged, not touched by this
--       file), so the pending 'counter' intent row is never treated as
--       money received. Once the real payment is recorded, that original
--       pending intent is cancelled (not deleted, not silently left
--       'pending' forever) - the same pattern qs_apply_payfast_payment
--       already uses for its own stale pending PayFast rows - so the
--       order's payment history still shows the customer's original
--       counter-payment intent, superseded by the real payment.
create or replace function public.record_quick_solution_counter_payment(p_order_id uuid, p_method text, p_idempotency_key text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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
$$;

revoke all on function public.record_quick_solution_counter_payment(uuid,text,text) from public, anon, authenticated;
grant execute on function public.record_quick_solution_counter_payment(uuid,text,text) to authenticated;

-- ── 5. The one genuinely new RPC: records the customer's stated payment
--       intent (EFT or Pay at Counter) as a 'pending' row on the SAME
--       order/payment table every other payment path already uses -
--       never a completed payment, never touches
--       commerce.service_orders.payment_status (which stays 'unpaid'
--       until a REAL payment - PayFast ITN or a real Counter POS cash/card
--       recording - completes it). Ownership is proven the same way
--       qs_get_quick_solution_payment_status already proves it: the
--       order's own hashed payment_token, issued at order-creation time by
--       create_quick_solution_order/create_quick_solution_cart_order -
--       no new token type. Idempotent: calling this again for the same
--       order/method returns the existing pending row rather than
--       inserting a second one (e.g. the customer revisits the
--       confirmation screen).
create or replace function public.qs_record_quick_solution_payment_intent(
  p_order_id uuid,
  p_payment_token text,
  p_method text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order commerce.service_orders;
  v_method text;
  v_existing commerce.service_order_payments;
begin
  v_method := lower(trim(coalesce(p_method,'')));
  if v_method not in ('eft','counter') then
    return jsonb_build_object('ok',false,'reason','unsupported_method');
  end if;

  select * into v_order
  from commerce.service_orders so
  where so.id = p_order_id
  for update;

  if v_order.id is null
     or v_order.payment_token_hash is null
     or v_order.payment_token_expires_at is null
     or v_order.payment_token_expires_at <= now()
     or encode(extensions.digest(coalesce(p_payment_token,''), 'sha256'),'hex') <> v_order.payment_token_hash then
    return jsonb_build_object('ok',false,'reason','not_available');
  end if;

  if v_order.status in ('cancelled','completed') then
    return jsonb_build_object('ok',false,'reason','not_available');
  end if;

  if v_order.payment_status = 'paid' then
    return jsonb_build_object('ok',true,'alreadyPaid',true,'orderId',v_order.id,'orderNumber',v_order.order_number);
  end if;

  select * into v_existing
  from commerce.service_order_payments p
  where p.service_order_id = v_order.id
    and p.provider = v_method
    and p.status = 'pending'
  order by p.initiated_at desc
  limit 1;

  if v_existing.id is null then
    insert into commerce.service_order_payments (
      tenant_id, service_order_id, provider, status, amount
    )
    values (
      v_order.tenant_id, v_order.id, v_method, 'pending', v_order.total_amount
    )
    returning * into v_existing;
  end if;

  return jsonb_build_object(
    'ok', true,
    'orderId', v_order.id,
    'orderNumber', v_order.order_number,
    'amount', v_existing.amount,
    'method', v_method,
    'intentId', v_existing.id
  );
end
$$;

revoke all on function public.qs_record_quick_solution_payment_intent(uuid,text,text) from public, anon, authenticated;
grant execute on function public.qs_record_quick_solution_payment_intent(uuid,text,text) to anon, authenticated;

do $postflight$
declare
  v_hash text;
begin
  if to_regprocedure('public.qs_record_quick_solution_payment_intent(uuid,text,text)') is null then
    raise exception 'QS_PAYMENT_ELIGIBILITY_V1_POSTFLIGHT: public.qs_record_quick_solution_payment_intent was not created';
  end if;

  -- The four replaced functions must actually carry the new enforcement -
  -- checked by source marker rather than a pinned "after" hash, since this
  -- migration has not been run against any live database yet to observe
  -- one.
  if (select prosrc from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='commerce' and p.proname='qs_begin_payfast_payment') not like '%below_minimum%'
     or (select prosrc from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='commerce' and p.proname='qs_begin_payfast_payment') not like '%payfast_not_allowed%' then
    raise exception 'QS_PAYMENT_ELIGIBILITY_V1_POSTFLIGHT: commerce.qs_begin_payfast_payment is missing the new server-side eligibility checks';
  end if;
  if (select prosrc from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='list_quick_solution_counter_orders_today') not like '%provider = ''counter''%' then
    raise exception 'QS_PAYMENT_ELIGIBILITY_V1_POSTFLIGHT: list_quick_solution_counter_orders_today is missing the counter-intent widening';
  end if;
  if (select prosrc from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='list_quick_solution_unpaid_counter_orders') not like '%provider = ''counter''%' then
    raise exception 'QS_PAYMENT_ELIGIBILITY_V1_POSTFLIGHT: list_quick_solution_unpaid_counter_orders is missing the counter-intent widening';
  end if;
  if (select prosrc from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='record_quick_solution_counter_payment') not like '%provider = ''counter''%'
     or (select prosrc from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='record_quick_solution_counter_payment') not like '%status = ''cancelled''%' then
    raise exception 'QS_PAYMENT_ELIGIBILITY_V1_POSTFLIGHT: record_quick_solution_counter_payment is missing the counter-intent widening or the audit-cancel step';
  end if;
end
$postflight$;
