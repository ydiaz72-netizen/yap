-- PonteTalk · Add the Urdu ⇄ English lounge. Run once in Supabase → SQL Editor. Safe to run again.
insert into public.lounges(id, lang_a, lang_b, sort) values ('ur-en','ur','en',5)
on conflict (id) do update set active = true;
