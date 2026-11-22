-- =====================================================================
-- PonteTalk · Test practice: history and stats
-- "Leben in Deutschland" / Einbürgerungstest (exam = 'lid').
-- Run once in Supabase → SQL Editor. Safe to run again.
--
--   exam_attempts: one row per mock test or practice round (score, time, wrong questions)
--   exam_answers:  one row per answered question (for "mistakes" practice and progress)
--   Everyone only sees their own rows. A free limit can later count exam_attempts per month.
-- =====================================================================

create table if not exists public.exam_attempts (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  exam       text not null default 'lid' check (exam in ('lid')),
  mode       text not null check (mode in ('mock','practice')),
  state      text check (state is null or char_length(state) <= 3),
  topic      text check (topic is null or char_length(topic) <= 60),
  total      smallint not null check (total between 1 and 400),
  correct    smallint not null check (correct >= 0 and correct <= total),
  passed     boolean,
  seconds    int check (seconds is null or seconds between 0 and 86400),
  wrong      text[] not null default '{}' check (cardinality(wrong) <= 400),
  created_at timestamptz not null default now()
);
create index if not exists exam_attempts_user on public.exam_attempts(user_id, exam, created_at desc);

create table if not exists public.exam_answers (
  id         bigserial primary key,
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  exam       text not null default 'lid' check (exam in ('lid')),
  qnum       text not null check (char_length(qnum) <= 8),
  correct    boolean not null,
  created_at timestamptz not null default now()
);
create index if not exists exam_answers_user on public.exam_answers(user_id, exam, created_at desc);

alter table public.exam_attempts enable row level security;
alter table public.exam_answers  enable row level security;

drop policy if exists exam_attempts_own_sel on public.exam_attempts;
create policy exam_attempts_own_sel on public.exam_attempts for select to authenticated using (user_id = auth.uid());
drop policy if exists exam_attempts_own_ins on public.exam_attempts;
create policy exam_attempts_own_ins on public.exam_attempts for insert to authenticated with check (user_id = auth.uid());
drop policy if exists exam_attempts_own_del on public.exam_attempts;
create policy exam_attempts_own_del on public.exam_attempts for delete to authenticated using (user_id = auth.uid());

drop policy if exists exam_answers_own_sel on public.exam_answers;
create policy exam_answers_own_sel on public.exam_answers for select to authenticated using (user_id = auth.uid());
drop policy if exists exam_answers_own_ins on public.exam_answers;
create policy exam_answers_own_ins on public.exam_answers for insert to authenticated with check (user_id = auth.uid());
drop policy if exists exam_answers_own_del on public.exam_answers;
create policy exam_answers_own_del on public.exam_answers for delete to authenticated using (user_id = auth.uid());

revoke all on public.exam_attempts, public.exam_answers from anon;
grant select, insert, delete on public.exam_attempts, public.exam_answers to authenticated;
grant usage, select on sequence public.exam_answers_id_seq to authenticated;

-- Admin: how much is the practice used? (for the Stats page / future pricing)
create or replace function public.pt_admin_exam_stats()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(public.pt_is_admin(), false) then raise exception 'not_allowed'; end if;
  return jsonb_build_object(
    'users',       (select count(distinct user_id) from exam_attempts),
    'users_30d',   (select count(distinct user_id) from exam_attempts where created_at > now() - interval '30 days'),
    'mocks',       (select count(*) from exam_attempts where mode = 'mock'),
    'mocks_30d',   (select count(*) from exam_attempts where mode = 'mock' and created_at > now() - interval '30 days'),
    'pass_rate',   (select round(100.0 * avg(case when passed then 1 else 0 end)) from exam_attempts where mode = 'mock'),
    'answers',     (select count(*) from exam_answers),
    'heavy_users', (select count(*) from (select user_id from exam_attempts where mode = 'mock'
                      and created_at > now() - interval '30 days' group by user_id having count(*) > 5) t));
end $$;
grant execute on function public.pt_admin_exam_stats() to authenticated;

-- Done ✅
select 'Test practice ready 🇩🇪' as status;
