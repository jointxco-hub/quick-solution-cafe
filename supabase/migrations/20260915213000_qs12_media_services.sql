-- QS-12: Photography & Video service requests + service-only OPPS handoff.
-- Adds a quote-first Media Services catalogue item and a dedicated public
-- service-request RPC. Existing print/product order flow remains unchanged.

begin;

-- ---------------------------------------------------------------------------
-- Allow non-shipping service requests to live in the same Quick Solution
-- service_orders table and flow through the existing OPPS handoff boundary.
-- QS-04 already maps unknown/non-shipping fulfilment types to service_only.
-- ---------------------------------------------------------------------------
alter table commerce.service_orders
  drop constraint if exists service_orders_fulfilment_type_check;

alter table commerce.service_orders
  add constraint service_orders_fulfilment_type_check
  check (fulfilment_type in ('cafe','quick_point','delivery','service'));

-- ---------------------------------------------------------------------------
-- Preserve the existing canonical calculator as a legacy implementation, then
-- place a thin wrapper in front of it for quote-first ENQUIRY products.
-- ---------------------------------------------------------------------------
do $qs12$
begin
  if to_regprocedure('commerce.qs_calculate_price_legacy(uuid,text,jsonb)') is null then
    if to_regprocedure('commerce.qs_calculate_price(uuid,text,jsonb)') is null then
      raise exception 'QS-12 prerequisite missing: commerce.qs_calculate_price(uuid,text,jsonb)';
    end if;

    alter function commerce.qs_calculate_price(uuid,text,jsonb)
      rename to qs_calculate_price_legacy;
  end if;
end
$qs12$;

create or replace function commerce.qs_calculate_price(
  p_tenant_id uuid,
  p_product_key text,
  p_configuration jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_product_id uuid;
  v_product_name text;
  v_pricing_version text;
  v_pricing jsonb;
  v_strategy text;
begin
  if p_configuration is null or jsonb_typeof(p_configuration) is distinct from 'object' then
    raise exception using errcode = '22023', message = 'Configuration must be a JSON object.';
  end if;

  select p.id, p.name, c.pricing_version, c.pricing_definition
    into v_product_id, v_product_name, v_pricing_version, v_pricing
  from commerce.service_product_configs c
  join commerce.products p
    on p.id = c.product_id
   and p.tenant_id = c.tenant_id
  where c.tenant_id = p_tenant_id
    and c.source_key = trim(p_product_key)
    and c.status = 'published'
    and p.status = 'published'
    and p.availability = 'available'
  limit 1;

  if v_product_id is null then
    raise exception using errcode = '22023', message = 'Product is not available.';
  end if;

  v_strategy := upper(coalesce(v_pricing->>'strategy', ''));

  if v_strategy = 'ENQUIRY' then
    return jsonb_build_object(
      'productId', v_product_id,
      'productKey', trim(p_product_key),
      'productName', v_product_name,
      'total', 0,
      'summary', 'Quote after review',
      'lines', jsonb_build_array(
        jsonb_build_object('label','Service request','text','Photo / video brief captured'),
        jsonb_build_object('label','Pricing','text','Confirmed after crew, location and scope review')
      ),
      'metrics', jsonb_build_object(
        'quoteRequired', true,
        'serviceType', coalesce(v_pricing->>'serviceType','service')
      ),
      'snapshot', jsonb_build_object(
        'pricingVersion', v_pricing_version,
        'productKey', trim(p_product_key),
        'productName', v_product_name,
        'pricingStrategy', v_strategy,
        'configuration', p_configuration,
        'pricingDefinition', v_pricing,
        'calculation', jsonb_build_object(
          'lines', jsonb_build_array(
            jsonb_build_object('label','Service request','text','Photo / video brief captured'),
            jsonb_build_object('label','Pricing','text','Confirmed after crew, location and scope review')
          ),
          'metrics', jsonb_build_object('quoteRequired',true),
          'total', 0
        ),
        'capturedAt', now()
      )
    );
  end if;

  return commerce.qs_calculate_price_legacy(
    p_tenant_id,
    p_product_key,
    p_configuration
  );
end
$$;

revoke all on function commerce.qs_calculate_price(uuid,text,jsonb)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Media Services catalogue item.
-- ---------------------------------------------------------------------------
insert into commerce.products (
  tenant_id,
  slug,
  name,
  description,
  currency,
  availability,
  status,
  source_system,
  source_ref
)
select
  t.id,
  'media-services',
  'Photography & Video',
  'From quick café shoots to full on-location photo and video production.',
  'ZAR',
  'available',
  'published',
  'quick_solution',
  'media-services'
from public.tenants t
where t.slug='quick-solution'
  and not exists (
    select 1
    from commerce.products p
    where p.tenant_id=t.id
      and p.slug='media-services'
  );

update commerce.products p
set name='Photography & Video',
    description='From quick café shoots to full on-location photo and video production.',
    availability='available',
    status='published',
    source_system='quick_solution',
    source_ref='media-services',
    updated_at=now()
from public.tenants t
where p.tenant_id=t.id
  and t.slug='quick-solution'
  and p.slug='media-services';

insert into commerce.service_product_configs (
  tenant_id,
  product_id,
  source_key,
  customer_definition,
  pricing_version,
  pricing_definition,
  status,
  sort_order
)
select
  t.id,
  p.id,
  'media-services',
  jsonb_build_object(
    'id','media-services',
    'name','Photography & Video',
    'shortName','Photo + Video',
    'category','Photo & Video',
    'description','From quick café shoots to full on-location photo and video production.',
    'plainDescription','Choose what you need, where the shoot should happen and which medium should lead.',
    'keywords',jsonb_build_array(
      'photography','photo','video','videography','headshot','id photo',
      'product photography','content','reels','event','matric dance','onsite shoot'
    ),
    'popular',true,
    'active',true,
    'serviceType','media',
    'channels',jsonb_build_object(
      'storefront',true,
      'guided',true,
      'advanced',false,
      'pos',true,
      'quote',true
    ),
    'guidedJourneyId','media-guided',
    'nextActionLabel','Send request',
    'pricing',jsonb_build_object(
      'strategy','ENQUIRY',
      'quoteRequired',true
    ),
    'fields',jsonb_build_array(
      jsonb_build_object(
        'id','mediumFocus','type','segmented',
        'label','What do you need?','shortLabel','Media focus','default','balanced',
        'options',jsonb_build_array(
          jsonb_build_object('id','photo-only','label','Photography only','helper','Still photography is the full focus.'),
          jsonb_build_object('id','video-only','label','Video only','helper','Video is the full focus.'),
          jsonb_build_object('id','photo-led','label','Photo-led','helper','Photography is primary with a few supporting video clips.'),
          jsonb_build_object('id','video-led','label','Video-led','helper','Video is primary with a smaller set of supporting photos.'),
          jsonb_build_object('id','balanced','label','Photo + video','helper','A balanced mix of photography and video.')
        )
      ),
      jsonb_build_object(
        'id','shootType','type','select',
        'label','What are we shooting?','shortLabel','Shoot type','default','business-content',
        'options',jsonb_build_array(
          jsonb_build_object('id','id-passport','label','ID / passport photos'),
          jsonb_build_object('id','headshot','label','Professional headshot / CV / LinkedIn'),
          jsonb_build_object('id','products','label','Products / ecommerce'),
          jsonb_build_object('id','business-content','label','Business / brand content'),
          jsonb_build_object('id','social-content','label','Social media / reels content'),
          jsonb_build_object('id','staff-team','label','Staff / team portraits'),
          jsonb_build_object('id','event','label','Event coverage'),
          jsonb_build_object('id','matric-dance','label','Matric dance'),
          jsonb_build_object('id','property-location','label','Property / location'),
          jsonb_build_object('id','campaign','label','Campaign / commercial shoot'),
          jsonb_build_object('id','other','label','Something else')
        )
      ),
      jsonb_build_object(
        'id','shootLocation','type','segmented',
        'label','Where should the shoot happen?','shortLabel','Shoot location','default','cafe',
        'options',jsonb_build_array(
          jsonb_build_object('id','cafe','label','At Quick Solution Café','helper','Come to us for quick portraits, headshots, product shots and short content sessions.'),
          jsonb_build_object('id','client-location','label','Shoot at my location','helper','We send our photographer or videographer to your home, office, shop, venue or chosen location.'),
          jsonb_build_object('id','onsite-team','label','Send a photo / video team','helper','For bigger coverage, events, campaigns or shoots that need more than one person.')
        )
      ),
      jsonb_build_object(
        'id','crew','type','select',
        'label','Who should we send?','shortLabel','Crew','default','recommend',
        'options',jsonb_build_array(
          jsonb_build_object('id','photographer','label','Photographer'),
          jsonb_build_object('id','videographer','label','Videographer'),
          jsonb_build_object('id','photo-video-duo','label','Photographer + videographer'),
          jsonb_build_object('id','content-team','label','Small content team'),
          jsonb_build_object('id','recommend','label','Not sure — recommend the right setup')
        )
      ),
      jsonb_build_object(
        'id','duration','type','select',
        'label','Roughly how long do you think you need?','shortLabel','Duration','default','not-sure',
        'options',jsonb_build_array(
          jsonb_build_object('id','under-1h','label','Under 1 hour'),
          jsonb_build_object('id','1h','label','About 1 hour'),
          jsonb_build_object('id','2h','label','About 2 hours'),
          jsonb_build_object('id','half-day','label','Half day'),
          jsonb_build_object('id','full-day','label','Full day'),
          jsonb_build_object('id','not-sure','label','Not sure yet')
        )
      ),
      jsonb_build_object(
        'id','preferredDate','type','date',
        'label','Preferred shoot date','shortLabel','Preferred date','default',''
      ),
      jsonb_build_object(
        'id','preferredTime','type','time',
        'label','Preferred start time','shortLabel','Preferred time','default',''
      ),
      jsonb_build_object(
        'id','shootAddress','type','text',
        'label','Shoot address / area','shortLabel','Address',
        'placeholder','Area, venue or full address',
        'help','If you are coming to the Café, you can leave this blank.',
        'default',''
      ),
      jsonb_build_object(
        'id','deliverables','type','textarea',
        'label','What do you want us to deliver?','shortLabel','Deliverables',
        'placeholder','Example: one 60-second promo video, 3 reels and 15 edited photos.',
        'help','Tell us the outcome rather than technical camera details.',
        'default',''
      ),
      jsonb_build_object(
        'id','file','type','file',
        'label','Reference / moodboard',
        'help','Optional. Upload an image or PDF reference if it helps explain the look you want.'
      )
    )
  ),
  '2026-09-qsc-06',
  jsonb_build_object(
    'strategy','ENQUIRY',
    'quoteRequired',true,
    'serviceType','media'
  ),
  'published',
  20
from public.tenants t
join commerce.products p
  on p.tenant_id=t.id
 and p.slug='media-services'
where t.slug='quick-solution'
on conflict (tenant_id, source_key) do update
set product_id=excluded.product_id,
    customer_definition=excluded.customer_definition,
    pricing_version=excluded.pricing_version,
    pricing_definition=excluded.pricing_definition,
    status='published',
    sort_order=excluded.sort_order,
    updated_at=now();

-- ---------------------------------------------------------------------------
-- Dedicated quote-first service request intake.
-- No PayFast token is created because the scope and price are intentionally
-- confirmed after review.
-- ---------------------------------------------------------------------------
create or replace function public.create_quick_solution_service_request(
  p_tenant_slug text,
  p_product_key text,
  p_configuration jsonb,
  p_customer_name text,
  p_customer_email text default null,
  p_customer_phone text default null,
  p_service_location jsonb default null,
  p_customer_notes text default null,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_order_id uuid;
  v_order_item_id uuid;
  v_existing commerce.service_orders;
  v_order_number text;
  v_price jsonb;
  v_product_id uuid;
  v_product_name text;
  v_email text;
  v_phone text;
  v_upload_token text;
begin
  select t.id into v_tenant_id
  from public.tenants t
  where t.slug=lower(trim(p_tenant_slug))
    and t.status='active'
    and exists (
      select 1
      from public.tenant_capabilities tc
      where tc.tenant_id=t.id
        and tc.capability_key='quick_solution'
        and tc.enabled=true
    )
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode='22023', message='Quick Solution storefront is not active.';
  end if;

  if length(trim(coalesce(p_idempotency_key,''))) < 8 then
    raise exception using errcode='22023', message='Request idempotency key is required.';
  end if;

  if length(trim(coalesce(p_customer_name,''))) < 2 then
    raise exception using errcode='22023', message='Customer name is required.';
  end if;

  v_email := nullif(lower(trim(coalesce(p_customer_email,''))), '');
  v_phone := nullif(trim(coalesce(p_customer_phone,'')), '');

  if v_email is null and v_phone is null then
    raise exception using errcode='22023', message='Provide an email address or phone number.';
  end if;

  if v_email is not null and position('@' in v_email) < 2 then
    raise exception using errcode='22023', message='Email address is not valid.';
  end if;

  if v_phone is not null
     and length(regexp_replace(v_phone, '[^0-9+]', '', 'g')) < 7 then
    raise exception using errcode='22023', message='Phone number is not valid.';
  end if;

  select * into v_existing
  from commerce.service_orders so
  where so.tenant_id=v_tenant_id
    and so.idempotency_key=trim(p_idempotency_key)
  limit 1;

  if v_existing.id is not null then
    v_upload_token := encode(extensions.gen_random_bytes(32), 'hex');

    update commerce.service_orders
    set upload_token_hash=encode(extensions.digest(v_upload_token,'sha256'),'hex'),
        upload_token_expires_at=now()+interval '24 hours'
    where id=v_existing.id;

    select soi.id into v_order_item_id
    from commerce.service_order_items soi
    where soi.order_id=v_existing.id
    order by soi.created_at asc
    limit 1;

    return jsonb_build_object(
      'ok',true,
      'replayed',true,
      'orderId',v_existing.id,
      'orderItemId',v_order_item_id,
      'orderNumber',v_existing.order_number,
      'subtotal',v_existing.subtotal,
      'fulfilmentFee',v_existing.fulfilment_fee,
      'totalAmount',v_existing.total_amount,
      'status',v_existing.status,
      'paymentStatus',v_existing.payment_status,
      'quoteRequired',true,
      'uploadToken',v_upload_token,
      'uploadTokenExpiresAt',now()+interval '24 hours'
    );
  end if;

  v_price := commerce.qs_calculate_price(
    v_tenant_id,
    trim(p_product_key),
    p_configuration
  );

  if upper(coalesce(v_price->'snapshot'->>'pricingStrategy','')) <> 'ENQUIRY' then
    raise exception using errcode='22023', message='This product is not configured as a service enquiry.';
  end if;

  v_product_id := (v_price->>'productId')::uuid;
  v_product_name := v_price->>'productName';
  v_order_number := commerce.qs_generate_order_number();
  v_upload_token := encode(extensions.gen_random_bytes(32), 'hex');

  insert into commerce.service_orders (
    tenant_id,
    order_number,
    status,
    customer_name,
    customer_email,
    customer_phone,
    fulfilment_type,
    fulfilment_point_id,
    delivery_address,
    subtotal,
    fulfilment_fee,
    total_amount,
    payment_status,
    idempotency_key,
    customer_notes,
    source_metadata,
    upload_token_hash,
    upload_token_expires_at
  ) values (
    v_tenant_id,
    v_order_number,
    'submitted',
    trim(p_customer_name),
    v_email,
    v_phone,
    'service',
    null,
    case
      when p_service_location is not null
       and jsonb_typeof(p_service_location)='object'
      then p_service_location
      else null
    end,
    0,
    0,
    0,
    'unpaid',
    trim(p_idempotency_key),
    nullif(trim(coalesce(p_customer_notes,'')), ''),
    jsonb_build_object(
      'channel','storefront',
      'requestType','media_service',
      'quoteRequired',true,
      'quoteStatus','pending_review',
      'serviceLocation',p_service_location
    ),
    encode(extensions.digest(v_upload_token,'sha256'),'hex'),
    now()+interval '24 hours'
  )
  returning id into v_order_id;

  insert into commerce.service_order_items (
    order_id,
    tenant_id,
    product_id,
    product_key,
    product_name,
    quantity,
    configuration,
    pricing_snapshot,
    line_total
  ) values (
    v_order_id,
    v_tenant_id,
    v_product_id,
    trim(p_product_key),
    v_product_name,
    1,
    p_configuration,
    v_price->'snapshot',
    0
  )
  returning id into v_order_item_id;

  return jsonb_build_object(
    'ok',true,
    'replayed',false,
    'orderId',v_order_id,
    'orderItemId',v_order_item_id,
    'orderNumber',v_order_number,
    'subtotal',0,
    'fulfilmentFee',0,
    'totalAmount',0,
    'status','submitted',
    'paymentStatus','unpaid',
    'quoteRequired',true,
    'uploadToken',v_upload_token,
    'uploadTokenExpiresAt',now()+interval '24 hours'
  );
end
$$;

revoke all on function public.create_quick_solution_service_request(
  text,text,jsonb,text,text,text,jsonb,text,text
) from public;

grant execute on function public.create_quick_solution_service_request(
  text,text,jsonb,text,text,text,jsonb,text,text
) to anon, authenticated;

commit;
