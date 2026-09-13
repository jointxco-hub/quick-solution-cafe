-- QS-04A: explicit Quick Solution -> OPPS handoff boundary.
-- This phase does NOT create OPPS orders. It adds source support, prevents accidental X LAB mirroring,
-- creates a handoff ledger, tenant-access helpers, and a deterministic preview/mapping contract.

alter table public.orders drop constraint if exists orders_source_check;
alter table public.orders
  add constraint orders_source_check
  check (source = any (array['opps'::text,'xlab'::text,'x1_sample'::text,'quick_solution'::text]));

create or replace function public.mirror_opps_order_to_xlab_orders()
returns trigger
language plpgsql
security definer
set search_path = 'public'
as $$
begin
  if new.source = 'quick_solution' then
    return new;
  end if;

  perform public._mirror_opps_order_row(new);
  return new;
exception when others then
  raise warning 'mirror_opps_order_to_xlab_orders failed for order %: %', new.order_number, sqlerrm;
  return new;
end;
$$;

create table if not exists commerce.service_order_handoffs (
  id uuid primary key default gen_random_uuid(),
  service_order_id uuid not null references commerce.service_orders(id) on delete cascade,
  source_tenant_id uuid not null references public.tenants(id) on delete restrict,
  target_tenant_id uuid not null references public.tenants(id) on delete restrict,
  mapping_version text not null default 'qs-opps-v1',
  status text not null default 'previewed'
    check (status in ('previewed','blocked','ready','sending','sent','failed')),
  preview_payload jsonb not null default '{}'::jsonb,
  blockers jsonb not null default '[]'::jsonb,
  warnings jsonb not null default '[]'::jsonb,
  opps_order_id uuid references public.orders(id) on delete set null,
  idempotency_key text not null,
  last_previewed_at timestamptz,
  last_previewed_by uuid,
  sent_at timestamptz,
  failure_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (service_order_id),
  unique (idempotency_key)
);

create index if not exists idx_qs_handoffs_status
  on commerce.service_order_handoffs(status, updated_at desc);
create index if not exists idx_qs_handoffs_target_tenant
  on commerce.service_order_handoffs(target_tenant_id, status, updated_at desc);

alter table commerce.service_order_handoffs enable row level security;
revoke all on commerce.service_order_handoffs from anon, authenticated;

do $$
begin
  if not exists (
    select 1 from pg_trigger
    where tgname='trg_qs_service_order_handoffs_updated_at'
      and tgrelid='commerce.service_order_handoffs'::regclass
  ) then
    create trigger trg_qs_service_order_handoffs_updated_at
    before update on commerce.service_order_handoffs
    for each row execute function public.handle_updated_at();
  end if;
end
$$;

comment on table commerce.service_order_handoffs is
  'Explicit, idempotent Quick Solution -> OPPS handoff ledger. QS-04A previews only; QS-04B will create the target OPPS order.';

create or replace function commerce.qs_build_opps_handoff_preview(p_service_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order commerce.service_orders;
  v_source_tenant public.tenants;
  v_target_tenant public.tenants;
  v_point commerce.fulfilment_points;
  v_items jsonb := '[]'::jsonb;
  v_file_urls jsonb := '[]'::jsonb;
  v_files jsonb := '[]'::jsonb;
  v_blockers jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_ready boolean := false;
  v_fulfillment_type text;
  v_payment_status text;
  v_apply_shipping boolean := false;
begin
  select * into v_order from commerce.service_orders so where so.id=p_service_order_id limit 1;
  if v_order.id is null then
    raise exception using errcode='22023', message='Quick Solution order was not found.';
  end if;

  select * into v_source_tenant from public.tenants t where t.id=v_order.tenant_id limit 1;
  if v_source_tenant.slug <> 'quick-solution' then
    raise exception using errcode='22023', message='Order is not a Quick Solution order.';
  end if;

  select * into v_target_tenant from public.tenants t where t.slug='quick-solution' and t.status='active' limit 1;
  if v_target_tenant.id is null then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('code','TARGET_TENANT_MISSING','message','Quick Solution OPPS tenant is not active.'));
  end if;
  if v_order.status in ('cancelled','completed') then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('code','ORDER_CLOSED','message','Closed Quick Solution orders cannot be handed to OPPS.'));
  end if;
  if v_order.opps_order_id is not null then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('code','ALREADY_HANDED_OFF','message','This Quick Solution order is already linked to an OPPS order.','oppsOrderId',v_order.opps_order_id));
  end if;
  if not exists (select 1 from commerce.service_order_items soi where soi.order_id=v_order.id) then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('code','NO_ORDER_ITEMS','message','The order has no order items.'));
  end if;
  if nullif(trim(coalesce(v_order.customer_email,'')),'') is null and nullif(trim(coalesce(v_order.customer_phone,'')),'') is null then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('code','NO_CUSTOMER_CONTACT','message','A phone number or email address is required.'));
  end if;
  if exists (
    select 1 from commerce.service_order_items soi
    where soi.order_id=v_order.id
      and nullif(trim(coalesce(soi.configuration->>'fileName','')),'') is not null
      and not exists (
        select 1 from commerce.service_order_files sof
        where sof.order_item_id=soi.id and sof.status='uploaded'
      )
  ) then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('code','EXPECTED_FILE_MISSING','message','At least one order item names a customer file but no private upload is linked.'));
  end if;
  if v_order.payment_status <> 'paid' then
    v_warnings := v_warnings || jsonb_build_array(jsonb_build_object('code','PAYMENT_NOT_PAID','message','The Quick Solution order is not marked paid. OPPS may receive it for review, but staff should control production release.'));
  end if;

  if v_order.fulfilment_type in ('cafe','quick_point') then
    v_fulfillment_type := 'collection'; v_apply_shipping := false;
  elsif v_order.fulfilment_type='delivery' then
    v_fulfillment_type := 'courier'; v_apply_shipping := true;
    if v_order.delivery_address is null then
      v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('code','DELIVERY_ADDRESS_MISSING','message','Delivery orders require a delivery address.'));
    end if;
  else
    v_fulfillment_type := 'service_only'; v_apply_shipping := false;
  end if;

  v_payment_status := case v_order.payment_status when 'paid' then 'paid' when 'failed' then 'failed' when 'cancelled' then 'cancelled' else 'pending' end;

  if v_order.fulfilment_point_id is not null then
    select * into v_point from commerce.fulfilment_points fp
    where fp.id=v_order.fulfilment_point_id and fp.tenant_id=v_order.tenant_id limit 1;
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'name', soi.product_name,
      'quantity', greatest(coalesce(public.safe_numeric(soi.configuration->>'quantity'), soi.quantity, 1), 1),
      'price', case when greatest(coalesce(public.safe_numeric(soi.configuration->>'quantity'), soi.quantity, 1),1) > 0
                    then round(soi.line_total / greatest(coalesce(public.safe_numeric(soi.configuration->>'quantity'), soi.quantity, 1),1), 2)
                    else soi.line_total end,
      'line_total', soi.line_total,
      'line_id', soi.id::text,
      'line_role', 'product',
      'source', 'quick_solution',
      'category', coalesce(c.customer_definition->>'category','Quick Solution'),
      'price_breakdown', jsonb_build_object('mode','quick_solution_snapshot','pricing_version',soi.pricing_snapshot->>'pricingVersion','calculation',coalesce(soi.pricing_snapshot->'calculation','{}'::jsonb)),
      'quick_solution', jsonb_build_object('service_order_item_id',soi.id,'product_key',soi.product_key,'configuration',soi.configuration,'pricing_version',soi.pricing_snapshot->>'pricingVersion','file_refs',coalesce(soi.file_refs,'[]'::jsonb))
    ) order by soi.created_at
  ), '[]'::jsonb)
  into v_items
  from commerce.service_order_items soi
  left join commerce.service_product_configs c on c.tenant_id=soi.tenant_id and c.source_key=soi.product_key
  where soi.order_id=v_order.id;

  select
    coalesce(jsonb_agg(jsonb_build_object('id', sof.id,'orderItemId', sof.order_item_id,'name', sof.original_filename,'mimeType', sof.mime_type,'byteSize', sof.byte_size,'bucket', sof.storage_bucket,'path', sof.storage_path,'privateUri', 'private-upload://' || sof.storage_bucket || '/' || sof.storage_path) order by sof.uploaded_at), '[]'::jsonb),
    coalesce(jsonb_agg(to_jsonb('private-upload://' || sof.storage_bucket || '/' || sof.storage_path) order by sof.uploaded_at), '[]'::jsonb)
  into v_files, v_file_urls
  from commerce.service_order_files sof
  where sof.order_id=v_order.id and sof.status='uploaded';

  v_ready := jsonb_array_length(v_blockers)=0;

  return jsonb_build_object(
    'mappingVersion','qs-opps-v1','ready',v_ready,'blockers',v_blockers,'warnings',v_warnings,
    'sourceOrder',jsonb_build_object('id',v_order.id,'orderNumber',v_order.order_number,'tenantId',v_order.tenant_id,'tenantSlug',v_source_tenant.slug,'status',v_order.status,'paymentStatus',v_order.payment_status,'submittedAt',v_order.submitted_at),
    'proposedOppsOrder',jsonb_build_object(
      'tenant_id',v_target_tenant.id,'order_number',v_order.order_number,'client_name',v_order.customer_name,'client_email',v_order.customer_email,'client_phone',v_order.customer_phone,
      'status','confirmed','pipeline_stage','received','priority','normal','source','quick_solution','products',v_items,'total_amount',v_order.total_amount,
      'deposit_paid',case when v_order.payment_status='paid' then v_order.total_amount else 0 end,'payment_status',v_payment_status,'fulfillment_type',v_fulfillment_type,
      'apply_shipping_fee',v_apply_shipping,'shipping_fee',v_order.fulfilment_fee,'shipping_address',case when v_order.fulfilment_type='delivery' then v_order.delivery_address else null end,
      'shipping_method',case when v_order.fulfilment_type='quick_point' then 'Quick Point collection' when v_order.fulfilment_type='cafe' then 'Quick Solution Café collection' when v_order.fulfilment_type='delivery' then 'Quick Solution delivery' else null end,
      'file_urls',v_file_urls,'special_instructions',v_order.customer_notes,'portal_show_files',false,'account_show_files',false,
      'source_metadata',jsonb_build_object('quick_solution',jsonb_build_object('service_order_id',v_order.id,'service_order_number',v_order.order_number,'mapping_version','qs-opps-v1','fulfilment_type',v_order.fulfilment_type,'fulfilment_point',case when v_point.id is null then null else jsonb_build_object('id',v_point.id,'slug',v_point.slug,'name',v_point.name,'kind',v_point.kind) end,'pricing_total',v_order.total_amount,'files',v_files))
    )
  );
end
$$;

revoke all on function commerce.qs_build_opps_handoff_preview(uuid) from public, anon, authenticated;

create or replace function public.admin_preview_quick_solution_opps_handoff(p_service_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_preview jsonb;
  v_source_tenant_id uuid;
  v_target_tenant_id uuid;
  v_status text;
  v_idempotency_key text;
begin
  if auth.uid() is null then raise exception using errcode='42501', message='Staff sign-in is required.'; end if;
  select so.tenant_id into v_source_tenant_id from commerce.service_orders so where so.id=p_service_order_id limit 1;
  if v_source_tenant_id is null then raise exception using errcode='22023', message='Quick Solution order was not found.'; end if;
  if not public.is_app_admin() and not (public.is_opps_staff() and public.can_access_tenant(v_source_tenant_id)) then
    raise exception using errcode='42501', message='You do not have access to this Quick Solution order.';
  end if;

  v_preview := commerce.qs_build_opps_handoff_preview(p_service_order_id);
  v_target_tenant_id := (v_preview->'proposedOppsOrder'->>'tenant_id')::uuid;
  v_status := case when coalesce((v_preview->>'ready')::boolean,false) then 'ready' else 'blocked' end;
  v_idempotency_key := 'quick-solution:opps:' || p_service_order_id::text;

  insert into commerce.service_order_handoffs (service_order_id,source_tenant_id,target_tenant_id,mapping_version,status,preview_payload,blockers,warnings,idempotency_key,last_previewed_at,last_previewed_by)
  values (p_service_order_id,v_source_tenant_id,v_target_tenant_id,'qs-opps-v1',v_status,v_preview,coalesce(v_preview->'blockers','[]'::jsonb),coalesce(v_preview->'warnings','[]'::jsonb),v_idempotency_key,now(),auth.uid())
  on conflict (service_order_id) do update
  set target_tenant_id=excluded.target_tenant_id,mapping_version=excluded.mapping_version,status=case when commerce.service_order_handoffs.status='sent' then 'sent' else excluded.status end,
      preview_payload=excluded.preview_payload,blockers=excluded.blockers,warnings=excluded.warnings,idempotency_key=excluded.idempotency_key,last_previewed_at=excluded.last_previewed_at,last_previewed_by=excluded.last_previewed_by,failure_message=null;

  return v_preview;
end
$$;

grant execute on function public.admin_preview_quick_solution_opps_handoff(uuid) to authenticated;

create or replace function public.admin_list_quick_solution_opps_handoffs(p_tenant_slug text default 'quick-solution')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_tenant_id uuid;
begin
  if auth.uid() is null then raise exception using errcode='42501', message='Staff sign-in is required.'; end if;
  select t.id into v_tenant_id from public.tenants t where t.slug=lower(trim(p_tenant_slug)) and t.status='active' limit 1;
  if v_tenant_id is null then raise exception using errcode='22023', message='Quick Solution tenant was not found.'; end if;
  if not public.is_app_admin() and not (public.is_opps_staff() and public.can_access_tenant(v_tenant_id)) then
    raise exception using errcode='42501', message='You do not have access to Quick Solution handoffs.';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'serviceOrderId',so.id,'orderNumber',so.order_number,'customerName',so.customer_name,'totalAmount',so.total_amount,'paymentStatus',so.payment_status,'serviceStatus',so.status,'submittedAt',so.submitted_at,
      'oppsOrderId',so.opps_order_id,'handoffStatus',coalesce(h.status,'not_previewed'),'mappingVersion',h.mapping_version,'lastPreviewedAt',h.last_previewed_at,'blockers',coalesce(h.blockers,'[]'::jsonb),'warnings',coalesce(h.warnings,'[]'::jsonb)
    ) order by so.submitted_at desc)
    from commerce.service_orders so left join commerce.service_order_handoffs h on h.service_order_id=so.id
    where so.tenant_id=v_tenant_id
  ), '[]'::jsonb);
end
$$;

grant execute on function public.admin_list_quick_solution_opps_handoffs(text) to authenticated;

create or replace function public.admin_grant_quick_solution_opps_access(p_email text,p_tenant_role text default 'member')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_user_id uuid; v_tenant_id uuid; v_role text;
begin
  if auth.uid() is null or not public.is_app_admin() then raise exception using errcode='42501', message='App admin access is required.'; end if;
  v_role := lower(trim(coalesce(p_tenant_role,'member')));
  if v_role not in ('owner','admin','member') then raise exception using errcode='22023', message='Tenant role must be owner, admin or member.'; end if;
  select u.id into v_user_id from auth.users u where lower(u.email)=lower(trim(p_email)) limit 1;
  if v_user_id is null then raise exception using errcode='22023', message='Staff auth user was not found.'; end if;
  select t.id into v_tenant_id from public.tenants t where t.slug='quick-solution' and t.status='active' limit 1;
  if v_tenant_id is null then raise exception using errcode='22023', message='Quick Solution tenant is not active.'; end if;
  insert into public.tenant_memberships (tenant_id,auth_user_id,tenant_role,status)
  values (v_tenant_id,v_user_id,v_role,'active')
  on conflict (tenant_id,auth_user_id) do update set tenant_role=excluded.tenant_role,status='active',updated_at=now();
  return jsonb_build_object('ok',true,'email',lower(trim(p_email)),'tenantId',v_tenant_id,'role',v_role);
end
$$;

grant execute on function public.admin_grant_quick_solution_opps_access(text,text) to authenticated;

insert into public.tenant_memberships (tenant_id,auth_user_id,tenant_role,status)
select t.id,u.id,case when lower(u.email)='phd-staff@jointx.co.za' then 'owner' else 'admin' end,'active'
from public.tenants t
join auth.users u on lower(u.email) in ('jointx.co@gmail.com','phd-staff@jointx.co.za')
where t.slug='quick-solution'
on conflict (tenant_id,auth_user_id) do update
set tenant_role=excluded.tenant_role,status='active',updated_at=now();
