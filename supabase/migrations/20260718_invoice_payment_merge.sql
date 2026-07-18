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
-- Idempotent: safe to re-run.

create or replace function public.merge_invoice_payments()
returns trigger
language plpgsql
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
  -- off its absence, and stamping an empty array here would change how every
  -- historical invoice is derived.
  if old_payments is null and new_payments is null then
    return NEW;
  end if;

  with all_payments as (
    select value, 0 as prio
      from jsonb_array_elements(coalesce(old_payments, '[]'::jsonb))
    union all
    select value, 1 as prio
      from jsonb_array_elements(coalesce(new_payments, '[]'::jsonb))
  ),
  ranked as (
    select
      value ->> 'id' as payment_id,
      value,
      row_number() over (
        partition by value ->> 'id'
        -- MUST match pickSurvivingPayment in utils/invoicePayments.ts exactly,
        -- or the server and the device will store different void dates and
        -- ping-pong writes at each other.
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
