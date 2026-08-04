-- Cloud table for public booking-link submissions (2026-08-04 spec).
-- Name matches the client's COLLECTION_TABLES entry EXACTLY — camelCase is a
-- quoted identifier on purpose; supabase-js .from('bookingRequests') resolves
-- case-sensitively. Same blob shape + owner-scoped RLS as the other data
-- tables. Rows are INSERTED by the backend with the service role (which
-- bypasses RLS); the policy below is what lets the owner's device pull and
-- update its own rows.
--
-- RELEASE GATE: run this in the Supabase SQL editor BEFORE shipping the OTA
-- that adds bookingRequests to COLLECTION_TABLES — a missing cloud table
-- wedges every push into retained-retry (2026-07-14 pricebook incident).
-- Applied out-of-band via the Supabase SQL editor. Safe to re-run (idempotent).

create table if not exists public."bookingRequests" (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  data jsonb not null,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false
);

alter table public."bookingRequests" enable row level security;

drop policy if exists "users manage own bookingRequests" on public."bookingRequests";
create policy "users manage own bookingRequests"
  on public."bookingRequests"
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
