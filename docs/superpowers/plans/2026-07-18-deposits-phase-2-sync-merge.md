# Deposits & Partial Payments — Phase 2: Sync Merge Safety

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop a concurrent device edit from silently destroying a payment that the Stripe webhook wrote to the cloud, by union-merging invoice payment ledgers during `pullRemote` instead of replacing the whole record.

**Architecture:** `pullRemote` currently does `local[idx] = remote.data` — a whole-record, last-write-wins replace. Phase 2 routes that assignment through a new pure `mergeRemoteRecord`, which for the `invoices` table unions the two sides' payment ledgers by payment `id` and recomputes `paid`/`paidAt` from the result. Every other table keeps the existing replace, byte for byte. The merge logic lives in pure, directly-testable modules (`utils/invoicePayments.ts` and a new `utils/syncMerge.ts`); `utils/sync.ts` changes by three lines.

**Tech Stack:** TypeScript, React Native (Expo 54), Supabase JS client, Jest with `jest-expo`, no new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-18-deposits-partial-payments-design.md` (§"Sync and webhook")
**Phase 1 (complete):** `docs/superpowers/plans/2026-07-18-deposits-phase-1-model-and-derivations.md`

## Why this phase exists, and why it comes before any UI

`utils/sync.ts:158` reads `local[idx] = remote.data`, and `pushQueue` runs *before* `pullRemote`. Today that is harmless because `paid` is an idempotent boolean — whichever side wins, the result is identical. With a payment ledger it is not. If the Stripe webhook appends a payment to the cloud record while the device edits the same invoice, one side's payments are overwritten and **money silently disappears from the ledger**.

Phase 1 deliberately shipped no writer of `payments`. Nothing can produce this bug yet. Phase 3 (the recording UI) is the first phase that can, so this merge must land first.

## Global Constraints

- **No new dependencies.** Adding a package or changing the Expo SDK requires the owner's explicit approval (`tradeready-change-control`). This phase needs none.
- **The gate must be green before every commit:** `npm run typecheck` (0 errors), `npm test` (0 failures), `npm run lint` (0 warnings — `--max-warnings=0`).
- **Starting baseline: 844 tests / 57 suites** on branch `feat/deposits-partial-payments` @ `b03a7ef`.
- **The `__dataOwner` guard is untouchable.** `utils/sync.ts` keeps a `localDataBelongsToOtherUser` check (~line 201) that is the only thing preventing User A's offline data being pushed into User B's cloud account. Do not modify, reorder, or refactor it. If a change appears to require touching it, STOP and escalate.
- **Never make a user-facing read wait on the network.** The merge runs inside the existing background `pullRemote`; it must not be introduced onto any render path.
- **`SECURE_FIELDS` (`providerKey`, `anthropicKey`, `groqKey`) must never enter the sync queue or Supabase.** This phase does not touch settings, but do not add any code path that widens what is synced.
- **Only the `invoices` table gets merge behaviour.** Every other table in `COLLECTION_TABLES` (`jobs`, `customers`, `expenses`, `pricebook`) must keep the exact current replace semantics. A test pins this.
- **Money is a plain `number` of dollars.** Dates are `"YYYY-MM-DD"` strings. Float epsilon is exactly `0.005`.
- **Do not modify anything under `backend/`.** The webhook rewrite is Phase 5.
- **Do not wire anything into a screen or component.** This phase is data-layer only.

## Design decisions settled before implementation

**1. Remote wins for scalar fields.** The merge changes ledger handling only. `customer`, `amount`, `due`, `desc` and every other field still take the remote value, preserving today's last-write-wins behaviour exactly.

**2. Both sides are materialized before unioning.** This is load-bearing. `materializeLegacyLedger` turns a legacy `paid: true` invoice into its implied single entry with the **deterministic** id `legacy_<invoice.id>`. Because the id is derived from the invoice id, both devices synthesize the *identical* entry and the union collapses it to one.

Without this step, two legacy invoices (both with no `payments` array) would union to `[]`, and the recompute would return `paid: false` — **silently un-paying every legacy paid invoice on its first sync.** That is the single most dangerous mistake available in this phase. Task 1 has a test named for it.

**3. Merged ledgers are sorted into a canonical order.** Phase 1 established that `paidAt` is the date of the payment that closed the balance *in insertion order*. A plain union inherits the order of whichever side happened to be "local", so two devices could derive different `paidAt` for the same invoice. The merge therefore sorts the union by `(date, id)` — ISO date strings sort lexicographically, and `id` breaks ties deterministically. This makes the merge genuinely commutative, which is the property the spec claims.

Canonical ordering applies **only to merged ledgers**. `applyPayment` keeps appending in insertion order; nothing about single-device behaviour changes.

**4. On an id collision, the remote entry wins.** Consistent with scalar handling. In practice a collision means the two sides hold the *same* payment (identical id), so the choice is unobservable — the id namespaces (`p<ts>_<n>` device, `stripe_<session_id>` webhook, `legacy_<invoice_id>` synthetic) make a genuine conflict between different payments impossible.

**5. `applyPayment` is already idempotent by id** (owner decision, landed in Phase 1 at `b03a7ef`). The merge and the mutator now agree: appending a duplicate id is a no-op on both paths.

## File structure

| File | Responsibility | Change |
|---|---|---|
| `utils/invoicePayments.ts` | All payment-ledger math, now including how two ledgers combine | Add `mergePaymentLedgers` |
| `utils/syncMerge.ts` | **New.** Table-aware dispatch: which tables merge, which replace | Create |
| `utils/sync.ts` | The sync engine | 3-line change at `pullRemote` |
| `__tests__/invoicePayments.test.js` | Existing suite | Append merge tests |
| `__tests__/syncMerge.test.js` | **New.** Dispatcher behaviour | Create |
| `__tests__/sync.test.js` | Existing suite | Append one integration test |
| `ARCHITECTURE.md` | Overview docs | Document the exception |

The merge math lives in `invoicePayments.ts` because it *is* payment-ledger math and needs the private `withDerivedPaidFields`. The table dispatch lives in its own tiny module so it is testable without mocking Supabase.

---

### Task 1: `mergePaymentLedgers` — the union itself

**Files:**
- Modify: `utils/invoicePayments.ts` (append; it currently ends with `collectedInRange`)
- Test: `__tests__/invoicePayments.test.js` (append)

**Interfaces:**
- Consumes: `materializeLegacyLedger`, and the private `withDerivedPaidFields` (same file, no export needed).
- Produces: `mergePaymentLedgers(local: Invoice, remote: Invoice): Invoice`

- [ ] **Step 1: Write the failing tests**

Append to `__tests__/invoicePayments.test.js`. Extend the import at the top of the file to include `mergePaymentLedgers`.

```js
describe("mergePaymentLedgers", () => {
  test("keeps payments from BOTH sides (the whole point)", () => {
    // The device recorded a cash payment; the webhook recorded a Stripe one.
    const local = inv({ amount: 1000, payments: [pmt({ id: "p1", amount: 400, date: "2026-07-01" })] });
    const remote = inv({ amount: 1000, payments: [pmt({ id: "stripe_cs_1", amount: 300, date: "2026-07-05" })] });
    const merged = mergePaymentLedgers(local, remote);
    expect(merged.payments).toHaveLength(2);
    expect(amountPaid(merged)).toBe(700);
  });

  test("a payment present on both sides is not double-counted", () => {
    const shared = pmt({ id: "stripe_cs_1", amount: 300, date: "2026-07-05" });
    const local = inv({ amount: 1000, payments: [shared] });
    const remote = inv({ amount: 1000, payments: [shared] });
    const merged = mergePaymentLedgers(local, remote);
    expect(merged.payments).toHaveLength(1);
    expect(amountPaid(merged)).toBe(300);
  });

  test("TWO LEGACY INVOICES DO NOT GET UN-PAID (the dangerous case)", () => {
    // Neither side has a ledger. Without materializing both sides first, the
    // union would be [] and the recompute would return paid:false — silently
    // un-paying every legacy paid invoice on its first sync.
    const local = inv({ id: "i1", amount: 1000, paid: true, paidAt: "2026-06-15", payments: undefined });
    const remote = inv({ id: "i1", amount: 1000, paid: true, paidAt: "2026-06-15", payments: undefined });
    const merged = mergePaymentLedgers(local, remote);
    expect(merged.paid).toBe(true);
    expect(amountPaid(merged)).toBe(1000);
    expect(balanceDue(merged)).toBe(0);
    // The deterministic legacy id means both sides synthesized the SAME entry,
    // so the union collapses it rather than counting $1,000 twice.
    expect(merged.payments).toHaveLength(1);
  });

  test("a legacy invoice on one side merges with a real ledger on the other", () => {
    const local = inv({ id: "i1", amount: 1000, paid: true, paidAt: "2026-06-15", payments: undefined });
    const remote = inv({
      id: "i1", amount: 1000, paid: true, paidAt: "2026-06-15",
      payments: [pmt({ id: "legacy_i1", amount: 1000, date: "2026-06-15" })],
    });
    const merged = mergePaymentLedgers(local, remote);
    expect(merged.payments).toHaveLength(1);
    expect(amountPaid(merged)).toBe(1000);
  });

  test("is COMMUTATIVE — merge(a,b) equals merge(b,a) apart from scalar precedence", () => {
    const a = inv({ amount: 1000, payments: [pmt({ id: "p1", amount: 400, date: "2026-07-10" })] });
    const b = inv({ amount: 1000, payments: [pmt({ id: "stripe_cs_1", amount: 600, date: "2026-07-02" })] });
    const ab = mergePaymentLedgers(a, b);
    const ba = mergePaymentLedgers(b, a);
    expect(ab.payments).toEqual(ba.payments);
    expect(ab.paid).toBe(ba.paid);
    expect(ab.paidAt).toBe(ba.paidAt);
  });

  test("is IDEMPOTENT — merge(x,x) equals x", () => {
    const x = inv({
      amount: 1000,
      payments: [pmt({ id: "p1", amount: 400, date: "2026-07-01" }), pmt({ id: "p2", amount: 600, date: "2026-07-20" })],
    });
    const once = mergePaymentLedgers(x, x);
    expect(once.payments).toEqual(x.payments);
    expect(amountPaid(once)).toBe(1000);
    expect(mergePaymentLedgers(once, once).payments).toEqual(once.payments);
  });

  test("orders the merged ledger canonically by date, then id", () => {
    // Deliberately supplied out of order and interleaved across sides.
    const local = inv({
      amount: 1000,
      payments: [pmt({ id: "p9", amount: 100, date: "2026-07-20" }), pmt({ id: "p1", amount: 100, date: "2026-07-01" })],
    });
    const remote = inv({ amount: 1000, payments: [pmt({ id: "p5", amount: 100, date: "2026-07-10" })] });
    const merged = mergePaymentLedgers(local, remote);
    expect(merged.payments.map((p) => p.id)).toEqual(["p1", "p5", "p9"]);
  });

  test("same-date payments tie-break on id so both devices agree", () => {
    const local = inv({ amount: 1000, payments: [pmt({ id: "pb", amount: 100, date: "2026-07-01" })] });
    const remote = inv({ amount: 1000, payments: [pmt({ id: "pa", amount: 100, date: "2026-07-01" })] });
    expect(mergePaymentLedgers(local, remote).payments.map((p) => p.id)).toEqual(["pa", "pb"]);
    expect(mergePaymentLedgers(remote, local).payments.map((p) => p.id)).toEqual(["pa", "pb"]);
  });

  test("the remote side wins for scalar fields (unchanged last-write-wins)", () => {
    const local = inv({ amount: 1000, desc: "old description", customer: "Old Name" });
    const remote = inv({ amount: 1200, desc: "new description", customer: "New Name" });
    const merged = mergePaymentLedgers(local, remote);
    expect(merged.amount).toBe(1200);
    expect(merged.desc).toBe("new description");
    expect(merged.customer).toBe("New Name");
  });

  test("a merge that completes the balance marks the invoice paid", () => {
    const local = inv({ amount: 1000, payments: [pmt({ id: "p1", amount: 400, date: "2026-07-01" })] });
    const remote = inv({ amount: 1000, payments: [pmt({ id: "stripe_cs_1", amount: 600, date: "2026-07-20" })] });
    const merged = mergePaymentLedgers(local, remote);
    expect(merged.paid).toBe(true);
    expect(merged.paidAt).toBe("2026-07-20");
    expect(balanceDue(merged)).toBe(0);
  });

  test("does not mutate either input", () => {
    const local = inv({ amount: 1000, payments: [pmt({ id: "p1", amount: 400, date: "2026-07-01" })] });
    const remote = inv({ amount: 1000, payments: [pmt({ id: "p2", amount: 300, date: "2026-07-05" })] });
    mergePaymentLedgers(local, remote);
    expect(local.payments).toHaveLength(1);
    expect(remote.payments).toHaveLength(1);
    expect(local.payments[0].id).toBe("p1");
    expect(remote.payments[0].id).toBe("p2");
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npx jest __tests__/invoicePayments.test.js`
Expected: FAIL — `mergePaymentLedgers is not a function`.

- [ ] **Step 3: Write the implementation**

Append to `utils/invoicePayments.ts`:

```ts
/**
 * Combine two versions of the same invoice, keeping the payments from BOTH.
 *
 * This exists because sync's pullRemote used to replace whole records
 * (last-write-wins). That is safe for a boolean `paid` — either side yields the
 * same answer — but with a ledger it destroys money: a payment the Stripe
 * webhook wrote to the cloud vanishes if the device happened to edit the same
 * invoice, or vice versa.
 *
 * Semantics:
 *  - Scalar fields take the REMOTE value (unchanged last-write-wins).
 *  - Payments are UNIONED by id. Both sides are materialized first, so a legacy
 *    invoice contributes its implied entry under the deterministic id
 *    `legacy_<invoice.id>`. That determinism is load-bearing: two legacy copies
 *    synthesize the identical entry and collapse to one. Skipping the
 *    materialize step would union two legacy invoices to [] and silently
 *    un-pay them.
 *  - On an id collision the remote entry wins. Unobservable in practice: the id
 *    namespaces (`p…` device, `stripe_…` webhook, `legacy_…` synthetic) mean a
 *    shared id is the same payment.
 *  - The union is sorted canonically by (date, id). Phase 1 derives `paidAt`
 *    from the closing payment in INSERTION order, so an unsorted union would
 *    let two devices disagree on `paidAt`. Sorting makes this merge genuinely
 *    commutative. Canonical ordering applies to merges only — applyPayment
 *    still appends.
 *
 * Pure: neither input is mutated.
 */
export function mergePaymentLedgers(local: Invoice, remote: Invoice): Invoice {
  const byId = new Map<string, Payment>();
  for (const p of materializeLegacyLedger(local)) byId.set(p.id, p);
  for (const p of materializeLegacyLedger(remote)) byId.set(p.id, p);

  const merged = [...byId.values()].sort((a, b) =>
    a.date === b.date ? a.id.localeCompare(b.id) : a.date.localeCompare(b.date),
  );

  return withDerivedPaidFields(remote, merged);
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `npx jest __tests__/invoicePayments.test.js`
Expected: PASS — 11 new tests.

- [ ] **Step 5: Prove the materialize step is load-bearing**

Temporarily replace both `materializeLegacyLedger(...)` calls with `(local.payments ?? [])` and `(remote.payments ?? [])`, then run:

`npx jest __tests__/invoicePayments.test.js -t "DO NOT GET UN-PAID"`

Expected: that test FAILS (`merged.paid` is `false`). This is the evidence the guard is real. **Revert the change** and confirm the suite passes again. Record both outputs in your report.

- [ ] **Step 6: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0. Test total 855 / 57.

- [ ] **Step 7: Commit**

```bash
git add utils/invoicePayments.ts __tests__/invoicePayments.test.js
git commit -m "feat: add mergePaymentLedgers for cross-device ledger union

Unions two versions of an invoice's payments by id, materializing both sides
first so legacy invoices contribute their deterministic legacy_<id> entry and
collapse rather than un-paying. Sorts canonically by (date, id) so both
devices derive the same paidAt. Commutative and idempotent."
```

---

### Task 2: `mergeRemoteRecord` — the table dispatcher

**Files:**
- Create: `utils/syncMerge.ts`
- Test: `__tests__/syncMerge.test.js`

**Interfaces:**
- Consumes: `mergePaymentLedgers` (Task 1).
- Produces: `mergeRemoteRecord(table: string, local: SyncRecord | undefined, remote: SyncRecord): SyncRecord`, plus the exported `SyncRecord` type.

This module exists so the "which tables merge" decision is unit-testable without mocking Supabase. It is deliberately tiny.

- [ ] **Step 1: Write the failing test**

Create `__tests__/syncMerge.test.js`:

```js
// __tests__/syncMerge.test.js
// Which tables merge and which replace. The invoices table unions payment
// ledgers (see mergePaymentLedgers); EVERY other table keeps the historical
// whole-record replace, and a test pins that so a future edit can't quietly
// widen merge behaviour to collections that don't expect it.

import { mergeRemoteRecord } from "../utils/syncMerge";

const invoice = (over) => ({
  id: "i1", customer: "Acme", number: "INV-1", desc: "", email: "", phone: "",
  amount: 1000, due: "2026-07-01", paid: false, ...over,
});

const pmt = (over) => ({ id: "p1", amount: 500, date: "2026-07-01", method: "cash", ...over });

describe("mergeRemoteRecord — invoices", () => {
  test("unions payments from both sides", () => {
    const local = invoice({ payments: [pmt({ id: "p1", amount: 400 })] });
    const remote = invoice({ payments: [pmt({ id: "stripe_cs_1", amount: 300, date: "2026-07-05" })] });
    const result = mergeRemoteRecord("invoices", local, remote);
    expect(result.payments).toHaveLength(2);
  });

  test("returns the remote record unchanged when there is no local copy", () => {
    const remote = invoice({ payments: [pmt({ id: "p1", amount: 400 })] });
    expect(mergeRemoteRecord("invoices", undefined, remote)).toBe(remote);
  });
});

describe("mergeRemoteRecord — every other table replaces", () => {
  test.each(["jobs", "customers", "expenses", "pricebook"])(
    "%s takes the remote record wholesale, ignoring local",
    (table) => {
      const local = { id: "x1", title: "local version", payments: [pmt({ id: "p1" })] };
      const remote = { id: "x1", title: "remote version" };
      const result = mergeRemoteRecord(table, local, remote);
      // Identity, not just equality: these tables must not be reconstructed.
      expect(result).toBe(remote);
      expect(result.title).toBe("remote version");
      expect(result.payments).toBeUndefined();
    },
  );

  test("an unknown table name also replaces (safe default)", () => {
    const remote = { id: "x1", v: 2 };
    expect(mergeRemoteRecord("something_new", { id: "x1", v: 1 }, remote)).toBe(remote);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npx jest __tests__/syncMerge.test.js`
Expected: FAIL — `Cannot find module '../utils/syncMerge'`.

- [ ] **Step 3: Write the implementation**

Create `utils/syncMerge.ts`:

```ts
// utils/syncMerge.ts
// Decides how a record arriving from Supabase combines with the local copy.
//
// The historical rule — and still the rule for every table but one — is a
// whole-record replace: the cloud version wins outright. That is safe when
// every field is a scalar the two sides can't both meaningfully change.
//
// `invoices` is the exception. Its payment ledger can legitimately grow on
// BOTH sides at once (the Stripe webhook appends server-side while the
// tradesperson records a cash payment on the device), so replacing would
// destroy whichever side lost. Those records union instead.
//
// This is a deliberate, narrow exception to the JSON-blob replace rule
// described in ARCHITECTURE.md. Do not widen it to other tables without
// designing the merge for their shape — a blind union on the wrong record is
// worse than a replace.

import { mergePaymentLedgers } from "./invoicePayments";
import type { Invoice } from "../types/models";

/** The minimum a synced record must have: sync keys everything by id. */
export interface SyncRecord {
  id: string;
  [key: string]: unknown;
}

/**
 * Combine the incoming remote record with the local one.
 *
 * Returns the remote record itself (same reference) whenever the table does not
 * merge or there is no local copy — callers rely on that being cheap.
 */
export function mergeRemoteRecord(
  table: string,
  local: SyncRecord | undefined,
  remote: SyncRecord,
): SyncRecord {
  if (table !== "invoices" || !local) return remote;
  // Both sides are invoice blobs; mergePaymentLedgers owns the ledger rules.
  return mergePaymentLedgers(local as unknown as Invoice, remote as unknown as Invoice) as unknown as SyncRecord;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npx jest __tests__/syncMerge.test.js`
Expected: PASS — 7 tests.

- [ ] **Step 5: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0. Test total 862 / 58.

- [ ] **Step 6: Commit**

```bash
git add utils/syncMerge.ts __tests__/syncMerge.test.js
git commit -m "feat: add mergeRemoteRecord table dispatcher

Invoices union their payment ledgers; every other table keeps the historical
whole-record replace, pinned by test. Kept in its own module so the decision
is testable without mocking Supabase."
```

---

### Task 3: Wire the merge into `pullRemote`

**Files:**
- Modify: `utils/sync.ts` (the pull loop, currently `local[idx] = remote.data` at ~line 158)
- Test: `__tests__/sync.test.js` (append)

**Interfaces:**
- Consumes: `mergeRemoteRecord` (Task 2).
- Produces: no new exports. Behaviour change only.

This is the only task that touches the live sync engine. Keep the diff minimal.

- [ ] **Step 1: Read the current pull loop**

Run: `grep -n -A 20 "async function pullRemote" utils/sync.ts`

Confirm the loop still reads:

```ts
      for (const remote of data) {
        if (remote.deleted) {
          local = local.filter(r => r.id !== remote.id);
        } else {
          const idx = local.findIndex(r => r.id === remote.id);
          if (idx >= 0) {
            local[idx] = remote.data;
          } else {
            local.push(remote.data);
          }
        }
      }
```

If it has drifted from this, STOP and report NEEDS_CONTEXT rather than guessing.

- [ ] **Step 2: Write the failing integration test**

Append to `__tests__/sync.test.js`. It follows the file's existing mocking pattern; read the top of that file first so your mock matches its `buildFromMock` conventions.

```js
describe("pullRemote merges invoice payment ledgers", () => {
  test("a webhook payment in the cloud does not clobber a device payment", async () => {
    const localInvoice = {
      id: "i1", customer: "Acme", number: "INV-1", desc: "", email: "", phone: "",
      amount: 1000, due: "2026-07-01", paid: false,
      payments: [{ id: "p1", amount: 400, date: "2026-07-01", method: "cash" }],
    };
    // The cloud copy has the Stripe payment but NOT the device's cash payment.
    const remoteInvoice = {
      ...localInvoice,
      payments: [{ id: "stripe_cs_1", amount: 600, date: "2026-07-20", method: "stripe" }],
    };

    supabase.from.mockImplementation((table) => {
      const chain = {};
      chain.select = jest.fn(() => chain);
      chain.eq = jest.fn(() => chain);
      chain.gt = jest.fn().mockResolvedValue({
        data: table === "invoices"
          ? [{ id: "i1", data: remoteInvoice, deleted: false }]
          : [],
        error: null,
      });
      chain.maybeSingle = jest.fn().mockResolvedValue({ data: null });
      chain.upsert = jest.fn().mockResolvedValue({ error: null });
      return chain;
    });

    AsyncStorage.getItem.mockImplementation((key) => {
      if (key === "invoices") return Promise.resolve(JSON.stringify([localInvoice]));
      return Promise.resolve(null);
    });

    await syncIfOnline("user-a");

    const write = AsyncStorage.setItem.mock.calls.find(([key]) => key === "invoices");
    expect(write).toBeDefined();
    const stored = JSON.parse(write[1]);
    expect(stored).toHaveLength(1);
    // BOTH payments survive — this is the whole point of the phase.
    expect(stored[0].payments.map((p) => p.id).sort()).toEqual(["p1", "stripe_cs_1"]);
    expect(stored[0].paid).toBe(true);
  });

  test("a non-invoice table still replaces wholesale", async () => {
    const localJob = { id: "j1", title: "local version" };
    const remoteJob = { id: "j1", title: "remote version" };

    supabase.from.mockImplementation((table) => {
      const chain = {};
      chain.select = jest.fn(() => chain);
      chain.eq = jest.fn(() => chain);
      chain.gt = jest.fn().mockResolvedValue({
        data: table === "jobs" ? [{ id: "j1", data: remoteJob, deleted: false }] : [],
        error: null,
      });
      chain.maybeSingle = jest.fn().mockResolvedValue({ data: null });
      chain.upsert = jest.fn().mockResolvedValue({ error: null });
      return chain;
    });

    AsyncStorage.getItem.mockImplementation((key) => {
      if (key === "jobs") return Promise.resolve(JSON.stringify([localJob]));
      return Promise.resolve(null);
    });

    await syncIfOnline("user-a");

    const write = AsyncStorage.setItem.mock.calls.find(([key]) => key === "jobs");
    const stored = JSON.parse(write[1]);
    expect(stored[0].title).toBe("remote version");
  });
});
```

Add `syncIfOnline` to the existing import from `../utils/sync` at the top of the file (it currently imports only `initialSync`).

- [ ] **Step 3: Run the test to verify the first one fails**

Run: `npx jest __tests__/sync.test.js`
Expected: the first new test FAILS — the stored invoice has only `["stripe_cs_1"]`, because the current replace drops the device's `p1`. That failure IS the bug this phase fixes; record it in your report. The second new test should already pass.

- [ ] **Step 4: Make the change**

In `utils/sync.ts`, add to the imports at the top of the file:

```ts
import { mergeRemoteRecord } from './syncMerge';
import type { SyncRecord } from './syncMerge';
```

Then change the pull loop's local-record branch. Replace:

```ts
          const idx = local.findIndex(r => r.id === remote.id);
          if (idx >= 0) {
            local[idx] = remote.data;
          } else {
            local.push(remote.data);
          }
```

with:

```ts
          const idx = local.findIndex(r => r.id === remote.id);
          if (idx >= 0) {
            // invoices union their payment ledgers instead of replacing —
            // see utils/syncMerge.ts. Every other table replaces as before.
            local[idx] = mergeRemoteRecord(table, local[idx], remote.data);
          } else {
            local.push(remote.data);
          }
```

The surrounding `local` declaration is typed `{ id: string }[]`. Widen it to `SyncRecord[]` so the assignment typechecks:

```ts
      let local: SyncRecord[] = localRaw ? JSON.parse(localRaw) : [];
```

Do not change anything else in `pullRemote` — not the `lastSynced` bookkeeping, not the `deleted` branch, not the settings or customer_notes handling below it.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `npx jest __tests__/sync.test.js`
Expected: PASS, including the previously failing merge test and all pre-existing `initialSync` ownership-guard tests.

- [ ] **Step 6: Verify the ownership guard is untouched**

Run: `git diff utils/sync.ts`
Confirm the diff contains ONLY the two import lines, the `local` type widening, and the single `mergeRemoteRecord` call plus its comment. If `localDataBelongsToOtherUser`, `pushAllLocalToCloud`, or the `__dataOwner` handling appears anywhere in the diff, revert and redo — those are untouchable.

- [ ] **Step 7: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0. Test total 864 / 58.

- [ ] **Step 8: Commit**

```bash
git add utils/sync.ts __tests__/sync.test.js
git commit -m "fix: union invoice payment ledgers on pull instead of replacing

pullRemote replaced whole records, so a payment written to the cloud by the
Stripe webhook was destroyed whenever the device edited the same invoice (and
vice versa). Route the local-record branch through mergeRemoteRecord. Every
other table is unaffected. The __dataOwner ownership guard is untouched."
```

---

### Task 4: Document the exception

**Files:**
- Modify: `README.md` (the "Known limitations" block, ~line 306)
- Modify: `ARCHITECTURE.md` (the sync pointer at ~line 39)

**Interfaces:** none consumed by code.

The merge is a deliberate exception to a rule this project treats as load-bearing. An undocumented exception gets "simplified" back by a future session, silently reintroducing payment loss. That is the whole reason this task exists.

**There is also active doc drift to correct.** `README.md` currently states flatly that there is *no* merge. After Task 3 that sentence is false, and it is exactly the sentence a future session would cite while "restoring" the replace.

- [ ] **Step 1: Correct the README's conflict-resolution claim**

`README.md` currently reads (in "### Known limitations", ~line 306):

```markdown
**No conflict resolution.** If the same record is edited on two devices while
both are offline, last-write wins when they both sync. There is no merge or
conflict detection.
```

Replace that paragraph with:

```markdown
**Almost no conflict resolution.** If the same record is edited on two devices
while both are offline, last-write wins when they both sync. There is no
general merge or conflict detection.

The one exception is an invoice's **payment ledger**, which is merged rather
than replaced: `pullRemote` unions the two sides' `payments` by payment id
(`utils/syncMerge.ts` → `mergePaymentLedgers` in `utils/invoicePayments.ts`),
then recomputes `paid` / `paidAt` from the union. Everything else on the
invoice — amount, customer, description — still follows last-write-wins.

The exception exists because a ledger can legitimately grow on both sides at
once: the Stripe webhook appends a payment server-side while the tradesperson
records a cash payment on the device. Replacing would destroy whichever side
lost, i.e. lose money. Union by id is commutative and idempotent, so arrival
order doesn't matter and a repeated webhook delivery can't double-count.

Do NOT "simplify" this back to a plain replace, and do not widen the union to
other tables without designing a merge for their shape.
```

- [ ] **Step 2: Point ARCHITECTURE.md at it**

`ARCHITECTURE.md:39-40` currently reads:

```markdown
**Sync is live:** Supabase (Postgres + Auth) is the sync backend today, not a future item.
See the "Sync model" section of README.md for how the local-first queue works.
```

Append one sentence to that second line so the exception is discoverable from either document:

```markdown
**Sync is live:** Supabase (Postgres + Auth) is the sync backend today, not a future item.
See the "Sync model" section of README.md for how the local-first queue works —
including the one place sync merges rather than replaces (an invoice's payment
ledger, unioned by payment id).
```

- [ ] **Step 3: Verify the gate is unmoved**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0, still 864 / 58 — a docs change moves nothing.

- [ ] **Step 4: Commit**

```bash
git add README.md ARCHITECTURE.md
git commit -m "docs: record the invoices payment-ledger sync merge exception

The README's 'there is no merge or conflict detection' is no longer true —
correct it and explain why the exception exists, so a future session doesn't
cite the stale sentence while restoring the replace."
```

---

## Phase 2 exit criteria

Before reporting the phase complete, confirm all of:

- [ ] `npm run typecheck` — 0 errors
- [ ] `npm test` — 0 failures, 864 tests / 58 suites, no pre-existing test removed or modified
- [ ] `npm run lint` — 0 warnings
- [ ] README.md no longer claims "There is no merge or conflict detection"
- [ ] `git diff master..HEAD -- utils/sync.ts` shows ONLY: two import lines, the `local` type widening, and one `mergeRemoteRecord` call with its comment
- [ ] `grep -n "localDataBelongsToOtherUser" utils/sync.ts` still matches, unchanged
- [ ] `grep -rn "syncMerge\|mergePaymentLedgers" screens/ components/` returns **nothing** — this phase wires into the data layer only
- [ ] No file under `backend/` was modified
- [ ] The Task 1 Step 5 mutation check was performed and recorded (proof the materialize step is load-bearing)

Then stop and report for the phase gate. Do NOT begin Phase 3 (the recording UI) without an explicit go-ahead.

## Carried into later phases — do not address here

From the Phase 1 final review, recorded in `.superpowers/sdd/progress.md`:

- **Phase 5:** `backend/` is a separate CommonJS package and cannot import `utils/invoicePayments.ts`. The webhook would reimplement `withDerivedPaidFields`, `PAID_EPSILON` and the closing-payment rule in JS — two implementations of one money rule, which will drift. Decide then: vendor a JS copy driven by shared test vectors, or keep the server append-only and let the device derive `paid`/`paidAt`. Also: `webhook.js:111` stamps dates in UTC while device payments are local `YYYY-MM-DD`, which now matters because each payment is individually revenue-bucketed.
- **Phase 4:** six of the ~12 sweep targets coerce `amount` (`parseFloat(String(inv.amount)) || 0`); `amountPaid` returns `invoice.amount` verbatim, so a string amount would concatenate rather than sum. Not reachable today — both creation screens validate — but the sweep must pick a contract.
- **Phase 3:** `materializeLegacyLedger` is the de facto "effective ledger" accessor; the history UI will render the synthetic `legacy_<id>` entry and offer to delete it. That path works and is pinned, but whether to show a synthetic row is a UI decision. Consider a `effectivePayments` alias.
