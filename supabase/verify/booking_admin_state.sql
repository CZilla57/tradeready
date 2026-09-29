-- supabase/verify/booking_admin_state.sql
-- Task 8.05 verification queries for 20260921_booking_admin_state.sql.
-- Run in the Supabase SQL editor AFTER applying the migration, BEFORE the
-- Workers deploy that registers /api/booking/admin. All read-only except the
-- clearly marked transaction blocks, which ROLL BACK. Replace :OWNER_ID with
-- a real auth.users id for the live blocks. NO DEPLOYMENT is part of
-- task 8.05.

-- 1. Objects exist with the exact signatures the Workers call.
select p.proname,
       pg_get_function_identity_arguments(p.oid) as args
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('admin_booking_link');
-- Expect 1 row: 8 args
-- (uuid, text, uuid, text, boolean, integer, text, jsonb).

select tablename from pg_tables
 where schemaname = 'public'
   and tablename in ('booking_link_state', 'booking_operations');
-- Expect 2 rows.

-- 2. Execute is locked down: service_role only.
select p.proname, grantee, privilege_type
  from information_schema.routine_privileges
 where routine_schema = 'public'
   and routine_name = 'admin_booking_link';
-- Expect only {grantee: service_role, privilege: EXECUTE} rows.

-- 3. RLS is on with an owner-scoped policy on both new tables.
select tablename, rowsecurity from pg_tables
 where schemaname = 'public'
   and tablename in ('booking_link_state', 'booking_operations');
-- Expect rowsecurity = true for both.

select policyname, cmd from pg_policies
 where schemaname = 'public'
   and tablename in ('booking_link_state', 'booking_operations');
-- Expect the "users own …" policies.

-- 4. pgcrypto present (sha256 token-hash comparison + backfill).
select extname from pg_extension where extname = 'pgcrypto';
-- Expect 1 row on Supabase (standard extension). If absent, the backfill and
-- the adopted-branch comparisons fail at execution — do NOT deploy Workers
-- until resolved.

-- 5. Backfill validation (deployment step 2 gates the Workers deploy):
-- row-count == distinct blob-token count, zero hash mismatches, and no
-- adopted rows before any admin mutation runs.
select
  (select count(distinct s.data -> 'bookingLink' ->> 'token')
     from public.settings s
    where s.data -> 'bookingLink' ->> 'token' is not null) as distinct_blob_tokens,
  (select count(*) from public.booking_link_state) as state_rows,
  (select count(*) from public.booking_link_state where adopted_at is not null) as adopted_rows;
-- Expect state_rows == distinct_blob_tokens and adopted_rows == 0.

-- Mismatched hashes (must be zero):
-- select b.user_id from public.booking_link_state b join public.settings s
--   on s.user_id = b.user_id
--  where b.token_hash <> encode(digest(s.data -> 'bookingLink' ->> 'token', 'sha256'), 'hex');

-- ── live blocks (transactional, ROLL BACK — paste one at a time) ──────────
-- Each block needs a scratch owner: use an existing test user id for
-- :OWNER_ID and scratch operation ids. Nothing commits.

-- 6. mint commits: revision 1, enabled, adopted, exact stored bytes.
-- begin;
-- select public.admin_booking_link(:'OWNER_ID', 'mint',
--   '0193f123-0000-4000-8000-000000000001',
--   'hash MintA', true, null, 'aa-halfs-ha256-hex',
--   '{"ok":true,"operationId":"0193f123-0000-4000-8000-000000000001","token":"raw-48-hex"}');
-- -- Expect: {"ok": true, "decision": "committed", "response":
-- --   {"ok":true,"operationId":"…","token":"raw-48-hex","enabled":true,"revision":1}}.
-- select token_hash, enabled, revision, (adopted_at is not null) as adopted
--   from public.booking_link_state where user_id = :'OWNER_ID';
-- -- Expect: the hash, true, 1, true.
-- rollback;

-- 7. Replay: same operationId + same hash returns the stored copy, no bump.
-- begin;
-- select public.admin_booking_link(:'OWNER_ID', 'mint',
--   '0193f123-0000-4000-8000-000000000002',
--   'hash MintB', true, null, 'bb-hash',
--   '{"ok":true,"operationId":"0193f123-0000-4000-8000-000000000002","token":"tok-b"}');
-- select public.admin_booking_link(:'OWNER_ID', 'mint',
--   '0193f123-0000-4000-8000-000000000002',
--   'hash MintB', true, null, 'cc-other-hash',
--   '{"ok":true,"operationId":"0193f123-0000-4000-8000-000000000002","token":"tok-c"}');
-- -- Expect: {"ok": true, "decision": "replay", "response": {… "token":"tok-b", …}}
-- -- (the second call's token/response are ignored — no second capability).
-- select revision from public.booking_link_state where user_id = :'OWNER_ID';
-- -- Expect: 1 (exactly one bump for the pair).
-- rollback;

-- 8. Same operationId + different hash → operation_conflict; foreign id → not_found.
-- begin;
-- select public.admin_booking_link(:'OWNER_ID', 'mint',
--   '0193f123-0000-4000-8000-000000000003',
--   'hash One', true, null, 'dd-hash',
--   '{"ok":true,"operationId":"0193f123-0000-4000-8000-000000000003","token":"tok-1"}');
-- select public.admin_booking_link(:'OWNER_ID', 'rotate',
--   '0193f123-0000-4000-8000-000000000003',
--   'hash Two-different-intent', null, null, 'ee-hash',
--   '{"ok":true,"operationId":"0193f123-0000-4000-8000-000000000003","token":"tok-2"}');
-- -- Expect: {"ok": false, "error": "operation_conflict"}.
-- rollback;
-- -- Foreign owner presenting the id (run with a SECOND owner id):
-- -- select public.admin_booking_link(:'OTHER_OWNER_ID', 'mint', '<id above>', …);
-- -- Expect: {"ok": false, "error": "not_found"}.

-- 9. stale_revision echoes current state; absent expectedRevision is LWW.
-- begin;
-- select public.admin_booking_link(:'OWNER_ID', 'mint',
--   '0193f123-0000-4000-8000-000000000004',
--   'hash M', true, null, 'ff-hash',
--   '{"ok":true,"operationId":"0193f123-0000-4000-8000-000000000004","token":"tok-m"}');
-- select public.admin_booking_link(:'OWNER_ID', 'set_enabled',
--   '0193f123-0000-4000-8000-000000000005',
--   'hash S', false, 99,
--   '{"ok":true,"operationId":"0193f123-0000-4000-8000-000000000005"}');
-- -- Expect: {"ok": false, "error": "stale_revision", "enabled": true, "revision": 1}.
-- select public.admin_booking_link(:'OWNER_ID', 'set_enabled',
--   '0193f123-0000-4000-8000-000000000006',
--   'hash S2', false, null,
--   '{"ok":true,"operationId":"0193f123-0000-4000-8000-000000000006"}');
-- -- Expect: committed, revision 2, enabled false (LWW, no expectedRevision).
-- rollback;

-- 10. Disable revokes resolution: after set_enabled(false), the adopted
-- branch of claim_booking_slot answers slot_taken for the old token (claim
-- commit revalidates revocation — run against the same scratch owner inside
-- one rolled-back txn with a settings row carrying the token).
-- (Covered end-to-end by __tests__/phase8BookingAdmin85.test.js at core
-- level; the competing-session timing proof rides the Phase 12 harness —
-- never label the mock below as race proof.)

-- 11. claim_booking_slot against an adopted disabled row (paste after block 9
-- shapes, inside one txn): expect {"ok": false, "error": "slot_taken"}.
-- (Requires the 8.04 function deployed; its to_regclass guard finds this
-- file's table.)
