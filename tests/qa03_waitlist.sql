-- PonteTalk QA-03: waitlist offer chain
-- Safe to run in Supabase → SQL Editor (or any copy of the database).
-- Everything it creates is rolled back at the end: no test users, sessions or emails are left behind.
-- Result: a table of checks with ✅ / ❌.

create temp table if not exists qa_results(n serial, test text, ok boolean, got text);
truncate qa_results;

do $qa$
declare
  h uuid := gen_random_uuid(); a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); c uuid := gen_random_uuid();
  act uuid := gen_random_uuid(); act2 uuid := gen_random_uuid();
  r jsonb; st text; pos int; exp timestamptz; res text[] := '{}'; msg text;
  procedure_ok boolean;
begin
  begin  -- everything inside this block is undone at the end
    -- setup: four adult test users, one session with 1 seat starting tomorrow
    insert into auth.users(id, email) values (h,'qa-h@test.invalid'),(a,'qa-a@test.invalid'),(b,'qa-b@test.invalid'),(c,'qa-c@test.invalid');
    insert into profiles(id, display_name, time_zone, adult_confirmed_at)
      select x, 'QA '||left(x::text,4), 'Europe/Berlin', now() from unnest(array[h,a,b,c]) x
      on conflict (id) do update set adult_confirmed_at = now(), time_zone = 'Europe/Berlin';
    update app_settings set value = '0' where key = 'new_user_approval_sessions';
    update app_settings set value = '30' where key = 'waitlist_confirm_minutes';
    insert into activities(id, host_id, title, language_a, language_b, starts_at, duration_min, seats, host_time_zone)
      values (act, h, 'QA waitlist', 'de', 'en', now() + interval '1 day', 60, 1, 'Europe/Berlin');

    -- 1. A takes the only seat
    perform set_config('request.jwt.claim.sub', a::text, true);
    r := pt_join_activity(act);
    res := res || format('1. First person gets the seat|%s|%s', r->>'status' = 'joined', r->>'status');

    -- 2. B and C go on the waitlist as #1 and #2
    perform set_config('request.jwt.claim.sub', b::text, true);  r := pt_join_activity(act);
    res := res || format('2. Second person → waitlist #1|%s|%s #%s', r->>'status'='waitlisted' and (r->>'position')::int=1, r->>'status', r->>'position');
    perform set_config('request.jwt.claim.sub', c::text, true);  r := pt_join_activity(act);
    res := res || format('3. Third person → waitlist #2|%s|%s #%s', r->>'status'='waitlisted' and (r->>'position')::int=2, r->>'status', r->>'position');

    -- 4. A leaves → B is offered the seat for 30 minutes, C moves up to #1
    perform set_config('request.jwt.claim.sub', a::text, true);  r := pt_leave_activity(act);
    select status, offer_expires_at into st, exp from participants where activity_id = act and user_id = b;
    res := res || format('4. Seat opens → next person is offered it|%s|%s', st = 'offered', st);
    res := res || format('5. Offer lasts 30 minutes|%s|%s min', abs(extract(epoch from exp - now())/60 - 30) < 1, round(extract(epoch from exp - now())/60));
    select waitlist_position into pos from participants where activity_id = act and user_id = c;
    res := res || format('6. Rest of the waitlist moves up|%s|C is #%s', pos = 1, pos);

    -- 7. B doesn't answer: offer expires → B drops out, C is offered
    update participants set offer_expires_at = now() - interval '1 second' where activity_id = act and user_id = b;
    perform pt_expire_offers();
    select status into st from participants where activity_id = act and user_id = b;
    res := res || format('7. Expired offer is taken back|%s|B: %s', st = 'cancelled', st);
    select status into st from participants where activity_id = act and user_id = c;
    res := res || format('8. Expired offer passes to the next person|%s|C: %s', st = 'offered', st);

    -- 9. C accepts within the window → joined
    perform set_config('request.jwt.claim.sub', c::text, true);  r := pt_accept_offer(act);
    select status into st from participants where activity_id = act and user_id = c;
    res := res || format('9. Accepting in time confirms the seat|%s|C: %s', st = 'joined', st);

    -- 10. Seat count is right: exactly 1 joined, nobody offered
    select count(*) filter (where status='joined') || ' joined, ' || count(*) filter (where status='offered') || ' offered'
      into msg from participants where activity_id = act;
    res := res || format('10. Never more people than seats|%s|%s', msg = '1 joined, 0 offered', msg);

    -- 11. Accepting AFTER the offer ran out does not give a seat
    insert into activities(id, host_id, title, language_a, starts_at, duration_min, seats, host_time_zone)
      values (act2, h, 'QA late accept', 'de', now() + interval '3 days', 60, 1, 'Europe/Berlin');
    perform set_config('request.jwt.claim.sub', a::text, true);  perform pt_join_activity(act2);
    perform set_config('request.jwt.claim.sub', b::text, true);  perform pt_join_activity(act2);
    perform set_config('request.jwt.claim.sub', a::text, true);  perform pt_leave_activity(act2);
    update participants set offer_expires_at = now() - interval '1 second' where activity_id = act2 and user_id = b;
    perform set_config('request.jwt.claim.sub', b::text, true);
    begin
      r := pt_accept_offer(act2); msg := coalesce(r->>'status', r::text);
    exception when others then msg := 'refused: ' || sqlerrm;
    end;
    select status into st from participants where activity_id = act2 and user_id = b;
    res := res || format('11. Late accept gets no seat|%s|%s → B: %s', st <> 'joined', msg, st);

    -- 12. Leaving the waitlist works and closes the gap
    perform set_config('request.jwt.claim.sub', a::text, true);  perform pt_join_activity(act);   -- A back on act's waitlist
    perform set_config('request.jwt.claim.sub', a::text, true);  perform pt_leave_activity(act);
    select status into st from participants where activity_id = act and user_id = a;
    res := res || format('12. Leaving the waitlist works|%s|A: %s', st = 'cancelled', st);

    raise exception using errcode = 'QA000';   -- undo everything above
  exception when sqlstate 'QA000' then null;
            when others then res := res || format('❗ Test stopped early|false|%s', sqlerrm);
  end;
  insert into qa_results(test, ok, got)
    select split_part(x,'|',1), split_part(x,'|',2)::boolean, split_part(x,'|',3) from unnest(res) x;
end $qa$;

select case when ok then '✅' else '❌' end as " ", test as "QA-03 waitlist offer chain", got as "what happened" from qa_results order by n;
