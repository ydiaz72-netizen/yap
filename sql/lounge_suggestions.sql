-- =====================================================================
-- PonteTalk · Members can suggest new lounges
-- Run once in Supabase → SQL Editor. Safe to run again.
--   * Anyone with a name + 18+ can suggest a language pair (max 10 open suggestions each).
--   * Same pair from several people = one suggestion with more 👍 votes.
--   * Admins see the list in the Lounges tab and can create the lounge in one tap.
-- =====================================================================

create table if not exists public.lounge_suggestions (
  pair        text not null,                 -- both codes in alphabetical order, e.g. 'en-fr'
  lang_a      text not null,
  lang_b      text not null,
  user_id     uuid not null references auth.users(id) on delete cascade,
  note        text check (note is null or length(note) <= 140),
  created_at  timestamptz not null default now(),
  primary key (pair, user_id)
);
alter table public.lounge_suggestions enable row level security;
revoke all on public.lounge_suggestions from anon, authenticated;

create or replace function public.pt_lounge_pair(a text, b text)
returns text language sql immutable as $$ select least(a,b) || '-' || greatest(a,b) $$;

-- ---------- suggest (or vote for) a pair ----------
create or replace function public.pt_lounge_suggest(p_a text, p_b text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare a text := lower(trim(coalesce(p_a,''))); b text := lower(trim(coalesce(p_b,'')));
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if not pt_lounge_can_post() then raise exception 'lounge_profile_needed'; end if;
  if a !~ '^[a-z]{2,5}$' or b !~ '^[a-z]{2,5}$' or a = b then raise exception 'lounge_bad_pair'; end if;
  if exists(select 1 from lounges where active and pt_lounge_pair(lang_a, lang_b) = pt_lounge_pair(a, b)) then
    raise exception 'lounge_exists'; end if;
  if not exists(select 1 from lounge_suggestions where pair = pt_lounge_pair(a,b) and user_id = auth.uid())
     and (select count(*) from lounge_suggestions where user_id = auth.uid()) >= 10 then
    raise exception 'lounge_too_many_suggestions'; end if;
  insert into lounge_suggestions(pair, lang_a, lang_b, user_id, note)
  values (pt_lounge_pair(a,b), a, b, auth.uid(), nullif(left(trim(coalesce(p_note,'')),140),''))
  on conflict (pair, user_id) do update set note = coalesce(excluded.note, lounge_suggestions.note);
end $$;

-- ---------- take back my vote ----------
create or replace function public.pt_lounge_unsuggest(p_pair text)
returns void language sql security definer set search_path = public as $$
  delete from lounge_suggestions where pair = p_pair and user_id = auth.uid();
$$;

-- ---------- list (most wanted first). Notes only for admins ----------
create or replace function public.pt_lounge_suggestions()
returns table(pair text, lang_a text, lang_b text, votes int, mine boolean, notes text[])
language sql stable security definer set search_path = public as $$
  select s.pair,
         (array_agg(s.lang_a order by s.created_at))[1],
         (array_agg(s.lang_b order by s.created_at))[1],
         count(*)::int,
         bool_or(s.user_id = auth.uid()),
         case when coalesce(pt_is_admin(), false)
              then array_remove(array_agg(s.note order by s.created_at), null) else null end
  from lounge_suggestions s
  where auth.uid() is not null
    and not exists(select 1 from lounges l where l.active and pt_lounge_pair(l.lang_a, l.lang_b) = s.pair)
  group by s.pair
  order by count(*) desc, min(s.created_at);
$$;

-- ---------- admin: create the lounge / dismiss ----------
create or replace function public.pt_admin_create_lounge(p_a text, p_b text)
returns text language plpgsql security definer set search_path = public as $$
declare a text := lower(trim(p_a)); b text := lower(trim(p_b)); new_id text;
begin
  if not coalesce(pt_is_admin(), false) then raise exception 'not_allowed'; end if;
  if a !~ '^[a-z]{2,5}$' or b !~ '^[a-z]{2,5}$' or a = b then raise exception 'lounge_bad_pair'; end if;
  select id into new_id from lounges where pt_lounge_pair(lang_a, lang_b) = pt_lounge_pair(a, b);
  if new_id is not null then
    update lounges set active = true where id = new_id;
  else
    new_id := a || '-' || b;
    insert into lounges(id, lang_a, lang_b, sort)
    values (new_id, a, b, coalesce((select max(sort) from lounges), 0) + 1);
  end if;
  delete from lounge_suggestions where pair = pt_lounge_pair(a, b);
  return new_id;
end $$;

create or replace function public.pt_admin_dismiss_lounge_suggestion(p_pair text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(pt_is_admin(), false) then raise exception 'not_allowed'; end if;
  delete from lounge_suggestions where pair = p_pair;
end $$;

grant execute on function
  public.pt_lounge_suggest(text, text, text), public.pt_lounge_unsuggest(text), public.pt_lounge_suggestions(),
  public.pt_admin_create_lounge(text, text), public.pt_admin_dismiss_lounge_suggestion(text)
to authenticated;
