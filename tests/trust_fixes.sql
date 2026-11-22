-- PonteTalk: checks for sql/trust_fixes.sql (midnight free times, host late cancels, host remove).
-- Safe to run in Supabase → SQL Editor after trust_fixes.sql. Everything is rolled back.

create temp table if not exists qa_results(n serial, test text, ok boolean, got text); truncate qa_results;
do $qa$
declare h uuid:=gen_random_uuid(); g uuid:=gen_random_uuid(); w uuid:=gen_random_uuid(); x uuid:=gen_random_uuid(); n1 uuid:=gen_random_uuid();
  a1 uuid:=gen_random_uuid(); a2 uuid:=gen_random_uuid(); a3 uuid:=gen_random_uuid(); res text[]:='{}'; msg text; s jsonb; st text;
begin
 begin
  insert into auth.users(id,email) select u,'qa-'||left(u::text,8)||'@test.invalid' from unnest(array[h,g,w,x,n1]) u;
  insert into profiles(id,display_name,time_zone,adult_confirmed_at) select u,'QA','Europe/Berlin',now() from unnest(array[h,g,w,x,n1]) u on conflict(id) do update set adult_confirmed_at=now();
  update app_settings set value='0' where key='new_user_approval_sessions';
  update app_settings set value='0' where key='passes_per_month';
  insert into availability(user_id,weekday,start_time,end_time) values (n1,4,'22:00','23:59:59'),(n1,5,'00:00','02:00'),(n1,0,'18:00','20:00');
  -- midnight: Fri Mar 20 2026 23:30 Berlin, 60 min
  res:=res||format('1. 23:30–00:30 Fri→Sat fits 22–24 + 0–2|%s|%s', pt_fits_time(n1, timestamptz '2026-03-20 23:30 Europe/Berlin',60,'Europe/Berlin'), pt_fits_time(n1, timestamptz '2026-03-20 23:30 Europe/Berlin',60,'Europe/Berlin'));
  res:=res||format('2. 23:30–01:30 Sun→Mon does NOT fit|%s|%s', not pt_fits_time(n1, timestamptz '2026-03-22 23:30 Europe/Berlin',120,'Europe/Berlin'), pt_fits_time(n1, timestamptz '2026-03-22 23:30 Europe/Berlin',120,'Europe/Berlin'));
  res:=res||format('3. Normal 18:00–19:00 Monday still fits|%s|%s', pt_fits_time(n1, timestamptz '2026-03-16 18:00 Europe/Berlin',60,'Europe/Berlin'), pt_fits_time(n1, timestamptz '2026-03-16 18:00 Europe/Berlin',60,'Europe/Berlin'));
  res:=res||format('4. Free time to 23:59 still fits Fri 22:30–23:30|%s|%s', pt_fits_time(n1, timestamptz '2026-03-20 22:30 Europe/Berlin',60,'Europe/Berlin'), pt_fits_time(n1, timestamptz '2026-03-20 22:30 Europe/Berlin',60,'Europe/Berlin'));
  -- host late cancel
  insert into activities(id,host_id,title,language_a,starts_at,duration_min,seats,host_time_zone) values
   (a1,h,'QA soon','de',now()+interval '30 minutes',30,1,'Europe/Berlin'),(a2,h,'QA later','de',now()+interval '2 days',60,1,'Europe/Berlin'),(a3,h,'QA empty','de',now()+interval '1 hour 30 minutes',30,4,'Europe/Berlin');
  perform set_config('request.jwt.claim.sub',g::text,true); perform pt_join_activity(a1); perform pt_join_activity(a2);
  perform set_config('request.jwt.claim.sub',w::text,true); perform pt_join_activity(a2);
  perform set_config('request.jwt.claim.sub',h::text,true);

  update activities set status='cancelled' where id=a3;
  s:=pt_strike_status(h);
  res:=res||format('5. Host cancelling an empty session <2 h = no strike|%s|%s', (s->>'strikes')::numeric=0, s->>'strikes');
  update activities set status='cancelled' where id=a1;
  s:=pt_strike_status(h);
  res:=res||format('6. Host cancelling with guests <2 h = ½ strike|%s|%s', (s->>'strikes')::numeric=0.5, s->>'strikes');
  s:=pt_strike_status(g);
  res:=res||format('7. Guests get no strike when the host cancels|%s|%s', (s->>'strikes')::numeric=0, s->>'strikes');
  -- remove
  perform set_config('request.jwt.claim.sub',x::text,true);
  begin perform pt_host_remove(a2,g); msg:='removed'; exception when others then msg:=sqlerrm; end;
  res:=res||format('8. A guest can''t remove people|%s|%s', msg like '%not_host%', msg);
  perform set_config('request.jwt.claim.sub',h::text,true);
  perform pt_host_remove(a2,g);
  select status into st from participants where activity_id=a2 and user_id=g;
  res:=res||format('9. Host removes a person|%s|%s', st='kicked', st);
  select status into st from participants where activity_id=a2 and user_id=w;
  res:=res||format('10. The seat goes to the next on the waitlist|%s|%s', st='offered', st);
  perform set_config('request.jwt.claim.sub',g::text,true);
  begin perform pt_join_activity(a2); msg:='joined'; exception when others then msg:=sqlerrm; end;
  res:=res||format('11. Removed person can''t join again|%s|%s', msg like '%kicked%', msg);
  raise exception using errcode='QA000';
 exception when sqlstate 'QA000' then null; when others then res:=res||format('❗ stopped|false|%s',sqlerrm); end;
 insert into qa_results(test,ok,got) select split_part(y,'|',1),split_part(y,'|',2)::boolean,split_part(y,'|',3) from unnest(res) y;
end $qa$;
select case when ok then '✅' else '❌' end as " ", test as "Trust fixes", got as "what happened" from qa_results order by n;
