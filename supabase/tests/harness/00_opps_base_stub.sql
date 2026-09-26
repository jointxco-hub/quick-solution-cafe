-- DB-HARNESS-01: the OPPS-owned base layer the Quick Solution Cafe migrations
-- are written against, for a DISPOSABLE LOCAL PostgreSQL only.
--
-- This project's migrations sit on top of objects that another repository
-- (OPPS) owns in the shared Supabase project: the tenants/membership tables,
-- the staff-authority helpers, commerce.products, the Supabase roles and the
-- auth schema. Those cannot be replayed from this repository, so this file
-- reproduces ONLY what the Cafe migrations and SQL tests need, as faithfully
-- as the OPPS sources allow:
--
--   * public.current_user_app_role / is_app_admin / is_opps_staff /
--     current_user_tenant_ids / can_access_tenant are the LATEST OPPS
--     definitions, copied verbatim (source file noted on each). The Cafe admin
--     gate therefore runs against the real helper bodies, not a stand-in.
--   * public.tenants and commerce.products keep the OPPS columns and CHECK
--     constraints the Cafe code touches (source noted).
--   * auth.uid()/email()/role()/jwt() follow Supabase's own definitions: they
--     read the request.jwt.claims setting, exactly like PostgREST sets it.
--   * roles anon / authenticated / service_role, the `extensions` schema
--     (pgcrypto lives there, as on Supabase) and Supabase's default
--     privileges for objects the postgres role creates in `public`.
--
-- What this is NOT: a copy of the live database. Anything the OPPS side has
-- added since these sources, or any live drift, is invisible here (a separate,
-- explicitly authorized slice would be needed to inspect the live schema).
-- The stubbed tables carry only the columns Cafe code uses.
--
-- Never run this against anything but the throwaway cluster the runner creates.

\set ON_ERROR_STOP on

-- Guard: refuse to run unless the runner marked this database as disposable.
do $guard$
begin
  if current_setting('harness.disposable', true) is distinct from 'yes' then
    raise exception 'DB-HARNESS-01: refusing to load the base stub - this connection is not marked disposable (set harness.disposable=yes via the runner)';
  end if;
end
$guard$;

-- ── roles (Supabase names; nologin like the platform's) ───────────────────
do $roles$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin noinherit bypassrls; end if;
end
$roles$;

-- ── schemas / extensions ──────────────────────────────────────────────────
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;
create schema if not exists auth;
create schema if not exists commerce;

grant usage on schema public, extensions to anon, authenticated, service_role;
grant usage on schema auth to anon, authenticated, service_role;

-- Supabase default privileges for objects the postgres role creates in public.
alter default privileges for role postgres in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges for role postgres in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges for role postgres in schema public grant all on sequences to anon, authenticated, service_role;

-- ── auth (Supabase definitions) ───────────────────────────────────────────
-- The columns Supabase's auth.users has that fixtures in this repo (and the OPPS
-- access tests) populate; the real table has more.
create table auth.users (
  id uuid primary key default gen_random_uuid(),
  aud text,
  role text,
  email text unique,
  email_confirmed_at timestamptz,
  raw_app_meta_data jsonb not null default '{}'::jsonb,
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function auth.uid() returns uuid language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;

create or replace function auth.role() returns text language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )::text
$$;

create or replace function auth.email() returns text language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.email', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email')
  )::text
$$;

create or replace function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')
  )::jsonb
$$;

grant execute on function auth.uid(), auth.role(), auth.email(), auth.jwt() to anon, authenticated, service_role;

-- ── OPPS-owned tables (columns Cafe code uses) ────────────────────────────
-- public.handle_updated_at: the standard trigger the Cafe foundation attaches.
create or replace function public.handle_updated_at() returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end
$$;

-- Source: OPPS 202606200001_multi_tenant_foundation.sql
create table public.tenants (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  status text not null default 'active' check (status in ('active', 'suspended', 'archived')),
  settings jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.tenant_memberships (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  auth_user_id uuid not null references auth.users(id) on delete cascade,
  tenant_role text not null default 'member' check (tenant_role in ('owner', 'admin', 'member')),
  status text not null default 'active' check (status in ('active', 'suspended')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, auth_user_id)
);

-- The columns the OPPS staff helpers read; the real table has many more.
create table public.users (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid unique references auth.users(id) on delete cascade,
  user_email text,
  full_name text,
  role text,
  is_active boolean not null default true
);

-- Cafe capability flag table (columns used by the Cafe seed/migrations).
create table public.tenant_capabilities (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  capability_key text not null,
  enabled boolean not null default true,
  config jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, capability_key)
);

-- Source: OPPS 20260823111500_xos_3a_products_foundation.sql
create table commerce.products (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  slug text not null,
  name text not null,
  description text,
  price numeric,
  sale_price numeric,
  currency text not null default 'ZAR',
  primary_image_url text,
  availability text not null default 'available',
  status text not null default 'draft',
  source_system text,
  source_ref text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint commerce_products_status_check check (status in ('draft', 'published', 'archived')),
  constraint commerce_products_availability_check check (availability in ('available', 'out_of_stock', 'preorder', 'unavailable')),
  constraint commerce_products_price_nonneg check (price is null or price >= 0),
  constraint commerce_products_sale_price_nonneg check (sale_price is null or sale_price >= 0),
  constraint commerce_products_sale_price_le_price check (sale_price is null or price is null or sale_price <= price),
  constraint commerce_products_slug_format check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  constraint commerce_products_tenant_slug_unique unique (tenant_id, slug)
);

-- OPPS orders: the Cafe handoff migrations (qs_04a onwards) alter the source
-- constraint on it and reference public.orders(id). Only the columns the Cafe
-- DDL touches are present; the real table is far wider.
create table public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number text,
  source text not null default 'opps'
);

-- ── OPPS staff-authority helpers, verbatim, latest OPPS definitions ───────
-- Source: OPPS 20260523_finance_rls_tighten.sql (body) +
--         20260817173001_xos_opps_staff_authority.sql (search_path, ACL)
create or replace function public.current_user_app_role()
returns text
language sql
security definer
stable
set search_path = pg_catalog, public
as $$
  select role
  from public.users
  where auth_user_id = auth.uid()
  limit 1;
$$;
revoke all on function public.current_user_app_role() from public, anon;
grant execute on function public.current_user_app_role() to authenticated, service_role;

-- Source: OPPS 20260824090200_app_admin_null_safety_and_phase2_regrant.sql
create or replace function public.is_app_admin()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select coalesce(public.current_user_app_role() = 'admin', false)
    or lower(coalesce(auth.jwt() ->> 'email', '')) in (
      'jointx.co@gmail.com', 'jointsexclusive@gmail.com',
      'jasperjaimataruse@gmail.com', 'jaicreativerealm@gmail.com'
    );
$$;
revoke all on function public.is_app_admin() from public, anon;
grant execute on function public.is_app_admin() to authenticated, service_role;

-- Source: OPPS 202606200001_multi_tenant_foundation.sql (bodies) +
--         20260817173001_xos_opps_staff_authority.sql (search_path, ACL)
create or replace function public.current_user_tenant_ids()
returns setof uuid
language sql
security definer
stable
set search_path = pg_catalog, public
as $$
  select membership.tenant_id
  from public.tenant_memberships membership
  where membership.auth_user_id = auth.uid()
    and membership.status = 'active';
$$;
revoke all on function public.current_user_tenant_ids() from public, anon;
grant execute on function public.current_user_tenant_ids() to authenticated, service_role;

create or replace function public.can_access_tenant(p_tenant_id uuid)
returns boolean
language sql
security definer
stable
set search_path = pg_catalog, public
as $$
  select exists (
    select 1
    from public.current_user_tenant_ids() as membership_tenant(tenant_id)
    where membership_tenant.tenant_id = p_tenant_id
  );
$$;
revoke all on function public.can_access_tenant(uuid) from public, anon;
grant execute on function public.can_access_tenant(uuid) to authenticated, service_role;

-- Source: OPPS 20260817173001_xos_opps_staff_authority.sql
create or replace function public.is_opps_staff()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select coalesce(exists (
    select 1
    from public.users u
    join public.tenant_memberships membership
      on membership.auth_user_id = u.auth_user_id
     and membership.status = 'active'
    join public.tenants tenant
      on tenant.id = membership.tenant_id
     and tenant.status = 'active'
     and tenant.slug = 'joint-x'
    where u.auth_user_id = auth.uid()
      and coalesce(u.is_active, true)
  ), false)
$$;
revoke all on function public.is_opps_staff() from public, anon, authenticated, service_role;
grant execute on function public.is_opps_staff() to authenticated, service_role;

-- ── real OPPS triggers on public.users, verbatim ──────────────────────────
-- Source: OPPS 202606230005_admin_role_guard.sql. Only approved owners may assign or
-- change administrator access (the approved-owner emails are read from the JWT).
create or replace function public.enforce_approved_admin_role_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  requester_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  approved boolean := requester_email in (
    'jointx.co@gmail.com',
    'jointsexclusive@gmail.com',
    'jasperjaimataruse@gmail.com',
    'jaicreativerealm@gmail.com'
  );
begin
  if tg_op = 'INSERT' and new.role = 'admin' and not approved then
    raise exception 'Only approved owners can assign administrator access.';
  end if;
  if tg_op = 'UPDATE' and new.role is distinct from old.role
    and (new.role = 'admin' or old.role = 'admin') and not approved then
    raise exception 'Only approved owners can change administrator access.';
  end if;
  return new;
end;
$$;

create trigger trg_users_enforce_admin_role_change
  before insert or update of role on public.users
  for each row execute function public.enforce_approved_admin_role_change();

-- Source: OPPS 202606230006_fix_internal_order_access.sql. Every active internal user
-- is given an active membership (admin for role admin, else member) in the joint-x team.
create or replace function public.add_internal_user_to_joint_x_team()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.auth_user_id is not null and coalesce(new.is_active, true) then
    insert into public.tenant_memberships (tenant_id, auth_user_id, tenant_role, status)
    select id, new.auth_user_id, case when new.role = 'admin' then 'admin' else 'member' end, 'active'
    from public.tenants where slug = 'joint-x'
    on conflict (tenant_id, auth_user_id) do update set status = 'active';
  end if;
  return new;
end;
$$;

create trigger trg_internal_user_joint_x_membership
  after insert or update of auth_user_id, is_active, role on public.users
  for each row execute function public.add_internal_user_to_joint_x_team();

-- The OPPS staff tenant every Cafe staff path is authorized against.
insert into public.tenants (slug, name) values ('joint-x', 'Joint X');
