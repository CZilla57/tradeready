# Deposits & Partial Payments — Phase 4: Money-tab ledger sweep

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every money surface read from the payment ledger, so a partly-paid invoice reports $600 outstanding and $400 collected instead of $1,000 and $0.

**Architecture:** All derivations already exist and are tested (`utils/invoicePayments.ts`). This phase is a call-site sweep: ~19 sites across three semantic classes. Two small additions come first — a coercion contract inside the derivations, and a grouped bucketing helper — then the sites convert in risk order, tested-utils before untested-components.

**Tech Stack:** TypeScript, React Native (Expo 54), Jest, no new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-18-deposits-phase-4-money-sweep-design.md` (a delta on `2026-07-18-deposits-partial-payments-design.md`)

## Global Constraints

- **No new dependencies.** No `package.json` change. Adding a package or changing the Expo SDK needs the owner's explicit approval (`tradeready-change-control`).
- **The gate must be green before every commit:** `npm run typecheck` (0 errors), `npm test` (0 failures), `npm run lint` (0 warnings — `--max-warnings=0`).
- **Starting baseline: 974 tests / 61 suites** on branch `feat/deposits-partial-payments` @ `d9cc18b`.
- **`__tests__/invoicePaymentsLegacyEquivalence.test.js` must pass COMPLETELY UNCHANGED.** It pins the new derivations against the old formulas across 60 generated legacy invoice shapes. If any task needs to edit it, something has gone wrong — stop and report rather than adjusting it.
- **Every converted site's EXISTING tests must also pass untouched.** Those suites are built on legacy fixtures, so a correct conversion is invisible to them. A test that needs editing means the conversion changed legacy behaviour — stop and report.
- **The coercion change must land in BOTH `utils/invoicePayments.ts` and `backend/lib/paymentMath.js`,** or `__tests__/paymentMathParity.test.js` fails. That gate is the point.
- **Non-finite amount cases go in `__fixtures__/paymentVectors.js` ONLY, never in the legacy-equivalence fixture.** The equivalence suite asserts exact equality with the old formulas, which returned `inv.amount` raw — a string `"1000"` would have produced the string while the new code produces the number. Adding those cases there would break the safety net and look like the sweep broke equivalence.
- **Do NOT change `utils/pdfTemplates.ts` beyond its one boolean.** The PDF balance/history block is Phase 6.
- **Do NOT touch `utils/sync.ts`, `utils/syncMerge.ts`, or anything under `backend/`** except `backend/lib/paymentMath.js` as required by Task 1.
- Money is a plain `number` of dollars. Dates are `"YYYY-MM-DD"` strings. Float epsilon is exactly `0.005`.
- Shell is PowerShell on Windows; a Bash tool is also available.

## Existing interfaces you will use

From `utils/invoicePayments.ts` (committed and tested):

```ts
export function amountPaid(invoice: Invoice): number;     // sums the ledger, SKIPPING voided entries;
                                                          // falls back to `paid ? amount : 0` when the ledger is empty
export function balanceDue(invoice: Invoice): number;     // Math.max(0, amount - amountPaid)
export function isFullyPaid(invoice: Invoice): boolean;   // balanceDue <= 0.005
export function isPartlyPaid(invoice: Invoice): boolean;
export const effectivePayments: (invoice: Invoice) => Payment[];  // includes voided entries
export function paymentsInRange(invoice: Invoice, start: Date, end: Date): Payment[];  // includes voided
export function collectedInRange(invoices: Invoice[], start: Date, end: Date): number; // EXCLUDES voided
```

**The voided asymmetry matters.** `paymentsInRange` returns voided entries (a history UI renders them struck through); `collectedInRange` skips them. Anything you write that SUMS must skip voided entries itself.

## File structure

| File | Change |
|---|---|
| `utils/invoicePayments.ts` | Coercion contract; `collectedByPeriod` |
| `backend/lib/paymentMath.js` | Mirror the coercion contract |
| `__fixtures__/paymentVectors.js` | Non-finite amount vectors |
| `utils/customerMix.ts`, `utils/seasonalTrends.ts`, `utils/businessSnapshot.ts`, `utils/customerList.ts`, `utils/invoiceAging.ts` | Convert (all have test suites) |
| `utils/invoiceStats.ts` | Convert outstanding/collected/isOverdue |
| `screens/MoneyScreen.tsx`, `components/money/ReceivablesCard.tsx`, `components/money/TopCustomersCard.tsx`, `components/money/MonthlyChart.tsx` | Convert (no test suites) |
| `utils/notifications.ts`, `utils/storage/dailyOps.ts`, `screens/OutreachScreen.tsx`, `screens/CustomerDetailScreen.tsx`, `utils/pdfTemplates.ts` | Boolean swaps |
| `ARCHITECTURE.md`, `docs/deposits-resume-here.md` | Docs |

---

### Task 1: The coercion contract

**Files:**
- Modify: `utils/invoicePayments.ts`
- Modify: `backend/lib/paymentMath.js`
- Modify: `__fixtures__/paymentVectors.js`
- Test: `__tests__/invoicePayments.test.js`

**Interfaces:**
- Produces: `amountPaid` and `balanceDue` now always return a finite number.

Six call sites currently defend with `parseFloat(String(inv.amount)) || 0` while nine do not. Rather than scatter that further, the derivations take responsibility.

- [ ] **Step 1: Write the failing tests**

Append to `__tests__/invoicePayments.test.js`, using the file's existing `inv()` / `pmt()` helpers:

```js
describe("amount coercion", () => {
  test("a string invoice amount does not concatenate", () => {
    const i = inv({ amount: "1000", paid: true, payments: undefined });
    expect(amountPaid(i)).toBe(1000);
  });

  test("an undefined invoice amount reads as zero, not NaN", () => {
    const i = inv({ amount: undefined, paid: true, payments: undefined });
    expect(amountPaid(i)).toBe(0);
    expect(balanceDue(i)).toBe(0);
  });

  test("a NaN invoice amount reads as zero", () => {
    const i = inv({ amount: NaN, paid: true, payments: undefined });
    expect(balanceDue(i)).toBe(0);
  });

  test("a string payment amount does not concatenate", () => {
    const i = inv({ amount: 1000, payments: [pmt({ id: "p1", amount: "400" })] });
    expect(amountPaid(i)).toBe(400);
    expect(balanceDue(i)).toBe(600);
  });

  test("a malformed payment amount contributes zero rather than poisoning the sum", () => {
    const i = inv({
      amount: 1000,
      payments: [pmt({ id: "p1", amount: 400 }), pmt({ id: "p2", amount: undefined })],
    });
    expect(amountPaid(i)).toBe(400);
  });

  test("balanceDue is always finite", () => {
    const i = inv({ amount: "abc", payments: [pmt({ id: "p1", amount: "xyz" })] });
    expect(Number.isFinite(balanceDue(i))).toBe(true);
  });
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `npx jest __tests__/invoicePayments.test.js`
Expected: FAIL — the string cases produce `"1000"`/`"0400"` or `NaN`.

- [ ] **Step 3: Implement in the TypeScript module**

In `utils/invoicePayments.ts`, add above `amountPaid`:

```ts
/**
 * Coerce a persisted amount to a finite number.
 *
 * Invoice and payment amounts are supposed to be numbers, and both invoice
 * creation screens validate that. But this data round-trips through JSON blobs
 * in Supabase and through older app versions, and six money call sites already
 * carried defensive `parseFloat(String(x)) || 0` wrappers while nine did not.
 * Rather than scatter that further, the derivations take responsibility: a
 * malformed amount contributes zero instead of concatenating a string or
 * poisoning the whole sum with NaN.
 */
function toAmount(value: unknown): number {
  const n = typeof value === "number" ? value : parseFloat(String(value));
  return Number.isFinite(n) ? n : 0;
}
```

Then use it in both derivations:

```ts
export function amountPaid(invoice: Invoice): number {
  const ledger = invoice.payments;
  if (ledger && ledger.length > 0) {
    return ledger.reduce((sum, p) => (p.voidedAt ? sum : sum + toAmount(p.amount)), 0);
  }
  return invoice.paid ? toAmount(invoice.amount) : 0;
}

export function balanceDue(invoice: Invoice): number {
  return Math.max(0, toAmount(invoice.amount) - amountPaid(invoice));
}
```

Leave `withDerivedPaidFields` alone for now — check whether it also reads `invoice.amount` raw, and if so route that read through `toAmount` too. Say in your report whether it needed changing.

- [ ] **Step 4: Mirror it in the backend**

`backend/lib/paymentMath.js` must implement `toAmount` identically (plain CommonJS, no types) and use it in its `amountPaid` and `balanceDue`. This is not optional — the parity test compares the two implementations directly.

- [ ] **Step 5: Add parity vectors**

Append to `__fixtures__/paymentVectors.js`. **These go here and NOT in the legacy-equivalence fixture** — that suite asserts exact equality with the old formulas, which returned raw values, so a string amount would break it:

```js
  {
    label: "string invoice amount coerces rather than concatenating",
    invoice: invoice({ amount: "1000", paid: true }),
    expectedAmountPaid: 1000, expectedBalance: 0, expectedFullyPaid: true,
  },
  {
    label: "undefined invoice amount reads as zero",
    invoice: invoice({ amount: undefined, paid: true }),
    expectedAmountPaid: 0, expectedBalance: 0, expectedFullyPaid: true,
  },
  {
    label: "string payment amount coerces",
    invoice: invoice({ amount: 1000, payments: [p({ id: "p1", amount: "400" })] }),
    expectedAmountPaid: 400, expectedBalance: 600, expectedFullyPaid: false,
  },
```

- [ ] **Step 6: Run to verify everything passes**

Run: `npx jest __tests__/invoicePayments.test.js __tests__/paymentMathParity.test.js __tests__/invoicePaymentsLegacyEquivalence.test.js`
Expected: PASS. **The legacy-equivalence suite must pass with no edits** — all its fixture amounts are finite, so coercion is a no-op for them. If it fails, stop and report; do not adjust that file.

- [ ] **Step 7: Prove the parity gate still bites**

Temporarily remove `toAmount` from the BACKEND's `amountPaid` only (leave the TS one), run `npx jest __tests__/paymentMathParity.test.js`, and confirm it FAILS. Revert and confirm it passes. Paste both outputs — this is the evidence the two implementations are actually pinned.

- [ ] **Step 8: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0.

- [ ] **Step 9: Commit**

```bash
git add utils/invoicePayments.ts backend/lib/paymentMath.js __fixtures__/paymentVectors.js __tests__/invoicePayments.test.js
git commit -m "feat: derivations guarantee a finite amount

Six money call sites carried defensive parseFloat wrappers and nine did not.
The derivations now take responsibility: a malformed amount contributes zero
rather than concatenating a string or poisoning a sum with NaN. Mirrored in
the backend copy, pinned by the parity vectors."
```

---

### Task 2: `collectedByPeriod`

**Files:**
- Modify: `utils/invoicePayments.ts`
- Test: `__tests__/invoicePayments.test.js`

**Interfaces:**
- Produces: `collectedByPeriod(invoices: Invoice[], ranges: { start: Date; end: Date }[]): number[]`

`MonthlyChart` needs 6 buckets and `seasonalTrends` needs 24. Calling `collectedInRange` per bucket re-walks and re-materialises every invoice's ledger once per bucket. This walks each ledger once.

- [ ] **Step 1: Write the failing tests**

Append to `__tests__/invoicePayments.test.js`:

```js
describe("collectedByPeriod", () => {
  const JUNE = { start: new Date(2026, 5, 1), end: new Date(2026, 5, 30) };
  const JULY = { start: new Date(2026, 6, 1), end: new Date(2026, 6, 31) };

  test("bins each payment into the range that contains it", () => {
    const i = inv({
      amount: 1000,
      payments: [
        pmt({ id: "p1", amount: 400, date: "2026-06-20" }),
        pmt({ id: "p2", amount: 600, date: "2026-07-05" }),
      ],
    });
    expect(collectedByPeriod([i], [JUNE, JULY])).toEqual([400, 600]);
  });

  test("returns a zero for a range with no payments", () => {
    const i = inv({ amount: 1000, payments: [pmt({ id: "p1", amount: 400, date: "2026-07-05" })] });
    expect(collectedByPeriod([i], [JUNE, JULY])).toEqual([0, 400]);
  });

  test("excludes voided payments", () => {
    const i = inv({
      amount: 1000,
      payments: [
        pmt({ id: "p1", amount: 400, date: "2026-07-05" }),
        pmt({ id: "p2", amount: 600, date: "2026-07-06", voidedAt: "2026-07-22" }),
      ],
    });
    expect(collectedByPeriod([i], [JULY])).toEqual([400]);
  });

  test("a legacy paid invoice buckets on paidAt, matching collectedInRange", () => {
    const i = inv({ paid: true, amount: 1000, paidAt: "2026-07-15", due: "2026-06-01" });
    expect(collectedByPeriod([i], [JUNE, JULY])).toEqual([0, 1000]);
  });

  test("sums across several invoices", () => {
    const a = inv({ id: "a", amount: 1000, payments: [pmt({ id: "p1", amount: 400, date: "2026-07-10" })] });
    const b = inv({ id: "b", paid: true, amount: 250, paidAt: "2026-07-11" });
    expect(collectedByPeriod([a, b], [JULY])).toEqual([650]);
  });

  test("agrees with collectedInRange for every range", () => {
    const invoices = [
      inv({ id: "a", amount: 1000, payments: [pmt({ id: "p1", amount: 400, date: "2026-06-20" })] }),
      inv({ id: "b", paid: true, amount: 250, paidAt: "2026-07-11" }),
    ];
    const ranges = [JUNE, JULY];
    expect(collectedByPeriod(invoices, ranges)).toEqual(
      ranges.map((r) => collectedInRange(invoices, r.start, r.end)),
    );
  });

  test("an empty ranges array yields an empty result", () => {
    expect(collectedByPeriod([inv({ amount: 1000 })], [])).toEqual([]);
  });
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `npx jest __tests__/invoicePayments.test.js`
Expected: FAIL — `collectedByPeriod is not a function`.

- [ ] **Step 3: Implement**

Append to `utils/invoicePayments.ts`:

```ts
/**
 * Total collected in each of several windows, walking every ledger ONCE.
 *
 * Equivalent to mapping collectedInRange over the ranges (there is a test
 * pinning that), but the bucketed charts need 6 and 24 windows respectively and
 * the naive form re-materialises every invoice's ledger once per window.
 *
 * Voided payments are excluded, matching collectedInRange. A payment falling in
 * two overlapping ranges counts in both — that is the caller's business.
 */
export function collectedByPeriod(
  invoices: Invoice[],
  ranges: { start: Date; end: Date }[],
): number[] {
  const totals = new Array<number>(ranges.length).fill(0);
  for (const invoice of invoices) {
    for (const p of effectivePayments(invoice)) {
      if (p.voidedAt) continue;
      const amount = toAmount(p.amount);
      for (let i = 0; i < ranges.length; i++) {
        if (isInRange(p.date, ranges[i].start, ranges[i].end)) totals[i] += amount;
      }
    }
  }
  return totals;
}
```

`isInRange` is already imported in this file from `./moneyUtils`; `toAmount` comes from Task 1.

- [ ] **Step 4: Run to verify they pass**

Run: `npx jest __tests__/invoicePayments.test.js`
Expected: PASS — 7 new tests.

- [ ] **Step 5: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0.

- [ ] **Step 6: Commit**

```bash
git add utils/invoicePayments.ts __tests__/invoicePayments.test.js
git commit -m "feat: add collectedByPeriod for bucketed revenue charts

Walks each ledger once instead of once per bucket. Pinned to agree with
collectedInRange for every range."
```

---

### Task 3: The tested pure utils

**Files:**
- Modify: `utils/customerMix.ts`, `utils/seasonalTrends.ts`, `utils/businessSnapshot.ts`, `utils/customerList.ts`, `utils/invoiceAging.ts`
- Test: their existing suites, plus new partial-payment cases

**Interfaces:**
- Consumes: `amountPaid`, `balanceDue`, `isFullyPaid`, `collectedInRange`, `collectedByPeriod` (Tasks 1–2).

**Every existing test in these five suites must pass untouched.** They are built on legacy fixtures, where the conversion is a no-op. If one needs editing, the conversion changed legacy behaviour — stop and report.

- [ ] **Step 1: Convert `utils/customerMix.ts`**

The revenue loop (~line 42) currently reads:

```ts
  for (const inv of invoices) {
    if (!inv.paid) continue;
    const dateStr = inv.paidAt ?? inv.due;
    if (!dateStr || !isInRange(dateStr, start, end)) continue;
    const name = (inv.customer || "").trim().toLowerCase();
    if (!name) continue;
    revenueByCustomer.set(name, (revenueByCustomer.get(name) || 0) + (inv.amount || 0));
  }
```

Replace with a per-invoice ledger sum:

```ts
  for (const inv of invoices) {
    const name = (inv.customer || "").trim().toLowerCase();
    if (!name) continue;
    // Each payment counts in the window it actually arrived in, so a deposit
    // and its final balance land in the months they were received.
    const collected = collectedInRange([inv], start, end);
    if (collected === 0) continue;
    revenueByCustomer.set(name, (revenueByCustomer.get(name) || 0) + collected);
  }
```

Import `collectedInRange` from `./invoicePayments`. Note the file has a private `isInRange`/`parseLocalDate` pair — if they become unused after this change, DELETE them (lint runs with `--max-warnings=0` and will flag them anyway). If they are still used by the first loop, leave them.

- [ ] **Step 2: Convert `utils/seasonalTrends.ts`**

`incomeInMonth` (~line 21) becomes unnecessary — `computeSeasonalTrends` builds 24 month windows and reads them from one call. Replace the per-month helper and its two call sites with:

```ts
export function computeSeasonalTrends(
  invoices: Invoice[],
  now: Date = new Date(),
): SeasonalTrendsResult {
  // Build this-year and last-year windows for all 12 months, then collect once.
  const windows: { start: Date; end: Date }[] = [];
  for (let i = 11; i >= 0; i--) {
    const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
    windows.push({ start: new Date(d.getFullYear(), d.getMonth(), 1), end: new Date(d.getFullYear(), d.getMonth() + 1, 0) });
    windows.push({ start: new Date(d.getFullYear() - 1, d.getMonth(), 1), end: new Date(d.getFullYear() - 1, d.getMonth() + 1, 0) });
  }
  const totals = collectedByPeriod(invoices, windows);
  // totals[2*k] is month k this year; totals[2*k + 1] is the same month last year.
  ...
}
```

Keep the rest of the function's shape (the `months` array, `thisYearTotal`, `lastYearTotal`, `yoyChangePct`) exactly as it is — only where the two numbers come from changes. Read the existing function fully before editing and preserve its output contract.

Delete `incomeInMonth` and any now-unused local date helpers.

- [ ] **Step 3: Convert `utils/businessSnapshot.ts`**

The loop at ~lines 65-78 currently splits every invoice into EITHER revenue OR outstanding:

```ts
  for (const inv of invoices) {
    const amount = inv.amount || 0;
    if (inv.paid) {
      const dateStr = inv.paidAt ?? inv.due;
      if (isInMonth(dateStr, thisYear, thisMonth)) revenueThisMonth += amount;
      if (isInMonth(dateStr, lastYear, lastMonth)) revenueLastMonth += amount;
    } else {
      outstandingTotal += amount;
      if (isOverdue(inv)) {
        overdueTotal += amount;
        overdueCount++;
      }
    }
  }
```

The either/or is the bug: a partly-paid invoice belongs in BOTH. Replace with:

```ts
  // Build month windows once so payments bucket by their own dates.
  const thisMonthRange = { start: new Date(thisYear, thisMonth, 1), end: new Date(thisYear, thisMonth + 1, 0) };
  const lastMonthRange = { start: new Date(lastYear, lastMonth, 1), end: new Date(lastYear, lastMonth + 1, 0) };

  for (const inv of invoices) {
    // Not either/or any more: a partly-paid invoice contributes revenue for
    // what arrived AND outstanding for what's still owed.
    revenueThisMonth += collectedInRange([inv], thisMonthRange.start, thisMonthRange.end);
    revenueLastMonth += collectedInRange([inv], lastMonthRange.start, lastMonthRange.end);

    const balance = balanceDue(inv);
    outstandingTotal += balance;
    if (balance > 0 && isOverdue(inv)) {
      overdueTotal += balance;
      overdueCount++;
    }
  }
```

Import `collectedInRange` and `balanceDue` from `./invoicePayments`. Note `isOverdue` here is whatever this file already uses — leave that import as it is; Task 4 converts `invoiceStats.isOverdue` itself, and this call site picks the change up for free.

If `isInMonth` becomes unused after this change, delete it (lint runs with `--max-warnings=0`).

- [ ] **Step 4: Convert `utils/customerList.ts`**

Lines 77–78:

```ts
    entry.totalSpent += inv.paid ? parseNumberInput(inv.amount, 0) : 0;
    entry.totalOwed += !inv.paid ? parseNumberInput(inv.amount, 0) : 0;
```

become:

```ts
    // A part-paid customer should show both what they've paid and what's left,
    // rather than appearing to owe everything and have paid nothing.
    entry.totalSpent += amountPaid(inv);
    entry.totalOwed += balanceDue(inv);
```

The `parseNumberInput` wrapper comes out — Task 1 moved that responsibility into the derivations. If `parseNumberInput` becomes unused in this file, remove its import.

- [ ] **Step 5: Convert `utils/invoiceAging.ts`**

Line 36 only:

```ts
    if (!inv.paid || !inv.paidAt || !inv.due) continue;
```

becomes:

```ts
    // Aging measures how long an invoice took to SETTLE, so partly-paid ones
    // are correctly excluded — they haven't finished aging. paidAt still holds
    // the settling payment's date.
    if (!isFullyPaid(inv) || !inv.paidAt || !inv.due) continue;
```

Change nothing else in this file — `totalAmount += inv.amount` stays, because it is the invoice's value, not the amount collected.

- [ ] **Step 6: Run the five existing suites unchanged**

Run: `npx jest __tests__/customerMix.test.js __tests__/seasonalTrends.test.js __tests__/businessSnapshot.test.js __tests__/customerList.test.js __tests__/invoiceAging.test.js`
Expected: PASS with **no edits to any of those files**. If any fails, the conversion changed legacy behaviour — stop and report rather than adjusting the test.

- [ ] **Step 7: Add one partial-payment case per converted site**

Append to each suite a test proving the new behaviour. Use each file's existing fixture helpers. For example, in `__tests__/customerList.test.js`:

```js
  test("a partly-paid invoice splits across spent and owed", () => {
    const invoices = [{
      id: "i1", customer: "Acme", number: "INV-1", desc: "", email: "", phone: "",
      amount: 1000, due: "2026-07-01", paid: false,
      payments: [{ id: "p1", amount: 400, date: "2026-07-01", method: "cash" }],
    }];
    const list = buildCustomerList(invoices, [], []);
    const acme = list.find((c) => c.name === "Acme");
    expect(acme.totalSpent).toBe(400);
    expect(acme.totalOwed).toBe(600);
  });
```

Adjust the call signature and fixture shape to match each suite's actual conventions — read each file first. Write the equivalent case for `customerMix` (revenue counts in the month the payment arrived), `seasonalTrends` (a deposit and balance land in different months), `businessSnapshot` (revenue reflects payments, not whole invoices), and `invoiceAging` (a partly-paid invoice is excluded).

- [ ] **Step 8: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0. Record the test count.

- [ ] **Step 9: Commit**

```bash
git add utils/customerMix.ts utils/seasonalTrends.ts utils/businessSnapshot.ts utils/customerList.ts utils/invoiceAging.ts __tests__/
git commit -m "feat: convert the tested money utils to the payment ledger

Revenue now counts in the window each payment arrived in, and a part-paid
customer shows both what they've paid and what's left. Every pre-existing test
passes untouched — the conversion is a no-op on legacy data."
```

---

### Task 4: `invoiceStats` and the outstanding math

**Files:**
- Modify: `utils/invoiceStats.ts`
- Test: `__tests__/invoiceStats.test.js`

These are the numbers users stare at most, and the ones currently contradicting the invoice rows.

- [ ] **Step 1: Write the failing tests**

Append to `__tests__/invoiceStats.test.js`, matching its existing `inv()` helper and its pinned date:

```js
describe("partial payments", () => {
  test("outstanding counts only the balance, collected counts what arrived", () => {
    const invoices = [
      inv({ id: "1", amount: 1000, paid: false, due: "2026-08-01",
            payments: [{ id: "p1", amount: 400, date: "2026-07-01", method: "cash" }] }),
    ];
    const { outstanding, collected } = summarizeInvoices(invoices);
    expect(outstanding).toBe(600);
    expect(collected).toBe(400);
  });

  test("a fully-paid ledger invoice is all collected, nothing outstanding", () => {
    const invoices = [
      inv({ id: "1", amount: 1000, paid: true, due: "2026-08-01",
            payments: [{ id: "p1", amount: 1000, date: "2026-07-01", method: "cash" }] }),
    ];
    const { outstanding, collected } = summarizeInvoices(invoices);
    expect(outstanding).toBe(0);
    expect(collected).toBe(1000);
  });

  test("a voided payment returns the money to outstanding", () => {
    const invoices = [
      inv({ id: "1", amount: 1000, paid: false, due: "2026-08-01",
            payments: [{ id: "p1", amount: 400, date: "2026-07-01", method: "cash", voidedAt: "2026-07-22" }] }),
    ];
    const { outstanding, collected } = summarizeInvoices(invoices);
    expect(outstanding).toBe(1000);
    expect(collected).toBe(0);
  });

  test("a partly-paid invoice past due is still overdue", () => {
    const i = inv({ amount: 1000, paid: false, due: "2026-06-01",
                    payments: [{ id: "p1", amount: 400, date: "2026-07-01", method: "cash" }] });
    expect(isOverdue(i)).toBe(true);
  });
});
```

**Check the date this suite pins with `jest.setSystemTime` before writing these** and adjust the `due` values so "2026-08-01" is genuinely future and "2026-06-01" genuinely past relative to it. Say in your report what it pins.

- [ ] **Step 2: Run to verify they fail**

Run: `npx jest __tests__/invoiceStats.test.js`
Expected: FAIL — outstanding reports 1000 and collected 0 for the partial case.

- [ ] **Step 3: Implement**

In `utils/invoiceStats.ts`, add `import { amountPaid, balanceDue, isFullyPaid } from "./invoicePayments";` and convert:

```ts
/** Has a remaining balance and is past due — matches the "Nd overdue" badge. */
export function isOverdue(invoice: Invoice): boolean {
  return !isFullyPaid(invoice) && daysPastDue(invoice.due) > 0;
}

export function summarizeInvoices(invoices: Invoice[]): InvoiceSummary {
  let outstanding = 0;
  let overdueCount = 0;
  let collected = 0;
  for (const inv of invoices) {
    // Per-invoice rather than per-flag: a partly-paid invoice contributes to
    // BOTH, which is what makes these totals agree with the rows below them.
    collected += amountPaid(inv);
    outstanding += balanceDue(inv);
    if (isOverdue(inv)) overdueCount += 1;
  }
  return { outstanding, overdueCount, collected };
}
```

Update the `InvoiceSummary` doc comments: `outstanding` is now "sum of remaining balances" and `collected` is "sum of payments received".

- [ ] **Step 4: Run to verify they pass, including the pre-existing tests**

Run: `npx jest __tests__/invoiceStats.test.js`
Expected: PASS, with **no edits to any pre-existing test in that file**.

- [ ] **Step 5: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0.

- [ ] **Step 6: Commit**

```bash
git add utils/invoiceStats.ts __tests__/invoiceStats.test.js
git commit -m "feat: invoice stats sum balances and payments, not whole invoices

The header StatCards were reporting a $1000 invoice with a $400 deposit as
$1000 outstanding and $0 collected, contradicting the row beneath it."
```

---

### Task 5: The untested components and screens

**Files:**
- Modify: `screens/MoneyScreen.tsx`, `components/money/ReceivablesCard.tsx`, `components/money/TopCustomersCard.tsx`, `components/money/MonthlyChart.tsx`

**Interfaces:**
- Consumes: `collectedInRange`, `collectedByPeriod`, `balanceDue`, `isFullyPaid`.

None of these have test suites, so read each one fully before editing and keep the diffs minimal. This task adds no tests; the derivations underneath are already covered.

- [ ] **Step 1: Convert `screens/MoneyScreen.tsx`**

`filteredIncome` (~line 99) currently:

```ts
    (invoices as Invoice[])
      .filter((inv) => inv.paid === true && isInRange(inv.paidAt || inv.due, start, end))
      .reduce((sum, inv) => sum + (inv.amount || 0), 0),
```

becomes:

```ts
    collectedInRange(invoices as Invoice[], start, end),
```

and `prevFilteredIncome` (~line 139) the same, with `prevRange.start` / `prevRange.end`, preserving its `prevRange ? ... : null` shape.

Import `collectedInRange` from `../utils/invoicePayments`. If `isInRange` becomes unused in this file, remove its import.

- [ ] **Step 2: Convert `components/money/ReceivablesCard.tsx`**

Lines 23–26 currently:

```ts
    const unpaid           = invoices.filter(inv => !inv.paid);
    const totalOutstanding = unpaid.reduce((s, inv) => s + (parseFloat(String(inv.amount)) || 0), 0);
    const overdue          = unpaid.filter(inv => inv.due && new Date(inv.due) < today);
    const totalOverdue     = overdue.reduce((s, inv) => s + (parseFloat(String(inv.amount)) || 0), 0);
```

become:

```ts
    // `unpaid` is RENDERED as a list further down, not just reduced — so this
    // is "invoices with a balance", and the totals are what's still owed.
    const unpaid           = invoices.filter(inv => !isFullyPaid(inv));
    const totalOutstanding = unpaid.reduce((s, inv) => s + balanceDue(inv), 0);
    const overdue          = unpaid.filter(inv => inv.due && new Date(inv.due) < today);
    const totalOverdue     = overdue.reduce((s, inv) => s + balanceDue(inv), 0);
```

The `parseFloat(String(...))` wrappers come out — Task 1 moved that into the derivations.

- [ ] **Step 3: Convert `components/money/TopCustomersCard.tsx`**

Line 21 filters `inv.paid && isInRange(inv.paidAt || inv.due, start, end)` then sums amounts. Read the full `useMemo` and convert it to accumulate `collectedInRange([inv], start, end)` per invoice, skipping invoices that contribute zero. Keep the sorting and slicing exactly as they are.

- [ ] **Step 4: Convert `components/money/MonthlyChart.tsx`**

The `chartData` memo currently maps over `getLast6MonthLabels()` and filters all invoices per month:

```tsx
    const months = getLast6MonthLabels();
    return months.map(({ label, year, month }) => {
      const monthIncome = invoices
        .filter(inv => {
          const dateStr = inv.paidAt || inv.due;
          if (!inv.paid || !dateStr) return false;
          const d = parseLocalDate(dateStr);
          return d.getFullYear() === year && d.getMonth() === month;
        })
        .reduce((sum, inv) => sum + (parseFloat(String(inv.amount)) || 0), 0);
      ...
```

Replace the income half with one bucketed call, leaving the expenses half exactly as it is:

```tsx
    const months = getLast6MonthLabels();
    const windows = months.map(({ year, month }) => ({
      start: new Date(year, month, 1),
      end: new Date(year, month + 1, 0),
    }));
    const income = collectedByPeriod(invoices, windows);

    return months.map(({ label, year, month }, i) => {
      const monthExpenses = expenses
        .filter(exp => {
          const d = parseLocalDate(exp.date);
          return d.getFullYear() === year && d.getMonth() === month;
        })
        .reduce((sum, exp) => sum + (parseFloat(String(exp.amount)) || 0), 0);

      return { label, income: income[i], expenses: monthExpenses };
    });
```

Import `collectedByPeriod` from `../../utils/invoicePayments`. **Leave the expenses `parseFloat(String(...))` alone** — expenses are not invoices and Task 1's coercion contract does not cover them. `parseLocalDate` stays: the expenses filter still uses it.

- [ ] **Step 5: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0, test count unchanged from Task 4.

- [ ] **Step 6: Verify no stale defensive coercion remains**

Run: `grep -rn "parseFloat(String(inv" screens/ components/ utils/`
Expected: no match. Task 1 moved that responsibility into the derivations; any leftover is a site that did not get converted.

- [ ] **Step 7: Commit**

```bash
git add screens/MoneyScreen.tsx components/money/
git commit -m "feat: convert Money tab surfaces to the payment ledger

Income counts each payment in the window it arrived, and Money owed shows the
remaining balance rather than the whole invoice amount."
```

---

### Task 6: The boolean one-liners

**Files:**
- Modify: `utils/notifications.ts`, `utils/storage/dailyOps.ts`, `screens/OutreachScreen.tsx`, `screens/CustomerDetailScreen.tsx`, `utils/pdfTemplates.ts`

Nine sites, all `!inv.paid` → `!isFullyPaid(inv)` (or the positive form). These produce identical results today because `paid` is maintained. They are in scope because Phase 3's review found two competing definitions of "settled" on one screen, and they diverged on reachable data.

- [ ] **Step 1: Convert each site**

| File | Line | Change |
|---|---|---|
| `utils/notifications.ts` | 53 | `!inv.paid && inv.due` → `!isFullyPaid(inv) && inv.due` |
| `utils/storage/dailyOps.ts` | 53 | `!inv.paid && new Date(inv.due) < today` → `!isFullyPaid(inv) && new Date(inv.due) < today` |
| `screens/OutreachScreen.tsx` | 168 | `invoice && !invoice.paid && settings` → `invoice && !isFullyPaid(invoice) && settings` |
| `screens/OutreachScreen.tsx` | 223 | `!invoice.paid && configuredProviders.length > 1` → `!isFullyPaid(invoice) && ...` |
| `screens/OutreachScreen.tsx` | 251 | `!invoice.paid ?` → `!isFullyPaid(invoice) ?` |
| `screens/OutreachScreen.tsx` | 269 | `invoice.paid ?` → `isFullyPaid(invoice) ?` |
| `screens/CustomerDetailScreen.tsx` | 42 | `if (inv.paid) return { label: 'Paid', ... }` → `if (isFullyPaid(inv)) ...` |
| `utils/pdfTemplates.ts` | 146 | `const isPaid = invoice.paid;` → `const isPaid = isFullyPaid(invoice);` |

Add `import { isFullyPaid } from "..."` to each file with the correct relative path. **Change nothing else in `utils/pdfTemplates.ts`** — its balance and history block is Phase 6.

- [ ] **Step 2: Run the affected existing suites unchanged**

Run: `npx jest __tests__/notifications.test.js`
Expected: PASS with no edits. (The other files have no suites.)

- [ ] **Step 3: Verify the sweep is complete**

Run: `grep -rn "inv\.paid\|invoice\.paid" utils/ screens/ components/ --include=*.ts --include=*.tsx | grep -v "\.test\." | grep -v invoicePayments.ts`

Expected: the ONLY remaining match is `utils/invoiceHelpers.ts:24` (`if (invoice.paid)` in `getStatus`), which is correct — `getStatus` reads the maintained flag first as a fast path before its partly-paid branch. Everything else must be gone. List anything else you find in your report rather than converting it blindly.

- [ ] **Step 4: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0.

- [ ] **Step 5: Commit**

```bash
git add utils/ screens/
git commit -m "refactor: one definition of settled across the app

These nine sites produced identical results to the raw flag today. Phase 3's
review found a screen carrying two competing definitions that diverged on
reachable data — this removes the class."
```

---

### Task 7: Docs

**Files:**
- Modify: `ARCHITECTURE.md`, `docs/deposits-resume-here.md`

- [ ] **Step 1: Update ARCHITECTURE.md**

In the `### Invoice` block's `payments` bullet, append:

```markdown
  Every money surface derives from the ledger: `outstanding` sums `balanceDue`,
  `collected` sums `amountPaid`, and revenue is bucketed by each payment's own
  date (`collectedInRange` / `collectedByPeriod` in `utils/invoicePayments.ts`).
  The invoice `amount` is never summed directly on a money surface.
```

- [ ] **Step 2: Update the resume-here doc**

In `docs/deposits-resume-here.md`, update the status line to note Phase 4 is built, refresh the gate count, and remove the Phase-4 item from any carried-findings list it holds (the StatCards/rows contradiction is now fixed).

- [ ] **Step 3: Confirm the gate is unmoved**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0 — a docs change moves nothing.

- [ ] **Step 4: Commit**

```bash
git add ARCHITECTURE.md docs/deposits-resume-here.md
git commit -m "docs: record that every money surface derives from the ledger"
```

---

## Exit criteria

- [ ] `npm run typecheck` — 0 errors
- [ ] `npm test` — 0 failures, no pre-existing test edited
- [ ] `npm run lint` — 0 warnings
- [ ] `__tests__/invoicePaymentsLegacyEquivalence.test.js` passes **completely unchanged** — verify with `git diff master..HEAD -- __tests__/invoicePaymentsLegacyEquivalence.test.js`, which must be empty apart from the vectors added in earlier phases
- [ ] `grep -rn "parseFloat(String(inv" screens/ components/ utils/` returns nothing
- [ ] `grep -rn "inv\.paid\|invoice\.paid" utils/ screens/ components/ --include=*.ts --include=*.tsx | grep -v "\.test\." | grep -v invoicePayments.ts` returns only `utils/invoiceHelpers.ts:24`
- [ ] The Task 1 Step 7 parity mutation check was performed and recorded
- [ ] No file under `backend/` other than `backend/lib/paymentMath.js` was modified
- [ ] `utils/sync.ts` and `utils/syncMerge.ts` unchanged by this phase

Then stop and report for the phase gate.

## Still not shippable

Unchanged: this may be merged but must NOT ship until the Supabase migration is
applied and the backend deployed. See `docs/deposits-resume-here.md` §4.
