-- SOURCE-OF-TRUTH RESTORATION (not a redesign): brings the canonical Quick Solution
-- customer-tracking subsystem into git. It has been live, unchanged, on staging
-- (tijiamrfnxrbitafiflj) since QS-09/QS-09.1, and is byte-identical there today, but its
-- CREATE statements were never committed - QS-09's own migration
-- (20260913202423_qs_09_secure_customer_tracking.sql) documents this explicitly: "This repo
-- records the migration boundary while XOS Staging remains the source of the applied
-- canonical function bodies." QS-09.1
-- (20260913203520_qs_09_1_sa_phone_tracking_normalization.sql) already fully commits
-- public.qs_normalize_sa_phone and only PATCHES the live get_quick_solution_tracking body in
-- place (a textual find/replace against pg_get_functiondef); it does not, and cannot, create
-- get_quick_solution_tracking or commerce.qs_issue_tracking_token from nothing, and the local
-- harness documents this as a known, deliberate gap.
--
-- Discovered while auditing why production's create_quick_solution_cart_order/
-- create_quick_solution_service_request cannot reach their own success path: both call
-- commerce.qs_issue_tracking_token(uuid), which - along with its backing table and
-- public.get_quick_solution_tracking - exists only live, only on staging, not on production,
-- and not in git. This migration captures the staging-canonical definitions exactly, verified
-- read-only, with no behavior invented:
--
--   commerce.service_order_tracking_tokens  (table)      md5(pg_get_functiondef n/a; table DDL below)
--   commerce.qs_issue_tracking_token(uuid)                prosrc md5 c440ed34f44cca9880c642ec404f7058
--   public.get_quick_solution_tracking(text,text,text)    prosrc md5 f44e531d46ecdfb524eb72d31ccbc22c
--   public.qs_normalize_sa_phone(text)                    already fully git-tracked (QS-09.1);
--                                                          repeated here verbatim because the
--                                                          tracking functions depend on it and
--                                                          production has neither yet.
--
-- Recursively checked (read-only, staging): both functions' remaining references
-- (commerce.service_orders, commerce.service_order_handoffs, commerce.service_order_items,
-- public.orders, public.tenants, extensions.digest/gen_random_bytes) already exist on
-- production or are created by the accompanying general reconciliation migration
-- (commerce.fulfilment_point_external_links, commerce.service_order_handoffs). No further
-- missing dependency was found.
--
-- Must run AFTER 20260927140000_qs_production_reconciliation.sql, not before: this migration's
-- get_quick_solution_tracking declares a variable of type commerce.service_order_handoffs,
-- which PL/pgSQL resolves at CREATE FUNCTION time - that table does not exist until the
-- reconciliation migration creates it.
--
-- Security properties captured, not redesigned:
--   * both functions: SECURITY DEFINER, SET search_path = ''
--   * raw tracking token is never stored - only encode(digest(token,'sha256'),'hex') - matching
--     QS-09's own documented invariant
--   * commerce.service_order_tracking_tokens: RLS enabled, zero policies (default-deny to every
--     role but the owner) and NO direct grants to anon/authenticated/service_role - reachable
--     only through the two SECURITY DEFINER functions
--   * qs_issue_tracking_token: EXECUTE granted to nobody but the owning role - callable only via
--     SECURITY DEFINER escalation from create_quick_solution_order/cart_order/service_request
--   * get_quick_solution_tracking: EXECUTE granted to anon, authenticated, service_role -
--     intentionally public (guest order tracking needs no sign-in)
--
-- OUT OF SCOPE, DELIBERATELY: this migration does not touch is_opps_staff(),
-- is_opps_workspace_tenant(), has_tenant_permission(), or any object in the separate
-- OPPS_PERMISSION_MODEL_SOURCE_OF_TRUTH_RESTORATION document. That is a distinct,
-- separately-tracked source-of-truth gap in a different subsystem; nothing here requires it.

do $preflight$
begin
  if to_regclass('commerce.service_orders') is null then
    raise exception 'QS_TRACKING_RESTORATION_PRECONDITION: commerce.service_orders must exist';
  end if;
  if to_regclass('commerce.service_order_handoffs') is null then
    raise exception 'QS_TRACKING_RESTORATION_PRECONDITION: commerce.service_order_handoffs (20260927140000_qs_production_reconciliation.sql) must already exist';
  end if;
  if to_regclass('commerce.service_order_tracking_tokens') is not null then
    raise exception 'QS_TRACKING_RESTORATION_PRECONDITION: commerce.service_order_tracking_tokens already exists - this migration must not run twice';
  end if;
end
$preflight$;

create table commerce.service_order_tracking_tokens (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  service_order_id uuid not null references commerce.service_orders(id) on delete cascade,
  token_hash text not null unique,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  created_at timestamptz default now()
);

create index idx_qs_tracking_tokens_order on commerce.service_order_tracking_tokens (service_order_id, expires_at desc);

alter table commerce.service_order_tracking_tokens enable row level security;
-- Deliberately zero policies: RLS-enabled with no policy is default-deny for every role except
-- the table owner/BYPASSRLS roles, matching staging exactly. Access is only through the two
-- functions below, which are SECURITY DEFINER and therefore unaffected by this table's RLS.

revoke all on table commerce.service_order_tracking_tokens from public, anon, authenticated, service_role;

create or replace function public.qs_normalize_sa_phone(p_value text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_digits text;
begin
  v_digits := regexp_replace(coalesce(p_value,''),'[^0-9]','','g');

  if length(v_digits)=11 and left(v_digits,2)='27' then
    return '0' || substring(v_digits from 3);
  end if;

  if length(v_digits)=10 and left(v_digits,1)='0' then
    return v_digits;
  end if;

  if length(v_digits)=9 then
    return '0' || v_digits;
  end if;

  return v_digits;
end
$$;

revoke all on function public.qs_normalize_sa_phone(text) from public;
grant execute on function public.qs_normalize_sa_phone(text) to anon, authenticated, service_role;

create or replace function commerce.qs_issue_tracking_token(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_order commerce.service_orders;
  v_token text;
  v_expires_at timestamptz;
begin
  select * into v_order
  from commerce.service_orders so
  where so.id=p_order_id
  limit 1;

  if v_order.id is null then
    raise exception using errcode='22023', message='Quick Solution order was not found.';
  end if;

  delete from commerce.service_order_tracking_tokens t
  where t.service_order_id=v_order.id
    and (t.expires_at <= now() or t.revoked_at is not null);

  v_token := encode(extensions.gen_random_bytes(32),'hex');
  v_expires_at := now() + interval '180 days';

  insert into commerce.service_order_tracking_tokens (
    tenant_id, service_order_id, token_hash, expires_at
  )
  values (
    v_order.tenant_id,
    v_order.id,
    encode(extensions.digest(v_token,'sha256'),'hex'),
    v_expires_at
  );

  return jsonb_build_object(
    'token',v_token,
    'expiresAt',v_expires_at
  );
end
$function$;

revoke all on function commerce.qs_issue_tracking_token(uuid) from public, anon, authenticated, service_role;

create or replace function public.get_quick_solution_tracking(p_order_number text, p_tracking_token text default null::text, p_contact text default null::text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_order commerce.service_orders;
  v_handoff commerce.service_order_handoffs;
  v_opps public.orders;
  v_contact text;
  v_contact_digits text;
  v_authorized boolean := false;
  v_point_snapshot jsonb := null;
  v_easy_url text := null;
  v_items jsonb := '[]'::jsonb;
  v_stage_key text := 'received';
  v_stage_label text := 'Order received';
  v_stage_detail text := 'We have your order and will review the job before production starts.';
  v_stage_index integer := 0;
  v_stage_total integer := 4;
  v_is_delivery boolean := false;
  v_timeline jsonb;
  v_last_updated timestamptz;
  v_prod_detail text;
  v_prod_method text;
  v_status text;
  v_pipeline text;
begin
  select so.* into v_order
  from commerce.service_orders so
  join public.tenants t on t.id=so.tenant_id
  where t.slug='quick-solution'
    and upper(trim(so.order_number))=upper(trim(coalesce(p_order_number,'')))
  order by so.submitted_at desc
  limit 1;

  if v_order.id is null then
    return null;
  end if;

  if nullif(trim(coalesce(p_tracking_token,'')),'') is not null then
    select exists (
      select 1
      from commerce.service_order_tracking_tokens tok
      where tok.service_order_id=v_order.id
        and tok.tenant_id=v_order.tenant_id
        and tok.revoked_at is null
        and tok.expires_at > now()
        and tok.token_hash=encode(
          extensions.digest(trim(p_tracking_token),'sha256'),
          'hex'
        )
    )
    into v_authorized;
  end if;

  if not v_authorized and nullif(trim(coalesce(p_contact,'')),'') is not null then
    v_contact := lower(trim(p_contact));
    v_contact_digits := public.qs_normalize_sa_phone(v_contact);

    v_authorized :=
      (v_order.customer_email is not null and lower(trim(v_order.customer_email))=v_contact)
      or (
        v_order.customer_phone is not null
        and length(v_contact_digits) >= 9
        and public.qs_normalize_sa_phone(v_order.customer_phone)=v_contact_digits
      );
  end if;

  if not v_authorized then
    return null;
  end if;

  select h.* into v_handoff
  from commerce.service_order_handoffs h
  where h.service_order_id=v_order.id
  limit 1;

  if v_order.opps_order_id is not null then
    select o.* into v_opps
    from public.orders o
    where o.id=v_order.opps_order_id
      and o.tenant_id=v_order.tenant_id
    limit 1;
  end if;

  if jsonb_typeof(v_order.source_metadata->'fulfilmentPointSnapshot')='object' then
    v_point_snapshot := v_order.source_metadata->'fulfilmentPointSnapshot';
  end if;

  if v_order.fulfilment_point_id is not null then
    select el.canonical_url into v_easy_url
    from commerce.fulfilment_point_external_links el
    where el.fulfilment_point_id=v_order.fulfilment_point_id
      and el.tenant_id=v_order.tenant_id
      and el.provider='easy_locate'
      and el.status='verified'
    limit 1;
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id',soi.id,
      'name',soi.product_name,
      'quantity',soi.quantity,
      'lineTotal',soi.line_total
    )
    order by soi.created_at
  ),'[]'::jsonb)
  into v_items
  from commerce.service_order_items soi
  where soi.order_id=v_order.id;

  v_is_delivery := v_order.fulfilment_type='delivery';
  v_stage_total := case when v_is_delivery then 4 else 5 end;
  v_status := lower(coalesce(v_opps.status,''));
  v_pipeline := lower(coalesce(v_opps.pipeline_stage,''));
  v_prod_detail := nullif(trim(coalesce(v_opps.production_detail_stage,'')),'');
  v_prod_method := nullif(trim(coalesce(v_opps.production_method,'')),'');

  if v_order.status='cancelled' or v_status='cancelled' then
    v_stage_key := 'cancelled';
    v_stage_label := 'Order cancelled';
    v_stage_detail := 'This order has been cancelled. Contact Quick Solution if you need help.';
    v_stage_index := 0;

  elsif v_status in ('delivered','completed','complete')
     or v_pipeline in ('delivered','completed','complete') then
    v_stage_key := 'completed';
    v_stage_label := case when v_is_delivery then 'Delivered' else 'Order complete' end;
    v_stage_detail := case
      when v_is_delivery then 'Your order has been delivered.'
      else 'This order has been completed.'
    end;
    v_stage_index := case when v_is_delivery then 3 else 4 end;

  elsif v_is_delivery and (
      v_status in ('shipped','out_for_delivery')
      or v_pipeline in ('shipped','out_for_delivery','dispatch','dispatched')
    ) then
    v_stage_key := 'on_the_way';
    v_stage_label := 'On the way';
    v_stage_detail := coalesce(
      nullif(trim(coalesce(v_opps.delivery_note,'')),''),
      'Your order is on the way.'
    );
    v_stage_index := 2;

  elsif not v_is_delivery and (
      v_status in ('shipped','collected')
      or v_pipeline in ('shipped','collected','dispatch','dispatched')
    ) then
    v_stage_key := 'collected';
    v_stage_label := 'Collected';
    v_stage_detail := 'Your order has been collected.';
    v_stage_index := 3;

  elsif not v_is_delivery and (
      v_status='ready'
      or v_pipeline in ('ready','ready_for_collection')
    ) then
    v_stage_key := 'ready';
    v_stage_label := 'Ready for collection';
    v_stage_detail := case
      when v_order.fulfilment_type='quick_point'
        then 'Your order is ready for collection at the selected Quick Point.'
      else 'Your order is ready for collection at Quick Solution.'
    end;
    v_stage_index := 2;

  elsif v_opps.id is not null
     or v_order.status='accepted'
     or coalesce(v_handoff.status,'')='sent' then
    v_stage_key := 'preparing';
    v_stage_label := case
      when v_prod_detail is not null then initcap(replace(v_prod_detail,'_',' '))
      when v_pipeline not in ('','received') then initcap(replace(v_pipeline,'_',' '))
      else 'Preparing your order'
    end;
    v_stage_detail := coalesce(
      nullif(trim(coalesce(v_opps.production_client_update,'')),''),
      case
        when v_prod_detail is not null
          then 'Your order is currently at ' || lower(replace(v_prod_detail,'_',' ')) || '.'
        else 'Your order has moved into operations and is being prepared.'
      end
    );
    v_stage_index := 1;

  else
    v_stage_key := 'received';
    v_stage_label := 'Order received';
    v_stage_detail := case
      when v_order.payment_status='paid'
        then 'Payment is confirmed. We have your order and will review the job before production starts.'
      else 'We have your order. Payment or staff review may still be needed before production starts.'
    end;
    v_stage_index := 0;
  end if;

  if v_is_delivery then
    v_timeline := jsonb_build_array(
      jsonb_build_object('key','received','label','Received'),
      jsonb_build_object('key','preparing','label','Preparing'),
      jsonb_build_object('key','on_the_way','label','On the way'),
      jsonb_build_object('key','completed','label','Delivered')
    );
  else
    v_timeline := jsonb_build_array(
      jsonb_build_object('key','received','label','Received'),
      jsonb_build_object('key','preparing','label','Preparing'),
      jsonb_build_object('key','ready','label','Ready to collect'),
      jsonb_build_object('key','collected','label','Collected'),
      jsonb_build_object('key','completed','label','Complete')
    );
  end if;

  v_last_updated := greatest(
    coalesce(v_order.updated_at,v_order.submitted_at),
    coalesce(v_handoff.updated_at,'epoch'::timestamptz),
    coalesce(v_opps.updated_at,'epoch'::timestamptz)
  );

  return jsonb_build_object(
    'order',jsonb_build_object(
      'id',v_order.id,
      'orderNumber',v_order.order_number,
      'submittedAt',v_order.submitted_at,
      'lastUpdated',v_last_updated,
      'paymentStatus',v_order.payment_status,
      'totalAmount',v_order.total_amount,
      'items',v_items
    ),
    'stage',jsonb_build_object(
      'key',v_stage_key,
      'label',v_stage_label,
      'detail',v_stage_detail,
      'index',v_stage_index,
      'total',v_stage_total,
      'timeline',v_timeline
    ),
    'fulfilment',jsonb_build_object(
      'type',v_order.fulfilment_type,
      'name',case
        when v_order.fulfilment_type='delivery' then 'Local delivery'
        else coalesce(v_point_snapshot->>'name','Collection')
      end,
      'address',case
        when v_order.fulfilment_type='delivery' then v_order.delivery_address
        else coalesce(v_point_snapshot->'address','{}'::jsonb)
      end,
      'feeAmount',v_order.fulfilment_fee,
      'easyLocateUrl',v_easy_url
    ),
    'production',jsonb_strip_nulls(jsonb_build_object(
      'method',v_prod_method,
      'detailStage',v_prod_detail,
      'clientUpdate',nullif(trim(coalesce(v_opps.production_client_update,'')),'')
    )),
    'delivery',jsonb_strip_nulls(jsonb_build_object(
      'courier',nullif(trim(coalesce(v_opps.courier,'')),''),
      'trackingNumber',nullif(trim(coalesce(v_opps.tracking_number,'')),''),
      'pepCode',nullif(trim(coalesce(v_opps.pep_code,'')),''),
      'note',nullif(trim(coalesce(v_opps.delivery_note,'')),'')
    )),
    'message',nullif(trim(coalesce(v_opps.portal_message,'')),''),
    'attentionItems',coalesce(v_opps.portal_attention_items,'[]'::jsonb)
  );
end
$function$;

revoke all on function public.get_quick_solution_tracking(text,text,text) from public;
grant execute on function public.get_quick_solution_tracking(text,text,text) to anon, authenticated, service_role;
