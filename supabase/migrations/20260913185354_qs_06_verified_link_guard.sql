-- QS-06: the compatibility reference may only be changed after trusted verification.
create or replace function commerce.qs_guard_easy_locate_business_ref()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(auth.role(),'')='service_role'
     or session_user in ('postgres','supabase_admin') then
    return new;
  end if;

  if tg_op='INSERT' then
    new.easy_locate_business_ref := null;
    return new;
  end if;

  if new.easy_locate_business_ref is distinct from old.easy_locate_business_ref then
    new.easy_locate_business_ref := old.easy_locate_business_ref;
  end if;

  return new;
end
$$;

drop trigger if exists trg_qs_guard_easy_locate_business_ref on commerce.fulfilment_points;
create trigger trg_qs_guard_easy_locate_business_ref
before insert or update of easy_locate_business_ref
on commerce.fulfilment_points
for each row execute function commerce.qs_guard_easy_locate_business_ref();

comment on function commerce.qs_guard_easy_locate_business_ref() is
  'QS-06: prevents browser/admin payloads from manufacturing Easy Locate links. Only trusted service-role verification may change the compatibility reference.';
