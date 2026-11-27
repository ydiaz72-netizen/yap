-- =====================================================================
-- PonteTalk · 📧 Nudge members who haven't added their languages yet
-- Needs: account_holds.sql (admins, pt_is_admin), word_fixed_bell.sql (notifications, pt_notify).
-- Run once in Supabase → SQL Editor. Safe to run again.
--
--   * Admins see members with NO languages in Profile → 🛠 → 📧 Incomplete profiles
--     (name, email, when they joined, when they were last nudged).
--   * "Mark as sent" remembers the date and sends each person a 🔔 bell
--     (bell only: the email itself is sent by you, with the text the app prepares).
--   * Stats: how many were nudged and how many added languages afterwards.
-- =====================================================================

create table if not exists public.profile_nudges (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  nudged_at  timestamptz not null default now(),
  times      int not null default 1
);
alter table public.profile_nudges enable row level security;
revoke all on public.profile_nudges from anon, authenticated;

-- allow the new bell kind (keeps every kind that already exists)
do $$
declare ks text[];
begin
  select array(
    select k from unnest(array['seat_offer','join_request','approved','declined','cancelled','reminder_24h','reminder_15m',
      'new_joiner','changed','invited','chat','report','session_match','reschedule','reminder_prep','word_fixed',
      'echo_new','echo_result','duel_done','new_member','feedback','profile_nudge']) k
    union
    select distinct kind from public.notifications where kind is not null
  ) into ks;
  alter table public.notifications drop constraint if exists notifications_kind_check;
  execute format('alter table public.notifications add constraint notifications_kind_check check (kind = any (%L::text[]))', ks);
end $$;

-- members without any language
create or replace function public.pt_admin_incomplete()
returns table(user_id uuid, name text, email text, joined timestamptz, nudged_at timestamptz, times int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(pt_is_admin(), false) then raise exception 'admins_only'; end if;
  return query
    select u.id, nullif(trim(p.display_name),'')::text, u.email::text, u.created_at, n.nudged_at, coalesce(n.times,0)
    from auth.users u
    left join profiles p on p.id = u.id
    left join profile_nudges n on n.user_id = u.id
    where u.email is not null
      and u.id is distinct from auth.uid()
      and not exists (select 1 from user_languages l where l.user_id = u.id)
    order by n.nudged_at nulls first, u.created_at desc;
end $$;

-- mark as sent + bell
create or replace function public.pt_admin_nudge(p_ids uuid[])
returns int language plpgsql security definer set search_path = public as $$
declare u uuid; n int := 0;
begin
  if not coalesce(pt_is_admin(), false) then raise exception 'admins_only'; end if;
  foreach u in array coalesce(p_ids, '{}') loop
    insert into profile_nudges(user_id) values (u)
      on conflict (user_id) do update set nudged_at = now(), times = profile_nudges.times + 1;
    begin
      perform pt_notify(u, 'profile_nudge', null, 'profile_nudge:' || u || ':' || to_char(now(),'YYYY-MM-DD'), '{}'::jsonb);
      update notifications set email = false where user_id = u and kind = 'profile_nudge' and sent_at is null;
    exception when others then null;
    end;
    n := n + 1;
  end loop;
  return n;
end $$;

-- how well it works
create or replace function public.pt_admin_nudge_stats()
returns table(nudged int, completed int)
language sql stable security definer set search_path = public as $$
  select case when coalesce(pt_is_admin(),false) then (select count(*)::int from profile_nudges) else 0 end,
         case when coalesce(pt_is_admin(),false) then (select count(*)::int from profile_nudges n
              where exists (select 1 from user_languages l where l.user_id = n.user_id)) else 0 end;
$$;

revoke all on function public.pt_admin_incomplete() from anon;
revoke all on function public.pt_admin_nudge(uuid[]) from anon;
revoke all on function public.pt_admin_nudge_stats() from anon;
grant execute on function public.pt_admin_incomplete(), public.pt_admin_nudge(uuid[]), public.pt_admin_nudge_stats() to authenticated;

notify pgrst, 'reload schema';
