-- CAFE-GUEST-01A: contract test for commerce.service_orders channel/created_by.
--
-- Run only against an isolated database that has the real Quick Solution
-- effective schema (including commerce.service_orders and public.tenants)
-- after applying 20260926100000_cafe_guest_01a_counter_channel_foundation.sql.
-- Executed by the disposable local harness (supabase/tests/harness/run-local-sql-tests.ps1),
-- which replays the migration history onto the OPPS-owned base layer. The static
-- counterpart is tests/cafe-guest-01a-counter-channel.test.mjs.
--
-- All fixtures are synthetic and enclosed by BEGIN/ROLLBACK.

\set ON_ERROR_STOP on

begin;

do $catalog$
declare
  v_channel record;
  v_created_by record;
  v_def text;
  v_values text[];
begin
  select c.data_type, c.is_nullable, c.column_default
    into v_channel
  from information_schema.columns c
  where c.table_schema='commerce'
    and c.table_name='service_orders'
    and c.column_name='channel';
  if v_channel.data_type is null then
    raise exception 'commerce.service_orders.channel must exist';
  end if;
  if v_channel.data_type <> 'text' then
    raise exception 'channel must be text (repository convention: text + CHECK), got %',v_channel.data_type;
  end if;
  if v_channel.is_nullable <> 'NO' then
    raise exception 'channel must be NOT NULL';
  end if;
  if v_channel.column_default is null or v_channel.column_default not like '''storefront''%' then
    raise exception 'channel must default to storefront, got %',v_channel.column_default;
  end if;

  select c.data_type, c.is_nullable, c.column_default
    into v_created_by
  from information_schema.columns c
  where c.table_schema='commerce'
    and c.table_name='service_orders'
    and c.column_name='created_by';
  if v_created_by.data_type is null then
    raise exception 'commerce.service_orders.created_by must exist';
  end if;
  if v_created_by.data_type <> 'uuid' then
    raise exception 'created_by must be uuid, got %',v_created_by.data_type;
  end if;
  if v_created_by.is_nullable <> 'YES' then
    raise exception 'created_by must be nullable';
  end if;
  if v_created_by.column_default is not null then
    raise exception 'created_by must have no default, got %',v_created_by.column_default;
  end if;

  select pg_get_constraintdef(k.oid) into v_def
  from pg_constraint k
  where k.conrelid='commerce.service_orders'::regclass
    and k.conname='service_orders_channel_check'
    and k.contype='c';
  if v_def is null then
    raise exception 'service_orders_channel_check must exist';
  end if;
  select array_agg(m[1] order by m[1])
    into v_values
  from regexp_matches(v_def,'''([a-z_]+)''','g') as m;
  if v_values is distinct from array['counter','storefront'] then
    raise exception 'channel check must allow exactly storefront and counter, got %',v_def;
  end if;

  if exists (
    select 1
    from pg_constraint k
    join pg_attribute a
      on a.attrelid=k.conrelid
     and a.attnum = any (k.conkey)
    where k.conrelid='commerce.service_orders'::regclass
      and k.contype='f'
      and a.attname='created_by'
  ) then
    raise exception 'created_by must not carry a foreign key (matches last_previewed_by/verified_by convention)';
  end if;

  if (
    select c.is_nullable
    from information_schema.columns c
    where c.table_schema='commerce'
      and c.table_name='service_orders'
      and c.column_name='customer_name'
  ) <> 'NO' then
    raise exception 'customer_name must remain NOT NULL';
  end if;
end
$catalog$;

do $behavior$
declare
  v_tenant uuid := gen_random_uuid();
  v_suffix text := replace(gen_random_uuid()::text,'-','');
  v_staff uuid := gen_random_uuid();
  v_order uuid;
  v_channel text;
  v_created_by uuid;
  v_provenance text;
begin
  insert into public.tenants(id,slug,name,status,settings)
  values (v_tenant,'cafe-guest-01a-'||left(v_suffix,12),'CAFE GUEST 01A synthetic','active','{}'::jsonb);

  -- Existing storefront insert shape: the column list used by the latest
  -- create_quick_solution_cart_order, without channel or created_by.
  insert into commerce.service_orders (
    tenant_id, order_number, status, customer_name, customer_email, customer_phone,
    fulfilment_type, fulfilment_point_id, delivery_address, subtotal, fulfilment_fee,
    total_amount, payment_status, idempotency_key, customer_notes, source_metadata
  ) values (
    v_tenant, 'CG01A-S-'||left(v_suffix,10), 'submitted', 'CAFE GUEST 01A storefront', 'sf@disposable.test', null,
    'cafe', null, null, 10, 0,
    10, 'unpaid', 'cafe-guest-01a-'||v_suffix||'-s', null,
    jsonb_build_object('channel','storefront_cart','itemCount',1)
  ) returning id into v_order;

  select channel, created_by, source_metadata->>'channel'
    into v_channel, v_created_by, v_provenance
  from commerce.service_orders where id=v_order;
  if v_channel is distinct from 'storefront' then
    raise exception 'omitted channel must resolve to storefront, got %',v_channel;
  end if;
  if v_created_by is not null then
    raise exception 'omitted created_by must resolve to NULL, got %',v_created_by;
  end if;
  if v_provenance is distinct from 'storefront_cart' then
    raise exception 'source_metadata provenance must be preserved, got %',v_provenance;
  end if;

  -- An anonymous counter job: a real staff-style uuid that is NOT an
  -- auth.users row must be accepted (no foreign key), Walk-in name, no contact.
  insert into commerce.service_orders (
    tenant_id, order_number, status, customer_name, customer_email, customer_phone,
    fulfilment_type, total_amount, payment_status, idempotency_key, source_metadata,
    channel, created_by
  ) values (
    v_tenant, 'CG01A-C-'||left(v_suffix,10), 'submitted', 'Walk-in', null, null,
    'service', 25, 'unpaid', 'cafe-guest-01a-'||v_suffix||'-c', '{}'::jsonb,
    'counter', v_staff
  ) returning id into v_order;

  select channel, created_by into v_channel, v_created_by
  from commerce.service_orders where id=v_order;
  if v_channel is distinct from 'counter' or v_created_by is distinct from v_staff then
    raise exception 'counter job must keep channel=counter and its created_by, got %/%',v_channel,v_created_by;
  end if;

  -- Invalid channel is rejected by the check constraint.
  begin
    insert into commerce.service_orders (
      tenant_id, order_number, customer_name, idempotency_key, channel
    ) values (
      v_tenant, 'CG01A-X-'||left(v_suffix,10), 'CAFE GUEST 01A invalid',
      'cafe-guest-01a-'||v_suffix||'-x', 'kiosk'
    );
    raise exception 'invalid channel was accepted';
  exception when check_violation then
    null;
  end;

  -- An explicit NULL channel is rejected (the default only covers omission).
  begin
    insert into commerce.service_orders (
      tenant_id, order_number, customer_name, idempotency_key, channel
    ) values (
      v_tenant, 'CG01A-N-'||left(v_suffix,10), 'CAFE GUEST 01A null channel',
      'cafe-guest-01a-'||v_suffix||'-n', null
    );
    raise exception 'NULL channel was accepted';
  exception when not_null_violation then
    null;
  end;

  -- customer_name keeps its NOT NULL contract.
  begin
    insert into commerce.service_orders (
      tenant_id, order_number, customer_name, idempotency_key
    ) values (
      v_tenant, 'CG01A-M-'||left(v_suffix,10), null,
      'cafe-guest-01a-'||v_suffix||'-m'
    );
    raise exception 'NULL customer_name was accepted';
  exception when not_null_violation then
    null;
  end;
end
$behavior$;

rollback;

select 'CAFE-GUEST-01A counter channel foundation contracts passed' as result;
