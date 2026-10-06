-- Run after the supplier-admin migration. Disposable identities and edits roll back.
begin;
do $test$
declare tenant uuid; actor uuid:=gen_random_uuid(); member uuid:=gen_random_uuid(); c commerce.service_product_configs; result jsonb; public_product jsonb; def jsonb; old_version text; key text;
begin
 select id into tenant from public.tenants where slug='quick-solution';
 insert into auth.users(id,email) values(actor,'admin-photo-qa-'||actor||'@disposable.test'),(member,'member-photo-qa-'||member||'@disposable.test');
 insert into public.tenant_memberships(tenant_id,auth_user_id,tenant_role,status) values(tenant,actor,'admin','active'),(tenant,member,'member','active');
 perform set_config('request.jwt.claims',jsonb_build_object('sub',member,'role','authenticated')::text,true);
 select * into c from commerce.service_product_configs where tenant_id=tenant and source_key='car-magnets';
 begin
  perform public.admin_update_quick_solution_product('quick-solution','car-magnets',c.customer_definition,c.pricing_definition,c.pricing_version);
  raise exception 'Member incorrectly allowed to manage pricing';
 exception when insufficient_privilege then null; end;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true);
 def:=c.pricing_definition||'{"quoteRequired":false,"quoteOperations":{"sourceName":"Private QA supplier","notes":"Private test notes"}}'::jsonb;
 old_version:=c.pricing_version;
 result:=public.admin_update_quick_solution_product('quick-solution','car-magnets',jsonb_set(c.customer_definition,'{pricing}','{"strategy":"ENQUIRY","quoteRequired":false}'::jsonb),def,c.pricing_version);
 select * into c from commerce.service_product_configs where tenant_id=tenant and source_key='car-magnets';
 if c.pricing_definition->>'quoteRequired'<>'true' or c.customer_definition->'pricing'->>'quoteRequired'<>'true' then raise exception 'Quote protection lost'; end if;
 if c.pricing_definition->'quoteOperations'->>'sourceName'<>'Private QA supplier' then raise exception 'Private notes not retained'; end if;
 begin
  perform public.admin_update_quick_solution_product('quick-solution','car-magnets',c.customer_definition,c.pricing_definition,old_version);
  raise exception 'Stale save accepted';
 exception when serialization_failure then null; end;
 select * into c from commerce.service_product_configs where tenant_id=tenant and source_key='contravision';
 def:=jsonb_set(c.pricing_definition,'{areaSupplier,supplierCost}','180'::jsonb);
 def:=jsonb_set(def,'{baseRate}','1'::jsonb);
 result:=public.admin_update_quick_solution_product('quick-solution','contravision',jsonb_set(c.customer_definition,'{pricing,baseRate}','1'::jsonb),def,c.pricing_version);
 select p into public_product from jsonb_array_elements(public.get_quick_solution_catalog('quick-solution')->'products') p where p->>'id'='contravision';
 if (public_product->'pricing'->>'baseRate')::numeric<>360 then raise exception 'Server did not derive selling rate'; end if;
 result:=commerce.qs_calculate_price(tenant,'contravision','{"width":1,"height":1,"material":"standard","finishing":"print-only","artwork":"ready","turnaround":"standard"}'::jsonb);
 if (result->>'total')::numeric<>360 then raise exception 'Pricing engine disagrees with admin model'; end if;
 if public.get_quick_solution_catalog('quick-solution')::text ~ 'areaSupplier|supplierCost|marginRate|Private QA supplier|Private test notes|quoteOperations' then raise exception 'Private admin fields exposed'; end if;
 if commerce._qs_area_supplier_rate('{"supplierCost":150,"marginRate":0.5,"vatBasis":"excl_vat","vatRate":0.15}'::jsonb)<>345 then raise exception 'VAT rate error'; end if;
 begin
  perform commerce._qs_area_supplier_rate('{"supplierCost":150,"marginRate":1,"vatBasis":"none","vatRate":0}'::jsonb);
  raise exception 'Invalid margin accepted';
 exception when invalid_parameter_value then null; end;
 if has_function_privilege('anon','commerce._qs_area_supplier_rate(jsonb)','execute') or has_function_privilege('authenticated','commerce._qs_area_supplier_rate(jsonb)','execute') then raise exception 'Private helper grants'; end if;
 foreach key in array array['car-magnets','posters','rigid-signage'] loop
  select p into public_product from jsonb_array_elements(public.get_quick_solution_catalog('quick-solution')->'products') p where p->>'id'=key;
  if public_product->'media'->>'hero' is distinct from '/qs-catalogue/'||key||'-v1.webp' then raise exception 'Photo not published: %',key; end if;
 end loop;
end $test$;
select 'Admin quote saves, notes privacy, role/stale guards, area pricing and photos verified; QA changes rolled back.' as verification;
rollback;
