-- PRODUCTION RECONCILIATION: restores only the two missing upload-authorization RPCs
-- required by the quick-solution-upload Edge Function - public.qs_authorize_file_upload
-- and public.qs_register_file_upload.
--
-- WHY THIS FILE EXISTS, SEPARATELY FROM 20260913163950_qs_03_1_upload_tokens.sql: that
-- migration's own ledger row was never applied to production (confirmed: no row for
-- version 20260913163950), and its committed body is no longer safe to apply as-is,
-- because it ALSO does `create or replace function public.create_quick_solution_order`,
-- with a body dated BEFORE the later checkout-protection guard (the quoteRequired /
-- PHOTOGRAPHY_SESSION block added by 20260921120000_qs14_checkout_guards_and_supplier_
-- rules.sql) that production's live create_quick_solution_order already carries.
-- Re-applying that migration's copy of create_quick_solution_order today would silently
-- regress a live, currently-used function (the Guided single-item checkout path still
-- calls it), stripping that guard back out.
--
-- THIS FILE deliberately extracts ONLY the two RPCs this incident actually needs -
-- qs_authorize_file_upload and qs_register_file_upload, byte-identical to their bodies
-- in 20260913163950_qs_03_1_upload_tokens.sql - plus their exact revoke/grant statements
-- from that same file. create_quick_solution_order is not mentioned, not replaced, and
-- explicitly asserted unchanged both before and after (see the two assertion blocks
-- below). Restoring upload-token issuance on create_quick_solution_order itself (the
-- Guided/single-item path) is intentionally left as a separate, distinct follow-up -
-- not in scope here. The real incident's checkout path, create_quick_solution_cart_order,
-- already issues upload tokens on production today and needs nothing from this file.
--
-- Ordered after every other Cafe/CAFE-ACCESS production step already applied (all dated
-- 2026-09-24 through 2026-09-27); this restoration is dated 2026-09-28.

do $preflight$
declare
  v_create_order_hash text;
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'commerce' and table_name = 'service_orders' and column_name = 'upload_token_hash'
  ) then
    raise exception 'QS_UPLOAD_AUTHORIZATION_RPCS_PRECONDITION: commerce.service_orders.upload_token_hash does not exist';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'commerce' and table_name = 'service_orders' and column_name = 'upload_token_expires_at'
  ) then
    raise exception 'QS_UPLOAD_AUTHORIZATION_RPCS_PRECONDITION: commerce.service_orders.upload_token_expires_at does not exist';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'commerce' and table_name = 'service_order_items' and column_name = 'file_refs'
  ) then
    raise exception 'QS_UPLOAD_AUTHORIZATION_RPCS_PRECONDITION: commerce.service_order_items.file_refs does not exist';
  end if;

  if not exists (
    select 1 from information_schema.tables
    where table_schema = 'commerce' and table_name = 'service_order_files'
  ) then
    raise exception 'QS_UPLOAD_AUTHORIZATION_RPCS_PRECONDITION: commerce.service_order_files does not exist';
  end if;

  if to_regprocedure('extensions.gen_random_bytes(int)') is null then
    raise exception 'QS_UPLOAD_AUTHORIZATION_RPCS_PRECONDITION: extensions.gen_random_bytes(int) is not available';
  end if;

  if to_regprocedure('extensions.digest(text,text)') is null then
    raise exception 'QS_UPLOAD_AUTHORIZATION_RPCS_PRECONDITION: extensions.digest(text,text) is not available';
  end if;

  if to_regprocedure('commerce.qs_generate_order_number()') is null then
    raise exception 'QS_UPLOAD_AUTHORIZATION_RPCS_PRECONDITION: commerce.qs_generate_order_number() is not available';
  end if;

  -- Sanity check, not a hard dependency of the two RPCs themselves: the real checkout
  -- path (create_quick_solution_cart_order) should already be issuing upload tokens on
  -- production. If this ever regresses, that is a signal worth stopping for, since it
  -- would mean this file's assumption about what already works has changed.
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'create_quick_solution_cart_order'
      and p.prosrc ilike '%upload_token%'
  ) then
    raise exception 'QS_UPLOAD_AUTHORIZATION_RPCS_PRECONDITION: create_quick_solution_cart_order no longer appears to issue upload tokens - re-review before proceeding';
  end if;

  -- The explicit guard this file exists to honour: create_quick_solution_order's current
  -- production body is pinned to the hash captured during the pre-apply safety review
  -- (2026-09-28). If it differs, something else has already changed that function since
  -- that review and this migration must not proceed on a stale assumption.
  select md5(p.prosrc) into v_create_order_hash
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'create_quick_solution_order';

  if v_create_order_hash is distinct from 'd24745c4792c9cc549f9bfab34ac70ba' then
    raise exception 'QS_UPLOAD_AUTHORIZATION_RPCS_PRECONDITION: public.create_quick_solution_order hash is % (expected d24745c4792c9cc549f9bfab34ac70ba) - this migration must not run against a changed body without re-review', v_create_order_hash;
  end if;
end
$preflight$;

-- ── public.qs_authorize_file_upload ─────────────────────────────────────
-- Byte-identical to 20260913163950_qs_03_1_upload_tokens.sql's version.
create or replace function public.qs_authorize_file_upload(
  p_order_id uuid,
  p_upload_token text,
  p_order_item_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order commerce.service_orders;
  v_item_id uuid;
begin
  select * into v_order
  from commerce.service_orders so
  where so.id = p_order_id
  limit 1;

  if v_order.id is null
     or v_order.upload_token_hash is null
     or v_order.upload_token_expires_at is null
     or v_order.upload_token_expires_at < now()
     or encode(extensions.digest(coalesce(p_upload_token,''), 'sha256'), 'hex') <> v_order.upload_token_hash then
    raise exception using errcode = '42501', message = 'Upload authorization is invalid or expired.';
  end if;
  if v_order.status in ('completed','cancelled') then
    raise exception using errcode = '22023', message = 'This order no longer accepts uploads.';
  end if;

  select soi.id into v_item_id
  from commerce.service_order_items soi
  where soi.order_id = v_order.id
    and soi.tenant_id = v_order.tenant_id
    and (p_order_item_id is null or soi.id = p_order_item_id)
  order by soi.created_at asc
  limit 1;
  if v_item_id is null then
    raise exception using errcode = '22023', message = 'Order item could not be resolved.';
  end if;

  return jsonb_build_object(
    'ok', true,
    'tenantId', v_order.tenant_id,
    'orderId', v_order.id,
    'orderItemId', v_item_id,
    'orderNumber', v_order.order_number,
    'storageBucket', 'uploads',
    'maxFiles', 5,
    'maxBytes', 20971520
  );
end
$$;

revoke all on function public.qs_authorize_file_upload(uuid,text,uuid) from public, anon, authenticated;
grant execute on function public.qs_authorize_file_upload(uuid,text,uuid) to service_role;

-- ── public.qs_register_file_upload ──────────────────────────────────────
-- Byte-identical to 20260913163950_qs_03_1_upload_tokens.sql's version.
create or replace function public.qs_register_file_upload(
  p_order_id uuid,
  p_order_item_id uuid,
  p_upload_token text,
  p_storage_path text,
  p_original_filename text,
  p_mime_type text,
  p_byte_size bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth jsonb;
  v_tenant_id uuid;
  v_file_id uuid;
  v_ref jsonb;
  v_prefix text;
  v_existing_count integer;
begin
  v_auth := public.qs_authorize_file_upload(p_order_id, p_upload_token, p_order_item_id);
  v_tenant_id := (v_auth->>'tenantId')::uuid;
  v_prefix := v_tenant_id::text || '/quick-solution/orders/' || p_order_id::text || '/' || p_order_item_id::text || '/';

  if p_storage_path is null
     or p_storage_path not like (v_prefix || '%')
     or p_storage_path like '%..%' then
    raise exception using errcode = '22023', message = 'Storage path is not valid for this order.';
  end if;
  if length(trim(coalesce(p_original_filename,''))) < 1 or length(p_original_filename) > 255 then
    raise exception using errcode = '22023', message = 'Filename is not valid.';
  end if;
  if p_byte_size <= 0 or p_byte_size > 20971520 then
    raise exception using errcode = '22023', message = 'File is larger than the 20MB limit.';
  end if;

  select count(*) into v_existing_count
  from commerce.service_order_files f
  where f.order_id = p_order_id
    and f.order_item_id = p_order_item_id
    and f.status = 'uploaded';
  if v_existing_count >= 5 then
    raise exception using errcode = '22023', message = 'This order item already has the maximum number of files.';
  end if;

  insert into commerce.service_order_files (
    tenant_id, order_id, order_item_id, storage_bucket, storage_path,
    original_filename, mime_type, byte_size, status
  ) values (
    v_tenant_id, p_order_id, p_order_item_id, 'uploads', p_storage_path,
    trim(p_original_filename), nullif(trim(coalesce(p_mime_type,'')), ''), p_byte_size, 'uploaded'
  ) returning id into v_file_id;

  v_ref := jsonb_build_object(
    'id', v_file_id,
    'bucket', 'uploads',
    'path', p_storage_path,
    'name', trim(p_original_filename),
    'mimeType', nullif(trim(coalesce(p_mime_type,'')), ''),
    'byteSize', p_byte_size,
    'uploadedAt', now()
  );

  update commerce.service_order_items soi
  set file_refs = coalesce(soi.file_refs, '[]'::jsonb) || jsonb_build_array(v_ref)
  where soi.id = p_order_item_id
    and soi.order_id = p_order_id
    and soi.tenant_id = v_tenant_id;

  return jsonb_build_object('ok',true,'file',v_ref);
end
$$;

revoke all on function public.qs_register_file_upload(uuid,uuid,text,text,text,text,bigint) from public, anon, authenticated;
grant execute on function public.qs_register_file_upload(uuid,uuid,text,text,text,text,bigint) to service_role;

-- ── postflight: create_quick_solution_order must be untouched ──────────
do $postflight$
declare
  v_create_order_hash text;
begin
  select md5(p.prosrc) into v_create_order_hash
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'create_quick_solution_order';

  if v_create_order_hash is distinct from 'd24745c4792c9cc549f9bfab34ac70ba' then
    raise exception 'QS_UPLOAD_AUTHORIZATION_RPCS_POSTFLIGHT: public.create_quick_solution_order hash changed to % during this migration - it must remain d24745c4792c9cc549f9bfab34ac70ba', v_create_order_hash;
  end if;

  if to_regprocedure('public.qs_authorize_file_upload(uuid,text,uuid)') is null then
    raise exception 'QS_UPLOAD_AUTHORIZATION_RPCS_POSTFLIGHT: public.qs_authorize_file_upload(uuid,text,uuid) was not created';
  end if;

  if to_regprocedure('public.qs_register_file_upload(uuid,uuid,text,text,text,text,bigint)') is null then
    raise exception 'QS_UPLOAD_AUTHORIZATION_RPCS_POSTFLIGHT: public.qs_register_file_upload(uuid,uuid,text,text,text,text,bigint) was not created';
  end if;
end
$postflight$;
