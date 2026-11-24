-- PonteTalk: "My words" — words you add yourself (from anywhere, or from a story) become flashcards.
-- Run once in Supabase → SQL Editor. Safe to run again.
create table if not exists public.my_words (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  lang       text not null default 'de',
  word       text not null,
  meaning    text not null,
  example    text,
  src        text,                 -- where it came from, e.g. a story title
  created_at timestamptz not null default now()
);
create index if not exists my_words_user_idx on public.my_words(user_id, created_at desc);
alter table public.my_words enable row level security;
-- No policies on purpose: only the functions below can read/write, and only your own words.
revoke all on public.my_words from anon, authenticated;

create or replace function public.pt_mywords_list()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'lang', lang, 'word', word, 'meaning', meaning,
           'example', example, 'src', src, 'created_at', created_at) order by created_at desc), '[]'::jsonb)
  from my_words where user_id = auth.uid();
$$;

create or replace function public.pt_mywords_add(p_word text, p_meaning text, p_example text default null, p_src text default null, p_lang text default 'de')
returns uuid language plpgsql security definer set search_path = public as $$
declare nid uuid;
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  p_word := trim(coalesce(p_word,'')); p_meaning := trim(coalesce(p_meaning,''));
  p_example := nullif(trim(coalesce(p_example,'')),''); p_src := nullif(trim(coalesce(p_src,'')),'');
  if length(p_word) < 1 or length(p_word) > 80 or length(p_meaning) < 1 or length(p_meaning) > 120
     or length(coalesce(p_example,'')) > 240 or length(coalesce(p_src,'')) > 80 then raise exception 'words_invalid'; end if;
  -- the same word twice: just return the one you already have
  select id into nid from my_words where user_id = auth.uid() and lower(word) = lower(p_word) and lang = coalesce(p_lang,'de');
  if nid is not null then return nid; end if;
  if (select count(*) from my_words where user_id = auth.uid()) >= 1000 then raise exception 'words_limit'; end if;
  insert into my_words(user_id, lang, word, meaning, example, src)
  values (auth.uid(), coalesce(p_lang,'de'), p_word, p_meaning, p_example, p_src) returning id into nid;
  return nid;
end $$;

create or replace function public.pt_mywords_delete(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from my_words where id = p_id and user_id = auth.uid();
  if not found then raise exception 'not_yours'; end if;
end $$;

revoke all on function public.pt_mywords_list(), public.pt_mywords_add(text,text,text,text,text), public.pt_mywords_delete(uuid) from public, anon;
grant execute on function public.pt_mywords_list(), public.pt_mywords_add(text,text,text,text,text), public.pt_mywords_delete(uuid) to authenticated;
