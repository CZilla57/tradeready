-- 20261002_job_approval_preserve.sql
--
-- Keep a customer's estimate / change-order decision on EVERY update of
-- public.jobs, so that no writer can erase it with a stale blob.
--
-- Why this exists: devices push the WHOLE job blob with an unconditional
-- upsert, and the native sync coordinator pushes BEFORE it pulls. The Worker
-- (service role) records the customer's Approve/Decline inside that same
-- blob: `data.approval` for estimates (backend-workers/src/routes/estimate/
-- respond.js, nextApproval) and `data.changeOrders[i].approval` for change
-- orders (changeRespond.js). A device that queued an edit before it pulled the
-- decision therefore pushes a blob without it, and a plain upsert silently
-- destroys the customer's decision — and, since Phase 25 (good/better/best,
-- docs/superpowers/specs/2026-10-02-quote-options-design.md), the option they
-- chose (`approval.selection`). The device-side rebase graft (spec §6.3) cannot
-- close this alone, because the push happens before the pull that would feed
-- it. Same failure, same cure as 20260718_invoice_payment_merge.sql.
--
-- THE RULE — one rule, applied to `data.approval` and, separately, to every
-- `data.changeOrders[i].approval`. O = the stored approval (OLD), N = the
-- incoming one (NEW).
--
--   Server-owned keys: decision, consentAt, signerName, declineReason, ip,
--   userAgent, selection. Only the Worker writes them; no device authors them.
--
--   It applies only when O and N are both objects carrying the SAME non-null
--   `token` (same link). Then:
--   1. O is approved  -> approved is terminal. N keeps every other key it
--      carries (additive device metadata), but the server-owned keys PLUS
--      `snapshot` and `sentAt` (what the customer accepted) are exactly O's:
--      O's value where O has the key, and REMOVED where O lacks it — never
--      taken from N.
--   2. O has a decision and N has none (absent or JSON null) -> the device has
--      not seen the decision yet: the server-owned keys are exactly O's, by the
--      same present-or-removed rule. snapshot/sentAt stay N's (a declined
--      estimate may legitimately be re-sent with a new snapshot).
--   3. Anything else -> N untouched. This is what lets the Worker move
--      pending -> declined/approved and declined -> approved (N carries the new
--      decision), lets create-link re-send a declined estimate under the same
--      token (N keeps the decision), and leaves a re-send under a NEW token or a
--      removed approval (revise-declined archives it into approvalHistory)
--      alone.
--   Change orders are matched by `id` AND `token`: each element of NEW's array
--   whose approval has a token is compared with the first OLD element that has
--   the same id and an approval with the same token. Unmatched elements, array
--   order and every other key are kept exactly as N sent them.
--
-- This trigger is DELIBERATELY DUMB. It does not validate decisions, derive
-- `status`, read `manualDecision`, `approvalHistory` or `quoteOptions`, or
-- reconcile anything — the device does that on pull and the Worker owns the
-- decision itself. It only stops a stale blob from shrinking what the server
-- already recorded.
--
-- Never errors on shape: a non-object `data`, approval or change order, a
-- non-array `changeOrders`, jsonb `null`, or a missing/null token on either
-- side degrades to "no change" — a poisoned OLD row must never make every
-- later write to it fail. INSERTs and rows whose NEW.data is SQL NULL are never
-- touched, and no key outside the matched approval objects is ever changed.
--
-- CONCURRENCY: the comparison is against OLD, and Postgres locks the target row
-- before BEFORE ROW triggers run (under READ COMMITTED, PostgREST's default, an
-- UPDATE that loses a race re-reads the latest version; INSERT ... ON CONFLICT
-- DO UPDATE locks the conflicting row first). So a device push that races the
-- Worker's decision write waits for it and is then merged onto the committed
-- decision.
--
-- TRIGGER ORDER on `jobs`: the other triggers are booking_fence_statement_trg
-- and booking_fence_row_trg (20260920; take the per-owner advisory lock, read
-- only NEW.user_id, change nothing) and set_updated_at_trg (20260831; writes
-- only NEW.updated_at). Postgres fires BEFORE ROW triggers in name order —
-- booking_fence_row_trg, preserve_job_approvals_trg, set_updated_at_trg — after
-- the statement-level fence. They read and write disjoint columns, so their
-- relative order does not matter. (A FUTURE trigger that rewrites
-- `data.approval` would have to be ordered deliberately against this one.)
--
-- ASSUMPTION (not enforced): an approval token identifies one approval and is
-- never reused for a different estimate or change order. create-link mints 24
-- random bytes and reuses a token only to re-send the SAME approval
-- (estimateStore.planApprovalWrite), and refuses to rewrite an approved one —
-- the same freeze this trigger applies. create-link also KEEPS a decline when
-- it re-sends under the same token, while the app's local mirror of that call
-- (utils/estimateApprovalLink.ts, utils/changeOrderLink.ts) stores only
-- {token, sentAt, snapshot}; rule 2 restoring the decline on the next push
-- therefore matches what the server already holds.
--
-- NOT COVERED (by design — the rule keys on an unchanged token): a stale push
-- that carries NO approval, or one with an OLDER token, still replaces the
-- stored approval wholesale. Those windows belong to the device rebase graft
-- and the unmerged conditional-device-writes work, not to this trigger.
--
-- RELEASE GATE: apply this in the Supabase SQL editor (no CLI runner in this
-- repo) BEFORE shipping the native build that can create option estimates
-- (Phase 25 / feat/quote-options). Safe to apply any time before that: it only
-- restores keys the server wrote, and no current client or Worker flow relies
-- on a same-token write erasing a decision. Verify locally first with
-- `sh supabase/verify/job_approval_preserve.sh`.
--
-- Idempotent: safe to re-run.

create or replace function public.preserve_job_approvals()
returns trigger
language plpgsql
security invoker
set search_path = pg_catalog, public
as $$
declare
  -- Written only by the Worker (respond.js nextApproval / changeRespond.js).
  server_keys constant text[] := array[
    'decision', 'consentAt', 'signerName', 'declineReason', 'ip', 'userAgent',
    'selection'
  ];
  -- Once approved, the estimate the customer accepted is frozen as well.
  frozen_keys constant text[] := array[
    'decision', 'consentAt', 'signerName', 'declineReason', 'ip', 'userAgent',
    'selection', 'snapshot', 'sentAt'
  ];
  old_cos   jsonb;
  new_cos   jsonb;
  n_cos     int := 0;
  cos_dirty boolean := false;
  elem      jsonb;   -- NEW change-order element for the current slot
  o         jsonb;   -- stored approval (OLD)
  n         jsonb;   -- incoming approval (NEW)
  keep      text[];  -- keys whose presence and value come from O
  merged    jsonb;
begin
  -- Nothing to preserve against on INSERT (the trigger is BEFORE UPDATE only;
  -- this is a second guard, not the first).
  if TG_OP <> 'UPDATE' then
    return NEW;
  end if;

  if NEW.data is null or OLD.data is null then
    return NEW;
  end if;

  -- `->` on a non-object yields SQL NULL rather than erroring, but jsonb_set
  -- below needs an object; a blob of any other shape is left exactly as sent.
  if jsonb_typeof(NEW.data) <> 'object' or jsonb_typeof(OLD.data) <> 'object' then
    return NEW;
  end if;

  -- Non-array changeOrders on either side degrade to "no change orders"
  -- (jsonb_array_length / jsonb_array_elements would hard-error on them).
  old_cos := OLD.data -> 'changeOrders';
  if jsonb_typeof(old_cos) is distinct from 'array' then
    old_cos := '[]'::jsonb;
  end if;
  new_cos := NEW.data -> 'changeOrders';
  if jsonb_typeof(new_cos) = 'array' then
    n_cos := jsonb_array_length(new_cos);
  end if;

  -- Slot 0 is the estimate approval; slot k (1..n_cos) is NEW's change order at
  -- array index k-1. One loop so the rule below exists exactly once.
  for slot in 0 .. n_cos loop
    o := null;
    if slot = 0 then
      n := NEW.data -> 'approval';
      o := OLD.data -> 'approval';
    else
      elem := new_cos -> (slot - 1);
      n := elem -> 'approval';            -- NULL unless elem is an object
      if jsonb_typeof(n) = 'object'
         and (n ->> 'token') is not null
         and (elem ->> 'id') is not null then
        select e -> 'approval'
          into o
          from jsonb_array_elements(old_cos) with ordinality as t(e, ord)
         where e ->> 'id' = elem ->> 'id'
           and jsonb_typeof(e -> 'approval') = 'object'
           and (e -> 'approval' ->> 'token') = (n ->> 'token')
         order by ord
         limit 1;
      end if;
    end if;

    -- THE RULE (see header). jsonb_typeof(NULL) is NULL, so a missing side
    -- simply fails the condition.
    keep := null;
    if jsonb_typeof(o) = 'object'
       and jsonb_typeof(n) = 'object'
       and (o ->> 'token') is not null
       and (o ->> 'token') = (n ->> 'token') then
      if (o ->> 'decision') = 'approved' then
        keep := frozen_keys;
      elsif (o ->> 'decision') is not null and (n ->> 'decision') is null then
        keep := server_keys;
      end if;
    end if;

    if keep is not null then
      -- Strip N's copy of every kept key, then add back O's — so a key O lacks
      -- ends up absent, not inherited from N.
      merged := (n - keep) || coalesce(
        (select jsonb_object_agg(key, value) from jsonb_each(o) where key = any(keep)),
        '{}'::jsonb
      );
      if merged is distinct from n then
        if slot = 0 then
          NEW.data := jsonb_set(NEW.data, '{approval}', merged, false);
        else
          new_cos := jsonb_set(
            new_cos,
            array[(slot - 1)::text],
            jsonb_set(elem, '{approval}', merged, false),
            false
          );
          cos_dirty := true;
        end if;
      end if;
    end if;
  end loop;

  if cos_dirty then
    NEW.data := jsonb_set(NEW.data, '{changeOrders}', new_cos, false);
  end if;

  return NEW;
end;
$$;

drop trigger if exists preserve_job_approvals_trg on public.jobs;

-- UPDATE only: an INSERT has no stored decision to lose. PostgREST's
-- merge-duplicates upsert (INSERT ... ON CONFLICT DO UPDATE) fires this on its
-- conflict path with OLD = the stored row, which is the case that matters.
create trigger preserve_job_approvals_trg
  before update on public.jobs
  for each row
  execute function public.preserve_job_approvals();

-- ROLLBACK
--   drop trigger if exists preserve_job_approvals_trg on public.jobs;
-- The function can be left in place harmlessly.
--
-- NOTE: rows the trigger already processed keep the decisions it restored.
-- That is the correct state (the server recorded them), so there is nothing to
-- undo — but "drop the trigger" does not return those rows to what the stale
-- writer sent.
