-- PonteTalk: checks for sql/bridge_league.sql. Safe to run in Supabase → SQL Editor after bridge_league.sql. Everything is rolled back.
create temp table if not exists qa_results(n serial, test text, ok boolean, got text); truncate qa_results;
do $qa$
declare a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); c uuid:=gen_random_uuid();
  res text[]:='{}'; msg text; j jsonb; v int;
begin
 begin
  insert into auth.users(id,email,created_at) select u,'qa-'||left(u::text,8)||'@test.invalid', now()-interval '30 days' from unnest(array[a,b,c]) u;
  insert into profiles(id,display_name,time_zone) select u,'QA '||left(u::text,4),'Europe/Berlin' from unnest(array[a,b,c]) u
    on conflict(id) do update set display_name=excluded.display_name;

  perform set_config('request.jwt.claim.sub','',true);
  begin perform pt_bb_add(10); msg:='added'; exception when others then msg:=sqlerrm; end;
  res:=res||format('1. Signed-out people can''t add points|%s|%s', msg like '%not_signed_in%', msg);

  perform set_config('request.jwt.claim.sub',a::text,true);
  v:=pt_bb_add(10);
  res:=res||format('2. Points before joining are not counted|%s|%s', v is null, coalesce(v::text,'null'));

  perform pt_bb_join(true);
  begin perform pt_bb_add(500); msg:='added'; exception when others then msg:=sqlerrm; end;
  res:=res||format('3. More than 60 XP in one go is refused|%s|%s', msg like '%bb_invalid%', msg);
  v:=pt_bb_add(40); v:=pt_bb_add(30);
  res:=res||format('4. A joins and earns 40 + 30 = 70|%s|%s', v=70, v);

  perform set_config('request.jwt.claim.sub',b::text,true);
  perform pt_bb_join(true); v:=pt_bb_add(50);
  perform set_config('request.jwt.claim.sub',c::text,true);
  perform pt_bb_join(true); v:=pt_bb_add(20);
  j:=pt_bb_board();
  res:=res||format('5. Board order: A 70, B 50, C 20|%s|%s', j->'top'->0->>'xp'='70' and j->'top'->1->>'xp'='50' and j->'top'->2->>'xp'='20' and (j->'top'->2->>'me')::boolean, j->'top');
  res:=res||format('6. C sees own place 3|%s|%s', (j->'mine'->>'rank')::int=3, j->'mine');

  insert into user_blocks(blocker_id,blocked_id) values (a,c);
  j:=pt_bb_board();
  res:=res||format('7. Someone C is blocked with is hidden from C|%s|players=%s', (j->>'players')::int=2, j->>'players');

  perform set_config('request.jwt.claim.sub',b::text,true);
  perform pt_bb_join(false);
  perform set_config('request.jwt.claim.sub',c::text,true);
  j:=pt_bb_board();
  res:=res||format('8. After B leaves, B is hidden|%s|players=%s', (j->>'players')::int=1, j->>'players');

  perform set_config('request.jwt.claim.sub',a::text,true);
  update bb_weekly_xp set xp=4990 where user_id=a;
  v:=pt_bb_add(60);
  res:=res||format('9. Weekly limit stops at 5,000|%s|%s', v=5000, v);

  update bb_weekly_xp set week=week-7 where user_id=a;
  j:=pt_bb_board();
  res:=res||format('10. A new week starts from 0|%s|mine=%s', j->'mine' is null or j->'mine'='null'::jsonb, j->'mine');

  raise exception using errcode='QA000';
 exception when sqlstate 'QA000' then null; when others then res:=res||format('❗ stopped|false|%s',sqlerrm); end;
 insert into qa_results(test,ok,got) select split_part(y,'|',1),split_part(y,'|',2)::boolean,split_part(y,'|',3) from unnest(res) y;
end $qa$;
select case when ok then '✅' else '❌' end as " ", test as "Bridge league", got as "what happened" from qa_results order by n;
