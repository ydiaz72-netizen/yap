-- =====================================================================
-- PonteTalk · Vocabulary flashcards: progress + daily history
-- Run once in Supabase → SQL Editor. Safe to run again.
--
--   vocab_progress : one row per user × deck × word (spaced repetition state)
--   vocab_days     : one row per user × day (cards reviewed, correct, new words)
--   Signed-out users keep their progress on the phone instead.
-- =====================================================================

create table if not exists public.vocab_progress (
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  deck       text not null check (char_length(deck) <= 20),
  word_id    text not null check (char_length(word_id) <= 60),
  interval   real not null default 0,
  ease       real not null default 2.5,
  due        timestamptz not null default now(),
  reps       int  not null default 0,
  lapses     int  not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, deck, word_id)
);

create table if not exists public.vocab_days (
  user_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  day       date not null,
  reviews   int  not null default 0,
  correct   int  not null default 0,
  new_words int  not null default 0,
  primary key (user_id, day)
);

alter table public.vocab_progress enable row level security;
alter table public.vocab_days     enable row level security;

drop policy if exists vp_sel on public.vocab_progress;
drop policy if exists vp_ins on public.vocab_progress;
drop policy if exists vp_upd on public.vocab_progress;
drop policy if exists vp_del on public.vocab_progress;
create policy vp_sel on public.vocab_progress for select to authenticated using (user_id = auth.uid());
create policy vp_ins on public.vocab_progress for insert to authenticated with check (user_id = auth.uid());
create policy vp_upd on public.vocab_progress for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy vp_del on public.vocab_progress for delete to authenticated using (user_id = auth.uid());

drop policy if exists vd_sel on public.vocab_days;
drop policy if exists vd_ins on public.vocab_days;
drop policy if exists vd_upd on public.vocab_days;
drop policy if exists vd_del on public.vocab_days;
create policy vd_sel on public.vocab_days for select to authenticated using (user_id = auth.uid());
create policy vd_ins on public.vocab_days for insert to authenticated with check (user_id = auth.uid());
create policy vd_upd on public.vocab_days for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy vd_del on public.vocab_days for delete to authenticated using (user_id = auth.uid());

grant select, insert, update, delete on public.vocab_progress, public.vocab_days to authenticated;

-- Admin: how many people use flashcards
create or replace function public.pt_admin_vocab_stats()
returns json language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.pt_is_admin(), false) then raise exception 'not allowed'; end if;
  return json_build_object(
    'users',       (select count(distinct user_id) from public.vocab_days),
    'users_7d',    (select count(distinct user_id) from public.vocab_days where day > current_date - 7),
    'reviews_7d',  (select coalesce(sum(reviews),0) from public.vocab_days where day > current_date - 7),
    'words_known', (select count(*) from public.vocab_progress where reps > 0)
  );
end $$;
grant execute on function public.pt_admin_vocab_stats() to authenticated;
