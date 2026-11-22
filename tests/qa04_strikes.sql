-- PonteTalk QA-04: strike rules
-- Safe to run in Supabase → SQL Editor. Everything is rolled back at the end.
-- Rules (Settings): late cancel = ½, no-show = 1, 1 free pass a month, strikes expire after 60 days,
-- 2 strikes in 30 days = 7-day block, 3 = 30-day block. Blocks only stop joining when strike_blocks_on = 1.

create temp table if not exists qa_results(n serial, test text, ok boolean, got text);
truncate qa_results;

do $qa$
declare
  h uuid := gen_random_uuid(); u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid(); u3 uuid := gen_random_uuid();
  u4 uuid := gen_random_uuid(); u5 uuid := gen_random_uuid(); u6 uuid := gen_random_uuid();
  res text[] := '{}'; s jsonb; msg text; i int; act uuid; fut uuid := gen_random_uuid();
  -- make a past session for the host and give the user a no-show in it
  procedure_dummy int;
begin
  begin
    insert into auth.users(id, email) select x, 'qa-'||left(x::text,8)||'@test.invalid' from unnest(array[h,u1,u2,u3,u4,u5,u6]) x;
    insert into profiles(id, display_name, time_zone, adult_confirmed_at)
      select x, 'QA', 'Europe/Berlin', now() from unnest(array[h,u1,u2,u3,u4,u5,u6]) x
      on conflict (id) do update set adult_confirmed_at = now();
    update app_settings set value = '0' where key = 'new_user_approval_sessions';
    update app_settings set value = '0' where key = 'passes_per_month';      -- passes tested separately below
    update app_settings set value = '0' where key = 'strike_blocks_on';

    -- helper: no-show for user x, d days ago (each in its own past session)
    create temp table qa_ns(u uuid, d numeric, cancelled boolean default false) on commit drop;
    insert into qa_ns values (u1, 61, false), (u2, 5, false), (u2, 3, false), (u3, 5, false), (u3, 3, false), (u3, 1, false), (u4, 20, false), (u4, 19, false), (u5, 4, true);
    for i in 1..(select count(*) from qa_ns) loop
      act := gen_random_uuid();
      insert into activities(id, host_id, title, language_a, starts_at, duration_min, seats, host_time_zone, status)
        select act, h, 'QA past '||i, 'de', now() - make_interval(secs => (d*86400)::int), 60, 4, 'Europe/Berlin',
               case when cancelled then 'cancelled' else 'ended' end
          from (select *, row_number() over () rn from qa_ns) q where rn = i;
      insert into participants(activity_id, user_id, status)
        select act, u, 'no_show' from (select *, row_number() over () rn from qa_ns) q where rn = i;
    end loop;

    s := pt_strike_status(u6);
    res := res || format('1. Nobody starts with strikes|%s|%s', (s->>'strikes')::numeric = 0, s->>'strikes');
    s := pt_strike_status(u1);
    res := res || format('2. A no-show older than 60 days has expired|%s|%s strikes', (s->>'strikes')::numeric = 0, s->>'strikes');
    s := pt_strike_status(u5);
    res := res || format('3. Session cancelled by the host gives no strike|%s|%s strikes', (s->>'strikes')::numeric = 0, s->>'strikes');
    s := pt_strike_status(u2);
    res := res || format('4. Each no-show counts 1|%s|%s strikes', (s->>'strikes')::numeric = 2, s->>'strikes');
    res := res || format('5. 2 strikes in 30 days → 7-day block from the 2nd|%s|until %s',
       abs(extract(epoch from (s->>'block_until')::timestamptz - (now() + interval '4 days'))) < 120, to_char((s->>'block_until')::timestamptz,'DD Mon HH24:MI'));
    res := res || format('6. Warn-only mode: block shown but joining not stopped|%s|blocked=%s', (s->>'blocked')::boolean = false, s->>'blocked');
    s := pt_strike_status(u3);
    res := res || format('7. 3 strikes in 30 days → 30-day block|%s|until %s',
       abs(extract(epoch from (s->>'block_until')::timestamptz - (now() + interval '29 days'))) < 120, to_char((s->>'block_until')::timestamptz,'DD Mon HH24:MI'));
    s := pt_strike_status(u4);
    res := res || format('8. A block that already ended is gone|%s|until %s', s->>'block_until' is null, coalesce(s->>'block_until','—'));

    -- blocks switched on: a blocked person can't join, a past block doesn't stop anyone
    update app_settings set value = '1' where key = 'strike_blocks_on';
    insert into activities(id, host_id, title, language_a, starts_at, duration_min, seats, host_time_zone)
      values (fut, h, 'QA future', 'de', now() + interval '10 days', 60, 4, 'Europe/Berlin');
    perform set_config('request.jwt.claim.sub', u2::text, true);
    begin perform pt_join_activity(fut); msg := 'joined';
    exception when others then msg := sqlerrm; end;
    res := res || format('9. Blocks ON: blocked person can''t join|%s|%s', msg like 'strike_block%', msg);
    perform set_config('request.jwt.claim.sub', u4::text, true);
    begin perform pt_join_activity(fut); msg := 'joined';
    exception when others then msg := sqlerrm; end;
    res := res || format('10. Blocks ON: old block doesn''t stop joining|%s|%s', msg = 'joined', msg);
    update app_settings set value = '0' where key = 'strike_blocks_on';

    -- late cancel = ½, and the monthly free pass covers the first one
    perform set_config('request.jwt.claim.sub', u6::text, true);
    act := gen_random_uuid();
    insert into activities(id, host_id, title, language_a, starts_at, duration_min, seats, host_time_zone)
      values (act, h, 'QA soon', 'de', now() + interval '1 hour', 60, 4, 'Europe/Berlin');
    perform pt_join_activity(act); perform pt_leave_activity(act);
    s := pt_strike_status(u6);
    res := res || format('11. Leaving <2 h before = late cancel ½ strike|%s|%s strikes', (s->>'strikes')::numeric = 0.5, s->>'strikes');
    update app_settings set value = '1' where key = 'passes_per_month';
    s := pt_strike_status(u6);
    res := res || format('12. Free monthly pass covers the first one|%s|%s strikes, %s passes left', (s->>'strikes')::numeric = 0, s->>'strikes', s->>'passes_left');
    act := gen_random_uuid();
    insert into activities(id, host_id, title, language_a, starts_at, duration_min, seats, host_time_zone)
      values (act, h, 'QA early', 'de', now() + interval '3 days', 60, 4, 'Europe/Berlin');
    perform pt_join_activity(act); perform pt_leave_activity(act);
    s := pt_strike_status(u6);
    res := res || format('13. Leaving >2 h before is free|%s|%s strikes', (s->>'strikes')::numeric = 0, s->>'strikes');

    raise exception using errcode = 'QA000';
  exception when sqlstate 'QA000' then null;
            when others then res := res || format('❗ Test stopped early|false|%s', sqlerrm);
  end;
  insert into qa_results(test, ok, got)
    select split_part(x,'|',1), split_part(x,'|',2)::boolean, split_part(x,'|',3) from unnest(res) x;
end $qa$;

select case when ok then '✅' else '❌' end as " ", test as "QA-04 strike rules", got as "what happened" from qa_results order by n;
