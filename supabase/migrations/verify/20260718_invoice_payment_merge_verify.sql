-- 20260718_invoice_payment_merge_verify.sql
--
-- Self-checking verification for the merge_invoice_payments trigger.
-- Wrapped in a transaction that ALWAYS rolls back, so it touches no real data.
-- Run once against the project after applying the migration:
--   psql "$DATABASE_URL" -f supabase/migrations/verify/20260718_invoice_payment_merge_verify.sql
-- Success prints five NOTICE lines and "ALL CHECKS PASSED". Any failure raises.

begin;

do $$
declare
  uid       uuid;
  ledger    jsonb;
  test_id   text := 'verify_trigger_i1';
  legacy_id text := 'verify_trigger_i2';
begin
  select id into uid from auth.users limit 1;
  if uid is null then
    raise exception 'no auth.users row available to satisfy the FK';
  end if;

  ---------------------------------------------------------------- 1. seed
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
  raise notice 'CHECK 1 ok: seeded a two-payment ledger';

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
  raise notice 'CHECK 2 ok: stale push did not shrink the ledger';

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

  ------------------------------------ 4. legacy invoice passes through clean
  insert into public.invoices (id, user_id, data, updated_at, deleted)
  values (legacy_id, uid,
    jsonb_build_object('id', legacy_id, 'amount', 500, 'paid', true, 'paidAt', '2026-06-15'),
    now(), false);

  update public.invoices
     set data = jsonb_build_object('id', legacy_id, 'amount', 500, 'paid', true,
                                   'paidAt', '2026-06-15', 'desc', 'edited')
   where id = legacy_id;

  select data into ledger from public.invoices where id = legacy_id;
  if ledger ? 'payments' then
    raise exception 'CHECK 4 FAILED: legacy invoice gained a payments key: %', ledger;
  end if;
  raise notice 'CHECK 4 ok: legacy invoice untouched, no payments key added';

  raise notice 'ALL CHECKS PASSED';
end $$;

rollback;
