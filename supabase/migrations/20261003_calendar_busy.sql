-- 20261003_calendar_busy.sql
--
-- Roadmap Phase 26 — calendar busy times (on-device EventKit path). Spec:
-- docs/superpowers/specs/2026-10-03-calendar-sync-design.md §2.3, §3. Owner
-- decision Q6 (2026-10-03): write this file; the OWNER applies it.
--
-- ADDITIVE ONLY: one new server-authority table. No rewrites, no column
-- changes, no RLS changes to existing tables, no functions, no triggers. The
-- claim RPC (20260920) does not read this table in v1 (spec §3.4), so no
-- writer fence is needed.
--
-- One row per owner, written only by the Worker (POST /api/calendar/busy)
-- with the service role. A row holds UTC start/end instants of busy periods
-- inside the booking window (at most 63 days), all-day busy dates and a random
-- per-install id. It never holds event titles, locations, notes, attendees,
-- calendar names or event ids. Each put replaces the row; turning calendar
-- checks off deletes it; account deletion cascades it.
--
-- Deploy order does not matter: before this table exists the Worker treats
-- busy times as `off` (PostgREST 404 on the relation) and the endpoint answers
-- 503 `unavailable`. Idempotent — safe to re-run.
--
-- RELEASE GATE: run `supabase/verify/calendar_busy.sql` after applying; its
-- grant queries must return zero rows.
--
-- Rollback: `drop table if exists public.calendar_busy;` (a Worker without
-- the table reads busy times as `off`; no settings, job or booking data
-- changes, so nothing else needs unwinding).

create table if not exists public.calendar_busy (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  source_id    text not null,                 -- device install id (spec 2.1)
  snapshot     jsonb,                         -- {v,timed,allDay}; null = registered, nothing shared
  computed_at  timestamptz,
  window_start timestamptz,
  window_end   timestamptz,
  received_at  timestamptz not null default now(),  -- Worker clock, stamped on every put
  constraint calendar_busy_snapshot_columns check (
    snapshot is null
    or (computed_at is not null and window_start is not null and window_end is not null)
  )
);

-- Server-authority table (P12-023): RLS on with NO client-facing policy and
-- NO client grants. Devices never read or write this row directly; the Worker
-- reaches it with the service role, which bypasses RLS but still needs table
-- privileges on projects without automatic grants.
alter table public.calendar_busy enable row level security;

drop policy if exists "users own calendar_busy" on public.calendar_busy;

revoke all on table public.calendar_busy from public, anon, authenticated;
grant select, insert, update, delete on table public.calendar_busy to service_role;
