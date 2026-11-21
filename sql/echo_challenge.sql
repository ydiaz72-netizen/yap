-- =====================================================================
-- PonteTalk · 🎙️ Echo Challenge (voice challenges in the lounges)
-- Needs: lounges.sql, blocking.sql, word_fixed_bell.sql (notifications).
-- Run once in Supabase → SQL Editor. Safe to run again.
--
--   · A native or fluent speaker records a word or sentence and sets a
--     time window (1 hour to 7 days, starting within 14 days).
--   · Others record their echo (max 15 s by default). One entry each;
--     re-recording replaces it until the window closes.
--   · Everyone gets 3 likes per challenge. Likes stay hidden until the end.
--     Voting needs an account older than 24 h, except in challenges of
--     1 day or less: there, name + 18+ is enough (new people can vote at once).
--   · At the end: 🏆 People's choice (most likes, ties all win) and
--     ⭐ Host's pick (chosen by the host after the end).
--   · Limits: 1 live + up to 3 queued challenges per lounge,
--     1 active (live or queued) challenge per person.
--   · Bell only (no emails): "new challenge" to learners of that language
--     and to people who use the lounge; "results" to host + entrants.
--   · Voice files live in the private bucket "echo" and are deleted
--     14 days after the challenge ends.
-- =====================================================================

-- ---------- tables ----------
create table if not exists public.echo_challenges (
  id          uuid primary key default gen_random_uuid(),
  lounge_id   text not null references public.lounges(id) on delete cascade,
  language    text not null,
  host_id     uuid not null references auth.users(id) on delete cascade,
  phrase      text not null check (char_length(phrase) between 1 and 200),
  meaning     text check (char_length(meaning) <= 200),
  audio_path  text not null,
  max_sec     smallint not null default 15 check (max_sec between 5 and 30),
  starts_at   timestamptz not null,
  ends_at     timestamptz not null,
  host_pick   uuid,
  removed     boolean not null default false,
  announced   boolean not null default false,
  results_sent boolean not null default false,
  created_at  timestamptz not null default now(),
  check (ends_at > starts_at)
);
create index if not exists echo_challenges_lounge on public.echo_challenges(lounge_id, starts_at);

create table if not exists public.echo_entries (
  id           uuid primary key default gen_random_uuid(),
  challenge_id uuid not null references public.echo_challenges(id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  audio_path   text not null,
  duration_ms  int  not null check (duration_ms between 300 and 31000),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (challenge_id, user_id)
);

create table if not exists public.echo_likes (
  entry_id     uuid not null references public.echo_entries(id) on delete cascade,
  challenge_id uuid not null references public.echo_challenges(id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  created_at   timestamptz not null default now(),
  primary key (entry_id, user_id)
);
create index if not exists echo_likes_user on public.echo_likes(challenge_id, user_id);

alter table public.echo_challenges enable row level security;
alter table public.echo_entries    enable row level security;
alter table public.echo_likes      enable row level security;
revoke all on public.echo_challenges, public.echo_entries, public.echo_likes from anon, authenticated;

-- ---------- notification kinds (keeps every kind that already exists) ----------
do $$
declare ks text[];
begin
  select array(
    select k from unnest(array['seat_offer','join_request','approved','declined','cancelled','reminder_24h','reminder_15m',
      'new_joiner','changed','invited','chat','report','session_match','reschedule','reminder_prep','word_fixed',
      'echo_new','echo_result']) k
    union
    select distinct kind from public.notifications where kind is not null
  ) into ks;
  alter table public.notifications drop constraint if exists notifications_kind_check;
  execute format('alter table public.notifications add constraint notifications_kind_check check (kind = any (%L::text[]))', ks);
end $$;

-- ---------- voice storage: private bucket "echo" (max 2 MB per clip) ----------
insert into storage.buckets (id, name, public, file_size_limit)
values ('echo', 'echo', false, 2097152)
on conflict (id) do update set public = false, file_size_limit = 2097152;

-- Is this file still used by a challenge or an entry?
create or replace function public.pt_echo_referenced(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from echo_challenges where audio_path = p_name)
      or exists(select 1 from echo_entries where audio_path = p_name);
$$;
grant execute on function public.pt_echo_referenced(text) to authenticated;

drop policy if exists echo_files_read on storage.objects;
create policy echo_files_read on storage.objects for select to authenticated
  using (bucket_id = 'echo');

drop policy if exists echo_files_ins on storage.objects;
create policy echo_files_ins on storage.objects for insert to authenticated
  with check (bucket_id = 'echo' and (storage.foldername(name))[1] = auth.uid()::text);

-- Own files, or (for the cleanup) files nobody uses any more that are older than 2 days
drop policy if exists echo_files_del on storage.objects;
create policy echo_files_del on storage.objects for delete to authenticated
  using (bucket_id = 'echo' and (
         (storage.foldername(name))[1] = auth.uid()::text
      or (created_at < now() - interval '2 days' and not public.pt_echo_referenced(name))));

-- ---------- helpers ----------
create or replace function public.pt_echo_speaks(p_user uuid, p_lang text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from user_languages where user_id = p_user and language_code = p_lang
                and role in ('native','fluent'));
$$;

-- Can I start a challenge in this language? (native/fluent, name + 18+, account 7+ days; admins always)
create or replace function public.pt_echo_can_host(p_lang text)
returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (
    coalesce(public.pt_is_admin(), false)
    or (public.pt_echo_speaks(auth.uid(), p_lang)
        and public.pt_lounge_can_post()
        and exists(select 1 from auth.users where id = auth.uid() and created_at < now() - interval '7 days')));
$$;
grant execute on function public.pt_echo_can_host(text) to authenticated;

-- ---------- create ----------
create or replace function public.pt_echo_create(p_lounge text, p_language text, p_phrase text, p_meaning text,
                                                p_path text, p_max_sec int, p_starts timestamptz, p_ends timestamptz)
returns uuid language plpgsql security definer set search_path = public as $$
declare l lounges%rowtype; v_id uuid; v_phrase text := trim(coalesce(p_phrase,'')); v_busy timestamptz;
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  select * into l from lounges where id = p_lounge and active;
  if not found or p_language not in (l.lang_a, l.lang_b) then raise exception 'not_found'; end if;
  if not public.pt_echo_can_host(p_language) then raise exception 'echo_cannot_host'; end if;
  if char_length(v_phrase) < 1 or char_length(v_phrase) > 200 then raise exception 'echo_phrase'; end if;
  if p_path is null or split_part(p_path, '/', 1) <> auth.uid()::text then raise exception 'echo_audio'; end if;
  if p_starts < now() - interval '10 minutes' or p_starts > now() + interval '14 days' then raise exception 'echo_window'; end if;
  if p_ends - p_starts < interval '1 hour' or p_ends - p_starts > interval '7 days' then raise exception 'echo_window'; end if;
  -- 1 active challenge per person
  if exists(select 1 from echo_challenges where host_id = auth.uid() and not removed and ends_at > now()) then
    raise exception 'echo_one_each'; end if;
  -- no overlap in this lounge (1 live at a time)
  select max(ends_at) into v_busy from echo_challenges
   where lounge_id = p_lounge and not removed and ends_at > p_starts and starts_at < p_ends;
  if v_busy is not null then raise exception 'echo_busy: %', v_busy; end if;
  -- at most 3 waiting in the queue
  if (select count(*) from echo_challenges where lounge_id = p_lounge and not removed and starts_at > now()) >= 3 then
    raise exception 'echo_queue_full'; end if;
  insert into echo_challenges(lounge_id, language, host_id, phrase, meaning, audio_path, max_sec, starts_at, ends_at)
  values (p_lounge, p_language, auth.uid(), v_phrase, nullif(trim(coalesce(p_meaning,'')),''), p_path,
          greatest(5, least(30, coalesce(p_max_sec,15))), greatest(p_starts, now()), p_ends)
  returning id into v_id;
  return v_id;
end $$;
grant execute on function public.pt_echo_create(text,text,text,text,text,int,timestamptz,timestamptz) to authenticated;

-- First free start time in a lounge (end of the last challenge, or now)
create or replace function public.pt_echo_next_free(p_lounge text)
returns timestamptz language sql stable security definer set search_path = public as $$
  select greatest(now(), coalesce((select max(ends_at) from echo_challenges where lounge_id = p_lounge and not removed), now()));
$$;
grant execute on function public.pt_echo_next_free(text) to authenticated;

-- May I vote in this challenge? (24 h old account, or name + 18+ in short challenges)
create or replace function public.pt_echo_can_vote(p_challenge uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (
    exists(select 1 from auth.users where id = auth.uid() and created_at < now() - interval '24 hours')
    or (public.pt_lounge_can_post()
        and exists(select 1 from echo_challenges where id = p_challenge and ends_at - starts_at <= interval '24 hours 5 minutes')));
$$;

-- ---------- one challenge as JSON (likes hidden while live) ----------
create or replace function public.pt_echo_json(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c echo_challenges%rowtype; v_state text; v_top int; v_me uuid := auth.uid(); res jsonb;
begin
  select * into c from echo_challenges where id = p_id and not removed;
  if not found then return null; end if;
  v_state := case when now() < c.starts_at then 'upcoming' when now() < c.ends_at then 'live' else 'ended' end;
  select coalesce(max(n),0) into v_top from (select count(*) n from echo_likes where challenge_id = c.id group by entry_id) t;
  select jsonb_build_object(
    'id', c.id, 'lounge_id', c.lounge_id, 'language', c.language, 'host_id', c.host_id,
    'host_name', coalesce((select display_name from profiles where id = c.host_id), 'Member'),
    'phrase', c.phrase, 'meaning', c.meaning, 'audio_path', c.audio_path, 'max_sec', c.max_sec,
    'starts_at', c.starts_at, 'ends_at', c.ends_at, 'state', v_state, 'host_pick', c.host_pick,
    'entries_count', (select count(*) from echo_entries where challenge_id = c.id),
    'likes_given', (select count(*) from echo_likes where challenge_id = c.id),
    'my_likes', (select count(*) from echo_likes where challenge_id = c.id and user_id = v_me),
    'can_vote', public.pt_echo_can_vote(c.id),
    'short', c.ends_at - c.starts_at <= interval '24 hours 5 minutes',
    'entries', case when v_state = 'upcoming' then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', e.id, 'user_id', e.user_id, 'name', coalesce(p.display_name,'Member'), 'avatar_url', p.avatar_url,
        'audio_path', e.audio_path, 'duration_ms', e.duration_ms, 'mine', e.user_id = v_me,
        'liked', exists(select 1 from echo_likes k where k.entry_id = e.id and k.user_id = v_me),
        'likes', case when v_state = 'ended' then (select count(*) from echo_likes k where k.entry_id = e.id) end,
        'people_choice', v_state = 'ended' and v_top > 0 and (select count(*) from echo_likes k where k.entry_id = e.id) = v_top,
        'host_pick', e.id = c.host_pick)
        order by case when v_state = 'ended' then -(select count(*) from echo_likes k where k.entry_id = e.id) else 0 end,
                 case when e.user_id = v_me then 0 else 1 end, e.created_at)
      from echo_entries e left join profiles p on p.id = e.user_id
      where e.challenge_id = c.id and not public.pt_blocked_between(v_me, e.user_id)), '[]'::jsonb) end
  ) into res;
  return res;
end $$;

-- ---------- what the lounge shows: current (live or next), queue, last results ----------
create or replace function public.pt_echo_lounge(p_lounge text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare l lounges%rowtype; v_cur uuid; v_last uuid;
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  select * into l from lounges where id = p_lounge and active;
  if not found then raise exception 'not_found'; end if;
  select id into v_cur from echo_challenges
   where lounge_id = p_lounge and not removed and ends_at > now()
     and not public.pt_blocked_between(auth.uid(), host_id)
   order by starts_at limit 1;
  select id into v_last from echo_challenges
   where lounge_id = p_lounge and not removed and ends_at <= now() and ends_at > now() - interval '14 days'
     and not public.pt_blocked_between(auth.uid(), host_id)
   order by ends_at desc limit 1;
  return jsonb_build_object(
    'current', public.pt_echo_json(v_cur),
    'last',    public.pt_echo_json(v_last),
    'queue',   coalesce((select jsonb_agg(jsonb_build_object('id', id, 'language', language, 'phrase', phrase, 'starts_at', starts_at,
                          'host_name', coalesce((select display_name from profiles where id = host_id),'Member')) order by starts_at)
                         from echo_challenges where lounge_id = p_lounge and not removed and starts_at > now()
                           and id is distinct from v_cur), '[]'::jsonb),
    'can_host', jsonb_build_object(l.lang_a, public.pt_echo_can_host(l.lang_a), l.lang_b, public.pt_echo_can_host(l.lang_b)),
    'next_free', public.pt_echo_next_free(p_lounge),
    'mine_active', exists(select 1 from echo_challenges where host_id = auth.uid() and not removed and ends_at > now()),
    'can_post', public.pt_lounge_can_post());
end $$;
grant execute on function public.pt_echo_lounge(text) to authenticated;

-- ---------- enter (or re-record) · returns the old file path to delete ----------
create or replace function public.pt_echo_enter(p_challenge uuid, p_path text, p_duration_ms int)
returns text language plpgsql security definer set search_path = public as $$
declare c echo_challenges%rowtype; v_old text;
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  select * into c from echo_challenges where id = p_challenge and not removed;
  if not found then raise exception 'not_found'; end if;
  if now() < c.starts_at or now() >= c.ends_at then raise exception 'echo_closed'; end if;
  if c.host_id = auth.uid() then raise exception 'echo_own'; end if;
  if not public.pt_lounge_can_post() then raise exception 'lounge_profile_needed'; end if;
  if public.pt_blocked_between(auth.uid(), c.host_id) then raise exception 'not_found'; end if;
  if p_path is null or split_part(p_path, '/', 1) <> auth.uid()::text then raise exception 'echo_audio'; end if;
  if p_duration_ms is null or p_duration_ms < 300 or p_duration_ms > c.max_sec * 1000 + 1000 then raise exception 'echo_length'; end if;
  select audio_path into v_old from echo_entries where challenge_id = c.id and user_id = auth.uid();
  insert into echo_entries(challenge_id, user_id, audio_path, duration_ms)
  values (c.id, auth.uid(), p_path, p_duration_ms)
  on conflict (challenge_id, user_id) do update
     set audio_path = excluded.audio_path, duration_ms = excluded.duration_ms, updated_at = now();
  -- a new recording starts fresh: likes on the old one go
  if v_old is not null and v_old <> p_path then
    delete from echo_likes where entry_id = (select id from echo_entries where challenge_id = c.id and user_id = auth.uid());
  end if;
  return case when v_old is distinct from p_path then v_old end;
end $$;
grant execute on function public.pt_echo_enter(uuid,text,int) to authenticated;

-- ---------- like / unlike (3 per challenge, hidden until the end) ----------
create or replace function public.pt_echo_like(p_entry uuid, p_on boolean)
returns int language plpgsql security definer set search_path = public as $$
declare e echo_entries%rowtype; c echo_challenges%rowtype;
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  select * into e from echo_entries where id = p_entry;
  if not found then raise exception 'not_found'; end if;
  select * into c from echo_challenges where id = e.challenge_id and not removed;
  if not found then raise exception 'not_found'; end if;
  if now() < c.starts_at or now() >= c.ends_at then raise exception 'echo_closed'; end if;
  if e.user_id = auth.uid() then raise exception 'echo_own'; end if;
  if public.pt_blocked_between(auth.uid(), e.user_id) then raise exception 'not_found'; end if;
  if not public.pt_echo_can_vote(c.id) then raise exception 'echo_too_new'; end if;
  if p_on then
    if not exists(select 1 from echo_likes where entry_id = e.id and user_id = auth.uid()) then
      if (select count(*) from echo_likes where challenge_id = c.id and user_id = auth.uid()) >= 3 then
        raise exception 'echo_no_likes_left'; end if;
      insert into echo_likes(entry_id, challenge_id, user_id) values (e.id, c.id, auth.uid());
    end if;
  else
    delete from echo_likes where entry_id = e.id and user_id = auth.uid();
  end if;
  return 3 - (select count(*) from echo_likes where challenge_id = c.id and user_id = auth.uid())::int;
end $$;
grant execute on function public.pt_echo_like(uuid,boolean) to authenticated;

-- ---------- ⭐ Host's pick (after the end, within 7 days) ----------
create or replace function public.pt_echo_pick(p_entry uuid)
returns void language plpgsql security definer set search_path = public as $$
declare c echo_challenges%rowtype;
begin
  select c2.* into c from echo_challenges c2 join echo_entries e on e.challenge_id = c2.id where e.id = p_entry and not c2.removed;
  if not found or c.host_id <> auth.uid() then raise exception 'not_allowed'; end if;
  if now() < c.ends_at or now() > c.ends_at + interval '7 days' then raise exception 'echo_pick_time'; end if;
  update echo_challenges set host_pick = p_entry where id = c.id;
end $$;
grant execute on function public.pt_echo_pick(uuid) to authenticated;

-- ---------- remove a challenge (host or admin) / an entry (own or admin) ----------
create or replace function public.pt_echo_remove(p_challenge uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update echo_challenges set removed = true
   where id = p_challenge and (host_id = auth.uid() or coalesce(public.pt_is_admin(), false));
  if not found then raise exception 'not_allowed'; end if;
end $$;
grant execute on function public.pt_echo_remove(uuid) to authenticated;

create or replace function public.pt_echo_entry_remove(p_entry uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from echo_entries where id = p_entry and (user_id = auth.uid() or coalesce(public.pt_is_admin(), false));
  if not found then raise exception 'not_allowed'; end if;
end $$;
grant execute on function public.pt_echo_entry_remove(uuid) to authenticated;

-- ---------- 🚩 report a clip or a challenge (goes to the admin Reports page) ----------
create or replace function public.pt_echo_report(p_challenge uuid, p_entry uuid, p_reason text, p_details text)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_user uuid; v_phrase text; v_id bigint; r record;
begin
  if auth.uid() is null then raise exception 'sign_in_required'; end if;
  if (select count(*) from reports where reporter = auth.uid() and created_at > now() - interval '1 day') >= 10 then
    raise exception 'too_many_reports'; end if;
  if p_entry is not null then
    select e.user_id, c.phrase into v_user, v_phrase from echo_entries e join echo_challenges c on c.id = e.challenge_id where e.id = p_entry;
  else
    select host_id, phrase into v_user, v_phrase from echo_challenges where id = p_challenge;
  end if;
  if v_user is null or v_user = auth.uid() then raise exception 'not_found'; end if;
  insert into reports (reporter, target_type, target_user, reason, details)
  values (auth.uid(), 'user', v_user,
          case when p_reason in ('inappropriate','harassment','spam','unsafe','fake','other') then p_reason else 'other' end,
          left('Echo Challenge ' || case when p_entry is not null then 'clip ' || p_entry::text else 'challenge ' || p_challenge::text end
               || ' (“' || coalesce(v_phrase,'') || '”)' || coalesce(': ' || nullif(trim(coalesce(p_details,'')),''), ''), 500))
  returning id into v_id;
  for r in select user_id from admins loop
    perform public.pt_notify(r.user_id, 'report', null, 'report:' || v_id::text,
      jsonb_build_object('report_id', v_id, 'type', 'user', 'reason', p_reason));
  end loop;
  return v_id;
end $$;
grant execute on function public.pt_echo_report(uuid,uuid,text,text) to authenticated;

-- ---------- every minute: announce new challenges, send results, tidy up ----------
create or replace function public.pt_echo_tick()
returns int language plpgsql security definer set search_path = public as $$
declare c record; u record; n int := 0; v_top int; v_winners text;
begin
  -- 🔔 a challenge just went live → learners of that language + people active in the lounge
  for c in select * from echo_challenges where not removed and not announced and starts_at <= now() and ends_at > now() loop
    for u in
      select distinct x.uid from (
        select user_id uid from user_languages where language_code = c.language and role = 'learning'
        union select user_id from lounge_free where lounge_id = c.lounge_id
        union select user_id from lounge_messages where lounge_id = c.lounge_id and created_at > now() - interval '30 days'
      ) x
      where x.uid <> c.host_id and not public.pt_blocked_between(x.uid, c.host_id)
      limit 500
    loop
      perform public.pt_notify(u.uid, 'echo_new', null, 'echo_new:' || c.id::text,
        jsonb_build_object('from_user', c.host_id, 'lounge', c.lounge_id, 'challenge', c.id, 'phrase', c.phrase,
                           'language', c.language, 'ends_at', c.ends_at));
      n := n + 1;
    end loop;
    update notifications set email = false where kind = 'echo_new' and dedupe_key = 'echo_new:' || c.id::text and sent_at is null;
    update echo_challenges set announced = true where id = c.id;
  end loop;

  -- 🏆 a challenge ended → results to the host and everyone who entered
  for c in select * from echo_challenges where not removed and not results_sent and ends_at <= now() loop
    select coalesce(max(k),0) into v_top from (select count(*) k from echo_likes where challenge_id = c.id group by entry_id) t;
    select string_agg(coalesce(p.display_name,'Member'), ', ') into v_winners
      from echo_entries e left join profiles p on p.id = e.user_id
     where e.challenge_id = c.id and v_top > 0
       and (select count(*) from echo_likes k where k.entry_id = e.id) = v_top;
    for u in select c.host_id uid union select user_id from echo_entries where challenge_id = c.id loop
      perform public.pt_notify(u.uid, 'echo_result', null, 'echo_result:' || c.id::text,
        jsonb_build_object('lounge', c.lounge_id, 'challenge', c.id, 'phrase', c.phrase, 'winners', v_winners,
                           'host', u.uid = c.host_id));
      n := n + 1;
    end loop;
    update notifications set email = false where kind = 'echo_result' and dedupe_key = 'echo_result:' || c.id::text and sent_at is null;
    update echo_challenges set results_sent = true where id = c.id;
  end loop;

  -- 🧹 14 days after the end, the challenge and its clips go (files are removed by the app, see pt_echo_cleanup_list)
  delete from echo_challenges where ends_at < now() - interval '14 days' or (removed and created_at < now() - interval '2 days');
  return n;
end $$;
revoke all on function public.pt_echo_tick() from public, anon, authenticated;

-- Files nobody uses any more (older than 2 days). The app removes them quietly.
create or replace function public.pt_echo_cleanup_list()
returns text[] language sql stable security definer set search_path = public, storage as $$
  select coalesce(array_agg(o.name), '{}') from (
    select name from storage.objects
     where bucket_id = 'echo' and created_at < now() - interval '2 days' and not public.pt_echo_referenced(name)
     limit 50) o;
$$;
grant execute on function public.pt_echo_cleanup_list() to authenticated;

do $do$
begin
  begin perform cron.unschedule('pt-echo-tick'); exception when others then null; end;
  perform cron.schedule('pt-echo-tick', '* * * * *', 'select public.pt_echo_tick();');
  raise notice 'Echo Challenge job ready.';
exception when others then
  raise notice 'Could not start the Echo job (%). Turn on pg_cron in Database → Extensions, then run again.', sqlerrm;
end
$do$;

-- Done ✅
select 'Echo Challenge ready 🎙️' as status;
