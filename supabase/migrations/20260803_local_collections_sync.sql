-- Cloud-sync tables for the three formerly device-local collections:
-- recurring-job rules, recurring-invoice (maintenance plan) rules, and
-- mileage trips (2026-08-03 durability work). Table names match the client's
-- AsyncStorage keys / COLLECTION_TABLES entries EXACTLY — the camelCase ones
-- are quoted identifiers on purpose; supabase-js .from('recurringJobs')
-- resolves case-sensitively.
-- Same blob shape + owner-scoped RLS as the other seven data tables
-- (template: 20260714_pricebook.sql).
--
-- RELEASE GATE: run this in the Supabase SQL editor BEFORE shipping the OTA
-- that adds these tables to COLLECTION_TABLES. A missing cloud table wedges
-- every push into retained-retry — the 2026-07-14 pricebook incident; push
-- failures are Sentry-visible now, but the queue still jams until the table
-- exists.
-- Applied out-of-band via the Supabase SQL editor (no CLI runner in this repo).
-- Safe to re-run (idempotent).

create table if not exists public."recurringJobs" (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  data jsonb not null,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false
);

alter table public."recurringJobs" enable row level security;

drop policy if exists "users manage own recurringJobs" on public."recurringJobs";
create policy "users manage own recurringJobs"
  on public."recurringJobs"
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create table if not exists public."recurringInvoices" (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  data jsonb not null,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false
);

alter table public."recurringInvoices" enable row level security;

drop policy if exists "users manage own recurringInvoices" on public."recurringInvoices";
create policy "users manage own recurringInvoices"
  on public."recurringInvoices"
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create table if not exists public.trips (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  data jsonb not null,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false
);

alter table public.trips enable row level security;

drop policy if exists "users manage own trips" on public.trips;
create policy "users manage own trips"
  on public.trips
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
