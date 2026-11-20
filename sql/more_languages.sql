-- =====================================================================
-- PonteTalk · Allow 9 more languages in profiles, sessions and PonteShop
-- (Italian, French, Turkish, Russian, Dutch, Chinese, Japanese, Korean, Hindi)
-- Run once in Supabase → SQL Editor. Safe to run again.
--
-- It finds the old "only these 8 languages" rules on the language columns and
-- replaces them with the new list. The Results/Messages tab lists what it changed.
-- =====================================================================
do $$
declare
  langs text[] := array['en','de','es','pt','pl','uk','ar','ur','it','fr','tr','ru','nl','zh','ja','ko','hi'];
  targets text[][] := array[
    ['user_languages','language_code'],
    ['activities','language_a'],
    ['activities','language_b'],
    ['shop_items','language'],
    ['shop_items','base_language']
  ];
  t text; c text; i int; r record; typ regtype; l text; cname text;
begin
  for i in 1 .. array_length(targets, 1) loop
    t := targets[i][1]; c := targets[i][2];
    if not exists (select 1 from information_schema.columns
                   where table_schema = 'public' and table_name = t and column_name = c) then
      raise notice 'skip %.% (no such column)', t, c; continue;
    end if;

    -- Case 1: the column uses an enum type → add the new values
    select a.atttypid::regtype into typ from pg_attribute a
      where a.attrelid = ('public.' || t)::regclass and a.attname = c;
    if exists (select 1 from pg_type where oid = typ::oid and typtype = 'e') then
      foreach l in array langs loop
        execute format('alter type %s add value if not exists %L', typ, l);
      end loop;
      raise notice '%.%: added values to enum %', t, c, typ;
      continue;
    end if;

    -- Case 2: check constraints that list the old languages → drop them
    for r in select conname, pg_get_constraintdef(oid) as def from pg_constraint
             where conrelid = ('public.' || t)::regclass and contype = 'c'
               and pg_get_constraintdef(oid) ilike '%' || c || '%'
               and pg_get_constraintdef(oid) like '%''ur''%' loop
      execute format('alter table public.%I drop constraint %I', t, r.conname);
      raise notice '%.%: dropped old rule % (%)', t, c, r.conname, r.def;
    end loop;

    -- Add the new rule (one per column)
    cname := t || '_' || c || '_lang_check';
    execute format('alter table public.%I drop constraint if exists %I', t, cname);
    execute format('alter table public.%I add constraint %I check (%I is null or %I = any (%L::text[]))',
                   t, cname, c, c, langs);
    raise notice '%.%: languages now allowed: %', t, c, array_to_string(langs, ', ');
  end loop;

  -- Keep the rule that a session's two languages must be different
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='activities' and column_name='language_b') then
    alter table public.activities drop constraint if exists activities_languages_differ;
    alter table public.activities add constraint activities_languages_differ
      check (language_b is null or language_a is distinct from language_b) not valid;
    raise notice 'activities: the two languages must be different (kept)';
  end if;
end $$;
