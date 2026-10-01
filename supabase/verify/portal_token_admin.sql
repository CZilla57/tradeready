-- supabase/verify/portal_token_admin.sql
-- Task 8.06 verification queries for 20260922_portal_token_admin.sql.
-- Run in the Supabase SQL editor AFTER applying the migration, BEFORE the
-- Workers deploy that switches portal-manage to the RPC path. All read-only
-- except the clearly marked transaction blocks, which ROLL BACK. Replace
-- :OWNER_ID / :CUSTOMER_ID with a real auth.users id and a real customer id
-- for the live blocks. NO DEPLOYMENT is part of task 8.06.

-- 1. Objects exist with the exact signatures the Workers call.
select p.proname,
       pg_get_function_identity_arguments(p.oid) as args
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('admin_portal_token');
-- Expect 1 row: 8 args
-- (uuid, text, text, uuid, text, boolean, text, jsonb).

select tablename from pg_tables
 where schemaname = 'public'
   and tablename in ('portal_tokens', 'portal_operations');
-- Expect 2 rows.

-- 2. The invariant index exists and is partial (live rows only, so disabled
-- and legacy revoked rows never collide).
select indexname, indexdef from pg_indexes
 where schemaname = 'public'
   and tablename = 'portal_tokens'
   and indexname = 'portal_tokens_single_active';
-- Expect 1 row with "WHERE revoked_at IS NULL".

-- 3. Execute is locked down (P12-023). Supabase grants EXECUTE on new public
-- functions straight to anon/authenticated, which `revoke ... from public`
-- does not remove, so test the ROLES, not the ACL text. Expect ZERO rows.
select p.oid::regprocedure as function, r.rolname as role_that_can_execute
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  cross join (select rolname from pg_roles where rolname in ('anon', 'authenticated')) r
 where n.nspname = 'public'
   and p.proname in ('admin_portal_token')
   and has_function_privilege(r.rolname, p.oid, 'execute');
-- And service_role must keep it. Expect one row per function, all true.
select p.oid::regprocedure as function, has_function_privilege('service_role', p.oid, 'execute') as service_role_can_execute
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('admin_portal_token');

-- 4. Server-authority tables (P12-023): RLS on, NO policy, NO client privileges.
select tablename, rowsecurity from pg_tables
 where schemaname = 'public' and tablename in ('portal_operations');
-- Expect rowsecurity = true for every row.
select tablename, policyname, cmd from pg_policies
 where schemaname = 'public' and tablename in ('portal_operations');
-- Expect ZERO rows (devices never read or write these tables).
select t.tablename, r.rolname as role, p.priv as privilege
  from (select unnest(array['portal_operations']) as tablename) t
  cross join (select rolname from pg_roles where rolname in ('anon', 'authenticated')) r
  cross join (values ('select'), ('insert'), ('update'), ('delete')) p(priv)
 where has_table_privilege(r.rolname, format('public.%I', t.tablename), p.priv);
-- Expect ZERO rows.
select t.tablename, p.priv as privilege_service_role_lacks
  from (select unnest(array['portal_operations']) as tablename) t
  cross join (values ('select'), ('insert'), ('update')) p(priv)
 where not has_table_privilege('service_role', format('public.%I', t.tablename), p.priv);
-- Expect ZERO rows (the Worker reads these over REST).

-- 5. pgcrypto present (sha256 token-hash comparison + backfill).
select e.extname, n.nspname as schema from pg_extension e join pg_namespace n on n.oid = e.extnamespace where e.extname = 'pgcrypto';
-- Expect 1 row, schema = extensions on Supabase (the migrations call extensions.digest). If absent, the backfill and
-- hash comparisons fail at execution — do NOT deploy Workers until resolved.

-- 6. Consolidation validation (deployment step 2 gates the Workers deploy):
-- zero customers with two live rows, and every blob-token customer keeps its
-- display-copy row live.
select user_id, customer_id, count(*)
  from public.portal_tokens
 where revoked_at is null
 group by user_id, customer_id
having count(*) > 1;
-- Expect 0 rows.

-- ── live blocks (transactional, ROLL BACK — paste one at a time) ──────────
-- Each block needs a scratch owner + customer: use an existing test user id
-- for :OWNER_ID, an owned customer id for :CUSTOMER_ID, and scratch
-- operation ids. Nothing commits.

-- 7. mint commits: live row + exact stored bytes.
-- begin;
-- select public.admin_portal_token(:'OWNER_ID', :'CUSTOMER_ID', 'mint',
--   '0193f123-0000-4000-8000-0000000000a1',
--   'hash MintA', null, 'aa-portal-hash-64-hex',
--   '{"ok":true,"token":"raw-48-hex"}');
-- -- Expect: {"ok": true, "decision": "committed", "response":
-- --   {"ok":true,"token":"raw-48-hex","enabled":true,"adopted":true}}.
-- select token_hash, enabled, (revoked_at is null) as live
--   from public.portal_tokens
--  where user_id = :'OWNER_ID' and customer_id = :'CUSTOMER_ID';
-- -- Expect: the hash, true, true (exactly one live row).
-- rollback;

-- 8. Second mint → already_exists (ANY live row blocks, even disabled).
-- begin;
-- select public.admin_portal_token(:'OWNER_ID', :'CUSTOMER_ID', 'mint',
--   '0193f123-0000-4000-8000-0000000000a2',
--   'hash MintB', null, 'bb-portal-hash-64-hex',
--   '{"ok":true,"token":"tok-b"}');
-- select public.admin_portal_token(:'OWNER_ID', :'CUSTOMER_ID', 'set_enabled',
--   '0193f123-0000-4000-8000-0000000000a3',
--   'hash Dis', false, null,
--   '{"ok":true}');
-- select public.admin_portal_token(:'OWNER_ID', :'CUSTOMER_ID', 'mint',
--   '0193f123-0000-4000-8000-0000000000a4',
--   'hash MintC', null, 'cc-portal-hash-64-hex',
--   '{"ok":true,"token":"tok-c"}');
-- -- Expect the third call: {"ok": false, "error": "already_exists"}
-- -- (the disabled-but-live row still blocks — G4-02 closed).
-- rollback;

-- 9. Replay: same operationId + same hash returns the stored copy, no bump.
-- begin;
-- select public.admin_portal_token(:'OWNER_ID', :'CUSTOMER_ID', 'rotate',
--   '0193f123-0000-4000-8000-0000000000a5',
--   'hash RotB', null, 'bb-hash',
--   '{"ok":true,"token":"tok-b"}');
-- select public.admin_portal_token(:'OWNER_ID', :'CUSTOMER_ID', 'rotate',
--   '0193f123-0000-4000-8000-0000000000a5',
--   'hash RotB', null, 'cc-other-hash',
--   '{"ok":true,"token":"tok-c"}');
-- -- Expect: {"ok": true, "decision": "replay", "response": {… "token":"tok-b" …}}
-- -- (the second call's token/response are ignored — no second capability).
-- select count(*) from public.portal_tokens
--  where user_id = :'OWNER_ID' and customer_id = :'CUSTOMER_ID' and revoked_at is null;
-- -- Expect: 1 (exactly one live row for the pair).
-- rollback;

-- 10. Same operationId + different hash → operation_conflict; foreign id → not_found.
-- begin;
-- select public.admin_portal_token(:'OWNER_ID', :'CUSTOMER_ID', 'mint',
--   '0193f123-0000-4000-8000-0000000000a6',
--   'hash One', null, 'dd-hash',
--   '{"ok":true,"token":"tok-1"}');
-- select public.admin_portal_token(:'OWNER_ID', :'CUSTOMER_ID', 'rotate',
--   '0193f123-0000-4000-8000-0000000000a6',
--   'hash Two-different-intent', null, 'ee-hash',
--   '{"ok":true,"token":"tok-2"}');
-- -- Expect: {"ok": false, "error": "operation_conflict"}.
-- rollback;
-- -- Foreign owner presenting the id (run with a SECOND owner id):
-- -- select public.admin_portal_token(:'OTHER_OWNER_ID', :'CUSTOMER_ID', 'mint', '<id above>', …);
-- -- Expect: {"ok": false, "error": "not_found"}.

-- 11. Rotate is atomic: revoke + insert commit together; a failed insert
-- keeps the previous token live (G4-04 closed — failure rolls back, so the
-- old live row survives; prove by raising inside one txn and re-reading).
-- (Covered at core level by __tests__/phase8PortalAdmin86.test.js; the
-- competing-session timing proof rides the Phase 12 harness — never label
-- the mock below as race proof.)

-- 12. Unknown stale blob token after adoption fails closed: with ≥1
-- portal_tokens row for the customer, resolvePortalCustomer answers null for
-- a hash the table never saw, even when the blob still carries an enabled
-- token (G4-05 closed). Exercise via the portal-view route in staging, not
-- here — this file only proves the table/index shape it depends on.
