-- QS-09.1 — normalize South African phone formats for public order tracking.
-- Applied to XOS Staging as 20260913203520_qs_09_1_sa_phone_tracking_normalization.

create or replace function public.qs_normalize_sa_phone(p_value text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_digits text;
begin
  v_digits := regexp_replace(coalesce(p_value,''),'[^0-9]','','g');

  if length(v_digits)=11 and left(v_digits,2)='27' then
    return '0' || substring(v_digits from 3);
  end if;

  if length(v_digits)=10 and left(v_digits,1)='0' then
    return v_digits;
  end if;

  if length(v_digits)=9 then
    return '0' || v_digits;
  end if;

  return v_digits;
end
$$;

revoke all on function public.qs_normalize_sa_phone(text) from public;
grant execute on function public.qs_normalize_sa_phone(text) to anon, authenticated, service_role;

do $do$
declare
  v_oid oid;
  v_definition text;
  v_old text := $old$
    v_contact_digits := regexp_replace(v_contact,'[^0-9]','','g');

    v_authorized :=
      (v_order.customer_email is not null and lower(trim(v_order.customer_email))=v_contact)
      or (
        v_order.customer_phone is not null
        and length(v_contact_digits) >= 7
        and regexp_replace(v_order.customer_phone,'[^0-9]','','g')=v_contact_digits
      );
$old$;
  v_new text := $new$
    v_contact_digits := public.qs_normalize_sa_phone(v_contact);

    v_authorized :=
      (v_order.customer_email is not null and lower(trim(v_order.customer_email))=v_contact)
      or (
        v_order.customer_phone is not null
        and length(v_contact_digits) >= 9
        and public.qs_normalize_sa_phone(v_order.customer_phone)=v_contact_digits
      );
$new$;
begin
  select p.oid
  into v_oid
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='get_quick_solution_tracking'
  limit 1;

  if v_oid is null then
    raise exception 'get_quick_solution_tracking is missing';
  end if;

  select pg_get_functiondef(v_oid) into v_definition;

  if position(v_old in v_definition)=0 then
    raise exception 'Expected QS-09 contact verification block was not found';
  end if;

  v_definition := replace(v_definition, v_old, v_new);
  execute v_definition;
end
$do$;

revoke all on function public.get_quick_solution_tracking(text,text,text) from public;
grant execute on function public.get_quick_solution_tracking(text,text,text) to anon, authenticated;
