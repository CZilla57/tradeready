-- 20261003_autopay_verify.sql
--
-- Self-checking verification for 20261003_autopay.sql (Phase 24, card on
-- file & autopay). Wrapped in a transaction that ALWAYS rolls back, so it
-- touches no real data.
--
-- Run once against the project after applying the migration:
--   psql -v ON_ERROR_STOP=1 "$DATABASE_URL" -f supabase/migrations/verify/20261003_autopay_verify.sql
--
-- Without -v ON_ERROR_STOP=1, psql exits 0 even when a `raise exception` fires
-- inside a failed check — a failure could be misread as a pass. Always pass it.
--
-- psql ONLY — do NOT paste this into the Supabase SQL editor. The editor may
-- autocommit per statement rather than running the whole script as one
-- transaction, which would leave the seeded verify_autopay_* rows behind in
-- real data despite the trailing `rollback`.
--
-- Success prints one NOTICE per check (11), ending with "ALL CHECKS PASSED". Any
-- failure raises an exception and (with ON_ERROR_STOP) a non-zero exit.

begin;

do $$
declare
  uid      uuid;
  e1       uuid;
  e2       uuid;
  e3       uuid;
  n        int;
  ok       boolean;
begin
  select id into uid from auth.users limit 1;
  if uid is null then
    raise exception 'no auth.users row available to satisfy the FK';
  end if;

  ------------------------------------------------ 1. tables exist, RLS on
  if to_regclass('public.autopay_enrollments') is null or to_regclass('public.autopay_charges') is null then
    raise exception 'CHECK 1 FAILED: autopay tables missing';
  end if;
  select count(*) into n from pg_class
   where oid in ('public.autopay_enrollments'::regclass, 'public.autopay_charges'::regclass)
     and relrowsecurity;
  if n <> 2 then
    raise exception 'CHECK 1 FAILED: row level security is not enabled on both tables';
  end if;
  raise notice 'CHECK 1 ok: both tables exist with row level security enabled';

  ------------------------------- 2. owner-read only: no client write policy
  select count(*) into n from pg_policies
   where schemaname = 'public' and tablename in ('autopay_enrollments', 'autopay_charges')
     and cmd = 'SELECT';
  if n <> 2 then
    raise exception 'CHECK 2 FAILED: expected one SELECT policy per table, found %', n;
  end if;
  select count(*) into n from pg_policies
   where schemaname = 'public' and tablename in ('autopay_enrollments', 'autopay_charges')
     and cmd <> 'SELECT';
  if n <> 0 then
    raise exception 'CHECK 2 FAILED: % non-SELECT policies would let clients write autopay rows', n;
  end if;
  raise notice 'CHECK 2 ok: owner-read policies only, no client write policies';

  ------------------------------------------------------------ seed rows
  insert into public.autopay_enrollments
    (user_id, stripe_account_id, customer_id, recurring_invoice_id, stripe_customer_id,
     max_amount_cents, status, consent_version, consent_text, checkout_session_id)
  values (uid, 'acct_verify', 'verify_autopay_c1', 'verify_autopay_r1', 'cus_verify',
          12000, 'active', 'autopay-consent-v1', 'verify text', 'cs_verify_autopay_1')
  returning id into e1;

  ---------------------------------- 3. one active enrollment per plan only
  ok := false;
  begin
    insert into public.autopay_enrollments
      (user_id, stripe_account_id, customer_id, recurring_invoice_id, stripe_customer_id,
       max_amount_cents, status, consent_version, consent_text)
    values (uid, 'acct_verify', 'verify_autopay_c1', 'verify_autopay_r1', 'cus_verify',
            12000, 'active', 'autopay-consent-v1', 'verify text');
  exception when unique_violation then
    ok := true;
  end;
  if not ok then
    raise exception 'CHECK 3 FAILED: a second active enrollment for the same plan was accepted';
  end if;
  raise notice 'CHECK 3 ok: a second active enrollment for one plan is refused';

  ------------- 4. replaced/revoked/pending rows coexist; other plans are free
  insert into public.autopay_enrollments
    (user_id, stripe_account_id, customer_id, recurring_invoice_id, stripe_customer_id,
     max_amount_cents, status, consent_version, consent_text, revoked_by, revoke_reason)
  values
    (uid, 'acct_verify', 'verify_autopay_c1', 'verify_autopay_r1', 'cus_verify', 12000, 'replaced', 'autopay-consent-v1', 'old', null, 'replaced'),
    (uid, 'acct_verify', 'verify_autopay_c1', 'verify_autopay_r1', 'cus_verify', 12000, 'revoked', 'autopay-consent-v1', 'old', 'customer', 'customer_turned_off'),
    (uid, 'acct_verify', 'verify_autopay_c1', 'verify_autopay_r1', 'cus_verify', 12000, 'pending', 'autopay-consent-v1', 'new', null, null);
  insert into public.autopay_enrollments
    (user_id, stripe_account_id, customer_id, recurring_invoice_id, stripe_customer_id,
     max_amount_cents, status, consent_version, consent_text)
  values (uid, 'acct_verify', 'verify_autopay_c1', 'verify_autopay_r2', 'cus_verify',
          5000, 'active', 'autopay-consent-v1', 'verify text')
  returning id into e2;
  raise notice 'CHECK 4 ok: inactive rows coexist with the active one; another plan can be active';

  ------------------------------------- 5. activation order: replace, then activate
  select id into e3 from public.autopay_enrollments
   where user_id = uid and recurring_invoice_id = 'verify_autopay_r1' and status = 'pending';
  update public.autopay_enrollments set status = 'replaced', revoke_reason = 'replaced'
   where user_id = uid and recurring_invoice_id = 'verify_autopay_r1' and status = 'active';
  update public.autopay_enrollments set status = 'active', activated_at = now() where id = e3;
  select count(*) into n from public.autopay_enrollments
   where user_id = uid and recurring_invoice_id = 'verify_autopay_r1' and status = 'active';
  if n <> 1 then
    raise exception 'CHECK 5 FAILED: expected exactly one active row after replacement, found %', n;
  end if;
  raise notice 'CHECK 5 ok: replace-then-activate leaves exactly one active enrollment';

  -------------------------------------------------- 6. enrollment checks
  ok := false;
  begin
    update public.autopay_enrollments set status = 'bogus' where id = e2;
  exception when check_violation then ok := true;
  end;
  if not ok then raise exception 'CHECK 6 FAILED: status accepted an unknown value'; end if;
  ok := false;
  begin
    update public.autopay_enrollments set revoked_by = 'stranger' where id = e2;
  exception when check_violation then ok := true;
  end;
  if not ok then raise exception 'CHECK 6 FAILED: revoked_by accepted an unknown value'; end if;
  ok := false;
  begin
    update public.autopay_enrollments set max_amount_cents = 0 where id = e2;
  exception when check_violation then ok := true;
  end;
  if not ok then raise exception 'CHECK 6 FAILED: max_amount_cents accepted 0'; end if;
  ok := false;
  begin
    update public.autopay_enrollments set checkout_session_id = 'cs_verify_autopay_1' where id = e2;
  exception when unique_violation then ok := true;
  end;
  if not ok then raise exception 'CHECK 6 FAILED: a checkout session id was accepted twice'; end if;
  raise notice 'CHECK 6 ok: status, revoked_by, amount and session-id constraints hold';

  ------------------------------------ 7. one charge claim per invoice/attempt
  insert into public.autopay_charges (user_id, invoice_id, enrollment_id, amount_cents, status)
  values (uid, 'verify_autopay_inv1', e2, 5000, 'claimed');
  insert into public.autopay_charges (user_id, invoice_id, enrollment_id, amount_cents, status)
  values (uid, 'verify_autopay_inv1', e2, 5000, 'claimed')
  on conflict (user_id, invoice_id, attempt) do nothing;
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'CHECK 7 FAILED: a second claim for the same invoice was inserted';
  end if;
  select count(*) into n from public.autopay_charges where user_id = uid and invoice_id = 'verify_autopay_inv1';
  if n <> 1 then
    raise exception 'CHECK 7 FAILED: expected one claim row, found %', n;
  end if;
  raise notice 'CHECK 7 ok: the claim insert is first-writer-wins (on conflict do nothing)';

  ------------------------------------------------------ 8. charge status check
  ok := false;
  begin
    update public.autopay_charges set status = 'retrying' where invoice_id = 'verify_autopay_inv1';
  exception when check_violation then ok := true;
  end;
  if not ok then raise exception 'CHECK 8 FAILED: charge status accepted an unknown value'; end if;
  raise notice 'CHECK 8 ok: charge status is constrained';

  ---------------------------------------- 9. charges cascade with their enrollment
  delete from public.autopay_enrollments where id = e2;
  select count(*) into n from public.autopay_charges where invoice_id = 'verify_autopay_inv1';
  if n <> 0 then
    raise exception 'CHECK 9 FAILED: % charge rows survived their enrollment', n;
  end if;
  raise notice 'CHECK 9 ok: charge rows cascade with their enrollment';

  ------------- 10. the owner role never reads consent IP / user agent (§4.8)
  if has_table_privilege('authenticated', 'public.autopay_enrollments', 'SELECT')
     or has_column_privilege('authenticated', 'public.autopay_enrollments', 'consent_ip', 'SELECT')
     or has_column_privilege('authenticated', 'public.autopay_enrollments', 'consent_user_agent', 'SELECT') then
    raise exception 'CHECK 10 FAILED: authenticated can read consent IP / user agent';
  end if;
  if not has_column_privilege('authenticated', 'public.autopay_enrollments', 'card_last4', 'SELECT')
     or not has_column_privilege('authenticated', 'public.autopay_enrollments', 'consented_at', 'SELECT')
     or not has_table_privilege('authenticated', 'public.autopay_charges', 'SELECT') then
    raise exception 'CHECK 10 FAILED: authenticated lost the owner-read columns';
  end if;
  if has_table_privilege('anon', 'public.autopay_enrollments', 'SELECT')
     or has_column_privilege('anon', 'public.autopay_enrollments', 'consent_ip', 'SELECT')
     or has_table_privilege('anon', 'public.autopay_charges', 'SELECT') then
    raise exception 'CHECK 10 FAILED: anon can read autopay rows';
  end if;
  if has_table_privilege('authenticated', 'public.autopay_charges', 'INSERT')
     or has_table_privilege('authenticated', 'public.autopay_charges', 'UPDATE')
     or has_table_privilege('authenticated', 'public.autopay_charges', 'DELETE')
     or has_table_privilege('authenticated', 'public.autopay_enrollments', 'UPDATE') then
    raise exception 'CHECK 10 FAILED: authenticated holds a write grant';
  end if;
  raise notice 'CHECK 10 ok: owner role reads enrollments without consent IP / user agent, and charges; no client writes';

  ------------------------------- 11. the charge-sent stamp exists and is optional
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'autopay_charges'
                    and column_name = 'charge_sent_at' and data_type = 'timestamp with time zone' and is_nullable = 'YES') then
    raise exception 'CHECK 11 FAILED: autopay_charges.charge_sent_at (timestamptz, nullable) is missing';
  end if;
  raise notice 'CHECK 11 ok: autopay_charges.charge_sent_at exists';

  raise notice 'ALL CHECKS PASSED';
end
$$;

rollback;
