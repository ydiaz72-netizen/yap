-- =====================================================================
-- PonteTalk · Strikes (no-shows and late cancels)
-- Run once in Supabase → SQL Editor. Safe to run again.
-- Needs: join logic (step2), waitlist (step3), attendance (step18).
--
-- Uses the rules already in Settings (app_settings):
--   late_cancel_strike 0.5 · no_show_strike 1 · strike_window_days 30
--   block_rules [{strikes:2, days:7}, {strikes:3, days:30}]
--   strike_expiry_days 60 · passes_per_month 1
--
-- Strikes are worked out from what already happened (no extra table):
--   * leaving a session less than 2h before start  → late_cancel_strike
--   * marked no-show by the host                   → no_show_strike
--   * the first one(s) each month are covered by a free "life happens" pass
--   * sessions the host cancelled never count
--
-- NEW setting strike_blocks_on = 0 → WARN ONLY (pilot).
-- Set it to 1 later to switch blocking on:
--   update app_settings set value = '1' where key = 'strike_blocks_on';
-- =====================================================================

insert into public.app_settings(key, value)
values ('strike_blocks_on', '0'::jsonb)
on conflict (key) do nothing;

-- ---------- every strike event of one person (last N days) ----------
create or replace function public.pt_strike_events(p_user uuid)
returns table(activity_id uuid, title text, kind text, at timestamptz, weight numeric, waived boolean, expires_at timestamptz)
language sql stable security definer set search_path = public as $$
  with cfg as (
    select coalesce((select (value #>> '{}')::numeric from app_settings where key = 'late_cancel_strike'), 0.5) as late_w,
           coalesce((select (value #>> '{}')::numeric from app_settings where key = 'no_show_strike'), 1)       as ns_w,
           coalesce((select (value #>> '{}')::numeric::int from app_settings where key = 'strike_expiry_days'), 60) as exp_d,
           coalesce((select (value #>> '{}')::numeric::int from app_settings where key = 'passes_per_month'), 1)   as passes
  ), ev as (
    select p.activity_id, a.title::text as title,
           case when p.status = 'no_show' then 'no_show' else 'late_cancel' end as kind,
           case when p.status = 'no_show' then a.starts_at else p.updated_at end as at,
           case when p.status = 'no_show' then cfg.ns_w else cfg.late_w end as weight,
           cfg.exp_d, cfg.passes
      from participants p join activities a on a.id = p.activity_id cross join cfg
     where p.user_id = p_user
       and (p.status = 'no_show' or (p.status = 'cancelled' and p.late_cancel))
       and coalesce(a.status, '') <> 'cancelled'
  ), ranked as (
    select ev.*, row_number() over (partition by date_trunc('month', ev.at at time zone 'Europe/Berlin') order by ev.at, ev.activity_id) as n
      from ev
  )
  select r.activity_id, r.title, r.kind, r.at, r.weight,
         (r.n <= r.passes) as waived,
         r.at + make_interval(days => r.exp_d) as expires_at
    from ranked r
   where r.at > now() - make_interval(days => r.exp_d)
   order by r.at desc;
$$;
revoke all on function public.pt_strike_events(uuid) from public, anon, authenticated;

-- ---------- summary: strikes, would-be block, blocking on/off ----------
create or replace function public.pt_strike_status(p_user uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  win int := coalesce((select (value #>> '{}')::numeric::int from app_settings where key = 'strike_window_days'), 30);
  rules jsonb := coalesce((select value from app_settings where key = 'block_rules'), '[{"strikes":2,"days":7},{"strikes":3,"days":30}]'::jsonb);
  blocks_on boolean := coalesce((select (value #>> '{}')::numeric::int from app_settings where key = 'strike_blocks_on'), 0) = 1;
  passes int := coalesce((select (value #>> '{}')::numeric::int from app_settings where key = 'passes_per_month'), 1);
  e record; r jsonb; s numeric; until timestamptz := null; total numeric := 0; recent numeric := 0; used int;
begin
  -- a block starts at the strike that reaches a rule and lasts that rule's days
  for e in select * from pt_strike_events(p_user) where not waived order by at loop
    total := total + e.weight;
    select coalesce(sum(x.weight), 0) into s from pt_strike_events(p_user) x
     where not x.waived and x.at <= e.at and x.at > e.at - make_interval(days => win);
    for r in select * from jsonb_array_elements(rules) loop
      if s >= (r->>'strikes')::numeric then
        until := greatest(coalesce(until, e.at), e.at + make_interval(days => (r->>'days')::int));
      end if;
    end loop;
  end loop;
  select coalesce(sum(weight), 0) into recent from pt_strike_events(p_user)
   where not waived and at > now() - make_interval(days => win);
  select count(*) into used from pt_strike_events(p_user)
   where waived and date_trunc('month', at at time zone 'Europe/Berlin') = date_trunc('month', now() at time zone 'Europe/Berlin');
  if until is not null and until <= now() then until := null; end if;
  return jsonb_build_object(
    'strikes', total, 'recent', recent, 'window_days', win,
    'block_until', until, 'blocks_on', blocks_on, 'blocked', blocks_on and until is not null,
    'passes_left', greatest(passes - used, 0),
    'next_rule', (select x from jsonb_array_elements(rules) x where (x->>'strikes')::numeric > recent
                   order by (x->>'strikes')::numeric limit 1));
end $$;
revoke all on function public.pt_strike_status(uuid) from public, anon, authenticated;

-- ---------- my own strikes (Profile) ----------
create or replace function public.pt_my_strikes()
returns jsonb language sql stable security definer set search_path = public as $$
  select case when auth.uid() is null then null else
    pt_strike_status(auth.uid()) || jsonb_build_object('events',
      coalesce((select jsonb_agg(to_jsonb(e) order by e.at desc) from pt_strike_events(auth.uid()) e), '[]'::jsonb)) end;
$$;
grant execute on function public.pt_my_strikes() to authenticated;

-- ---------- block joining (only when strike_blocks_on = 1) ----------
create or replace function public.pt_strike_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare st jsonb;
begin
  if not (new.status in ('joined','pending','waitlisted','offered')
          and (tg_op = 'INSERT' or old.status is distinct from new.status)) then return new; end if;
  if coalesce((select (value #>> '{}')::numeric::int from app_settings where key = 'strike_blocks_on'), 0) <> 1 then return new; end if;
  -- someone already in (joined) who accepts an offer etc. is not re-checked for host-side moves
  if new.user_id is distinct from auth.uid() and tg_op = 'UPDATE' then return new; end if;
  st := pt_strike_status(new.user_id);
  if (st->>'blocked')::boolean then
    raise exception 'strike_block: %', to_char((st->>'block_until')::timestamptz at time zone 'Europe/Berlin', 'DD Mon');
  end if;
  return new;
end $$;

drop trigger if exists strike_guard on public.participants;
create trigger strike_guard before insert or update of status on public.participants
  for each row execute function public.pt_strike_guard();
