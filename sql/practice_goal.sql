-- =====================================================================
-- PonteTalk · Weekly practice goal + progress (Home → "My week")
-- Run once in Supabase → SQL Editor. Safe to run again.
-- Needs: vocab.sql, exam_practice.sql, echo_challenge.sql (skipped if missing).
--
--   * Each person picks a goal: practice on N days a week (1–7, default 3)
--   * A day counts when they: went to / hosted a session, did flashcards,
--     did Leben in Deutschland or DTZ practice, or posted an Echo
-- =====================================================================

create table if not exists public.practice_goals (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  days_per_week smallint not null default 3 check (days_per_week between 1 and 7),
  updated_at    timestamptz not null default now()
);
alter table public.practice_goals enable row level security;
drop policy if exists pg_sel on public.practice_goals;
drop policy if exists pg_ins on public.practice_goals;
drop policy if exists pg_upd on public.practice_goals;
create policy pg_sel on public.practice_goals for select to authenticated using (user_id = auth.uid());
create policy pg_ins on public.practice_goals for insert to authenticated with check (user_id = auth.uid());
create policy pg_upd on public.practice_goals for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select, insert, update on public.practice_goals to authenticated;

-- What I practised per day (in my time zone), for the last p_days days
-- kind: session · cards · test · echo     n: how many (sessions, cards reviewed, tests, echos)
create or replace function public.pt_my_practice(p_tz text default 'Europe/Berlin', p_days int default 70)
returns table(day date, kind text, n int)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); tz text; since timestamptz;
begin
  if me is null then return; end if;
  tz := case when exists(select 1 from pg_timezone_names where name = p_tz) then p_tz else 'Europe/Berlin' end;
  since := now() - make_interval(days => least(greatest(coalesce(p_days, 70), 7), 400));

  return query
  select (a.starts_at at time zone tz)::date, 'session'::text, count(*)::int
    from participants p join activities a on a.id = p.activity_id
   where p.user_id = me and p.status in ('joined','attended') and a.status <> 'cancelled'
     and a.starts_at <= now() and a.starts_at > since
   group by 1
  union all
  select (a.starts_at at time zone tz)::date, 'session', count(*)::int
    from activities a
   where a.host_id = me and a.status <> 'cancelled' and a.starts_at <= now() and a.starts_at > since
   group by 1;

  if to_regclass('public.vocab_days') is not null then
    return query execute
      'select day, ''cards''::text, sum(reviews)::int from vocab_days
        where user_id = $1 and day > ($2 at time zone $3)::date and reviews > 0 group by day'
      using me, since, tz;
  end if;
  if to_regclass('public.exam_attempts') is not null then
    return query execute
      'select (created_at at time zone $3)::date, ''test''::text, count(*)::int from exam_attempts
        where user_id = $1 and created_at > $2 group by 1'
      using me, since, tz;
  end if;
  if to_regclass('public.echo_entries') is not null then
    return query execute
      'select (created_at at time zone $3)::date, ''echo''::text, count(*)::int from echo_entries
        where user_id = $1 and created_at > $2 group by 1'
      using me, since, tz;
  end if;
end $$;
grant execute on function public.pt_my_practice(text, int) to authenticated;
