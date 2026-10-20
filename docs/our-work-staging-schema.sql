-- Our Work: staging-first schema proposal. Review tenant membership policy before execution.
-- All write operations require a current authenticated tenant member with admin/owner role.
create table if not exists public.qs_portfolio_projects (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  slug text not null check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  title text not null check (length(trim(title)) between 1 and 160),
  summary text not null default '',
  description text not null default '',
  category_slugs text[] not null default '{}',
  product_keys text[] not null default '{}',
  status text not null default 'draft' check (status in ('draft','published')),
  featured boolean not null default false,
  media jsonb not null default '[]'::jsonb check (jsonb_typeof(media) = 'array'),
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(tenant_id, slug)
);
create index if not exists qs_portfolio_tenant_status_idx on public.qs_portfolio_projects(tenant_id,status,published_at desc);
alter table public.qs_portfolio_projects enable row level security;
revoke all on public.qs_portfolio_projects from public, anon, authenticated;
grant select on public.qs_portfolio_projects to anon, authenticated;
grant insert, update on public.qs_portfolio_projects to authenticated;

-- Public reads contain only intentionally published projects.
create policy qs_portfolio_public_read on public.qs_portfolio_projects
  for select to anon, authenticated using (status = 'published');

-- Staff may read drafts only for their tenant.
create policy qs_portfolio_staff_read on public.qs_portfolio_projects
  for select to authenticated using (
    exists (select 1 from public.tenant_memberships m
      where m.tenant_id = qs_portfolio_projects.tenant_id
        and m.auth_user_id = (select auth.uid())
        and m.status = 'active'
        and m.tenant_role in ('owner','admin'))
  );
create policy qs_portfolio_staff_insert on public.qs_portfolio_projects
  for insert to authenticated with check (
    exists (select 1 from public.tenant_memberships m
      where m.tenant_id = qs_portfolio_projects.tenant_id
        and m.auth_user_id = (select auth.uid())
        and m.status = 'active'
        and m.tenant_role in ('owner','admin'))
  );
create policy qs_portfolio_staff_update on public.qs_portfolio_projects
  for update to authenticated
  using (exists (select 1 from public.tenant_memberships m
      where m.tenant_id = qs_portfolio_projects.tenant_id
        and m.auth_user_id = (select auth.uid())
        and m.status = 'active'
        and m.tenant_role in ('owner','admin')))
  with check (exists (select 1 from public.tenant_memberships m
      where m.tenant_id = qs_portfolio_projects.tenant_id
        and m.auth_user_id = (select auth.uid())
        and m.status = 'active'
        and m.tenant_role in ('owner','admin')));

-- Public function only returns published content and never staff-only records.
create or replace function public.get_quick_solution_portfolio(p_tenant_slug text)
returns jsonb language sql stable security invoker set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',p.id,'slug',p.slug,'title',p.title,'summary',p.summary,
    'description',p.description,'categorySlugs',p.category_slugs,
    'productKeys',p.product_keys,'status',p.status,'featured',p.featured,
    'publishedAt',p.published_at,'media',p.media,
    'coverUrl',p.media->0->>'url','coverAlt',p.media->0->>'altText'
  ) order by p.featured desc,p.published_at desc), '[]'::jsonb)
  from public.qs_portfolio_projects p
  join public.tenants t on t.id=p.tenant_id
  where t.slug=p_tenant_slug and p.status='published';
$$;
revoke all on function public.get_quick_solution_portfolio(text) from public;
grant execute on function public.get_quick_solution_portfolio(text) to anon,authenticated;

create or replace function public.admin_get_quick_solution_portfolio(p_tenant_slug text)
returns jsonb language sql stable security invoker set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',p.id,'slug',p.slug,'title',p.title,'summary',p.summary,
    'description',p.description,'categorySlugs',p.category_slugs,
    'productKeys',p.product_keys,'status',p.status,'featured',p.featured,
    'publishedAt',p.published_at,'media',p.media
  ) order by p.updated_at desc), '[]'::jsonb)
  from public.qs_portfolio_projects p
  join public.tenants t on t.id=p.tenant_id
  where t.slug=p_tenant_slug and exists (
    select 1 from public.tenant_memberships m
    where m.tenant_id=p.tenant_id and m.auth_user_id=auth.uid()
      and m.status='active' and m.tenant_role in ('owner','admin'));
$$;
revoke all on function public.admin_get_quick_solution_portfolio(text) from public;
grant execute on function public.admin_get_quick_solution_portfolio(text) to authenticated;

create or replace function public.admin_save_quick_solution_portfolio_project(p_tenant_slug text,p_project jsonb)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_tenant uuid; v_row public.qs_portfolio_projects;
begin
  select t.id into v_tenant from public.tenants t where t.slug=p_tenant_slug;
  if v_tenant is null or not exists (
    select 1 from public.tenant_memberships m
    where m.tenant_id=v_tenant and m.auth_user_id=auth.uid()
      and m.status='active' and m.tenant_role in ('owner','admin')
  ) then raise exception 'Not authorized for portfolio administration' using errcode='42501'; end if;
  if p_project ? 'id' and nullif(p_project->>'id','') is not null then
    update public.qs_portfolio_projects p set
      title=p_project->>'title',slug=p_project->>'slug',
      summary=coalesce(p_project->>'summary',''),description=coalesce(p_project->>'description',''),
      category_slugs=coalesce(array(select jsonb_array_elements_text(p_project->'categorySlugs')),'{}'),
      product_keys=coalesce(array(select jsonb_array_elements_text(p_project->'productKeys')),'{}'),
      status=coalesce(p_project->>'status','draft'),
      featured=coalesce((p_project->>'featured')::boolean,false),
      published_at=case when p_project->>'status'='published' then coalesce(p.published_at,now()) else null end,
      updated_at=now()
    where p.id=(p_project->>'id')::uuid and p.tenant_id=v_tenant returning * into v_row;
  else
    insert into public.qs_portfolio_projects(tenant_id,title,slug,summary,description,category_slugs,product_keys,status,featured,published_at)
    values(v_tenant,p_project->>'title',p_project->>'slug',coalesce(p_project->>'summary',''),
      coalesce(p_project->>'description',''),
      coalesce(array(select jsonb_array_elements_text(p_project->'categorySlugs')),'{}'),
      coalesce(array(select jsonb_array_elements_text(p_project->'productKeys')),'{}'),
      coalesce(p_project->>'status','draft'),coalesce((p_project->>'featured')::boolean,false),
      case when p_project->>'status'='published' then now() else null end)
    returning * into v_row;
  end if;
  if v_row.id is null then raise exception 'Project not found in this tenant'; end if;
  return jsonb_build_object('id',v_row.id,'slug',v_row.slug,'title',v_row.title,
    'summary',v_row.summary,'description',v_row.description,
    'categorySlugs',v_row.category_slugs,'productKeys',v_row.product_keys,
    'status',v_row.status,'featured',v_row.featured,'publishedAt',v_row.published_at,'media',v_row.media);
end;
$$;
revoke all on function public.admin_save_quick_solution_portfolio_project(text,jsonb) from public;
grant execute on function public.admin_save_quick_solution_portfolio_project(text,jsonb) to authenticated;
