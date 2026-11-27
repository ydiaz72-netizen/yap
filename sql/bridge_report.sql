-- =====================================================================
-- PonteTalk · 🌉 Bridge Report, step 2: the numbers for "my report"
-- Needs: learn_log.sql. Run once in Supabase → SQL Editor. Safe to run again.
-- Returns this week (last 7 days) and the week before, for the signed-in learner only.
-- =====================================================================
create or replace function public.pt_bridge_report(p_tz text default 'Europe/Berlin')
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); tz text := coalesce(nullif(p_tz,''),'Europe/Berlin'); res jsonb;
begin
  if me is null then return null; end if;
  begin perform now() at time zone tz; exception when others then tz := 'Europe/Berlin'; end;
  with l as (select * from learn_log where user_id = me and at > now() - interval '14 days'),
  wk as (select *, case when at > now() - interval '7 days' then 'cur' else 'prev' end as w from l)
  select jsonb_build_object(
    'cur',  (select jsonb_build_object('n', count(*), 'ok', count(*) filter (where ok),
               'days', count(distinct (at at time zone tz)::date), 'secs', coalesce(sum(secs),0),
               'words', count(distinct item) filter (where game='cards' and skill='vocab' and ok),
               'sent', count(*) filter (where game in ('sb','bb') and ok),
               'dayset', coalesce(jsonb_agg(distinct to_char(at at time zone tz,'YYYY-MM-DD')),'[]'::jsonb))
             from wk where w='cur'),
    'prev', (select jsonb_build_object('n', count(*), 'ok', count(*) filter (where ok),
               'days', count(distinct (at at time zone tz)::date), 'secs', coalesce(sum(secs),0))
             from wk where w='prev'),
    'skills', coalesce((select jsonb_agg(jsonb_build_object('s', skill, 'w', w, 'n', n, 'ok', k))
             from (select skill, w, count(*) n, count(*) filter (where ok) k from wk group by skill, w) x), '[]'::jsonb),
    'mist', coalesce((select jsonb_agg(jsonb_build_object('s', skill, 'g', game, 'i', item, 'w', wrong, 'r', right_a) order by at desc)
             from (select distinct on (coalesce(item,'')) * from wk where w='cur' and not ok order by coalesce(item,''), at desc) m), '[]'::jsonb),
    'total', (select count(*) from learn_log where user_id = me)
  ) into res;
  return res;
end $$;
revoke all on function public.pt_bridge_report(text) from anon;
grant execute on function public.pt_bridge_report(text) to authenticated;
notify pgrst, 'reload schema';
