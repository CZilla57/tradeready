-- Cloud-sync table for past-customer campaigns (Roadmap Phase 33,
-- docs/superpowers/specs/2026-10-03-campaigns-tags-design.md §2, D2). One row
-- per campaign: its audience rules, message templates and the frozen
-- recipient list with each recipient's send status. Rendered messages and
-- contact snapshots are never stored (spec §11). Customer tags and the
-- marketing opt-out live on the customer blob and need no migration.
--
-- Same blob shape + owner-scoped RLS as the other data tables (template:
-- 20261002_forms.sql). The table name matches the native client's collection
-- name EXACTLY (NativeSupabasePush `collectionTables`, NativeInitialSync
-- `Collection.campaigns`). `campaigns` is all lowercase, so it needs no
-- quoting, but it is quoted below for symmetry with the camelCase tables.
--
-- The `id` primary key is global across every account, so the client
-- randomizes every row id (`cmp_` + a UUID v4); never insert a fixed id.
--
-- RELEASE GATE: run this in the Supabase SQL editor BEFORE shipping the native
-- build that adds `campaigns` to its collections. The initial full pull fails
-- closed on any table, so a missing table breaks sign-in on every new device,
-- and every campaign push is retained for retry (the 2026-07-14 pricebook
-- incident). docs/release-checklist.md carries the entry.
-- Applied out-of-band via the Supabase SQL editor (no CLI runner in this repo).
-- Safe to re-run (idempotent).
--
-- Account deletion: `user_id ... on delete cascade` removes every row with the
-- auth user, like the other blob tables (supabase/verify/account_deletion_cascade.sql
-- checks every public table that has a user_id column).

create table if not exists public."campaigns" (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  data jsonb not null,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false
);

alter table public."campaigns" enable row level security;

drop policy if exists "users manage own campaigns" on public."campaigns";
create policy "users manage own campaigns"
  on public."campaigns"
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

drop trigger if exists set_updated_at_trg on public."campaigns";
create trigger set_updated_at_trg
  before insert or update on public."campaigns"
  for each row execute function public.set_updated_at();

-- ROLLBACK (only before any build that syncs `campaigns` has shipped):
--   drop table if exists public."campaigns";
