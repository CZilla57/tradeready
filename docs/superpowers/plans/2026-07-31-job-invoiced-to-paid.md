# Job invoiced→paid Transition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Jobs advance from `invoiced` to `paid` when their linked invoice becomes fully paid — the transition has existed only as data (`JOB_STATUSES.invoiced.next`) since the pipeline was built; no code has ever performed it (owner smoke finding 2026-07-31; to be recorded as FA-037).

**Architecture:** Jobs follow invoice truth — a job is `paid` exactly when its linked invoice (`job.invoiceId`) is fully paid, and only ever advancing from exactly `invoiced` (never jumping a mid-pipeline job whose pre-work *deposit* invoice got fully paid). One pure helper, `advanceJobsForPaidInvoices(jobs, invoices)`, is wired at the two in-app settle points (InvoicesScreen mark-paid and record-payment) and as an idempotent read-side sweep on JobsScreen/JobDetailScreen load — the sweep both catches webhook-paid invoices arriving via sync pull (WITHOUT touching `utils/sync.ts`) and retroactively heals every already-stuck job in existing installs. The deposit-finalize edge (deposit covered 100% of the final bill) is closed by extending `jobChangesAfterInvoiceSave` with an `invoicePaid` flag.

**Tech Stack:** TypeScript, pure helpers in `utils/jobStatus.ts`, Jest (plain `.js` unit tests, no RNTL needed).

## Global Constraints

- Gate green before every commit, from `C:\Users\Chadr\OneDrive\Documents\TraderPro App\tradeready`: `npm run typecheck` 0 errors / `npm test` all pass (1350 baseline + new) / `npm run lint` 0 warnings.
- NO dependency, SDK, or `app.json` plugins changes. No `eslint-disable` / `@ts-ignore` / `@ts-expect-error`.
- **NO persisted data-shape changes** — the fix only writes an existing `JobStatus` enum value to the existing `status` field. No new fields (no `paidAt` on jobs — invoice `paidAt` remains the money-truth).
- **`utils/sync.ts` untouched** — pull-side coverage comes from the read-side sweep, deliberately, to stay out of approval-gated sync territory.
- Status transitions derive from the `JOB_STATUSES` `.next` chain (`utils/pricingEngine.ts`); `utils/jobStatus.ts` is the one sanctioned home for transition logic.
- No analytics on automatic transitions (matches `advanceStatusForSchedule` precedent; the invoice-side `invoice_paid` / `payment_recorded` events already fire at the settle points).
- Commit messages: imperative `feat:`/`fix:`/`docs:` subject, ending with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Do not push.
- Feature is NOT done until the owner's device smoke passes (checklist in Task 3).

---

### Task 1: Pure helpers + deposit-finalize edge (TDD)

**Files:**
- Test: `__tests__/jobStatus.test.js` (extend — the file exists with `describe` blocks per helper)
- Modify: `utils/jobStatus.ts` (add one helper; change one signature)
- Modify: `screens/CreateInvoiceFromJobScreen.tsx:212-263` (thread the new param)

**Interfaces:**
- Consumes: `isFullyPaid(invoice)` from `utils/invoicePayments` (no import cycle: invoicePayments imports only `types/models` + `moneyUtils`); `JOB_STATUSES` from `utils/pricingEngine`.
- Produces: `advanceJobsForPaidInvoices(jobs: Job[], invoices: Invoice[]): Job[]` — returns the SAME array reference when nothing changed (callers use `result !== jobs` to skip a redundant `saveJobs`); `jobChangesAfterInvoiceSave(mode, invoiceId, invoicePaid: boolean)` — Task 2 relies on both.

- [ ] **Step 1: Write the failing tests**

In `__tests__/jobStatus.test.js`, add `advanceJobsForPaidInvoices` to the existing `require('../utils/jobStatus')` destructure, then append a new describe block, and update the existing `jobChangesAfterInvoiceSave` block:

```js
describe('advanceJobsForPaidInvoices', () => {
  // isFullyPaid semantics (utils/invoicePayments): a legacy `paid: true` invoice
  // with no ledger synthesizes a full legacy_<id> payment; otherwise the payments
  // ledger must cover `amount`.
  const paidInvoice   = { id: 'inv1', amount: 500, paid: true };
  const ledgerPaid    = { id: 'inv2', amount: 200, paid: false, payments: [{ id: 'p1', amount: 200, date: '2026-07-30', method: 'cash' }] };
  const partlyPaid    = { id: 'inv3', amount: 300, paid: false, payments: [{ id: 'p2', amount: 100, date: '2026-07-30', method: 'cash' }] };

  it('advances an invoiced job whose linked invoice is fully paid (legacy flag)', () => {
    const jobs = [{ id: 'j1', status: 'invoiced', invoiceId: 'inv1' }];
    const out = advanceJobsForPaidInvoices(jobs, [paidInvoice]);
    expect(out[0].status).toBe('paid');
    expect(out).not.toBe(jobs); // changed → new array
  });

  it('advances on a fully-covering payment ledger too', () => {
    const jobs = [{ id: 'j1', status: 'invoiced', invoiceId: 'inv2' }];
    expect(advanceJobsForPaidInvoices(jobs, [ledgerPaid])[0].status).toBe('paid');
  });

  it('ignores a partly-paid invoice', () => {
    const jobs = [{ id: 'j1', status: 'invoiced', invoiceId: 'inv3' }];
    expect(advanceJobsForPaidInvoices(jobs, [partlyPaid])).toBe(jobs); // same ref = no-op
  });

  it('never jumps a mid-pipeline job whose DEPOSIT invoice is fully paid — the core invariant', () => {
    const jobs = [{ id: 'j1', status: 'scheduled', invoiceId: 'inv1' }];
    expect(advanceJobsForPaidInvoices(jobs, [paidInvoice])).toBe(jobs);
  });

  it('ignores jobs with no or dangling invoiceId', () => {
    const jobs = [
      { id: 'j1', status: 'invoiced', invoiceId: null },
      { id: 'j2', status: 'invoiced', invoiceId: 'gone' },
    ];
    expect(advanceJobsForPaidInvoices(jobs, [paidInvoice])).toBe(jobs);
  });

  it('handles a mixed list, advancing only the eligible job', () => {
    const jobs = [
      { id: 'j1', status: 'invoiced', invoiceId: 'inv1' },
      { id: 'j2', status: 'invoiced', invoiceId: 'inv3' },
      { id: 'j3', status: 'complete', invoiceId: null },
    ];
    const out = advanceJobsForPaidInvoices(jobs, [paidInvoice, partlyPaid]);
    expect(out.map((j) => j.status)).toEqual(['paid', 'invoiced', 'complete']);
  });
});
```

Replace the three existing `jobChangesAfterInvoiceSave` cases with:

```js
describe('jobChangesAfterInvoiceSave', () => {
  it('requesting a deposit early never advances status — the core invariant', () => {
    expect(jobChangesAfterInvoiceSave('requestDeposit', 'inv123', false)).toEqual({ invoiceId: 'inv123' });
  });

  it('creating at complete advances to invoiced', () => {
    expect(jobChangesAfterInvoiceSave('create', 'inv123', false)).toEqual({ status: 'invoiced', invoiceId: 'inv123' });
  });

  it('finalizing an unpaid balance advances to invoiced', () => {
    expect(jobChangesAfterInvoiceSave('finalize', 'inv123', false)).toEqual({ status: 'invoiced', invoiceId: 'inv123' });
  });

  it('finalizing an invoice the deposit already fully covered advances straight to paid', () => {
    expect(jobChangesAfterInvoiceSave('finalize', 'inv123', true)).toEqual({ status: 'paid', invoiceId: 'inv123' });
  });

  it('a fully-paid deposit request still never advances', () => {
    expect(jobChangesAfterInvoiceSave('requestDeposit', 'inv123', true)).toEqual({ invoiceId: 'inv123' });
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npm test -- jobStatus.test`
Expected: FAIL — `advanceJobsForPaidInvoices is not a function`, plus the updated three-arg expectations against the two-arg implementation.

- [ ] **Step 3: Implement in `utils/jobStatus.ts`**

Add the import at the top (alongside the existing ones):

```ts
import { isFullyPaid } from "./invoicePayments";
import type { Invoice } from "../types/models"; // extend the existing type-import line
```

Replace `jobChangesAfterInvoiceSave` (lines ~90-99) with:

```ts
/**
 * The Job patch to apply once CreateInvoiceFromJobScreen saves. The core
 * invariant lives here: requesting a deposit early must never advance the job
 * to "invoiced" — only finishing the job (create at complete, or finalize an
 * existing deposit invoice at complete) does that. `invoicePaid` covers the
 * finalize edge where the deposit already settled the whole bill
 * (reconcilePaidFields marks the invoice paid at save time): the job then
 * lands straight on "paid" — invoiced's own `.next` — instead of sitting on
 * an "invoiced" status no code would ever advance.
 */
export function jobChangesAfterInvoiceSave(
  mode: InvoiceScreenMode,
  invoiceId: string,
  invoicePaid: boolean,
): Partial<Job> {
  if (mode === "requestDeposit") return { invoiceId };
  return { status: invoicePaid ? "paid" : "invoiced", invoiceId };
}
```

Add the new helper after `isJobDunningEligible`:

```ts
/**
 * Jobs follow invoice truth: a job is "paid" exactly when the invoice it is
 * linked to (job.invoiceId) is fully paid. Advances ONLY from exactly
 * "invoiced" — a mid-pipeline job whose pre-work DEPOSIT invoice got fully
 * paid must not jump the pipeline (no-skip mirror of
 * advanceStatusForSchedule's no-regress guarantee).
 *
 * Returns the SAME array reference when nothing changed, so callers can skip
 * saveJobs (`result !== jobs`). Idempotent — safe to run as a read-side
 * sweep, which is also how webhook-paid invoices arriving via sync pull get
 * reflected without touching utils/sync.ts, and how jobs stuck at "invoiced"
 * from before this fix (FA-037) self-heal.
 */
export function advanceJobsForPaidInvoices(jobs: Job[], invoices: Invoice[]): Job[] {
  const paidInvoiceIds = new Set(invoices.filter(isFullyPaid).map((inv) => inv.id));
  let changed = false;
  const next = jobs.map((j) => {
    if (j.status === "invoiced" && j.invoiceId && paidInvoiceIds.has(j.invoiceId)) {
      changed = true;
      return { ...j, status: JOB_STATUSES.invoiced.next ?? j.status };
    }
    return j;
  });
  return changed ? next : jobs;
}
```

- [ ] **Step 4: Thread the new param through `screens/CreateInvoiceFromJobScreen.tsx`**

In `handleCreate`, both save branches already exist (~lines 212-257). Capture whether the saved invoice is paid: in the finalize branch, after `const updatedInvoice: Invoice = reconcilePaidFields({...})`, the flag is `updatedInvoice.paid`; the create branch always builds `paid: false`. Declare alongside `savedInvoiceId`:

```ts
      let savedInvoiceId: string;
      let savedInvoicePaid = false;
```

In the finalize branch, after `savedInvoiceId = freshInvoice.id;` add:

```ts
        savedInvoicePaid = !!updatedInvoice.paid;
```

And change the call at ~line 259 to:

```ts
      const jobChanges = jobChangesAfterInvoiceSave(mode, savedInvoiceId, savedInvoicePaid);
```

- [ ] **Step 5: Run the focused tests to verify they pass**

Run: `npm test -- jobStatus.test`
Expected: PASS, all cases.

- [ ] **Step 6: Run the full gate**

Run: `npm run typecheck` then `npm test` then `npm run lint`
Expected: 0 / all pass (1350 + 8 new = 1358 expected; adjust if the actual count differs, but ALL must pass) / 0. The typecheck also proves no other `jobChangesAfterInvoiceSave` call site exists (tsc would flag a two-arg call).

- [ ] **Step 7: Commit**

```bash
git add utils/jobStatus.ts __tests__/jobStatus.test.js screens/CreateInvoiceFromJobScreen.tsx
git commit -m "feat: advance jobs invoiced->paid when their invoice is fully paid

The invoiced->paid transition existed only as pipeline data - no code
ever performed it (FA-037), so every job stalled at invoiced forever.
advanceJobsForPaidInvoices follows invoice truth, advancing only from
exactly invoiced so a fully-paid pre-work deposit never jumps a
mid-pipeline job; jobChangesAfterInvoiceSave gains an invoicePaid flag
so finalizing a deposit-covered bill lands straight on paid.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Wire the settle points and the read-side sweep

**Files:**
- Modify: `screens/InvoicesScreen.tsx` (imports; `markPaid`; `handleRecordPayment`)
- Modify: `screens/JobsScreen.tsx` (focus effect + refresh handler)
- Modify: `screens/JobDetailScreen.tsx` (the `load()` in its focus effect)

**Interfaces:**
- Consumes: `advanceJobsForPaidInvoices(jobs, invoices): Job[]` from Task 1 (same-reference no-op contract) and `loadJobs`/`saveJobs`/`loadInvoices` from `utils/storage`.
- Produces: nothing consumed later; Task 3's smoke exercises it.

**Why no new automated test:** all four wirings are screen plumbing around the Task-1-tested helper; these screens have no render-test harness (repo precedent). The full gate plus device smoke covers them.

- [ ] **Step 1: InvoicesScreen — settle points**

Extend the storage import (line ~20):

```ts
import { loadInvoices, saveInvoices, loadSettings, loadJobs, saveJobs } from "../utils/storage";
```

Import the helper (with the existing invoice-helper imports):

```ts
import { advanceJobsForPaidInvoices } from "../utils/jobStatus";
```

Add one local function (below `handleRecordPayment` is fine):

```ts
  // Jobs follow invoice truth (FA-037): after any save that can settle an
  // invoice, advance its linked job invoiced -> paid. Same-reference return
  // means nothing changed and the save is skipped.
  async function reconcileJobsWith(updatedInvoices: Invoice[]) {
    const jobs = await loadJobs();
    const advanced = advanceJobsForPaidInvoices(jobs, updatedInvoices);
    if (advanced !== jobs) await saveJobs(advanced);
  }
```

In `markPaid`'s confirm `onPress`, directly after `await saveInvoices(updated);` add:

```ts
          await reconcileJobsWith(updated);
```

In `handleRecordPayment`, directly after its `await saveInvoices(updated);` add:

```ts
    await reconcileJobsWith(updated);
```

(Both functions already build `updated` — the full post-save invoice list — in scope. Do not reorder anything else; the `track(...)`/`syncNotifications()` calls stay where they are.)

- [ ] **Step 2: JobsScreen — sweep on focus and refresh**

Extend imports: `loadJobs` → `loadJobs, loadInvoices, saveJobs` (from `../utils/storage`) and add `import { advanceJobsForPaidInvoices } from "../utils/jobStatus";`.

Replace the focus effect body and refresh handler (currently `loadJobs().then(setJobs)` / `setJobs(await loadJobs())`) with a shared local:

```ts
  // Read-side sweep (FA-037): reflects invoices paid outside this device's
  // settle flows (Stripe webhook via sync pull) and heals jobs stuck at
  // "invoiced" from before the fix. Local-only reads; writes only on change.
  const refreshJobs = useCallback(async () => {
    const [jobs, invoices] = await Promise.all([loadJobs(), loadInvoices()]);
    const advanced = advanceJobsForPaidInvoices(jobs, invoices);
    if (advanced !== jobs) await saveJobs(advanced);
    setJobs(advanced);
  }, []);

  useFocusEffect(
    useCallback(() => {
      refreshJobs();
    }, [refreshJobs])
  );

  const { refreshing, onRefresh } = useRefresh(refreshJobs, 'JobsScreen');
```

- [ ] **Step 3: JobDetailScreen — sweep in `load()`**

Extend imports: add `loadInvoices` to the storage import and `advanceJobsForPaidInvoices` to the `../utils/jobStatus` import (which already imports `canSendEstimate, canRequestDeposit`).

In the focus effect's `load()`, the current code is:

```ts
          const [jobs, customers] = await Promise.all([
            loadJobs(),
            loadCustomers(),
          ]);
          if (!active) return;

          const j = jobs.find((x: Job) => x.id === jobId);
```

Replace with:

```ts
          const [jobs, customers, invoices] = await Promise.all([
            loadJobs(),
            loadCustomers(),
            loadInvoices(),
          ]);
          if (!active) return;

          // Read-side sweep (FA-037) — same reconcile as JobsScreen, so a
          // webhook-paid invoice is reflected even when the user deep-links
          // straight here without visiting the Jobs list.
          const advanced = advanceJobsForPaidInvoices(jobs, invoices);
          if (advanced !== jobs) await saveJobs(advanced);

          const j = advanced.find((x: Job) => x.id === jobId);
```

(`saveJobs` is already imported in JobDetailScreen — verify; if not, add it.)

- [ ] **Step 4: Run the full gate**

Run: `npm run typecheck` then `npm test` then `npm run lint`
Expected: 0 / all pass / 0.

- [ ] **Step 5: Commit**

```bash
git add screens/InvoicesScreen.tsx screens/JobsScreen.tsx screens/JobDetailScreen.tsx
git commit -m "feat: wire job paid-status reconcile at settle points and loads

Mark-paid and record-payment now advance the linked job when the
invoice settles; JobsScreen and JobDetailScreen run the idempotent
sweep on load, covering webhook-paid invoices from sync pull and
healing jobs stuck at invoiced from before FA-037.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: FA-037 record, docs, and device smoke

**Files:**
- Modify: `..\.claude\skills\tradeready-failure-archaeology\SKILL.md` (index) and its `references\chronicle.md` (full entry) — outside the repo
- Check: `ARCHITECTURE.md` for any "jobs end at invoiced"-style claim (unlikely; fix only if found)

- [ ] **Step 1: Record FA-037**

In the archaeology SKILL.md index, Era 6 table, append:

```
| FA-037 | Job invoiced→paid transition existed only as pipeline data — no code ever performed it; every job stalled at "invoiced" (found in owner device smoke of the settings-gear feature) | fixed 2026-07-31 (`advanceJobsForPaidInvoices` in utils/jobStatus.ts + settle-point/load sweeps) |
```

Update the index header count (36 → 37 entries) and the maintenance note's next-free ID (FA-037 → FA-038). Append a full entry to `references/chronicle.md` following its existing format: symptom (owner smoke: "all jobs seem to end at invoiced even when fully paid"), root cause (`.next` chain data with no consumer; JobDetail's invoiced action navigates instead of advancing; InvoicesScreen settles invoices without touching jobs; `git log -S 'status: "paid"'` proves the code never existed; even sample data has no paid job, so the Paid filter was empty for every user since launch), resolution (this plan's two commits), and the FA-011 cross-reference (same bug shape: a pipeline step with no driver).

- [ ] **Step 2: Sweep ARCHITECTURE.md**

Run: `npx rg -n -i "invoiced" ARCHITECTURE.md` — update any sentence that describes the job lifecycle as ending at invoiced or omits the paid transition; leave everything else. Commit only if changed:

```bash
git add ARCHITECTURE.md
git commit -m "docs: record the job invoiced->paid reconcile

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 3: Owner device smoke (Expo Go) — feature is not done until this passes**

1. Invoices tab → "Mark paid" on an invoice linked to an invoiced job → Jobs tab: the job now shows **Paid** (badge + "Paid" filter), and JobDetail's pipeline bar reads 8 of 8.
2. Record a PARTIAL payment on another linked invoice → job stays **Invoiced**; record the remainder → job flips to **Paid**.
3. Pre-work deposit guard: request a deposit on an `approved` job, mark that deposit invoice fully paid → the job stays **approved** (does NOT jump).
4. Deposit-finalize edge: on a `complete` job whose deposit already covered the full amount, finalize the invoice → job goes straight to **Paid**.
5. Healing: any old fully-paid-but-invoiced job flips to Paid the first time the Jobs tab (or its JobDetail) is opened.
6. Jobs "Paid" filter now lists these jobs; "Complete" no longer shows them.

---

## Self-review (done at plan time)

- **Coverage:** helper + no-skip invariant ✓ (Task 1 Steps 1/3), deposit-finalize edge ✓ (Steps 1/4), both in-app settle points ✓ (Task 2 Step 1), webhook/pull coverage + retroactive healing without touching sync.ts ✓ (Task 2 Steps 2-3), FA-037 record ✓ (Task 3). Verified 2026-07-31: `git log -S 'status: "paid"'` over screens/utils returns nothing — no existing call site can conflict; tsc guards the signature change (only one caller exists).
- **Placeholder scan:** none.
- **Type consistency:** `advanceJobsForPaidInvoices(jobs: Job[], invoices: Invoice[]): Job[]` same-reference contract is stated in Task 1's Produces block and consumed verbatim by all four Task 2 call sites; `jobChangesAfterInvoiceSave(mode, invoiceId, invoicePaid)` third arg is `boolean` in helper, tests, and the one call site.
