-- PonteTalk: three trust & safety fixes
--   1. "Fits my free time" now works for sessions that cross midnight (e.g. 23:30–00:30),
--      and a free time that runs to 23:59 counts as running to midnight.
--   2. Hosts follow the same rules: cancelling a session that has guests less than
--      2 hours before the start = ½ strike for the host (same as a guest's late cancel).
--   3. Hosts can remove a person from their session. A removed person can't join that host's sessions again.
-- Run once in Supabase → SQL Editor. Safe to run again.

-- ============ 1. fits my free time, across midnight ============
create or replace function public.pt_fits_time(p_user uuid, p_start timestamptz, p_dur integer, p_tz text)
returns boolean language sql stable security definer set search_path = public as $$
  with s as (
    select (p_start at time zone coalesce(p_tz,'UTC')) as ls,
           ((p_start + make_interval(mins => p_dur)) at time zone coalesce(p_tz,'UTC')) as le
  ), segs as (      -- the session split per calendar day, in seconds of that day
    select extract(isodow from ls)::int - 1 as wd,
           extract(epoch from ls::time) as a,
           case when ls::date = le::date then extract(epoch from le::time) else 86400 end as b
      from s
    union all
    select extract(isodow from le)::int - 1, 0, extract(epoch from le::time)
      from s where ls::date <> le::date and le::time <> '00:00'
  )
  select case when p_user is null then false else coalesce((
    select sum(greatest(0,
             least(case when av.end_time >= '23:59' then 86400 else extract(epoch from av.end_time) end, g.b)
             - greatest(extract(epoch from av.start_time), g.a)))
      from public.availability av join segs g on av.weekday = g.wd
     where av.user_id = p_user
  ), 0) >= p_dur * 60 end
$$;

-- ============ 2. host late cancels ============
create table if not exists public.host_late_cancels (
  activity_id  uuid primary key references public.activities(id) on delete cascade,
  host_id      uuid not null,
  cancelled_at timestamptz not null default now(),
  guests       integer not null default 0
);
alter table public.host_late_cancels enable row level security;   -- no policies: functions only

create or replace function public.pt_host_late_cancel_log()
returns trigger language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if new.status = 'cancelled' and old.status is distinct from 'cancelled'
     and auth.uid() = old.host_id                                  -- the host did it (not an admin)
     and old.starts_at > now()
     and old.starts_at - now() < make_interval(hours => coalesce((select (value #>> '{}')::numeric::int from app_settings where key = 'free_cancel_hours'), 2)) then
    select count(*) into n from participants where activity_id = old.id and status in ('joined','offered');
    if n > 0 then
      insert into host_late_cancels(activity_id, host_id, guests) values (old.id, old.host_id, n)
      on conflict (activity_id) do nothing;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_activities_host_late_cancel on public.activities;
create trigger trg_activities_host_late_cancel before update of status on public.activities
  for each row execute function public.pt_host_late_cancel_log();

-- strike list now includes the host's own late cancels (kind 'host_late_cancel', same weight as a late cancel)
create or replace function public.pt_strike_events(p_user uuid)
returns table(activity_id uuid, title text, kind text, at timestamptz, weight numeric, waived boolean, expires_at timestamptz)
language sql stable security definer set search_path = public as $$
  with cfg as (
    select coalesce((select (value #>> '{}')::numeric from app_settings where key = 'late_cancel_strike'), 0.5) as late_w,
           coalesce((select (value #>> '{}')::numeric from app_settings where key = 'no_show_strike'), 1)       as ns_w,
           coalesce((select (value #>> '{}')::numeric::int from app_settings where key = 'strike_expiry_days'), 60) as exp_d,
           coalesce((select (value #>> '{}')::numeric::int from app_settings where key = 'passes_per_month'), 1)   as passes
  ), ev as (
    select p.activity_id, a.title::text as title,
           case when p.status = 'no_show' then 'no_show' else 'late_cancel' end as kind,
           case when p.status = 'no_show' then a.starts_at else p.updated_at end as at,
           case when p.status = 'no_show' then cfg.ns_w else cfg.late_w end as weight,
           cfg.exp_d, cfg.passes
      from participants p join activities a on a.id = p.activity_id cross join cfg
     where p.user_id = p_user
       and (p.status = 'no_show' or (p.status = 'cancelled' and p.late_cancel))
       and coalesce(a.status, '') <> 'cancelled'
    union all
    select h.activity_id, a.title::text, 'host_late_cancel', h.cancelled_at, cfg.late_w, cfg.exp_d, cfg.passes
      from host_late_cancels h join activities a on a.id = h.activity_id cross join cfg
     where h.host_id = p_user
  ), ranked as (
    select ev.*, row_number() over (partition by date_trunc('month', ev.at at time zone 'Europe/Berlin') order by ev.at, ev.activity_id) as n
      from ev
  )
  select r.activity_id, r.title, r.kind, r.at, r.weight,
         (r.n <= r.passes) as waived,
         r.at + make_interval(days => r.exp_d) as expires_at
    from ranked r
   where r.at > now() - make_interval(days => r.exp_d)
   order by r.at desc;
$$;
revoke all on function public.pt_strike_events(uuid) from public, anon, authenticated;

-- ============ 3. host removes a person ============
create or replace function public.pt_host_remove(p_activity uuid, p_user uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a activities; old text;
begin
  if auth.uid() is null then raise exception 'sign_in_required'; end if;
  select * into a from activities where id = p_activity for update;
  if not found then raise exception 'not_found'; end if;
  if a.host_id <> auth.uid() and not pt_is_admin() then raise exception 'not_host'; end if;
  if p_user = a.host_id then raise exception 'not_host'; end if;
  select status into old from participants where activity_id = p_activity and user_id = p_user for update;
  if not found or old not in ('joined','pending','waitlisted','offered','invited') then raise exception 'not_in_session'; end if;
  update participants set status = 'kicked', waitlist_position = null, offer_expires_at = null
   where activity_id = p_activity and user_id = p_user;
  if old in ('joined','offered') and a.starts_at > now() then
    perform pt_offer_next_seats(p_activity);       -- the seat moves on to the waitlist
  else
    perform pt_compact_waitlist(p_activity);
  end if;
  return jsonb_build_object('status','kicked');
end $$;
revoke all on function public.pt_host_remove(uuid, uuid) from public, anon;
grant execute on function public.pt_host_remove(uuid, uuid) to authenticated;

select 'Trust fixes ready' as status;
