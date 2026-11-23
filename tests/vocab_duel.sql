-- PonteTalk: checks for sql/vocab_duel.sql. Safe to run in Supabase → SQL Editor after vocab_duel.sql. Everything is rolled back.
create temp table if not exists qa_results(n serial, test text, ok boolean, got text); truncate qa_results;
do $qa$
declare a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); c uuid:=gen_random_uuid();
  res text[]:='{}'; msg text; dc text; j jsonb; n int;
  w text[]:=array['hallo','danke','bitte','tschuess','die-wohnung','der-tisch','das-haus','gehen','essen','gross'];
begin
 begin
  insert into auth.users(id,email,created_at) select u,'qa-'||left(u::text,8)||'@test.invalid', now()-interval '30 days' from unnest(array[a,b,c]) u;
  insert into profiles(id,display_name,time_zone) select u,'QA '||left(u::text,4),'Europe/Berlin' from unnest(array[a,b,c]) u
    on conflict(id) do update set display_name=excluded.display_name;

  -- signed out
  perform set_config('request.jwt.claim.sub','',true);
  begin perform pt_duel_create('A1',w); msg:='created'; exception when others then msg:=sqlerrm; end;
  res:=res||format('1. Signed-out people can''t start a duel|%s|%s', msg like '%not_signed_in%', msg);

  perform set_config('request.jwt.claim.sub',a::text,true);
  begin perform pt_duel_create('A1',array['hallo','hallo','bitte','x','y']); msg:='created'; exception when others then msg:=sqlerrm; end;
  res:=res||format('2. Repeated words are refused|%s|%s', msg like '%duel_invalid%', msg);

  dc:=pt_duel_create('A1',w);
  res:=res||format('3. A starts a duel and gets a 6-character code|%s|%s', dc ~ '^[A-Z0-9]{6}$', dc);

  j:=pt_duel_finish(dc,8,42000);
  res:=res||format('4. A plays first: own score visible|%s|%s', (j->'players'->0->>'score')::int=8, j->'players'->0->>'score');

  begin perform pt_duel_finish(dc,10,40000); msg:='saved'; exception when others then msg:=sqlerrm; end;
  res:=res||format('5. A can''t play the same duel twice|%s|%s', msg like '%duel_played%', msg);

  perform set_config('request.jwt.claim.sub',b::text,true);
  j:=pt_duel_get(dc);
  res:=res||format('6. B opens the link: can play, A''s score hidden|%s|can_play=%s score=%s', (j->>'can_play')::boolean and j->'players'->0->>'score' is null, j->>'can_play', coalesce(j->'players'->0->>'score','hidden'));

  begin perform pt_duel_finish(dc,7,500); msg:='saved'; exception when others then msg:=sqlerrm; end;
  res:=res||format('7. An impossible time (0.5 s for 10 words) is refused|%s|%s', msg like '%duel_invalid%', msg);

  j:=pt_duel_finish(dc,7,30000);
  res:=res||format('8. B plays: now sees both scores|%s|%s', jsonb_array_length(j->'players')=2 and (select bool_and(p->>'score' is not null) from jsonb_array_elements(j->'players') p), j->'players');

  select count(*) into n from notifications where user_id=a and kind='duel_done';
  res:=res||format('9. A gets a bell that B has played (no email)|%s|%s bell(s)', n=1 and not exists(select 1 from notifications where user_id=a and kind='duel_done' and email), n);

  perform set_config('request.jwt.claim.sub',c::text,true);
  j:=pt_duel_get(dc);
  begin perform pt_duel_finish(dc,10,30000); msg:='saved'; exception when others then msg:=sqlerrm; end;
  res:=res||format('10. A third person can''t join a finished duel|%s|can_play=%s, %s', not (j->>'can_play')::boolean and msg like '%duel_taken%', j->>'can_play', msg);

  -- blocked people can't duel
  perform set_config('request.jwt.claim.sub',a::text,true);
  dc:=pt_duel_create('B1',w);
  insert into user_blocks(blocker_id,blocked_id) values (a,c);
  perform set_config('request.jwt.claim.sub',c::text,true);
  begin perform pt_duel_finish(dc,5,30000); msg:='saved'; exception when others then msg:=sqlerrm; end;
  res:=res||format('11. Someone A blocked can''t play A''s duel|%s|%s', msg like '%duel_blocked%', msg);

  update vocab_duels set expires_at=now()-interval '1 minute' where vocab_duels.code=dc;
  perform set_config('request.jwt.claim.sub',b::text,true);
  begin perform pt_duel_finish(dc,5,30000); msg:='saved'; exception when others then msg:=sqlerrm; end;
  res:=res||format('12. Old links (after 7 days) stop working|%s|%s', msg like '%duel_expired%', msg);

  perform set_config('request.jwt.claim.sub',a::text,true);
  select jsonb_array_length(pt_duel_mine()) into n;
  res:=res||format('13. A''s list shows both duels|%s|%s', n=2, n);

  raise exception using errcode='QA000';
 exception when sqlstate 'QA000' then null; when others then res:=res||format('❗ stopped|false|%s',sqlerrm); end;
 insert into qa_results(test,ok,got) select split_part(y,'|',1),split_part(y,'|',2)::boolean,split_part(y,'|',3) from unnest(res) y;
end $qa$;
select case when ok then '✅' else '❌' end as " ", test as "Flashcard duel", got as "what happened" from qa_results order by n;
