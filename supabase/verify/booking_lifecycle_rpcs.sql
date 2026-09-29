-- supabase/verify/booking_lifecycle_rpcs.sql
-- Task 8.04 verification queries for 20260920_booking_lifecycle_rpcs.sql.
-- Run in the Supabase SQL editor AFTER applying the migration, BEFORE any
-- Workers deploy. All read-only except the clearly marked transaction blocks,
-- which ROLL BACK. Replace :OWNER_ID with a real auth.users id for the live
-- blocks. NO DEPLOYMENT is part of task 8.04.

-- 1. Objects exist with the exact signatures the Workers call.
select p.proname,
       pg_get_function_identity_arguments(p.oid) as args
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('claim_booking_slot', 'transition_booking',
                     'booking_take_lock', 'booking_to_minutes');
-- Expect 4 rows. claim_booking_slot: 11 args; transition_booking: 8 args.

-- 2. Execute is locked down: service_role only, no public/anon/anons.
select p.proname, grantee, privilege_type
  from information_schema.routine_privileges
 where routine_schema = 'public'
   and routine_name in ('claim_booking_slot', 'transition_booking');
-- Expect only {grantee: service_role, privilege: EXECUTE} rows.

-- 3. Backstop index still present (identical-start serialization until and
-- beyond the RPC deploy — §10 step 1: keep it).
select indexname, indexdef
  from pg_indexes
 where schemaname = 'public'
   and tablename = 'booking_reservations'
   and indexname = 'booking_reservations_active_slot';
-- Expect 1 row: UNIQUE (user_id, slot_start_utc) WHERE status = 'booked'.

-- 4. pgcrypto present (adopted-branch token-hash comparison; §5).
select extname from pg_extension where extname = 'pgcrypto';
-- Expect 1 row on Supabase (standard extension). If absent, the adopted
-- branch fails at execution — do NOT deploy Workers until resolved.

-- 5. set_updated_at trigger still stamps bookingRequests (scheduleProof
-- compares jobs.updated_at against the DB clock — 20260831 authority).
select tgname from pg_trigger
 where tgname = 'set_updated_at_trg'
   and tgrelid in (to_regclass('public."bookingRequests"'),
                   to_regclass('public.jobs'));
-- Expect 2 rows.

-- ── live blocks (transactional, ROLL BACK — paste one at a time) ──────────
-- Each block needs a scratch owner. Use an existing test user id for
-- :OWNER_ID, a scratch request id 'bk_verify_8_04', and scratch reservation
-- id 'rv_verify_8_04'. Nothing commits.

-- 6. transition_booking: invalid_state echo (run inside a txn that first
-- inserts a scratch booked row, then rolls back).
-- begin;
-- insert into public."bookingRequests" (id, user_id, data, deleted) values
--   ('bk_verify_8_04', :'OWNER_ID',
--    '{"id":"bk_verify_8_04","status":"booked","kind":"booked","manageToken":"t"}',
--    false);
-- select public.transition_booking('bk_verify_8_04', :'OWNER_ID', null,
--   array['reschedule_requested'], 'confirmed',
--   '{"at":"2026-09-20T00:00:00Z","actor":"owner","event":"resolve_reschedule"}',
--   true, null);
-- -- Expect: {"ok": false, "error": "invalid_state", "status": "booked"}.
-- rollback;

-- 7. transition_booking: happy-path decline releases then patches (G2-09
-- order: reservation row flips to cancelled AND data.status = declined).
-- begin;
-- insert into public."bookingRequests" (id, user_id, data, deleted) values
--   ('bk_verify_8_04', :'OWNER_ID',
--    '{"id":"bk_verify_8_04","status":"booked","kind":"booked","manageToken":"t","history":[]}',
--    false);
-- insert into public.booking_reservations
--   (id, user_id, request_id, slot_date, slot_start, slot_end,
--    slot_start_utc, slot_end_utc, status)
-- values ('rv_verify_8_04', :'OWNER_ID', 'bk_verify_8_04',
--   '2026-09-21', '09:00', '10:00',
--   '2026-09-21T14:00:00Z', '2026-09-21T15:00:00Z', 'booked');
-- select public.transition_booking('bk_verify_8_04', :'OWNER_ID', null,
--   array['booked','confirmed','reschedule_requested'], 'declined',
--   '{"at":"2026-09-20T00:00:00Z","actor":"owner","event":"decline"}',
--   true, null);
-- -- Expect: {"ok": true, "status": "declined"}.
-- select status from public.booking_reservations where id = 'rv_verify_8_04';
-- -- Expect: cancelled.
-- select data->>'status', jsonb_array_length(data->'history')
--   from public."bookingRequests" where id = 'bk_verify_8_04';
-- -- Expect: declined, 1 (exactly one appended entry).
-- rollback;

-- 8. claim_booking_slot: covered by the competing-session proof in
-- booking_lifecycle_concurrency.sh (identical-start, overlap, buffer-only,
-- disjoint, cross-owner). Do not run ad-hoc claims outside a rolled-back
-- txn: a committed claim inserts customer-visible rows.
