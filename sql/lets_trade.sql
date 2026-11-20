-- =====================================================================
-- PonteTalk · "🤝 Let's trade?" from Find partners
-- Run once in Supabase → SQL Editor. Safe to run again. (Needs partners.sql + blocking.sql.)
--
-- The app creates a private one-to-one session, then calls pt_trade_invite.
-- The partner gets a normal session invitation (Accept / Decline), exactly like 📩 Invite,
-- but without needing to have met before. Limits: 5 trade invites a day,
-- and the same person once a week. No free text, so nothing creepy can be sent.
-- =====================================================================

create table if not exists public.trade_log (
  id          bigserial primary key,
  from_id     uuid not null references auth.users(id) on delete cascade,
  to_id       uuid not null references auth.users(id) on delete cascade,
  activity_id uuid references public.activities(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index if not exists trade_log_from on public.trade_log(from_id, created_at);
alter table public.trade_log enable row level security;
revoke all on public.trade_log from anon, authenticated;

create or replace function public.pt_trade_invite(p_activity uuid, p_user uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a activities; nm text; cols text[]; actor text; sql text;
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if p_user = auth.uid() then raise exception 'cannot_invite_self'; end if;
  select * into a from activities where id = p_activity;
  if not found or a.host_id <> auth.uid() then raise exception 'not_allowed'; end if;
  if a.starts_at <= now() then raise exception 'not_open'; end if;
  if coalesce(a.visibility,'public') <> 'private' or a.seats <> 1 then raise exception 'trade_bad_session'; end if;
  if not exists(select 1 from profiles where id = auth.uid() and partner_visible) then raise exception 'partner_optin_needed'; end if;
  if not exists(select 1 from profiles where id = p_user and partner_visible and adult_confirmed_at is not null) then raise exception 'trade_not_available'; end if;
  if pt_blocked_between(auth.uid(), p_user) then raise exception 'trade_not_available'; end if;
  if (select count(*) from trade_log where from_id = auth.uid() and created_at > now() - interval '1 day') >= 5 then raise exception 'trade_daily_limit'; end if;
  if exists(select 1 from trade_log where from_id = auth.uid() and to_id = p_user and created_at > now() - interval '7 days') then raise exception 'trade_weekly_limit'; end if;

  insert into participants(activity_id, user_id, status) values (p_activity, p_user, 'invited');
  insert into trade_log(from_id, to_id, activity_id) values (auth.uid(), p_user, p_activity);

  -- Bell notification, like a normal invite (only if the app's notifications table looks as expected)
  begin
    select array_agg(column_name::text) into cols from information_schema.columns
      where table_schema = 'public' and table_name = 'notifications';
    if cols @> array['user_id','kind','activity_id']
       and not exists(select 1 from notifications where user_id = p_user and activity_id = p_activity and kind = 'invited') then
      actor := (select c from unnest(array['actor_id','from_user_id','from_user','sender_id','from_id']) c where c = any(cols) limit 1);
      if actor is null then
        execute 'insert into public.notifications(user_id, kind, activity_id) values ($1, $2, $3)' using p_user, 'invited', p_activity;
      else
        sql := format('insert into public.notifications(user_id, kind, activity_id, %I) values ($1, $2, $3, $4)', actor);
        execute sql using p_user, 'invited', p_activity, auth.uid();
      end if;
    end if;
  exception when others then null;   -- the invitation still shows on their Home screen
  end;

  select display_name into nm from profiles where id = p_user;
  return jsonb_build_object('status','invited','name',coalesce(nm,'They'));
end $$;

grant execute on function public.pt_trade_invite(uuid, uuid) to authenticated;
