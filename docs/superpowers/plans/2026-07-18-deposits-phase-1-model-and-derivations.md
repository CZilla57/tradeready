# Deposits & Partial Payments — Phase 1: Model and Derivations

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the payment-ledger data model and a single module owning all payment math, with zero change to any existing runtime behaviour.

**Architecture:** Two optional fields are added to `Invoice` (`payments`, `depositRequest`) and a new `utils/invoicePayments.ts` derives paid-amount, balance and status from them. Every derivation falls back to the legacy `paid`/`amount`/`paidAt` fields when no ledger is present, so existing invoices produce byte-identical results and no migration is needed. Nothing in this phase writes a payment or renders any UI — it is pure groundwork that later phases consume.

**Tech Stack:** TypeScript, React Native (Expo 54), Jest with `jest-expo`, no new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-18-deposits-partial-payments-design.md`

## Global Constraints

- **No new dependencies.** Adding a package or changing the Expo SDK requires the owner's explicit approval (`tradeready-change-control`). This phase needs none.
- **The gate must be green before every commit:** `npm run typecheck` (0 errors), `npm test` (0 failures), `npm run lint` (0 warnings — the script uses `--max-warnings=0`).
- **Float comparison epsilon is `0.005`.** Never compare a derived balance to zero with `===` or `<= 0`.
- **Reuse `isInRange` and `parseLocalDate` from `utils/moneyUtils.ts`.** Do not write a fourth local copy — `utils/avgJobValue.ts` and `utils/customerMix.ts` already have private duplicates and that duplication is a known debt, not a pattern to follow.
- **Do not modify any screen, component, or existing analytics helper in this phase.** Phase 1 is additive only. The only existing file touched is `types/models.ts`.
- **Do not modify `utils/invoiceStats.ts`, `utils/invoiceHelpers.ts`, or `backend/`.** Those belong to Phases 3–5.
- **Money is stored as a plain `number` of dollars** throughout this codebase (not cents). Match that.
- **Dates are `"YYYY-MM-DD"` strings** parsed with `parseLocalDate` to avoid the UTC-vs-local off-by-one that has bitten this project before.

---

### Task 1: Data model types

**Files:**
- Modify: `types/models.ts` (add types near the existing `Invoice` interface at line 158)

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `PaymentMethod`, `Payment`, `DepositRequest` types; `Invoice.payments?: Payment[]`; `Invoice.depositRequest?: DepositRequest`.

- [ ] **Step 1: Add the new types above the `Invoice` interface**

In `types/models.ts`, immediately before `export interface Invoice {` (currently line 158), insert:

```ts
/** How a payment reached the tradesperson. */
export type PaymentMethod = 'stripe' | 'cash' | 'check' | 'card' | 'other';

/**
 * A single payment against an invoice. Invoices may be settled in any number
 * of partial payments (a deposit up front, progress draws, a final balance).
 *
 * `id` is `p<timestamp>_<counter>` for payments recorded on the device, and
 * `stripe_<checkout_session_id>` for payments appended by the Stripe Connect
 * webhook. The two id spaces cannot collide, which is what lets pullRemote
 * union the two sides' ledgers deterministically (see utils/sync.ts).
 */
export interface Payment {
  id: string;
  amount: number;
  /** The date money was actually received — "YYYY-MM-DD". Drives revenue bucketing. */
  date: DateString;
  method: PaymentMethod;
  note?: string;
  /**
   * Present only on webhook-created payments. Doubles as the idempotency key:
   * a repeated Stripe delivery for the same session must not append twice.
   */
  stripeSessionId?: string;
}

/**
 * An up-front amount requested from the customer, set on the Outreach screen.
 * Recorded so the UI can show "Deposit requested: $500 — unpaid" and reuse the
 * same payment link rather than minting a new one each render.
 */
export interface DepositRequest {
  /** The resolved dollar amount, even when the user chose a percentage. */
  amount: number;
  /** Set only when the user picked a percentage rather than a fixed amount. */
  percent?: number;
  requestedAt: DateString;
}
```

- [ ] **Step 2: Add the two optional fields to `Invoice`**

In `types/models.ts`, inside `export interface Invoice { ... }`, immediately after the `paidAt` field (currently line 186), insert:

```ts
  /**
   * The payment ledger. ABSENT on every invoice created before this feature —
   * that is deliberate, not an oversight. utils/invoicePayments.ts falls back
   * to `paid`/`amount`/`paidAt` when this is absent, so legacy invoices derive
   * exactly as they always did and no migration is required.
   *
   * `paid` above is now maintained as `balanceDue(inv) <= 0.005`. It is kept
   * because the PDF template, the backend reminder selector, and any client
   * running older code still read it.
   */
  payments?: Payment[];
  /** An up-front amount requested from the customer; set on the Outreach screen. */
  depositRequest?: DepositRequest;
```

- [ ] **Step 3: Verify the types compile**

Run: `npm run typecheck`
Expected: exits 0 with no output. Both new fields are optional, so no existing construction site breaks.

- [ ] **Step 4: Verify nothing else moved**

Run: `npm test`
Expected: the existing suite passes unchanged (baseline is 579 tests / 57 suites on the appointment-reminders branch; on `master` expect the current baseline — record whatever number you get, it must not decrease).

- [ ] **Step 5: Commit**

```bash
git add types/models.ts
git commit -m "feat: add Payment, PaymentMethod and DepositRequest types

Optional Invoice.payments and Invoice.depositRequest fields. Additive only —
absent on every existing invoice, so no migration is needed."
```

---

### Task 2: Core derivations — amountPaid, balanceDue, paid predicates

**Files:**
- Create: `utils/invoicePayments.ts`
- Test: `__tests__/invoicePayments.test.js`

**Interfaces:**
- Consumes: `Payment`, `Invoice` from `types/models` (Task 1).
- Produces:
  - `PAID_EPSILON: number` (= `0.005`)
  - `amountPaid(inv: Invoice): number`
  - `balanceDue(inv: Invoice): number`
  - `isFullyPaid(inv: Invoice): boolean`
  - `isPartlyPaid(inv: Invoice): boolean`

Test files in this repo are plain `.js` with ESM imports (see `__tests__/invoiceStats.test.js`), which keeps fixtures free of full-`Invoice` type friction. Follow that.

- [ ] **Step 1: Write the failing test**

Create `__tests__/invoicePayments.test.js`:

```js
// __tests__/invoicePayments.test.js
// Deposits & partial payments, phase 1. The load-bearing property here is
// LEGACY EQUIVALENCE: an invoice with no `payments` array must derive exactly
// as it did before this feature existed (paid => fully collected, unpaid =>
// fully outstanding). Every analytics conversion in phase 4 depends on it.

import {
  amountPaid,
  balanceDue,
  isFullyPaid,
  isPartlyPaid,
} from "../utils/invoicePayments";

const inv = (over) => ({
  id: "i1",
  customer: "Acme",
  number: "INV-1",
  desc: "",
  email: "",
  phone: "",
  amount: 1000,
  due: "2026-07-01",
  paid: false,
  ...over,
});

const pmt = (over) => ({
  id: "p1",
  amount: 500,
  date: "2026-07-01",
  method: "cash",
  ...over,
});

describe("amountPaid — legacy invoices (no ledger)", () => {
  test("an unpaid legacy invoice has paid nothing", () => {
    expect(amountPaid(inv({ paid: false }))).toBe(0);
  });
  test("a paid legacy invoice has paid the full amount", () => {
    expect(amountPaid(inv({ paid: true, amount: 1000 }))).toBe(1000);
  });
  test("an empty payments array still falls back to the legacy fields", () => {
    expect(amountPaid(inv({ paid: true, amount: 1000, payments: [] }))).toBe(1000);
  });
});

describe("amountPaid — ledger invoices", () => {
  test("sums a single partial payment", () => {
    expect(amountPaid(inv({ payments: [pmt({ amount: 400 })] }))).toBe(400);
  });
  test("sums multiple payments", () => {
    expect(
      amountPaid(inv({ payments: [pmt({ id: "p1", amount: 400 }), pmt({ id: "p2", amount: 250 })] })),
    ).toBe(650);
  });
  test("the ledger wins over the legacy paid flag when present", () => {
    // A stale `paid: true` must not inflate the total past the ledger.
    expect(amountPaid(inv({ paid: true, amount: 1000, payments: [pmt({ amount: 400 })] }))).toBe(400);
  });
});

describe("balanceDue", () => {
  test("full balance outstanding on an unpaid legacy invoice", () => {
    expect(balanceDue(inv({ amount: 1000, paid: false }))).toBe(1000);
  });
  test("zero on a paid legacy invoice", () => {
    expect(balanceDue(inv({ amount: 1000, paid: true }))).toBe(0);
  });
  test("remainder after a partial payment", () => {
    expect(balanceDue(inv({ amount: 1000, payments: [pmt({ amount: 400 })] }))).toBe(600);
  });
  test("never negative when overpaid", () => {
    expect(balanceDue(inv({ amount: 1000, payments: [pmt({ amount: 1200 })] }))).toBe(0);
  });
});

describe("isFullyPaid / isPartlyPaid", () => {
  test("unpaid legacy invoice is neither", () => {
    const i = inv({ paid: false });
    expect(isFullyPaid(i)).toBe(false);
    expect(isPartlyPaid(i)).toBe(false);
  });
  test("paid legacy invoice is fully paid, not partly", () => {
    const i = inv({ paid: true });
    expect(isFullyPaid(i)).toBe(true);
    expect(isPartlyPaid(i)).toBe(false);
  });
  test("a partial payment is partly paid, not fully", () => {
    const i = inv({ amount: 1000, payments: [pmt({ amount: 400 })] });
    expect(isPartlyPaid(i)).toBe(true);
    expect(isFullyPaid(i)).toBe(false);
  });
  test("payments summing to the amount are fully paid, not partly", () => {
    const i = inv({
      amount: 1000,
      payments: [pmt({ id: "p1", amount: 400 }), pmt({ id: "p2", amount: 600 })],
    });
    expect(isFullyPaid(i)).toBe(true);
    expect(isPartlyPaid(i)).toBe(false);
  });
  test("a sub-cent shortfall counts as fully paid (float epsilon)", () => {
    // 0.1 + 0.2 === 0.30000000000000004 — the classic float trap.
    const i = inv({
      amount: 0.3,
      payments: [pmt({ id: "p1", amount: 0.1 }), pmt({ id: "p2", amount: 0.2 })],
    });
    expect(isFullyPaid(i)).toBe(true);
    expect(balanceDue(i)).toBe(0);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npx jest __tests__/invoicePayments.test.js`
Expected: FAIL — `Cannot find module '../utils/invoicePayments'`.

- [ ] **Step 3: Write the minimal implementation**

Create `utils/invoicePayments.ts`:

```ts
// utils/invoicePayments.ts
// The single home for payment-ledger math. Every screen and analytics helper
// that needs "how much has been paid" or "what's still owed" routes through
// here — nobody sums an invoice's payments by hand.
//
// LEGACY FALLBACK (the reason this feature needed no migration): invoices
// created before the ledger existed have no `payments` array. For those,
// amountPaid derives from the old boolean — a paid invoice counts as one
// implicit payment of the full amount, an unpaid one as zero. That is exactly
// what every money surface already assumed, so converted analytics return
// identical numbers on legacy data.

import type { Invoice, Payment } from "../types/models";

/**
 * Balances are floats, so "settled" means "within half a cent", never === 0.
 * 0.1 + 0.2 !== 0.3 in IEEE 754 and invoices really do split into thirds.
 */
export const PAID_EPSILON = 0.005;

/** Total received against this invoice, in dollars. */
export function amountPaid(invoice: Invoice): number {
  const ledger = invoice.payments;
  if (ledger && ledger.length > 0) {
    return ledger.reduce((sum, p) => sum + p.amount, 0);
  }
  return invoice.paid ? invoice.amount : 0;
}

/** Still owed, in dollars. Never negative — an overpayment reads as zero due. */
export function balanceDue(invoice: Invoice): number {
  return Math.max(0, invoice.amount - amountPaid(invoice));
}

export function isFullyPaid(invoice: Invoice): boolean {
  return balanceDue(invoice) <= PAID_EPSILON;
}

/** Something has been received, but not everything. */
export function isPartlyPaid(invoice: Invoice): boolean {
  return amountPaid(invoice) > PAID_EPSILON && !isFullyPaid(invoice);
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npx jest __tests__/invoicePayments.test.js`
Expected: PASS — 15 tests.

- [ ] **Step 5: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0. The unused-import rule will flag `Payment` if you left it imported without using it — at this point only `Invoice` is used, so the import line should read `import type { Invoice } from "../types/models";`. Fix it if lint complains.

- [ ] **Step 6: Commit**

```bash
git add utils/invoicePayments.ts __tests__/invoicePayments.test.js
git commit -m "feat: add invoicePayments derivations with legacy fallback

amountPaid/balanceDue/isFullyPaid/isPartlyPaid. Invoices with no ledger
derive from the legacy paid flag, so existing data reads identically and
no migration is needed. Float comparisons use a half-cent epsilon."
```

---

### Task 3: Ledger mutation — applyPayment and removePayment

**Files:**
- Modify: `utils/invoicePayments.ts`
- Test: `__tests__/invoicePayments.test.js` (append)

**Interfaces:**
- Consumes: `amountPaid`, `balanceDue`, `isFullyPaid`, `PAID_EPSILON` (Task 2).
- Produces:
  - `newPaymentId(): string`
  - `materializeLegacyLedger(inv: Invoice): Payment[]`
  - `applyPayment(inv: Invoice, payment: Payment): Invoice`
  - `removePayment(inv: Invoice, paymentId: string): Invoice`

These are pure functions returning a new `Invoice`. They do NOT save, sync, or touch AsyncStorage — Phase 3's UI calls them and hands the result to the existing `saveInvoices`.

**Why `materializeLegacyLedger` exists — read this before implementing.** `amountPaid` falls back to the legacy fields *only while the ledger is empty*. So if you append a payment to a legacy `paid: true` invoice worth $1,000, the fallback stops applying and `amountPaid` drops from $1,000 to just the new payment. That silently erases a thousand dollars. Any function that begins a ledger on a legacy invoice must first convert the implied legacy payment into a real entry.

- [ ] **Step 1: Write the failing tests**

Append to `__tests__/invoicePayments.test.js` (and extend the import at the top of the file to include the four new names):

```js
describe("newPaymentId", () => {
  test("ids are unique even within the same millisecond", () => {
    const ids = new Set();
    for (let i = 0; i < 100; i++) ids.add(newPaymentId());
    expect(ids.size).toBe(100);
  });
  test("ids do not collide with the webhook's stripe_ namespace", () => {
    expect(newPaymentId().startsWith("stripe_")).toBe(false);
  });
});

describe("materializeLegacyLedger", () => {
  test("a legacy paid invoice becomes one payment for the full amount", () => {
    const ledger = materializeLegacyLedger(
      inv({ paid: true, amount: 1000, paidAt: "2026-06-15", payments: undefined }),
    );
    expect(ledger).toHaveLength(1);
    expect(ledger[0].amount).toBe(1000);
    expect(ledger[0].date).toBe("2026-06-15");
  });
  test("falls back to the due date when paidAt is absent", () => {
    const ledger = materializeLegacyLedger(
      inv({ paid: true, amount: 1000, due: "2026-07-01", payments: undefined }),
    );
    expect(ledger[0].date).toBe("2026-07-01");
  });
  test("a legacy unpaid invoice yields an empty ledger", () => {
    expect(materializeLegacyLedger(inv({ paid: false }))).toEqual([]);
  });
  test("an existing ledger is returned untouched", () => {
    const existing = [pmt({ amount: 400 })];
    expect(materializeLegacyLedger(inv({ payments: existing }))).toEqual(existing);
  });
});

describe("applyPayment", () => {
  test("appends to an empty invoice and leaves it unpaid", () => {
    const result = applyPayment(inv({ amount: 1000 }), pmt({ amount: 400 }));
    expect(result.payments).toHaveLength(1);
    expect(result.paid).toBe(false);
    expect(result.paidAt).toBeUndefined();
    expect(balanceDue(result)).toBe(600);
  });
  test("the payment that closes the balance sets paid and paidAt to ITS date", () => {
    const first = applyPayment(inv({ amount: 1000 }), pmt({ id: "p1", amount: 400, date: "2026-07-01" }));
    const second = applyPayment(first, pmt({ id: "p2", amount: 600, date: "2026-07-20" }));
    expect(second.paid).toBe(true);
    expect(second.paidAt).toBe("2026-07-20");
    expect(balanceDue(second)).toBe(0);
  });
  test("does NOT erase the original amount on a legacy paid invoice", () => {
    // The bug this guards: without materializing, amountPaid would fall from
    // 1000 to 50 the moment the ledger became non-empty.
    const legacy = inv({ paid: true, amount: 1000, paidAt: "2026-06-15", payments: undefined });
    const result = applyPayment(legacy, pmt({ id: "p2", amount: 50, date: "2026-07-02" }));
    expect(amountPaid(result)).toBe(1050);
    expect(result.payments).toHaveLength(2);
  });
  test("does not mutate the input invoice", () => {
    const original = inv({ amount: 1000 });
    applyPayment(original, pmt({ amount: 400 }));
    expect(original.payments).toBeUndefined();
    expect(original.paid).toBe(false);
  });
});

describe("removePayment", () => {
  test("removing a payment restores the balance", () => {
    const withPayment = applyPayment(inv({ amount: 1000 }), pmt({ id: "p1", amount: 400 }));
    const result = removePayment(withPayment, "p1");
    expect(result.payments).toHaveLength(0);
    expect(balanceDue(result)).toBe(1000);
  });
  test("removing the closing payment un-pays the invoice", () => {
    const first = applyPayment(inv({ amount: 1000 }), pmt({ id: "p1", amount: 400, date: "2026-07-01" }));
    const settled = applyPayment(first, pmt({ id: "p2", amount: 600, date: "2026-07-20" }));
    const result = removePayment(settled, "p2");
    expect(result.paid).toBe(false);
    expect(result.paidAt).toBeUndefined();
    expect(isPartlyPaid(result)).toBe(true);
  });
  test("removing a non-closing payment from a settled invoice keeps it unpaid-but-partial", () => {
    const first = applyPayment(inv({ amount: 1000 }), pmt({ id: "p1", amount: 400, date: "2026-07-01" }));
    const settled = applyPayment(first, pmt({ id: "p2", amount: 600, date: "2026-07-20" }));
    const result = removePayment(settled, "p1");
    expect(result.paid).toBe(false);
    expect(amountPaid(result)).toBe(600);
  });
  test("an unknown payment id is a no-op", () => {
    const withPayment = applyPayment(inv({ amount: 1000 }), pmt({ id: "p1", amount: 400 }));
    const result = removePayment(withPayment, "nope");
    expect(result.payments).toHaveLength(1);
  });
  test("does not mutate the input invoice", () => {
    const withPayment = applyPayment(inv({ amount: 1000 }), pmt({ id: "p1", amount: 400 }));
    removePayment(withPayment, "p1");
    expect(withPayment.payments).toHaveLength(1);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npx jest __tests__/invoicePayments.test.js`
Expected: FAIL — the new describe blocks error with `newPaymentId is not a function` (and the same for the other three names).

- [ ] **Step 3: Write the minimal implementation**

Append to `utils/invoicePayments.ts` (and change the type import to `import type { Invoice, Payment } from "../types/models";`):

```ts
// Monotonic within a run so several payments recorded in the same millisecond
// can't collide on `p<Date.now()>`. Mirrors newCustomerId in storage/customers.
let _pidCounter = 0;
export function newPaymentId(): string {
  _pidCounter += 1;
  return `p${Date.now()}_${_pidCounter}`;
}

/**
 * Convert a legacy invoice's implied payment into a real ledger entry.
 *
 * CRITICAL: amountPaid falls back to `paid`/`amount` only while the ledger is
 * empty. Appending to a legacy paid invoice without calling this first would
 * drop the original amount from the total the moment the array became
 * non-empty. Any function that starts a ledger must go through here.
 *
 * Returns the existing ledger untouched when one is already present.
 */
export function materializeLegacyLedger(invoice: Invoice): Payment[] {
  if (invoice.payments && invoice.payments.length > 0) return invoice.payments;
  if (!invoice.paid) return [];
  return [
    {
      id: `legacy_${invoice.id}`,
      amount: invoice.amount,
      date: invoice.paidAt || invoice.due,
      method: "other",
      note: "Recorded before payment history was itemised",
    },
  ];
}

/** Recompute the legacy `paid`/`paidAt` fields from a ledger. */
function withDerivedPaidFields(invoice: Invoice, payments: Payment[]): Invoice {
  const next: Invoice = { ...invoice, payments };
  const settled = balanceDue(next) <= PAID_EPSILON;
  if (settled) {
    // paidAt is the date of the payment that closed the balance — walk the
    // ledger in order and stop at the one that crossed the line.
    let running = 0;
    let closingDate = payments.length ? payments[payments.length - 1].date : invoice.due;
    for (const p of payments) {
      running += p.amount;
      if (running >= invoice.amount - PAID_EPSILON) {
        closingDate = p.date;
        break;
      }
    }
    return { ...next, paid: true, paidAt: closingDate };
  }
  const { paidAt: _dropped, ...rest } = next;
  return { ...rest, paid: false };
}

/**
 * Append a payment and recompute paid/paidAt. Pure — returns a new Invoice and
 * does not save or sync. Callers hand the result to saveInvoices themselves.
 */
export function applyPayment(invoice: Invoice, payment: Payment): Invoice {
  const ledger = [...materializeLegacyLedger(invoice), payment];
  return withDerivedPaidFields(invoice, ledger);
}

/**
 * Remove a payment by id and recompute paid/paidAt. Removing the payment that
 * settled an invoice legitimately flips it back to unpaid — the UI confirms
 * that consequence with the user before calling this.
 */
export function removePayment(invoice: Invoice, paymentId: string): Invoice {
  const ledger = materializeLegacyLedger(invoice).filter((p) => p.id !== paymentId);
  return withDerivedPaidFields(invoice, ledger);
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `npx jest __tests__/invoicePayments.test.js`
Expected: PASS — 30 tests (15 from Task 2 plus 15 new).

- [ ] **Step 5: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0. If lint flags the `_dropped` destructuring as an unused variable, confirm the repo's eslint config ignores identifiers prefixed with `_`; if it does not, replace that branch with an explicit `delete` on a shallow copy rather than disabling the rule.

- [ ] **Step 6: Commit**

```bash
git add utils/invoicePayments.ts __tests__/invoicePayments.test.js
git commit -m "feat: add applyPayment/removePayment ledger mutations

Pure functions returning a new Invoice with paid/paidAt recomputed. Both
materialize a legacy invoice's implied payment before starting a ledger,
without which amountPaid's fallback would silently drop the original amount."
```

---

### Task 4: Date-ranged derivations for the Money tab

**Files:**
- Modify: `utils/invoicePayments.ts`
- Test: `__tests__/invoicePayments.test.js` (append)

**Interfaces:**
- Consumes: `materializeLegacyLedger` (Task 3), `isInRange` from `utils/moneyUtils` (existing).
- Produces:
  - `paymentsInRange(inv: Invoice, start: Date, end: Date): Payment[]`
  - `collectedInRange(invoices: Invoice[], start: Date, end: Date): number`

These are what Phase 4 substitutes for the current `inv.paid && isInRange(inv.paidAt || inv.due, start, end)` pattern found in `MoneyScreen.tsx:101`, `TopCustomersCard.tsx:21` and others. The legacy fallback is what makes that substitution a no-op on old data.

- [ ] **Step 1: Write the failing tests**

Append to `__tests__/invoicePayments.test.js` (extend the import to include `paymentsInRange` and `collectedInRange`):

```js
describe("paymentsInRange / collectedInRange", () => {
  const JULY_START = new Date(2026, 6, 1);
  const JULY_END = new Date(2026, 6, 31);

  test("includes payments inside the window", () => {
    const i = inv({ amount: 1000, payments: [pmt({ amount: 400, date: "2026-07-10" })] });
    expect(paymentsInRange(i, JULY_START, JULY_END)).toHaveLength(1);
  });
  test("excludes payments outside the window", () => {
    const i = inv({ amount: 1000, payments: [pmt({ amount: 400, date: "2026-06-10" })] });
    expect(paymentsInRange(i, JULY_START, JULY_END)).toHaveLength(0);
  });
  test("splits a part-paid invoice across two months", () => {
    const i = inv({
      amount: 1000,
      payments: [
        pmt({ id: "p1", amount: 400, date: "2026-06-20" }),
        pmt({ id: "p2", amount: 600, date: "2026-07-05" }),
      ],
    });
    expect(collectedInRange([i], JULY_START, JULY_END)).toBe(600);
    expect(collectedInRange([i], new Date(2026, 5, 1), new Date(2026, 5, 30))).toBe(400);
  });
  test("a legacy paid invoice buckets on paidAt, matching the old Money-tab math", () => {
    const i = inv({ paid: true, amount: 1000, paidAt: "2026-07-15", due: "2026-06-01" });
    expect(collectedInRange([i], JULY_START, JULY_END)).toBe(1000);
  });
  test("a legacy paid invoice with no paidAt falls back to due, as the old math did", () => {
    const i = inv({ paid: true, amount: 1000, paidAt: undefined, due: "2026-07-15" });
    expect(collectedInRange([i], JULY_START, JULY_END)).toBe(1000);
  });
  test("a legacy unpaid invoice contributes nothing", () => {
    expect(collectedInRange([inv({ paid: false, due: "2026-07-15" })], JULY_START, JULY_END)).toBe(0);
  });
  test("sums across several invoices", () => {
    const a = inv({ id: "a", amount: 1000, payments: [pmt({ id: "p1", amount: 400, date: "2026-07-10" })] });
    const b = inv({ id: "b", paid: true, amount: 250, paidAt: "2026-07-11" });
    expect(collectedInRange([a, b], JULY_START, JULY_END)).toBe(650);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npx jest __tests__/invoicePayments.test.js`
Expected: FAIL — `paymentsInRange is not a function`.

- [ ] **Step 3: Write the minimal implementation**

Append to `utils/invoicePayments.ts`, and add this import at the top of the file beneath the existing type import:

```ts
import { isInRange } from "./moneyUtils";
```

```ts
/**
 * The payments received in a window. Legacy invoices resolve through
 * materializeLegacyLedger, so a paid one buckets on `paidAt || due` — exactly
 * the rule the Money tab already applied before the ledger existed.
 */
export function paymentsInRange(invoice: Invoice, start: Date, end: Date): Payment[] {
  return materializeLegacyLedger(invoice).filter((p) => isInRange(p.date, start, end));
}

/** Total collected across a set of invoices in a window, bucketed by payment date. */
export function collectedInRange(invoices: Invoice[], start: Date, end: Date): number {
  let total = 0;
  for (const inv of invoices) {
    for (const p of paymentsInRange(inv, start, end)) total += p.amount;
  }
  return total;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `npx jest __tests__/invoicePayments.test.js`
Expected: PASS — 37 tests (30 from Tasks 2–3 plus 7 new).

- [ ] **Step 5: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0.

- [ ] **Step 6: Commit**

```bash
git add utils/invoicePayments.ts __tests__/invoicePayments.test.js
git commit -m "feat: add paymentsInRange/collectedInRange for revenue bucketing

Each payment counts on its own date, so a deposit and its final balance land
in the months they were actually received. Legacy invoices bucket on
paidAt || due, matching the Money tab's existing rule exactly."
```

---

### Task 5: Legacy-equivalence property test

**Files:**
- Create: `__tests__/invoicePaymentsLegacyEquivalence.test.js`

**Interfaces:**
- Consumes: everything from Tasks 2–4.
- Produces: no new exports — this is the safety net that licenses Phase 4's sweep.

This test generates every shape of legacy invoice and asserts the new derivations reproduce the old formulas exactly. Phase 4 rewrites ~12 analytics call sites; this is the evidence that the rewrite cannot drift on existing data. It is a separate file because it outlives Phase 1 as the regression guard for that sweep.

- [ ] **Step 1: Write the test**

Create `__tests__/invoicePaymentsLegacyEquivalence.test.js`:

```js
// __tests__/invoicePaymentsLegacyEquivalence.test.js
// The safety net for the phase-4 Money-tab sweep.
//
// Every analytics site currently computes collected revenue as
//   inv.paid ? inv.amount : 0,  bucketed on (inv.paidAt || inv.due)
// and outstanding as
//   !inv.paid ? inv.amount : 0.
//
// Phase 4 replaces those with amountPaid/balanceDue/collectedInRange. On
// invoices that carry no ledger — which is all existing data — the results
// must be IDENTICAL, not merely close. This enumerates the legacy shapes and
// pins that equality. If this file ever fails, the sweep changed real numbers
// and the change is wrong.

import {
  amountPaid,
  balanceDue,
  isFullyPaid,
  collectedInRange,
} from "../utils/invoicePayments";
import { isInRange } from "../utils/moneyUtils";

// The old formulas, written out verbatim so the comparison is explicit.
const legacyCollected = (inv) => (inv.paid ? inv.amount : 0);
const legacyOutstanding = (inv) => (!inv.paid ? inv.amount : 0);
const legacyInRange = (inv, start, end) =>
  inv.paid && isInRange(inv.paidAt || inv.due, start, end) ? inv.amount : 0;

// Every combination of the fields that vary on legacy invoices.
const AMOUNTS = [0, 0.5, 100, 1234.56, 99999];
const PAID = [true, false];
const PAID_AT = ["2026-07-15", undefined];
const DUES = ["2026-07-20", "2026-06-01"];

const legacyInvoices = [];
let n = 0;
for (const amount of AMOUNTS) {
  for (const paid of PAID) {
    for (const paidAt of PAID_AT) {
      for (const due of DUES) {
        n += 1;
        legacyInvoices.push({
          id: `i${n}`,
          customer: "Acme",
          number: `INV-${n}`,
          desc: "",
          email: "",
          phone: "",
          amount,
          paid,
          paidAt,
          due,
          // No `payments` key at all — this is the whole point.
        });
      }
    }
  }
}

describe("legacy equivalence", () => {
  test("the fixture covers every legacy shape", () => {
    expect(legacyInvoices).toHaveLength(
      AMOUNTS.length * PAID.length * PAID_AT.length * DUES.length,
    );
  });

  test.each(legacyInvoices.map((inv) => [inv.number, inv]))(
    "%s — amountPaid matches the old collected formula",
    (_label, inv) => {
      expect(amountPaid(inv)).toBe(legacyCollected(inv));
    },
  );

  test.each(legacyInvoices.map((inv) => [inv.number, inv]))(
    "%s — balanceDue matches the old outstanding formula",
    (_label, inv) => {
      expect(balanceDue(inv)).toBe(legacyOutstanding(inv));
    },
  );

  test.each(legacyInvoices.map((inv) => [inv.number, inv]))(
    "%s — isFullyPaid matches the old paid flag",
    (_label, inv) => {
      // A zero-amount invoice is trivially settled either way; every other
      // invoice must agree with its stored boolean.
      if (inv.amount === 0) return;
      expect(isFullyPaid(inv)).toBe(inv.paid);
    },
  );

  test("collectedInRange matches the old date-bucketed formula over the whole set", () => {
    const start = new Date(2026, 6, 1);
    const end = new Date(2026, 6, 31);
    const expected = legacyInvoices.reduce((sum, inv) => sum + legacyInRange(inv, start, end), 0);
    expect(collectedInRange(legacyInvoices, start, end)).toBe(expected);
  });
});
```

- [ ] **Step 2: Run the test**

Run: `npx jest __tests__/invoicePaymentsLegacyEquivalence.test.js`
Expected: PASS — 122 tests (1 fixture check + 3 × 40 parameterised + 1 aggregate).

If any case fails, **do not adjust the expectation to match the implementation.** A failure here means a derivation genuinely disagrees with the shipped behaviour, and the derivation is what must change.

- [ ] **Step 3: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0. Record the new total test count — it should be the Task 1 baseline plus 37 (Tasks 2–4) plus 122 (this task) = baseline + 159.

- [ ] **Step 4: Commit**

```bash
git add __tests__/invoicePaymentsLegacyEquivalence.test.js
git commit -m "test: pin legacy equivalence for the payment derivations

Enumerates every legacy invoice shape and asserts the new derivations
reproduce the old collected/outstanding/bucketing formulas exactly. This is
the regression guard that licenses the phase-4 analytics sweep."
```

---

### Task 6: Document the model in ARCHITECTURE.md

**Files:**
- Modify: `ARCHITECTURE.md` (data-model section)

**Interfaces:**
- Consumes: the types from Task 1.
- Produces: nothing consumed by code.

Per `tradeready-docs-and-writing`, a data-shape change requires a doc update in the same phase. `types/models.ts` stays authoritative; ARCHITECTURE.md carries the overview.

- [ ] **Step 1: Update the Invoice data-model block**

The `### Invoice` block at `ARCHITECTURE.md:156` currently reads:

```markdown
### Invoice
- id, customerId (FK), customer (display name)
- jobId (optional)
- number, amount, due, paid, paidAt
- paymentLinkUrl
```

Replace it with (matching the file's terse bullet style — do not switch to prose):

```markdown
### Invoice
- id, customerId (FK), customer (display name)
- jobId (optional)
- number, amount, due, paid, paidAt
- paymentLinkUrl
- payments (optional): ledger of partial payments — `{id, amount, date, method, note?, stripeSessionId?}`.
  A deposit, progress draws and a final balance are separate entries. `paid` is
  retained and maintained as "balance within half a cent of zero".
  **Absent on invoices created before the ledger existed** — `utils/invoicePayments.ts`
  derives those from `paid`/`amount`/`paidAt`, which is why no migration was needed.
- depositRequest (optional): `{amount, percent?, requestedAt}` — the up-front amount asked for.
```

- [ ] **Step 2: Verify the gate is still green**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0 — a docs change should not move any of them.

- [ ] **Step 3: Commit**

```bash
git add ARCHITECTURE.md
git commit -m "docs: describe the invoice payment ledger in ARCHITECTURE.md"
```

---

## Phase 1 exit criteria

Before reporting the phase complete, confirm all of:

- [ ] `npm run typecheck` — 0 errors
- [ ] `npm test` — 0 failures, total count increased by 159 (37 + 122) with no pre-existing test removed or modified
- [ ] `npm run lint` — 0 warnings
- [ ] `git log --oneline master..HEAD` shows 6 commits, one per task
- [ ] `grep -rn "invoicePayments" screens/ components/` returns **nothing** — Phase 1 must not have wired anything into the UI
- [ ] No file under `backend/` was modified

Then stop and report to the owner for the phase gate. Do not begin Phase 2 (the `pullRemote` merge) without an explicit go-ahead.
