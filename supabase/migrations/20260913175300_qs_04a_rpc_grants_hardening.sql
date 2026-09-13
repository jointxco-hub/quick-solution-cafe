revoke all on function public.admin_preview_quick_solution_opps_handoff(uuid) from public, anon, authenticated;
grant execute on function public.admin_preview_quick_solution_opps_handoff(uuid) to authenticated;

revoke all on function public.admin_list_quick_solution_opps_handoffs(text) from public, anon, authenticated;
grant execute on function public.admin_list_quick_solution_opps_handoffs(text) to authenticated;

revoke all on function public.admin_grant_quick_solution_opps_access(text,text) from public, anon, authenticated;
grant execute on function public.admin_grant_quick_solution_opps_access(text,text) to authenticated;
