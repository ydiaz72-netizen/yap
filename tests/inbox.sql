-- PonteTalk: checks for sql/inbox.sql. Safe to run in Supabase → SQL Editor after inbox.sql. Everything is rolled back.
create temp table if not exists qa_results(n serial, test text, ok boolean, got text); truncate qa_results;
do $qa$
declare h uuid:=gen_random_uuid(); g uuid:=gen_random_uuid(); x uuid:=gen_random_uuid(); act uuid:=gen_random_uuid();
  res text[]:='{}'; msg text; n int; mid bigint; r record;
begin
 begin
  insert into auth.users(id,email,created_at) select u,'qa-'||left(u::text,8)||'@test.invalid', now()-interval '30 days' from unnest(array[h,g,x]) u;
  insert into profiles(id,display_name,time_zone,adult_confirmed_at) select u,'QA '||left(u::text,4),'Europe/Berlin',now() from unnest(array[h,g,x]) u
    on conflict(id) do update set adult_confirmed_at=now(), display_name=excluded.display_name;
  update app_settings set value='0' where key='new_user_approval_sessions';
  insert into activities(id,host_id,title,language_a,starts_at,duration_min,seats,host_time_zone) values (act,h,'QA dm','de',now()+interval '2 days',60,4,'Europe/Berlin');
  perform set_config('request.jwt.claim.sub',g::text,true); perform pt_join_activity(act);
  -- guest → host
  begin mid:=pt_dm_send(h,'Hallo! Bis Samstag 🙂'); msg:='sent'; exception when others then msg:=sqlerrm; end;
  res:=res||format('1. People who share a session can message|%s|%s', msg='sent', msg);
  perform set_config('request.jwt.claim.sub',x::text,true);
  begin perform pt_dm_send(h,'hi'); msg:='sent'; exception when others then msg:=sqlerrm; end;
  res:=res||format('2. Someone you never met can''t message you|%s|%s', msg like '%dm_not_allowed%', msg);
  perform set_config('request.jwt.claim.sub',h::text,true);
  select pt_dm_unread() into n;
  res:=res||format('3. Host sees 1 unread|%s|%s', n=1, n);
  select * into r from pt_dm_threads() limit 1;
  res:=res||format('4. Conversation list shows the guest + last message|%s|%s: %s', r.other=g and r.unread=1, r.name, r.last_body);
  perform count(*) from pt_dm_messages(g);
  select pt_dm_unread() into n;
  res:=res||format('5. Opening the conversation marks it read|%s|%s unread', n=0, n);
  perform pt_dm_send(g,'Gerne!');
  perform set_config('request.jwt.claim.sub',g::text,true);
  select count(*) into n from pt_dm_messages(h);
  res:=res||format('6. Both messages show for the guest|%s|%s messages', n=2, n);
  begin perform pt_dm_send(h, repeat('a',1001)); msg:='sent'; exception when others then msg:=sqlerrm; end;
  res:=res||format('7. Too long is refused|%s|%s', msg like '%dm_length%', msg);
  perform pt_dm_delete(mid);
  select body is null into msg from pt_dm_messages(h) where id=mid;
  res:=res||format('8. Deleting your own message hides it|%s|%s', msg='true', msg);
  perform set_config('request.jwt.claim.sub',h::text,true);
  begin perform pt_dm_delete((select max(id) from direct_messages where sender=g)); msg:='deleted'; exception when others then msg:=sqlerrm; end;
  res:=res||format('9. You can''t delete someone else''s message|%s|%s', msg like '%not_found%', msg);
  perform pt_block(g);
  perform set_config('request.jwt.claim.sub',g::text,true);
  begin perform pt_dm_send(h,'?'); msg:='sent'; exception when others then msg:=sqlerrm; end;
  res:=res||format('10. After a block, no more messages|%s|%s', msg like '%blocked_user%', msg);
  select count(*) into n from pt_dm_threads();
  res:=res||format('11. Blocked conversation disappears from the list|%s|%s', n=0, n);
  perform set_config('request.jwt.claim.sub','',true);
  begin perform pt_dm_send(h,'x'); msg:='sent'; exception when others then msg:=sqlerrm; end;
  res:=res||format('12. Signed-out can''t send|%s|%s', msg like '%sign_in_required%', msg);
  raise exception using errcode='QA000';
 exception when sqlstate 'QA000' then null; when others then res:=res||format('❗ stopped|false|%s',sqlerrm); end;
 insert into qa_results(test,ok,got) select split_part(y,'|',1),split_part(y,'|',2)::boolean,split_part(y,'|',3) from unnest(res) y;
end $qa$;
select case when ok then '✅' else '❌' end as " ", test as "Inbox", got as "what happened" from qa_results order by n;
