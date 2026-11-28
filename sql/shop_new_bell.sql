-- =====================================================================
-- PonteTalk · 📚 Tell learners about new PonteShop resources
-- When a resource goes live (published, public, not waiting for approval),
-- everyone who is LEARNING that language gets a 🔔:
--   "📚 New for your German: <title>". Tap → opens the resource.
-- Bell only (no email). Each person is told once per resource.
-- Run once in Supabase → SQL Editor. Safe to run again.
-- =====================================================================

-- allow the new bell kind (keeps every kind that already exists)
do $$
declare ks text[];
begin
  select array(select distinct k from (
      select unnest(array['seat_offer','join_request','approved','declined','cancelled','reminder_24h','reminder_15m',
        'new_joiner','changed','invited','chat','report','session_match','reschedule','reminder_prep','word_fixed',
        'echo_new','echo_result','duel_done','new_member','feedback','profile_nudge','times_nudge','shop_new']) k
      union select distinct kind from public.notifications where kind is not null
      union select m[1] from pg_constraint c,
            regexp_matches(substring(pg_get_constraintdef(c.oid) from 'ANY \((.*)\)'), '([a-z][a-z0-9_]*)', 'g') m
            where c.conname = 'notifications_kind_check' and m[1] <> 'text') x) into ks;
  alter table public.notifications drop constraint if exists notifications_kind_check;
  execute format('alter table public.notifications add constraint notifications_kind_check check (kind = any (%L::text[]))', ks);
end $$;

create or replace function public.pt_shop_is_live(p jsonb)
returns boolean language sql immutable as $$
  select coalesce((p->>'published')::boolean, false)
     and coalesce(p->>'visibility', 'public') = 'public'
     and coalesce(p->>'approval', 'approved') not in ('pending', 'rejected', 'declined');
$$;

create or replace function public.pt_shop_new_bell()
returns trigger language plpgsql security definer set search_path = public as $$
declare u uuid; n int := 0;
begin
  if new.language is null or not pt_shop_is_live(to_jsonb(new)) then return new; end if;
  if tg_op = 'UPDATE' and pt_shop_is_live(to_jsonb(old)) then return new; end if;   -- was already live
  for u in
    select distinct l.user_id from user_languages l
     where l.language_code = new.language and l.role = 'learning'
       and l.user_id is distinct from auth.uid()
  loop
    begin
      perform pt_notify(u, 'shop_new', null, 'shop_new:' || new.id || ':' || u,
        jsonb_build_object('item', new.id, 'title', left(coalesce(new.title, ''), 120), 'lang', new.language, 'level', new.level));
      n := n + 1;
    exception when others then null;
    end;
  end loop;
  update notifications set email = false where kind = 'shop_new' and sent_at is null and data->>'item' = new.id::text;
  return new;
end $$;

drop trigger if exists trg_shop_new_bell on public.shop_items;
create trigger trg_shop_new_bell after insert or update on public.shop_items
  for each row execute function public.pt_shop_new_bell();

notify pgrst, 'reload schema';
