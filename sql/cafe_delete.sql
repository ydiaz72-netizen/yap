-- =====================================================================
-- PonteTalk · Let admins delete language cafés
-- Run once in Supabase → SQL Editor. Safe to run again.
-- Deletes the café and any "broken link" flags on it, admins only.
-- =====================================================================
create or replace function public.pt_admin_delete_cafe(p_cafe public.cafes.id%TYPE)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(pt_is_admin(), false) then raise exception 'not_allowed'; end if;
  delete from cafe_reports where cafe_id = p_cafe;
  delete from cafes where id = p_cafe;
  if not found then raise exception 'not_found'; end if;
end $$;

revoke execute on function public.pt_admin_delete_cafe(public.cafes.id%TYPE) from anon, public;
grant execute on function public.pt_admin_delete_cafe(public.cafes.id%TYPE) to authenticated;
