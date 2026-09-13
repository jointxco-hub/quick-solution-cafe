-- QS-07.1: make the exact collection point visible through handoff/OPPS metadata.
-- Uses the immutable checkout fulfilment snapshot when available.

create or replace function commerce.qs_build_opps_handoff_preview(
  p_service_order_id uuid
)
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
  v_point_snapshot jsonb := null;
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
  select * into v_order
  from commerce.service_orders so
  where so.id=p_service_order_id
  limit 1;

  if v_order.id is null then
    raise exception using errcode='22023', message='Quick Solution order was not found.';
  end if;

  select * into v_source_tenant
  from public.tenants t
  where t.id=v_order.tenant_id
  limit 1;

  if v_source_tenant.slug <> 'quick-solution' then
    raise exception using errcode='22023', message='Order is not a Quick Solution order.';
  end if;

  select * into v_target_tenant
  from public.tenants t
  where t.slug='quick-solution' and t.status='active'
  limit 1;

  if v_target_tenant.id is null then
    v_blockers := v_blockers || jsonb_build_array(
      jsonb_build_object('code','TARGET_TENANT_MISSING','message','Quick Solution OPPS tenant is not active.')
    );
  end if;

  if v_order.status in ('cancelled','completed') then
    v_blockers := v_blockers || jsonb_build_array(
      jsonb_build_object('code','ORDER_CLOSED','message','Closed Quick Solution orders cannot be handed to OPPS.')
    );
  end if;

  if v_order.opps_order_id is not null then
    v_blockers := v_blockers || jsonb_build_array(
      jsonb_build_object(
        'code','ALREADY_HANDED_OFF',
        'message','This Quick Solution order is already linked to an OPPS order.',
        'oppsOrderId',v_order.opps_order_id
      )
    );
  end if;

  if not exists (
    select 1 from commerce.service_order_items soi where soi.order_id=v_order.id
  ) then
    v_blockers := v_blockers || jsonb_build_array(
      jsonb_build_object('code','NO_ORDER_ITEMS','message','The order has no order items.')
    );
  end if;

  if nullif(trim(coalesce(v_order.customer_email,'')),'') is null
     and nullif(trim(coalesce(v_order.customer_phone,'')),'') is null then
    v_blockers := v_blockers || jsonb_build_array(
      jsonb_build_object('code','NO_CUSTOMER_CONTACT','message','A phone number or email address is required.')
    );
  end if;

  if exists (
    select 1
    from commerce.service_order_items soi
    where soi.order_id=v_order.id
      and nullif(trim(coalesce(soi.configuration->>'fileName','')),'') is not null
      and not exists (
        select 1
        from commerce.service_order_files sof
        where sof.order_item_id=soi.id
          and sof.status='uploaded'
      )
  ) then
    v_blockers := v_blockers || jsonb_build_array(
      jsonb_build_object(
        'code','EXPECTED_FILE_MISSING',
        'message','At least one order item names a customer file but no private upload is linked.'
      )
    );
  end if;

  if v_order.payment_status <> 'paid' then
    v_warnings := v_warnings || jsonb_build_array(
      jsonb_build_object(
        'code','PAYMENT_NOT_PAID',
        'message','The Quick Solution order is not marked paid. OPPS may receive it for review, but staff should control production release.'
      )
    );
  end if;

  if v_order.fulfilment_type in ('cafe','quick_point') then
    v_fulfillment_type := 'collection';
    v_apply_shipping := false;
  elsif v_order.fulfilment_type='delivery' then
    v_fulfillment_type := 'courier';
    v_apply_shipping := true;
    if v_order.delivery_address is null then
      v_blockers := v_blockers || jsonb_build_array(
        jsonb_build_object('code','DELIVERY_ADDRESS_MISSING','message','Delivery orders require a delivery address.')
      );
    end if;
  else
    v_fulfillment_type := 'service_only';
    v_apply_shipping := false;
  end if;

  v_payment_status := case v_order.payment_status
    when 'paid' then 'paid'
    when 'failed' then 'failed'
    when 'cancelled' then 'cancelled'
    else 'pending'
  end;

  if v_order.fulfilment_point_id is not null then
    select * into v_point
    from commerce.fulfilment_points fp
    where fp.id=v_order.fulfilment_point_id
      and fp.tenant_id=v_order.tenant_id
    limit 1;
  end if;

  if jsonb_typeof(v_order.source_metadata->'fulfilmentPointSnapshot')='object' then
    v_point_snapshot := v_order.source_metadata->'fulfilmentPointSnapshot';
  elsif v_point.id is not null then
    v_point_snapshot := jsonb_build_object(
      'id',v_point.id,
      'slug',v_point.slug,
      'name',v_point.name,
      'kind',v_point.kind,
      'address',v_point.address,
      'contactPhone',v_point.contact_phone,
      'easyLocateBusinessRef',v_point.easy_locate_business_ref,
      'latitude',v_point.latitude,
      'longitude',v_point.longitude,
      'services',v_point.services,
      'feeAmount',v_point.fee_amount
    );
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'name', soi.product_name,
      'quantity', greatest(coalesce(public.safe_numeric(soi.configuration->>'quantity'), soi.quantity, 1), 1),
      'price',
        case
          when greatest(coalesce(public.safe_numeric(soi.configuration->>'quantity'), soi.quantity, 1),1) > 0
          then round(soi.line_total / greatest(coalesce(public.safe_numeric(soi.configuration->>'quantity'), soi.quantity, 1),1), 2)
          else soi.line_total
        end,
      'line_total', soi.line_total,
      'line_id', soi.id::text,
      'line_role', 'product',
      'source', 'quick_solution',
      'category', coalesce(c.customer_definition->>'category','Quick Solution'),
      'price_breakdown', jsonb_build_object(
        'mode','quick_solution_snapshot',
        'pricing_version',soi.pricing_snapshot->>'pricingVersion',
        'calculation',coalesce(soi.pricing_snapshot->'calculation','{}'::jsonb)
      ),
      'quick_solution', jsonb_build_object(
        'service_order_item_id',soi.id,
        'product_key',soi.product_key,
        'configuration',soi.configuration,
        'pricing_version',soi.pricing_snapshot->>'pricingVersion',
        'file_refs',coalesce(soi.file_refs,'[]'::jsonb)
      )
    )
    order by soi.created_at
  ), '[]'::jsonb)
  into v_items
  from commerce.service_order_items soi
  left join commerce.service_product_configs c
    on c.tenant_id=soi.tenant_id
   and c.source_key=soi.product_key
  where soi.order_id=v_order.id;

  select
    coalesce(jsonb_agg(
      jsonb_build_object(
        'id', sof.id,
        'orderItemId', sof.order_item_id,
        'name', sof.original_filename,
        'mimeType', sof.mime_type,
        'byteSize', sof.byte_size,
        'bucket', sof.storage_bucket,
        'path', sof.storage_path,
        'privateUri', 'private-upload://' || sof.storage_bucket || '/' || sof.storage_path
      )
      order by sof.uploaded_at
    ), '[]'::jsonb),
    coalesce(jsonb_agg(
      to_jsonb('private-upload://' || sof.storage_bucket || '/' || sof.storage_path)
      order by sof.uploaded_at
    ), '[]'::jsonb)
  into v_files, v_file_urls
  from commerce.service_order_files sof
  where sof.order_id=v_order.id
    and sof.status='uploaded';

  v_ready := jsonb_array_length(v_blockers)=0;

  return jsonb_build_object(
    'mappingVersion','qs-opps-v1',
    'ready',v_ready,
    'blockers',v_blockers,
    'warnings',v_warnings,
    'sourceOrder',jsonb_build_object(
      'id',v_order.id,
      'orderNumber',v_order.order_number,
      'tenantId',v_order.tenant_id,
      'tenantSlug',v_source_tenant.slug,
      'status',v_order.status,
      'paymentStatus',v_order.payment_status,
      'submittedAt',v_order.submitted_at
    ),
    'proposedOppsOrder',jsonb_build_object(
      'tenant_id',v_target_tenant.id,
      'order_number',v_order.order_number,
      'client_name',v_order.customer_name,
      'client_email',v_order.customer_email,
      'client_phone',v_order.customer_phone,
      'status','confirmed',
      'pipeline_stage','received',
      'priority','normal',
      'source','quick_solution',
      'products',v_items,
      'total_amount',v_order.total_amount,
      'deposit_paid',case when v_order.payment_status='paid' then v_order.total_amount else 0 end,
      'payment_status',v_payment_status,
      'fulfillment_type',v_fulfillment_type,
      'apply_shipping_fee',v_apply_shipping,
      'shipping_fee',v_order.fulfilment_fee,
      'shipping_address',case when v_order.fulfilment_type='delivery' then v_order.delivery_address else null end,
      'shipping_method',
        case
          when v_order.fulfilment_type='quick_point' then 'Quick Point collection'
          when v_order.fulfilment_type='cafe' then 'Quick Solution Café collection'
          when v_order.fulfilment_type='delivery' then 'Quick Solution delivery'
          else null
        end,
      'file_urls',v_file_urls,
      'special_instructions',v_order.customer_notes,
      'portal_show_files',false,
      'account_show_files',false,
      'source_metadata',jsonb_build_object(
        'quick_solution',jsonb_build_object(
          'service_order_id',v_order.id,
          'service_order_number',v_order.order_number,
          'mapping_version','qs-opps-v1',
          'fulfilment_type',v_order.fulfilment_type,
          'fulfilment_point',v_point_snapshot,
          'pricing_total',v_order.total_amount,
          'files',v_files
        )
      )
    )
  );
end
$$;

update commerce.service_order_handoffs h
set preview_payload = jsonb_set(
      h.preview_payload,
      '{proposedOppsOrder,source_metadata,quick_solution,fulfilment_point}',
      so.source_metadata->'fulfilmentPointSnapshot',
      true
    ),
    updated_at = now()
from commerce.service_orders so
where h.service_order_id=so.id
  and jsonb_typeof(h.preview_payload)='object'
  and jsonb_typeof(so.source_metadata->'fulfilmentPointSnapshot')='object';
