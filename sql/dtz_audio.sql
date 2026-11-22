-- =====================================================================
-- PonteTalk · German exam (DTZ): natural listening audio
-- Run once in Supabase → SQL Editor. Safe to run again.
--
--   Public bucket "dtz-audio": everyone can play the clips,
--   only admins can upload, replace or delete them (Admin → Audio studio).
-- =====================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('dtz-audio', 'dtz-audio', true, 5242880, array['audio/mpeg','application/json'])
on conflict (id) do update set public = true, file_size_limit = 5242880, allowed_mime_types = array['audio/mpeg','application/json'];

drop policy if exists dtz_audio_read on storage.objects;
create policy dtz_audio_read on storage.objects for select to authenticated
  using (bucket_id = 'dtz-audio' and coalesce(public.pt_is_admin(), false));

drop policy if exists dtz_audio_ins on storage.objects;
create policy dtz_audio_ins on storage.objects for insert to authenticated
  with check (bucket_id = 'dtz-audio' and coalesce(public.pt_is_admin(), false));

drop policy if exists dtz_audio_upd on storage.objects;
create policy dtz_audio_upd on storage.objects for update to authenticated
  using (bucket_id = 'dtz-audio' and coalesce(public.pt_is_admin(), false))
  with check (bucket_id = 'dtz-audio' and coalesce(public.pt_is_admin(), false));

drop policy if exists dtz_audio_del on storage.objects;
create policy dtz_audio_del on storage.objects for delete to authenticated
  using (bucket_id = 'dtz-audio' and coalesce(public.pt_is_admin(), false));
