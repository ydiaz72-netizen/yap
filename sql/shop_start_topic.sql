-- =====================================================================
-- PonteTalk · Allow the "📘 Start here" marker on PonteShop resources
-- Run once in Supabase → SQL Editor. Safe to run again.
-- Rebuilds the topics check so it also accepts 'start'.
-- =====================================================================
alter table public.shop_items drop constraint if exists shop_items_topics_check;
alter table public.shop_items add constraint shop_items_topics_check check (
  topics is null or (
    topics <@ array['grammar','vocabulary','conversation','pronunciation','culture',
                    'everyday','travel','work','exams','start']::text[]
    and cardinality(topics) <= 10
  )
);
