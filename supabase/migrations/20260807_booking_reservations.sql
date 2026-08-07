-- Server-side slot reservations for public booking (Phase 11 C, 2026-08-07
-- spec §3d/§6). REAL columns, not the blob shape, because the partial unique
-- index below IS the double-book prevention: two customers racing for one
-- slot both reach INSERT, Postgres serializes them, the loser gets 23505 and
-- the API maps it to 409 slot_taken. No Worker-side state is involved — the
-- Workers runtime has no durable coordination primitive.
--
-- The DEVICE never reads this table (the bookingRequests blob carries the
-- slot info the app needs); rows are written by the backend with the service
-- role. The owner-scoped policy ships anyway per the multi-tenant security
-- floor: any new table MUST carry it before holding user data.
--
-- Cancelling/declining flips `status`, which drops the row out of the
-- partial index and frees the slot atomically. `request_id` pairs each
-- reservation with its bookingRequests row (no FK — that table is blob-keyed
-- and rows can be soft-deleted independently).
--
-- RELEASE GATE: run this in the Supabase SQL editor BEFORE deploying the
-- Worker that serves /api/booking/slots + /api/booking/reserve — a missing
-- table 500s every reserve. Applied out-of-band via the Supabase SQL editor.
-- Safe to re-run (idempotent).

create table if not exists public.booking_reservations (
  id             text primary key,
  user_id        uuid not null references auth.users(id) on delete cascade,
  request_id     text not null,
  slot_date      text not null,
  slot_start     text not null,
  slot_end       text not null,
  slot_start_utc timestamptz not null,
  slot_end_utc   timestamptz not null,
  status         text not null default 'booked',
  created_at     timestamptz not null default now()
);

create unique index if not exists booking_reservations_active_slot
  on public.booking_reservations (user_id, slot_start_utc)
  where status = 'booked';

alter table public.booking_reservations enable row level security;

drop policy if exists "users read own booking_reservations" on public.booking_reservations;
create policy "users read own booking_reservations"
  on public.booking_reservations
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
