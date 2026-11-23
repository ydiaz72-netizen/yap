-- =====================================================================
-- PonteTalk · ⚔️ Flashcard duel (VC-03 part 3)
-- Needs: vocab.sql, blocking.sql, word_fixed_bell.sql (notifications).
-- Run once in Supabase → SQL Editor. Safe to run again.
--
-- How it works
--   * Someone starts a duel: 10 words from one level. They play first.
--   * They send the link (pontetalk.setzio.com/?duel=CODE) to a friend.
--   * The friend plays the same 10 words. Most correct wins; if equal,
--     the faster one wins. Scores stay hidden until you have played.
--   * One challenger + one opponent per duel. Links last 7 days.
--   * The starter gets a 🔔 bell (no email) when the friend has played.
-- All access goes through the pt_duel_* functions (tables are locked).
-- =====================================================================

create table if not exists public.vocab_duels (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique check (code ~ '^[A-Z0-9]{6}$'),
  created_by uuid not null references auth.users(id) on delete cascade,
  level      text not null check (level in ('A1','A2','B1','B2','C1')),
  words      text[] not null check (array_length(words,1) between 5 and 10),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '7 days'
);
create index if not exists vocab_duels_creator_idx on public.vocab_duels(created_by, created_at desc);

create table if not exists public.vocab_duel_plays (
  duel_id     uuid not null references public.vocab_duels(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  score       int  not null check (score between 0 and 10),
  ms          int  not null check (ms between 0 and 3600000),
  finished_at timestamptz not null default now(),
  primary key (duel_id, user_id)
);
create index if not exists vocab_duel_plays_user_idx on public.vocab_duel_plays(user_id, finished_at desc);

alter table public.vocab_duels      enable row level security;
alter table public.vocab_duel_plays enable row level security;
-- No policies on purpose: only the functions below can read/write.
revoke all on public.vocab_duels, public.vocab_duel_plays from anon, authenticated;

-- 🔔 allow the new notification kind (keeps every kind that already exists)
do $$
declare ks text[];
begin
  select array(
    select k from unnest(array['seat_offer','join_request','approved','declined','cancelled','reminder_24h','reminder_15m',
      'new_joiner','changed','invited','chat','report','session_match','reschedule','reminder_prep','word_fixed',
      'echo_new','echo_result','duel_done']) k
    union
    select distinct kind from public.notifications where kind is not null
  ) into ks;
  alter table public.notifications drop constraint if exists notifications_kind_check;
  execute format('alter table public.notifications add constraint notifications_kind_check check (kind = any (%L::text[]))', ks);
end $$;

-- ---------- one duel as JSON (scores of others hidden until you have played) ----------
create or replace function public.pt_duel_json(d vocab_duels)
returns jsonb language sql stable security definer set search_path = public as $$
  with me as (select exists(select 1 from vocab_duel_plays where duel_id = d.id and user_id = auth.uid()) as played),
       opp as (select count(*) as n from vocab_duel_plays where duel_id = d.id and user_id <> d.created_by)
  select jsonb_build_object(
    'code', d.code, 'level', d.level, 'words', to_jsonb(d.words),
    'created_at', d.created_at, 'expires_at', d.expires_at, 'expired', d.expires_at < now(),
    'creator', d.created_by,
    'creator_name', coalesce((select display_name from profiles where id = d.created_by), 'Member'),
    'mine', d.created_by = auth.uid(),
    'me_played', (select played from me),
    'can_play', auth.uid() is not null
                and not (select played from me)
                and d.expires_at >= now()
                and (d.created_by = auth.uid() or (select n from opp) = 0)
                and not coalesce(pt_blocked_between(auth.uid(), d.created_by), false),
    'players', coalesce((
      select jsonb_agg(jsonb_build_object(
               'user_id', p.user_id,
               'name', coalesce(pr.display_name, 'Member'),
               'avatar_url', pr.avatar_url,
               'me', p.user_id = auth.uid(),
               'score', case when (select played from me) or p.user_id = auth.uid() then p.score end,
               'ms',    case when (select played from me) or p.user_id = auth.uid() then p.ms end,
               'finished_at', p.finished_at)
             order by p.finished_at)
      from vocab_duel_plays p left join profiles pr on pr.id = p.user_id
      where p.duel_id = d.id), '[]'::jsonb));
$$;

-- ---------- start a duel ----------
create or replace function public.pt_duel_create(p_level text, p_words text[])
returns text language plpgsql security definer set search_path = public as $$
declare v_code text; n int;
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if p_level not in ('A1','A2','B1','B2','C1') then raise exception 'duel_invalid'; end if;
  if p_words is null or array_length(p_words,1) is null or array_length(p_words,1) < 5 or array_length(p_words,1) > 10
     or (select count(distinct w) from unnest(p_words) w) <> array_length(p_words,1)
     or exists(select 1 from unnest(p_words) w where w !~ '^[a-z0-9-]{1,60}$') then
    raise exception 'duel_invalid'; end if;
  select count(*) into n from vocab_duels where created_by = auth.uid() and created_at > now() - interval '1 day';
  if n >= 30 then raise exception 'duel_limit'; end if;
  loop
    v_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    exit when length(v_code) = 6 and not exists(select 1 from vocab_duels where code = v_code);
  end loop;
  insert into vocab_duels(code, created_by, level, words) values (v_code, auth.uid(), p_level, p_words);
  return v_code;
end $$;

-- ---------- open a duel by code (anyone with the link can see who challenges them) ----------
create or replace function public.pt_duel_get(p_code text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d vocab_duels;
begin
  select * into d from vocab_duels where code = upper(trim(coalesce(p_code,'')));
  if not found then raise exception 'duel_missing'; end if;
  return pt_duel_json(d);
end $$;

-- ---------- save my result ----------
create or replace function public.pt_duel_finish(p_code text, p_score int, p_ms int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d vocab_duels; nw int; other record;
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  select * into d from vocab_duels where code = upper(trim(coalesce(p_code,''))) for update;
  if not found then raise exception 'duel_missing'; end if;
  if d.expires_at < now() then raise exception 'duel_expired'; end if;
  if exists(select 1 from vocab_duel_plays where duel_id = d.id and user_id = auth.uid()) then raise exception 'duel_played'; end if;
  if d.created_by <> auth.uid() and exists(select 1 from vocab_duel_plays where duel_id = d.id and user_id <> d.created_by) then
    raise exception 'duel_taken'; end if;
  if coalesce(pt_blocked_between(auth.uid(), d.created_by), false) then raise exception 'duel_blocked'; end if;
  nw := array_length(d.words,1);
  if p_score is null or p_score < 0 or p_score > nw or p_ms is null or p_ms < nw * 300 or p_ms > 3600000 then
    raise exception 'duel_invalid'; end if;
  insert into vocab_duel_plays(duel_id, user_id, score, ms) values (d.id, auth.uid(), p_score, p_ms);

  -- 🔔 tell the other player that the result is ready (bell only, no email)
  if exists(select 1 from pg_proc where proname = 'pt_notify') then
    for other in select user_id from vocab_duel_plays where duel_id = d.id and user_id <> auth.uid() loop
      perform public.pt_notify(other.user_id, 'duel_done', null, 'duel_done:' || d.id::text || ':' || other.user_id::text,
                               jsonb_build_object('from_user', auth.uid(), 'code', d.code));
      update public.notifications set email = false
       where user_id = other.user_id and kind = 'duel_done' and sent_at is null;
    end loop;
  end if;
  return pt_duel_json(d);
end $$;

-- ---------- my duels (last 20) ----------
create or replace function public.pt_duel_mine()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(pt_duel_json(d) order by d.created_at desc), '[]'::jsonb)
  from (select * from vocab_duels d
        where d.created_by = auth.uid()
           or exists(select 1 from vocab_duel_plays p where p.duel_id = d.id and p.user_id = auth.uid())
        order by d.created_at desc limit 20) d;
$$;

revoke execute on function public.pt_duel_json(vocab_duels) from public, anon, authenticated;
grant execute on function public.pt_duel_get(text) to anon, authenticated;
grant execute on function public.pt_duel_create(text, text[]), public.pt_duel_finish(text, int, int), public.pt_duel_mine() to authenticated;
revoke execute on function public.pt_duel_create(text, text[]), public.pt_duel_finish(text, int, int), public.pt_duel_mine() from anon;
