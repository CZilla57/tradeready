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
-- Success prints one OK NOTICE per core table, then the full public-schema
-- policy inventory, ending with "ALL RLS CHECKS PASSED". Any failure raises
-- an exception (non-zero exit under ON_ERROR_STOP).
--
-- After a green run, paste the full NOTICE output into
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
