-- =====================================================================
-- PonteTalk · Language lounges
-- Run once in Supabase → SQL Editor. Safe to run again.
--
-- One open chat room per language pair, where people talk and agree on times.
--   * Any signed-in member can read. Posting needs a name + 18+ confirmed.
--   * "Find a time": people mark weekly times they're free (stored in UTC);
--     everyone sees how many people are free when, never who.
--   * "Host this" creates a normal session; the lounge gets a card for it.
--   * New accounts (under 7 days) can't post links. Messages vanish after 30 days.
-- To add a lounge later: insert into lounges(id, lang_a, lang_b, sort) values ('fr-en','fr','en',5);
-- =====================================================================

create table if not exists public.lounges (
  id      text primary key,
  lang_a  text not null,
  lang_b  text not null,
  sort    int  not null default 0,
  active  boolean not null default true
);

insert into public.lounges(id, lang_a, lang_b, sort) values
  ('es-en','es','en',1), ('es-de','es','de',2), ('en-de','en','de',3), ('es-it','es','it',4)
on conflict (id) do nothing;

create table if not exists public.lounge_messages (
  id           bigserial primary key,
  lounge_id    text not null references public.lounges(id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  body         text not null check (length(body) between 1 and 500),
  kind         text not null default 'msg' check (kind in ('msg','session')),
  ref_activity uuid references public.activities(id) on delete cascade,
  created_at   timestamptz not null default now()
);
create index if not exists lounge_messages_room on public.lounge_messages(lounge_id, id);
create index if not exists lounge_messages_user on public.lounge_messages(user_id, created_at);
create unique index if not exists lounge_messages_one_card on public.lounge_messages(lounge_id, ref_activity) where ref_activity is not null;

create table if not exists public.lounge_free (
  lounge_id  text not null references public.lounges(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  dow        smallint not null check (dow between 0 and 6),    -- UTC day, 0 = Sunday
  hour       smallint not null check (hour between 0 and 23),  -- UTC hour
  primary key (lounge_id, user_id, dow, hour)
);

alter table public.lounges         enable row level security;
alter table public.lounge_messages enable row level security;
alter table public.lounge_free     enable row level security;
revoke all on public.lounges, public.lounge_messages, public.lounge_free from anon, authenticated;

-- Signed-in members may read messages directly (needed for live updates). Writes only via functions.
grant select on public.lounge_messages to authenticated;
drop policy if exists "members read lounge messages" on public.lounge_messages;
create policy "members read lounge messages" on public.lounge_messages
  for select to authenticated using (created_at > now() - interval '30 days');

-- Live updates
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'lounge_messages') then
    alter publication supabase_realtime add table public.lounge_messages;
  end if;
end $$;

-- ---------- helpers ----------
create or replace function public.pt_lounge_can_post()
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from profiles where id = auth.uid()
                and adult_confirmed_at is not null and coalesce(trim(display_name),'') <> '');
$$;

-- ---------- list of lounges ----------
create or replace function public.pt_lounges()
returns table(id text, lang_a text, lang_b text, msgs_7d int, last_at timestamptz, free_24h int, my_times int)
language sql stable security definer set search_path = public as $$
  with next24 as (
    select distinct extract(dow from h at time zone 'UTC')::int as dow, extract(hour from h at time zone 'UTC')::int as hour
    from generate_series(date_trunc('hour', now()) + interval '1 hour', date_trunc('hour', now()) + interval '24 hours', interval '1 hour') h
  )
  select l.id, l.lang_a, l.lang_b,
    (select count(*)::int from lounge_messages m where m.lounge_id = l.id and m.created_at > now() - interval '7 days'),
    (select max(m.created_at) from lounge_messages m where m.lounge_id = l.id),
    (select count(distinct f.user_id)::int from lounge_free f join next24 n on n.dow = f.dow and n.hour = f.hour where f.lounge_id = l.id),
    (select count(*)::int from lounge_free f where f.lounge_id = l.id and f.user_id = auth.uid())
  from lounges l where l.active and auth.uid() is not null
  order by l.sort, l.id;
$$;

-- ---------- messages (newest 100, or everything after p_after) ----------
create or replace function public.pt_lounge_messages(p_lounge text, p_after bigint default 0)
returns table(id bigint, user_id uuid, name text, avatar_url text, body text, kind text,
              ref_activity uuid, starts_at timestamptz, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select * from (
    select m.id, m.user_id, coalesce(p.display_name,'Member'), p.avatar_url, m.body, m.kind,
           m.ref_activity, a.starts_at, m.created_at
    from lounge_messages m
    left join profiles p on p.id = m.user_id
    left join activities a on a.id = m.ref_activity
    where auth.uid() is not null and m.lounge_id = p_lounge and m.id > coalesce(p_after,0)
      and m.created_at > now() - interval '30 days'
    order by m.id desc limit 100
  ) t order by t.id;
$$;

-- ---------- post ----------
create or replace function public.pt_lounge_post(p_lounge text, p_body text)
returns bigint language plpgsql security definer set search_path = public as $$
declare b text := trim(coalesce(p_body,'')); new_id bigint; joined timestamptz;
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if not exists(select 1 from lounges where id = p_lounge and active) then raise exception 'not_found'; end if;
  if not pt_lounge_can_post() then raise exception 'lounge_profile_needed'; end if;
  if length(b) < 1 or length(b) > 500 then raise exception 'lounge_length'; end if;
  if exists(select 1 from lounge_messages where user_id = auth.uid() and created_at > now() - interval '3 seconds')
     or (select count(*) from lounge_messages where user_id = auth.uid() and created_at > now() - interval '10 minutes') >= 20 then
    raise exception 'lounge_slow_down'; end if;
  select created_at into joined from auth.users where id = auth.uid();
  if joined > now() - interval '7 days' and b ~* '(https?://|www\.|\.(com|de|es|it|net|org|io|ly|me)(/|\s|$))' then
    raise exception 'lounge_no_links_yet'; end if;
  insert into lounge_messages(lounge_id, user_id, body) values (p_lounge, auth.uid(), b) returning id into new_id;
  delete from lounge_messages where created_at < now() - interval '30 days';
  return new_id;
end $$;

-- ---------- delete (own message, or admin) ----------
create or replace function public.pt_lounge_delete(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from lounge_messages where id = p_id
    and (user_id = auth.uid() or coalesce(pt_is_admin(), false));
  if not found then raise exception 'not_allowed'; end if;
end $$;

-- ---------- Find a time ----------
create or replace function public.pt_lounge_free_get(p_lounge text)
returns table(dow int, hour int, n int, mine boolean)
language sql stable security definer set search_path = public as $$
  select f.dow::int, f.hour::int, count(*)::int, bool_or(f.user_id = auth.uid())
  from lounge_free f where auth.uid() is not null and f.lounge_id = p_lounge
  group by f.dow, f.hour;
$$;

create or replace function public.pt_lounge_free_set(p_lounge text, p_dow int, p_hour int, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if not exists(select 1 from lounges where id = p_lounge and active) then raise exception 'not_found'; end if;
  if p_dow not between 0 and 6 or p_hour not between 0 and 23 then raise exception 'lounge_bad_time'; end if;
  if p_on then
    if not pt_lounge_can_post() then raise exception 'lounge_profile_needed'; end if;
    if (select count(*) from lounge_free where lounge_id = p_lounge and user_id = auth.uid()) >= 21 then raise exception 'lounge_too_many_times'; end if;
    insert into lounge_free values (p_lounge, auth.uid(), p_dow, p_hour) on conflict do nothing;
  else
    delete from lounge_free where lounge_id = p_lounge and user_id = auth.uid() and dow = p_dow and hour = p_hour;
  end if;
end $$;

-- ---------- after "Host this": post a session card in the lounge ----------
create or replace function public.pt_lounge_announce(p_lounge text, p_activity uuid)
returns void language plpgsql security definer set search_path = public as $$
declare a activities;
begin
  select * into a from activities where id = p_activity;
  if not found or a.host_id <> auth.uid() then raise exception 'not_allowed'; end if;
  if coalesce(a.visibility,'public') = 'private' or a.starts_at < now() then return; end if;
  if not exists(select 1 from lounges where id = p_lounge and active) then raise exception 'not_found'; end if;
  insert into lounge_messages(lounge_id, user_id, body, kind, ref_activity)
  values (p_lounge, auth.uid(), left(coalesce(nullif(trim(a.title),''),'Language exchange'), 500), 'session', p_activity)
  on conflict do nothing;
end $$;

grant execute on function
  public.pt_lounges(), public.pt_lounge_messages(text, bigint), public.pt_lounge_post(text, text),
  public.pt_lounge_delete(bigint), public.pt_lounge_free_get(text), public.pt_lounge_free_set(text, int, int, boolean),
  public.pt_lounge_announce(text, uuid), public.pt_lounge_can_post()
to authenticated;
