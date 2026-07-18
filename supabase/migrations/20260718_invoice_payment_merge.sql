-- 20260718_invoice_payment_merge.sql
--
-- Union an invoice's payment ledger on EVERY write, so that no writer can
-- shrink it.
--
-- Why this exists: the app pushes whole-blob upserts from a queue, and each
-- queued item carries a frozen snapshot taken when the user saved. If the
-- Stripe webhook appends a payment server-side and the device later pushes an
-- older snapshot, a plain upsert silently destroys that payment. Union-on-write
-- makes that impossible regardless of which client is writing.
--
-- This trigger is DELIBERATELY DUMB. It unions the payments array and nothing
-- else — no paid, no paidAt, no rounding tolerance. Those rules live in exactly
-- two places (utils/invoicePayments.ts and backend/lib/paymentMath.js, pinned
-- together by __tests__/paymentMathParity.test.js) and must not be reproduced
-- here in a third dialect.
--
-- Deletion is represented as a one-way `voidedAt` field on the payment, never
-- as absence — otherwise this union could not tell "I don't know about this
-- payment" from "I deleted it", and would resurrect deletions. Void wins on an
-- id collision.
--
-- ASSUMPTION (not enforced): this trigger unions OLD's ledger into NEW's on
-- every UPDATE, including one where `deleted` is true on either side. If an
-- invoice were soft-deleted and a genuinely different invoice were later
-- upserted under the SAME id, its ledger would get unioned with the dead
-- invoice's — phantom money. The app never reuses invoice ids, so this is not
-- currently reachable, and no `OLD.deleted` guard has been added for it.
--
-- Idempotent: safe to re-run.

create or replace function public.merge_invoice_payments()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  old_payments jsonb;
  new_payments jsonb;
  merged       jsonb;
begin
  -- Nothing to merge against on INSERT.
  if TG_OP = 'INSERT' then
    return NEW;
  end if;

  if NEW.data is null then
    return NEW;
  end if;

  old_payments := OLD.data -> 'payments';
  new_payments := NEW.data -> 'payments';

  -- Neither side carries a ledger: leave the blob EXACTLY as-is. Legacy
  -- invoices must not gain a `payments` key — the app's legacy fallback keys
  -- off LENGTH, not presence (amountPaid/materializeLegacyLedger both test
  -- `payments && payments.length > 0`), but stamping an empty array here
  -- would still change every historical invoice from "no key" to "empty
  -- array" for no reason, so we leave it alone.
  if old_payments is null and new_payments is null then
    return NEW;
  end if;

  -- Deliberately NO early return here for a malformed new_payments (e.g. a
  -- device pushing `"payments": null` as jsonb 'null', or an object/scalar).
  -- A malformed ledger on EITHER side must degrade to contributing ZERO
  -- entries to the union below, not cause the union to be skipped — skipping
  -- the union is exactly how a stale/poisoned write would shrink the ledger,
  -- since `return NEW` here would store NEW.data verbatim and discard OLD's
  -- entire ledger. The case-check on new_payments inside the CTE below
  -- already handles this: non-array degrades to '[]'::jsonb, OLD's ledger
  -- still gets unioned in and written back, and no validation happens here —
  -- the trigger stays dumb.

  with all_payments as (
    -- old_payments/new_payments degrade to an empty array on ANY non-array
    -- shape (SQL NULL, jsonb 'null', a scalar, or an object) instead of
    -- letting jsonb_array_elements hard-error. This matters most for
    -- old_payments: OLD is never re-validated (it was already stored), so
    -- without this guard a poisoned row could never be repaired — every
    -- UPDATE would re-read the same bad OLD.data and error before the fix
    -- landed. NEW already passed the early-return above when malformed, so
    -- this case-check on new_payments is belt-and-suspenders.
    select value, 0 as prio
      from jsonb_array_elements(
        case when jsonb_typeof(old_payments) = 'array' then old_payments else '[]'::jsonb end
      )
    union all
    select value, 1 as prio
      from jsonb_array_elements(
        case when jsonb_typeof(new_payments) = 'array' then new_payments else '[]'::jsonb end
      )
  ),
  ranked as (
    select
      value ->> 'id' as payment_id,
      value,
      row_number() over (
        partition by value ->> 'id'
        -- The COLLISION RULE (below) must match pickSurvivingPayment in
        -- utils/invoicePayments.ts exactly, or the server and the device will
        -- store different void dates and ping-pong writes at each other. This
        -- requirement is about the tie-break rule only, NOT about the emitted
        -- array's order — see the comment on the final select below.
        --   1. A voided entry beats a live one (voidedAt is irreversible).
        --   2. When BOTH are voided, the EARLIEST void date wins — a
        --      side-independent value is what keeps the union commutative.
        --   3. Otherwise the incoming (NEW) version wins.
        order by
          ((value ->> 'voidedAt') is not null) desc,
          (value ->> 'voidedAt') asc nulls last,
          prio desc
      ) as rn
    from all_payments
  )
  -- Emitted array order is by payment_id, NOT the client's canonical order
  -- (comparePayments = (date, id) in utils/invoicePayments.ts). These
  -- intentionally diverge whenever date order != id order. This is benign,
  -- not an oversight: pullRemote -> mergeRemoteRecord -> mergePaymentLedgers
  -- re-sorts by comparePayments on every pull, and withDerivedPaidFields
  -- derives paidAt by walking a chronologically-sorted copy regardless of
  -- the stored array's order — so nothing downstream depends on the order
  -- this trigger emits. Do NOT change this sort to match the client's: doing
  -- so would invite the false impression that the two orderings are pinned
  -- together, when only the collision rule above needs to match.
  select coalesce(jsonb_agg(value order by payment_id), '[]'::jsonb)
    into merged
    from ranked
   where rn = 1;

  NEW.data := jsonb_set(NEW.data, '{payments}', merged, true);
  return NEW;
end;
$$;

drop trigger if exists merge_invoice_payments_trg on public.invoices;

create trigger merge_invoice_payments_trg
  before insert or update on public.invoices
  for each row
  execute function public.merge_invoice_payments();

-- ROLLBACK
--   drop trigger if exists merge_invoice_payments_trg on public.invoices;
-- The function can be left in place harmlessly.
--
-- NOTE: this is NOT a full undo. Any row the trigger already processed has had
-- a `payments` key written into it by jsonb_set. Dropping the trigger does not
-- un-write those. That is benign — the app's legacy fallback keys off ledger
-- LENGTH, not key presence — but "roll back the trigger" does not mean "return
-- to the prior state".
