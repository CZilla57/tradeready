# Deposits — Collection Surfaces, Overpayment, and the Sync Derivation Gap

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the app quoting a customer two different numbers for the same invoice, make overpaid money visible, and close the one sync path that bypasses `paid` derivation.

**Architecture:** Three whole-branch review findings. C1 — every customer-facing collection surface except the PDF still quotes the invoice's face amount. C2 — overpayment is silently absorbed. I1 — a pulled invoice with no local copy keeps whatever `paid` its blob cached. Two small pure additions come first, then the call sites.

**Tech Stack:** TypeScript, React Native (Expo 54), Jest, no new dependencies.

**Source:** the whole-branch review recorded in `.superpowers/sdd/progress.md`.

## Decisions (owner-approved)

| Decision | Choice |
|---|---|
| Message copy for a partly-paid invoice | Show BOTH numbers — "$600.00 of $1,000.00 still outstanding" — so the customer sees their deposit was credited |
| Payment link amount | Defaults to `balanceDue` now; Phase 5's deposit-request selector can override explicitly later without rework |
| Overpayment | An `overpaidAmount` derivation surfaced on the invoice row and in the detail modal. No refund flow |

## Global Constraints

- **No new dependencies.** No `package.json` change.
- **Gate green before every commit:** `npm run typecheck` (0 errors), `npm test` (0 failures), `npm run lint` (0 warnings — `--max-warnings=0`).
- **Starting baseline: 1033 tests / 62 suites** on branch `feat/deposits-partial-payments` @ `5cfd28f`.
- **These four files must remain unedited and passing:** `__tests__/invoicePaymentsLegacyEquivalence.test.js`, `__tests__/paymentMathParity.test.js`, `__fixtures__/invoiceHtmlGolden.js`, `__fixtures__/paymentVectors.js`.
- **If any OTHER pre-existing test fails, STOP and report** — do not edit the test and do not add a defensive branch to the source. Both moves were made earlier in this feature and both were wrong. Task 5 is the one place a pre-existing test legitimately changes, and it says so explicitly.
- **Legacy invoices must behave exactly as before.** On an invoice with no ledger, `balanceDue` equals `amount` when unpaid and `0` when paid, so every change here is a no-op for them. Tests must prove it.
- Do NOT apply the migration, deploy anything, or contact a database.
- Money is a plain `number` of dollars. Dates are `"YYYY-MM-DD"` strings.
- Shell is PowerShell on Windows; a Bash tool is also available.

## Existing interfaces

```ts
// utils/invoicePayments.ts — all tested, all coerce malformed amounts to zero
amountPaid(invoice), balanceDue(invoice), isFullyPaid(invoice), isPartlyPaid(invoice),
reconcilePaidFields(invoice)   // re-derives paid/paidAt; returns the SAME object when the ledger is empty
// utils/format.ts
formatMoney(n)
```

## File structure

| File | Change |
|---|---|
| `utils/invoicePayments.ts` | Add `overpaidAmount` |
| `utils/invoiceHelpers.ts` | Links, cache key, both message builders, plan math |
| `backend/lib/reminderEmail.js` | Cron email copy |
| `screens/InvoicesScreen.tsx` | Surface overpayment |
| `utils/syncMerge.ts`, `utils/sync.ts` | I1 |
| `ARCHITECTURE.md` | Docs |

---

### Task 1: `overpaidAmount`

**Files:** Modify `utils/invoicePayments.ts`; Test `__tests__/invoicePayments.test.js`

- [ ] **Step 1: Write the failing tests**

Append to `__tests__/invoicePayments.test.js` (existing `inv()` / `pmt()` helpers):

```js
describe("overpaidAmount", () => {
  test("is zero for an invoice paid exactly", () => {
    expect(overpaidAmount(inv({ amount: 1000, payments: [pmt({ id: "p1", amount: 1000 })] }))).toBe(0);
  });

  test("is zero for a partly-paid invoice", () => {
    expect(overpaidAmount(inv({ amount: 1000, payments: [pmt({ id: "p1", amount: 400 })] }))).toBe(0);
  });

  test("reports the excess when overpaid", () => {
    const i = inv({
      amount: 1000,
      payments: [pmt({ id: "p1", amount: 400 }), pmt({ id: "p2", amount: 1000 })],
    });
    expect(overpaidAmount(i)).toBe(400);
  });

  test("ignores voided payments", () => {
    const i = inv({
      amount: 1000,
      payments: [pmt({ id: "p1", amount: 1000 }), pmt({ id: "p2", amount: 500, voidedAt: "2026-07-22" })],
    });
    expect(overpaidAmount(i)).toBe(0);
  });

  test("is zero for a legacy paid invoice", () => {
    expect(overpaidAmount(inv({ amount: 1000, paid: true, payments: undefined }))).toBe(0);
  });

  test("is zero for a legacy unpaid invoice", () => {
    expect(overpaidAmount(inv({ amount: 1000, paid: false, payments: undefined }))).toBe(0);
  });
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `npx jest __tests__/invoicePayments.test.js`
Expected: FAIL — `overpaidAmount is not a function`.

- [ ] **Step 3: Implement**

Append to `utils/invoicePayments.ts`:

```ts
/**
 * Money received BEYOND what the invoice was for, in dollars. Zero normally.
 *
 * balanceDue clamps at zero, which is right for "what's still owed" but means
 * an overpayment vanishes from every surface. A customer who pays a
 * full-amount link after already paying a deposit hands over more than the
 * invoice was for, and the tradesperson needs to know they owe it back.
 *
 * Voided entries are excluded, and a legacy invoice always reports zero — its
 * implied payment is exactly its amount by construction.
 */
export function overpaidAmount(invoice: Invoice): number {
  return Math.max(0, amountPaid(invoice) - toAmount(invoice.amount));
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `npx jest __tests__/invoicePayments.test.js`
Expected: PASS — 6 new tests.

- [ ] **Step 5: Gate and commit**

Run: `npm run typecheck && npm test && npm run lint`

```bash
git add utils/invoicePayments.ts __tests__/invoicePayments.test.js
git commit -m "feat: add overpaidAmount

balanceDue clamps at zero, so money paid beyond the invoice total vanished
from every surface. This makes it visible."
```

---

### Task 2: The collection surfaces in `utils/invoiceHelpers.ts`

**Files:** Modify `utils/invoiceHelpers.ts`; Test `__tests__/invoiceHelpers.test.js`

**This is the core of C1.** Seven sites, all reading `invoice.amount`. After a $400 deposit on a $1,000 invoice, the PDF says "BALANCE DUE $600" while these charge and dun for $1,000.

**Read the whole file first.** Note there are TWO message builders — `buildGenericMessage` (~line 143) and the AI-prompt path in `generateOutreachMessage` (~line 279). Both need the same treatment; that duplication is pre-existing and is NOT to be refactored here.

- [ ] **Step 1: Write the failing tests**

Append to `__tests__/invoiceHelpers.test.js`. Read its existing conventions first — it pins "today" with `jest.setSystemTime`, and your `due` dates must be past/future relative to THAT date. Report what it pins.

```js
describe("collection surfaces use the remaining balance", () => {
  const partly = (over) => ({
    id: "i1", customer: "Acme", number: "INV-1", desc: "Work", email: "a@b.com", phone: "",
    amount: 1000, paid: false,
    payments: [{ id: "p1", amount: 400, date: "2026-07-01", method: "cash" }],
    ...over,
  });

  test("buildPaymentLink charges the balance, not the invoice total", () => {
    const url = buildPaymentLink(partly({ due: "2026-08-01" }), "paypal", "someone");
    expect(url).toContain("600");
    expect(url).not.toContain("1000");
  });

  test("the outreach message shows BOTH the balance and the invoice total", () => {
    const msg = buildOutreachMessage({
      invoice: partly({ due: "2026-06-01" }), channel: "text", biz: { businessName: "Acme Co" },
    });
    expect(msg).toContain("$600.00");
    expect(msg).toContain("$1,000.00");
  });

  test("an untouched invoice's message is unchanged — one number only", () => {
    const msg = buildOutreachMessage({
      invoice: { ...partly({ due: "2026-06-01" }), payments: undefined },
      channel: "text", biz: { businessName: "Acme Co" },
    });
    expect(msg).toContain("$1,000.00");
    expect(msg).not.toContain("still outstanding");
  });

  test("a payment plan splits the REMAINING balance, not the original total", () => {
    const msg = buildOutreachMessage({
      invoice: partly({ due: "2026-06-01" }), channel: "text", biz: {},
      paymentPlan: { enabled: true, installments: 3, frequency: "Monthly" },
    });
    // $600 / 3 = $200, not $1000 / 3 = $333.33
    expect(msg).toContain("$200.00");
    expect(msg).not.toContain("$333.33");
  });
});
```

**The exported name of the message builder may not be `buildOutreachMessage`** — read the file and use whatever is actually exported (it may only be reachable via `generateOutreachMessage`). If the generic builder is private, test through the public entry point and say so in your report. Do NOT export something new just to make testing easier without saying so.

- [ ] **Step 2: Run to verify they fail**

Run: `npx jest __tests__/invoiceHelpers.test.js`
Expected: FAIL — links contain 1000, messages show only the face amount.

- [ ] **Step 3: Add a shared copy helper**

Both message builders need identical phrasing. Add near the top of `utils/invoiceHelpers.ts`:

```ts
/**
 * How to describe what a customer owes, in one place for both message builders.
 *
 * A partly-paid invoice names BOTH numbers so the customer can see their
 * deposit was credited — quoting only the balance misstates the invoice, and
 * quoting only the total asks them to pay money they already sent.
 */
function describeAmountOwed(invoice: Invoice): string {
  const balance = balanceDue(invoice);
  if (isPartlyPaid(invoice)) {
    return `${formatMoney(balance)} of ${formatMoney(invoice.amount)} still outstanding`;
  }
  return formatMoney(balance);
}
```

Add `balanceDue` and `isPartlyPaid` to the existing `./invoicePayments` import.

- [ ] **Step 4: Convert the seven sites**

| Line | Now | Becomes |
|---|---|---|
| ~59 `buildPaymentLink` | `invoice.amount.toFixed(2)` | `balanceDue(invoice).toFixed(2)` |
| ~81 `resolvePaymentLink` | `invoice.paymentLinkAmount === invoice.amount` | `invoice.paymentLinkAmount === balanceDue(invoice)` |
| ~117 `fetchPaymentLink` | `amount: invoice.amount` | `amount: balanceDue(invoice)` |
| ~145 `buildGenericMessage` | `const amt = formatMoney(invoice.amount)` | `const amt = describeAmountOwed(invoice)` |
| ~150 plan math | `invoice.amount / installments` | `balanceDue(invoice) / installments` |
| ~281 AI-prompt path | `const amt = formatMoney(invoice.amount)` | `const amt = describeAmountOwed(invoice)` |
| ~286 plan math | `invoice.amount / installments` | `balanceDue(invoice) / installments` |

Check the sentences that consume `amt` still read correctly with the longer string — e.g. `"invoice ${number} for ${amt} is ${overdueText}"` becomes "invoice INV-1 for $600.00 of $1,000.00 still outstanding is 5 days overdue", which is clumsy. Reword the surrounding sentence in BOTH builders so it reads naturally, e.g. `"invoice ${number} — ${amt}, ${overdueText}"`. Say in your report what the final sentences read like for both a partly-paid and an untouched invoice.

- [ ] **Step 5: Run to verify they pass**

Run: `npx jest __tests__/invoiceHelpers.test.js`
Expected: PASS, with every pre-existing test in that file passing untouched.

- [ ] **Step 6: Gate and commit**

Run: `npm run typecheck && npm test && npm run lint`

```bash
git add utils/invoiceHelpers.ts __tests__/invoiceHelpers.test.js
git commit -m "fix: collection surfaces quote the balance, not the invoice total

After a \$400 deposit the PDF said BALANCE DUE \$600 while the payment link
charged \$1,000 and the outreach message dunned for \$1,000. Partly-paid
invoices now name both numbers so the customer sees their deposit credited,
and payment plans split what's left rather than the original total."
```

---

### Task 3: The cron reminder email

**Files:** Modify `backend/lib/reminderEmail.js`; Test — find its suite with `grep -rln "buildReminderEmail" __tests__/`

This is the newly-reachable one: Phase 2b deliberately made `selectInvoicesToRemind` select partly-paid invoices, so this email now goes out for them quoting the full amount.

`backend/` is a separate CommonJS package and cannot import the TypeScript util, so it needs its own small copy of the phrasing.

- [ ] **Step 1: Write the failing test**

Find the existing suite first. Add a case asserting that a partly-paid invoice's email names both numbers and an untouched one names only the total. Match the file's existing fixture conventions.

If no suite exists, create `__tests__/reminderEmail.test.js` and cover the existing behaviour first (an untouched overdue invoice's subject and body) before adding the new case — never change an untested module's behaviour without first pinning what it does.

- [ ] **Step 2: Run to verify it fails**

Run: `npx jest` on that file. Expected: FAIL — the email quotes $1,000.

- [ ] **Step 3: Implement**

In `backend/lib/reminderEmail.js`, add beside the existing requires:

```js
const { balanceDue, amountPaid } = require("./paymentMath");
```

Replace line ~10:

```js
  const amount = formatMoney(invoice.amount);
```

with:

```js
  // Mirrors describeAmountOwed in utils/invoiceHelpers.ts. A partly-paid
  // invoice names both numbers so the customer sees their deposit credited.
  // backend/ is a separate package and cannot import the TS util.
  const paid = amountPaid(invoice);
  const balance = balanceDue(invoice);
  const amount = paid > 0 && balance > 0
    ? `${formatMoney(balance)} of ${formatMoney(invoice.amount)} still outstanding`
    : formatMoney(balance);
```

Then check the sentence at ~line 20 (`"invoice ${invoice.number} for ${amount} is now ${days} days past due"`) still reads naturally with the longer string, and reword if not. Report the final copy.

- [ ] **Step 4: Run, gate, commit**

Run: `npm run typecheck && npm test && npm run lint`

```bash
git add backend/lib/reminderEmail.js __tests__/
git commit -m "fix: cron reminder email quotes the balance

Phase 2b made the cron select partly-paid invoices, so this email was newly
reachable and quoted the full invoice amount. NOT DEPLOYED — owner-gated."
```

---

### Task 4: Surface overpayment

**Files:** Modify `screens/InvoicesScreen.tsx`

**Interfaces:** Consumes `overpaidAmount` (Task 1).

This screen has no test suite; keep the diff minimal and read the surrounding code first.

- [ ] **Step 1: Show it on the invoice row**

The row currently renders balance-forward text when partly paid and `formatMoney(inv.amount)` otherwise. Add a third case ABOVE the partly-paid check, since an overpaid invoice is fully paid and would otherwise fall through to the plain amount:

```tsx
          {overpaidAmount(inv) > 0 ? (
            <Text style={styles.amount}>
              {formatMoney(inv.amount)} · overpaid by {formatMoney(overpaidAmount(inv))}
            </Text>
          ) : isPartlyPaid(inv) ? (
            /* …existing partly-paid branch, unchanged… */
          ) : (
            /* …existing default branch, unchanged… */
          )}
```

Read the existing block and preserve its exact style names and structure — only the new outer branch is added.

- [ ] **Step 2: Show it in the detail modal**

Add the same information to the detail modal's amount area, matching whatever style names that section already uses. Read it first; do not invent style entries.

- [ ] **Step 3: Add `overpaidAmount` to the imports**

Extend the existing `../utils/invoicePayments` import statement.

- [ ] **Step 4: Gate and commit**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0, test count unchanged.

```bash
git add screens/InvoicesScreen.tsx
git commit -m "feat: show when an invoice has been overpaid

balanceDue clamps at zero, so money paid beyond the total was invisible on
every surface. The tradesperson needs to know they owe it back."
```

---

### Task 5: I1 — the sync path that bypasses derivation

**Files:** Modify `utils/syncMerge.ts`, `utils/sync.ts`; Test `__tests__/syncMerge.test.js`

**Read this carefully — an earlier attempt at this fix was wrong.**

The bug: a pulled invoice with NO local copy keeps whatever `paid` its blob cached. A fresh install can render "12d overdue" beside that same row's "$0.00 due · $1,400.00 paid".

**The obvious fix does not work.** `mergeRemoteRecord`'s `!local` guard looks like the right place, but `utils/sync.ts` never calls it for that case:

```ts
          if (idx >= 0) {
            local[idx] = mergeRemoteRecord(table, local[idx], remote.data);
          } else {
            local.push(remote.data);        // ← bypasses mergeRemoteRecord entirely
          }
```

So patching the guard alone is a no-op for the real bug. **Both halves must change.**

- [ ] **Step 1: Write the failing tests**

Add to `__tests__/syncMerge.test.js`:

```js
  test("a remote invoice with no local copy has paid derived from its ledger", () => {
    const remote = invoice({
      amount: 1000, paid: false,
      payments: [{ id: "p1", amount: 1000, date: "2026-07-01", method: "cash" }],
    });
    expect(mergeRemoteRecord("invoices", undefined, remote).paid).toBe(true);
  });

  test("a stale paid:true on a remote invoice with no local copy is re-opened", () => {
    const remote = invoice({
      amount: 1000, paid: true, paidAt: "2026-07-01",
      payments: [{ id: "p1", amount: 400, date: "2026-07-01", method: "cash" }],
    });
    const result = mergeRemoteRecord("invoices", undefined, remote);
    expect(result.paid).toBe(false);
    expect(result.paidAt).toBeUndefined();
  });

  test("a LEGACY remote invoice with no local copy passes through by reference", () => {
    // reconcilePaidFields returns the same object when the ledger is empty, so
    // legacy invoices are untouched and cheap.
    const remote = invoice({ amount: 1000, paid: true, paidAt: "2026-06-15" });
    expect(mergeRemoteRecord("invoices", undefined, remote)).toBe(remote);
  });
```

- [ ] **Step 2: Handle the pre-existing test whose intent changes**

`__tests__/syncMerge.test.js:24-27` currently reads:

```js
  test("returns the remote record unchanged when there is no local copy", () => {
    const remote = invoice({ payments: [pmt({ id: "p1", amount: 400 })] });
    expect(mergeRemoteRecord("invoices", undefined, remote)).toBe(remote);
  });
```

Its fixture has a REAL ledger, so after this fix the function correctly returns a NEW object with `paid` derived — the identity assertion fails.

**This is the one place in this plan where a pre-existing test legitimately changes**, because its intent has changed: "pass through untouched" was right when nothing was derived, and is wrong now. Rewrite it to assert the ledger is preserved and `paid` is derived, and update its name and add a comment explaining why identity is no longer the contract. The new "LEGACY … by reference" test above preserves the identity guarantee for the case where it still holds.

Do NOT weaken it to `toEqual` and leave the name unchanged — that would hide the change.

- [ ] **Step 3: Run to verify the new tests fail**

Run: `npx jest __tests__/syncMerge.test.js`
Expected: the two derivation tests FAIL.

- [ ] **Step 4: Fix `mergeRemoteRecord`**

```ts
export function mergeRemoteRecord(
  table: string,
  local: SyncRecord | undefined,
  remote: SyncRecord,
): SyncRecord {
  if (table !== "invoices") return remote;
  if (!local) {
    // No local copy, but still derive: a writer can push a stale `paid` (its
    // queued snapshot predates a webhook payment the trigger later unioned in),
    // and getStatus's fast path at invoiceHelpers.ts:24 reads that flag.
    // reconcilePaidFields returns the same object for a legacy invoice.
    return reconcilePaidFields(remote as unknown as Invoice) as unknown as SyncRecord;
  }
  return mergePaymentLedgers(local as unknown as Invoice, remote as unknown as Invoice) as unknown as SyncRecord;
}
```

Import `reconcilePaidFields` alongside `mergePaymentLedgers`.

- [ ] **Step 5: Route the push branch through the dispatcher**

In `utils/sync.ts`, the `else` branch becomes:

```ts
          } else {
            // Route new records through the dispatcher too — otherwise an
            // invoice arriving on a device that has never seen it keeps
            // whatever `paid` its blob cached.
            local.push(mergeRemoteRecord(table, undefined, remote.data));
          }
```

Change nothing else in `pullRemote`. The `__dataOwner` ownership guard must not appear in your diff.

- [ ] **Step 6: Correct the now-true comment**

`utils/invoiceHelpers.ts:24-27` claims the `getStatus` fast path is safe because every write path maintains `paid` from the ledger. That claim was false for the pull path. Update it to state that sync's pull also derives, including for records with no local copy.

- [ ] **Step 7: Verify and commit**

Run: `npx jest __tests__/syncMerge.test.js __tests__/sync.test.js`
Expected: PASS, with every pre-existing test in `sync.test.js` untouched.

Run: `git diff utils/sync.ts` — confirm it contains ONLY the push-branch change and its comment.

Run: `npm run typecheck && npm test && npm run lint`

```bash
git add utils/syncMerge.ts utils/sync.ts utils/invoiceHelpers.ts __tests__/syncMerge.test.js
git commit -m "fix: derive paid for pulled invoices with no local copy

pullRemote pushed new records straight into storage, bypassing the merge
dispatcher, so a fresh install could show '12d overdue' beside that row's own
'\$0.00 due'. Both the dispatcher's guard and the push branch had to change —
patching the guard alone was a no-op."
```

---

### Task 6: Docs

**Files:** Modify `ARCHITECTURE.md`, `docs/deposits-resume-here.md`

- [ ] **Step 1: ARCHITECTURE.md**

Append to the `### Invoice` block's `payments` bullet:

```markdown
  Collection surfaces — payment links, outreach messages and the cron reminder
  email — quote `balanceDue`, and name both numbers for a partly-paid invoice
  so the customer sees their deposit credited. `overpaidAmount` surfaces money
  received beyond the invoice total, which `balanceDue` clamps away.
```

- [ ] **Step 2: `docs/deposits-resume-here.md`**

Update the status block's gate and commit counts to what you observe, and note that the whole-branch review's C1, C2 and I1 are now closed. Leave §1, §4 and §5 otherwise unchanged.

- [ ] **Step 3: Gate and commit**

Run: `npm run typecheck && npm test && npm run lint`

```bash
git add ARCHITECTURE.md docs/deposits-resume-here.md
git commit -m "docs: record the collection-surface and overpayment fixes"
```

---

## Exit criteria

- [ ] `npm run typecheck` 0 errors, `npm test` 0 failures, `npm run lint` 0 warnings
- [ ] `grep -n "invoice\.amount" utils/invoiceHelpers.ts` returns only the sites that legitimately name the invoice TOTAL (inside `describeAmountOwed`) — every charge/dun path reads `balanceDue`
- [ ] `grep -n "invoice.amount" backend/lib/reminderEmail.js` likewise
- [ ] `git diff utils/sync.ts` for this work contains only the push-branch change
- [ ] `grep -n "localDataBelongsToOtherUser" utils/sync.ts` still matches, unchanged
- [ ] The four protected fixture/equivalence files are unedited
- [ ] Exactly one pre-existing test changed — the `syncMerge` identity test in Task 5 Step 2 — and its name and comment explain why

Then stop and report.
