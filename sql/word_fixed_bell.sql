-- =====================================================================
-- PonteTalk · 🔔 Bell when a partner fixes your word
-- Needs sql/session_words.sql first. Run once in Supabase → SQL Editor.
-- Safe to run again.
--
--   · When a partner taps ✏️ Fix on your word, you get a bell
--     notification: "Lena fixed your word “der Termin”: now “die Verabredung”."
--   · Bell only, no email (one email per word would be too many).
--   · Tapping it opens the words of that session.
-- =====================================================================

-- 1) Allow the new notification kind (keeps every kind that already exists)
do $$
declare ks text[];
begin
  select array(
    select k from unnest(array['seat_offer','join_request','approved','declined','cancelled','reminder_24h','reminder_15m',
      'new_joiner','changed','invited','chat','report','session_match','reschedule','reminder_prep','word_fixed']) k
    union
    select distinct kind from public.notifications where kind is not null
  ) into ks;
  alter table public.notifications drop constraint if exists notifications_kind_check;
  execute format('alter table public.notifications add constraint notifications_kind_check check (kind = any (%L::text[]))', ks);
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
    -- 🔔 Tell the student (bell only, no email). Needs sql/word_fixed_bell.sql.
    if exists(select 1 from pg_proc where proname = 'pt_notify') then
      perform public.pt_notify(w.user_id, 'word_fixed', w.activity_id, 'word_fixed:' || w.id::text || ':' || now()::text,
                               jsonb_build_object('from_user', auth.uid(), 'word', p_word, 'old', w.word));
      update public.notifications set email = false
       where user_id = w.user_id and kind = 'word_fixed' and sent_at is null;
    end if;
  end if;
end $$;


grant execute on function public.pt_words_check(uuid, boolean, text, text, text) to authenticated;

-- Done ✅
select 'Word-fixed bell ready' as status;
