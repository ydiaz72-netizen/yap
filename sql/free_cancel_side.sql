-- =====================================================================
-- PonteTalk · No strike for the host when a language side is empty
-- A host who cancels less than 2 hours before the start does NOT get a strike
-- if one of the two languages has nobody who speaks it (host + joined guests).
-- Example: Spanish ⇄ German, only Spanish speakers joined → cancelling is free.
-- Also removes such strikes that were already given.
-- Needs: trust_fixes.sql. Run once in Supabase → SQL Editor. Safe to run again.
-- =====================================================================

create or replace function public.pt_side_missing(p_activity uuid)
returns boolean language sql stable security definer set search_path = public as $$
  with a as (select id, host_id, language_a, language_b from activities where id = p_activity),
  ppl as (
    select host_id as uid from a
    union
    select p.user_id from participants p, a where p.activity_id = a.id and p.status in ('joined','offered')
  ),
  sp as (
    select distinct l.language_code from user_languages l join ppl on ppl.uid = l.user_id
     where l.role in ('native','fluent')
  )
  select case when a.language_a is null or a.language_b is null then false
              else not exists (select 1 from sp where language_code = a.language_a)
                or not exists (select 1 from sp where language_code = a.language_b) end
    from a;
$$;
revoke all on function public.pt_side_missing(uuid) from public, anon;
grant execute on function public.pt_side_missing(uuid) to authenticated;

create or replace function public.pt_host_late_cancel_log()
returns trigger language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if new.status = 'cancelled' and old.status is distinct from 'cancelled'
     and auth.uid() = old.host_id                                  -- the host did it (not an admin)
     and old.starts_at > now()
     and old.starts_at - now() < make_interval(hours => coalesce((select (value #>> '{}')::numeric::int from app_settings where key = 'free_cancel_hours'), 2)) then
    select count(*) into n from participants where activity_id = old.id and status in ('joined','offered');
    if n > 0 and not coalesce(pt_side_missing(old.id), false) then   -- one language empty → free
      insert into host_late_cancels(activity_id, host_id, guests) values (old.id, old.host_id, n)
      on conflict (activity_id) do nothing;
    end if;
  end if;
  return new;
end $$;

-- clean up strikes already given for sessions where a language side was empty
delete from host_late_cancels h where coalesce(pt_side_missing(h.activity_id), false);

notify pgrst, 'reload schema';
