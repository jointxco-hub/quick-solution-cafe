-- QS Payment Eligibility v1.
--
-- Adds the backend for a configurable payment-choice layer: PayFast (only
-- once eligible AND at/above a configurable minimum), Pay at Counter, EFT,
-- and (separately, not a payment method) WhatsApp Order Handoff.
--
-- DELIBERATELY NOT INCLUDED HERE, called out as its own follow-up: widening
-- list_quick_solution_counter_orders_today / list_quick_solution_unpaid_
-- counter_orders / record_quick_solution_counter_payment so Counter POS can
-- also find a storefront order with a "pay at counter" intent. Those three
-- RPCs are already live in production; changing their WHERE clauses is a
-- real behavior change to already-working staff tooling and deserves its
-- own dedicated review pass, not to be bundled into this slice. Today, a
-- "pay at counter" intent is fully and correctly recorded (see below) but
-- not yet surfaced in the Counter POS screens.
--
-- Product-level payment flags (allowPayfast/allowEft/allowPayAtCounter) and
-- the tenant's payfastMinimumAmount/EFT bank details are NOT new columns -
-- they live in commerce.service_product_configs.customer_definition and
-- public.tenants.settings, both already-existing, already-flexible jsonb
-- columns. The only genuinely new schema here is two new commerce.
-- service_order_payments.provider values.

do $preflight$
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
--       config. eftBankDetails below are OBVIOUS PLACEHOLDERS - this
--       migration deliberately does not invent real-looking banking
--       details. Do not go live on the EFT path until these are replaced
--       with the real account details, the same discipline already used
--       for PAYFAST_PASSPHRASE earlier in this project (never a fabricated
--       real-looking value).
update public.tenants
set settings = coalesce(settings, '{}'::jsonb) || jsonb_build_object(
  'qsPayment', jsonb_build_object(
    'payfastMinimumAmount', 50.00,
    'eftBankDetails', jsonb_build_object(
      'accountName', 'REPLACE ME - real account name',
      'bank', 'REPLACE ME - real bank',
      'accountNumber', 'REPLACE ME - real account number',
      'branchCode', 'REPLACE ME - real branch code',
      'reference', 'Use your QS order number'
    )
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

-- ── 4. The one genuinely new RPC: records the customer's stated payment
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

  -- The 8 long-preserved production functions this whole project has
  -- tracked from the start must remain untouched by this file too.
  for v_hash in
    select case when md5(p.prosrc) = expected.h then 'ok' else
      'QS_PAYMENT_ELIGIBILITY_V1_POSTFLIGHT: ' || p.proname || ' hash changed to ' || md5(p.prosrc) || ' (expected ' || expected.h || ')'
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
