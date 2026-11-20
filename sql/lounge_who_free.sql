-- =====================================================================
-- PonteTalk · Lounges: show WHO is free at each time (first name + photo)
-- Run once in Supabase → SQL Editor. Safe to run again.
-- Only signed-in members see it, and only for people who marked a time in that lounge.
-- =====================================================================
drop function if exists public.pt_lounge_free_get(text);

create function public.pt_lounge_free_get(p_lounge text)
returns table(dow int, hour int, n int, mine boolean, people jsonb)
language sql stable security definer set search_path = public as $$
  select f.dow::int, f.hour::int, count(*)::int, bool_or(f.user_id = auth.uid()),
         jsonb_agg(jsonb_build_object('user_id', f.user_id,
                                      'name', coalesce(nullif(trim(p.display_name),''), 'Member'),
                                      'avatar_url', p.avatar_url)
                   order by (f.user_id = auth.uid()) desc, p.display_name)
  from lounge_free f
  left join profiles p on p.id = f.user_id
  where auth.uid() is not null and f.lounge_id = p_lounge
  group by f.dow, f.hour;
$$;

grant execute on function public.pt_lounge_free_get(text) to authenticated;
