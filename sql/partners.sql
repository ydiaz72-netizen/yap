-- =====================================================================
-- PonteTalk · Find partners (opt-in member profiles)
-- Run once in Supabase → SQL Editor. Safe to run again. (Run blocking.sql first.)
--
--   * Off by default. People switch on "Show me in Find partners" in their exchange profile.
--   * Only people who are visible themselves can browse (fair both ways).
--   * Shown: first name, photo, country, languages + levels, interests, short bio,
--     and the times you're BOTH usually free. Never: email, city, age, gender, time zone.
--   * Blocked people never see each other.
-- =====================================================================

alter table public.profiles add column if not exists partner_visible boolean not null default false;
alter table public.profiles add column if not exists bio text;
alter table public.profiles add column if not exists country text;
alter table public.profiles drop constraint if exists profiles_bio_len;
alter table public.profiles add constraint profiles_bio_len check (bio is null or length(bio) <= 160);
alter table public.profiles drop constraint if exists profiles_country_len;
alter table public.profiles add constraint profiles_country_len check (country is null or length(country) <= 40);

-- Weekly free times as real moments this week (so different time zones line up)
create or replace function public.pt_free_ranges(p_user uuid)
returns table(weekday int, start_time time, r tstzrange)
language sql stable security definer set search_path = public as $$
  select a.weekday::int, a.start_time::time,
         tstzrange(((date_trunc('week', now() at time zone coalesce(p.time_zone,'UTC'))::date + a.weekday) + a.start_time::time) at time zone coalesce(p.time_zone,'UTC'),
                   ((date_trunc('week', now() at time zone coalesce(p.time_zone,'UTC'))::date + a.weekday) + a.end_time::time)   at time zone coalesce(p.time_zone,'UTC'))
  from availability a join profiles p on p.id = a.user_id
  where a.user_id = p_user;
$$;

-- One partner card (as JSON). Viewer's own free times that overlap theirs → "both free"
create or replace function public.pt_partner_card(p_viewer uuid, p_user uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'user_id', p.id,
    'name', p.display_name,
    'avatar_url', p.avatar_url,
    'country', p.country,
    'bio', p.bio,
    'interests', coalesce(to_jsonb(p.interests), '[]'::jsonb),
    'languages', coalesce((select jsonb_agg(jsonb_build_object('code', l.language_code, 'role', l.role, 'level', l.level))
                           from user_languages l where l.user_id = p.id), '[]'::jsonb),
    'both_free', coalesce((select jsonb_agg(distinct jsonb_build_object('weekday', m.weekday, 'start', to_char(m.start_time,'HH24:MI')))
                           from pt_free_ranges(p_viewer) m join pt_free_ranges(p.id) t on m.r && t.r), '[]'::jsonb))
  from profiles p where p.id = p_user;
$$;

-- ---------- browse ----------
create or replace function public.pt_partners()
returns setof jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if not exists(select 1 from profiles where id = auth.uid() and partner_visible and adult_confirmed_at is not null) then
    raise exception 'partner_optin_needed'; end if;
  return query
    select pt_partner_card(auth.uid(), p.id)
    from profiles p
    where p.partner_visible and p.adult_confirmed_at is not null
      and coalesce(trim(p.display_name),'') <> '' and p.id <> auth.uid()
      and not pt_blocked_between(auth.uid(), p.id)
      and exists(select 1 from user_languages l where l.user_id = p.id)
    order by p.updated_at desc nulls last
    limit 300;
end $$;

-- ---------- one profile (for share links). Signed-in members only ----------
create or replace function public.pt_partner(p_user uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if p_user <> auth.uid() and (
       pt_blocked_between(auth.uid(), p_user)
       or not exists(select 1 from profiles where id = p_user and partner_visible and adult_confirmed_at is not null)) then
    return null;   -- hidden, blocked or not found: same answer, nothing revealed
  end if;
  return pt_partner_card(auth.uid(), p_user);
end $$;

grant execute on function public.pt_partners(), public.pt_partner(uuid) to authenticated;
revoke execute on function public.pt_partner_card(uuid, uuid), public.pt_free_ranges(uuid) from anon, authenticated, public;
