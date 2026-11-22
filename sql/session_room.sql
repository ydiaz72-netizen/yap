-- PonteTalk: Session room — shared language timer + conversation cards
-- Roadmap DB-08, BE-12, BE-13 (front end: FE-11)
-- Run once in Supabase → SQL Editor. Safe to run again.
--
-- How it works
--   • One state row per session: which language is being spoken now, since when, paused or not,
--     and which conversation card everyone sees.
--   • Every language stretch is saved as a segment (language, start, end).
--     Time per language = sum of its segments (the open one counts up to now).
--   • Anyone in the session (host, joined, attended) can switch language and get the next card.
--     Only the host can pause or reset.
--   • The room works from 15 minutes before the start until 60 minutes after the planned end.
--   • Tables are locked: all reading and writing goes through the pt_room_* functions below.

-- ---------- tables ----------
create table if not exists public.session_timer_state (
  activity_id  uuid primary key references public.activities(id) on delete cascade,
  current_lang text,
  seg_started  timestamptz,
  prompt_idx   integer not null default 0,
  updated_at   timestamptz not null default now(),
  updated_by   uuid
);

create table if not exists public.session_timer_segments (
  id          bigserial primary key,
  activity_id uuid not null references public.activities(id) on delete cascade,
  lang        text not null,
  started_at  timestamptz not null default now(),
  ended_at    timestamptz,
  started_by  uuid
);
create index if not exists session_timer_segments_act on public.session_timer_segments(activity_id, started_at);

alter table public.session_timer_state    enable row level security;
alter table public.session_timer_segments enable row level security;
-- No policies on purpose: only the security-definer functions below can read/write.

-- ---------- helpers ----------
create or replace function public.pt_room_is_member(p_activity uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from activities where id = p_activity and host_id = auth.uid())
      or exists(select 1 from participants
                where activity_id = p_activity and user_id = auth.uid()
                  and status in ('joined','attended'));
$$;

create or replace function public.pt_room_is_host(p_activity uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from activities where id = p_activity and host_id = auth.uid());
$$;

-- Open from 15 min before the start until 60 min after the planned end
create or replace function public.pt_room_is_open(p_activity uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from activities
                where id = p_activity and status <> 'cancelled'
                  and now() >= starts_at - interval '15 minutes'
                  and now() <= starts_at + make_interval(mins => coalesce(duration_min, 60) + 60));
$$;

-- Close the running stretch (if any)
create or replace function public.pt_room_close_segment(p_activity uuid)
returns void language sql security definer set search_path = public as $$
  update session_timer_segments set ended_at = now()
   where activity_id = p_activity and ended_at is null;
$$;

-- ---------- read ----------
create or replace function public.pt_room_state(p_activity uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare st session_timer_state; a activities; totals jsonb;
begin
  if auth.uid() is null or not pt_room_is_member(p_activity) then
    raise exception 'room_not_member';
  end if;
  select * into a from activities where id = p_activity;
  select * into st from session_timer_state where activity_id = p_activity;
  select coalesce(jsonb_object_agg(lang, secs), '{}'::jsonb) into totals
    from (select lang, round(sum(extract(epoch from (coalesce(ended_at, now()) - started_at))))::int as secs
            from session_timer_segments where activity_id = p_activity group by lang) t;
  return jsonb_build_object(
    'now',          now(),
    'open',         pt_room_is_open(p_activity),
    'is_host',      pt_room_is_host(p_activity),
    'language_a',   a.language_a,
    'language_b',   a.language_b,
    'current_lang', st.current_lang,
    'seg_started',  st.seg_started,
    'paused',       st.current_lang is null,
    'prompt_idx',   coalesce(st.prompt_idx, 0),
    'totals',       totals,
    'updated_at',   st.updated_at);
end $$;

-- ---------- actions ----------
-- Anyone in the session: start speaking a language (or switch)
create or replace function public.pt_room_switch(p_activity uuid, p_lang text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a activities; cur text;
begin
  if auth.uid() is null or not pt_room_is_member(p_activity) then raise exception 'room_not_member'; end if;
  if not pt_room_is_open(p_activity) then raise exception 'room_closed'; end if;
  select * into a from activities where id = p_activity;
  if p_lang is null or (p_lang is distinct from a.language_a and p_lang is distinct from a.language_b) then
    raise exception 'room_bad_lang';
  end if;
  select current_lang into cur from session_timer_state where activity_id = p_activity for update;
  if cur is not distinct from p_lang then return pt_room_state(p_activity); end if;
  perform pt_room_close_segment(p_activity);
  insert into session_timer_segments(activity_id, lang, started_by) values (p_activity, p_lang, auth.uid());
  insert into session_timer_state(activity_id, current_lang, seg_started, updated_at, updated_by)
       values (p_activity, p_lang, now(), now(), auth.uid())
  on conflict (activity_id) do update
       set current_lang = excluded.current_lang, seg_started = excluded.seg_started,
           updated_at = now(), updated_by = auth.uid();
  return pt_room_state(p_activity);
end $$;

-- Host only: pause
create or replace function public.pt_room_pause(p_activity uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not pt_room_is_host(p_activity) then raise exception 'room_host_only'; end if;
  perform pt_room_close_segment(p_activity);
  update session_timer_state set current_lang = null, seg_started = null, updated_at = now(), updated_by = auth.uid()
   where activity_id = p_activity;
  return pt_room_state(p_activity);
end $$;

-- Host only: reset (clears all language times; the card number stays so cards don't repeat)
create or replace function public.pt_room_reset(p_activity uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not pt_room_is_host(p_activity) then raise exception 'room_host_only'; end if;
  delete from session_timer_segments where activity_id = p_activity;
  update session_timer_state set current_lang = null, seg_started = null, updated_at = now(), updated_by = auth.uid()
   where activity_id = p_activity;
  return pt_room_state(p_activity);
end $$;

-- Anyone in the session: next conversation card (same card for everyone)
create or replace function public.pt_room_next_prompt(p_activity uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not pt_room_is_member(p_activity) then raise exception 'room_not_member'; end if;
  if not pt_room_is_open(p_activity) then raise exception 'room_closed'; end if;
  insert into session_timer_state(activity_id, prompt_idx, updated_at, updated_by)
       values (p_activity, 1, now(), auth.uid())
  on conflict (activity_id) do update
       set prompt_idx = session_timer_state.prompt_idx + 1, updated_at = now(), updated_by = auth.uid();
  return pt_room_state(p_activity);
end $$;

-- ---------- permissions ----------
grant execute on function
  public.pt_room_state(uuid), public.pt_room_switch(uuid, text), public.pt_room_pause(uuid),
  public.pt_room_reset(uuid), public.pt_room_next_prompt(uuid)
to authenticated;
revoke execute on function
  public.pt_room_state(uuid), public.pt_room_switch(uuid, text), public.pt_room_pause(uuid),
  public.pt_room_reset(uuid), public.pt_room_next_prompt(uuid),
  public.pt_room_is_member(uuid), public.pt_room_is_host(uuid), public.pt_room_is_open(uuid),
  public.pt_room_close_segment(uuid)
from anon, public;
grant execute on function
  public.pt_room_state(uuid), public.pt_room_switch(uuid, text), public.pt_room_pause(uuid),
  public.pt_room_reset(uuid), public.pt_room_next_prompt(uuid)
to authenticated;

-- Done ✅
select 'Session room ready' as status;
