-- =====================================================================
-- PonteTalk · Step 39 · "Get ready" reminder 3 days before
--   · 72 hours before a session that has materials (links or
--     PonteShop resources), everyone who joined gets a reminder:
--     "Have a look at the materials. Want to focus on something?
--      Tell the host in the session chat."
--   · Sessions without materials don't get it (no extra emails).
--   · Uses the existing "Reminders" switch in Profile → Notifications.
--   · The 24-hour and 15-minute reminders stay exactly as before.
-- Needs Steps 8–38. Safe to run more than once.
-- =====================================================================

-- 1) New notification kind
alter table public.notifications drop constraint if exists notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check check (kind = any (array[
  'seat_offer','join_request','approved','declined','cancelled','reminder_24h','reminder_15m',
  'new_joiner','changed','invited','chat','report','session_match','reschedule','reminder_prep']));
-- (pt_wants already treats every 'reminder…' kind with the Reminders switch)

-- 2) Reminder job: 72 h "get ready" (only with materials) + 24 h + 15 min
create or replace function public.pt_queue_reminders()
returns int language plpgsql security definer set search_path = public as $$
declare
  r record; v_n int := 0;
begin
  -- 24 hours and 15 minutes before (host + everyone joined) — unchanged
  for r in
    select a.id, a.host_id, a.starts_at,
           case when a.starts_at between now() + interval '23 hours 50 minutes' and now() + interval '24 hours' then 'reminder_24h'
                when a.starts_at between now() + interval '10 minutes' and now() + interval '16 minutes' then 'reminder_15m'
           end as kind
      from public.activities a
     where a.status = 'scheduled'
       and (a.starts_at between now() + interval '23 hours 50 minutes' and now() + interval '24 hours'
            or a.starts_at between now() + interval '10 minutes' and now() + interval '16 minutes')
  loop
    perform public.pt_notify(r.host_id, r.kind, r.id, r.id::text || ':' || r.starts_at::text, '{"role":"host"}'::jsonb);
    perform public.pt_notify(p.user_id, r.kind, r.id, r.id::text || ':' || r.starts_at::text)
       from public.participants p where p.activity_id = r.id and p.status = 'joined';
    v_n := v_n + 1;
  end loop;

  -- 72 hours before: "get ready" — only sessions with materials, only joined guests
  for r in
    select a.id, a.host_id, a.starts_at
      from public.activities a
     where a.status = 'scheduled'
       and a.starts_at between now() + interval '71 hours 50 minutes' and now() + interval '72 hours'
       and exists (select 1 from public.activity_materials m where m.activity_id = a.id)
  loop
    perform public.pt_notify(p.user_id, 'reminder_prep', r.id, r.id::text || ':' || r.starts_at::text,
                             jsonb_build_object('from_user', r.host_id))
       from public.participants p
      where p.activity_id = r.id and p.status = 'joined' and p.user_id <> r.host_id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
revoke all on function public.pt_queue_reminders() from public, anon, authenticated;
grant execute on function public.pt_queue_reminders() to service_role;

-- 3) Emails: the "get ready" email may include the materials + video link
--    (same rule as before: only the host / people who joined)
drop function if exists public.pt_outbox(int);
create or replace function public.pt_outbox(p_limit int default 50)
returns table (
  id bigint, kind text, data jsonb, email text, name text, time_zone text,
  activity_id uuid, title text, starts_at timestamptz, duration_min smallint,
  language_a text, language_b text, type text, game text, from_name text,
  video_url text, materials jsonb, place jsonb
)
language sql stable security definer set search_path = public as $$
  select n.id, n.kind, n.data, u.email::text,
         coalesce(pr.display_name, ''), coalesce(pr.time_zone, 'Europe/Berlin'),
         a.id, a.title, a.starts_at, a.duration_min, a.language_a, a.language_b, a.type, a.game,
         (select p2.display_name from public.profiles p2 where p2.id = (n.data->>'from_user')::uuid),
         case when ok.ok then (select l.url from public.activity_links l where l.activity_id = a.id) end,
         case when ok.ok then (select coalesce(jsonb_agg(jsonb_build_object('label', m.label, 'url', m.url, 'shop', m.shop_item is not null) order by m.position), '[]'::jsonb)
                                 from public.activity_materials m where m.activity_id = a.id) end,
         case when ok.ok and a.format = 'in_person' then
           (select jsonb_build_object('name', a.place_name, 'area', a.area, 'city', a.city,
                                      'address', pl.address, 'directions', pl.directions)
              from (select 1) x left join public.activity_places pl on pl.activity_id = a.id) end
    from public.notifications n
    join auth.users u on u.id = n.user_id
    left join public.profiles pr on pr.id = n.user_id
    left join public.activities a on a.id = n.activity_id
    cross join lateral (select n.kind in ('approved','changed','reminder_24h','reminder_15m','reminder_prep')
                           and (a.host_id = n.user_id
                                or exists (select 1 from public.participants p
                                            where p.activity_id = a.id and p.user_id = n.user_id and p.status = 'joined')) as ok) ok
   where n.email and n.sent_at is null and n.attempts < 5
     and n.created_at > now() - interval '2 days'
   order by n.created_at
   limit p_limit;
$$;
revoke all on function public.pt_outbox(int) from public, anon, authenticated;
grant execute on function public.pt_outbox(int) to service_role;

-- Done ✅
select 'Get-ready reminder (3 days before) ready' as status;
