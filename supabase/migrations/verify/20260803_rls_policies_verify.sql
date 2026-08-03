-- 20260803_rls_policies_verify.sql
--
-- Self-checking RLS verification for the six core data tables (security
-- roadmap item 6, audit 2026-08-02). jobs, invoices, customers, expenses,
-- settings and customer_notes were created via the dashboard, so no DDL for
-- them exists in this repo — yet the publishable key ships in the app bundle,
-- making their RLS policies the entire security boundary. They were
-- dashboard-verified owner-scoped on 2026-07-16; this script makes that
-- provable from the repo on demand instead of resting on a recorded claim.
--
-- READ-ONLY: queries pg_class / pg_policies only. Safe in psql or the
-- Supabase SQL editor (unlike the invoice_payment_merge verifier, nothing
-- here writes, so editor autocommit is harmless):
--   psql -v ON_ERROR_STOP=1 "$DATABASE_URL" -f supabase/migrations/verify/20260803_rls_policies_verify.sql
--
-- Output comes in two forms because the Supabase SQL editor hides NOTICEs:
--   * psql: OK NOTICEs per table + inventory NOTICEs + "ALL RLS CHECKS PASSED".
--   * SQL editor: "Success" with a RESULT GRID from the final SELECT below
--     (the editor shows only the last statement's rows). "Success. No rows
--     returned" on the pre-2026-08-03 version of this file meant the DO-block
--     checks all PASSED — any failure raises and shows as an error.
--
-- After a green run, export/copy the final SELECT's grid into
-- supabase/migrations/verify/rls-policies-snapshot-2026-08.txt and commit it
-- — the committed snapshot is what closes roadmap item 6.

do $$
declare
  t text;
  core_tables constant text[] :=
    array['jobs','invoices','customers','expenses','settings','customer_notes'];
  rls boolean;
  n int;
  bad int;
  pol record;
begin
  foreach t in array core_tables loop
    select c.relrowsecurity into rls
      from pg_class c
      join pg_namespace ns on ns.oid = c.relnamespace
     where ns.nspname = 'public' and c.relname = t;

    if rls is null then
      raise exception 'TABLE MISSING: public.%', t;
    elsif not rls then
      raise exception 'RLS DISABLED: public.%', t;
    end if;

    select count(*) into n
      from pg_policies
     where schemaname = 'public' and tablename = t
       and (coalesce(qual, '')       like '%auth.uid() = user_id%'
         or coalesce(qual, '')       like '%user_id = auth.uid()%'
         or coalesce(with_check, '') like '%auth.uid() = user_id%'
         or coalesce(with_check, '') like '%user_id = auth.uid()%');
    if n = 0 then
      raise exception 'NO OWNER-SCOPED POLICY on public.%', t;
    end if;

    select count(*) into bad
      from pg_policies
     where schemaname = 'public' and tablename = t
       and (qual = 'true' or with_check = 'true');
    if bad > 0 then
      raise exception 'PERMISSIVE USING(true)/CHECK(true) POLICY on public.%', t;
    end if;

    raise notice 'OK: public.% — RLS enabled, % owner-scoped policies', t, n;
  end loop;

  raise notice '--- full public-schema policy inventory (paste into the snapshot file) ---';
  for pol in
    select tablename, policyname, cmd, roles, qual, with_check
      from pg_policies
     where schemaname = 'public'
     order by tablename, policyname
  loop
    raise notice '% | % | % | % | USING % | CHECK %',
      pol.tablename, pol.policyname, pol.cmd, pol.roles,
      coalesce(pol.qual, '-'), coalesce(pol.with_check, '-');
  end loop;

  raise notice 'ALL RLS CHECKS PASSED';
end $$;

-- Editor-visible result: the same checks and inventory as ROWS, since the
-- dashboard swallows NOTICEs. Section 1 = per-core-table verdict; section 2 =
-- every public-schema policy. This is the grid to commit as the snapshot.
with core(tablename) as (
  values ('jobs'), ('invoices'), ('customers'), ('expenses'), ('settings'), ('customer_notes')
),
rls as (
  select c.relname::text as tablename, c.relrowsecurity as rls_enabled
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
),
pol as (
  select p.tablename::text  as tablename,
         p.policyname::text as policyname,
         p.cmd::text        as cmd,
         array_to_string(p.roles, ',') as roles,
         coalesce(p.qual, '-')       as using_expr,
         coalesce(p.with_check, '-') as check_expr,
         (coalesce(p.qual, '')          like '%auth.uid() = user_id%'
           or coalesce(p.qual, '')       like '%user_id = auth.uid()%'
           or coalesce(p.with_check, '') like '%auth.uid() = user_id%'
           or coalesce(p.with_check, '') like '%user_id = auth.uid()%') as owner_scoped,
         (p.qual = 'true' or p.with_check = 'true') as permissive
    from pg_policies p
   where p.schemaname = 'public'
)
select '1 CHECK' as section,
       core.tablename,
       case
         when rls.rls_enabled is null then 'FAIL: table missing'
         when not rls.rls_enabled     then 'FAIL: RLS disabled'
         when count(*) filter (where pol.owner_scoped) = 0
           then 'FAIL: no owner-scoped policy'
         when count(*) filter (where pol.permissive) > 0
           then 'FAIL: permissive USING(true)/CHECK(true)'
         else 'OK: RLS enabled, ' || count(*) filter (where pol.owner_scoped)
              || ' owner-scoped policies'
       end as status,
       null::text as policyname, null::text as cmd, null::text as roles,
       null::text as using_expr, null::text as check_expr
  from core
  left join rls on rls.tablename = core.tablename
  left join pol on pol.tablename = core.tablename
 group by core.tablename, rls.rls_enabled
union all
select '2 POLICY', pol.tablename, null::text, pol.policyname, pol.cmd, pol.roles,
       pol.using_expr, pol.check_expr
  from pol
 order by 1, 2, 4 nulls first;
