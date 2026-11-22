-- =====================================================================
-- PonteTalk · Account pause ("hold") after reports
-- Run once in Supabase → SQL Editor. Safe to run again. (Needs the reports step.)
--
--   * 3 different people report the same person within 30 days (open reports)
--     → the account is paused automatically and admins get a bell message
--   * Admins can also pause or lift a pause by hand (Reports page)
--   * While paused the person can still browse and sign in, but can't
--     host, join, request, chat in sessions or lounges, or post Echo entries
--   * The person sees a calm banner; they are never told who reported them
-- =====================================================================

create table if not exists public.account_holds (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  reason     text not null default 'reports' check (reason in ('reports','admin')),
  note       text check (char_length(note) <= 500),
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null
);
alter table public.account_holds enable row level security;
revoke all on public.account_holds from anon, authenticated;

create or replace function public.pt_on_hold(p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select p_user is not null and exists(select 1 from account_holds where user_id = p_user)
     and not coalesce((select exists(select 1 from admins a where a.user_id = p_user)), false);
$$;

-- ---------- my own status (for the banner) ----------
create or replace function public.pt_my_hold()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object('on_hold', exists(select 1 from account_holds where user_id = auth.uid()),
                           'since', (select created_at from account_holds where user_id = auth.uid()));
$$;
grant execute on function public.pt_my_hold() to authenticated;

-- ---------- automatic pause: 3 different reporters in 30 days ----------
create or replace function public.pt_reports_auto_hold()
returns trigger language plpgsql security definer set search_path = public as $$
declare n int; a record;
begin
  if new.target_user is null then return new; end if;
  select count(distinct reporter) into n from reports
   where target_user = new.target_user and status in ('open','reviewing')
     and created_at > now() - interval '30 days' and reporter is not null;
  if n >= 3 and not exists(select 1 from account_holds where user_id = new.target_user)
     and not exists(select 1 from admins where user_id = new.target_user) then
    insert into account_holds(user_id, reason, note) values (new.target_user, 'reports', n || ' different people reported this account')
      on conflict do nothing;
    for a in select user_id from admins loop
      perform pt_notify(a.user_id, 'report', null, 'hold:' || new.target_user::text || ':' || to_char(now(),'YYYYMMDDHH24MI'),
        json_build_object('hold', true, 'user', new.target_user, 'reports', n)::jsonb);
    end loop;
  end if;
  return new;
exception when others then
  return new;  -- never block a report because of the pause logic
end $$;

drop trigger if exists reports_auto_hold on public.reports;
create trigger reports_auto_hold after insert on public.reports
  for each row execute function public.pt_reports_auto_hold();

-- ---------- what a paused account can't do ----------
create or replace function public.pt_hold_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare who uuid;
begin
  if tg_table_name = 'participants' then
    if not (new.status in ('joined','pending','waitlisted','offered','invited')
            and (tg_op = 'INSERT' or old.status is distinct from new.status)) then return new; end if;
    who := new.user_id;
  elsif tg_table_name in ('activities','echo_challenges') then
    if tg_op <> 'INSERT' then return new; end if;
    who := new.host_id;
  else
    who := new.user_id;
  end if;
  if pt_on_hold(who) then raise exception 'account_on_hold'; end if;
  return new;
end $$;

drop trigger if exists hold_guard on public.participants;
create trigger hold_guard before insert or update of status on public.participants
  for each row execute function public.pt_hold_guard();
drop trigger if exists hold_guard on public.activities;
create trigger hold_guard before insert on public.activities
  for each row execute function public.pt_hold_guard();
drop trigger if exists hold_guard on public.session_messages;
create trigger hold_guard before insert on public.session_messages
  for each row execute function public.pt_hold_guard();
drop trigger if exists hold_guard on public.lounge_messages;
create trigger hold_guard before insert on public.lounge_messages
  for each row execute function public.pt_hold_guard();
do $$ begin
  if to_regclass('public.echo_entries') is not null then
    execute 'drop trigger if exists hold_guard on public.echo_entries';
    execute 'create trigger hold_guard before insert on public.echo_entries for each row execute function public.pt_hold_guard()';
  end if;
  if to_regclass('public.echo_challenges') is not null then
    execute 'drop trigger if exists hold_guard on public.echo_challenges';
    execute 'create trigger hold_guard before insert on public.echo_challenges for each row execute function public.pt_hold_guard()';
  end if;
end $$;

-- ---------- admin: list, pause, lift ----------
create or replace function public.pt_admin_holds()
returns table(user_id uuid, name text, email text, reason text, note text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(pt_is_admin(), false) then raise exception 'not_admin'; end if;
  return query
    select h.user_id, p.display_name::text, u.email::text, h.reason, h.note, h.created_at
      from account_holds h left join profiles p on p.id = h.user_id left join auth.users u on u.id = h.user_id
     order by h.created_at desc;
end $$;
grant execute on function public.pt_admin_holds() to authenticated;

create or replace function public.pt_admin_hold_set(p_user uuid, p_on boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(pt_is_admin(), false) then raise exception 'not_admin'; end if;
  if p_user is null then raise exception 'not_found'; end if;
  if p_on then
    if exists(select 1 from admins where user_id = p_user) then raise exception 'cannot_hold_admin'; end if;
    insert into account_holds(user_id, reason, note, created_by) values (p_user, 'admin', left(p_note, 500), auth.uid())
      on conflict (user_id) do update set reason = 'admin', note = coalesce(left(p_note, 500), account_holds.note), created_by = auth.uid();
  else
    delete from account_holds where user_id = p_user;
  end if;
end $$;
grant execute on function public.pt_admin_hold_set(uuid, boolean, text) to authenticated;
