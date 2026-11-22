-- PonteTalk QA-05: who may do what
-- Safe to run in Supabase → SQL Editor. Everything is rolled back at the end.

create temp table if not exists qa_results(n serial, test text, ok boolean, got text);
truncate qa_results;

do $qa$
declare
  h uuid := gen_random_uuid(); m uuid := gen_random_uuid(); x uuid := gen_random_uuid(); kid uuid := gen_random_uuid();
  bl uuid := gen_random_uuid(); kk uuid := gen_random_uuid();
  act uuid := gen_random_uuid(); live uuid := gen_random_uuid(); appr uuid := gen_random_uuid();
  res text[] := '{}'; msg text; n int;
begin
  begin
    insert into auth.users(id, email) select u, 'qa-'||left(u::text,8)||'@test.invalid' from unnest(array[h,m,x,kid,bl,kk]) u;
    insert into profiles(id, display_name, time_zone, adult_confirmed_at)
      select u, 'QA', 'Europe/Berlin', case when u = kid then null else now() end from unnest(array[h,m,x,kid,bl,kk]) u
      on conflict (id) do update set adult_confirmed_at = excluded.adult_confirmed_at;
    update app_settings set value = '0' where key = 'new_user_approval_sessions';
    insert into activities(id, host_id, title, language_a, language_b, starts_at, duration_min, seats, host_time_zone, join_mode) values
      (act,  h, 'QA perms',    'de', 'en', now() + interval '2 days',    60, 4, 'Europe/Berlin', 'instant'),
      (appr, h, 'QA approval', 'de', 'en', now() + interval '3 days',    60, 4, 'Europe/Berlin', 'approval'),
      (live, h, 'QA live',     'de', 'en', now() - interval '5 minutes', 60, 4, 'Europe/Berlin', 'instant');
    insert into participants(activity_id, user_id, status) values (live, m, 'joined');

    -- signed out
    perform set_config('request.jwt.claim.sub', '', true);
    begin perform pt_join_activity(act); msg := 'joined'; exception when others then msg := sqlerrm; end;
    res := res || format('1. Signed-out people can''t join|%s|%s', msg <> 'joined', msg);

    -- not 18+ confirmed
    perform set_config('request.jwt.claim.sub', kid::text, true);
    begin perform pt_join_activity(act); msg := 'joined'; exception when others then msg := sqlerrm; end;
    res := res || format('2. Without the 18+ confirmation you can''t join|%s|%s', msg like '%adult_required%', msg);

    -- host can't join own session
    perform set_config('request.jwt.claim.sub', h::text, true);
    begin perform pt_join_activity(act); msg := 'joined'; exception when others then msg := sqlerrm; end;
    res := res || format('3. Host can''t also join as a guest|%s|%s', msg like '%host_cannot_join%', msg);

    -- approvals: only the host
    perform set_config('request.jwt.claim.sub', x::text, true);  perform pt_join_activity(appr);
    perform set_config('request.jwt.claim.sub', m::text, true);
    begin perform pt_respond_request(appr, x, true); msg := 'approved'; exception when others then msg := sqlerrm; end;
    res := res || format('4. A guest can''t approve requests|%s|%s', msg like '%not_host%', msg);
    perform set_config('request.jwt.claim.sub', h::text, true);
    begin perform pt_respond_request(appr, x, true); msg := 'approved'; exception when others then msg := sqlerrm; end;
    res := res || format('5. The host can approve|%s|%s', msg = 'approved', msg);

    -- blocked person can't join the blocker's sessions (and the other way round)
    perform set_config('request.jwt.claim.sub', h::text, true);  perform pt_block(bl);
    perform set_config('request.jwt.claim.sub', bl::text, true);
    begin perform pt_join_activity(act); msg := 'joined'; exception when others then msg := sqlerrm; end;
    res := res || format('6. Someone the host blocked can''t join|%s|%s', msg like '%blocked%', msg);

    -- removed (kicked) person can't come back
    insert into participants(activity_id, user_id, status) values (act, kk, 'kicked');
    perform set_config('request.jwt.claim.sub', kk::text, true);
    begin perform pt_join_activity(act); msg := 'joined'; exception when others then msg := sqlerrm; end;
    res := res || format('7. Someone removed by the host can''t rejoin|%s|%s', msg like '%kicked%', msg);

    -- session room: everyone in the session switches, only the host pauses/resets, outsiders get nothing
    if to_regproc('public.pt_room_switch') is not null then
      perform set_config('request.jwt.claim.sub', m::text, true);
      begin perform pt_room_switch(live, 'de'); msg := 'switched'; exception when others then msg := sqlerrm; end;
      res := res || format('8. Guest in the session can switch the timer language|%s|%s', msg = 'switched', msg);
      begin perform pt_room_pause(live); msg := 'paused'; exception when others then msg := sqlerrm; end;
      res := res || format('9. Guest can''t pause the timer|%s|%s', msg like '%room_host_only%', msg);
      begin perform pt_room_reset(live); msg := 'reset'; exception when others then msg := sqlerrm; end;
      res := res || format('10. Guest can''t reset the timer|%s|%s', msg like '%room_host_only%', msg);
      perform set_config('request.jwt.claim.sub', h::text, true);
      begin perform pt_room_pause(live); msg := 'paused'; exception when others then msg := sqlerrm; end;
      res := res || format('11. Host can pause the timer|%s|%s', msg = 'paused', msg);
      perform set_config('request.jwt.claim.sub', x::text, true);
      begin perform pt_room_state(live); msg := 'saw it'; exception when others then msg := sqlerrm; end;
      res := res || format('12. Someone not in the session can''t see the room|%s|%s', msg like '%room_not_member%', msg);
    end if;

    -- direct table writes are closed (as a signed-in app user, not the admin console)
    perform set_config('request.jwt.claim.sub', m::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub', m::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    begin
      update participants set status = 'joined' where activity_id = act and user_id = kk;
      get diagnostics n = row_count; msg := n || ' rows changed';
    exception when others then msg := sqlerrm; end;
    res := res || format('13. A member can''t change other people''s seats directly|%s|%s', msg = '0 rows changed' or msg like '%denied%', msg);
    begin
      update activities set title = 'hacked' where id = act;
      get diagnostics n = row_count; msg := n || ' rows changed';
    exception when others then msg := sqlerrm; end;
    res := res || format('14. A member can''t edit someone else''s session|%s|%s', msg = '0 rows changed' or msg like '%denied%', msg);
    begin
      update app_settings set value = '99' where key = 'max_seats';
      get diagnostics n = row_count; msg := n || ' rows changed';
    exception when others then msg := sqlerrm; end;
    res := res || format('15. A member can''t change admin settings|%s|%s', msg = '0 rows changed' or msg like '%denied%', msg);
    execute 'reset role';

    raise exception using errcode = 'QA000';
  exception when sqlstate 'QA000' then null;
            when others then res := res || format('❗ Test stopped early|false|%s', sqlerrm);
  end;
  execute 'reset role';
  insert into qa_results(test, ok, got)
    select split_part(y,'|',1), split_part(y,'|',2)::boolean, split_part(y,'|',3) from unnest(res) y;
end $qa$;

select case when ok then '✅' else '❌' end as " ", test as "QA-05 permissions", got as "what happened" from qa_results order by n;
