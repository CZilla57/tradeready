-- 20260831_updated_at_server_authority.sql
--
-- Make `updated_at` authoritative on the DATABASE clock for every sync table,
-- via a BEFORE INSERT OR UPDATE trigger that stamps `now()` on each write and
-- ignores whatever the client sent.
--
-- WHY (roadmap P0.3, web/EDITING_ROADMAP.md):
-- The device pull loop selects rows with `gt('updated_at', since)`
-- (utils/sync.ts → pullRemote). Correct propagation therefore depends on
-- `updated_at` being monotonic and comparable across writers. Today it is NOT:
-- the same column is written from many independent clocks —
--   * every mobile version (pushQueue stamps `new Date()` at push time),
--   * the web portal (web/src/lib/writeRepository.ts),
--   * server-side writers on their own hosts: the Stripe Connect webhook, the
--     subscription webhook, and the booking / estimate stores
--     (backend*/**, all writing `new Date().toISOString()`).
-- A device with a skewed clock, or a row written by a host whose clock runs
-- behind the reader's watermark, can leave an edit permanently below the pull
-- filter — invisible until something else touches the row. A single DB-clock
-- source removes every one of those clock domains at once.
--
-- WHY OVERRIDE (not COALESCE the client value):
-- Filling `updated_at` only when absent would preserve the client clock and so
-- preserve the skew this migration exists to remove. Overriding unconditionally
-- is what makes it authoritative — and is backward-compatible: EXISTING clients
-- (every shipped mobile build, the current web bundle, the backends) may keep
-- sending `updated_at`; the trigger simply replaces it. No app release has to
-- ship in lockstep with this migration. Clients dropping the column from their
-- writes later is optional cleanup, not a prerequisite.
--
-- TRIGGER ORDER on `invoices`: this is an INDEPENDENT before-row trigger from
-- merge_invoice_payments_trg (20260718). One stamps NEW.updated_at, the other
-- rewrites NEW.data->'payments'; they touch disjoint columns, so their relative
-- firing order (Postgres fires BEFORE-row triggers alphabetically by name —
-- merge_… before set_…) does not matter.
--
-- SCOPE: the tables the sync layer writes with an `updated_at` — the ten
-- COLLECTION_TABLES plus `settings` and `customer_notes`. (settings and
-- customer_notes are pulled in full rather than by watermark today, but they are
-- written by the same sync path and unifying their clock keeps the rule simple
-- and future-proof.) Deliberately NOT applied to tables with their own
-- semantics that are not part of the device blob-sync watermark (e.g.
-- subscriptions, stripe_accounts) — widen only with intent.
--
-- CAUTION for future backfills: because the override is unconditional, a data
-- backfill that intentionally sets a HISTORICAL `updated_at` (to preserve
-- original timestamps) will be stomped to now() while this trigger is enabled.
-- Disable the trigger for that table for the duration of such a backfill:
--   alter table public.<t> disable trigger set_updated_at_trg;  -- ... backfill ...
--   alter table public.<t> enable  trigger set_updated_at_trg;
--
-- RELEASE GATE: apply this in the Supabase SQL editor (no CLI runner in this
-- repo). Idempotent — safe to re-run.

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  -- Authoritative DB-clock stamp on every insert and update, regardless of what
  -- the client sent. `now()` is the transaction timestamp, matching the column
  -- DEFAULT now(); each supabase-js write is its own transaction, so this moves
  -- forward on every distinct write.
  NEW.updated_at := now();
  return NEW;
end;
$$;

-- Attach the trigger to every in-scope table. `do $$ … $$` loops the list so
-- the set stays in one place; the camelCase names are quoted identifiers and
-- must match the table names EXACTLY (supabase-js resolves them case-sensitively
-- — see 20260803_local_collections_sync.sql).
do $$
declare
  t text;
  tables text[] := array[
    'jobs', 'invoices', 'customers', 'expenses', 'pricebook',
    'recurringJobs', 'recurringInvoices', 'trips', 'bookingRequests',
    'jobPhotos', 'settings', 'customer_notes'
  ];
begin
  foreach t in array tables loop
    execute format(
      'drop trigger if exists set_updated_at_trg on public.%I', t
    );
    execute format(
      'create trigger set_updated_at_trg
         before insert or update on public.%I
         for each row execute function public.set_updated_at()', t
    );
  end loop;
end;
$$;

-- ROLLBACK (per table, or loop the same array):
--   drop trigger if exists set_updated_at_trg on public.<t>;
-- The function can be left in place harmlessly. Dropping the trigger returns
-- writes to client-supplied `updated_at`; rows already stamped keep the DB-clock
-- value they were given (benign — a valid timestamp either way).
