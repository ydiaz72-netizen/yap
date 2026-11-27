-- =====================================================================
-- PonteTalk · 🌉 Bridge Report, step 1: remember each answer by skill
-- Every game answer (flashcards, Sentence Builder, Bridge Builder, Split or Stick,
-- verb game, Save the Pal) is saved for the signed-in learner, so the weekly
-- report can show "going well", "focus on X and Y" and the bridge position.
-- Run once in Supabase → SQL Editor. Safe to run again.
-- =====================================================================

create table if not exists public.learn_log (
  id      bigserial primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  at      timestamptz not null default now(),
  lang    text not null default 'de',
  game    text not null,           -- cards · sb · bb · split · conj · hangman
  skill   text not null,           -- vocab · gender · case:dat · sb:wohin · bb:<theme> …
  ok      boolean not null,
  item    text,                    -- the word / sentence asked
  wrong   text,                    -- what the learner wrote (only when wrong)
  right_a text,                    -- the right answer (only when wrong)
  secs    int not null default 0,  -- active seconds since the previous answer (max 120)
  lvl     text                     -- learner level at the time (A1 … C1)
);
create index if not exists learn_log_user_at on public.learn_log(user_id, at desc);
alter table public.learn_log enable row level security;
revoke all on public.learn_log from anon;
grant select on public.learn_log to authenticated;
grant usage, select on sequence public.learn_log_id_seq to authenticated;
drop policy if exists "own learn log" on public.learn_log;
create policy "own learn log" on public.learn_log for select to authenticated using (user_id = auth.uid());

-- the app sends answers in small batches
create or replace function public.pt_learn_add(p_rows jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if auth.uid() is null then return 0; end if;
  insert into learn_log(user_id, at, lang, game, skill, ok, item, wrong, right_a, secs, lvl)
  select auth.uid(),
         coalesce(least((r->>'at')::timestamptz, now()), now()),
         coalesce(left(r->>'lang', 5), 'de'),
         left(coalesce(r->>'g', '?'), 20),
         left(coalesce(r->>'s', '?'), 40),
         coalesce((r->>'ok')::boolean, false),
         left(r->>'i', 160), left(r->>'w', 240), left(r->>'r', 240),
         greatest(0, least(coalesce((r->>'t')::int, 0), 120)),
         left(r->>'lv', 4)
  from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) r
  limit 300;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.pt_learn_add(jsonb) from anon;
grant execute on function public.pt_learn_add(jsonb) to authenticated;

notify pgrst, 'reload schema';
