-- =====================================================================
-- PonteTalk · 🏆 Bridge Builder weekly league
-- Needs: blocking.sql, account_holds.sql. Run once in Supabase → SQL Editor.
-- Safe to run again.
--
-- How it works
--   * Opt-in only: nobody appears on the board until they press "Join".
--     Leaving hides them again right away (their points stay private).
--   * The game sends the XP it earns (only after joining).
--     At most 60 XP per call and 5,000 XP per week, so nobody can fake
--     a huge score.
--   * Weeks run Monday 00:00 to Sunday 23:59, Berlin time. Every Monday
--     the board starts again from 0.
--   * People you blocked (or who blocked you) and accounts on hold are
--     not shown.
-- All access goes through the pt_bb_* functions (tables are locked).
-- =====================================================================

create table if not exists public.bb_league_players (
  user_id   uuid primary key references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now()
);

create table if not exists public.bb_weekly_xp (
  user_id    uuid not null references auth.users(id) on delete cascade,
  week       date not null,
  xp         int  not null default 0 check (xp between 0 and 5000),
  updated_at timestamptz not null default now(),
  primary key (user_id, week)
);
create index if not exists bb_weekly_xp_week_idx on public.bb_weekly_xp(week, xp desc);

alter table public.bb_league_players enable row level security;
alter table public.bb_weekly_xp      enable row level security;
-- No policies on purpose: only the functions below can read/write.
revoke all on public.bb_league_players, public.bb_weekly_xp from anon, authenticated;

-- ---------- this week (Monday, Berlin time) ----------
create or replace function public.pt_bb_week()
returns date language sql stable set search_path = public as $$
  select date_trunc('week', now() at time zone 'Europe/Berlin')::date;
$$;

-- ---------- join / leave ----------
create or replace function public.pt_bb_join(p_on boolean)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if p_on then
    insert into bb_league_players(user_id) values (auth.uid()) on conflict do nothing;
  else
    delete from bb_league_players where user_id = auth.uid();
  end if;
  return p_on;
end $$;

-- ---------- add XP earned in the game ----------
create or replace function public.pt_bb_add(p_xp int)
returns int language plpgsql security definer set search_path = public as $$
declare v int;
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if not exists(select 1 from bb_league_players where user_id = auth.uid()) then return null; end if;
  if p_xp is null or p_xp < 1 or p_xp > 60 then raise exception 'bb_invalid'; end if;
  insert into bb_weekly_xp(user_id, week, xp) values (auth.uid(), pt_bb_week(), least(p_xp, 5000))
  on conflict (user_id, week) do update set xp = least(bb_weekly_xp.xp + p_xp, 5000), updated_at = now()
  returning xp into v;
  return v;
end $$;

-- ---------- the board: top 20 + my own place ----------
create or replace function public.pt_bb_board()
returns jsonb language sql stable security definer set search_path = public as $$
  with w as (select pt_bb_week() as week),
  ranked as (
    select x.user_id, x.xp, x.updated_at,
           rank() over (order by x.xp desc) as rk
    from bb_weekly_xp x
    join w on x.week = w.week
    join bb_league_players p on p.user_id = x.user_id
    where x.xp > 0
      and not pt_on_hold(x.user_id)
      and (x.user_id = auth.uid() or not pt_blocked_between(auth.uid(), x.user_id))
  ),
  rows as (
    select jsonb_build_object('rank', r.rk, 'xp', r.xp, 'me', r.user_id = auth.uid(),
             'name', coalesce(pr.display_name, 'Member'), 'avatar_url', pr.avatar_url) as j, r.rk, r.updated_at, r.user_id
    from ranked r left join profiles pr on pr.id = r.user_id
  )
  select jsonb_build_object(
    'week', (select week from w),
    'ends_at', ((select week from w) + 7)::timestamp at time zone 'Europe/Berlin',
    'joined', exists(select 1 from bb_league_players where user_id = auth.uid()),
    'players', (select count(*) from rows),
    'top', coalesce((select jsonb_agg(j order by rk, updated_at) from (select * from rows order by rk, updated_at limit 20) t), '[]'::jsonb),
    'mine', (select j from rows where user_id = auth.uid())
  );
$$;

revoke all on function public.pt_bb_join(boolean), public.pt_bb_add(int), public.pt_bb_board() from public, anon;
grant execute on function public.pt_bb_join(boolean), public.pt_bb_add(int), public.pt_bb_board() to authenticated;

notify pgrst, 'reload schema';
