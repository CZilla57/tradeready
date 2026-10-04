-- supabase/verify/calendar_busy.sql
-- Roadmap Phase 26 verification queries for 20261003_calendar_busy.sql.
-- Run in the Supabase SQL editor AFTER applying the migration (before or after
-- the Worker deploy; the order does not matter). Read-only.

-- 1. The table exists with the expected columns.
select column_name, data_type, is_nullable
  from information_schema.columns
 where table_schema = 'public' and table_name = 'calendar_busy'
 order by ordinal_position;
-- Expect 7 rows: user_id uuid NO, source_id text NO, snapshot jsonb YES,
-- computed_at / window_start / window_end timestamptz YES, received_at
-- timestamptz NO.

-- 2. Server-authority table (P12-023): RLS on, NO policy, NO client privileges.
select tablename, rowsecurity from pg_tables
 where schemaname = 'public' and tablename = 'calendar_busy';
-- Expect one row with rowsecurity = true.
select tablename, policyname, cmd from pg_policies
 where schemaname = 'public' and tablename = 'calendar_busy';
-- Expect ZERO rows (devices never read or write this table).
select r.rolname as role, p.priv as privilege
  from (select rolname from pg_roles where rolname in ('anon', 'authenticated')) r
  cross join (values ('select'), ('insert'), ('update'), ('delete')) p(priv)
 where has_table_privilege(r.rolname, 'public.calendar_busy', p.priv);
-- Expect ZERO rows.
select p.priv as privilege_service_role_lacks
  from (values ('select'), ('insert'), ('update'), ('delete')) p(priv)
 where not has_table_privilege('service_role', 'public.calendar_busy', p.priv);
-- Expect ZERO rows (the Worker reads, upserts and deletes over REST).

-- 3. Account deletion cascades the row (also covered by
-- supabase/verify/account_deletion_cascade.sql).
select con.conname, con.confdeltype
  from pg_constraint con
 where con.conrelid = 'public.calendar_busy'::regclass
   and con.contype = 'f';
-- Expect one row with confdeltype = 'c' (ON DELETE CASCADE to auth.users).

-- 4. The snapshot/columns check constraint is present.
select conname from pg_constraint
 where conrelid = 'public.calendar_busy'::regclass and contype = 'c';
-- Expect calendar_busy_snapshot_columns.
