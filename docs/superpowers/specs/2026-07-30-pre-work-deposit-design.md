# Pre-work deposits — request a deposit before the job starts

**Date:** 2026-07-30
**Branch:** `feat/pre-work-deposit`
**Status:** design approved, awaiting implementation plan

## Problem

Deposits (`feat/deposits-partial-payments`, merged to master `517ff6e`) are entirely
modeled on the `Invoice` object — `DepositRequest`, the payment ledger, cached
payment links, all of it lives on `types/models.ts:256` `Invoice`. But an `Invoice`
does not exist until the job reaches `"complete"` status and the owner taps
**Create invoice** (`screens/JobDetailScreen.tsx:514-519`, which navigates to
`screens/CreateInvoiceFromJobScreen.tsx`). That screen creates the invoice and
immediately advances `job.status` to `"invoiced"` (`CreateInvoiceFromJobScreen.tsx:178`).

Consequence: there is no way to collect a deposit before work starts. The owner
can only ask for money once the job is already done — the opposite of how deposits
are normally used (securing a booking, buying materials up front).

## Job status pipeline (unchanged reference)

```
lead → estimate_sent → approved → scheduled → in_progress → complete → invoiced → paid
```

(`utils/pricingEngine.ts` `JOB_STATUSES`, `utils/jobStatus.ts`.) Progression is driven
by `JobDetailScreen.advanceStatus()` walking `JOB_STATUSES[status].next` — **entirely
independent of whether an invoice exists.** The `"complete" → "invoiced"` step is the
one exception: it's driven by invoice creation, not `advanceStatus()`. This design
preserves that independence — creating an invoice early must not perturb the normal
`approved → scheduled → in_progress → complete` walk.

## What already exists (no changes needed)

| Piece | Location | Notes |
|---|---|---|
| Payment ledger, `balanceDue`, `isDepositSatisfied` | `utils/invoicePayments.ts` | amount-agnostic, works on any invoice regardless of when it was created |
| `DepositRequest`, deposit UI (Full/50%/Custom) | `screens/OutreachScreen.tsx` | reads `invoiceId` from route params only — doesn't care about job status |
| Deposit display on invoice list | `screens/InvoicesScreen.tsx:377` | renders `inv.depositRequest` generically, no job-status check |
| Invoice prefill-from-job (amount, line items, customer) | `CreateInvoiceFromJobScreen.tsx:79-109` | reuses `job.estimateTotal` / `computeEstimateBreakdown(job)`, both known as soon as the estimate exists — already stage-agnostic in practice |

Because all of this is already keyed off `invoiceId`, not job status, the ledger and
Outreach deposit UI need **zero changes**. The gap is purely in *when an invoice gets
created* and *what happens to job status when it does*.

## Design

### 1. JobDetailScreen — new secondary action

Add a secondary action below the existing primary action (`PrimaryAction`,
`JobDetailScreen.tsx:480-547`), shown only for `job.status` in
`["approved", "scheduled", "in_progress"]`:

- `!job.invoiceId` → **"Request deposit →"**, navigates to `CreateInvoiceFromJob`
  (same route, same `{ jobId }` param — no navigation type changes).
- `job.invoiceId` set → **"View deposit →"**, navigates straight to
  `Outreach` with the existing `invoiceId` (identical to the `invoiced`-status
  primary action already does at `JobDetailScreen.tsx:520-528`).

The existing primary action per status is unchanged. This is additive only.

At `"complete"`, the primary action itself now branches:
- `!job.invoiceId` → **"Create invoice"**, unchanged behavior.
- `job.invoiceId` set (a deposit was requested earlier) → **"Finalize invoice"**,
  same route, screen picks up finalize mode (below).

### 2. CreateInvoiceFromJobScreen — three modes

Same file, same route params (`{ jobId }`). The screen branches on
`(job.status, job.invoiceId)` at load time — no new route params needed, everything
required is already on the loaded `Job` record.

**Mode A — Create at complete** (`status === "complete"`, no `invoiceId`)
Exactly today's behavior, byte-for-byte: prefill from job estimate, create new
invoice, set `job.status = "invoiced"` + `invoiceId`, navigate to Outreach.

**Mode B — Create early / request deposit** (`status` ∈ `{approved, scheduled,
in_progress}`, no `invoiceId`)
Same prefill and same save path as Mode A, with two differences:
- Does **not** touch `job.status` — only writes `invoiceId` onto the job.
- Copy changes: screen title and button read "Request deposit" / "Request deposit →"
  instead of "Create Invoice" / "Create invoice →", since the job isn't done and
  calling it an "invoice" at this point would be misleading.
Still navigates to Outreach afterward — requesting a deposit and immediately seeing
the deposit-ask UI is the whole point.

**Mode C — Finalize** (`status === "complete"`, `invoiceId` already set)
Prefill comes from the **existing invoice's current fields** (not recomputed fresh
from the job) — a manually-adjusted deposit-time amount must not be silently
clobbered by re-deriving from `job.estimateTotal`. Adds a banner showing the deposit
already requested/paid on that invoice (reuse the same `DepositRequest` /
`isDepositSatisfied` read `OutreachScreen.tsx` already does). Saving **updates the
existing invoice in place** — never creates a second one — and this save is what
flips `job.status` to `"invoiced"`. Title/button: "Finalize invoice" / "Finalize
invoice →".

Line items and amount remain editable in Mode C exactly as they are today in Mode A,
so scope changes between deposit and completion (extra materials, longer job) are
handled by the existing editable-amount UI — no new logic. The already-collected
deposit continues to show as a payment in the ledger; `balanceDue` recalculates
automatically via `utils/invoicePayments.ts`, unchanged.

### 3. Edge cases (decided, not deferred)

- **Job revised or declined after a deposit invoice exists**
  (`JobDetailScreen.handleReviseAndResend`, which resets `status` to
  `"estimate_sent"` and clears the approval decision): the invoice is left alone —
  not voided, not deleted. This matches the existing void-not-delete philosophy
  already used for the payment ledger (`utils/invoicePayments.ts`). If the job is
  later re-approved and completes, Mode C picks up that same invoice via
  `job.invoiceId`. If it stays declined, the deposit invoice simply persists and can
  be voided/refunded manually through the existing Outreach/invoice UI — no new
  cascade logic.
- **Job deleted while it has a deposit invoice** (`JobDetailScreen.handleDelete`):
  unchanged — deleting a job never cascades to its invoice today (true already for
  `invoiced`/`paid` jobs), so no new code is needed.
- **Invoices tab**: pre-complete deposit invoices appear like any other invoice —
  confirmed `InvoicesScreen.tsx` renders `depositRequest` without checking job
  status.

### 4. Non-goals

- No changes to the payment ledger, Stripe webhook, payment-math, or PDF templates.
- No new `Job` or `Invoice` fields — `invoiceId` on `Job` already exists
  (`types/models.ts`) and is reused as-is.
- No navigation type changes — both routes keep their existing param shapes.

## Testing plan

This codebase has no screen-level (RNTL) tests anywhere — `utils/jobStatus.ts`
already exists specifically to hold status-transition logic "kept out of the
screens so it's unit-tested." Following that established pattern, all of the new
*decision* logic is extracted into pure functions in `utils/jobStatus.ts` and
covered in `__tests__/jobStatus.test.js`; the screens stay thin callers and are
not separately unit-tested (consistent with `JobDetailScreen.tsx` and
`CreateInvoiceFromJobScreen.tsx` today, neither of which has a test file).

New pure helpers, all unit-tested:
- `canRequestDeposit(status: JobStatus): boolean` — true for
  `approved`/`scheduled`/`in_progress`.
- `invoiceScreenMode(status: JobStatus, hasInvoice: boolean): "create" |
  "requestDeposit" | "finalize" | null` — the single source of truth for which of
  the three `CreateInvoiceFromJobScreen` modes applies (see Design §2). Returns
  `null` for any status/invoiceId combination that should never reach the screen.
- `jobChangesAfterInvoiceSave(mode, invoiceId): Partial<Job>` — the exact `Job`
  patch to apply after saving the invoice. This is the function that encodes the
  core invariant: `"requestDeposit"` returns `{ invoiceId }` only, never touching
  `status`; `"create"` and `"finalize"` both return `{ status: "invoiced",
  invoiceId }`. Directly unit-testable without touching AsyncStorage or navigation.
- `invoiceScreenCopy(mode): { title: string; cta: string }` — the title/button text
  per mode ("Request Deposit" / "Finalize Invoice" / "Create Invoice").

`CreateInvoiceFromJobScreen.handleCreate` and `prefillFromJob` call these helpers
rather than re-deriving the branching inline, so the only untested code is
straight-line UI wiring (which field maps to which `<Field>`, which navigation
call fires) — no conditional business logic left unverified.

Full gate (`tsc`, tests, lint) must stay green before merge, per
`tradeready-change-control`.
