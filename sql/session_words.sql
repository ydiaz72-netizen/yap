-- =====================================================================
-- PonteTalk · "Words I learned" (Learning loop, step 1)
-- Run once in Supabase → SQL Editor. Safe to run again.
--
-- How it works
--   * During or after a session, each person saves words/phrases they
--     learned: the word, what it means, and an optional example sentence.
--   * Words go straight into the student's list (later: the review quiz).
--   * Anyone else in the session (usually the native partner) can check
--     a word: ✓ looks good, or ✏️ fix it. A fix replaces the word and
--     keeps the original for history. Checking is optional.
--   * Only the host and people who joined/attended that session can see
--     its words (safety & privacy principle).
-- All access goes through the pt_words_* functions below (table is locked).
-- =====================================================================

create table if not exists public.session_words (
  id               uuid primary key default gen_random_uuid(),
  activity_id      uuid not null references public.activities(id) on delete cascade,
  user_id          uuid not null references auth.users(id) on delete cascade,
  lang             text not null,                 -- language of the word (e.g. 'de')
  word             text not null,
  meaning          text not null,
  example          text,
  status           text not null default 'unchecked' check (status in ('unchecked','confirmed','fixed')),
  checked_by       uuid references auth.users(id) on delete set null,
  checked_at       timestamptz,
  check_note       text,
  original_word    text,
  original_meaning text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists session_words_activity_idx on public.session_words(activity_id);
create index if not exists session_words_user_idx     on public.session_words(user_id, created_at desc);

alter table public.session_words enable row level security;
-- No policies on purpose: only the security-definer functions below can read/write.
revoke all on public.session_words from anon, authenticated;

-- ---------- helpers ----------
-- Host, or joined / attended
create or replace function public.pt_words_is_member(p_activity uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from activities where id = p_activity and host_id = auth.uid())
      or exists(select 1 from participants
                where activity_id = p_activity and user_id = auth.uid()
                  and status in ('joined','attended'));
$$;

-- Words open 30 minutes before the start (same as the pop quiz)
create or replace function public.pt_words_is_open(p_activity uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from activities
                where id = p_activity and status <> 'cancelled'
                  and starts_at - interval '30 minutes' <= now());
$$;

create or replace function public.pt_words_row(w session_words)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', w.id, 'activity_id', w.activity_id, 'lang', w.lang,
    'word', w.word, 'meaning', w.meaning, 'example', w.example,
    'status', w.status, 'check_note', w.check_note,
    'original_word', w.original_word, 'original_meaning', w.original_meaning,
    'created_at', w.created_at,
    'mine', w.user_id = auth.uid(),
    'user_id', w.user_id,
    'name', coalesce((select display_name from profiles where id = w.user_id), 'Member'),
    'checked_by_name', (select display_name from profiles where id = w.checked_by));
$$;

-- ---------- counts for the session cards ----------
-- n = all words in the session, mine = my words, to_check = others' unchecked words I could check
create or replace function public.pt_words_status_list()
returns table(activity_id uuid, n int, mine int, to_check int)
language sql stable security definer set search_path = public as $$
  select w.activity_id, count(*)::int,
         count(*) filter (where w.user_id = auth.uid())::int,
         count(*) filter (where w.user_id <> auth.uid() and w.status = 'unchecked')::int
  from session_words w
  where exists(select 1 from activities a where a.id = w.activity_id and a.host_id = auth.uid())
     or exists(select 1 from participants p where p.activity_id = w.activity_id
                and p.user_id = auth.uid() and p.status in ('joined','attended'))
  group by w.activity_id;
$$;

-- ---------- read the words of one session ----------
create or replace function public.pt_words_get(p_activity uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare a activities;
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if not pt_words_is_member(p_activity) then raise exception 'not_in_session'; end if;
  select * into a from activities where id = p_activity;
  return jsonb_build_object(
    'open', pt_words_is_open(p_activity),
    'langs', jsonb_build_array(a.language_a, a.language_b),
    'words', coalesce((select jsonb_agg(pt_words_row(w) order by w.created_at)
                         from session_words w where w.activity_id = p_activity), '[]'::jsonb));
end $$;

-- ---------- all my words, across sessions (for "My words") ----------
create or replace function public.pt_words_mine()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(pt_words_row(w) || jsonb_build_object('title', a.title, 'starts_at', a.starts_at)
                            order by a.starts_at desc, w.created_at), '[]'::jsonb)
  from session_words w join activities a on a.id = w.activity_id
  where w.user_id = auth.uid();
$$;

-- ---------- add a word ----------
create or replace function public.pt_words_add(p_activity uuid, p_lang text, p_word text, p_meaning text, p_example text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare a activities; nid uuid;
begin
  if not pt_words_is_member(p_activity) then raise exception 'not_in_session'; end if;
  if not pt_words_is_open(p_activity) then raise exception 'words_not_open'; end if;
  select * into a from activities where id = p_activity;
  if p_lang is null or p_lang not in (a.language_a, a.language_b) then raise exception 'words_invalid'; end if;
  p_word := trim(coalesce(p_word,'')); p_meaning := trim(coalesce(p_meaning,'')); p_example := nullif(trim(coalesce(p_example,'')),'');
  if length(p_word) < 1 or length(p_word) > 80 or length(p_meaning) < 1 or length(p_meaning) > 120
     or length(coalesce(p_example,'')) > 200 then raise exception 'words_invalid'; end if;
  if (select count(*) from session_words where activity_id = p_activity and user_id = auth.uid()) >= 30 then
    raise exception 'words_limit'; end if;
  insert into session_words(activity_id, user_id, lang, word, meaning, example)
  values (p_activity, auth.uid(), p_lang, p_word, p_meaning, p_example)
  returning id into nid;
  return nid;
end $$;

-- ---------- edit my own word (a checked word goes back to "not checked yet") ----------
create or replace function public.pt_words_edit(p_id uuid, p_lang text, p_word text, p_meaning text, p_example text default null)
returns void language plpgsql security definer set search_path = public as $$
declare w session_words; a activities;
begin
  select * into w from session_words where id = p_id;
  if not found or w.user_id <> auth.uid() then raise exception 'not_yours'; end if;
  select * into a from activities where id = w.activity_id;
  if p_lang is null or p_lang not in (a.language_a, a.language_b) then raise exception 'words_invalid'; end if;
  p_word := trim(coalesce(p_word,'')); p_meaning := trim(coalesce(p_meaning,'')); p_example := nullif(trim(coalesce(p_example,'')),'');
  if length(p_word) < 1 or length(p_word) > 80 or length(p_meaning) < 1 or length(p_meaning) > 120
     or length(coalesce(p_example,'')) > 200 then raise exception 'words_invalid'; end if;
  update session_words
     set lang = p_lang, word = p_word, meaning = p_meaning, example = p_example,
         status = case when word = p_word and meaning = p_meaning and lang = p_lang then status else 'unchecked' end,
         checked_by = case when word = p_word and meaning = p_meaning and lang = p_lang then checked_by end,
         checked_at = case when word = p_word and meaning = p_meaning and lang = p_lang then checked_at end,
         check_note = case when word = p_word and meaning = p_meaning and lang = p_lang then check_note end,
         updated_at = now()
   where id = p_id;
end $$;

-- ---------- delete my own word ----------
create or replace function public.pt_words_delete(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from session_words where id = p_id and user_id = auth.uid();
  if not found then raise exception 'not_yours'; end if;
end $$;

-- ---------- partner: ✓ confirm, or ✏️ fix someone else's word ----------
-- p_ok = true  → confirmed (word/meaning untouched)
-- p_ok = false → fixed: new word/meaning replace the old ones, originals kept
create or replace function public.pt_words_check(p_id uuid, p_ok boolean, p_word text default null, p_meaning text default null, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare w session_words;
begin
  select * into w from session_words where id = p_id;
  if not found then raise exception 'words_missing'; end if;
  if w.user_id = auth.uid() then raise exception 'words_own'; end if;
  if not pt_words_is_member(w.activity_id) then raise exception 'not_in_session'; end if;
  p_note := nullif(trim(coalesce(p_note,'')),'');
  if length(coalesce(p_note,'')) > 200 then raise exception 'words_invalid'; end if;
  if p_ok then
    update session_words set status = 'confirmed', checked_by = auth.uid(), checked_at = now(),
           check_note = p_note, updated_at = now() where id = p_id;
  else
    p_word := trim(coalesce(p_word,'')); p_meaning := trim(coalesce(p_meaning,''));
    if length(p_word) < 1 or length(p_word) > 80 or length(p_meaning) < 1 or length(p_meaning) > 120 then
      raise exception 'words_invalid'; end if;
    update session_words
       set original_word    = coalesce(original_word, word),
           original_meaning = coalesce(original_meaning, meaning),
           word = p_word, meaning = p_meaning,
           status = 'fixed', checked_by = auth.uid(), checked_at = now(),
           check_note = p_note, updated_at = now()
     where id = p_id;
  end if;
end $$;

grant execute on function
  public.pt_words_status_list(), public.pt_words_get(uuid), public.pt_words_mine(),
  public.pt_words_add(uuid, text, text, text, text), public.pt_words_edit(uuid, text, text, text, text),
  public.pt_words_delete(uuid), public.pt_words_check(uuid, boolean, text, text, text)
to authenticated;
revoke execute on function public.pt_words_is_member(uuid), public.pt_words_is_open(uuid),
  public.pt_words_row(public.session_words) from anon;

-- Done ✅
select 'Words I learned ready' as status;
