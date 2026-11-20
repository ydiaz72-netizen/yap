-- =====================================================================
-- PonteTalk · Block accounts
-- Run once in Supabase → SQL Editor. Safe to run again.
-- (Run lounges.sql and lounge_who_free.sql before this one.)
--
-- When A blocks B (works both ways from then on):
--   * B can't join, request, waitlist or be invited to A's sessions, and A can't to B's
--   * Lounges: neither sees the other's messages or name next to free times
--   * B is never told. A can unblock anytime in Profile → Blocked people.
-- =====================================================================

create table if not exists public.user_blocks (
  blocker_id  uuid not null references auth.users(id) on delete cascade,
  blocked_id  uuid not null references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);
create index if not exists user_blocks_blocked on public.user_blocks(blocked_id);
alter table public.user_blocks enable row level security;
revoke all on public.user_blocks from anon, authenticated;

-- true if either person blocked the other
create or replace function public.pt_blocked_between(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select a is not null and b is not null and exists(
    select 1 from user_blocks
    where (blocker_id = a and blocked_id = b) or (blocker_id = b and blocked_id = a));
$$;

-- ---------- block / unblock / list ----------
create or replace function public.pt_block(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if p_user is null or p_user = auth.uid() then raise exception 'block_self'; end if;
  if not exists(select 1 from auth.users where id = p_user) then raise exception 'not_found'; end if;
  if (select count(*) from user_blocks where blocker_id = auth.uid()) >= 500 then raise exception 'too_many_blocks'; end if;
  insert into user_blocks(blocker_id, blocked_id) values (auth.uid(), p_user) on conflict do nothing;
  -- they disappear from my lounge free times right away
end $$;

create or replace function public.pt_unblock(p_user uuid)
returns void language sql security definer set search_path = public as $$
  delete from user_blocks where blocker_id = auth.uid() and blocked_id = p_user;
$$;

create or replace function public.pt_my_blocks()
returns table(user_id uuid, name text, avatar_url text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select b.blocked_id, coalesce(nullif(trim(p.display_name),''),'Member'), p.avatar_url, b.created_at
  from user_blocks b left join profiles p on p.id = b.blocked_id
  where b.blocker_id = auth.uid()
  order by b.created_at desc;
$$;

-- ---------- sessions: no joining / inviting across a block ----------
create or replace function public.pt_participants_block_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare host uuid;
begin
  if new.status in ('joined','pending','waitlisted','offered','invited')
     and (tg_op = 'INSERT' or old.status is distinct from new.status) then
    select host_id into host from activities where id = new.activity_id;
    if pt_blocked_between(new.user_id, host) then
      raise exception 'blocked_user';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists participants_block_guard on public.participants;
create trigger participants_block_guard
  before insert or update of status on public.participants
  for each row execute function public.pt_participants_block_guard();

-- ---------- lounges: hide messages across a block ----------
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
      and not pt_blocked_between(auth.uid(), m.user_id)
    order by m.id desc limit 100
  ) t order by t.id;
$$;

-- ---------- lounges: hide people across a block in "who is free" ----------
create or replace function public.pt_lounge_free_get(p_lounge text)
returns table(dow int, hour int, n int, mine boolean, people jsonb)
language sql stable security definer set search_path = public as $$
  select f.dow::int, f.hour::int, count(*)::int, bool_or(f.user_id = auth.uid()),
         jsonb_agg(jsonb_build_object('user_id', f.user_id,
                                      'name', coalesce(nullif(trim(p.display_name),''), 'Member'),
                                      'avatar_url', p.avatar_url)
                   order by (f.user_id = auth.uid()) desc, p.display_name)
  from lounge_free f
  left join profiles p on p.id = f.user_id
  where auth.uid() is not null and f.lounge_id = p_lounge
    and not pt_blocked_between(auth.uid(), f.user_id)
  group by f.dow, f.hour;
$$;

grant execute on function
  public.pt_block(uuid), public.pt_unblock(uuid), public.pt_my_blocks(),
  public.pt_lounge_messages(text, bigint), public.pt_lounge_free_get(text)
to authenticated;
revoke execute on function public.pt_blocked_between(uuid, uuid) from anon;
