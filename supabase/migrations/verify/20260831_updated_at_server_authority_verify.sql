-- 20260831_updated_at_server_authority_verify.sql
--
-- Self-checking verification for the set_updated_at trigger
-- (20260831_updated_at_server_authority.sql). Wrapped in a transaction that
-- ALWAYS rolls back, so it touches no real data.
--
-- Run once against the project after applying the migration:
--   psql -v ON_ERROR_STOP=1 "$DATABASE_URL" -f supabase/migrations/verify/20260831_updated_at_server_authority_verify.sql
--
-- Without -v ON_ERROR_STOP=1, psql exits 0 even when a `raise exception` fires
-- inside a failed check — a failure could be misread as a pass. Always pass it.
--
-- psql ONLY — do NOT paste this into the Supabase SQL editor. The editor may
-- autocommit per statement rather than running the whole script as one
-- transaction, which would leave the seeded verify_* rows behind despite the
-- trailing `rollback`.
--
-- NOTE ON now(): the trigger stamps now() = transaction_timestamp(), which is
-- CONSTANT within a transaction. This whole script is one transaction, so every
-- stamp it observes equals the transaction's start time. That is exactly why the
-- checks below prove the OVERRIDE property (a backdated client value is replaced
-- by now()) rather than strict monotonic-increase-across-writes — the latter is
-- a property of separate transactions in production (each app write is its own
-- transaction) and cannot be exercised inside a single rolled-back one.
--
-- Success prints one NOTICE per check, ending with "ALL CHECKS PASSED". Any
-- failure raises an exception and (with ON_ERROR_STOP) a non-zero exit.

begin;

do $$
declare
  uid        uuid;
  tables     text[] := array[
    'jobs', 'invoices', 'customers', 'expenses', 'pricebook',
    'recurringJobs', 'recurringInvoices', 'trips', 'bookingRequests',
    'jobPhotos', 'settings', 'customer_notes'
  ];
  t          text;
  stored     timestamptz;
  backdated  timestamptz := '2000-01-01T00:00:00Z';
  ledger     jsonb;
  jid        text := 'verify_updated_at_j1';
  iid        text := 'verify_updated_at_i1';
begin
  select id into uid from auth.users limit 1;
  if uid is null then
    raise exception 'no auth.users row available to satisfy the FK';
  end if;

  ------------------------------------------- 1. trigger present on every table
  foreach t in array tables loop
    if not exists (
      select 1 from pg_trigger tg
        join pg_class c on c.oid = tg.tgrelid
        join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public'
         and c.relname = t
         and tg.tgname = 'set_updated_at_trg'
         and not tg.tgisinternal
    ) then
      raise exception 'CHECK 1 FAILED: set_updated_at_trg missing on public.%', t;
    end if;
  end loop;
  raise notice 'CHECK 1 ok: set_updated_at_trg present on all % tables', array_length(tables, 1);

  ---------------------------------------------------- 2. INSERT overrides value
  insert into public.jobs (id, user_id, data, updated_at, deleted)
  values (jid, uid, jsonb_build_object('id', jid, 'status', 'lead'), backdated, false);

  select updated_at into stored from public.jobs where id = jid;
  if stored = backdated then
    raise exception 'CHECK 2 FAILED: INSERT kept the client-sent backdated updated_at';
  end if;
  if stored <> now() then
    raise exception 'CHECK 2 FAILED: INSERT did not stamp now() (got %)', stored;
  end if;
  raise notice 'CHECK 2 ok: INSERT replaced the backdated updated_at with now()';

  ---------------------------------------------------- 3. UPDATE overrides value
  update public.jobs set data = jsonb_build_object('id', jid, 'status', 'in_progress'),
                         updated_at = backdated
   where id = jid;

  select updated_at into stored from public.jobs where id = jid;
  if stored = backdated then
    raise exception 'CHECK 3 FAILED: UPDATE kept the client-sent backdated updated_at';
  end if;
  if stored <> now() then
    raise exception 'CHECK 3 FAILED: UPDATE did not stamp now() (got %)', stored;
  end if;
  raise notice 'CHECK 3 ok: UPDATE replaced the backdated updated_at with now()';

  ----------------------------- 4. on-conflict upsert (the app's real write path)
  -- supabase-js writes via PostgREST `Prefer: resolution=merge-duplicates`,
  -- which compiles to `insert ... on conflict (id) do update` — the BEFORE
  -- UPDATE branch. Prove the override fires there too, not just on a plain UPDATE.
  insert into public.jobs (id, user_id, data, updated_at, deleted)
  values (jid, uid, jsonb_build_object('id', jid, 'status', 'paid'), backdated, false)
  on conflict (id) do update set data = excluded.data, updated_at = excluded.updated_at;

  select updated_at into stored from public.jobs where id = jid;
  if stored <> now() then
    raise exception 'CHECK 4 FAILED: on-conflict upsert did not override updated_at (got %)', stored;
  end if;
  raise notice 'CHECK 4 ok: on-conflict upsert (real write path) overrode updated_at';

  --------------------- 5. coexistence with merge_invoice_payments_trg on invoices
  -- Both before-row triggers must fire: updated_at gets stamped AND the payment
  -- ledger is still union-preserved. Seed a two-payment invoice, then push a
  -- backdated, ledger-shrinking write.
  insert into public.invoices (id, user_id, data, updated_at, deleted)
  values (iid, uid,
    jsonb_build_object(
      'id', iid, 'amount', 1000, 'paid', false,
      'payments', jsonb_build_array(
        jsonb_build_object('id','p1','amount',400,'date','2026-07-01','method','cash'),
        jsonb_build_object('id','p2','amount',600,'date','2026-07-20','method','card')
      )
    ),
    backdated, false);

  update public.invoices
     set data = jsonb_build_object(
       'id', iid, 'amount', 1000, 'paid', false,
       'payments', jsonb_build_array(
         jsonb_build_object('id','p1','amount',400,'date','2026-07-01','method','cash')
       )
     ),
     updated_at = backdated
   where id = iid;

  select updated_at into stored from public.invoices where id = iid;
  if stored <> now() then
    raise exception 'CHECK 5 FAILED: invoices updated_at not overridden (got %)', stored;
  end if;
  select data -> 'payments' into ledger from public.invoices where id = iid;
  if jsonb_array_length(ledger) <> 2 then
    raise exception 'CHECK 5 FAILED: the two triggers did not compose — ledger shrank to %', ledger;
  end if;
  raise notice 'CHECK 5 ok: updated_at stamped AND payment-merge trigger still preserved the ledger';

  raise notice 'ALL CHECKS PASSED';
end $$;

rollback;
