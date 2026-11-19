-- =====================================================================
-- PonteTalk · Pop quiz for sessions
-- Run once in Supabase → SQL Editor. Safe to run again.
--
-- How it works
--   * The host writes a multiple-choice quiz for a session ahead of time.
--   * Attendees can't see it until the host taps "Start quiz" (status = live).
--   * Attendees answer once; the score is worked out here on the server,
--     so nobody can see the right answers in the browser while it's live.
--   * When the host taps "Show answers" (status = closed) everyone sees
--     the right answers and the host sees the scoreboard.
-- All access goes through the pt_quiz_* functions below (tables are locked).
-- =====================================================================

create table if not exists public.session_quizzes (
  activity_id  uuid primary key references public.activities(id) on delete cascade,
  questions    jsonb not null,               -- [{ "q": "...", "o": ["a","b",...], "a": 0 }]
  status       text  not null default 'draft' check (status in ('draft','live','closed')),
  launched_at  timestamptz,
  closed_at    timestamptz,
  updated_at   timestamptz not null default now()
);

create table if not exists public.session_quiz_answers (
  activity_id  uuid not null references public.session_quizzes(activity_id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  answers      jsonb not null,               -- [0, 2, 1, ...]  (-1 = skipped)
  score        int  not null,
  total        int  not null,
  submitted_at timestamptz not null default now(),
  primary key (activity_id, user_id)
);

alter table public.session_quizzes      enable row level security;
alter table public.session_quiz_answers enable row level security;
-- No policies on purpose: only the security-definer functions below can read/write.
revoke all on public.session_quizzes, public.session_quiz_answers from anon, authenticated;

-- ---------- helpers ----------
create or replace function public.pt_quiz_is_host(p_activity uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from activities where id = p_activity and host_id = auth.uid());
$$;

create or replace function public.pt_quiz_is_member(p_activity uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from participants
                where activity_id = p_activity and user_id = auth.uid()
                  and status in ('joined','attended'));
$$;

-- Questions without the right answers (for attendees while live)
create or replace function public.pt_quiz_strip(p_q jsonb)
returns jsonb language sql immutable as $$
  select coalesce(jsonb_agg(jsonb_build_object('q', x->'q', 'o', x->'o') order by n), '[]'::jsonb)
  from jsonb_array_elements(p_q) with ordinality as t(x, n);
$$;

-- ---------- status of quizzes on my sessions (for the session cards) ----------
create or replace function public.pt_quiz_status_list()
returns table(activity_id uuid, status text, n int, answered int, mine boolean)
language sql stable security definer set search_path = public as $$
  select q.activity_id, q.status, jsonb_array_length(q.questions),
         (select count(*)::int from session_quiz_answers a where a.activity_id = q.activity_id),
         exists(select 1 from session_quiz_answers a where a.activity_id = q.activity_id and a.user_id = auth.uid())
  from session_quizzes q
  join activities s on s.id = q.activity_id
  where s.host_id = auth.uid()
     or (q.status <> 'draft' and exists(select 1 from participants p
          where p.activity_id = q.activity_id and p.user_id = auth.uid() and p.status in ('joined','attended')));
$$;

-- ---------- read one quiz ----------
create or replace function public.pt_quiz_get(p_activity uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare q session_quizzes; mine session_quiz_answers;
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  select * into q from session_quizzes where activity_id = p_activity;
  if pt_quiz_is_host(p_activity) then
    if not found then return jsonb_build_object('role','host','status','none'); end if;
    return jsonb_build_object('role','host','status',q.status,'questions',q.questions,
             'answered',(select count(*) from session_quiz_answers where activity_id = p_activity));
  end if;
  if not pt_quiz_is_member(p_activity) then raise exception 'not_in_session'; end if;
  if not found or q.status = 'draft' then return jsonb_build_object('role','guest','status','none'); end if;
  select * into mine from session_quiz_answers where activity_id = p_activity and user_id = auth.uid();
  return jsonb_build_object('role','guest','status',q.status,
           'questions', case when q.status = 'closed' then q.questions else pt_quiz_strip(q.questions) end,
           'mine', case when mine.user_id is null then null
                   else jsonb_build_object('answers',mine.answers,'score',mine.score,'total',mine.total) end);
end $$;

-- ---------- host: save the quiz (only while it isn't live) ----------
create or replace function public.pt_quiz_save(p_activity uuid, p_questions jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare x jsonb; nq int; no int; cur text;
begin
  if not pt_quiz_is_host(p_activity) then raise exception 'not_host'; end if;
  select status into cur from session_quizzes where activity_id = p_activity;
  if cur = 'live' then raise exception 'quiz_live'; end if;
  if jsonb_typeof(p_questions) <> 'array' then raise exception 'quiz_invalid'; end if;
  nq := jsonb_array_length(p_questions);
  if nq < 1 or nq > 15 then raise exception 'quiz_invalid'; end if;
  for x in select * from jsonb_array_elements(p_questions) loop
    if jsonb_typeof(x->'q') <> 'string' or length(trim(x->>'q')) < 1 or length(x->>'q') > 200 then raise exception 'quiz_invalid'; end if;
    if jsonb_typeof(x->'o') <> 'array' then raise exception 'quiz_invalid'; end if;
    no := jsonb_array_length(x->'o');
    if no < 2 or no > 4 then raise exception 'quiz_invalid'; end if;
    if exists(select 1 from jsonb_array_elements(x->'o') o
              where jsonb_typeof(o) <> 'string' or length(trim(o #>> '{}')) < 1 or length(o #>> '{}') > 80) then
      raise exception 'quiz_invalid'; end if;
    if jsonb_typeof(x->'a') <> 'number' or (x->>'a')::int < 0 or (x->>'a')::int >= no then raise exception 'quiz_invalid'; end if;
  end loop;
  insert into session_quizzes(activity_id, questions, status, updated_at)
  values (p_activity, p_questions, 'draft', now())
  on conflict (activity_id) do update
    set questions = excluded.questions, status = 'draft', launched_at = null, closed_at = null, updated_at = now();
  -- Saving a changed quiz starts it fresh
  delete from session_quiz_answers where activity_id = p_activity;
end $$;

-- ---------- host: delete the quiz ----------
create or replace function public.pt_quiz_delete(p_activity uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not pt_quiz_is_host(p_activity) then raise exception 'not_host'; end if;
  delete from session_quizzes where activity_id = p_activity;
end $$;

-- ---------- host: start / stop / reset ----------
-- p_status: 'live' (start or reopen), 'closed' (stop and show answers), 'draft' (reset, clears answers)
create or replace function public.pt_quiz_set_status(p_activity uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not pt_quiz_is_host(p_activity) then raise exception 'not_host'; end if;
  if p_status not in ('draft','live','closed') then raise exception 'quiz_invalid'; end if;
  if not exists(select 1 from session_quizzes where activity_id = p_activity) then raise exception 'quiz_missing'; end if;
  if p_status = 'draft' then delete from session_quiz_answers where activity_id = p_activity; end if;
  update session_quizzes
     set status = p_status,
         launched_at = case when p_status = 'live' then coalesce(launched_at, now()) when p_status = 'draft' then null else launched_at end,
         closed_at   = case when p_status = 'closed' then now() else null end,
         updated_at  = now()
   where activity_id = p_activity;
end $$;

-- ---------- attendee: send answers (once) ----------
create or replace function public.pt_quiz_submit(p_activity uuid, p_answers jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare q session_quizzes; i int; n int; pick int; sc int := 0;
begin
  if not pt_quiz_is_member(p_activity) then raise exception 'not_in_session'; end if;
  select * into q from session_quizzes where activity_id = p_activity;
  if not found or q.status <> 'live' then raise exception 'quiz_not_live'; end if;
  n := jsonb_array_length(q.questions);
  if jsonb_typeof(p_answers) <> 'array' or jsonb_array_length(p_answers) <> n then raise exception 'quiz_invalid'; end if;
  for i in 0..n-1 loop
    pick := coalesce((p_answers->>i)::int, -1);
    if pick = (q.questions->i->>'a')::int then sc := sc + 1; end if;
  end loop;
  insert into session_quiz_answers(activity_id, user_id, answers, score, total)
  values (p_activity, auth.uid(), p_answers, sc, n)
  on conflict (activity_id, user_id) do nothing;
  if not found then raise exception 'quiz_already_sent'; end if;
  return jsonb_build_object('score', sc, 'total', n);
end $$;

-- ---------- host: scoreboard + how many got each question right ----------
create or replace function public.pt_quiz_results(p_activity uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare q session_quizzes;
begin
  if not pt_quiz_is_host(p_activity) then raise exception 'not_host'; end if;
  select * into q from session_quizzes where activity_id = p_activity;
  if not found then return jsonb_build_object('people','[]'::jsonb,'right','[]'::jsonb); end if;
  return jsonb_build_object(
    'people', coalesce((select jsonb_agg(jsonb_build_object(
                 'user_id', a.user_id, 'name', coalesce(p.display_name,'Member'),
                 'score', a.score, 'total', a.total, 'at', a.submitted_at)
               order by a.score desc, a.submitted_at asc)
             from session_quiz_answers a left join profiles p on p.id = a.user_id
             where a.activity_id = p_activity), '[]'::jsonb),
    'right', (select coalesce(jsonb_agg(
                (select count(*) from session_quiz_answers a
                  where a.activity_id = p_activity and (a.answers->>(t.n-1)::int)::int = (t.x->>'a')::int)
              order by t.n), '[]'::jsonb)
              from jsonb_array_elements(q.questions) with ordinality as t(x, n)));
end $$;

grant execute on function
  public.pt_quiz_status_list(), public.pt_quiz_get(uuid), public.pt_quiz_save(uuid, jsonb),
  public.pt_quiz_delete(uuid), public.pt_quiz_set_status(uuid, text),
  public.pt_quiz_submit(uuid, jsonb), public.pt_quiz_results(uuid)
to authenticated;
revoke execute on function public.pt_quiz_is_host(uuid), public.pt_quiz_is_member(uuid) from anon;
