-- PonteTalk QA-01: time zones (Berlin ↔ New York, the weeks the clocks change)
-- Safe to run in Supabase → SQL Editor. Everything is rolled back at the end.
-- 2026 clock changes: USA Mar 8 + Nov 1, EU Mar 29 + Oct 25. Between those dates Berlin–New York is 5 h apart
-- instead of the usual 6 h — that's when wrong maths shows up.

create temp table if not exists qa_results(n serial, test text, ok boolean, got text);
truncate qa_results;

do $qa$
declare
  ber uuid := gen_random_uuid(); ny uuid := gen_random_uuid(); host uuid := gen_random_uuid(); act uuid := gen_random_uuid();
  res text[] := '{}'; v text;
begin
  begin
    insert into auth.users(id, email) values (ber,'qa-ber@test.invalid'),(ny,'qa-ny@test.invalid'),(host,'qa-host@test.invalid');
    insert into profiles(id, display_name, time_zone, adult_confirmed_at) values
      (ber,'QA Berlin','Europe/Berlin',now()),(ny,'QA NewYork','America/New_York',now()),(host,'QA Host','Europe/Berlin',now())
      on conflict (id) do update set time_zone = excluded.time_zone, adult_confirmed_at = now();
    -- Free times are saved in each person's own clock. weekday 0 = Monday.
    insert into availability(user_id, weekday, start_time, end_time) values
      (ber, 0, '18:00', '20:00'),     -- Berlin person: Mondays 18–20 Berlin time
      (ny,  0, '13:00', '15:00');     -- New York person: Mondays 13–15 New York time

    -- A Monday 18:00 Berlin session, in three different weeks (stored in UTC)
    --   Mar 2  = both on winter time → 17:00 UTC, NY 12:00
    --   Mar 16 = USA already on summer time, EU not yet → 17:00 UTC, NY 13:00
    --   Mar 30 = both on summer time → 16:00 UTC, NY 12:00
    v := to_char(timestamptz '2026-03-16 18:00 Europe/Berlin' at time zone 'UTC','HH24:MI');
    res := res || format('1. 18:00 Berlin on Mar 16 is saved as 17:00 UTC|%s|%s UTC', v='17:00', v);
    v := to_char(timestamptz '2026-03-30 18:00 Europe/Berlin' at time zone 'UTC','HH24:MI');
    res := res || format('2. 18:00 Berlin on Mar 30 (after EU change) is 16:00 UTC|%s|%s UTC', v='16:00', v);
    v := to_char(timestamptz '2026-03-16 18:00 Europe/Berlin' at time zone 'America/New_York','HH24:MI');
    res := res || format('3. New York sees the Mar 16 session at 13:00 (5 h gap week)|%s|%s', v='13:00', v);
    v := to_char(timestamptz '2026-03-02 18:00 Europe/Berlin' at time zone 'America/New_York','HH24:MI');
    res := res || format('4. New York sees the Mar 2 session at 12:00 (normal 6 h)|%s|%s', v='12:00', v);
    v := to_char(timestamptz '2026-10-26 18:00 Europe/Berlin' at time zone 'America/New_York','HH24:MI');
    res := res || format('5. Autumn gap week: Oct 26 18:00 Berlin = 13:00 New York|%s|%s', v='13:00', v);

    -- "Fits my free time" uses each person's own clock in every week
    res := res || format('6. Berlin person: Mon Mar 16 18:00 fits 18–20|%s|%s',
      pt_fits_time(ber, timestamptz '2026-03-16 18:00 Europe/Berlin', 60, 'Europe/Berlin'),
      pt_fits_time(ber, timestamptz '2026-03-16 18:00 Europe/Berlin', 60, 'Europe/Berlin'));
    res := res || format('7. Berlin person: Mon Mar 30 18:00 (summer time) still fits|%s|%s',
      pt_fits_time(ber, timestamptz '2026-03-30 18:00 Europe/Berlin', 60, 'Europe/Berlin'),
      pt_fits_time(ber, timestamptz '2026-03-30 18:00 Europe/Berlin', 60, 'Europe/Berlin'));
    res := res || format('8. New York person: Mar 16 session (13:00 NY) fits 13–15|%s|%s',
      pt_fits_time(ny, timestamptz '2026-03-16 18:00 Europe/Berlin', 60, 'America/New_York'),
      pt_fits_time(ny, timestamptz '2026-03-16 18:00 Europe/Berlin', 60, 'America/New_York'));
    res := res || format('9. New York person: Mar 2 session (12:00 NY) does NOT fit 13–15|%s|%s',
      not pt_fits_time(ny, timestamptz '2026-03-02 18:00 Europe/Berlin', 60, 'America/New_York'),
      pt_fits_time(ny, timestamptz '2026-03-02 18:00 Europe/Berlin', 60, 'America/New_York'));
    res := res || format('10. New York person: Mar 30 session (12:00 NY) does NOT fit|%s|%s',
      not pt_fits_time(ny, timestamptz '2026-03-30 18:00 Europe/Berlin', 60, 'America/New_York'),
      pt_fits_time(ny, timestamptz '2026-03-30 18:00 Europe/Berlin', 60, 'America/New_York'));
    res := res || format('11. Ending later than the free time does NOT fit (19:30–20:30)|%s|%s',
      not pt_fits_time(ber, timestamptz '2026-03-16 19:30 Europe/Berlin', 60, 'Europe/Berlin'),
      pt_fits_time(ber, timestamptz '2026-03-16 19:30 Europe/Berlin', 60, 'Europe/Berlin'));

    -- The night the clock jumps (Sun Mar 29, 02:00 → 03:00 in Berlin): a 01:30 session lasting 60 min ends 03:30 Berlin
    v := to_char((timestamptz '2026-03-29 01:30 Europe/Berlin' + interval '60 minutes') at time zone 'Europe/Berlin','HH24:MI');
    res := res || format('12. Clock-change night: 01:30 + 60 min ends 03:30 Berlin|%s|%s', v='03:30', v);

    -- Session saved with the host's time zone shows the host's own clock
    insert into activities(id, host_id, title, language_a, starts_at, duration_min, seats, host_time_zone)
      values (act, host, 'QA tz', 'de', timestamptz '2026-10-26 18:00 Europe/Berlin', 60, 4, 'Europe/Berlin');
    select to_char(starts_at at time zone host_time_zone,'HH24:MI') into v from activities where id = act;
    res := res || format('13. Host still sees 18:00 in the autumn gap week|%s|%s', v='18:00', v);

    raise exception using errcode = 'QA000';
  exception when sqlstate 'QA000' then null;
            when others then res := res || format('❗ Test stopped early|false|%s', sqlerrm);
  end;
  insert into qa_results(test, ok, got)
    select split_part(x,'|',1), split_part(x,'|',2)::boolean, split_part(x,'|',3) from unnest(res) x;
end $qa$;

select case when ok then '✅' else '❌' end as " ", test as "QA-01 time zones (database)", got as "what happened" from qa_results order by n;
