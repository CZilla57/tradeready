-- Pricebook sync table. The client has synced a `pricebook` collection since
-- the feature shipped, but this table was never created — every pricebook
-- push failed silently and wedged the sync queue ("N changes pending" banner
-- that Sync Now could not clear; TestFlight beta finding 2026-07-14).
-- Same blob shape + owner-scoped RLS as the other six data tables.
-- Safe to re-run (idempotent).

create table if not exists public.pricebook (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  data jsonb not null,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false
);

alter table public.pricebook enable row level security;

drop policy if exists "users manage own pricebook" on public.pricebook;
create policy "users manage own pricebook"
  on public.pricebook
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
