# Server-Side Ledger Merge + Webhook Append — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make it impossible for any writer — device push, Stripe webhook, or future client — to shrink an invoice's payment ledger, and make the webhook record Stripe payments as ledger entries rather than a bare `paid: true`.

**Architecture:** Deletion becomes a one-way `voidedAt` flag so a union can never resurrect it. A deliberately dumb Postgres trigger unions `data->'payments'` on every write to `invoices`. The money math is ported to `backend/lib/paymentMath.js` and pinned against the TypeScript implementation by a shared vector fixture, so the webhook and the reminder cron can both derive paid-ness without the two copies drifting.

**Tech Stack:** TypeScript, React Native (Expo 54), Jest with `jest-expo`, Supabase Postgres (plpgsql), Vercel serverless (CommonJS), no new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-18-server-side-ledger-merge-design.md`

## Global Constraints

- **No new dependencies.** No `package.json` change in either the root or `backend/`. No pgTAP, no property-testing library.
- **The gate must be green before every commit:** `npm run typecheck` (0 errors), `npm test` (0 failures), `npm run lint` (0 warnings — `--max-warnings=0`).
- **Starting baseline: 867 tests / 58 suites** on branch `feat/deposits-partial-payments` @ `ade798c`.
- **Do NOT apply the Supabase migration and do NOT deploy the backend.** Both are owner-gated (`tradeready-change-control`). Tasks 3–5 write code and SQL that land on the branch unapplied and undeployed. If a task seems to require running against the live project, STOP and report.
- **Fixtures must NOT live under `__tests__/`.** `jest-expo`'s default `testMatch` treats every `.js` under `__tests__/` as a suite, so a fixture there fails with "Your test suite must contain at least one test." Shared fixtures go in `__fixtures__/` at the repo root.
- **Void is irreversible.** No code path may clear `voidedAt`. That one-way property is what makes the union commutative; an "unvoid" would silently break convergence.
- **The trigger stays dumb.** It unions the array and nothing else — no `paid`, no `paidAt`, no epsilon. Money rules live only in `utils/invoicePayments.ts` and its `backend/lib/paymentMath.js` mirror.
- **Legacy invoices must stay byte-identical.** Nothing may stamp `payments: []` onto a row that lacks the key — Phase 1's legacy fallback depends on its absence.
- Money is a plain `number` of dollars. Dates are `"YYYY-MM-DD"` strings. Float epsilon is exactly `0.005`.
- Shell is PowerShell on Windows; a Bash tool is also available.

## File structure

| File | Responsibility | Change |
|---|---|---|
| `types/models.ts` | Persisted shapes | Add `Payment.voidedAt` |
| `utils/invoicePayments.ts` | All client payment math | `amountPaid` skips voided; `voidPayment` replaces `removePayment`; merge gains void-wins |
| `backend/lib/paymentMath.js` | **New.** CommonJS mirror for the backend | Create |
| `__fixtures__/paymentVectors.js` | **New.** The shared truth both implementations are tested against | Create |
| `__tests__/paymentMathParity.test.js` | **New.** Anti-drift gate | Create |
| `backend/api/stripe/webhook.js` | Stripe Connect webhook | Append a ledger entry |
| `backend/lib/selectInvoicesToRemind.js` | Overdue-reminder cron | Derive paid from the ledger |
| `supabase/migrations/20260718_invoice_payment_merge.sql` | **New.** The trigger | Create (not applied) |
| `supabase/migrations/verify/20260718_invoice_payment_merge_verify.sql` | **New.** Self-checking verification | Create (not run) |
| `README.md`, `ARCHITECTURE.md` | Docs | Update |

---

### Task 1: Void semantics in the client

**Files:**
- Modify: `types/models.ts`
- Modify: `utils/invoicePayments.ts`
- Test: `__tests__/invoicePayments.test.js`

**Interfaces:**
- Produces: `Payment.voidedAt?: DateString`; `voidPayment(invoice: Invoice, paymentId: string, voidedAt: DateString): Invoice`
- Removes: `removePayment` (nothing consumes it — no UI ships before Phase 3)

**Read this before implementing.** Three separate places sum the ledger, and ALL of them must skip voided entries or a voided payment still counts:
1. `amountPaid` — the public derivation.
2. `withDerivedPaidFields`'s `collected` — decides `paid`.
3. `withDerivedPaidFields`'s closing-payment walk — decides `paidAt`.

Missing any one produces a subtly wrong invoice rather than a crash.

- [ ] **Step 1: Add the field**

In `types/models.ts`, inside `export interface Payment`, after `note?: string;`:

```ts
  /**
   * Set when this payment is voided. Voided entries STAY in the ledger and are
   * skipped by amountPaid — deletion is recorded as DATA, not absence, so a
   * server-side union cannot resurrect it.
   *
   * Void is IRREVERSIBLE. Nothing may clear this field. That one-way property
   * is what makes the ledger union commutative: whichever copy carries the
   * void is unambiguously the later state, regardless of arrival order. To
   * correct a mistaken void, record a new payment.
   */
  voidedAt?: DateString;
```

- [ ] **Step 2: Write the failing tests**

In `__tests__/invoicePayments.test.js`, REPLACE the entire `describe("removePayment", ...)` block with the following. Extend the top-of-file import to swap `removePayment` for `voidPayment`.

```js
describe("voidPayment", () => {
  test("voiding a payment restores the balance", () => {
    const withPayment = applyPayment(inv({ amount: 1000 }), pmt({ id: "p1", amount: 400 }));
    const result = voidPayment(withPayment, "p1", "2026-07-22");
    expect(result.payments).toHaveLength(1);          // the entry REMAINS
    expect(result.payments[0].voidedAt).toBe("2026-07-22");
    expect(amountPaid(result)).toBe(0);               // but no longer counts
    expect(balanceDue(result)).toBe(1000);
  });

  test("voiding the closing payment un-pays the invoice", () => {
    const first = applyPayment(inv({ amount: 1000 }), pmt({ id: "p1", amount: 400, date: "2026-07-01" }));
    const settled = applyPayment(first, pmt({ id: "p2", amount: 600, date: "2026-07-20" }));
    const result = voidPayment(settled, "p2", "2026-07-22");
    expect(result.paid).toBe(false);
    expect(result.paidAt).toBeUndefined();
    expect(isPartlyPaid(result)).toBe(true);
    expect(amountPaid(result)).toBe(400);
  });

  test("voiding a non-closing payment leaves the invoice unpaid but partial", () => {
    const first = applyPayment(inv({ amount: 1000 }), pmt({ id: "p1", amount: 400, date: "2026-07-01" }));
    const settled = applyPayment(first, pmt({ id: "p2", amount: 600, date: "2026-07-20" }));
    const result = voidPayment(settled, "p1", "2026-07-22");
    expect(result.paid).toBe(false);
    expect(amountPaid(result)).toBe(600);
  });

  test("voiding is idempotent — the original void date is kept", () => {
    const withPayment = applyPayment(inv({ amount: 1000 }), pmt({ id: "p1", amount: 400 }));
    const once = voidPayment(withPayment, "p1", "2026-07-22");
    const twice = voidPayment(once, "p1", "2026-08-01");
    expect(twice.payments).toHaveLength(1);
    expect(twice.payments[0].voidedAt).toBe("2026-07-22");
  });

  test("an unknown payment id is a no-op", () => {
    const withPayment = applyPayment(inv({ amount: 1000 }), pmt({ id: "p1", amount: 400 }));
    const result = voidPayment(withPayment, "nope", "2026-07-22");
    expect(result.payments[0].voidedAt).toBeUndefined();
    expect(amountPaid(result)).toBe(400);
  });

  test("a legacy paid invoice can be un-paid by voiding its materialized entry", () => {
    const legacy = inv({ id: "i1", paid: true, amount: 1000, paidAt: "2026-06-15", payments: undefined });
    const result = voidPayment(legacy, "legacy_i1", "2026-07-22");
    expect(result.paid).toBe(false);
    expect(balanceDue(result)).toBe(1000);
  });

  test("voiding every payment leaves the invoice fully unpaid, not legacy-paid", () => {
    // The ledger is non-empty, so amountPaid must NOT fall back to the legacy
    // `paid` flag — it must report 0.
    const withPayment = applyPayment(inv({ amount: 1000, paid: true }), pmt({ id: "p1", amount: 1000 }));
    const result = voidPayment(withPayment, "p1", "2026-07-22");
    expect(amountPaid(result)).toBe(0);
    expect(result.paid).toBe(false);
  });

  test("does not mutate the input invoice", () => {
    const withPayment = applyPayment(inv({ amount: 1000 }), pmt({ id: "p1", amount: 400 }));
    voidPayment(withPayment, "p1", "2026-07-22");
    expect(withPayment.payments[0].voidedAt).toBeUndefined();
  });
});

describe("voided entries and paidAt derivation", () => {
  test("a voided payment does not count toward the closing balance", () => {
    // $600 voided, so $400 + $500 = $900 never settles a $1000 invoice.
    const a = applyPayment(inv({ amount: 1000 }), pmt({ id: "p1", amount: 400, date: "2026-07-01" }));
    const b = applyPayment(a, pmt({ id: "p2", amount: 600, date: "2026-07-10" }));
    const c = applyPayment(b, pmt({ id: "p3", amount: 500, date: "2026-07-20" }));
    const voided = voidPayment(c, "p2", "2026-07-22");
    expect(amountPaid(voided)).toBe(900);
    expect(voided.paid).toBe(false);
    expect(voided.paidAt).toBeUndefined();
  });

  test("paidAt skips voided entries when finding the closing payment", () => {
    const a = applyPayment(inv({ amount: 1000 }), pmt({ id: "p1", amount: 900, date: "2026-07-01" }));
    const b = applyPayment(a, pmt({ id: "p2", amount: 900, date: "2026-07-05" }));
    const c = applyPayment(b, pmt({ id: "p3", amount: 100, date: "2026-07-30" }));
    // Void the 07-05 payment: now 900 + 100 settles it, closing on 07-30.
    const voided = voidPayment(c, "p2", "2026-08-01");
    expect(voided.paid).toBe(true);
    expect(voided.paidAt).toBe("2026-07-30");
  });
});

describe("mergePaymentLedgers — void wins", () => {
  test("a void on the LOCAL side survives the merge", () => {
    const local = inv({ amount: 1000, payments: [pmt({ id: "p1", amount: 400, voidedAt: "2026-07-22" })] });
    const remote = inv({ amount: 1000, payments: [pmt({ id: "p1", amount: 400 })] });
    const merged = mergePaymentLedgers(local, remote);
    expect(merged.payments[0].voidedAt).toBe("2026-07-22");
    expect(amountPaid(merged)).toBe(0);
  });

  test("a void on the REMOTE side survives the merge", () => {
    const local = inv({ amount: 1000, payments: [pmt({ id: "p1", amount: 400 })] });
    const remote = inv({ amount: 1000, payments: [pmt({ id: "p1", amount: 400, voidedAt: "2026-07-22" })] });
    const merged = mergePaymentLedgers(local, remote);
    expect(merged.payments[0].voidedAt).toBe("2026-07-22");
    expect(amountPaid(merged)).toBe(0);
  });

  test("void-wins keeps the merge commutative", () => {
    const a = inv({ amount: 1000, payments: [pmt({ id: "p1", amount: 400, voidedAt: "2026-07-22" })] });
    const b = inv({ amount: 1000, payments: [pmt({ id: "p1", amount: 400 })] });
    expect(mergePaymentLedgers(a, b).payments).toEqual(mergePaymentLedgers(b, a).payments);
  });
});
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `npx jest __tests__/invoicePayments.test.js`
Expected: FAIL — `voidPayment is not a function`.

- [ ] **Step 4: Implement**

In `utils/invoicePayments.ts`:

**(a)** `amountPaid` — skip voided:

```ts
export function amountPaid(invoice: Invoice): number {
  const ledger = invoice.payments;
  if (ledger && ledger.length > 0) {
    // Voided entries stay in the ledger (so a union can't resurrect them) but
    // contribute nothing.
    return ledger.reduce((sum, p) => (p.voidedAt ? sum : sum + p.amount), 0);
  }
  return invoice.paid ? invoice.amount : 0;
}
```

**(b)** In `withDerivedPaidFields`, `collected` must skip voided:

```ts
  const collected = payments.reduce((sum, p) => (p.voidedAt ? sum : sum + p.amount), 0);
```

**(c)** In the same function's closing-payment walk, skip voided entries:

```ts
    for (const p of chronological) {
      if (p.voidedAt) continue;
      running += p.amount;
      if (running >= invoice.amount - PAID_EPSILON) {
        closingDate = p.date;
        break;
      }
    }
```

**(d)** Replace `removePayment` entirely with:

```ts
/**
 * Void a payment and recompute paid/paidAt. Pure — returns a new Invoice.
 *
 * The entry is KEPT and flagged rather than removed: a server-side union
 * cannot tell "unknown to me" from "deleted by me", so deletion has to be
 * data. Voiding is idempotent — re-voiding preserves the original void date —
 * and irreversible; to correct one, record a new payment.
 *
 * Voiding the payment that settled an invoice legitimately flips it back to
 * unpaid. The UI confirms that consequence before calling this.
 */
export function voidPayment(invoice: Invoice, paymentId: string, voidedAt: DateString): Invoice {
  const ledger = materializeLegacyLedger(invoice).map((p) =>
    p.id === paymentId && !p.voidedAt ? { ...p, voidedAt } : p,
  );
  return withDerivedPaidFields(invoice, ledger);
}
```

Add `DateString` to the type import from `../types/models`.

**(e)** In `mergePaymentLedgers`, make the collision rule void-aware:

```ts
  const byId = new Map<string, Payment>();
  for (const p of materializeLegacyLedger(local)) byId.set(p.id, p);
  for (const p of materializeLegacyLedger(remote)) {
    const existing = byId.get(p.id);
    // Void wins regardless of side. voidedAt is irreversible, so whichever copy
    // carries it is unambiguously the later state — which is exactly what keeps
    // this union commutative. Otherwise remote wins, as for scalar fields.
    byId.set(p.id, existing?.voidedAt && !p.voidedAt ? existing : p);
  }
```

Update the doc comment's collision paragraph to state the void-wins rule.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `npx jest __tests__/invoicePayments.test.js`
Expected: PASS.

- [ ] **Step 6: Prove each of the three skip sites is load-bearing**

For each of (a), (b), (c) in turn: remove ONLY that void check, run `npx jest __tests__/invoicePayments.test.js`, and confirm at least one test fails. Restore it before moving to the next. Record all three outputs in your report. If removing any one of them leaves the suite green, the coverage has a hole — add a test that closes it rather than moving on.

- [ ] **Step 7: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0. Test count rises by roughly 12 (13 added, `removePayment`'s 6 replaced by `voidPayment`'s 8, plus 2 derivation and 3 merge tests) — record the actual number; it must not decrease.

- [ ] **Step 8: Commit**

```bash
git add types/models.ts utils/invoicePayments.ts __tests__/invoicePayments.test.js
git commit -m "feat: void payments instead of deleting them

A server-side union cannot distinguish 'unknown to me' from 'deleted by me',
so deletion becomes a one-way voidedAt flag. Void wins on merge collisions,
which keeps the union commutative. amountPaid, the paid calculation and the
paidAt walk all skip voided entries."
```

---

### Task 2: Shared payment math + parity vectors

**Files:**
- Create: `backend/lib/paymentMath.js`
- Create: `__fixtures__/paymentVectors.js`
- Test: `__tests__/paymentMathParity.test.js`

**Interfaces:**
- Consumes: `utils/invoicePayments.ts` (Task 1).
- Produces: `backend/lib/paymentMath.js` exporting `PAID_EPSILON`, `amountPaid`, `balanceDue`, `isFullyPaid`.

`backend/` is a separate CommonJS package and cannot import the TypeScript util — the same constraint `backend/lib/overdue.js` already documents. The difference here: that file has no parity test, and this one does, because these are money rules.

- [ ] **Step 1: Write the shared vectors**

Create `__fixtures__/paymentVectors.js` (repo root — NOT under `__tests__/`, which jest would treat as a suite):

```js
// __fixtures__/paymentVectors.js
// The single source of truth that BOTH payment-math implementations are tested
// against: utils/invoicePayments.ts (app) and backend/lib/paymentMath.js
// (Vercel functions). They are separate packages and cannot share code, so
// __tests__/paymentMathParity.test.js runs both over these vectors and asserts
// they agree. If you change one implementation, change the other or the gate
// fails.
//
// Plain CommonJS so the backend copy can require it without transpilation.

const invoice = (over) => ({
  id: "i1", customer: "Acme", number: "INV-1", desc: "", email: "", phone: "",
  amount: 1000, due: "2026-07-01", paid: false, ...over,
});

const p = (over) => ({ id: "p1", amount: 500, date: "2026-07-01", method: "cash", ...over });

const paymentVectors = [
  {
    label: "legacy unpaid — no ledger",
    invoice: invoice({ paid: false }),
    expectedAmountPaid: 0, expectedBalance: 1000, expectedFullyPaid: false,
  },
  {
    label: "legacy paid — no ledger falls back to the flag",
    invoice: invoice({ paid: true }),
    expectedAmountPaid: 1000, expectedBalance: 0, expectedFullyPaid: true,
  },
  {
    label: "empty ledger array still falls back to the flag",
    invoice: invoice({ paid: true, payments: [] }),
    expectedAmountPaid: 1000, expectedBalance: 0, expectedFullyPaid: true,
  },
  {
    label: "single partial payment",
    invoice: invoice({ payments: [p({ amount: 400 })] }),
    expectedAmountPaid: 400, expectedBalance: 600, expectedFullyPaid: false,
  },
  {
    label: "two payments settling the balance",
    invoice: invoice({ payments: [p({ id: "p1", amount: 400 }), p({ id: "p2", amount: 600 })] }),
    expectedAmountPaid: 1000, expectedBalance: 0, expectedFullyPaid: true,
  },
  {
    label: "ledger wins over a stale paid flag",
    invoice: invoice({ paid: true, payments: [p({ amount: 400 })] }),
    expectedAmountPaid: 400, expectedBalance: 600, expectedFullyPaid: false,
  },
  {
    label: "overpayment clamps the balance at zero",
    invoice: invoice({ payments: [p({ amount: 1200 })] }),
    expectedAmountPaid: 1200, expectedBalance: 0, expectedFullyPaid: true,
  },
  {
    label: "sub-cent shortfall is settled (epsilon)",
    invoice: invoice({ amount: 100, payments: [p({ amount: 99.997 })] }),
    expectedAmountPaid: 99.997, expectedBalance: 100 - 99.997, expectedFullyPaid: true,
  },
  {
    label: "voided payment contributes nothing",
    invoice: invoice({ payments: [p({ id: "p1", amount: 400, voidedAt: "2026-07-22" })] }),
    expectedAmountPaid: 0, expectedBalance: 1000, expectedFullyPaid: false,
  },
  {
    label: "voided payment among live ones",
    invoice: invoice({
      payments: [p({ id: "p1", amount: 400 }), p({ id: "p2", amount: 600, voidedAt: "2026-07-22" })],
    }),
    expectedAmountPaid: 400, expectedBalance: 600, expectedFullyPaid: false,
  },
  {
    label: "every payment voided does NOT fall back to the legacy flag",
    invoice: invoice({ paid: true, payments: [p({ id: "p1", amount: 1000, voidedAt: "2026-07-22" })] }),
    expectedAmountPaid: 0, expectedBalance: 1000, expectedFullyPaid: false,
  },
  {
    label: "a voided payment on an otherwise settled invoice re-opens it",
    invoice: invoice({
      payments: [p({ id: "p1", amount: 400 }), p({ id: "p2", amount: 600, voidedAt: "2026-07-22" })],
    }),
    expectedAmountPaid: 400, expectedBalance: 600, expectedFullyPaid: false,
  },
];

module.exports = { paymentVectors };
```

- [ ] **Step 2: Write the failing parity test**

Create `__tests__/paymentMathParity.test.js`:

```js
// __tests__/paymentMathParity.test.js
// ANTI-DRIFT GATE. utils/invoicePayments.ts (app, TypeScript) and
// backend/lib/paymentMath.js (Vercel functions, CommonJS) implement the same
// money rules and cannot share code — backend/ is a separate package.
//
// This runs BOTH over the same vectors and asserts they agree with each other
// AND with the expected values. Changing one implementation without mirroring
// it in the other fails here immediately. That is the entire point of the file;
// do not weaken it to make a change land.

import { amountPaid, balanceDue, isFullyPaid, PAID_EPSILON } from "../utils/invoicePayments";

const backend = require("../backend/lib/paymentMath");
const { paymentVectors } = require("../__fixtures__/paymentVectors");

describe("the two implementations agree on the epsilon", () => {
  test("PAID_EPSILON matches", () => {
    expect(backend.PAID_EPSILON).toBe(PAID_EPSILON);
  });
});

describe.each(paymentVectors.map((v) => [v.label, v]))("%s", (_label, v) => {
  test("app implementation matches the expected values", () => {
    expect(amountPaid(v.invoice)).toBeCloseTo(v.expectedAmountPaid, 6);
    expect(balanceDue(v.invoice)).toBeCloseTo(v.expectedBalance, 6);
    expect(isFullyPaid(v.invoice)).toBe(v.expectedFullyPaid);
  });

  test("backend implementation matches the expected values", () => {
    expect(backend.amountPaid(v.invoice)).toBeCloseTo(v.expectedAmountPaid, 6);
    expect(backend.balanceDue(v.invoice)).toBeCloseTo(v.expectedBalance, 6);
    expect(backend.isFullyPaid(v.invoice)).toBe(v.expectedFullyPaid);
  });

  test("the two implementations agree with each other exactly", () => {
    expect(backend.amountPaid(v.invoice)).toBe(amountPaid(v.invoice));
    expect(backend.balanceDue(v.invoice)).toBe(balanceDue(v.invoice));
    expect(backend.isFullyPaid(v.invoice)).toBe(isFullyPaid(v.invoice));
  });
});
```

- [ ] **Step 3: Run it to verify it fails**

Run: `npx jest __tests__/paymentMathParity.test.js`
Expected: FAIL — `Cannot find module '../backend/lib/paymentMath'`.

- [ ] **Step 4: Write the backend mirror**

Create `backend/lib/paymentMath.js`:

```js
// backend/lib/paymentMath.js
// Pure payment-ledger math for the backend. MIRRORS utils/invoicePayments.ts —
// duplicated because backend/ is a separate CommonJS package and cannot import
// the app's TypeScript util (same constraint as backend/lib/overdue.js).
//
// THE TWO COPIES ARE PINNED TOGETHER by __tests__/paymentMathParity.test.js,
// which runs both over __fixtures__/paymentVectors.js. If you change one,
// change the other — the gate will catch you if you don't.
//
// Deliberately does NOT implement paidAt derivation or ledger merging: the
// server never needs them (the Postgres trigger unions ledgers, and the device
// derives paidAt). Keeping the mirror small keeps the drift surface small.

const PAID_EPSILON = 0.005;

/**
 * Total received, in dollars. Voided entries stay in the ledger but contribute
 * nothing. An invoice with no ledger falls back to the legacy `paid` flag.
 */
function amountPaid(invoice) {
  const ledger = invoice && invoice.payments;
  if (ledger && ledger.length > 0) {
    return ledger.reduce((sum, p) => (p && p.voidedAt ? sum : sum + p.amount), 0);
  }
  return invoice && invoice.paid ? invoice.amount : 0;
}

function balanceDue(invoice) {
  return Math.max(0, invoice.amount - amountPaid(invoice));
}

function isFullyPaid(invoice) {
  return balanceDue(invoice) <= PAID_EPSILON;
}

module.exports = { PAID_EPSILON, amountPaid, balanceDue, isFullyPaid };
```

- [ ] **Step 5: Run it to verify it passes**

Run: `npx jest __tests__/paymentMathParity.test.js`
Expected: PASS — 37 tests (1 epsilon + 12 vectors × 3).

- [ ] **Step 6: Prove the parity gate actually bites**

Temporarily change `PAID_EPSILON` in `backend/lib/paymentMath.js` to `0.5`, run the parity test, and confirm it FAILS. Then revert and confirm it passes. Do the same for the void check (remove `p.voidedAt ? sum :` from the backend reducer). Record both outputs — this is the evidence the anti-drift mechanism works.

- [ ] **Step 7: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0, +37 tests, +1 suite.

- [ ] **Step 8: Commit**

```bash
git add backend/lib/paymentMath.js __fixtures__/paymentVectors.js __tests__/paymentMathParity.test.js
git commit -m "feat: add backend payment math mirror pinned by parity vectors

backend/ is a separate CommonJS package and cannot import the TS util, so the
money rules are mirrored. The parity test runs both implementations over one
shared vector fixture so the copies cannot drift silently."
```

---

### Task 3: Webhook appends a ledger entry

**Files:**
- Modify: `backend/api/stripe/webhook.js`

**Interfaces:**
- Consumes: `backend/lib/paymentMath.js` (Task 2).

**This code is NOT deployed by this task.** It lands on the branch; deploying is owner-gated.

There is no Jest coverage for `backend/api/` handlers in this repo (only `backend/lib/` is tested), so keep all logic in small pieces and lean on the Task 2 module for anything mathematical.

- [ ] **Step 1: Read the current handler**

Run: `cat backend/api/stripe/webhook.js`

Note the existing guards you must PRESERVE: signature verification, `event.type !== 'checkout.session.completed'` skip, `session.payment_status !== 'paid'` skip, missing `session.metadata.invoiceId` skip, invoice-not-found logged-and-skipped without a Stripe retry, and DB errors returning 500 so Stripe retries.

- [ ] **Step 2: Replace `markInvoicePaid` with a ledger append**

Replace the whole `markInvoicePaid(invoiceId)` helper with `recordStripePayment(invoiceId, session)` and update its call site (`await markInvoicePaid(invoiceId);` becomes `await recordStripePayment(invoiceId, session);`).

Add near the top, beside the other requires:

```js
const { amountPaid, isFullyPaid } = require('../../lib/paymentMath');
```

New helper:

```js
async function recordStripePayment(invoiceId, session) {
  const supabaseHeaders = {
    Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
    apikey: SUPABASE_SERVICE_ROLE_KEY,
  };

  const fetchRes = await fetch(
    `${SUPABASE_URL}/rest/v1/invoices?id=eq.${encodeURIComponent(invoiceId)}&select=user_id,data`,
    { headers: supabaseHeaders }
  );

  if (!fetchRes.ok) {
    throw new Error(`Supabase fetch ${fetchRes.status}: ${await fetchRes.text()}`);
  }

  const rows = await fetchRes.json();
  if (!rows.length) {
    // Invoice hasn't synced to Supabase yet (device was offline when the link
    // was generated). Log and return — retries won't help until it syncs.
    console.warn(`[stripe/webhook] invoice ${invoiceId} not found in Supabase — skipping`);
    return;
  }

  const { user_id, data } = rows[0];
  const paymentId = `stripe_${session.id}`;
  const existing = Array.isArray(data?.payments) ? data.payments : [];

  // Idempotency: a repeated Stripe delivery must not append twice. The
  // Postgres trigger's union would collapse the duplicate id anyway, but
  // checking here keeps the write itself clean.
  if (existing.some((p) => p && p.id === paymentId)) return;

  // NOTE: dated from UTC. The device records local dates, so a payment near
  // midnight at a large offset can land on the adjacent day — and since each
  // payment is individually revenue-bucketed, that can shift a month boundary.
  // The server does not know the user's timezone. Accepted limitation.
  const payment = {
    id: paymentId,
    amount: (session.amount_total || 0) / 100,
    date: new Date().toISOString().split('T')[0],
    method: 'card',
    stripeSessionId: session.id,
  };

  const payments = [...existing, payment];
  const nextData = { ...data, payments };

  // paid/paidAt are a best-effort CACHE, not the source of truth: the trigger
  // may union in entries this function never saw. The device re-derives both
  // on sync, and the reminder cron derives from the ledger rather than reading
  // these fields.
  const settled = isFullyPaid(nextData);
  nextData.paid = settled;
  if (settled) {
    nextData.paidAt = payment.date;
  } else {
    delete nextData.paidAt;
  }

  console.log(
    `[stripe/webhook] invoice ${invoiceId}: +$${payment.amount} (${paymentId}), ` +
    `paid ${amountPaid(nextData)} of ${nextData.amount}`
  );

  const upsertRes = await fetch(`${SUPABASE_URL}/rest/v1/invoices`, {
    method: 'POST',
    headers: {
      ...supabaseHeaders,
      'Content-Type': 'application/json',
      Prefer: 'resolution=merge-duplicates',
    },
    body: JSON.stringify({
      id: invoiceId,
      user_id,
      data: nextData,
      updated_at: new Date().toISOString(),
      deleted: false,
    }),
  });

  if (!upsertRes.ok) {
    throw new Error(`Supabase upsert ${upsertRes.status}: ${await upsertRes.text()}`);
  }
}
```

Note the deliberate removal of the old `if (data?.paid) return;` guard: with partial payments, an invoice can receive a second Stripe payment legitimately. Idempotency is now keyed on the session id, which is the correct key.

- [ ] **Step 3: Update the file header comment**

The header still describes the old behaviour ("marks invoices paid"). Rewrite the opening comment to describe appending a ledger entry, note that `paid`/`paidAt` are a best-effort cache, and note that the Postgres trigger unions ledgers so this write cannot shrink one. Keep the existing Stripe-dashboard setup instructions and the env-var list intact.

- [ ] **Step 4: Syntax-check the handler**

Run: `node --check backend/api/stripe/webhook.js`
Expected: no output (exit 0).

- [ ] **Step 5: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0, test count unchanged from Task 2.

- [ ] **Step 6: Commit**

```bash
git add backend/api/stripe/webhook.js
git commit -m "feat: webhook records a Stripe payment as a ledger entry

Appends {id: stripe_<session>, amount, date, method} instead of writing a bare
paid: true, which the ledger merge would otherwise discard once an invoice has
any recorded payment. Idempotency moves from the paid flag to the session id.
NOT DEPLOYED — owner-gated."
```

---

### Task 4: Cron derives paid-ness from the ledger

**Files:**
- Modify: `backend/lib/selectInvoicesToRemind.js`
- Test: `__tests__/reminderLogic.test.js` (existing suite — append to it, do not create a new file)

**Interfaces:**
- Consumes: `backend/lib/paymentMath.js` (Task 2).

**Why this is needed.** The trigger can union in payments the webhook never saw, so the stored `paid` flag can be stale. If the cron keeps reading `!invoice.paid`, a fully-paid invoice can still receive dunning emails. The ledger is the truth.

- [ ] **Step 1: Read the existing tests**

Run: `cat __tests__/reminderLogic.test.js`

This module already has coverage. Read it so your new cases match its fixture and date-mocking conventions, and so you can confirm afterwards that every pre-existing case still passes — a change to the filter condition is exactly the kind of edit that quietly breaks an adjacent guard.

- [ ] **Step 2: Write the failing tests**

Add to that suite:

```js
describe("ledger-aware paid detection", () => {
  const base = {
    id: "i1", email: "a@b.com", due: "2026-06-01", amount: 1000, paid: false,
  };
  const settings = { autoSendEmailEnabled: true, rules: [{ days: 3 }] };
  const today = new Date(2026, 6, 4);

  test("an invoice fully settled by its ledger is NOT reminded, despite paid:false", () => {
    // The stored flag is stale — the trigger unioned in a payment the webhook
    // never saw. The ledger is the truth.
    const invoices = [{ ...base, paid: false, payments: [{ id: "p1", amount: 1000, date: "2026-07-01" }] }];
    expect(selectInvoicesToRemind({ invoices, settings, alreadySentInvoiceIds: [], today })).toHaveLength(0);
  });

  test("a partly-paid invoice IS still reminded", () => {
    const invoices = [{ ...base, paid: false, payments: [{ id: "p1", amount: 400, date: "2026-07-01" }] }];
    expect(selectInvoicesToRemind({ invoices, settings, alreadySentInvoiceIds: [], today })).toHaveLength(1);
  });

  test("an invoice whose only payment was voided IS reminded", () => {
    const invoices = [{
      ...base, paid: true,
      payments: [{ id: "p1", amount: 1000, date: "2026-07-01", voidedAt: "2026-07-22" }],
    }];
    expect(selectInvoicesToRemind({ invoices, settings, alreadySentInvoiceIds: [], today })).toHaveLength(1);
  });

  test("a legacy paid invoice with no ledger is still NOT reminded", () => {
    const invoices = [{ ...base, paid: true }];
    expect(selectInvoicesToRemind({ invoices, settings, alreadySentInvoiceIds: [], today })).toHaveLength(0);
  });
});
```

- [ ] **Step 3: Run to verify the first and third fail**

Run: `npx jest __tests__/reminderLogic.test.js`
Expected: the "fully settled by its ledger" and "only payment was voided" tests FAIL — the current code reads the stale flag. Record the output.

- [ ] **Step 4: Implement**

In `backend/lib/selectInvoicesToRemind.js`, add beside the existing require:

```js
const { isFullyPaid } = require("./paymentMath");
```

and replace the `!invoice.paid` filter condition with:

```js
      // Derive from the ledger rather than trusting the stored flag: the
      // Postgres trigger can union in payments the webhook never saw, so
      // `paid` may be stale. A voided payment correctly re-opens the invoice.
      !isFullyPaid(invoice) &&
```

Change nothing else — the opt-in guard, the rules parsing, the `NaN` rejection, the email and due-date checks and the already-sent set all stay exactly as they are.

- [ ] **Step 5: Run to verify they pass**

Run: `npx jest __tests__/reminderLogic.test.js`
Expected: PASS, including every pre-existing test in the file unchanged.

- [ ] **Step 6: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0.

- [ ] **Step 7: Commit**

```bash
git add backend/lib/selectInvoicesToRemind.js __tests__/reminderLogic.test.js
git commit -m "fix: overdue cron derives paid-ness from the payment ledger

The stored paid flag can be stale once the Postgres trigger unions in payments
the webhook never saw, which would dun a fully-paid invoice. A voided payment
correctly re-opens the invoice for reminders. NOT DEPLOYED — owner-gated."
```

---

### Task 5: The Postgres trigger and its verification script

**Files:**
- Create: `supabase/migrations/20260718_invoice_payment_merge.sql`
- Create: `supabase/migrations/verify/20260718_invoice_payment_merge_verify.sql`

**Interfaces:** none consumed by code.

**DO NOT APPLY EITHER FILE.** Applying the migration to the live project is owner-gated. This task writes and self-reviews SQL only.

- [ ] **Step 1: Confirm the `invoices` table shape**

The six collection tables predate `supabase/migrations/` (they were created through the dashboard), so no migration in the repo defines `invoices`. Determine its column types from how the code reads and writes it:

Run: `grep -rn "from('invoices')\|rest/v1/invoices" utils/ backend/ | head -20`

From `utils/sync.ts` and the backend you should be able to confirm the columns in play: `id`, `user_id`, `data` (jsonb), `updated_at`, `deleted`. Write the migration against exactly those. Record in your report what you confirmed and from which lines.

If anything about the shape is ambiguous, note it in the report as something the owner must confirm before applying — do NOT guess silently.

- [ ] **Step 2: Write the migration**

Create `supabase/migrations/20260718_invoice_payment_merge.sql`:

```sql
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
        -- Void wins first; otherwise the incoming (NEW) version wins.
        order by ((value ->> 'voidedAt') is not null) desc, prio desc
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
```

- [ ] **Step 3: Write the verification script**

Create `supabase/migrations/verify/20260718_invoice_payment_merge_verify.sql`:

```sql
-- 20260718_invoice_payment_merge_verify.sql
--
-- Self-checking verification for the merge_invoice_payments trigger.
-- Wrapped in a transaction that ALWAYS rolls back, so it touches no real data.
-- Run once against the project after applying the migration:
--   psql "$DATABASE_URL" -f supabase/migrations/verify/20260718_invoice_payment_merge_verify.sql
-- Success prints four NOTICE lines and "ALL CHECKS PASSED". Any failure raises.

begin;

do $$
declare
  uid       uuid;
  ledger    jsonb;
  test_id   text := 'verify_trigger_i1';
  legacy_id text := 'verify_trigger_i2';
begin
  select id into uid from auth.users limit 1;
  if uid is null then
    raise exception 'no auth.users row available to satisfy the FK';
  end if;

  ---------------------------------------------------------------- 1. seed
  insert into public.invoices (id, user_id, data, updated_at, deleted)
  values (test_id, uid,
    jsonb_build_object(
      'id', test_id, 'amount', 1000, 'paid', false,
      'payments', jsonb_build_array(
        jsonb_build_object('id','p1','amount',400,'date','2026-07-01','method','cash'),
        jsonb_build_object('id','p2','amount',600,'date','2026-07-20','method','card')
      )
    ),
    now(), false);
  raise notice 'CHECK 1 ok: seeded a two-payment ledger';

  ------------------------------------------- 2. stale push carrying only p1
  update public.invoices
     set data = jsonb_build_object(
       'id', test_id, 'amount', 1000, 'paid', false,
       'payments', jsonb_build_array(
         jsonb_build_object('id','p1','amount',400,'date','2026-07-01','method','cash')
       )
     )
   where id = test_id;

  select data -> 'payments' into ledger from public.invoices where id = test_id;
  if jsonb_array_length(ledger) <> 2 then
    raise exception 'CHECK 2 FAILED: stale push shrank the ledger to %', ledger;
  end if;
  raise notice 'CHECK 2 ok: stale push did not shrink the ledger';

  --------------------------------------------------------- 3. void sticks
  update public.invoices
     set data = jsonb_build_object(
       'id', test_id, 'amount', 1000, 'paid', false,
       'payments', jsonb_build_array(
         jsonb_build_object('id','p1','amount',400,'date','2026-07-01','method','cash',
                            'voidedAt','2026-07-22')
       )
     )
   where id = test_id;

  select data -> 'payments' into ledger from public.invoices where id = test_id;
  if jsonb_array_length(ledger) <> 2 then
    raise exception 'CHECK 3 FAILED: expected 2 entries, got %', ledger;
  end if;
  if not exists (
    select 1 from jsonb_array_elements(ledger) e
     where e ->> 'id' = 'p1' and e ->> 'voidedAt' = '2026-07-22'
  ) then
    raise exception 'CHECK 3 FAILED: the void was reverted by the union: %', ledger;
  end if;
  raise notice 'CHECK 3 ok: void survived the union';

  ------------------------------------ 4. legacy invoice passes through clean
  insert into public.invoices (id, user_id, data, updated_at, deleted)
  values (legacy_id, uid,
    jsonb_build_object('id', legacy_id, 'amount', 500, 'paid', true, 'paidAt', '2026-06-15'),
    now(), false);

  update public.invoices
     set data = jsonb_build_object('id', legacy_id, 'amount', 500, 'paid', true,
                                   'paidAt', '2026-06-15', 'desc', 'edited')
   where id = legacy_id;

  select data into ledger from public.invoices where id = legacy_id;
  if ledger ? 'payments' then
    raise exception 'CHECK 4 FAILED: legacy invoice gained a payments key: %', ledger;
  end if;
  raise notice 'CHECK 4 ok: legacy invoice untouched, no payments key added';

  raise notice 'ALL CHECKS PASSED';
end $$;

rollback;
```

- [ ] **Step 4: Self-review the SQL**

You cannot execute this — there is no database connection available and applying it is owner-gated. So review it by reading, and record your reasoning in the report for each of:

- Does the `ranked` CTE's `order by` put void first and NEW second? Walk through the case where OLD has `p1` voided and NEW has `p1` live, and the reverse.
- Does `jsonb_set(..., true)` create the `payments` key when NEW lacks it? (It must — that is the stale-push case.)
- Can the early return for "neither side has payments" ever be reached when one side does?
- Is `jsonb_array_elements` safe if `data->'payments'` is a JSON object rather than an array (a malformed blob)? Note what would happen.
- Is the whole file re-runnable without error?

Report anything you are unsure about rather than asserting it is fine.

- [ ] **Step 5: Confirm the gate is unmoved**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0, unchanged counts — SQL files are not in any test or lint path.

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/20260718_invoice_payment_merge.sql supabase/migrations/verify/20260718_invoice_payment_merge_verify.sql
git commit -m "feat: add invoice payment ledger union trigger (NOT APPLIED)

A BEFORE INSERT OR UPDATE trigger unions data->'payments' by payment id so no
writer can shrink a ledger, closing the stale-push clobber. Deliberately dumb:
union only, no paid/paidAt/epsilon. Ships with a self-checking verification
script that runs inside a rolled-back transaction.

Applying this to the live project is owner-gated and has NOT been done."
```

---

### Task 6: Documentation

**Files:**
- Modify: `README.md` (the "Almost no conflict resolution" block)
- Modify: `ARCHITECTURE.md` (the Invoice data-model block)

- [ ] **Step 1: Update the README's caveat**

Phase 2 added a paragraph to `README.md` stating that the union protects only the device copy on pull and that a server-side write can still be clobbered by a later device push. With the trigger, that caveat becomes wrong.

Replace that paragraph with one explaining that the union is now enforced on BOTH sides — `pullRemote` on the device and a Postgres trigger on every write to the `invoices` table — so neither a stale device push nor a webhook write can shrink a ledger. State plainly that this depends on deletion being recorded as a one-way `voidedAt` flag rather than removal, because a union cannot distinguish an unknown payment from a deleted one.

**Only make this change if the migration has actually been applied.** If it has not (which is the expected state when this task runs), write the paragraph in the future tense — "once the trigger migration is applied" — and add a one-line note that it is pending. Do not document an unapplied guarantee as live.

- [ ] **Step 2: Add `voidedAt` to the ARCHITECTURE.md Invoice block**

The `### Invoice` block lists the `payments` ledger. Add to the `payments` bullet:

```markdown
  Payments are voided, never removed: a voided entry stays in the ledger with a
  `voidedAt` date and is skipped by `amountPaid`. Deletion has to be data rather
  than absence, because the sync union cannot distinguish "unknown to me" from
  "deleted by me".
```

- [ ] **Step 3: Confirm the gate is unmoved**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0.

- [ ] **Step 4: Commit**

```bash
git add README.md ARCHITECTURE.md
git commit -m "docs: record void semantics and the two-sided ledger union"
```

---

## Exit criteria

- [ ] `npm run typecheck` — 0 errors
- [ ] `npm test` — 0 failures; no pre-existing test removed except `removePayment`'s, which Task 1 replaces with `voidPayment`'s
- [ ] `npm run lint` — 0 warnings
- [ ] `grep -rn "removePayment" utils/ screens/ components/ __tests__/` returns nothing
- [ ] `grep -rn "voidedAt" utils/invoicePayments.ts` shows the check in all THREE sum sites (`amountPaid`, `collected`, the closing-payment walk)
- [ ] The Task 1 Step 6 three-way mutation check was performed and recorded
- [ ] The Task 2 Step 6 parity-gate mutation check was performed and recorded
- [ ] `node --check backend/api/stripe/webhook.js` exits 0
- [ ] `grep -rn "invoicePayments" screens/ components/` still returns nothing — no UI ships in this work
- [ ] The migration has NOT been applied and the backend has NOT been deployed

Then stop and report. The owner decides when to apply the migration and deploy.

## After this lands — the owner-gated sequence

1. Apply `supabase/migrations/20260718_invoice_payment_merge.sql` to the live project.
2. Run the verification script; expect four NOTICEs and `ALL CHECKS PASSED`.
3. Deploy the backend to Vercel (webhook + cron).
4. Update the README paragraph from future to present tense.
5. Only then is Phase 3 (the recording UI) safe to build.

## Carried, still not addressed

- **I5:** `pullRemote` writes merged records with a raw `AsyncStorage.setItem`, bypassing the sync queue, so a union is never re-enqueued. With the trigger in place the cloud copy is now protected, which weakens the consequence — but a merged record still isn't pushed until the user next saves.
- **M7:** the `remote.deleted` branch still drops local payments outright.
- The Phase 1 `MonthlyChart` note: it still buckets a paid invoice's full amount on `paidAt || due` rather than per payment.
