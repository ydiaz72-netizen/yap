-- PonteTalk: 🗂️ Student Desk — your own notes in folders, plus PonteShop guides you pin.
-- Run once in Supabase → SQL Editor. Safe to run again.
-- Everything here is private: each person only ever sees their own desk.

create table if not exists public.desk_folders (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name       text not null check (length(trim(name)) between 1 and 40),
  color      text not null default 'teal' check (color in ('teal','plum','sun','coral','sky','leaf')),
  created_at timestamptz not null default now()
);
create index if not exists desk_folders_user_idx on public.desk_folders(user_id);

create table if not exists public.desk_notes (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  folder_id  uuid references public.desk_folders(id) on delete set null,
  lang       text check (lang is null or length(lang) <= 8),
  title      text not null default '' check (length(title) <= 80),
  body       text not null default '' check (length(body) <= 20000),
  pinned     boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists desk_notes_user_idx on public.desk_notes(user_id, updated_at desc);

create table if not exists public.desk_pins (
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  item_id    text not null check (length(item_id) <= 64),   -- a PonteShop resource id
  created_at timestamptz not null default now(),
  primary key (user_id, item_id)
);

alter table public.desk_folders enable row level security;
alter table public.desk_notes   enable row level security;
alter table public.desk_pins    enable row level security;

drop policy if exists desk_folders_own on public.desk_folders;
create policy desk_folders_own on public.desk_folders for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists desk_notes_own on public.desk_notes;
create policy desk_notes_own on public.desk_notes for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid()
    and (folder_id is null or exists (select 1 from public.desk_folders f where f.id = folder_id and f.user_id = auth.uid())));
drop policy if exists desk_pins_own on public.desk_pins;
create policy desk_pins_own on public.desk_pins for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

revoke all on public.desk_folders, public.desk_notes, public.desk_pins from anon;
grant select, insert, update, delete on public.desk_folders, public.desk_notes, public.desk_pins to authenticated;

-- Keep it fair: up to 30 folders, 500 notes and 200 pinned guides per person; stamp edits.
create or replace function public.pt_desk_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if tg_table_name = 'desk_folders' and (select count(*) from desk_folders where user_id = new.user_id) >= 30 then raise exception 'desk_limit'; end if;
    if tg_table_name = 'desk_notes'   and (select count(*) from desk_notes   where user_id = new.user_id) >= 500 then raise exception 'desk_limit'; end if;
    if tg_table_name = 'desk_pins'    and (select count(*) from desk_pins    where user_id = new.user_id) >= 200 then raise exception 'desk_limit'; end if;
  end if;
  if tg_table_name = 'desk_notes' and tg_op = 'UPDATE' then
    new.user_id := old.user_id; new.created_at := old.created_at; new.updated_at := now();
  end if;
  return new;
end $$;

drop trigger if exists trg_desk_folders_guard on public.desk_folders;
create trigger trg_desk_folders_guard before insert on public.desk_folders for each row execute function public.pt_desk_guard();
drop trigger if exists trg_desk_notes_guard on public.desk_notes;
create trigger trg_desk_notes_guard before insert or update on public.desk_notes for each row execute function public.pt_desk_guard();
drop trigger if exists trg_desk_pins_guard on public.desk_pins;
create trigger trg_desk_pins_guard before insert on public.desk_pins for each row execute function public.pt_desk_guard();
