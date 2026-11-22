-- PonteTalk: Inbox — 1:1 messages between people who shared a session
-- Roadmap DB-11, BE-17 (front end FE-14). Run once in Supabase → SQL Editor. Safe to run again.
--
-- Rules
--   • You can message someone only if you were both in the same session (host or joined/attended).
--   • Blocked either way → no messages, and the conversation is hidden.
--   • Paused accounts can't send (same as chats). Adults only (18+ confirmed), signed in.
--   • Max 1,000 characters; max 30 messages per 10 minutes; new members (< 7 days) can't post links.
--   • The table is locked: everything goes through the pt_dm_* functions below.

create table if not exists public.direct_messages (
  id         bigserial primary key,
  sender     uuid not null references auth.users(id) on delete cascade,
  recipient  uuid not null references auth.users(id) on delete cascade,
  body       text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now(),
  read_at    timestamptz,
  deleted    boolean not null default false,
  check (sender <> recipient)
);
create index if not exists direct_messages_pair on public.direct_messages (least(sender, recipient), greatest(sender, recipient), created_at desc);
create index if not exists direct_messages_unread on public.direct_messages (recipient) where read_at is null;
alter table public.direct_messages enable row level security;   -- no policies: functions only

-- paused accounts can't send (reuses the account-hold guard; it checks new.user_id, so map sender)
create or replace function public.pt_dm_hold_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if pt_on_hold(new.sender) then raise exception 'account_on_hold'; end if;
  return new;
end $$;
drop trigger if exists dm_hold_guard on public.direct_messages;
create trigger dm_hold_guard before insert on public.direct_messages for each row execute function public.pt_dm_hold_guard();

-- did a and b share a session? (host or joined/attended, not cancelled sessions)
create or replace function public.pt_dm_shared(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = public as $$
  with sa as (
    select activity_id from participants where user_id = a and status in ('joined','attended')
    union select id from activities where host_id = a and coalesce(status,'') <> 'cancelled'
  )
  select a is not null and b is not null and a <> b and exists (
    select 1 from sa
     where exists (select 1 from participants p where p.activity_id = sa.activity_id and p.user_id = b and p.status in ('joined','attended'))
        or exists (select 1 from activities x where x.id = sa.activity_id and x.host_id = b and coalesce(x.status,'') <> 'cancelled'));
$$;

create or replace function public.pt_dm_allowed(p_other uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and pt_dm_shared(auth.uid(), p_other) and not pt_blocked_between(auth.uid(), p_other);
$$;

-- conversations list
create or replace function public.pt_dm_threads()
returns table(other uuid, name text, avatar_url text, last_body text, last_at timestamptz, last_mine boolean, unread int, can_send boolean)
language sql stable security definer set search_path = public as $$
  with me as (select auth.uid() as u),
  m as (
    select d.*, case when d.sender = (select u from me) then d.recipient else d.sender end as other
      from direct_messages d
     where (d.sender = (select u from me) or d.recipient = (select u from me))
  ), last as (
    select distinct on (other) other, body, created_at, sender = (select u from me) as mine, deleted
      from m order by other, created_at desc
  )
  select l.other, pr.display_name, pr.avatar_url,
         case when l.deleted then null else left(l.body, 120) end, l.created_at, l.mine,
         (select count(*)::int from m where m.other = l.other and m.recipient = (select u from me) and m.read_at is null and not m.deleted),
         pt_dm_allowed(l.other)
    from last l join profiles pr on pr.id = l.other
   where (select u from me) is not null and not pt_blocked_between((select u from me), l.other)
   order by l.created_at desc
   limit 100;
$$;

-- one conversation (newest 60, or older than p_before); marks incoming as read
create or replace function public.pt_dm_messages(p_other uuid, p_before bigint default null)
returns table(id bigint, mine boolean, body text, created_at timestamptz, read_at timestamptz, deleted boolean)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'sign_in_required'; end if;
  if pt_blocked_between(me, p_other) then raise exception 'blocked_user'; end if;
  update direct_messages dm set read_at = now()
   where dm.recipient = me and dm.sender = p_other and dm.read_at is null;
  return query
    select d.id, d.sender = me, case when d.deleted then null else d.body end, d.created_at, d.read_at, d.deleted
      from direct_messages d
     where ((d.sender = me and d.recipient = p_other) or (d.sender = p_other and d.recipient = me))
       and (p_before is null or d.id < p_before)
     order by d.id desc limit 60;
end $$;

create or replace function public.pt_dm_send(p_other uuid, p_body text)
returns bigint language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); b text := btrim(coalesce(p_body,'')); v bigint;
begin
  if me is null then raise exception 'sign_in_required'; end if;
  if not exists (select 1 from profiles where id = me and adult_confirmed_at is not null) then raise exception 'adult_required'; end if;
  if b = '' or char_length(b) > 1000 then raise exception 'dm_length'; end if;
  if not pt_dm_shared(me, p_other) then raise exception 'dm_not_allowed'; end if;
  if pt_blocked_between(me, p_other) then raise exception 'blocked_user'; end if;
  if (select count(*) from direct_messages where sender = me and created_at > now() - interval '10 minutes') >= 30 then
    raise exception 'slow_down';
  end if;
  if b ~* '(https?://|www\.)' and (select created_at from auth.users where id = me) > now() - interval '7 days' then
    raise exception 'links_new_user';
  end if;
  insert into direct_messages(sender, recipient, body) values (me, p_other, b) returning id into v;
  return v;
end $$;

create or replace function public.pt_dm_delete(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  update direct_messages set deleted = true where id = p_id and sender = auth.uid();
  if not found then raise exception 'not_found'; end if;
end $$;

create or replace function public.pt_dm_unread()
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from direct_messages d
   where d.recipient = auth.uid() and d.read_at is null and not d.deleted
     and not pt_blocked_between(d.sender, d.recipient);
$$;

-- people I can start a conversation with (shared a session, not blocked)
create or replace function public.pt_dm_contacts()
returns table(user_id uuid, name text, avatar_url text)
language sql stable security definer set search_path = public as $$
  with mine as (
    select activity_id from participants where user_id = auth.uid() and status in ('joined','attended')
    union select id from activities where host_id = auth.uid() and coalesce(status,'') <> 'cancelled'
  ), others as (
    select p.user_id from participants p join mine m on m.activity_id = p.activity_id where p.status in ('joined','attended')
    union select a.host_id from activities a join mine m on m.activity_id = a.id where coalesce(a.status,'') <> 'cancelled'
  )
  select pr.id, pr.display_name, pr.avatar_url
    from profiles pr join others o on o.user_id = pr.id
   where pr.id <> auth.uid() and pr.display_name is not null and not pt_blocked_between(auth.uid(), pr.id)
   order by lower(pr.display_name)
   limit 200;
$$;

revoke all on function public.pt_dm_shared(uuid,uuid), public.pt_dm_hold_guard() from public, anon, authenticated;
revoke all on function public.pt_dm_allowed(uuid), public.pt_dm_threads(), public.pt_dm_messages(uuid,bigint),
  public.pt_dm_send(uuid,text), public.pt_dm_delete(bigint), public.pt_dm_unread(), public.pt_dm_contacts() from public, anon;
grant execute on function public.pt_dm_allowed(uuid), public.pt_dm_threads(), public.pt_dm_messages(uuid,bigint),
  public.pt_dm_send(uuid,text), public.pt_dm_delete(bigint), public.pt_dm_unread(), public.pt_dm_contacts() to authenticated;

select 'Inbox ready' as status;
