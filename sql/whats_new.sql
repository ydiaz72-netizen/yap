-- =====================================================================
-- PonteTalk · 🎁 What's new: updates feed with reactions + "Coming soon" voting
-- Admins post updates and ideas in the app (Profile → 🎁 → ＋). Everyone can read;
-- signed-in members react (🔥 ❤️ 👍 🤔) and vote 🙋 for ideas.
-- Needs: account_holds.sql (pt_is_admin). Run once in Supabase → SQL Editor. Safe to run again.
-- =====================================================================
create table if not exists public.app_updates (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  tag text not null default 'new' check (tag in ('new','improved','fixed')),
  emoji text, pal text,
  title_en text not null, title_de text, title_es text,
  body_en text, body_de text, body_es text,
  try_go text,
  active boolean not null default true
);
create table if not exists public.app_update_reacts (
  update_id uuid references public.app_updates(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,
  emoji text not null check (emoji in ('🔥','❤️','👍','🤔')),
  primary key (update_id, user_id, emoji)
);
create table if not exists public.app_ideas (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  emoji text,
  title_en text not null, title_de text, title_es text,
  body_en text, body_de text, body_es text,
  status text not null default 'open' check (status in ('open','building','done')),
  active boolean not null default true
);
create table if not exists public.app_idea_votes (
  idea_id uuid references public.app_ideas(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (idea_id, user_id)
);
alter table public.app_updates enable row level security;
alter table public.app_update_reacts enable row level security;
alter table public.app_ideas enable row level security;
alter table public.app_idea_votes enable row level security;
revoke all on public.app_updates, public.app_update_reacts, public.app_ideas, public.app_idea_votes from anon, authenticated;

-- everything the 🎁 sheet needs, in one call
create or replace function public.pt_news()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'updates', coalesce((select jsonb_agg(x order by x.created_at desc) from (
        select u.*,
          coalesce((select jsonb_object_agg(r.emoji, r.n) from (select emoji, count(*) n from app_update_reacts where update_id = u.id group by emoji) r), '{}'::jsonb) as reacts,
          coalesce((select jsonb_agg(emoji) from app_update_reacts where update_id = u.id and user_id = auth.uid()), '[]'::jsonb) as mine
        from app_updates u where u.active order by u.created_at desc limit 40) x), '[]'::jsonb),
    'ideas', coalesce((select jsonb_agg(y order by y.votes desc, y.created_at desc) from (
        select i.*, (select count(*) from app_idea_votes v where v.idea_id = i.id) as votes,
          exists (select 1 from app_idea_votes v where v.idea_id = i.id and v.user_id = auth.uid()) as voted
        from app_ideas i where i.active) y), '[]'::jsonb));
$$;

create or replace function public.pt_news_react(p_id uuid, p_emoji text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'sign_in'; end if;
  if exists (select 1 from app_update_reacts where update_id = p_id and user_id = auth.uid() and emoji = p_emoji) then
    delete from app_update_reacts where update_id = p_id and user_id = auth.uid() and emoji = p_emoji; return false;
  end if;
  insert into app_update_reacts(update_id, user_id, emoji) values (p_id, auth.uid(), p_emoji); return true;
end $$;

create or replace function public.pt_idea_vote(p_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'sign_in'; end if;
  if exists (select 1 from app_idea_votes where idea_id = p_id and user_id = auth.uid()) then
    delete from app_idea_votes where idea_id = p_id and user_id = auth.uid(); return false;
  end if;
  insert into app_idea_votes(idea_id, user_id) values (p_id, auth.uid()); return true;
end $$;

-- admin: post / hide an update or an idea
create or replace function public.pt_news_post(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare nid uuid;
begin
  if not coalesce(pt_is_admin(), false) then raise exception 'admins_only'; end if;
  if coalesce(p->>'type','update') = 'idea' then
    insert into app_ideas(emoji, title_en, title_de, title_es, body_en, body_de, body_es, status)
    values (left(p->>'emoji',8), left(p->>'title_en',120), nullif(left(p->>'title_de',120),''), nullif(left(p->>'title_es',120),''),
            left(p->>'body_en',400), nullif(left(p->>'body_de',400),''), nullif(left(p->>'body_es',400),''), coalesce(nullif(p->>'status',''),'open'))
    returning id into nid;
  else
    insert into app_updates(tag, emoji, pal, title_en, title_de, title_es, body_en, body_de, body_es, try_go)
    values (coalesce(nullif(p->>'tag',''),'new'), left(p->>'emoji',8), nullif(p->>'pal',''), left(p->>'title_en',120), nullif(left(p->>'title_de',120),''), nullif(left(p->>'title_es',120),''),
            left(p->>'body_en',600), nullif(left(p->>'body_de',600),''), nullif(left(p->>'body_es',600),''), nullif(left(p->>'try_go',300),''))
    returning id into nid;
  end if;
  return nid;
end $$;
create or replace function public.pt_news_hide(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(pt_is_admin(), false) then raise exception 'admins_only'; end if;
  update app_updates set active = false where id = p_id;
  update app_ideas set active = false where id = p_id;
end $$;
create or replace function public.pt_idea_status(p_id uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(pt_is_admin(), false) then raise exception 'admins_only'; end if;
  update app_ideas set status = p_status where id = p_id;
end $$;

grant execute on function public.pt_news() to anon, authenticated;
revoke all on function public.pt_news_react(uuid,text), public.pt_idea_vote(uuid), public.pt_news_post(jsonb), public.pt_news_hide(uuid), public.pt_idea_status(uuid,text) from anon;
grant execute on function public.pt_news_react(uuid,text), public.pt_idea_vote(uuid), public.pt_news_post(jsonb), public.pt_news_hide(uuid), public.pt_idea_status(uuid,text) to authenticated;

-- first posts (only when the tables are still empty)
insert into app_updates(created_at, tag, emoji, pal, title_en, title_de, title_es, body_en, body_de, body_es, try_go)
select * from (values
  (now()-interval '3 hours','new','🌉','bruno','Your Bridge Report','Dein Brücken-Bericht','Tu informe del puente',
   'See where you are on the bridge, what''s going well and the 2 things to focus on next week. Share it with friends!',
   'Sieh, wo du auf der Brücke stehst, was gut läuft und worauf du nächste Woche achten solltest. Teile es mit Freunden!',
   'Mira dónde estás en el puente, qué va bien y las 2 cosas en las que centrarte la semana que viene. ¡Compártelo!','report'),
  (now()-interval '2 hours','improved','🧱','pia','Sentence Builder: C1 + past, present, future','Satzbauer: C1 + Vergangenheit, Gegenwart, Zukunft','Constructor de frases: C1 + pasado, presente, futuro',
   'Build the same sentence in every tense, try the new C1 level, and tap any word to see what it means.',
   'Bau denselben Satz in jeder Zeitform, probier das neue C1-Niveau und tippe ein Wort an, um die Bedeutung zu sehen.',
   'Construye la misma frase en todos los tiempos, prueba el nuevo nivel C1 y toca cualquier palabra para ver su significado.','sbuild'),
  (now()-interval '1 hour','improved','🔁',null,'20 new weil/wenn sentences','20 neue weil/wenn-Sätze','20 frases nuevas con weil/wenn',
   'The weil/wenn challenge now picks 5 random sentences from 20, so it''s different every time.',
   'Die weil/wenn-Challenge wählt jetzt 5 zufällige Sätze aus 20, also jedes Mal anders.',
   'El reto de weil/wenn elige ahora 5 frases al azar de 20: cada vez es distinto.','games'),
  (now()-interval '30 minutes','fixed','🔧',null,'Practice tips show live "x of y right"','Übungstipps zeigen live „x von y richtig“','Los consejos muestran en vivo «x de y bien»',
   null,null,null,null)
) v where not exists (select 1 from app_updates);

insert into app_ideas(emoji, title_en, title_de, title_es, body_en, body_de, body_es)
select * from (values
  ('👩‍🏫','Classes with a tutor','Kurse mit Lehrkraft','Clases con profe','Small paid group classes with a real teacher','Kleine bezahlte Gruppenkurse mit einer echten Lehrkraft','Clases en grupos pequeños, de pago, con un profe de verdad'),
  ('🎙️','Speaking practice','Sprechübungen','Práctica oral','Say the sentence and get your pronunciation checked','Sprich den Satz und lass deine Aussprache prüfen','Di la frase y comprueba tu pronunciación'),
  ('🇮🇹','Italian games','Italienisch-Spiele','Juegos de italiano','Sentence Builder and flashcards in Italian','Satzbauer und Karteikarten auf Italienisch','Constructor de frases y tarjetas en italiano'),
  ('📊','Tutor dashboard','Lehrkraft-Dashboard','Panel para profes','Teachers see their students'' reports and set homework','Lehrkräfte sehen die Berichte ihrer Lernenden und geben Hausaufgaben','Los profes ven los informes de sus alumnos y ponen deberes')
) v where not exists (select 1 from app_ideas);

notify pgrst, 'reload schema';
