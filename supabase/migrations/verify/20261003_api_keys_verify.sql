-- 20261003_api_keys_verify.sql
--
-- Self-checking verification for 20261003_api_keys.sql (Roadmap Phase 23,
-- read-only open API), in the 2026-08 RLS-snapshot pattern: a DO block that
-- RAISES on the first failure, then a final SELECT grid for the Supabase SQL
-- editor (which hides NOTICEs and shows only the last statement's rows).
--
-- READ-ONLY: catalog queries only (pg_class, pg_policies, pg_proc and the
-- has_*_privilege functions). Safe in psql or the SQL editor:
--   psql -v ON_ERROR_STOP=1 "$DATABASE_URL" -f supabase/migrations/verify/20261003_api_keys_verify.sql
--
-- Run it AFTER applying the migration and BEFORE deploying the Worker that
-- routes /v1. "ALL API KEY CHECKS PASSED" (psql) or a result grid with every
-- `ok` = true (SQL editor) means the database side is ready.
--
-- Counter increments under real concurrent sessions are proven on a
-- throwaway local cluster by supabase/verify/local/api_keys.sh; repeat that
-- block against a staging project when one exists.

do $$
declare
  t text;
  rls boolean;
  n int;
  r text;
  fn text;
  api_tables constant text[] := array['api_keys', 'api_access_log', 'api_usage_counters'];
  rpcs constant text[] := array[
    'public.api_key_authorize(text,text,text)',
    'public.api_key_admin(uuid,text,uuid,text,uuid,text,text[],integer,text,text,integer)',
    'public.api_key_public(public.api_keys)'
  ];
  hidden_columns constant text[] := array['key_hash', 'operation_id', 'request_hash'];
  visible_columns constant text[] := array['id', 'user_id', 'key_prefix', 'name', 'scopes', 'created_at',
    'expires_at', 'revoked_at', 'last_used_at', 'replaced_by', 'expiry_days'];
  c text;
begin
  -- 1. Tables exist with RLS on.
  foreach t in array api_tables loop
    select c2.relrowsecurity into rls
      from pg_class c2 join pg_namespace ns on ns.oid = c2.relnamespace
     where ns.nspname = 'public' and c2.relname = t;
    if rls is null then raise exception 'TABLE MISSING: public.%', t; end if;
    if not rls then raise exception 'RLS DISABLED: public.%', t; end if;
  end loop;

  -- 2. Policies: owner-read on keys and log, NOTHING on counters, and no
  -- client write policy anywhere.
  foreach t in array array['api_keys', 'api_access_log'] loop
    select count(*) into n from pg_policies
     where schemaname = 'public' and tablename = t and cmd = 'SELECT'
       and (coalesce(qual, '') like '%auth.uid() = user_id%' or coalesce(qual, '') like '%user_id = auth.uid()%');
    if n <> 1 then raise exception 'EXPECTED ONE OWNER-READ POLICY on public.% (found %)', t, n; end if;
  end loop;
  select count(*) into n from pg_policies where schemaname = 'public' and tablename = 'api_usage_counters';
  if n <> 0 then raise exception 'api_usage_counters must have NO policy (found %)', n; end if;
  select count(*) into n from pg_policies
   where schemaname = 'public' and tablename = any(api_tables) and cmd <> 'SELECT';
  if n <> 0 then raise exception 'CLIENT WRITE POLICY on an API table (found %)', n; end if;

  -- 3. Table privileges: no client writes anywhere, no client reads of the
  -- counters, and the hidden key columns are unreadable by clients.
  foreach t in array api_tables loop
    foreach r in array array['anon', 'authenticated'] loop
      foreach c in array array['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE'] loop
        if has_table_privilege(r, format('public.%I', t), c) then
          raise exception '% HAS % ON public.%', r, c, t;
        end if;
      end loop;
    end loop;
    if has_table_privilege('anon', format('public.%I', t), 'SELECT') then
      raise exception 'anon HAS SELECT ON public.%', t;
    end if;
    foreach c in array array['SELECT', 'INSERT', 'UPDATE', 'DELETE'] loop
      if not has_table_privilege('service_role', format('public.%I', t), c) then
        raise exception 'service_role LACKS % ON public.%', c, t;
      end if;
    end loop;
  end loop;
  if has_table_privilege('authenticated', 'public.api_usage_counters', 'SELECT') then
    raise exception 'authenticated HAS SELECT ON public.api_usage_counters';
  end if;
  foreach c in array hidden_columns loop
    if has_column_privilege('authenticated', 'public.api_keys', c, 'SELECT') then
      raise exception 'authenticated CAN READ api_keys.%', c;
    end if;
  end loop;
  foreach c in array visible_columns loop
    if not has_column_privilege('authenticated', 'public.api_keys', c, 'SELECT') then
      raise exception 'authenticated CANNOT READ api_keys.% (metadata grant missing)', c;
    end if;
  end loop;

  -- 4. Functions: security definer, pinned search_path, EXECUTE for
  -- service_role only. Supabase grants EXECUTE on new functions straight to
  -- anon/authenticated, so test the roles, not the ACL text.
  foreach fn in array rpcs loop
    if to_regprocedure(fn) is null then raise exception 'FUNCTION MISSING: %', fn; end if;
    foreach r in array array['anon', 'authenticated'] loop
      if has_function_privilege(r, fn, 'EXECUTE') then raise exception '% CAN EXECUTE %', r, fn; end if;
    end loop;
    if not has_function_privilege('service_role', fn, 'EXECUTE') then
      raise exception 'service_role CANNOT EXECUTE %', fn;
    end if;
  end loop;
  foreach fn in array array['public.api_key_authorize(text,text,text)',
                            'public.api_key_admin(uuid,text,uuid,text,uuid,text,text[],integer,text,text,integer)'] loop
    select count(*) into n from pg_proc p
     where p.oid = to_regprocedure(fn) and p.prosecdef
       and exists (select 1 from unnest(coalesce(p.proconfig, '{}')) s where s like 'search_path=%');
    if n <> 1 then raise exception 'NOT SECURITY DEFINER WITH PINNED search_path: %', fn; end if;
  end loop;

  -- 5. Account deletion cascades: every API table reaches auth.users with
  -- ON DELETE CASCADE (counters through api_keys).
  select count(*) into n from pg_constraint con
   where con.contype = 'f' and con.confdeltype = 'c'
     and con.conrelid in ('public.api_keys'::regclass, 'public.api_access_log'::regclass)
     and con.confrelid = 'auth.users'::regclass;
  if n <> 2 then raise exception 'api_keys/api_access_log must cascade from auth.users (found %)', n; end if;
  select count(*) into n from pg_constraint con
   where con.contype = 'f' and con.confdeltype = 'c'
     and con.conrelid = 'public.api_usage_counters'::regclass
     and con.confrelid = 'public.api_keys'::regclass;
  if n <> 1 then raise exception 'api_usage_counters must cascade from api_keys'; end if;

  -- 6. Indexes the RPCs and the app depend on.
  foreach t in array array['api_keys_owner_live', 'api_keys_owner_created', 'api_keys_operation', 'api_access_log_owner_time'] loop
    if to_regclass('public.' || t) is null then raise exception 'INDEX MISSING: %', t; end if;
  end loop;

  raise notice 'ALL API KEY CHECKS PASSED';
end $$;

-- Result grid for the SQL editor: one row per check, every `ok` must be true.
select 'rls ' || c.relname as check, c.relrowsecurity as ok
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relname in ('api_keys', 'api_access_log', 'api_usage_counters')
union all
select 'no client policy on api_usage_counters',
       not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'api_usage_counters')
union all
select 'authenticated cannot read api_keys.key_hash',
       not has_column_privilege('authenticated', 'public.api_keys', 'key_hash', 'SELECT')
union all
select 'anon/authenticated cannot execute ' || p.oid::regprocedure::text,
       not has_function_privilege('anon', p.oid, 'EXECUTE') and not has_function_privilege('authenticated', p.oid, 'EXECUTE')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('api_key_authorize', 'api_key_admin', 'api_key_public')
order by 1;
