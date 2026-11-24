-- PonteTalk: checks for sql/new_member_bell.sql. Safe to run in Supabase → SQL Editor after it. Everything is rolled back.
create temp table if not exists qa_results(n serial, test text, ok boolean, got text); truncate qa_results;
do $qa$
declare adm uuid; u uuid:=gen_random_uuid(); res text[]:='{}'; n int; j jsonb;
begin
 begin
  select user_id into adm from admins limit 1;
  if adm is null then adm:=gen_random_uuid(); insert into auth.users(id,email,created_at) values (adm,'qa-admin@test.invalid',now()); insert into admins(user_id) values (adm); end if;
  insert into auth.users(id,email,created_at) values (u,'qa-newbie@test.invalid',now());
  select count(*), max(data::text)::jsonb into n, j from notifications where user_id=adm and kind='new_member' and data->>'user'=u::text;
  res:=res||format('1. Admin gets a bell when someone signs up|%s|%s', n=1, n);
  res:=res||format('2. It shows the new email|%s|%s', j->>'email'='qa-newbie@test.invalid', j->>'email');
  res:=res||format('3. Bell only, no email sent|%s|%s', not exists(select 1 from notifications where user_id=adm and kind='new_member' and data->>'user'=u::text and email), 'email=false');
  res:=res||format('4. Nobody else is told|%s|%s', not exists(select 1 from notifications where kind='new_member' and data->>'user'=u::text and user_id not in (select user_id from admins)), 'admins only');
  raise exception using errcode='QA000';
 exception when sqlstate 'QA000' then null; when others then res:=res||format('❗ stopped|false|%s',sqlerrm); end;
 insert into qa_results(test,ok,got) select split_part(y,'|',1),split_part(y,'|',2)::boolean,split_part(y,'|',3) from unnest(res) y;
end $qa$;
select case when ok then '✅' else '❌' end as " ", test as "New member bell", got as "what happened" from qa_results order by n;
