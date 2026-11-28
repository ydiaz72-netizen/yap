-- =====================================================================
-- PonteTalk · 🤝 Invite friends: personal invite link + badge ladder
--   🌱 1 friend = Bridge Starter · 🌉 3 = Bridge Builder · 🏅 5 = Ambassador
-- A friend counts once they have joined with your link AND added their languages.
-- You get a 🔔 when a friend counts. Run once in Supabase → SQL Editor. Safe to run again.
-- =====================================================================
alter table public.profiles add column if not exists ref_code text;
create unique index if not exists profiles_ref_code_key on public.profiles(ref_code) where ref_code is not null;

create table if not exists public.referrals (
  referee    uuid primary key references auth.users(id) on delete cascade,
  referrer   uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  notified   boolean not null default false
);
create index if not exists referrals_referrer on public.referrals(referrer);
alter table public.referrals enable row level security;
revoke all on public.referrals from anon, authenticated;

-- allow the new bell kind (keeps every kind that already exists)
do $$
declare ks text[];
begin
  select array(select distinct k from (
      select unnest(array['ref_joined']) k
      union select distinct kind from public.notifications where kind is not null
      union select m[1] from pg_constraint c,
            regexp_matches(substring(pg_get_constraintdef(c.oid) from 'ANY \((.*)\)'), '([a-z][a-z0-9_]*)', 'g') m
            where c.conname = 'notifications_kind_check' and m[1] <> 'text') x) into ks;
  alter table public.notifications drop constraint if exists notifications_kind_check;
  execute format('alter table public.notifications add constraint notifications_kind_check check (kind = any (%L::text[]))', ks);
end $$;

-- my invite code (made on first use)
create or replace function public.pt_my_ref()
returns text language plpgsql security definer set search_path = public as $$
declare c text; me uuid := auth.uid(); tries int := 0;
begin
  if me is null then return null; end if;
  select ref_code into c from profiles where id = me;
  while c is null and tries < 20 loop
    c := translate(substr(md5(random()::text || clock_timestamp()::text || me::text), 1, 6), '01', 'xy');
    begin
      update profiles set ref_code = c where id = me and ref_code is null;
      if not found then select ref_code into c from profiles where id = me; end if;
    exception when unique_violation then c := null; tries := tries + 1;
    end;
  end loop;
  return c;
end $$;

-- a new member opened someone's invite link
create or replace function public.pt_ref_claim(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); r uuid; nm text;
begin
  if me is null then return jsonb_build_object('ok', false, 'why', 'sign_in'); end if;
  select id, nullif(split_part(trim(display_name),' ',1),'') into r, nm from profiles where ref_code = lower(trim(p_code));
  if r is null then return jsonb_build_object('ok', false, 'why', 'unknown'); end if;
  if r = me then return jsonb_build_object('ok', false, 'why', 'self'); end if;
  if exists (select 1 from referrals where referee = me) then return jsonb_build_object('ok', false, 'why', 'already'); end if;
  if (select created_at from auth.users where id = me) < now() - interval '7 days' then return jsonb_build_object('ok', false, 'why', 'old'); end if;
  insert into referrals(referee, referrer) values (me, r);
  perform pt_ref_check(me);
  return jsonb_build_object('ok', true, 'name', nm);
end $$;

-- when the friend has languages: tell the inviter once
create or replace function public.pt_ref_check(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare x record; n int; nm text;
begin
  select * into x from referrals where referee = p_user and not notified;
  if not found then return; end if;
  if not exists (select 1 from user_languages where user_id = p_user) then return; end if;
  update referrals set notified = true where referee = p_user;
  select count(*) into n from referrals f where f.referrer = x.referrer and exists (select 1 from user_languages l where l.user_id = f.referee);
  select nullif(split_part(trim(display_name),' ',1),'') into nm from profiles where id = p_user;
  begin
    perform pt_notify(x.referrer, 'ref_joined', null, 'ref_joined:' || p_user, jsonb_build_object('name', coalesce(nm,''), 'count', n));
    update notifications set email = false where user_id = x.referrer and kind = 'ref_joined' and sent_at is null;
  exception when others then null;
  end;
end $$;

create or replace function public.pt_ref_lang_trg()
returns trigger language plpgsql security definer set search_path = public as $$
begin perform pt_ref_check(new.user_id); return new; end $$;
drop trigger if exists trg_ref_lang on public.user_languages;
create trigger trg_ref_lang after insert on public.user_languages for each row execute function public.pt_ref_lang_trg();

-- my friends + counts for the badge ladder
create or replace function public.pt_my_ref_stats()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'code', (select ref_code from profiles where id = auth.uid()),
    'joined', (select count(*) from referrals where referrer = auth.uid()),
    'counted', (select count(*) from referrals f where f.referrer = auth.uid() and exists (select 1 from user_languages l where l.user_id = f.referee)),
    'friends', coalesce((select jsonb_agg(jsonb_build_object('name', coalesce(nullif(split_part(trim(p.display_name),' ',1),''),'?'),
                 'ok', exists (select 1 from user_languages l where l.user_id = f.referee), 'at', f.created_at) order by f.created_at desc)
               from referrals f left join profiles p on p.id = f.referee where f.referrer = auth.uid()), '[]'::jsonb));
$$;

revoke all on function public.pt_my_ref(), public.pt_ref_claim(text), public.pt_my_ref_stats(), public.pt_ref_check(uuid) from anon;
grant execute on function public.pt_my_ref(), public.pt_ref_claim(text), public.pt_my_ref_stats() to authenticated;
revoke all on function public.pt_ref_check(uuid) from authenticated;

notify pgrst, 'reload schema';
