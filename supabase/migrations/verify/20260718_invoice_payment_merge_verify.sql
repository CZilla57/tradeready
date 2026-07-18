-- 20260718_invoice_payment_merge_verify.sql
--
-- Self-checking verification for the merge_invoice_payments trigger.
-- Wrapped in a transaction that ALWAYS rolls back, so it touches no real data.
--
-- Run once against the project after applying the migration:
--   psql -v ON_ERROR_STOP=1 "$DATABASE_URL" -f supabase/migrations/verify/20260718_invoice_payment_merge_verify.sql
--
-- Without -v ON_ERROR_STOP=1, psql exits 0 even when a `raise exception` fires
-- inside a failed check — a failure could be misread as a pass. Always pass it.
--
-- psql ONLY — do NOT paste this into the Supabase SQL editor. The editor may
-- autocommit per statement rather than running the whole script as one
-- transaction, which would leave the seeded verify_trigger_* rows behind in
-- real data despite the trailing `rollback`.
--
-- Success prints eleven NOTICE lines, ending with "ALL CHECKS PASSED". Any
-- failure raises an exception and (with ON_ERROR_STOP) a non-zero exit.

begin;

do $$
declare
  uid         uuid;
  ledger      jsonb;
  row_data    jsonb;
  test_id     text := 'verify_trigger_i1';
  legacy_id   text := 'verify_trigger_i2';
begin
  select id into uid from auth.users limit 1;
  if uid is null then
    raise exception 'no auth.users row available to satisfy the FK';
  end if;

  ----------------------------------------------------------------- seed
  -- Not a check — just establishes the starting two-payment ledger the
  -- checks below push stale/partial writes against.
  insert into public.invoices (id, user_id, data, updated_at, deleted)
  values (test_id, uid,
    jsonb_build_object(
      'id', test_id, 'amount', 1000, 'paid', false,
      'payments', jsonb_build_array(
        jsonb_build_object('id','p1','amount',400,'date','2026-07-01','method','cash'),
        jsonb_build_object('id','p2','amount',600,'date','2026-07-20','method','card')
      )
    ),
    now(), false);
  raise notice 'SEED ok: seeded a two-payment ledger';

  ------------------------------------------- 2. stale push carrying only p1
  update public.invoices
     set data = jsonb_build_object(
       'id', test_id, 'amount', 1000, 'paid', false,
       'payments', jsonb_build_array(
         jsonb_build_object('id','p1','amount',400,'date','2026-07-01','method','cash')
       )
     )
   where id = test_id;

  select data -> 'payments' into ledger from public.invoices where id = test_id;
  if jsonb_array_length(ledger) <> 2 then
    raise exception 'CHECK 2 FAILED: stale push shrank the ledger to %', ledger;
  end if;
  -- Weak-check hardening (Fix 9): a union that kept two entries but got them
  -- WRONG would still pass a bare length check. Assert both original ids
  -- survived and p2's amount (untouched by the stale push) is intact.
  if not exists (select 1 from jsonb_array_elements(ledger) e where e ->> 'id' = 'p1') then
    raise exception 'CHECK 2 FAILED: p1 missing from merged ledger: %', ledger;
  end if;
  if not exists (
    select 1 from jsonb_array_elements(ledger) e
     where e ->> 'id' = 'p2' and (e ->> 'amount')::numeric = 600
  ) then
    raise exception 'CHECK 2 FAILED: p2 missing or amount corrupted: %', ledger;
  end if;
  raise notice 'CHECK 2 ok: stale push did not shrink the ledger, both ids and amounts intact';

  --------------------------------------------------------- 3. void sticks
  update public.invoices
     set data = jsonb_build_object(
       'id', test_id, 'amount', 1000, 'paid', false,
       'payments', jsonb_build_array(
         jsonb_build_object('id','p1','amount',400,'date','2026-07-01','method','cash',
                            'voidedAt','2026-07-22')
       )
     )
   where id = test_id;

  select data -> 'payments' into ledger from public.invoices where id = test_id;
  if jsonb_array_length(ledger) <> 2 then
    raise exception 'CHECK 3 FAILED: expected 2 entries, got %', ledger;
  end if;
  if not exists (
    select 1 from jsonb_array_elements(ledger) e
     where e ->> 'id' = 'p1' and e ->> 'voidedAt' = '2026-07-22'
  ) then
    raise exception 'CHECK 3 FAILED: the void was reverted by the union: %', ledger;
  end if;
  raise notice 'CHECK 3 ok: void survived the union';

  ------------------------- 3b. earliest void wins when both sides are voided
  update public.invoices
     set data = jsonb_build_object(
       'id', test_id, 'amount', 1000, 'paid', false,
       'payments', jsonb_build_array(
         jsonb_build_object('id','p1','amount',400,'date','2026-07-01','method','cash',
                            'voidedAt','2026-08-01')
       )
     )
   where id = test_id;

  select data -> 'payments' into ledger from public.invoices where id = test_id;
  if not exists (
    select 1 from jsonb_array_elements(ledger) e
     where e ->> 'id' = 'p1' and e ->> 'voidedAt' = '2026-07-22'
  ) then
    raise exception
      'CHECK 3b FAILED: later void (2026-08-01) overwrote the earlier one (2026-07-22): %',
      ledger;
  end if;
  raise notice 'CHECK 3b ok: earliest void date won, matching the client rule';

  ------------- 3c. OLD voided / NEW live: a stale device re-pushing a
  -- pre-void snapshot must not un-void the payment. This is the core
  -- regression the whole trigger exists to prevent, and nothing above
  -- exercised it — every prior check pushed a NEW that was itself voided or
  -- live-with-OLD-live. Here p1 is already voidedAt = '2026-07-22' (from
  -- CHECK 3/3b); push a blob where p1 carries NO voidedAt at all.
  update public.invoices
     set data = jsonb_build_object(
       'id', test_id, 'amount', 1000, 'paid', false,
       'payments', jsonb_build_array(
         jsonb_build_object('id','p1','amount',400,'date','2026-07-01','method','cash'),
         jsonb_build_object('id','p2','amount',600,'date','2026-07-20','method','card')
       )
     )
   where id = test_id;

  select data -> 'payments' into ledger from public.invoices where id = test_id;
  if not exists (
    select 1 from jsonb_array_elements(ledger) e
     where e ->> 'id' = 'p1' and e ->> 'voidedAt' = '2026-07-22'
  ) then
    raise exception
      'CHECK 3c FAILED: a stale NEW with no voidedAt un-voided p1: %', ledger;
  end if;
  raise notice 'CHECK 3c ok: OLD voided beat NEW live — stale re-push could not un-void p1';

  ------------------------------------ 4. legacy invoice passes through clean
  insert into public.invoices (id, user_id, data, updated_at, deleted)
  values (legacy_id, uid,
    jsonb_build_object('id', legacy_id, 'amount', 500, 'paid', true, 'paidAt', '2026-06-15'),
    now(), false);

  update public.invoices
     set data = jsonb_build_object('id', legacy_id, 'amount', 500, 'paid', true,
                                   'paidAt', '2026-06-15', 'desc', 'edited')
   where id = legacy_id;

  select data into row_data from public.invoices where id = legacy_id;
  if row_data ? 'payments' then
    raise exception 'CHECK 4 FAILED: legacy invoice gained a payments key: %', row_data;
  end if;
  raise notice 'CHECK 4 ok: legacy invoice untouched, no payments key added';

  ------------------------------------------------------- 5. real write path
  -- The app and the Stripe webhook both write via PostgREST
  -- `Prefer: resolution=merge-duplicates`, which compiles to
  -- `insert ... on conflict (id) do update set ...`, NOT a plain UPDATE.
  -- Postgres fires the BEFORE UPDATE branch (with OLD populated) for that
  -- path too, but every check above used a plain UPDATE — nothing proved the
  -- trigger actually runs on the real write path. Assumption: the conflict
  -- target column is `(id)` (invoices' primary key, per every WHERE id = ...
  -- lookup already used in this script); unverified beyond that inference
  -- since no CREATE TABLE for public.invoices lives in this repo.
  insert into public.invoices (id, user_id, data, updated_at, deleted)
  values (test_id, uid,
    jsonb_build_object(
      'id', test_id, 'amount', 1000, 'paid', false,
      'payments', jsonb_build_array(
        jsonb_build_object('id','p2','amount',600,'date','2026-07-20','method','card')
      )
    ),
    now(), false)
  on conflict (id) do update set data = excluded.data, updated_at = excluded.updated_at;

  select data -> 'payments' into ledger from public.invoices where id = test_id;
  if jsonb_array_length(ledger) <> 2 then
    raise exception
      'CHECK 5 FAILED: on-conflict upsert with fewer payments shrank the ledger to %', ledger;
  end if;
  if not exists (
    select 1 from jsonb_array_elements(ledger) e
     where e ->> 'id' = 'p1' and e ->> 'voidedAt' = '2026-07-22'
  ) then
    raise exception 'CHECK 5 FAILED: on-conflict upsert lost the voided p1 entry: %', ledger;
  end if;
  raise notice 'CHECK 5 ok: on-conflict (id) do update — the app''s real write path — did not shrink the ledger';

  --------------------------------------------------- 6. create_if_missing
  -- Every check above sent a blob that already had a `payments` key. Send
  -- one that OMITS the key entirely (NEW.data has no 'payments' path at
  -- all) while OLD still carries a two-entry ledger, to exercise
  -- jsonb_set's fourth argument (create_if_missing = true). If that arg
  -- were false, jsonb_set would silently no-op and the merged ledger would
  -- never be attached back onto NEW.data.
  update public.invoices
     set data = jsonb_build_object('id', test_id, 'amount', 1000, 'paid', false,
                                   'desc', 'no payments key in this write at all')
   where id = test_id;

  select data into row_data from public.invoices where id = test_id;
  if not (row_data ? 'payments') then
    raise exception
      'CHECK 6 FAILED: payments key missing after a write that omitted it — create_if_missing not exercised: %',
      row_data;
  end if;
  select row_data -> 'payments' into ledger;
  if jsonb_array_length(ledger) <> 2 then
    raise exception 'CHECK 6 FAILED: ledger did not survive a write omitting the payments key: %', ledger;
  end if;
  raise notice 'CHECK 6 ok: ledger survived a write that omitted the payments key (create_if_missing exercised)';

  ------------------------------------------ 7. poison-pill: JSON null payments
  -- A device can push `"payments": null` — a jsonb JSON null, present as a
  -- key, NOT an absent key and NOT a SQL NULL. This is the exact shape that
  -- the removed early-return bug (Fix 1) mishandled: `return NEW` before the
  -- union ran, storing NEW.data verbatim and discarding OLD's entire ledger.
  -- OLD currently carries a two-entry ledger (from CHECK 6, above: p1 voided,
  -- p2 amount 600). Assert the write does NOT error and OLD's ledger survives
  -- intact.
  update public.invoices
     set data = jsonb_build_object(
       'id', test_id, 'amount', 1000, 'paid', false,
       'payments', 'null'::jsonb
     )
   where id = test_id;

  select data -> 'payments' into ledger from public.invoices where id = test_id;
  if jsonb_array_length(ledger) <> 2 then
    raise exception 'CHECK 7 FAILED: JSON-null payments push shrank the ledger to %', ledger;
  end if;
  if not exists (
    select 1 from jsonb_array_elements(ledger) e
     where e ->> 'id' = 'p1' and e ->> 'voidedAt' = '2026-07-22'
  ) then
    raise exception 'CHECK 7 FAILED: JSON-null payments push lost the voided p1 entry: %', ledger;
  end if;
  if not exists (
    select 1 from jsonb_array_elements(ledger) e
     where e ->> 'id' = 'p2' and (e ->> 'amount')::numeric = 600
  ) then
    raise exception 'CHECK 7 FAILED: JSON-null payments push lost or corrupted p2: %', ledger;
  end if;
  raise notice 'CHECK 7 ok: a JSON-null payments push did not error and OLD''s ledger survived intact';

  ---------------------------------------- 8. poison-pill: payments as object
  -- Same poison-pill shape, but as a JSON OBJECT (`{}`) instead of JSON null —
  -- another value jsonb_typeof reports as not 'array', which the same
  -- case-check must degrade to zero contributed entries rather than error or
  -- shrink. OLD still carries the same two-entry ledger.
  update public.invoices
     set data = jsonb_build_object(
       'id', test_id, 'amount', 1000, 'paid', false,
       'payments', '{}'::jsonb
     )
   where id = test_id;

  select data -> 'payments' into ledger from public.invoices where id = test_id;
  if jsonb_array_length(ledger) <> 2 then
    raise exception 'CHECK 8 FAILED: object-shaped payments push shrank the ledger to %', ledger;
  end if;
  if not exists (
    select 1 from jsonb_array_elements(ledger) e
     where e ->> 'id' = 'p1' and e ->> 'voidedAt' = '2026-07-22'
  ) then
    raise exception 'CHECK 8 FAILED: object-shaped payments push lost the voided p1 entry: %', ledger;
  end if;
  if not exists (
    select 1 from jsonb_array_elements(ledger) e
     where e ->> 'id' = 'p2' and (e ->> 'amount')::numeric = 600
  ) then
    raise exception 'CHECK 8 FAILED: object-shaped payments push lost or corrupted p2: %', ledger;
  end if;
  raise notice 'CHECK 8 ok: an object-shaped payments push did not error and OLD''s ledger survived intact';

  raise notice 'ALL CHECKS PASSED';
end $$;

rollback;
