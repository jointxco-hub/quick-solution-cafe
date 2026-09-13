
-- QS-03: Quick Solution persistent catalog, pricing snapshots, fulfilment points and guest orders.
-- Target: Joint X XOS Staging.
-- This migration intentionally keeps direct table access closed. Storefront access is RPC-only.

create schema if not exists commerce;

create table if not exists commerce.service_product_configs (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  product_id uuid not null references commerce.products(id) on delete cascade,
  source_key text not null,
  customer_definition jsonb not null default '{}'::jsonb,
  pricing_version text not null,
  pricing_definition jsonb not null default '{}'::jsonb,
  status text not null default 'draft'
    check (status in ('draft','published','archived')),
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, source_key),
  unique (tenant_id, product_id)
);

create table if not exists commerce.fulfilment_points (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  slug text not null,
  name text not null,
  kind text not null check (kind in ('cafe','quick_point')),
  status text not null default 'active'
    check (status in ('active','inactive','coming_soon')),
  address jsonb not null default '{}'::jsonb,
  contact_phone text,
  contact_email text,
  easy_locate_business_ref text,
  latitude numeric,
  longitude numeric,
  collection_enabled boolean not null default true,
  dropoff_enabled boolean not null default false,
  services text[] not null default '{}'::text[],
  fee_amount numeric not null default 0 check (fee_amount >= 0),
  opening_hours jsonb not null default '{}'::jsonb,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, slug)
);

create table if not exists commerce.service_orders (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  order_number text not null,
  status text not null default 'submitted'
    check (status in ('draft','submitted','accepted','in_production','ready','completed','cancelled')),
  customer_name text not null,
  customer_email text,
  customer_phone text,
  fulfilment_type text not null default 'cafe'
    check (fulfilment_type in ('cafe','quick_point','delivery')),
  fulfilment_point_id uuid references commerce.fulfilment_points(id) on delete set null,
  delivery_address jsonb,
  subtotal numeric not null default 0 check (subtotal >= 0),
  fulfilment_fee numeric not null default 0 check (fulfilment_fee >= 0),
  total_amount numeric not null default 0 check (total_amount >= 0),
  payment_status text not null default 'unpaid'
    check (payment_status in ('unpaid','pending','paid','failed','refunded','cancelled')),
  idempotency_key text not null,
  customer_notes text,
  source text not null default 'quick_solution',
  source_metadata jsonb not null default '{}'::jsonb,
  opps_order_id uuid,
  submitted_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, order_number),
  unique (tenant_id, idempotency_key)
);

create table if not exists commerce.service_order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references commerce.service_orders(id) on delete cascade,
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  product_id uuid not null references commerce.products(id) on delete restrict,
  product_key text not null,
  product_name text not null,
  quantity numeric not null default 1 check (quantity > 0),
  configuration jsonb not null default '{}'::jsonb,
  pricing_snapshot jsonb not null default '{}'::jsonb,
  file_refs jsonb not null default '[]'::jsonb,
  line_total numeric not null default 0 check (line_total >= 0),
  created_at timestamptz not null default now()
);

create index if not exists idx_service_product_configs_tenant_status
  on commerce.service_product_configs (tenant_id, status, sort_order);

create index if not exists idx_fulfilment_points_tenant_status
  on commerce.fulfilment_points (tenant_id, status, sort_order);

create index if not exists idx_service_orders_tenant_created
  on commerce.service_orders (tenant_id, created_at desc);

create index if not exists idx_service_order_items_order
  on commerce.service_order_items (order_id);

alter table commerce.service_product_configs enable row level security;
alter table commerce.fulfilment_points enable row level security;
alter table commerce.service_orders enable row level security;
alter table commerce.service_order_items enable row level security;

revoke all on commerce.service_product_configs from anon, authenticated;
revoke all on commerce.fulfilment_points from anon, authenticated;
revoke all on commerce.service_orders from anon, authenticated;
revoke all on commerce.service_order_items from anon, authenticated;

do $$
begin
  if not exists (
    select 1 from pg_trigger
    where tgname = 'trg_qs_service_product_configs_updated_at'
      and tgrelid = 'commerce.service_product_configs'::regclass
  ) then
    create trigger trg_qs_service_product_configs_updated_at
    before update on commerce.service_product_configs
    for each row execute function public.handle_updated_at();
  end if;

  if not exists (
    select 1 from pg_trigger
    where tgname = 'trg_qs_fulfilment_points_updated_at'
      and tgrelid = 'commerce.fulfilment_points'::regclass
  ) then
    create trigger trg_qs_fulfilment_points_updated_at
    before update on commerce.fulfilment_points
    for each row execute function public.handle_updated_at();
  end if;

  if not exists (
    select 1 from pg_trigger
    where tgname = 'trg_qs_service_orders_updated_at'
      and tgrelid = 'commerce.service_orders'::regclass
  ) then
    create trigger trg_qs_service_orders_updated_at
    before update on commerce.service_orders
    for each row execute function public.handle_updated_at();
  end if;
end
$$;

create or replace function commerce.qs_generate_order_number()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_candidate text;
  v_try integer := 0;
begin
  loop
    v_try := v_try + 1;
    v_candidate :=
      'QS-' ||
      to_char(clock_timestamp() at time zone 'Africa/Johannesburg', 'YYMMDD') ||
      '-' ||
      upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 4));

    exit when not exists (
      select 1
      from commerce.service_orders so
      where so.order_number = v_candidate
    );

    if v_try >= 10 then
      raise exception 'Could not allocate Quick Solution order number.';
    end if;
  end loop;

  return v_candidate;
end
$$;

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
  v_total numeric := 0;
  v_summary text := '';
  v_lines jsonb := '[]'::jsonb;
  v_metrics jsonb := '{}'::jsonb;

  v_width numeric;
  v_height numeric;
  v_raw_area numeric;
  v_billable_area numeric;
  v_base numeric;
  v_service_fees numeric;
  v_turn_mult numeric;

  v_pages integer;
  v_copies integer;
  v_rate numeric;
  v_side_mult numeric;
  v_finish_fee numeric;
  v_printed_pages numeric;

  v_quantity integer;
  v_unit numeric;
  v_discount numeric;

  v_material text;
  v_finishing text;
  v_artwork text;
  v_turnaround text;
  v_print_mode text;
  v_sides text;
  v_finish text;
  v_stock text;
  v_garment text;
  v_front text;
  v_back text;
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

  if v_strategy = 'PER_AREA' then
    begin
      v_width := (p_configuration->>'width')::numeric;
      v_height := (p_configuration->>'height')::numeric;
    exception when others then
      raise exception using errcode = '22023', message = 'Width and height must be valid numbers.';
    end;

    if v_width <= 0 or v_height <= 0 or v_width > 20 or v_height > 20 then
      raise exception using errcode = '22023', message = 'Banner dimensions are outside the supported range.';
    end if;

    v_material := coalesce(nullif(p_configuration->>'material',''), 'standard');
    v_finishing := coalesce(nullif(p_configuration->>'finishing',''), 'hem-eyelets');
    v_artwork := coalesce(nullif(p_configuration->>'artwork',''), 'ready');
    v_turnaround := coalesce(nullif(p_configuration->>'turnaround',''), 'standard');

    if not coalesce((v_pricing->'materials') ? v_material, false)
       or not coalesce((v_pricing->'finishing') ? v_finishing, false)
       or not coalesce((v_pricing->'artwork') ? v_artwork, false)
       or not coalesce((v_pricing->'turnaround') ? v_turnaround, false) then
      raise exception using errcode = '22023', message = 'One or more banner options are invalid.';
    end if;

    v_raw_area := v_width * v_height;
    v_billable_area := greatest(v_raw_area, coalesce((v_pricing->>'minimumBillableArea')::numeric, 0));
    v_base := v_billable_area
      * coalesce((v_pricing->>'baseRate')::numeric, 0)
      * coalesce((v_pricing->'materials'->v_material->>'multiplier')::numeric, 1);
    v_service_fees :=
      coalesce((v_pricing->'finishing'->v_finishing->>'fee')::numeric, 0) +
      coalesce((v_pricing->'artwork'->v_artwork->>'fee')::numeric, 0);
    v_turn_mult := coalesce((v_pricing->'turnaround'->v_turnaround->>'multiplier')::numeric, 1);
    v_total := round((v_base + v_service_fees) * v_turn_mult, 2);
    v_summary := to_char(v_raw_area, 'FM999990.00') || 'm² actual · ' ||
                 to_char(v_billable_area, 'FM999990.00') || 'm² billable';
    v_lines := jsonb_build_array(
      jsonb_build_object('label','Print + material','value',round(v_base,2)),
      jsonb_build_object('label','Finishing + artwork','value',round(v_service_fees,2)),
      jsonb_build_object('label','Turnaround','text',v_turnaround)
    );
    v_metrics := jsonb_build_object('rawArea',v_raw_area,'billableArea',v_billable_area);

  elsif v_strategy = 'PER_PAGE' then
    begin
      v_pages := greatest(coalesce((p_configuration->>'pages')::integer, 1), 1);
      v_copies := greatest(coalesce((p_configuration->>'copies')::integer, 1), 1);
    exception when others then
      raise exception using errcode = '22023', message = 'Pages and copies must be whole numbers.';
    end;

    if v_pages > 1000 or v_copies > 500 then
      raise exception using errcode = '22023', message = 'Document quantity is outside the supported range.';
    end if;

    v_print_mode := coalesce(nullif(p_configuration->>'printMode',''), 'bw');
    v_sides := coalesce(nullif(p_configuration->>'sides',''), 'single');
    v_finish := coalesce(nullif(p_configuration->>'finish',''), 'none');

    if not coalesce((v_pricing->'rates') ? v_print_mode, false)
       or not coalesce((v_pricing->'sides') ? v_sides, false)
       or not coalesce((v_pricing->'finishes') ? v_finish, false) then
      raise exception using errcode = '22023', message = 'One or more document options are invalid.';
    end if;

    v_rate := coalesce((v_pricing->'rates'->v_print_mode->>'rate')::numeric, 0);
    v_side_mult := coalesce((v_pricing->'sides'->v_sides->>'multiplier')::numeric, 1);
    v_finish_fee := coalesce((v_pricing->'finishes'->v_finish->>'fee')::numeric, 0);
    v_printed_pages := v_pages * v_copies;
    v_base := v_printed_pages * v_rate * v_side_mult;
    v_service_fees := v_finish_fee * v_copies;
    v_total := round(v_base + v_service_fees, 2);
    v_summary := v_pages::text || ' page' || case when v_pages = 1 then '' else 's' end ||
                 ' × ' || v_copies::text || ' cop' || case when v_copies = 1 then 'y' else 'ies' end;
    v_lines := jsonb_build_array(
      jsonb_build_object('label',v_print_mode,'value',round(v_base,2)),
      jsonb_build_object('label',v_sides,'text',case when v_sides='double' then 'paper-saving option' else 'standard' end),
      jsonb_build_object('label',v_finish,'value',round(v_service_fees,2))
    );
    v_metrics := jsonb_build_object('pages',v_pages,'copies',v_copies,'printedPages',v_printed_pages);

  elsif v_strategy = 'TIERED' then
    v_quantity := greatest(coalesce(nullif(p_configuration->>'quantity','')::integer, 100), 1);
    v_stock := coalesce(nullif(p_configuration->>'stock',''), 'standard');
    v_finish := coalesce(nullif(p_configuration->>'finish',''), 'standard');
    v_artwork := coalesce(nullif(p_configuration->>'artwork',''), 'ready');

    if not coalesce((v_pricing->'quantities') ? v_quantity::text, false)
       or not coalesce((v_pricing->'stock') ? v_stock, false)
       or not coalesce((v_pricing->'finishes') ? v_finish, false)
       or not coalesce((v_pricing->'artwork') ? v_artwork, false) then
      raise exception using errcode = '22023', message = 'One or more business-card options are invalid.';
    end if;

    v_base :=
      coalesce((v_pricing->'quantities'->v_quantity::text->>'total')::numeric, 0) *
      coalesce((v_pricing->'stock'->v_stock->>'multiplier')::numeric, 1);
    v_service_fees :=
      coalesce((v_pricing->'finishes'->v_finish->>'fee')::numeric, 0) +
      coalesce((v_pricing->'artwork'->v_artwork->>'fee')::numeric, 0);
    v_total := round(v_base + v_service_fees, 2);
    v_summary := v_quantity::text || ' cards · ' || v_stock;
    v_lines := jsonb_build_array(
      jsonb_build_object('label','Cards','value',round(v_base,2)),
      jsonb_build_object('label',v_finish,'value',coalesce((v_pricing->'finishes'->v_finish->>'fee')::numeric,0)),
      jsonb_build_object('label',v_artwork,'value',coalesce((v_pricing->'artwork'->v_artwork->>'fee')::numeric,0))
    );
    v_metrics := jsonb_build_object('quantity',v_quantity);

  elsif v_strategy = 'CONFIGURABLE' then
    begin
      v_quantity := greatest(coalesce((p_configuration->>'quantity')::integer, 1), 1);
    exception when others then
      raise exception using errcode = '22023', message = 'Quantity must be a whole number.';
    end;

    if v_quantity > 250 then
      raise exception using errcode = '22023', message = 'T-shirt quantity is outside the supported range.';
    end if;

    v_garment := coalesce(nullif(p_configuration->>'garment',''), 'jointx-220');
    v_front := coalesce(nullif(p_configuration->>'frontPrint',''), 'a4');
    v_back := coalesce(nullif(p_configuration->>'backPrint',''), 'none');
    v_artwork := coalesce(nullif(p_configuration->>'artwork',''), 'ready');

    if not coalesce((v_pricing->'garments') ? v_garment, false)
       or not coalesce((v_pricing->'frontPrint') ? v_front, false)
       or not coalesce((v_pricing->'backPrint') ? v_back, false)
       or not coalesce((v_pricing->'artwork') ? v_artwork, false) then
      raise exception using errcode = '22023', message = 'One or more T-shirt options are invalid.';
    end if;

    v_unit :=
      coalesce((v_pricing->'garments'->v_garment->>'unitFee')::numeric,0) +
      coalesce((v_pricing->'frontPrint'->v_front->>'unitFee')::numeric,0) +
      coalesce((v_pricing->'backPrint'->v_back->>'unitFee')::numeric,0);

    v_discount := case when v_quantity >= 25 then 0.90 when v_quantity >= 10 then 0.95 else 1 end;
    v_base := v_unit * v_quantity * v_discount;
    v_service_fees := coalesce((v_pricing->'artwork'->v_artwork->>'fee')::numeric,0);
    v_total := round(v_base + v_service_fees, 2);
    v_summary := v_quantity::text || ' shirt' || case when v_quantity=1 then '' else 's' end || ' · ' || v_garment;
    v_lines := jsonb_build_array(
      jsonb_build_object('label','Garment + print','value',round(v_base,2)),
      jsonb_build_object('label','Artwork support','value',round(v_service_fees,2)),
      jsonb_build_object('label','Quantity pricing','text',
        case when v_discount < 1 then round((1-v_discount)*100)::text || '% quantity saving' else 'standard' end)
    );
    v_metrics := jsonb_build_object('quantity',v_quantity,'unit',v_unit,'discount',v_discount);

  else
    raise exception using errcode = '22023', message = 'Unsupported pricing strategy.';
  end if;

  return jsonb_build_object(
    'productId', v_product_id,
    'productKey', p_product_key,
    'productName', v_product_name,
    'total', v_total,
    'summary', v_summary,
    'lines', v_lines,
    'metrics', v_metrics,
    'snapshot', jsonb_build_object(
      'pricingVersion', v_pricing_version,
      'productKey', p_product_key,
      'productName', v_product_name,
      'pricingStrategy', v_strategy,
      'configuration', p_configuration,
      'pricingDefinition', v_pricing,
      'calculation', jsonb_build_object(
        'lines', v_lines,
        'metrics', v_metrics,
        'total', v_total
      ),
      'capturedAt', now()
    )
  );
end
$$;

revoke all on function commerce.qs_generate_order_number() from public, anon, authenticated;
revoke all on function commerce.qs_calculate_price(uuid,text,jsonb) from public, anon, authenticated;

create or replace function public.get_quick_solution_catalog(
  p_tenant_slug text default 'quick-solution'
)
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
      select jsonb_build_object('id',t.id,'slug',t.slug,'name',t.name)
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
          'latitude', fp.latitude,
          'longitude', fp.longitude,
          'collectionEnabled', fp.collection_enabled,
          'dropoffEnabled', fp.dropoff_enabled,
          'services', fp.services,
          'feeAmount', fp.fee_amount,
          'openingHours', fp.opening_hours
        )
        order by fp.sort_order, fp.name
      )
      from commerce.fulfilment_points fp
      where fp.tenant_id = v_tenant_id
        and fp.status = 'active'
    ), '[]'::jsonb)
  );
end
$$;

grant execute on function public.get_quick_solution_catalog(text) to anon, authenticated;

create or replace function public.create_quick_solution_order(
  p_tenant_slug text,
  p_product_key text,
  p_configuration jsonb,
  p_customer_name text,
  p_customer_email text default null,
  p_customer_phone text default null,
  p_fulfilment_type text default 'cafe',
  p_fulfilment_point_id uuid default null,
  p_delivery_address jsonb default null,
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
  v_existing commerce.service_orders;
  v_order_number text;
  v_price jsonb;
  v_product_id uuid;
  v_product_name text;
  v_subtotal numeric;
  v_fulfilment_fee numeric := 0;
  v_total numeric;
  v_fulfilment_type text;
  v_point commerce.fulfilment_points;
  v_email text;
  v_phone text;
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

  if length(trim(coalesce(p_idempotency_key,''))) < 8 then
    raise exception using errcode = '22023', message = 'Order idempotency key is required.';
  end if;

  if length(trim(coalesce(p_customer_name,''))) < 2 then
    raise exception using errcode = '22023', message = 'Customer name is required.';
  end if;

  v_email := nullif(lower(trim(coalesce(p_customer_email,''))), '');
  v_phone := nullif(trim(coalesce(p_customer_phone,'')), '');

  if v_email is null and v_phone is null then
    raise exception using errcode = '22023', message = 'Provide an email address or phone number.';
  end if;

  if v_email is not null and position('@' in v_email) < 2 then
    raise exception using errcode = '22023', message = 'Email address is not valid.';
  end if;

  if v_phone is not null and length(regexp_replace(v_phone, '[^0-9+]', '', 'g')) < 7 then
    raise exception using errcode = '22023', message = 'Phone number is not valid.';
  end if;

  select *
  into v_existing
  from commerce.service_orders so
  where so.tenant_id = v_tenant_id
    and so.idempotency_key = trim(p_idempotency_key)
  limit 1;

  if v_existing.id is not null then
    return jsonb_build_object(
      'ok', true,
      'replayed', true,
      'orderId', v_existing.id,
      'orderNumber', v_existing.order_number,
      'subtotal', v_existing.subtotal,
      'fulfilmentFee', v_existing.fulfilment_fee,
      'totalAmount', v_existing.total_amount,
      'status', v_existing.status
    );
  end if;

  v_price := commerce.qs_calculate_price(v_tenant_id, trim(p_product_key), p_configuration);
  v_product_id := (v_price->>'productId')::uuid;
  v_product_name := v_price->>'productName';
  v_subtotal := (v_price->>'total')::numeric;

  v_fulfilment_type := lower(trim(coalesce(p_fulfilment_type,'cafe')));

  if v_fulfilment_type in ('cafe','quick_point') then
    if p_fulfilment_point_id is null then
      if v_fulfilment_type = 'quick_point' then
        raise exception using errcode = '22023', message = 'Choose a Quick Point.';
      end if;

      select *
      into v_point
      from commerce.fulfilment_points fp
      where fp.tenant_id = v_tenant_id
        and fp.kind = 'cafe'
        and fp.status = 'active'
        and fp.collection_enabled = true
      order by fp.sort_order, fp.created_at
      limit 1;
    else
      select *
      into v_point
      from commerce.fulfilment_points fp
      where fp.id = p_fulfilment_point_id
        and fp.tenant_id = v_tenant_id
        and fp.kind = v_fulfilment_type
        and fp.status = 'active'
        and fp.collection_enabled = true
      limit 1;
    end if;

    if v_point.id is null then
      raise exception using errcode = '22023', message = 'Selected collection point is not available.';
    end if;

    v_fulfilment_fee := coalesce(v_point.fee_amount,0);

  elsif v_fulfilment_type = 'delivery' then
    if p_delivery_address is null or jsonb_typeof(p_delivery_address) is distinct from 'object' then
      raise exception using errcode = '22023', message = 'Delivery address is required.';
    end if;
    -- Delivery pricing is intentionally not guessed in QS-03.
    -- The order is persisted at the product total and delivery is confirmed before payment.
    v_fulfilment_fee := 0;
  else
    raise exception using errcode = '22023', message = 'Unsupported fulfilment type.';
  end if;

  v_total := round(v_subtotal + v_fulfilment_fee, 2);
  v_order_number := commerce.qs_generate_order_number();

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
    source_metadata
  ) values (
    v_tenant_id,
    v_order_number,
    'submitted',
    trim(p_customer_name),
    v_email,
    v_phone,
    v_fulfilment_type,
    case when v_fulfilment_type in ('cafe','quick_point') then v_point.id else null end,
    case when v_fulfilment_type='delivery' then p_delivery_address else null end,
    v_subtotal,
    v_fulfilment_fee,
    v_total,
    'unpaid',
    trim(p_idempotency_key),
    nullif(trim(coalesce(p_customer_notes,'')), ''),
    jsonb_build_object(
      'channel','storefront',
      'deliveryFeeStatus', case when v_fulfilment_type='delivery' then 'pending_confirmation' else 'not_required' end
    )
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
    v_subtotal
  );

  return jsonb_build_object(
    'ok', true,
    'replayed', false,
    'orderId', v_order_id,
    'orderNumber', v_order_number,
    'subtotal', v_subtotal,
    'fulfilmentFee', v_fulfilment_fee,
    'totalAmount', v_total,
    'status', 'submitted',
    'deliveryFeeStatus', case when v_fulfilment_type='delivery' then 'pending_confirmation' else 'not_required' end
  );
end
$$;

grant execute on function public.create_quick_solution_order(
  text,text,jsonb,text,text,text,text,uuid,jsonb,text,text
) to anon, authenticated;

comment on table commerce.service_product_configs is
  'Quick Solution/XOS configurable service products. customer_definition drives storefront UX; pricing_definition is the canonical server-side price rule set.';

comment on table commerce.service_orders is
  'Quick Solution storefront order intake. Orders remain here until the explicit OPPS handoff phase.';

comment on column commerce.service_order_items.pricing_snapshot is
  'Immutable copy of the pricing version, rules, configuration and calculation used when the order was submitted.';
