-- =====================================================================
-- PonteTalk · 💡 Feedback button (ideas, bugs, anything) for the beta
-- Needs: word_fixed_bell.sql (notifications + pt_notify), account_holds.sql (admins, pt_is_admin).
-- Run once in Supabase → SQL Editor. Safe to run again.
--
--   * Anyone can send feedback, signed in or not (guests can leave an email).
--   * Each message saves the screen they were on, the app language and the device.
--   * Every admin gets a 🔔 bell (bell only, no email).
--   * Admins see the list in Profile → 🛠 → 💡 Feedback and mark it seen / done.
--   * Limits: 10 per hour per member, 30 per hour for all guests together.
-- =====================================================================

create table if not exists public.site_feedback (
  id          bigserial primary key,
  user_id     uuid references auth.users(id) on delete set null,
  kind        text not null check (kind in ('idea','bug','other')),
  message     text not null check (length(message) between 3 and 2000),
  contact     text check (contact is null or length(contact) <= 200),
  screen      text check (screen is null or length(screen) <= 40),
  ui          text check (ui is null or length(ui) <= 5),
  device      text check (device is null or length(device) <= 200),
  status      text not null default 'new' check (status in ('new','seen','done')),
  created_at  timestamptz not null default now()
);
create index if not exists site_feedback_new on public.site_feedback (status, created_at desc);
alter table public.site_feedback enable row level security;
revoke all on public.site_feedback from anon, authenticated;

-- allow the new bell kind (keeps every kind that already exists)
do $$
declare ks text[];
begin
  select array(
    select k from unnest(array['seat_offer','join_request','approved','declined','cancelled','reminder_24h','reminder_15m',
      'new_joiner','changed','invited','chat','report','session_match','reschedule','reminder_prep','word_fixed',
      'echo_new','echo_result','duel_done','new_member','feedback']) k
    union
    select distinct kind from public.notifications where kind is not null
  ) into ks;
  alter table public.notifications drop constraint if exists notifications_kind_check;
  execute format('alter table public.notifications add constraint notifications_kind_check check (kind = any (%L::text[]))', ks);
end $$;

-- ---------- send ----------
create or replace function public.pt_feedback_send(p_kind text, p_message text, p_contact text default null,
  p_screen text default null, p_ui text default null, p_device text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); msg text := trim(coalesce(p_message,'')); new_id bigint; a record;
begin
  if coalesce(p_kind,'') not in ('idea','bug','other') then raise exception 'feedback_bad_kind'; end if;
  if length(msg) < 3 then raise exception 'feedback_too_short'; end if;
  if me is not null then
    if (select count(*) from site_feedback where user_id = me and created_at > now() - interval '1 hour') >= 10 then
      raise exception 'feedback_too_many'; end if;
  else
    if (select count(*) from site_feedback where user_id is null and created_at > now() - interval '1 hour') >= 30 then
      raise exception 'feedback_too_many'; end if;
  end if;
  insert into site_feedback(user_id, kind, message, contact, screen, ui, device)
  values (me, p_kind, left(msg, 2000),
          nullif(left(trim(coalesce(p_contact,'')), 200), ''),
          nullif(left(coalesce(p_screen,''), 40), ''),
          nullif(left(coalesce(p_ui,''), 5), ''),
          nullif(left(coalesce(p_device,''), 200), ''))
  returning id into new_id;
  begin
    for a in select user_id from admins where user_id is distinct from me loop
      perform pt_notify(a.user_id, 'feedback', null, 'feedback:' || new_id,
        jsonb_build_object('id', new_id, 'kind', p_kind, 'text', left(msg, 80)));
      update notifications set email = false where user_id = a.user_id and kind = 'feedback' and sent_at is null;
    end loop;
  exception when others then null;   -- never lose feedback because of the bell
  end;
  return new_id;
end $$;
grant execute on function public.pt_feedback_send(text,text,text,text,text,text) to anon, authenticated;

-- ---------- admin: list, count, mark ----------
create or replace function public.pt_feedback_list(p_status text default null, p_limit int default 200)
returns table(id bigint, kind text, message text, contact text, screen text, ui text, device text, status text,
              created_at timestamptz, user_id uuid, name text, email text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(pt_is_admin(), false) then raise exception 'admins_only'; end if;
  return query
    select f.id, f.kind, f.message, f.contact, f.screen, f.ui, f.device, f.status, f.created_at, f.user_id,
           coalesce(nullif(trim(p.display_name),''), case when f.user_id is null then null else 'Member' end)::text,
           u.email::text
    from site_feedback f
    left join profiles p on p.id = f.user_id
    left join auth.users u on u.id = f.user_id
    where p_status is null or f.status = p_status
    order by (f.status = 'new') desc, f.created_at desc
    limit greatest(1, least(coalesce(p_limit,200), 500));
end $$;

create or replace function public.pt_feedback_count()
returns int language sql stable security definer set search_path = public as $$
  select case when coalesce(pt_is_admin(), false) then (select count(*)::int from site_feedback where status = 'new') else 0 end;
$$;

create or replace function public.pt_feedback_set(p_id bigint, p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(pt_is_admin(), false) then raise exception 'admins_only'; end if;
  if p_status not in ('new','seen','done') then raise exception 'feedback_bad_status'; end if;
  update site_feedback set status = p_status where id = p_id;
end $$;

revoke all on function public.pt_feedback_list(text,int) from anon;
revoke all on function public.pt_feedback_count() from anon;
revoke all on function public.pt_feedback_set(bigint,text) from anon;
grant execute on function public.pt_feedback_list(text,int), public.pt_feedback_count(), public.pt_feedback_set(bigint,text) to authenticated;

notify pgrst, 'reload schema';
