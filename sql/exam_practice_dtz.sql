-- =====================================================================
-- PonteTalk · Test practice: add the German exam (DTZ A2–B1)
-- Run once in Supabase → SQL Editor, AFTER exam_practice.sql. Safe to run again.
--
--   exam = 'dtz'  → Deutsch-Test für Zuwanderer practice (Hören, Lesen, Schreiben, Sprechen)
--   mode adds 'writing' and 'speaking' (self-checked letters and speaking cards)
-- =====================================================================

alter table public.exam_attempts drop constraint if exists exam_attempts_exam_check;
alter table public.exam_attempts add  constraint exam_attempts_exam_check check (exam in ('lid','dtz'));

alter table public.exam_attempts drop constraint if exists exam_attempts_mode_check;
alter table public.exam_attempts add  constraint exam_attempts_mode_check check (mode in ('mock','practice','writing','speaking'));

alter table public.exam_answers drop constraint if exists exam_answers_exam_check;
alter table public.exam_answers add  constraint exam_answers_exam_check check (exam in ('lid','dtz'));
