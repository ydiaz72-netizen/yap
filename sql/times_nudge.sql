-- =====================================================================
-- PonteTalk · 📧 Nudge #2: members who have languages but NO free times
-- Needs: profile_nudge.sql (run it first). Run once in Supabase → SQL Editor. Safe to run again.
-- =====================================================================

-- remember nudges per type ('langs' or 'times')
alter table public.profile_nudges add column if not exists kind text not null default 'langs';
do $$ begin
  if not exists (select 1 from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any(c.conkey)
                 where c.conrelid = 'public.profile_nudges'::regclass and c.contype = 'p' and a.attname = 'kind') then
    alter table public.profile_nudges drop constraint if exists profile_nudges_pkey;
    alter table public.profile_nudges add primary key (user_id, kind);
  end if;
end $$;

-- allow the new bell kind
do $$
declare ks text[];
begin
  select array(select distinct k from (
      select unnest(array['seat_offer','join_request','approved','declined','cancelled','reminder_24h','reminder_15m',
        'new_joiner','changed','invited','chat','report','session_match','reschedule','reminder_prep','word_fixed',
        'echo_new','echo_result','duel_done','new_member','feedback','profile_nudge','times_nudge']) k
      union select distinct kind from public.notifications where kind is not null
      union select m[1] from pg_constraint c,
            regexp_matches(substring(pg_get_constraintdef(c.oid) from 'ANY \((.*)\)'), '([a-z][a-z0-9_]*)', 'g') m
            where c.conname = 'notifications_kind_check' and m[1] <> 'text') x) into ks;
  alter table public.notifications drop constraint if exists notifications_kind_check;
  execute format('alter table public.notifications add constraint notifications_kind_check check (kind = any (%L::text[]))', ks);
end $$;

drop function if exists public.pt_admin_incomplete();
drop function if exists public.pt_admin_nudge(uuid[]);
drop function if exists public.pt_admin_nudge_stats();

-- 'langs' = no languages · 'times' = has languages but no free times
create or replace function public.pt_admin_incomplete(p_kind text default 'langs')
returns table(user_id uuid, name text, email text, joined timestamptz, nudged_at timestamptz, times int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(pt_is_admin(), false) then raise exception 'admins_only'; end if;
  return query
    select u.id, nullif(trim(p.display_name),'')::text, u.email::text, u.created_at, n.nudged_at, coalesce(n.times,0)
    from auth.users u
    left join profiles p on p.id = u.id
    left join profile_nudges n on n.user_id = u.id and n.kind = p_kind
    where u.email is not null
      and u.id is distinct from auth.uid()
      and case when p_kind = 'times'
            then exists (select 1 from user_languages l where l.user_id = u.id)
                 and not exists (select 1 from availability a where a.user_id = u.id)
            else not exists (select 1 from user_languages l where l.user_id = u.id) end
    order by n.nudged_at nulls first, u.created_at desc;
end $$;

create or replace function public.pt_admin_nudge(p_ids uuid[], p_kind text default 'langs')
returns int language plpgsql security definer set search_path = public as $$
declare u uuid; n int := 0; k text := case when p_kind = 'times' then 'times' else 'langs' end;
        bell text := case when p_kind = 'times' then 'times_nudge' else 'profile_nudge' end;
begin
  if not coalesce(pt_is_admin(), false) then raise exception 'admins_only'; end if;
  foreach u in array coalesce(p_ids, '{}') loop
    insert into profile_nudges(user_id, kind) values (u, k)
      on conflict (user_id, kind) do update set nudged_at = now(), times = profile_nudges.times + 1;
    begin
      perform pt_notify(u, bell, null, bell || ':' || u || ':' || to_char(now(),'YYYY-MM-DD'), '{}'::jsonb);
      update notifications set email = false where user_id = u and kind = bell and sent_at is null;
    exception when others then null;
    end;
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.pt_admin_nudge_stats(p_kind text default 'langs')
returns table(nudged int, completed int)
language sql stable security definer set search_path = public as $$
  select case when coalesce(pt_is_admin(),false) then (select count(*)::int from profile_nudges where kind = coalesce(p_kind,'langs')) else 0 end,
         case when coalesce(pt_is_admin(),false) then (select count(*)::int from profile_nudges n where n.kind = coalesce(p_kind,'langs') and
              case when p_kind = 'times' then exists (select 1 from availability a where a.user_id = n.user_id)
                   else exists (select 1 from user_languages l where l.user_id = n.user_id) end) else 0 end;
$$;

revoke all on function public.pt_admin_incomplete(text), public.pt_admin_nudge(uuid[], text), public.pt_admin_nudge_stats(text) from anon;
grant execute on function public.pt_admin_incomplete(text), public.pt_admin_nudge(uuid[], text), public.pt_admin_nudge_stats(text) to authenticated;

notify pgrst, 'reload schema';
