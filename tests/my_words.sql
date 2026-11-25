-- PonteTalk: checks for sql/my_words.sql. Safe to run in Supabase → SQL Editor after it. Everything is rolled back.
create temp table if not exists qa_results(n serial, test text, ok boolean, got text); truncate qa_results;
do $qa$
declare a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); w1 uuid; w2 uuid; res text[]:='{}'; j jsonb; err text;
begin
 begin
  insert into auth.users(id,email,created_at) values (a,'qa-a@test.invalid',now()),(b,'qa-b@test.invalid',now());
  perform set_config('request.jwt.claim.sub', a::text, true);
  w1:=pt_mywords_add('die Kaution','deposit','Die Kaution beträgt zwei Monatsmieten.','Tomo sucht eine Wohnung');
  j:=pt_mywords_list();
  res:=res||format('1. I can add a word and see it|%s|%s', jsonb_array_length(j)=1 and j->0->>'word'='die Kaution', j->0->>'word');
  res:=res||format('2. Story title is kept|%s|%s', j->0->>'src'='Tomo sucht eine Wohnung', j->0->>'src');
  w2:=pt_mywords_add('Die Kaution','deposit');
  res:=res||format('3. Same word twice is not doubled|%s|%s', w2=w1 and jsonb_array_length(pt_mywords_list())=1, jsonb_array_length(pt_mywords_list()));
  begin perform pt_mywords_add('','x'); err:='added'; exception when others then err:=sqlerrm; end;
  res:=res||format('4. An empty word is refused|%s|%s', err='words_invalid', err);
  perform set_config('request.jwt.claim.sub', b::text, true);
  res:=res||format('5. Someone else does not see my words|%s|%s', jsonb_array_length(pt_mywords_list())=0, jsonb_array_length(pt_mywords_list()));
  begin perform pt_mywords_delete(w1); err:='deleted'; exception when others then err:=sqlerrm; end;
  res:=res||format('6. Someone else cannot delete my word|%s|%s', err='not_yours', err);
  perform set_config('request.jwt.claim.sub', a::text, true);
  perform pt_mywords_delete(w1);
  res:=res||format('7. I can delete my word|%s|%s', jsonb_array_length(pt_mywords_list())=0, jsonb_array_length(pt_mywords_list()));
  raise exception using errcode='QA000';
 exception when sqlstate 'QA000' then null; when others then res:=res||format('❗ stopped|false|%s',sqlerrm); end;
 insert into qa_results(test,ok,got) select split_part(y,'|',1),split_part(y,'|',2)::boolean,split_part(y,'|',3) from unnest(res) y;
end $qa$;
select case when ok then '✅' else '❌' end as " ", test as "My words", got as "what happened" from qa_results order by n;
