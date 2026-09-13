-- QS-06: verified Easy Locate <-> Quick Point linking.
-- XOS owns fulfilment settings. Easy Locate remains the source of business identity.

create table if not exists commerce.fulfilment_point_external_links (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  fulfilment_point_id uuid not null references commerce.fulfilment_points(id) on delete cascade,
  provider text not null check (provider in ('easy_locate')),
  external_id text not null,
  external_slug text not null,
  canonical_url text not null,
  status text not null default 'verified' check (status in ('verified','stale')),
  public_snapshot jsonb not null default '{}'::jsonb,
  source_updated_at timestamptz,
  verified_at timestamptz not null default now(),
  verified_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (fulfilment_point_id, provider),
  unique (provider, external_id)
);

create index if not exists idx_fulfilment_external_links_tenant
  on commerce.fulfilment_point_external_links(tenant_id, provider, status);

alter table commerce.fulfilment_point_external_links enable row level security;
revoke all on commerce.fulfilment_point_external_links from anon, authenticated;

do $$
begin
  if not exists (
    select 1 from pg_trigger
    where tgname='trg_fulfilment_point_external_links_updated_at'
      and tgrelid='commerce.fulfilment_point_external_links'::regclass
  ) then
    create trigger trg_fulfilment_point_external_links_updated_at
    before update on commerce.fulfilment_point_external_links
    for each row execute function public.handle_updated_at();
  end if;
end
$$;

comment on table commerce.fulfilment_point_external_links is
  'Verified external identity links for Quick Solution fulfilment points. Provider data is a safe public snapshot only; operational settings stay in XOS.';

create or replace function public.qs_internal_apply_verified_external_link(
  p_tenant_id uuid,
  p_fulfilment_point_id uuid,
  p_provider text,
  p_external_id text,
  p_external_slug text,
  p_canonical_url text,
  p_public_snapshot jsonb,
  p_source_updated_at timestamptz default null,
  p_verified_by uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_provider text;
  v_external_id text;
  v_external_slug text;
  v_url text;
  v_link commerce.fulfilment_point_external_links;
begin
  if coalesce(auth.role(),'') <> 'service_role'
     and session_user not in ('postgres','supabase_admin') then
    raise exception using errcode='42501', message='Trusted backend access is required.';
  end if;

  if not exists (
    select 1 from commerce.fulfilment_points fp
    where fp.id=p_fulfilment_point_id and fp.tenant_id=p_tenant_id
  ) then
    raise exception using errcode='22023', message='Quick Solution fulfilment point was not found.';
  end if;

  v_provider := lower(trim(coalesce(p_provider,'')));
  if v_provider <> 'easy_locate' then
    raise exception using errcode='22023', message='Unsupported external provider.';
  end if;

  v_external_id := left(trim(coalesce(p_external_id,'')),240);
  v_external_slug := left(trim(coalesce(p_external_slug,'')),240);
  v_url := left(trim(coalesce(p_canonical_url,'')),800);

  if length(v_external_id) < 1 or length(v_external_slug) < 1 then
    raise exception using errcode='22023', message='Verified Easy Locate identity is incomplete.';
  end if;

  if v_url !~ '^https://easy-locate\.vercel\.app(/|$)' then
    raise exception using errcode='22023', message='Easy Locate canonical URL is not trusted.';
  end if;

  if p_public_snapshot is null or jsonb_typeof(p_public_snapshot) is distinct from 'object' then
    raise exception using errcode='22023', message='Verified Easy Locate snapshot is required.';
  end if;

  insert into commerce.fulfilment_point_external_links (
    tenant_id, fulfilment_point_id, provider, external_id, external_slug,
    canonical_url, status, public_snapshot, source_updated_at,
    verified_at, verified_by
  ) values (
    p_tenant_id, p_fulfilment_point_id, v_provider, v_external_id, v_external_slug,
    v_url, 'verified', p_public_snapshot, p_source_updated_at,
    now(), p_verified_by
  )
  on conflict (fulfilment_point_id, provider) do update
  set external_id=excluded.external_id,
      external_slug=excluded.external_slug,
      canonical_url=excluded.canonical_url,
      status='verified',
      public_snapshot=excluded.public_snapshot,
      source_updated_at=excluded.source_updated_at,
      verified_at=now(),
      verified_by=excluded.verified_by
  returning * into v_link;

  update commerce.fulfilment_points fp
  set easy_locate_business_ref=v_external_id,
      updated_at=now()
  where fp.id=p_fulfilment_point_id and fp.tenant_id=p_tenant_id;

  return jsonb_build_object(
    'ok',true,
    'link',jsonb_build_object(
      'id',v_link.id,
      'provider',v_link.provider,
      'externalId',v_link.external_id,
      'externalSlug',v_link.external_slug,
      'canonicalUrl',v_link.canonical_url,
      'status',v_link.status,
      'business',v_link.public_snapshot,
      'sourceUpdatedAt',v_link.source_updated_at,
      'verifiedAt',v_link.verified_at
    )
  );
end
$$;

revoke all on function public.qs_internal_apply_verified_external_link(uuid,uuid,text,text,text,text,jsonb,timestamptz,uuid) from public, anon, authenticated;
grant execute on function public.qs_internal_apply_verified_external_link(uuid,uuid,text,text,text,text,jsonb,timestamptz,uuid) to service_role;

create or replace function public.qs_internal_unlink_external_link(
  p_tenant_id uuid,
  p_fulfilment_point_id uuid,
  p_provider text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_provider text;
  v_deleted integer := 0;
begin
  if coalesce(auth.role(),'') <> 'service_role'
     and session_user not in ('postgres','supabase_admin') then
    raise exception using errcode='42501', message='Trusted backend access is required.';
  end if;

  v_provider := lower(trim(coalesce(p_provider,'')));
  if v_provider <> 'easy_locate' then
    raise exception using errcode='22023', message='Unsupported external provider.';
  end if;

  if not exists (
    select 1 from commerce.fulfilment_points fp
    where fp.id=p_fulfilment_point_id and fp.tenant_id=p_tenant_id
  ) then
    raise exception using errcode='22023', message='Quick Solution fulfilment point was not found.';
  end if;

  delete from commerce.fulfilment_point_external_links l
  where l.tenant_id=p_tenant_id
    and l.fulfilment_point_id=p_fulfilment_point_id
    and l.provider=v_provider;
  get diagnostics v_deleted = row_count;

  update commerce.fulfilment_points fp
  set easy_locate_business_ref=null,
      updated_at=now()
  where fp.id=p_fulfilment_point_id and fp.tenant_id=p_tenant_id;

  return jsonb_build_object('ok',true,'unlinked',v_deleted > 0);
end
$$;

revoke all on function public.qs_internal_unlink_external_link(uuid,uuid,text) from public, anon, authenticated;
grant execute on function public.qs_internal_unlink_external_link(uuid,uuid,text) to service_role;

create or replace function public.admin_get_quick_solution_fulfilment_points(
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
  if auth.uid() is null then
    raise exception using errcode='42501', message='Staff sign-in is required.';
  end if;

  select t.id into v_tenant_id
  from public.tenants t
  where t.slug=lower(trim(p_tenant_slug)) and t.status='active'
  limit 1;

  if v_tenant_id is null then
    raise exception using errcode='22023', message='Quick Solution tenant was not found.';
  end if;

  if not public.is_app_admin()
     and not (public.is_opps_staff() and public.can_access_tenant(v_tenant_id)) then
    raise exception using errcode='42501', message='You do not have access to Quick Solution fulfilment points.';
  end if;

  return jsonb_build_object(
    'tenantId', v_tenant_id,
    'points', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', fp.id,
          'slug', fp.slug,
          'name', fp.name,
          'kind', fp.kind,
          'status', fp.status,
          'address', fp.address,
          'contactPhone', fp.contact_phone,
          'contactEmail', fp.contact_email,
          'easyLocateBusinessRef', fp.easy_locate_business_ref,
          'easyLocateLink', case when el.id is null then null else jsonb_build_object(
            'id', el.id,
            'provider', el.provider,
            'externalId', el.external_id,
            'externalSlug', el.external_slug,
            'canonicalUrl', el.canonical_url,
            'status', el.status,
            'business', el.public_snapshot,
            'sourceUpdatedAt', el.source_updated_at,
            'verifiedAt', el.verified_at
          ) end,
          'latitude', fp.latitude,
          'longitude', fp.longitude,
          'collectionEnabled', fp.collection_enabled,
          'dropoffEnabled', fp.dropoff_enabled,
          'services', fp.services,
          'feeAmount', fp.fee_amount,
          'openingHours', fp.opening_hours,
          'sortOrder', fp.sort_order,
          'createdAt', fp.created_at,
          'updatedAt', fp.updated_at,
          'orderCount', (
            select count(*) from commerce.service_orders so where so.fulfilment_point_id=fp.id
          )
        )
        order by case fp.kind when 'cafe' then 0 else 1 end, fp.sort_order, fp.name
      )
      from commerce.fulfilment_points fp
      left join commerce.fulfilment_point_external_links el
        on el.fulfilment_point_id=fp.id
       and el.tenant_id=fp.tenant_id
       and el.provider='easy_locate'
      where fp.tenant_id=v_tenant_id
    ), '[]'::jsonb)
  );
end
$$;

revoke all on function public.admin_get_quick_solution_fulfilment_points(text) from public, anon, authenticated;
grant execute on function public.admin_get_quick_solution_fulfilment_points(text) to authenticated;
