-- Cloud-sync table for the new per-job photo collection (2026-08-06 job-photo
-- R2 sync spec). Table name matches the client's AsyncStorage key /
-- COLLECTION_TABLES entry EXACTLY — "jobPhotos" is a quoted identifier on
-- purpose; supabase-js .from('jobPhotos') resolves case-sensitively.
-- Same blob shape + owner-scoped RLS as the other data tables
-- (template: 20260803_local_collections_sync.sql).
--
-- These rows hold only photo METADATA (id, jobId, timestamps, dimensions); the
-- image bytes live on device disk + the R2 `tradeready-photos` bucket, never in
-- Postgres.
--
-- RELEASE GATE: run this in the Supabase SQL editor BEFORE shipping the OTA
-- that adds "jobPhotos" to COLLECTION_TABLES. A missing cloud table wedges every
-- push into retained-retry (the 2026-07-14 pricebook incident).
-- Applied out-of-band via the Supabase SQL editor (no CLI runner in this repo).
-- Safe to re-run (idempotent).

create table if not exists public."jobPhotos" (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  data jsonb not null,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false
);

alter table public."jobPhotos" enable row level security;

drop policy if exists "users manage own jobPhotos" on public."jobPhotos";
create policy "users manage own jobPhotos"
  on public."jobPhotos"
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
