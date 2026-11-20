-- =====================================================================
-- PonteTalk · 🎯 Practice my words (Learning loop, step 2)
-- Needs sql/session_words.sql first. Run once in Supabase → SQL Editor.
-- Safe to run again.
--
-- How it works
--   * The app builds a 5-question quiz from the student's own saved words
--     (multiple choice, reverse, fill-in-the-blank, or a flashcard).
--   * After each quiz the results are saved here, per word.
--   * A word is "mastered" after 3 right answers in a row.
--     A wrong answer resets the streak (mastered stays earned).
--   * If the word or meaning changes (student edits it or a partner fixes
--     it), its progress starts again, so they practise the new version.
-- All access goes through the pt_words_progress / pt_words_practice_save
-- functions below (table is locked).
-- =====================================================================

create table if not exists public.word_practice (
  word_id     uuid primary key references public.session_words(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  streak      int  not null default 0,
  right_n     int  not null default 0,
  wrong_n     int  not null default 0,
  last_seen   timestamptz,
  mastered_at timestamptz
);
create index if not exists word_practice_user_idx on public.word_practice(user_id);

alter table public.word_practice enable row level security;
-- No policies on purpose: only the security-definer functions below can read/write.
revoke all on public.word_practice from anon, authenticated;

-- ---------- my progress on all my words ----------
create or replace function public.pt_words_progress()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.word_id, 'streak', p.streak, 'right', p.right_n, 'wrong', p.wrong_n,
           'last_seen', p.last_seen, 'mastered', p.mastered_at is not null)), '[]'::jsonb)
  from word_practice p where p.user_id = auth.uid();
$$;

-- ---------- save one quiz: [{ "id": "<word id>", "ok": true }, ...] ----------
-- Returns { "mastered_now": n, "progress": [...] } for the words in this quiz
create or replace function public.pt_words_practice_save(p_results jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare x jsonb; wid uuid; ok boolean; n_new int := 0; was boolean; ids uuid[] := '{}';
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if jsonb_typeof(p_results) <> 'array' or jsonb_array_length(p_results) < 1 or jsonb_array_length(p_results) > 20 then
    raise exception 'practice_invalid'; end if;
  for x in select * from jsonb_array_elements(p_results) loop
    begin wid := (x->>'id')::uuid; exception when others then raise exception 'practice_invalid'; end;
    if jsonb_typeof(x->'ok') <> 'boolean' then raise exception 'practice_invalid'; end if;
    ok := (x->>'ok')::boolean;
    if not exists(select 1 from session_words where id = wid and user_id = auth.uid()) then raise exception 'not_yours'; end if;
    if wid = any(ids) then continue; end if;   -- each word counts once per quiz
    ids := ids || wid;
    select mastered_at is not null into was from word_practice where word_id = wid;
    insert into word_practice(word_id, user_id, streak, right_n, wrong_n, last_seen, mastered_at)
    values (wid, auth.uid(), case when ok then 1 else 0 end, case when ok then 1 else 0 end,
            case when ok then 0 else 1 end, now(), null)
    on conflict (word_id) do update
      set streak  = case when ok then word_practice.streak + 1 else 0 end,
          right_n = word_practice.right_n + case when ok then 1 else 0 end,
          wrong_n = word_practice.wrong_n + case when ok then 0 else 1 end,
          last_seen = now(),
          mastered_at = case when word_practice.mastered_at is not null then word_practice.mastered_at
                             when ok and word_practice.streak + 1 >= 3 then now() end;
    if coalesce(was, false) = false and exists(select 1 from word_practice where word_id = wid and mastered_at is not null) then
      n_new := n_new + 1; end if;
  end loop;
  return jsonb_build_object('mastered_now', n_new,
    'progress', (select coalesce(jsonb_agg(jsonb_build_object(
                   'id', p.word_id, 'streak', p.streak, 'right', p.right_n, 'wrong', p.wrong_n,
                   'last_seen', p.last_seen, 'mastered', p.mastered_at is not null)), '[]'::jsonb)
                 from word_practice p where p.word_id = any(ids)));
end $$;

-- ---------- a changed word starts its progress again ----------
create or replace function public.pt_words_reset_progress()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.word is distinct from old.word or new.meaning is distinct from old.meaning or new.lang is distinct from old.lang then
    delete from word_practice where word_id = new.id;
  end if;
  return new;
end $$;
drop trigger if exists session_words_reset_progress on public.session_words;
create trigger session_words_reset_progress after update on public.session_words
  for each row execute function public.pt_words_reset_progress();

grant execute on function public.pt_words_progress(), public.pt_words_practice_save(jsonb) to authenticated;
revoke execute on function public.pt_words_reset_progress() from public, anon, authenticated;

-- Done ✅
select 'Practice my words ready' as status;
