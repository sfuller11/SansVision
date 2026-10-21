-- Run once in Supabase (SQL Editor > New query > paste > Run) if you already ran the first schema.sql.
-- Allows the new plant types and growth stages up to 20. Your existing plants are not touched.
alter table public.plants drop constraint if exists plants_type_check;
alter table public.plants add constraint plants_type_check check (type in ('cream','sword','dark','banded','coppertone','siamsilver','trifasciata','laurentii','blackgold'));
alter table public.plants drop constraint if exists plants_stage_check;
alter table public.plants add constraint plants_stage_check check (stage between 1 and 20);
