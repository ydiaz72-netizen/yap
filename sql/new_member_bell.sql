-- =====================================================================
-- PonteTalk · 🔔 tell admins when a new person joins
-- Needs: word_fixed_bell.sql (notifications + pt_notify), account_holds.sql (admins).
-- Run once in Supabase → SQL Editor. Safe to run again.
--
-- When someone creates an account (first sign-in with their email code),
-- every admin gets a bell message: "👋 New member: name or email".
-- Bell only, no email. The person's email is shown to admins only.
-- =====================================================================

-- 1) allow the new notification kind (keeps every kind that already exists)
do $$
declare ks text[];
begin
  select array(
    select k from unnest(array['seat_offer','join_request','approved','declined','cancelled','reminder_24h','reminder_15m',
      'new_joiner','changed','invited','chat','report','session_match','reschedule','reminder_prep','word_fixed',
      'echo_new','echo_result','duel_done','new_member']) k
    union
    select distinct kind from public.notifications where kind is not null
  ) into ks;
  alter table public.notifications drop constraint if exists notifications_kind_check;
  execute format('alter table public.notifications add constraint notifications_kind_check check (kind = any (%L::text[]))', ks);
end $$;

-- 2) the trigger: runs when a new account is created
create or replace function public.pt_new_member_bell()
returns trigger language plpgsql security definer set search_path = public as $$
declare a record; total int;
begin
  select count(*) into total from auth.users;
  for a in select user_id from public.admins where user_id <> new.id loop
    perform public.pt_notify(a.user_id, 'new_member', null, 'new_member:' || new.id::text,
      jsonb_build_object('user', new.id, 'email', new.email, 'total', total));
    update public.notifications set email = false
     where user_id = a.user_id and kind = 'new_member' and sent_at is null;
  end loop;
  return new;
exception when others then
  return new;   -- never block a sign-up because of the bell
end $$;

drop trigger if exists pt_new_member_bell on auth.users;
create trigger pt_new_member_bell after insert on auth.users
  for each row execute function public.pt_new_member_bell();

notify pgrst, 'reload schema';
