-- Cloud-sync table for custom job / inspection forms and checklists (Roadmap
-- Phase 20, docs/superpowers/specs/2026-10-02-job-forms-design.md). One table
-- holds both the owner's custom templates and filled job checklists, told
-- apart by `data.kind` ('template' | 'instance'). Built-in templates live in
-- the app and are never rows.
--
-- Same blob shape + owner-scoped RLS as the other data tables (template:
-- 20260806_job_photos.sql). The table name matches the native client's
-- collection name EXACTLY (NativeSupabasePush `collectionTables`,
-- NativeInitialSync `Collection.forms`). `forms` is all lowercase, so it needs
-- no quoting, but it is quoted below for symmetry with the camelCase tables.
--
-- The `id` primary key is global across every account, so the client
-- randomizes every row id (`fm<ms>_<base36 random>`); never insert a fixed id.
--
-- RELEASE GATE: run this in the Supabase SQL editor BEFORE shipping the native
-- build that adds `forms` to its collections. The initial full pull fails
-- closed on any table, so a missing table breaks sign-in on every new device,
-- and every form push is retained for retry (the 2026-07-14 pricebook
-- incident). docs/release-checklist.md carries the entry.
-- Applied out-of-band via the Supabase SQL editor (no CLI runner in this repo).
-- Safe to re-run (idempotent).
--
-- Account deletion: `user_id ... on delete cascade` removes every row with the
-- auth user, like the other blob tables (supabase/verify/account_deletion_cascade.sql
-- checks every public table that has a user_id column).

create table if not exists public."forms" (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  data jsonb not null,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false
);

alter table public."forms" enable row level security;

drop policy if exists "users manage own forms" on public."forms";
create policy "users manage own forms"
  on public."forms"
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- Server-authoritative `updated_at` (the delta-pull cursor), attached HERE so
-- the already-applied 20260831_updated_at_server_authority.sql is never edited.
-- It reuses that migration's `public.set_updated_at()`; if the function is
-- missing this stops with a clear error instead of leaving a table whose
-- cursor trusts device clocks.
do $$
begin
  if to_regprocedure('public.set_updated_at()') is null then
    raise exception 'public.set_updated_at() is missing: apply 20260831_updated_at_server_authority.sql first';
  end if;
end;
$$;

drop trigger if exists set_updated_at_trg on public."forms";
create trigger set_updated_at_trg
  before insert or update on public."forms"
  for each row execute function public.set_updated_at();

-- ROLLBACK (only before any build that syncs `forms` has shipped):
--   drop table if exists public."forms";
