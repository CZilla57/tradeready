# Change Orders Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Documented, customer-approved scope changes on jobs ("+$850 rotted subfloor") whose approved amounts flow automatically into billing.

**Architecture:** `Job.changeOrders?: ChangeOrder[]` on the synced job blob (additive — no migration). Per-CO e-sign approval reuses the shipped estimate-approval flow (two new actions on the existing `estimate/[action].js` dispatcher; Vercel stays 11/12 functions) plus a device-written manual decision. `jobBillableTotal = estimateTotal + Σ approved COs` becomes the single source of truth for display; `computeBillableBreakdown` becomes CO-inclusive so all three invoice paths pick COs up automatically. Spec: `docs/superpowers/specs/2026-08-05-change-orders-design.md`.

**Tech Stack:** Expo 54 / RN 0.81 / React 19 / TypeScript (strict), Jest + RNTL, Vercel serverless (CommonJS backend), static HTML customer page (tradeready-legal repo).

## Global Constraints

- Branch: `feat/change-orders` off master (`3b38c58` or later). Run `git branch --show-current` before EVERY commit (concurrent-session trap).
- Gate green at every commit: `npm run typecheck` 0 errors, `npm test` all pass, `npm run lint` 0 warnings. Never commit red.
- NO new dependencies, NO app.json plugin changes, NO Supabase migration, NO new Vercel function (`backend/api/` file count must not grow).
- `job.estimateTotal` is NEVER mutated by this feature.
- Absent `job.changeOrders` must behave exactly as today — every helper treats absent as `[]`.
- Money formatters: proposed money → `formatQuote`; never inline `"$" + n`.
- Themed components use the `createStyles(colors, shadow)` + `useMemo` factory pattern with `useTheme()`.
- Customer records only via `getOrCreateCustomer`/`resolveCustomer` — never raw pushes.
- Commit messages: imperative, `feat:`/`fix:`/`docs:` prefix, specific subject.
- `backend/` is a separate CommonJS package — client logic mirrored there needs a parity test (`jobDunningParity.test.js` convention).
- change.html work happens in the SIBLING repo `../tradeready-legal` on a held branch — never push that repo.

---

### Task 1: ChangeOrder types + `utils/changeOrders.ts` core helpers

**Files:**
- Modify: `types/models.ts` (add `ChangeOrderDecision`, `ChangeOrder`, `Job.changeOrders`)
- Create: `utils/changeOrders.ts`
- Test: `__tests__/changeOrders.test.js`

**Interfaces:**
- Consumes: `EstimateApproval`, `EstimateApprovalSnapshot`, `Job`, `JobStatus` from `types/models.ts`; `roundToCents` from `utils/invoicePayments.ts`.
- Produces (later tasks import ALL of these from `utils/changeOrders.ts`):
  - `type ChangeOrderStatus = "pending" | "awaiting" | "approved" | "declined" | "cancelled"`
  - `newChangeOrderId(): string`
  - `changeOrderStatus(co: ChangeOrder): ChangeOrderStatus`
  - `approvedChangeOrderTotal(job: Pick<Job, "changeOrders">): number`
  - `jobBillableTotal(job: Pick<Job, "estimateTotal" | "changeOrders">): number`
  - `canAddChangeOrder(status: JobStatus): boolean`
  - `validateChangeOrderInput(title: string, amountText: string, job: Job, editingId?: string): { ok: true; title: string; amount: number } | { ok: false; message: string }`
  - `applyManualDecision(co: ChangeOrder, decision: "approved" | "declined", note: string, today: string): ChangeOrder`
  - `cancelChangeOrder(co: ChangeOrder, today: string): ChangeOrder`
  - `buildChangeOrderSnapshot(co: ChangeOrder, job: Job, customer: Pick<Customer, "name">, settings: Pick<Settings, "businessName">): EstimateApprovalSnapshot`

- [ ] **Step 1: Add the types to `types/models.ts`**

Insert directly after the `EstimateApproval` interface (after its closing `}`, currently line 115):

```ts
/** Device-written record of an on-site (verbal) change-order decision. */
export interface ChangeOrderDecision {
  decision: "approved" | "declined";
  decidedAt: DateString;   // local "YYYY-MM-DD", device clock
  note?: string;           // e.g. "verbal OK on site"
}

/**
 * A documented scope change on a job (2026-08-05 spec). Approved change
 * orders raise the job's billable total (utils/changeOrders.ts
 * jobBillableTotal); job.estimateTotal is NEVER mutated — it stays the
 * as-approved baseline that computeEstimateBreakdown's residual math
 * depends on. Status is DERIVED by changeOrderStatus(), never stored.
 */
export interface ChangeOrder {
  id: string;              // co<timestamp>_<counter>
  title: string;
  description?: string;
  /** Dollars. Negative = descope credit. */
  amount: number;
  createdAt: DateString;
  /**
   * Link-based approval — reuses EstimateApproval verbatim. decision/
   * consentAt/signer fields are written SERVER-SIDE only (change-respond),
   * exactly like Job.approval.
   */
  approval?: EstimateApproval;
  /** On-site decision — device-written. Separate field from `approval` so
      the device never writes into the server-owned object. */
  manualDecision?: ChangeOrderDecision;
  /**
   * One-way cancel stamp (mirrors Payment.voidedAt): cancelled COs stay in
   * the list as data, excluded from billable totals. Nothing may clear it.
   */
  cancelledAt?: DateString;
}
```

And inside `interface Job`, after the `approval?: EstimateApproval;` line:

```ts
  /**
   * Scope changes (2026-08-05 spec). OPTIONAL and additive — ABSENT on every
   * pre-feature job, deliberate; utils/changeOrders.ts treats absent as [].
   */
  changeOrders?: ChangeOrder[];
```

- [ ] **Step 2: Write the failing test `__tests__/changeOrders.test.js`**

```js
const {
  changeOrderStatus,
  approvedChangeOrderTotal,
  jobBillableTotal,
  canAddChangeOrder,
  validateChangeOrderInput,
  applyManualDecision,
  cancelChangeOrder,
  buildChangeOrderSnapshot,
  newChangeOrderId,
} = require("../utils/changeOrders");

const co = (over = {}) => ({
  id: "co1", title: "Rotted subfloor", amount: 850, createdAt: "2026-08-05", ...over,
});
const job = (over = {}) => ({
  id: "j1", customerId: "c1", customerName: "Dana", title: "Bath remodel",
  description: "", status: "in_progress", scheduledDate: null,
  scheduledStartTime: null, scheduledEndTime: null, address: "",
  estimateTotal: 2400, laborHours: 4, laborRate: 85, materials: [],
  materialMarkup: 20, overhead: 15, margin: 20, notes: "", invoiceId: null,
  createdAt: "2026-08-01", ...over,
});

describe("changeOrderStatus", () => {
  it("derives pending with no approval and no manual decision", () => {
    expect(changeOrderStatus(co())).toBe("pending");
  });
  it("derives awaiting once a link is minted", () => {
    expect(changeOrderStatus(co({ approval: { token: "T", sentAt: "s", snapshot: {} } }))).toBe("awaiting");
  });
  it("derives approved from a server (link) decision", () => {
    expect(changeOrderStatus(co({ approval: { token: "T", sentAt: "s", snapshot: {}, decision: "approved" } }))).toBe("approved");
  });
  it("derives approved/declined from a manual decision", () => {
    expect(changeOrderStatus(co({ manualDecision: { decision: "approved", decidedAt: "2026-08-05" } }))).toBe("approved");
    expect(changeOrderStatus(co({ manualDecision: { decision: "declined", decidedAt: "2026-08-05" } }))).toBe("declined");
  });
  it("link decision WINS over manual in the race window", () => {
    const both = co({
      approval: { token: "T", sentAt: "s", snapshot: {}, decision: "declined" },
      manualDecision: { decision: "approved", decidedAt: "2026-08-05" },
    });
    expect(changeOrderStatus(both)).toBe("declined");
  });
  it("cancelled beats everything", () => {
    expect(changeOrderStatus(co({ cancelledAt: "2026-08-05", approval: { token: "T", sentAt: "s", snapshot: {}, decision: "approved" } }))).toBe("cancelled");
  });
});

describe("billable totals", () => {
  const approved = co({ manualDecision: { decision: "approved", decidedAt: "d" } });
  it("legacy job (changeOrders absent) — billable equals estimateTotal", () => {
    expect(approvedChangeOrderTotal(job())).toBe(0);
    expect(jobBillableTotal(job())).toBe(2400);
  });
  it("sums ONLY approved COs — pending/awaiting/declined/cancelled excluded", () => {
    const j = job({ changeOrders: [
      approved,
      co({ id: "co2", amount: 100 }),                                                   // pending
      co({ id: "co3", amount: 100, approval: { token: "T", sentAt: "s", snapshot: {} } }), // awaiting
      co({ id: "co4", amount: 100, manualDecision: { decision: "declined", decidedAt: "d" } }),
      co({ id: "co5", amount: 100, cancelledAt: "d", manualDecision: { decision: "approved", decidedAt: "d" } }),
    ] });
    expect(approvedChangeOrderTotal(j)).toBe(850);
    expect(jobBillableTotal(j)).toBe(3250);
  });
  it("negative (descope) credits subtract and cents round", () => {
    const j = job({ changeOrders: [
      approved,
      co({ id: "co2", amount: -100.005, manualDecision: { decision: "approved", decidedAt: "d" } }),
    ] });
    expect(jobBillableTotal(j)).toBe(3150);
  });
});

describe("canAddChangeOrder", () => {
  it.each(["approved", "scheduled", "in_progress", "complete"])("allows %s", (s) => {
    expect(canAddChangeOrder(s)).toBe(true);
  });
  it.each(["lead", "estimate_sent", "invoiced", "paid", "declined"])("blocks %s", (s) => {
    expect(canAddChangeOrder(s)).toBe(false);
  });
});

describe("validateChangeOrderInput", () => {
  it("accepts a title + positive amount", () => {
    const out = validateChangeOrderInput("Subfloor", "850", job());
    expect(out).toEqual({ ok: true, title: "Subfloor", amount: 850 });
  });
  it("rejects empty title, empty/NaN/zero amount", () => {
    expect(validateChangeOrderInput("  ", "850", job()).ok).toBe(false);
    expect(validateChangeOrderInput("X", "", job()).ok).toBe(false);
    expect(validateChangeOrderInput("X", "abc", job()).ok).toBe(false);
    expect(validateChangeOrderInput("X", "0", job()).ok).toBe(false);
  });
  it("blocks a credit that would push billable total below $0", () => {
    const out = validateChangeOrderInput("Huge credit", "-2500", job());
    expect(out.ok).toBe(false);
    expect(out.message).toMatch(/below \$0/);
  });
  it("allows a credit that keeps billable ≥ 0, and excludes the CO being edited from the check", () => {
    expect(validateChangeOrderInput("Credit", "-2400", job()).ok).toBe(true);
    const j = job({ changeOrders: [co({ id: "coE", amount: -2400 })] }); // pending, being edited
    expect(validateChangeOrderInput("Credit", "-2400", j, "coE").ok).toBe(true);
  });
});

describe("applyManualDecision / cancelChangeOrder", () => {
  it("stamps manualDecision with note and date on pending + awaiting COs", () => {
    const out = applyManualDecision(co(), "approved", "verbal OK", "2026-08-05");
    expect(out.manualDecision).toEqual({ decision: "approved", decidedAt: "2026-08-05", note: "verbal OK" });
  });
  it("omits an empty note", () => {
    const out = applyManualDecision(co(), "declined", "  ", "2026-08-05");
    expect(out.manualDecision).toEqual({ decision: "declined", decidedAt: "2026-08-05" });
  });
  it("refuses to re-decide a decided or cancelled CO (returns same reference)", () => {
    const done = co({ manualDecision: { decision: "approved", decidedAt: "d" } });
    expect(applyManualDecision(done, "declined", "", "2026-08-06")).toBe(done);
    const gone = co({ cancelledAt: "d" });
    expect(applyManualDecision(gone, "approved", "", "2026-08-06")).toBe(gone);
  });
  it("cancels pending and awaiting COs; refuses on approved (returns same reference)", () => {
    expect(cancelChangeOrder(co(), "2026-08-05").cancelledAt).toBe("2026-08-05");
    const appr = co({ manualDecision: { decision: "approved", decidedAt: "d" } });
    expect(cancelChangeOrder(appr, "2026-08-05")).toBe(appr);
  });
});

describe("buildChangeOrderSnapshot", () => {
  it("freezes the CO as a one-line snapshot in the EstimateApprovalSnapshot shape", () => {
    const snap = buildChangeOrderSnapshot(co(), job(), { name: "Dana R" }, { businessName: "Rivera Plumbing" });
    expect(snap).toEqual({
      businessName: "Rivera Plumbing",
      customerName: "Dana R",
      jobTitle: "Bath remodel",
      lineItems: [{ label: "Rotted subfloor", amount: 850 }],
      total: 850,
      currency: "USD",
    });
  });
  it("falls back to job.customerName and a default business name", () => {
    const snap = buildChangeOrderSnapshot(co(), job(), { name: "" }, { businessName: "" });
    expect(snap.customerName).toBe("Dana");
    expect(snap.businessName).toBe("Your tradesperson");
  });
});

describe("newChangeOrderId", () => {
  it("mints co<ts>_<counter> ids that never collide in a burst", () => {
    const a = newChangeOrderId();
    const b = newChangeOrderId();
    expect(a).toMatch(/^co\d+_\d+$/);
    expect(a).not.toBe(b);
  });
});
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `npm test -- changeOrders.test`
Expected: FAIL — `Cannot find module '../utils/changeOrders'`

- [ ] **Step 4: Create `utils/changeOrders.ts`**

```ts
// utils/changeOrders.ts
// Change-order domain logic (2026-08-05 spec). Single source of truth for
// CO status derivation and the job's billable total. Pure — no storage.
//
// jobBillableTotal is what every DISPLAY surface shows for a job's value;
// job.estimateTotal stays the as-approved baseline (computeEstimateBreakdown's
// residual overhead math depends on it) and is never mutated here.
//
// Mirrored (CommonJS) in backend/lib/estimate/changeOrderMath.js for the
// change-view context totals — kept in sync by __tests__/changeOrderParity.test.js.

import { roundToCents } from "./invoicePayments";
import type {
  ChangeOrder,
  Customer,
  EstimateApprovalSnapshot,
  Job,
  JobStatus,
  Settings,
} from "../types/models";

export type ChangeOrderStatus = "pending" | "awaiting" | "approved" | "declined" | "cancelled";

let _coCounter = 0;
/** co<timestamp>_<counter> — counter prevents same-millisecond collisions (newCustomerId pattern). */
export function newChangeOrderId(): string {
  _coCounter += 1;
  return `co${Date.now()}_${_coCounter}`;
}

/**
 * Derived status — never stored. Link decision wins over manual in the race
 * window (server-stamped consent is the stronger record); cancelled beats all.
 */
export function changeOrderStatus(co: ChangeOrder): ChangeOrderStatus {
  if (co.cancelledAt) return "cancelled";
  const decision = co.approval?.decision ?? co.manualDecision?.decision;
  if (decision === "approved") return "approved";
  if (decision === "declined") return "declined";
  if (co.approval) return "awaiting";
  return "pending";
}

export function approvedChangeOrderTotal(job: Pick<Job, "changeOrders">): number {
  return roundToCents(
    (job.changeOrders ?? []).reduce(
      (sum, co) => (changeOrderStatus(co) === "approved" ? sum + (co.amount || 0) : sum),
      0,
    ),
  );
}

/** estimateTotal + approved COs — the number every display surface shows. */
export function jobBillableTotal(job: Pick<Job, "estimateTotal" | "changeOrders">): number {
  return roundToCents((job.estimateTotal || 0) + approvedChangeOrderTotal(job));
}

const CO_ADDABLE_STATUSES: readonly JobStatus[] = ["approved", "scheduled", "in_progress", "complete"];

/**
 * COs need an agreed baseline (post-approval) and an open bill (pre-invoiced):
 * before approval, revise the estimate instead; after invoiced, edit the
 * invoice or open a new job.
 */
export function canAddChangeOrder(status: JobStatus): boolean {
  return CO_ADDABLE_STATUSES.includes(status);
}

export type ChangeOrderInputResult =
  | { ok: true; title: string; amount: number }
  | { ok: false; message: string };

/**
 * Form validation for AddChangeOrderScreen. `editingId` excludes the CO being
 * edited from the below-$0 floor check (its old amount is being replaced).
 * NOTE: only PENDING COs are editable, and pending COs never count toward
 * approvedChangeOrderTotal — editingId exists for future-proofing the floor
 * math, not because an approved CO can be edited (it can't).
 */
export function validateChangeOrderInput(
  title: string,
  amountText: string,
  job: Job,
  editingId?: string,
): ChangeOrderInputResult {
  const trimmed = title.trim();
  if (!trimmed) return { ok: false, message: "Please give this change a short title." };
  const amount = parseFloat(amountText);
  if (!amountText.trim() || isNaN(amount) || amount === 0) {
    return { ok: false, message: "Please enter a non-zero amount (negative for a credit)." };
  }
  const others: Pick<Job, "estimateTotal" | "changeOrders"> = {
    estimateTotal: job.estimateTotal,
    changeOrders: (job.changeOrders ?? []).filter((c) => c.id !== editingId),
  };
  if (jobBillableTotal(others) + amount < 0) {
    return { ok: false, message: "This credit would take the job's total below $0." };
  }
  return { ok: true, title: trimmed, amount: roundToCents(amount) };
}

/**
 * Stamps an on-site decision. Refuses (same reference back) when the CO is
 * already decided or cancelled — callers can skip saveJobs on `out === co`.
 */
export function applyManualDecision(
  co: ChangeOrder,
  decision: "approved" | "declined",
  note: string,
  today: string,
): ChangeOrder {
  const status = changeOrderStatus(co);
  if (status !== "pending" && status !== "awaiting") return co;
  const trimmedNote = note.trim();
  return {
    ...co,
    manualDecision: { decision, decidedAt: today, ...(trimmedNote ? { note: trimmedNote } : {}) },
  };
}

/** One-way cancel. Refuses (same reference) unless pending/awaiting. */
export function cancelChangeOrder(co: ChangeOrder, today: string): ChangeOrder {
  const status = changeOrderStatus(co);
  if (status !== "pending" && status !== "awaiting") return co;
  return { ...co, cancelledAt: today };
}

/**
 * Freezes the CO for the customer page — EstimateApprovalSnapshot reused
 * verbatim so the backend and viewer handle one shape (buildEstimateSnapshot
 * pattern). Context totals (original/new) are deliberately NOT frozen here:
 * change-view computes them live so multi-CO jobs show truthful numbers.
 */
export function buildChangeOrderSnapshot(
  co: ChangeOrder,
  job: Job,
  customer: Pick<Customer, "name">,
  settings: Pick<Settings, "businessName">,
): EstimateApprovalSnapshot {
  return {
    businessName: settings.businessName || "Your tradesperson",
    customerName: customer.name || job.customerName,
    jobTitle: job.title,
    lineItems: [{ label: co.title, amount: co.amount }],
    total: co.amount,
    currency: "USD",
  };
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `npm test -- changeOrders.test`
Expected: PASS (all suites)

- [ ] **Step 6: Full gate, then commit**

Run: `npm run typecheck` (0 errors), `npm test` (all pass), `npm run lint` (0 warnings)

```bash
git checkout -b feat/change-orders
git add types/models.ts utils/changeOrders.ts __tests__/changeOrders.test.js
git commit -m "feat: ChangeOrder model + utils/changeOrders domain logic"
```

---

### Task 2: Backend CO math mirror + parity test

**Files:**
- Create: `backend/lib/estimate/changeOrderMath.js`
- Test: `__tests__/changeOrderMath.test.js`, `__tests__/changeOrderParity.test.js`

**Interfaces:**
- Consumes: nothing (pure CommonJS module).
- Produces: `changeOrderStatus(co)`, `approvedChangeOrderTotal(changeOrders)`, `billableContext(jobData, changeOrderId)` → `{ originalTotal, changeAmount, newTotal }` — used by Task 4's `changeView.js`.

- [ ] **Step 1: Write the failing tests**

`__tests__/changeOrderMath.test.js`:

```js
const { changeOrderStatus, approvedChangeOrderTotal, billableContext } = require("../backend/lib/estimate/changeOrderMath");

const co = (over = {}) => ({ id: "co1", title: "Subfloor", amount: 850, createdAt: "d", ...over });

describe("billableContext", () => {
  const jobData = {
    estimateTotal: 2400,
    changeOrders: [
      co({ id: "coA", amount: 850, manualDecision: { decision: "approved", decidedAt: "d" } }),
      co({ id: "coB", amount: 200, approval: { token: "T", sentAt: "s", snapshot: {} } }), // awaiting — this link's CO
      co({ id: "coC", amount: 999 }), // pending, excluded
    ],
  };
  it("original excludes THIS CO but includes other approved COs; newTotal adds this CO", () => {
    expect(billableContext(jobData, "coB")).toEqual({
      originalTotal: 3250,   // 2400 + 850
      changeAmount: 200,
      newTotal: 3450,
    });
  });
  it("an already-approved CO is excluded from its own original", () => {
    expect(billableContext(jobData, "coA")).toEqual({
      originalTotal: 2400,
      changeAmount: 850,
      newTotal: 3250,
    });
  });
  it("handles absent changeOrders and missing CO", () => {
    expect(billableContext({ estimateTotal: 100 }, "nope")).toBeNull();
  });
});

describe("mirror semantics", () => {
  it("cancelled beats approved; link decision wins over manual", () => {
    expect(changeOrderStatus(co({ cancelledAt: "d", manualDecision: { decision: "approved", decidedAt: "d" } }))).toBe("cancelled");
    expect(changeOrderStatus(co({
      approval: { token: "T", sentAt: "s", snapshot: {}, decision: "declined" },
      manualDecision: { decision: "approved", decidedAt: "d" },
    }))).toBe("declined");
  });
  it("sums only approved", () => {
    expect(approvedChangeOrderTotal([
      co({ manualDecision: { decision: "approved", decidedAt: "d" } }),
      co({ id: "co2", amount: 100 }),
    ])).toBe(850);
  });
});
```

`__tests__/changeOrderParity.test.js` (pins client ↔ backend — the `jobDunningParity.test.js` convention):

```js
// The backend mirrors utils/changeOrders' status + total math (backend/ is a
// separate CommonJS package). This test pins the two implementations to each
// other: same fixtures through both, outputs must be identical.
const client = require("../utils/changeOrders");
const server = require("../backend/lib/estimate/changeOrderMath");

const co = (over = {}) => ({ id: "x", title: "t", amount: 100, createdAt: "d", ...over });

const FIXTURES = [
  co(),
  co({ approval: { token: "T", sentAt: "s", snapshot: {} } }),
  co({ approval: { token: "T", sentAt: "s", snapshot: {}, decision: "approved" } }),
  co({ approval: { token: "T", sentAt: "s", snapshot: {}, decision: "declined" } }),
  co({ manualDecision: { decision: "approved", decidedAt: "d" } }),
  co({ manualDecision: { decision: "declined", decidedAt: "d" } }),
  co({ approval: { token: "T", sentAt: "s", snapshot: {}, decision: "declined" },
       manualDecision: { decision: "approved", decidedAt: "d" } }),
  co({ cancelledAt: "d", approval: { token: "T", sentAt: "s", snapshot: {}, decision: "approved" } }),
];

it("changeOrderStatus agrees on every fixture", () => {
  for (const f of FIXTURES) {
    expect(server.changeOrderStatus(f)).toBe(client.changeOrderStatus(f));
  }
});

it("approved totals agree, including negatives and cents rounding", () => {
  const list = [
    co({ amount: 850.005, manualDecision: { decision: "approved", decidedAt: "d" } }),
    co({ id: "y", amount: -100, manualDecision: { decision: "approved", decidedAt: "d" } }),
    co({ id: "z", amount: 999 }),
  ];
  expect(server.approvedChangeOrderTotal(list)).toBe(client.approvedChangeOrderTotal({ changeOrders: list }));
});
```

- [ ] **Step 2: Run to verify failure**

Run: `npm test -- changeOrder`
Expected: changeOrders.test PASSES (Task 1); changeOrderMath + changeOrderParity FAIL with module-not-found.

- [ ] **Step 3: Create `backend/lib/estimate/changeOrderMath.js`**

```js
// Mirrors utils/changeOrders.ts status + total math for change-view's context
// totals. backend/ is a separate CommonJS package, so this is a deliberate
// mirror — kept honest by __tests__/changeOrderParity.test.js. If you change
// one side, change both.

function roundToCents(n) {
  return Math.round(n * 100) / 100;
}

function changeOrderStatus(co) {
  if (co.cancelledAt) return 'cancelled';
  const decision = (co.approval && co.approval.decision) || (co.manualDecision && co.manualDecision.decision);
  if (decision === 'approved') return 'approved';
  if (decision === 'declined') return 'declined';
  if (co.approval) return 'awaiting';
  return 'pending';
}

function approvedChangeOrderTotal(changeOrders) {
  const list = Array.isArray(changeOrders) ? changeOrders : [];
  return roundToCents(list.reduce(
    (sum, co) => (changeOrderStatus(co) === 'approved' ? sum + (co.amount || 0) : sum),
    0,
  ));
}

// Context totals for the customer page: "Original" is the job's billable
// total EXCLUDING this CO (estimateTotal + other approved COs), computed
// LIVE so multi-CO jobs show truthful numbers. Returns null when the CO
// isn't on the job.
function billableContext(jobData, changeOrderId) {
  const list = Array.isArray(jobData.changeOrders) ? jobData.changeOrders : [];
  const co = list.find((c) => c && c.id === changeOrderId);
  if (!co) return null;
  const others = list.filter((c) => c && c.id !== changeOrderId);
  const originalTotal = roundToCents((jobData.estimateTotal || 0) + approvedChangeOrderTotal(others));
  return {
    originalTotal,
    changeAmount: co.amount || 0,
    newTotal: roundToCents(originalTotal + (co.amount || 0)),
  };
}

module.exports = { changeOrderStatus, approvedChangeOrderTotal, billableContext };
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test -- changeOrder`
Expected: all three suites PASS.

- [ ] **Step 5: Full gate, commit**

```bash
git add backend/lib/estimate/changeOrderMath.js __tests__/changeOrderMath.test.js __tests__/changeOrderParity.test.js
git commit -m "feat: backend change-order math mirror with client parity test"
```

---

### Task 3: `create-link` learns `changeOrderId`

**Files:**
- Modify: `backend/lib/estimate/createLink.js`
- Test: extend `__tests__/estimateCreateLink.test.js` (a new pure-function describe block)

**Interfaces:**
- Consumes: `planApprovalWrite` from `backend/lib/estimateStore.js` (unchanged).
- Produces: a new exported pure helper `planChangeOrderLink(changeOrders, changeOrderId, snapshot, sentAt, mintToken)` → `{ error: 'not-found' | 'decided' } | { changed, changeOrders, token, sentAt }`; the handler accepts optional `changeOrderId` in the POST body and returns a `change.html` URL. Task 5's client sends `{ jobId, changeOrderId, snapshot }`.

- [ ] **Step 1: Write the failing test — append to `__tests__/estimateCreateLink.test.js`**

```js
const { planChangeOrderLink } = require('../backend/lib/estimate/createLink');

describe('planChangeOrderLink', () => {
  const mint = () => 'MINTED';
  const snap = { total: 850 };
  const cos = [
    { id: 'coA', title: 'Subfloor', amount: 850, createdAt: 'd' },
    { id: 'coB', title: 'Done', amount: 100, createdAt: 'd', manualDecision: { decision: 'approved', decidedAt: 'd' } },
  ];

  it('mints into the right CO and leaves the others untouched', () => {
    const out = planChangeOrderLink(cos, 'coA', snap, 's1', mint);
    expect(out.error).toBeUndefined();
    expect(out.changed).toBe(true);
    expect(out.token).toBe('MINTED');
    expect(out.changeOrders[0].approval).toEqual({ token: 'MINTED', sentAt: 's1', snapshot: snap });
    expect(out.changeOrders[1]).toBe(cos[1]);   // untouched reference
    expect(cos[0].approval).toBeUndefined();     // input not mutated
  });

  it('errors not-found for an unknown CO', () => {
    expect(planChangeOrderLink(cos, 'nope', snap, 's1', mint)).toEqual({ error: 'not-found' });
  });

  it('errors decided for a manually-decided CO', () => {
    expect(planChangeOrderLink(cos, 'coB', snap, 's1', mint)).toEqual({ error: 'decided' });
  });

  it('freezes once link-approved (planApprovalWrite semantics carry over)', () => {
    const approved = [{ id: 'coA', title: 'X', amount: 1, createdAt: 'd',
      approval: { token: 'T', sentAt: 's0', snapshot: snap, decision: 'approved' } }];
    const out = planChangeOrderLink(approved, 'coA', { total: 999 }, 's9', mint);
    expect(out.changed).toBe(false);
    expect(out.token).toBe('T');
    expect(out.changeOrders[0].approval.snapshot).toBe(snap); // NOT the new snapshot
  });

  it('handles a non-array changeOrders as not-found', () => {
    expect(planChangeOrderLink(undefined, 'coA', snap, 's1', mint)).toEqual({ error: 'not-found' });
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `npm test -- estimateCreateLink`
Expected: existing `planApprovalWrite` block PASSES; new block FAILS (`planChangeOrderLink` is not a function).

- [ ] **Step 3: Implement in `backend/lib/estimate/createLink.js`**

Add near the top (after the `PUBLIC_BASE` constant):

```js
// change.html rides the same host as estimate.html (env-overridable the same
// way): swap the filename off the estimate base so flipping
// ESTIMATE_PUBLIC_BASE to the branded domain moves BOTH pages.
const CHANGE_PUBLIC_BASE =
  process.env.CHANGE_PUBLIC_BASE || PUBLIC_BASE.replace(/estimate\.html$/, 'change.html');

// Pure planner for minting a link on ONE change order inside the array.
// Mirrors planApprovalWrite's freeze semantics (delegates to it); refuses a
// CO that already has an on-site manual decision. Never mutates its input.
function planChangeOrderLink(changeOrders, changeOrderId, snapshot, sentAt, mintToken) {
  const list = Array.isArray(changeOrders) ? changeOrders : [];
  const idx = list.findIndex((c) => c && c.id === changeOrderId);
  if (idx === -1) return { error: 'not-found' };
  const co = list[idx];
  if (co.manualDecision) return { error: 'decided' };
  const plan = planApprovalWrite(co.approval, snapshot, sentAt, mintToken);
  const next = list.slice();
  next[idx] = { ...co, approval: plan.approval };
  return { changed: plan.changed, changeOrders: next, token: plan.token, sentAt: plan.sentAt };
}
```

Then in the handler, replace the body-destructure + approval-write section. The destructure becomes:

```js
  const { jobId, snapshot, changeOrderId } = req.body || {};
  if (!jobId || typeof jobId !== 'string') return res.status(400).json({ error: 'jobId is required' });
  if (!snapshot || typeof snapshot !== 'object') return res.status(400).json({ error: 'snapshot is required' });
  if (changeOrderId !== undefined && typeof changeOrderId !== 'string') {
    return res.status(400).json({ error: 'changeOrderId must be a string' });
  }
```

And after the existing `if (!row) { ... 422 ... }` block, branch on `changeOrderId` (the existing estimate path moves into the `else`):

```js
  const sentAt = new Date().toISOString();

  if (changeOrderId) {
    const plan = planChangeOrderLink(row.data?.changeOrders, changeOrderId, snapshot, sentAt,
      () => crypto.randomBytes(24).toString('hex'));
    if (plan.error === 'not-found') {
      return res.status(422).json({ error: 'Change order not synced yet. Open the app while online and try again.' });
    }
    if (plan.error === 'decided') {
      return res.status(409).json({ error: 'This change was already decided.' });
    }
    if (plan.changed) {
      try {
        await upsertJob(jobId, userId, { ...row.data, changeOrders: plan.changeOrders });
      } catch (err) {
        console.error('[estimate/create-link] upsert failed:', err.message);
        return res.status(500).json({ error: 'Database error' });
      }
    }
    const url = `${CHANGE_PUBLIC_BASE}?j=${encodeURIComponent(jobId)}&co=${encodeURIComponent(changeOrderId)}&t=${encodeURIComponent(plan.token)}`;
    return res.status(200).json({ url, token: plan.token, sentAt: plan.sentAt });
  }

  const existing = row.data?.approval || {};
  const plan = planApprovalWrite(existing, snapshot, sentAt, () => crypto.randomBytes(24).toString('hex'));
  // ... (existing estimate path unchanged from here: if (plan.changed) upsert; build estimate URL; return)
```

Export the helper at the bottom (the handler is the module export — attach the same way `respond.js` attaches `nextApproval`):

```js
module.exports.planChangeOrderLink = planChangeOrderLink;
```

(If `createLink.js` currently exports via `module.exports = async function handler...`, assign the function to a named `handler` const first, then `module.exports = handler; module.exports.planChangeOrderLink = planChangeOrderLink;` — the `respond.js` pattern.)

- [ ] **Step 4: Run tests**

Run: `npm test -- estimateCreateLink`
Expected: PASS (both describe blocks).

- [ ] **Step 5: Full gate, commit**

```bash
git add backend/lib/estimate/createLink.js __tests__/estimateCreateLink.test.js
git commit -m "feat: create-link mints change-order approval tokens (changeOrderId param)"
```

---

### Task 4: `change-view` + `change-respond` handlers + dispatcher routes

**Files:**
- Create: `backend/lib/estimate/changeView.js`, `backend/lib/estimate/changeRespond.js`
- Modify: `backend/api/estimate/[action].js` (ROUTES map + header comment)
- Test: `__tests__/changeView.test.js`, `__tests__/changeRespond.test.js`, extend `__tests__/estimateDispatcherPortal.test.js`

**Interfaces:**
- Consumes: `fetchJob`, `upsertJob`, `constantTimeEqual` (estimateStore); `nextApproval` from `backend/lib/estimate/respond.js`; `billableContext`, `changeOrderStatus` from Task 2; `createRateLimiter` from `backend/lib/guards`; `applyCors` from `backend/lib/estimate/cors.js`.
- Produces: `GET /api/estimate/change-view?j&co&t` → `{ ...snapshot, description, decision, consentAt, signerName, signatureRequired, context: { originalTotal, changeAmount, newTotal } }`; `POST /api/estimate/change-respond` body `{ jobId, changeOrderId, token, decision, signerName?, declineReason? }` → `{ ok, decision, consentAt }` (409 when manually decided). Task 10's change.html consumes both.

- [ ] **Step 1: Write the failing tests**

`__tests__/changeView.test.js` (mock `estimateStore`, real math — the `portalView.test.js` conventions):

```js
jest.mock('../backend/lib/estimateStore', () => ({
  fetchJob: jest.fn(),
  constantTimeEqual: (a, b) => a === b,
}));

const store = require('../backend/lib/estimateStore');
const changeView = require('../backend/lib/estimate/changeView');

function mockRes() {
  const res = { headers: {}, statusCode: 0, body: null };
  res.setHeader = (k, v) => { res.headers[k] = v; };
  res.status = (c) => { res.statusCode = c; return res; };
  res.json = (b) => { res.body = b; return res; };
  res.end = () => res;
  return res;
}
const req = (query) => ({ method: 'GET', headers: { origin: 'https://gettradereadyapp.com' }, query });

const jobData = {
  title: 'Bath remodel', estimateTotal: 2400,
  changeOrders: [
    { id: 'coA', title: 'Prior work', amount: 850, createdAt: 'd',
      manualDecision: { decision: 'approved', decidedAt: 'd' } },
    { id: 'coB', title: 'Subfloor', amount: 200, description: 'Replace rotted section', createdAt: 'd',
      approval: { token: 'TOK', sentAt: 's',
        snapshot: { businessName: 'Rivera Plumbing', customerName: 'Dana', jobTitle: 'Bath remodel',
          lineItems: [{ label: 'Subfloor', amount: 200 }], total: 200, currency: 'USD' } } },
  ],
};

beforeEach(() => {
  jest.clearAllMocks();
  store.fetchJob.mockResolvedValue({ user_id: 'u1', data: jobData });
});

describe('change-view', () => {
  it('returns snapshot + live context totals for a valid token', async () => {
    const res = mockRes();
    await changeView(req({ j: 'j1', co: 'coB', t: 'TOK' }), res);
    expect(res.statusCode).toBe(200);
    expect(res.body.businessName).toBe('Rivera Plumbing');
    expect(res.body.total).toBe(200);
    expect(res.body.description).toBe('Replace rotted section');
    expect(res.body.decision).toBeNull();
    expect(res.body.signatureRequired).toBe(true);
    expect(res.body.context).toEqual({ originalTotal: 3250, changeAmount: 200, newTotal: 3450 });
  });

  it('surfaces a manual decision as decided state', async () => {
    const decided = JSON.parse(JSON.stringify(jobData));
    decided.changeOrders[1].manualDecision = { decision: 'approved', decidedAt: 'd' };
    store.fetchJob.mockResolvedValue({ user_id: 'u1', data: decided });
    const res = mockRes();
    await changeView(req({ j: 'j1', co: 'coB', t: 'TOK' }), res);
    expect(res.body.decision).toBe('approved');
  });

  it('404s on a bad token, missing CO, or CO without approval', async () => {
    for (const q of [
      { j: 'j1', co: 'coB', t: 'WRONG' },
      { j: 'j1', co: 'nope', t: 'TOK' },
      { j: 'j1', co: 'coA', t: 'TOK' },   // coA has no approval object
    ]) {
      const res = mockRes();
      await changeView(req(q), res);
      expect(res.statusCode).toBe(404);
      expect(res.body.error).toBe('This link is invalid or has expired.');
    }
  });

  it('400s on missing params', async () => {
    const res = mockRes();
    await changeView(req({ j: 'j1', t: 'TOK' }), res);
    expect(res.statusCode).toBe(400);
  });
});
```

`__tests__/changeRespond.test.js`:

```js
jest.mock('../backend/lib/estimateStore', () => ({
  fetchJob: jest.fn(),
  upsertJob: jest.fn().mockResolvedValue(undefined),
  constantTimeEqual: (a, b) => a === b,
}));

const store = require('../backend/lib/estimateStore');
const changeRespond = require('../backend/lib/estimate/changeRespond');

function mockRes() {
  const res = { headers: {}, statusCode: 0, body: null };
  res.setHeader = (k, v) => { res.headers[k] = v; };
  res.status = (c) => { res.statusCode = c; return res; };
  res.json = (b) => { res.body = b; return res; };
  res.end = () => res;
  return res;
}
const req = (body) => ({
  method: 'POST', headers: { origin: 'https://gettradereadyapp.com', 'user-agent': 'ua' },
  socket: { remoteAddress: '9.9.9.9' }, body,
});

const freshJob = () => ({
  user_id: 'u1',
  data: {
    estimateTotal: 2400,
    changeOrders: [
      { id: 'coB', title: 'Subfloor', amount: 200, createdAt: 'd',
        approval: { token: 'TOK', sentAt: 's', snapshot: { total: 200 } } },
    ],
  },
});

beforeEach(() => {
  jest.clearAllMocks();
  store.fetchJob.mockResolvedValue(freshJob());
});

describe('change-respond', () => {
  it('records an approval into the RIGHT array element with server consent', async () => {
    const res = mockRes();
    await changeRespond(req({ jobId: 'j1', changeOrderId: 'coB', token: 'TOK', decision: 'approved', signerName: 'Dana R' }), res);
    expect(res.statusCode).toBe(200);
    expect(res.body.ok).toBe(true);
    expect(res.body.decision).toBe('approved');
    const [, , written] = store.upsertJob.mock.calls[0];
    const co = written.changeOrders[0];
    expect(co.approval.decision).toBe('approved');
    expect(co.approval.signerName).toBe('Dana R');
    expect(typeof co.approval.consentAt).toBe('string');
    expect(written.estimateTotal).toBe(2400); // rest of blob preserved
  });

  it('refuses 409 when the CO was manually decided on site', async () => {
    const decided = freshJob();
    decided.data.changeOrders[0].manualDecision = { decision: 'approved', decidedAt: 'd' };
    store.fetchJob.mockResolvedValue(decided);
    const res = mockRes();
    await changeRespond(req({ jobId: 'j1', changeOrderId: 'coB', token: 'TOK', decision: 'declined' }), res);
    expect(res.statusCode).toBe(409);
    expect(res.body.error).toBe('This change was already decided.');
    expect(store.upsertJob).not.toHaveBeenCalled();
  });

  it('does not rewrite once link-approved (terminal lock, no needless upsert)', async () => {
    const approved = freshJob();
    approved.data.changeOrders[0].approval.decision = 'approved';
    approved.data.changeOrders[0].approval.consentAt = 'c1';
    store.fetchJob.mockResolvedValue(approved);
    const res = mockRes();
    await changeRespond(req({ jobId: 'j1', changeOrderId: 'coB', token: 'TOK', decision: 'declined' }), res);
    expect(res.statusCode).toBe(200);
    expect(res.body.decision).toBe('approved');   // lock held
    expect(store.upsertJob).not.toHaveBeenCalled();
  });

  it('404s on bad token / unknown CO; 400s on bad decision or missing signer name', async () => {
    let res = mockRes();
    await changeRespond(req({ jobId: 'j1', changeOrderId: 'coB', token: 'WRONG', decision: 'approved', signerName: 'D' }), res);
    expect(res.statusCode).toBe(404);
    res = mockRes();
    await changeRespond(req({ jobId: 'j1', changeOrderId: 'nope', token: 'TOK', decision: 'approved', signerName: 'D' }), res);
    expect(res.statusCode).toBe(404);
    res = mockRes();
    await changeRespond(req({ jobId: 'j1', changeOrderId: 'coB', token: 'TOK', decision: 'maybe' }), res);
    expect(res.statusCode).toBe(400);
    res = mockRes();
    await changeRespond(req({ jobId: 'j1', changeOrderId: 'coB', token: 'TOK', decision: 'approved', signerName: '  ' }), res);
    expect(res.statusCode).toBe(400);
  });
});
```

Extend `__tests__/estimateDispatcherPortal.test.js` — add to its route assertions:

```js
  it('routes change-view and change-respond', () => {
    // follow the file's existing pattern for asserting a ROUTES entry exists
    // (same style as its portal-view assertion)
  });
```

Use the file's existing assertion style verbatim — open it first and copy the portal-view case, substituting the two new action names.

- [ ] **Step 2: Run to verify failure**

Run: `npm test -- "change(View|Respond)"`
Expected: FAIL — modules not found.

- [ ] **Step 3: Create `backend/lib/estimate/changeView.js`**

```js
// GET /api/estimate/change-view?j=<jobId>&co=<changeOrderId>&t=<token>
// Sanitized, token-gated read for the change-order viewer. Returns ONLY this
// CO's frozen snapshot + decided state + LIVE context totals (original/new).

const { fetchJob, constantTimeEqual } = require('../estimateStore');
const { billableContext } = require('./changeOrderMath');
const { createRateLimiter } = require('../guards');
const { applyCors } = require('./cors');
const allow = createRateLimiter({ limit: 30 });

module.exports = async function handler(req, res) {
  applyCors(req, res, 'GET, OPTIONS');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'GET') return res.status(405).json({ error: 'Method not allowed' });

  const ip = (req.headers['x-forwarded-for'] || req.socket?.remoteAddress || 'unknown').split(',')[0].trim();
  if (!allow(ip)) return res.status(429).json({ error: 'Too many requests.' });

  const jobId = req.query.j;
  const coId = req.query.co;
  const token = req.query.t;
  if (!jobId || !coId || !token) return res.status(400).json({ error: 'Missing link parameters.' });

  let row;
  try {
    row = await fetchJob(String(jobId));
  } catch (err) {
    console.error('[estimate/change-view] fetch failed:', err.message);
    return res.status(500).json({ error: 'Database error' });
  }
  const cos = (row && row.data && Array.isArray(row.data.changeOrders)) ? row.data.changeOrders : [];
  const co = cos.find((c) => c && c.id === String(coId));
  const a = co && co.approval;
  if (!row || !co || !a || !constantTimeEqual(a.token, String(token))) {
    return res.status(404).json({ error: 'This link is invalid or has expired.' });
  }

  // A manual on-site decision also counts as decided for the viewer.
  const decision = a.decision || (co.manualDecision && co.manualDecision.decision) || null;

  return res.status(200).json({
    ...a.snapshot,
    description: co.description || null,
    decision,
    consentAt: a.consentAt || null,
    signerName: a.signerName || null,
    signatureRequired: true,
    context: billableContext(row.data, String(coId)),
  });
};
```

- [ ] **Step 4: Create `backend/lib/estimate/changeRespond.js`**

```js
// POST /api/estimate/change-respond
// The customer's Approve/Decline for ONE change order. Token-gated; stamps
// consentAt SERVER-SIDE and merges only that CO's approval.* into the jobs
// blob (service role). Reuses respond.js's nextApproval merge (terminal lock
// on approved). Refuses 409 when the tradesperson already recorded an
// on-site manual decision — a stale link can't override it.

const { fetchJob, upsertJob, constantTimeEqual } = require('../estimateStore');
const { nextApproval } = require('./respond');
const { createRateLimiter } = require('../guards');
const { applyCors } = require('./cors');
const allow = createRateLimiter({ limit: 10 });

module.exports = async function handler(req, res) {
  applyCors(req, res, 'POST, OPTIONS');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const ip = (req.headers['x-forwarded-for'] || req.socket?.remoteAddress || 'unknown').split(',')[0].trim();
  if (!allow(ip)) return res.status(429).json({ error: 'Too many requests.' });

  const { jobId, changeOrderId, token, decision, signerName, declineReason } = req.body || {};
  if (!jobId || !changeOrderId || !token) return res.status(400).json({ error: 'Missing link parameters.' });
  if (decision !== 'approved' && decision !== 'declined') return res.status(400).json({ error: 'Invalid decision.' });
  if (decision === 'approved' && !String(signerName || '').trim()) {
    return res.status(400).json({ error: 'Please type your name to approve.' });
  }

  let row;
  try {
    row = await fetchJob(String(jobId));
  } catch (err) {
    console.error('[estimate/change-respond] fetch failed:', err.message);
    return res.status(500).json({ error: 'Database error' });
  }
  const cos = (row && row.data && Array.isArray(row.data.changeOrders)) ? row.data.changeOrders : [];
  const idx = cos.findIndex((c) => c && c.id === String(changeOrderId));
  const co = idx === -1 ? null : cos[idx];
  const existing = co && co.approval;
  if (!row || !co || !existing || !constantTimeEqual(existing.token, String(token))) {
    return res.status(404).json({ error: 'This link is invalid or has expired.' });
  }
  if (co.manualDecision) {
    return res.status(409).json({ error: 'This change was already decided.' });
  }

  const merged = nextApproval(existing, { decision, signerName, declineReason }, {
    consentAt: new Date().toISOString(),
    ip,
    userAgent: String(req.headers['user-agent'] || '').slice(0, 300),
  });

  if (merged !== existing) {
    const next = cos.slice();
    next[idx] = { ...co, approval: merged };
    try {
      await upsertJob(String(jobId), row.user_id, { ...row.data, changeOrders: next });
    } catch (err) {
      console.error('[estimate/change-respond] upsert failed:', err.message);
      return res.status(500).json({ error: 'Database error' });
    }
  }

  return res.status(200).json({ ok: true, decision: merged.decision, consentAt: merged.consentAt });
};
```

- [ ] **Step 5: Register the routes in `backend/api/estimate/[action].js`**

```js
const changeView = require('../../lib/estimate/changeView');
const changeRespond = require('../../lib/estimate/changeRespond');

const ROUTES = {
  'create-link': createLink,
  'respond': respond,
  'view': view,
  'portal-view': portalView,
  'change-view': changeView,
  'change-respond': changeRespond,
};
```

Also extend the file's header comment: add `/api/estimate/change-view and /api/estimate/change-respond (change orders, 2026-08-05)` to the URL list.

- [ ] **Step 6: Run tests, verify function count unchanged**

Run: `npm test -- "change(View|Respond)|estimateDispatcher"`
Expected: PASS.
Run: `ls backend/api backend/api/*/ | grep -c "\.js"` (Git Bash) — count must equal the pre-task count (the two new files live under `lib/`, not `api/`).

- [ ] **Step 7: Full gate, commit**

```bash
git add backend/lib/estimate/changeView.js backend/lib/estimate/changeRespond.js "backend/api/estimate/[action].js" __tests__/changeView.test.js __tests__/changeRespond.test.js __tests__/estimateDispatcherPortal.test.js
git commit -m "feat: change-view + change-respond actions on the estimate dispatcher"
```

---

### Task 5: Client mint util `utils/changeOrderLink.ts`

**Files:**
- Create: `utils/changeOrderLink.ts`
- Modify: `utils/estimateApprovalLink.ts` (export the `ApprovalLinkResult` type — it already is exported; verify, no change expected)
- Test: `__tests__/changeOrderLink.test.ts`

**Interfaces:**
- Consumes: `ApprovalLinkResult` from `utils/estimateApprovalLink.ts`; `buildChangeOrderSnapshot` from Task 1; `loadJobs`/`saveJobs` from `utils/storage`; `supabase`, `syncIfOnline`.
- Produces: `createChangeOrderLink(job: Job, co: ChangeOrder, customer: Customer, settings: Settings): Promise<ApprovalLinkResult>` — used by Task 9's section component.

- [ ] **Step 1: Write the failing test `__tests__/changeOrderLink.test.ts`**

```ts
// Mock the storage + network edges; assert the orchestration order and the
// local mirror write (the estimateApprovalLink contract, minus status stamping).
jest.mock("../utils/storage", () => ({
  loadJobs: jest.fn(),
  saveJobs: jest.fn().mockResolvedValue(undefined),
}));
jest.mock("../utils/supabase", () => ({
  supabase: { auth: { getSession: jest.fn() } },
}));
jest.mock("../utils/sync", () => ({ syncIfOnline: jest.fn().mockResolvedValue(undefined) }));
jest.mock("expo-constants", () => ({
  __esModule: true,
  default: { expoConfig: { extra: { backendUrl: "https://backend.test" } } },
}));

import { createChangeOrderLink } from "../utils/changeOrderLink";
import { loadJobs, saveJobs } from "../utils/storage";
import { supabase } from "../utils/supabase";
import type { Job, ChangeOrder } from "../types/models";

const co: ChangeOrder = { id: "coB", title: "Subfloor", amount: 200, createdAt: "d" };
const job = {
  id: "j1", customerName: "Dana", title: "Bath", estimateTotal: 2400,
  changeOrders: [co], status: "in_progress",
} as unknown as Job;
const customer = { id: "c1", name: "Dana R", email: "", phone: "", address: "", notes: "" };
const settings = { businessName: "Rivera Plumbing" } as never;

beforeEach(() => {
  jest.clearAllMocks();
  (loadJobs as jest.Mock).mockResolvedValue([job]);
  (supabase.auth.getSession as jest.Mock).mockResolvedValue({
    data: { session: { access_token: "JWT", user: { id: "u1" } } },
  });
  global.fetch = jest.fn().mockResolvedValue({
    ok: true,
    json: async () => ({ url: "https://x/change.html?j=j1&co=coB&t=TOK", token: "TOK", sentAt: "S" }),
  }) as jest.Mock;
});

it("mints via create-link with changeOrderId and mirrors approval locally", async () => {
  const out = await createChangeOrderLink(job, co, customer as never, settings);
  expect(out.ok).toBe(true);
  const call = (global.fetch as jest.Mock).mock.calls[0];
  expect(call[0]).toBe("https://backend.test/api/estimate/create-link");
  const body = JSON.parse(call[1].body);
  expect(body.jobId).toBe("j1");
  expect(body.changeOrderId).toBe("coB");
  expect(body.snapshot.total).toBe(200);
  // local mirror: the CO gained approval {token, sentAt, snapshot}
  const savedJobs = (saveJobs as jest.Mock).mock.calls.at(-1)[0];
  const savedCo = savedJobs[0].changeOrders[0];
  expect(savedCo.approval.token).toBe("TOK");
  expect(savedCo.approval.sentAt).toBe("S");
});

it("returns a server failure without writing locally", async () => {
  (global.fetch as jest.Mock).mockResolvedValue({ ok: false, json: async () => ({ error: "nope" }) });
  const out = await createChangeOrderLink(job, co, customer as never, settings);
  expect(out.ok).toBe(false);
  expect(saveJobs).not.toHaveBeenCalled();
});

it("returns signed-out when there is no session", async () => {
  (supabase.auth.getSession as jest.Mock).mockResolvedValue({ data: { session: null } });
  const out = await createChangeOrderLink(job, co, customer as never, settings);
  expect(out).toMatchObject({ ok: false, reason: "signed-out" });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `npm test -- changeOrderLink`
Expected: FAIL — module not found.

- [ ] **Step 3: Create `utils/changeOrderLink.ts`**

```ts
// utils/changeOrderLink.ts
// Mints a customer approval link for ONE change order. Sibling of
// estimateApprovalLink.ts (same result contract, same sync-before-mint
// ordering) minus the estimate-specific status stamping: sending a CO link
// never touches job.status or estimateSentAt.

import Constants from "expo-constants";
import { loadJobs, saveJobs } from "./storage";
import { supabase } from "./supabase";
import { syncIfOnline } from "./sync";
import { buildChangeOrderSnapshot } from "./changeOrders";
import type { ApprovalLinkResult } from "./estimateApprovalLink";
import type { ChangeOrder, Customer, Job, Settings } from "../types/models";

const BACKEND_URL = (Constants.expoConfig?.extra as { backendUrl?: string } | undefined)?.backendUrl;

/**
 * Server-mints an approval token into `co.approval`, mirrors the write
 * locally, and returns the customer-facing change.html URL. The job (with
 * the CO already saved on it) must reach Supabase before create-link can
 * find it — hence the explicit syncIfOnline await.
 */
export async function createChangeOrderLink(
  job: Job,
  co: ChangeOrder,
  customer: Customer,
  settings: Settings,
): Promise<ApprovalLinkResult> {
  if (!BACKEND_URL) {
    return { ok: false, reason: "no-backend", message: "Approval links need a network connection." };
  }

  try {
    const { data: sess } = await supabase.auth.getSession();
    const jwt = sess.session?.access_token;
    const userId = sess.session?.user?.id;
    if (!jwt || !userId) {
      return { ok: false, reason: "signed-out", message: "Please sign in to send an approval link." };
    }

    const snapshot = buildChangeOrderSnapshot(co, job, customer, settings);
    await syncIfOnline(userId);

    const res = await fetch(`${BACKEND_URL}/api/estimate/create-link`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${jwt}` },
      body: JSON.stringify({ jobId: job.id, changeOrderId: co.id, snapshot }),
    });
    const out = await res.json();
    if (!res.ok) {
      return { ok: false, reason: "server", message: out.error || "Please try again." };
    }

    // Mirror the server write locally so the section reflects "awaiting"
    // immediately (approval presence is what flips the derived status).
    const linked = (await loadJobs()).map((j): Job =>
      j.id === job.id
        ? {
            ...j,
            changeOrders: (j.changeOrders ?? []).map((c) =>
              c.id === co.id ? { ...c, approval: { token: out.token, sentAt: out.sentAt, snapshot } } : c,
            ),
          }
        : j,
    );
    await saveJobs(linked);

    return { ok: true, url: out.url as string, token: out.token as string, sentAt: out.sentAt as string };
  } catch {
    return { ok: false, reason: "network", message: "Please check your connection and try again." };
  }
}
```

- [ ] **Step 4: Run tests**

Run: `npm test -- changeOrderLink`
Expected: PASS.

- [ ] **Step 5: Full gate, commit**

```bash
git add utils/changeOrderLink.ts __tests__/changeOrderLink.test.ts
git commit -m "feat: client change-order link minting (utils/changeOrderLink)"
```

---

### Task 6: Invoice math — CO-inclusive billing

**Files:**
- Modify: `utils/autoInvoice.ts` (`computeBillableBreakdown`, `buildInvoiceLineItems`)
- Modify: `screens/CreateInvoiceFromJobScreen.tsx` (finalize prefill + banner)
- Test: extend the existing autoInvoice test suite (find it with `ls __tests__ | grep -i autoInvoice`); extend `__tests__/pdfTemplates.test.js` with a CO-line case (NEW test case — do NOT touch existing golden fixtures)

**Interfaces:**
- Consumes: `approvedChangeOrderTotal`, `changeOrderStatus` from Task 1.
- Produces: `BillableBreakdown` gains `changeOrderTotal: number`; `computeBillableBreakdown().total` and `buildInvoiceLineItems()` become CO-inclusive — which makes ALL THREE invoice paths (manual create/requestDeposit via `prefillInvoiceDraftFromJob`, finalize line items, auto-invoice) pick up approved COs with no further changes.

- [ ] **Step 1: Write the failing tests (append to the autoInvoice suite)**

```js
const approvedCo = (id, amount) => ({
  id, title: `CO ${id}`, amount, createdAt: "d",
  manualDecision: { decision: "approved", decidedAt: "d" },
});

describe("change orders in billing", () => {
  it("computeBillableBreakdown adds approved COs to the total (and reports them)", () => {
    const job = baseJob({ estimateTotal: 2400, changeOrders: [approvedCo("coA", 850), { id: "coP", title: "p", amount: 999, createdAt: "d" }] });
    const b = computeBillableBreakdown(job);
    expect(b.changeOrderTotal).toBe(850);
    expect(b.total).toBe(3250);
  });

  it("buildInvoiceLineItems appends one line per approved CO and lines sum to total", () => {
    const job = baseJob({ estimateTotal: 2400, changeOrders: [approvedCo("coA", 850), approvedCo("coB", -100)] });
    const items = buildInvoiceLineItems(job);
    const coLines = items.filter((i) => i.category === "other");
    expect(coLines).toEqual([
      { description: "Change order — CO coA", amount: 850, category: "other" },
      { description: "Change order — CO coB", amount: -100, category: "other" },
    ]);
    const sum = items.reduce((s, i) => s + i.amount, 0);
    expect(sum).toBeCloseTo(computeBillableBreakdown(job).total, 2);
  });

  it("legacy job without changeOrders is byte-identical to before", () => {
    const job = baseJob({ estimateTotal: 2400 });
    expect(computeBillableBreakdown(job).changeOrderTotal).toBe(0);
    expect(computeBillableBreakdown(job).total).toBe(2400);
    expect(buildInvoiceLineItems(job).some((i) => i.category === "other")).toBe(false);
  });
});
```

Adapt `baseJob(...)` to whatever job-fixture helper the existing suite uses (read the suite first; if it builds jobs inline, build them inline the same way). The three behavioral assertions must stay exactly as written.

- [ ] **Step 2: Run to verify failure**

Run: `npm test -- autoInvoice`
Expected: new cases FAIL (`changeOrderTotal` undefined; no CO lines); existing cases PASS.

- [ ] **Step 3: Implement in `utils/autoInvoice.ts`**

Import at top: `import { approvedChangeOrderTotal, changeOrderStatus } from "./changeOrders";`

In `BillableBreakdown`, add after `usedTrackedTime`:

```ts
  /** Σ approved change-order amounts included in `total` (0 when none). */
  changeOrderTotal: number;
```

In `computeBillableBreakdown`, compute once before the branch:

```ts
  const changeOrderTotal = approvedChangeOrderTotal(job);
```

and change both return branches: the no-tracked-time branch's fields gain `changeOrderTotal` and its total becomes

```ts
      total: roundToCents(base.estimateTotal + changeOrderTotal),
```

the tracked-time branch likewise gains `changeOrderTotal` and its total becomes

```ts
    total: roundToCents(base.estimateTotal + laborCost - base.laborCost + changeOrderTotal),
```

In `buildInvoiceLineItems`, before the `return items;`:

```ts
  for (const co of job.changeOrders ?? []) {
    if (changeOrderStatus(co) !== "approved") continue;
    items.push({ description: `Change order — ${co.title}`, amount: co.amount, category: "other" });
  }
```

Also update the file's header comment: add one line — "Approved change orders are included in the total and appended as `other`-category lines (2026-08-05 spec), so all three invoice paths pick them up from this single home."

- [ ] **Step 4: Finalize prefill in `screens/CreateInvoiceFromJobScreen.tsx`**

Import: `import { approvedChangeOrderTotal } from "../utils/changeOrders";` and add `computeBillableBreakdown` to the existing `../utils/autoInvoice` import.

Add state next to `billedFromTracked`:

```ts
  // Non-zero when finalize re-derived the amount because approved change
  // orders exist — switches on the explanatory banner.
  const [finalizeCoTotal, setFinalizeCoTotal] = useState<number>(0);
```

In the `screenMode === "finalize"` branch, replace `setAmount(String(existing.amount));` with:

```ts
          // The deposit invoice's amount was fixed at request time. When
          // approved change orders exist, re-derive the amount fresh (the
          // same recomputation the line items below already do) — otherwise
          // keep the existing amount so a manual adjustment survives.
          const coTotal = approvedChangeOrderTotal(j);
          if (coTotal !== 0) {
            setAmount(String(computeBillableBreakdown(j).total));
            setFinalizeCoTotal(coTotal);
          } else {
            setAmount(String(existing.amount));
          }
```

In the JSX near the existing tracked-time banner (the block gated on `mode !== "finalize"` around line 292), add a sibling banner for finalize:

```tsx
          {mode === "finalize" && finalizeCoTotal !== 0 && (
            <View style={styles.trackedBanner}>
              <Text style={styles.trackedBannerText}>
                Amount updated to include approved change orders ({finalizeCoTotal > 0 ? "+" : ""}{formatQuote(finalizeCoTotal)}). Review and adjust if needed.
              </Text>
            </View>
          )}
```

Reuse the EXACT style names the tracked-time banner uses (read the file; if they differ from `trackedBanner`/`trackedBannerText`, use the real names).

- [ ] **Step 5: Add the invoice-PDF CO case (append to `__tests__/pdfTemplates.test.js`)**

```js
it("renders change-order line items on the invoice", () => {
  // Build the same minimal invoice fixture style the suite already uses,
  // with lineItems including a CO line:
  const html = buildInvoiceHtml(
    invoiceFixture({
      lineItems: [
        { description: "Labor — 4 hrs @ $85/hr", amount: 340, category: "labor" },
        { description: "Change order — Rotted subfloor", amount: 850, category: "other" },
      ],
    }),
    settingsFixture(),
  );
  expect(html).toContain("Change order — Rotted subfloor");
});
```

Adapt fixture/helper names to the suite's real ones (read it first); the assertion (`toContain` on the CO description) must remain. Do NOT regenerate or edit any existing golden string.

- [ ] **Step 6: Run tests**

Run: `npm test -- "autoInvoice|pdfTemplates"`
Expected: PASS.

- [ ] **Step 7: Full gate, commit**

```bash
git add utils/autoInvoice.ts screens/CreateInvoiceFromJobScreen.tsx __tests__ 
git commit -m "feat: approved change orders flow into invoice totals + line items"
```

---

### Task 7: Display sweep — job value surfaces read `jobBillableTotal`

**Files:**
- Modify: `screens/JobsScreen.tsx:108,129-130`, `screens/CustomerDetailScreen.tsx:151-152`, `components/money/ReceivablesCard.tsx:32-33`, `utils/businessSnapshot.ts:105-106`, `utils/avgJobValue.ts:22-24`, `utils/revenueForecast.ts:27-33`, `utils/revenueByType.ts:27`, `utils/storage/dailyOps.ts:38`, `utils/todayInsights.ts:96`
- Test: one new case in `__tests__/businessSnapshot.test.js`; one new case in the todayInsights suite; a `duplicateJob` assertion in `__tests__/changeOrders.test.js`

**Interfaces:**
- Consumes: `jobBillableTotal` from Task 1.
- Produces: nothing new — display behavior only.

- [ ] **Step 1: Write the failing tests**

Append to `__tests__/businessSnapshot.test.js` (adapt fixtures to the suite's style):

```js
it("completed-job average uses billable total (estimate + approved COs)", () => {
  // one complete job: estimateTotal 2400 + approved CO 850 → avg 3250
  // build via the suite's existing job fixture helper, adding:
  //   changeOrders: [{ id: "coA", title: "X", amount: 850, createdAt: "d",
  //     manualDecision: { decision: "approved", decidedAt: "d" } }]
  // assert the snapshot's avg completed-job figure equals 3250, not 2400.
});
```

Fill the body concretely against the suite's real fixture helpers — the behavioral assertion (3250, not 2400) is the requirement.

Append to `__tests__/changeOrders.test.js`:

```js
describe("duplicateJob does not copy change orders", () => {
  const { duplicateJob } = require("../utils/duplicateJob");
  it("a duplicated job starts with no changeOrders", () => {
    const src = job({ changeOrders: [co({ manualDecision: { decision: "approved", decidedAt: "d" } })] });
    const dup = duplicateJob(src);
    expect(dup.changeOrders).toBeUndefined();
  });
});
```

(Read `utils/duplicateJob.ts` for the real export name/signature and adapt the call — the assertion stands: the duplicate carries NO changeOrders. If `duplicateJob` already constructs explicitly and the test passes immediately, keep it as a pin.)

- [ ] **Step 2: Apply the sweep**

In each file, import `jobBillableTotal` from `utils/changeOrders` (adjust relative path: `../utils/changeOrders` from screens/components, `./changeOrders` from utils, `../changeOrders` from utils/storage) and replace the VALUE read — formatter and gating stay:

- `screens/JobsScreen.tsx:108`: `s + (j.estimateTotal || 0)` → `s + jobBillableTotal(j)`
- `screens/JobsScreen.tsx:129-130`: gate `job.estimateTotal > 0` → `jobBillableTotal(job) > 0`; display `formatQuote(job.estimateTotal)` → `formatQuote(jobBillableTotal(job))`
- `screens/CustomerDetailScreen.tsx:151-152`: same swap (keeps `formatMoney` — that surface's chosen formatter)
- `components/money/ReceivablesCard.tsx:32-33`: filter `j.estimateTotal > 0` → `jobBillableTotal(j) > 0`; sum `s + j.estimateTotal` → `s + jobBillableTotal(j)`
- `utils/businessSnapshot.ts:105-106`: `job.estimateTotal > 0` → `jobBillableTotal(job) > 0`; `+= job.estimateTotal` → `+= jobBillableTotal(job)`
- `utils/avgJobValue.ts:22-24`: same pattern
- `utils/revenueForecast.ts:27-33`: `job.estimateTotal <= 0` continue-gate → `jobBillableTotal(job) <= 0`; both `+= job.estimateTotal` accumulations → `+= jobBillableTotal(job)`
- `utils/revenueByType.ts:27` and its accumulation → same pattern
- `utils/storage/dailyOps.ts:38`: `Number(job.estimateTotal) || 0` → `jobBillableTotal(job)`
- `utils/todayInsights.ts:96`: `job.estimateTotal > 0 ? \`${formatQuote(job.estimateTotal)} to bill\`` → `jobBillableTotal(job) > 0 ? \`${formatQuote(jobBillableTotal(job))} to bill\``

Deliberately NOT swept (pre-approval surfaces where COs cannot exist, or baseline math): `SendEstimateScreen`, `EstimateFollowUpScreen`, `utils/estimateFollowUps.ts`, `utils/invoiceHelpers.ts` estimate messages, `utils/pdfTemplates.ts` estimate PDF, `utils/estimateSnapshot.ts`, `utils/pricingEngine.ts`, `utils/todayInsights.ts:81` (estimate-rate insight), `canSendEstimate`, PricingCalculator/Pricebook writes, `shouldAutoInvoice`'s `estimateTotal > 0` gate (a zero-estimate job stays manual). Leave every one of these alone.

- [ ] **Step 3: Run the full suite**

Run: `npm test`
Expected: all PASS (including the new cases; if any existing suite pinned the old display values with CO-less fixtures, they still pass — absent COs is identity).

- [ ] **Step 4: Full gate, commit**

```bash
git add screens/JobsScreen.tsx screens/CustomerDetailScreen.tsx components/money/ReceivablesCard.tsx utils/businessSnapshot.ts utils/avgJobValue.ts utils/revenueForecast.ts utils/revenueByType.ts utils/storage/dailyOps.ts utils/todayInsights.ts __tests__
git commit -m "feat: job-value display surfaces read jobBillableTotal (estimate + approved COs)"
```

---

### Task 8: `AddChangeOrderScreen` modal + navigation registration

**Files:**
- Modify: `types/navigation.ts` (JobStackParamList), `App.tsx` (JobStack registration)
- Create: `screens/AddChangeOrderScreen.tsx`
- Test: covered by Task 1's `validateChangeOrderInput` unit tests (the screen is a thin shell); typecheck is the gate here

**Interfaces:**
- Consumes: `validateChangeOrderInput`, `newChangeOrderId`, `canAddChangeOrder`, `changeOrderStatus` from Task 1; `Field` component; `loadJobs`/`saveJobs`; `track` from `utils/analytics`.
- Produces: route `AddChangeOrder: { jobId: string; changeOrderId?: string }` in `JobStackParamList` — Task 9 navigates to it.

- [ ] **Step 1: Add the route type in `types/navigation.ts`**

In `JobStackParamList` (the block containing `PricingCalculator: { jobId: string };` at line 42), add:

```ts
  AddChangeOrder: { jobId: string; changeOrderId?: string };
```

- [ ] **Step 2: Create `screens/AddChangeOrderScreen.tsx`**

```tsx
// screens/AddChangeOrderScreen.tsx
// Modal form for creating (or editing a still-PENDING) change order on a job.
// Fast on-site entry: title + description + amount. Negative amount = descope
// credit. Validation lives in utils/changeOrders.validateChangeOrderInput.

import React, { useEffect, useMemo, useState } from "react";
import { Alert, KeyboardAvoidingView, Platform, ScrollView, StyleSheet, Text, View } from "react-native";
import type { NativeStackScreenProps } from "@react-navigation/native-stack";
import Field from "../components/Field";
import { Button } from "../components/UI";
import { useTheme } from "../hooks/useTheme";
import { spacing } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { loadJobs, saveJobs } from "../utils/storage";
import {
  canAddChangeOrder,
  changeOrderStatus,
  newChangeOrderId,
  validateChangeOrderInput,
} from "../utils/changeOrders";
import { track } from "../utils/analytics";
import type { Job, ChangeOrder } from "../types/models";
import type { JobStackParamList } from "../types/navigation";

type Props = NativeStackScreenProps<JobStackParamList, "AddChangeOrder">;

export default function AddChangeOrderScreen({ route, navigation }: Props) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const { jobId, changeOrderId } = route.params;

  const [job, setJob] = useState<Job | null>(null);
  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [amount, setAmount] = useState("");
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    (async () => {
      const jobs = await loadJobs();
      const j = jobs.find((x) => x.id === jobId);
      if (!j || (!changeOrderId && !canAddChangeOrder(j.status))) {
        Alert.alert("Error", "Change orders can be added once a job is approved and before it's invoiced.");
        navigation.goBack();
        return;
      }
      setJob(j);
      if (changeOrderId) {
        const co = (j.changeOrders ?? []).find((c) => c.id === changeOrderId);
        if (!co || changeOrderStatus(co) !== "pending") {
          Alert.alert("Error", "Only a change order that hasn't been sent or decided can be edited.");
          navigation.goBack();
          return;
        }
        navigation.setOptions({ title: "Edit Change Order" });
        setTitle(co.title);
        setDescription(co.description ?? "");
        setAmount(String(co.amount));
      }
    })();
  }, [jobId, changeOrderId, navigation]);

  async function handleSave() {
    if (!job) return;
    const result = validateChangeOrderInput(title, amount, job, changeOrderId);
    if (!result.ok) {
      Alert.alert("Check the form", result.message);
      return;
    }
    setSaving(true);
    try {
      const jobs = await loadJobs();
      const today = new Date().toISOString().split("T")[0];
      const updated = jobs.map((j): Job => {
        if (j.id !== jobId) return j;
        const existing = j.changeOrders ?? [];
        if (changeOrderId) {
          return {
            ...j,
            changeOrders: existing.map((c) =>
              c.id === changeOrderId && changeOrderStatus(c) === "pending"
                ? { ...c, title: result.title, description: description.trim() || undefined, amount: result.amount }
                : c,
            ),
          };
        }
        const co: ChangeOrder = {
          id: newChangeOrderId(),
          title: result.title,
          ...(description.trim() ? { description: description.trim() } : {}),
          amount: result.amount,
          createdAt: today,
        };
        return { ...j, changeOrders: [...existing, co] };
      });
      await saveJobs(updated);
      if (!changeOrderId) track("change_order_created", { amount: result.amount });
      navigation.goBack();
    } catch (err) {
      console.error("AddChangeOrderScreen: save failed", err);
      Alert.alert("Error", "Could not save this change order. Please try again.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <KeyboardAvoidingView style={styles.flex} behavior={Platform.OS === "ios" ? "padding" : undefined}>
      <ScrollView style={styles.container} keyboardShouldPersistTaps="handled">
        <Field label="What changed?" value={title} onChangeText={setTitle} placeholder="e.g. Replace rotted subfloor section" />
        <Field label="Details (optional)" value={description} onChangeText={setDescription} placeholder="What you found and what it takes to fix" multiline />
        <Field label="Amount ($)" value={amount} onChangeText={setAmount} placeholder="850 (negative for a credit)" keyboardType="numbers-and-punctuation" />
        <Text style={styles.hint}>
          Use a negative amount for a descope credit. The customer approves this change before the extra work starts.
        </Text>
        <View style={styles.buttonRow}>
          <Button title={saving ? "Saving…" : changeOrderId ? "Save changes" : "Add change order"} onPress={handleSave} disabled={saving} />
        </View>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    flex: { flex: 1 },
    container: { flex: 1, backgroundColor: colors.background, padding: spacing.lg },
    hint: { color: colors.textMuted, marginTop: spacing.sm, marginBottom: spacing.lg },
    buttonRow: { marginTop: spacing.md, marginBottom: spacing.xl },
  });
}
```

Check `Field`'s real prop names (`multiline`, `keyboardType` pass-through) and `Button`'s `disabled` prop against `components/Field.tsx` / `components/UI.tsx` before finishing; adjust to the components' actual APIs (e.g. if Field exposes `inputProps`, route `multiline`/`keyboardType` through it). Check `ColorScheme` for the muted-text token's real name (`textMuted` vs `textSecondary`) and use the real one.

- [ ] **Step 3: Register in `App.tsx` JobStack**

Find the JobStack's `AddJob` modal registration and add a sibling below it, matching its options style:

```tsx
        <JobStack.Screen
          name="AddChangeOrder"
          component={AddChangeOrderScreen}
          options={{ presentation: "modal", title: "Add Change Order" }}
        />
```

with the import `import AddChangeOrderScreen from "./screens/AddChangeOrderScreen";` alongside the other screen imports.

- [ ] **Step 4: Full gate, commit**

Run: `npm run typecheck`, `npm test`, `npm run lint`
Expected: all green (typecheck exercises the new screen + route).

```bash
git add types/navigation.ts App.tsx screens/AddChangeOrderScreen.tsx
git commit -m "feat: AddChangeOrder modal screen in JobStack"
```

---

### Task 9: `ChangeOrdersSection` in JobDetail + billable header

**Files:**
- Create: `components/ChangeOrdersSection.tsx`
- Modify: `screens/JobDetailScreen.tsx` (render section; billable arithmetic rows in the estimate card)
- Test: `__tests__/changeOrdersSection.test.tsx` (RNTL)

**Interfaces:**
- Consumes: everything from Tasks 1 + 5 (`changeOrderStatus`, `canAddChangeOrder`, `applyManualDecision`, `cancelChangeOrder`, `approvedChangeOrderTotal`, `jobBillableTotal`, `createChangeOrderLink`); `Badge`, `SectionHeader`, `Card`, `Button` from `components/UI`; `composeEmail`/`composeSMS` from `utils/messaging`; `resolveCustomer`, `loadJobs`, `saveJobs`, `loadCustomers`, `loadSettings` from `utils/storage`; `track`.
- Produces: `<ChangeOrdersSection job={job} onChanged={() => reload()} onAdd={() => nav} onEdit={(id) => nav} />` — self-contained actions; JobDetail only re-reads.

- [ ] **Step 1: Write the failing RNTL test `__tests__/changeOrdersSection.test.tsx`**

```tsx
import React from "react";
import { render } from "@testing-library/react-native";
import { ThemeProvider } from "../context/ThemeContext";
import ChangeOrdersSection from "../components/ChangeOrdersSection";
import type { Job } from "../types/models";

const job = {
  id: "j1", customerId: "c1", customerName: "Dana", title: "Bath", description: "",
  status: "in_progress", scheduledDate: null, scheduledStartTime: null,
  scheduledEndTime: null, address: "", estimateTotal: 2400, laborHours: 0,
  laborRate: 0, materials: [], materialMarkup: 0, overhead: 0, margin: 0,
  notes: "", invoiceId: null, createdAt: "2026-08-01",
  changeOrders: [
    { id: "coA", title: "Rotted subfloor", amount: 850, createdAt: "d",
      manualDecision: { decision: "approved", decidedAt: "d" } },
    { id: "coB", title: "Extra outlet", amount: 200, createdAt: "d",
      approval: { token: "T", sentAt: "s", snapshot: {} as never } },
    { id: "coC", title: "Descope tile", amount: -100, createdAt: "d" },
  ],
} as unknown as Job;

function renderSection(j: Job) {
  return render(
    <ThemeProvider>
      <ChangeOrdersSection job={j} onChanged={jest.fn()} onAdd={jest.fn()} onEdit={jest.fn()} />
    </ThemeProvider>,
  );
}

it("renders one row per CO with derived status labels", async () => {
  const { findByText, getByText } = renderSection(job);
  await findByText("Rotted subfloor");
  getByText("Approved");
  getByText("Awaiting");
  getByText("Pending");
  getByText("$850");
  getByText("-$100");
});

it("shows the add button only when the job status allows it", async () => {
  const { findByText, queryByText, rerender } = renderSection(job);
  await findByText("Add change order");
  rerender(
    <ThemeProvider>
      <ChangeOrdersSection job={{ ...job, status: "paid" } as Job} onChanged={jest.fn()} onAdd={jest.fn()} onEdit={jest.fn()} />
    </ThemeProvider>,
  );
  expect(queryByText("Add change order")).toBeNull();
});

it("renders nothing at all for a legacy job with no COs at a pre-approval status", () => {
  const bare = { ...job, changeOrders: undefined, status: "lead" } as Job;
  const { toJSON } = renderSection(bare);
  expect(toJSON()).toBeNull();
});
```

Follow the repo's RNTL async conventions (`jest.setup.js` mocks are already in place; see `bookingLinkSettings.test.tsx` for the provider-wrapping pattern — if it wraps differently, e.g. without ThemeProvider or with a custom helper, copy that file's wrapper instead).

- [ ] **Step 2: Run to verify failure**

Run: `npm test -- changeOrdersSection`
Expected: FAIL — component doesn't exist.

- [ ] **Step 3: Create `components/ChangeOrdersSection.tsx`**

```tsx
// components/ChangeOrdersSection.tsx
// JobDetail's change-orders block: rows with derived-status badges, add/edit
// entry points, and the three decision actions (send link / mark decided /
// cancel). Owns its own storage writes; the parent just re-reads onChanged.
// Decision notes use an in-component Modal (Alert.prompt is iOS-only).

import React, { useMemo, useState } from "react";
import { Alert, Modal, StyleSheet, Text, TouchableOpacity, View } from "react-native";
import Field from "./Field";
import { Badge, Button, Card, SectionHeader } from "./UI";
import { useTheme } from "../hooks/useTheme";
import { spacing, fontSize } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { formatQuote } from "../utils/format";
import {
  applyManualDecision,
  cancelChangeOrder,
  canAddChangeOrder,
  changeOrderStatus,
  type ChangeOrderStatus,
} from "../utils/changeOrders";
import { createChangeOrderLink } from "../utils/changeOrderLink";
import { composeEmail, composeSMS } from "../utils/messaging";
import { loadCustomers, loadJobs, loadSettings, saveJobs, resolveCustomer } from "../utils/storage";
import { track } from "../utils/analytics";
import type { ChangeOrder, Job } from "../types/models";

const STATUS_LABEL: Record<ChangeOrderStatus, string> = {
  pending: "Pending",
  awaiting: "Awaiting",
  approved: "Approved",
  declined: "Declined",
  cancelled: "Cancelled",
};
const STATUS_BADGE: Record<ChangeOrderStatus, "muted" | "accent" | "success" | "warning" | "danger"> = {
  pending: "muted",
  awaiting: "accent",
  approved: "success",
  declined: "danger",
  cancelled: "muted",
};

interface Props {
  job: Job;
  onChanged: () => void;
  onAdd: () => void;
  onEdit: (changeOrderId: string) => void;
}

export default function ChangeOrdersSection({ job, onChanged, onAdd, onEdit }: Props) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const [busy, setBusy] = useState(false);
  // The decision modal's target: which CO + which decision is being recorded.
  const [decisionTarget, setDecisionTarget] = useState<{ id: string; decision: "approved" | "declined" } | null>(null);
  const [decisionNote, setDecisionNote] = useState("");

  const cos = job.changeOrders ?? [];
  const canAdd = canAddChangeOrder(job.status);
  if (cos.length === 0 && !canAdd) return null;

  async function mutateCo(id: string, fn: (co: ChangeOrder) => ChangeOrder): Promise<boolean> {
    const jobs = await loadJobs();
    let changed = false;
    const updated = jobs.map((j): Job => {
      if (j.id !== job.id) return j;
      return {
        ...j,
        changeOrders: (j.changeOrders ?? []).map((c) => {
          if (c.id !== id) return c;
          const next = fn(c);
          if (next !== c) changed = true;
          return next;
        }),
      };
    });
    if (changed) await saveJobs(updated);
    return changed;
  }

  async function handleSend(co: ChangeOrder) {
    setBusy(true);
    try {
      const [customers, settings, jobs] = await Promise.all([loadCustomers(), loadSettings(), loadJobs()]);
      const fresh = jobs.find((j) => j.id === job.id) ?? job;
      const customer = resolveCustomer(customers, { customerId: job.customerId, customerName: job.customerName });
      const result = await createChangeOrderLink(fresh, co, customer ?? ({ id: "", name: job.customerName, email: "", phone: "", address: "", notes: "" } as never), settings);
      if (!result.ok) {
        Alert.alert("Couldn't create the link", result.message);
        return;
      }
      const body =
        `Hi ${customer?.name || job.customerName}, while working on "${job.title}" we found something that changes the scope: ` +
        `${co.title} (${co.amount >= 0 ? "+" : ""}${formatQuote(co.amount)}). ` +
        `Please review and approve before we do this extra work: ${result.url}`;
      const email = customer?.email || "";
      const phone = customer?.phone || "";
      const sent = phone
        ? await composeSMS(phone, body)
        : await composeEmail(email, `Change to your ${job.title} job`, body);
      if (sent) track("change_order_sent", { amount: co.amount });
      onChanged();
    } finally {
      setBusy(false);
    }
  }

  async function confirmDecision() {
    if (!decisionTarget) return;
    const today = new Date().toISOString().split("T")[0];
    const changed = await mutateCo(decisionTarget.id, (c) =>
      applyManualDecision(c, decisionTarget.decision, decisionNote, today),
    );
    if (changed) track("change_order_decided", { decision: decisionTarget.decision, channel: "manual" });
    setDecisionTarget(null);
    setDecisionNote("");
    onChanged();
  }

  function handleCancel(co: ChangeOrder) {
    Alert.alert("Cancel this change order?", "It stays in the list as cancelled and won't be billed.", [
      { text: "Keep it", style: "cancel" },
      {
        text: "Cancel change order",
        style: "destructive",
        onPress: async () => {
          const today = new Date().toISOString().split("T")[0];
          await mutateCo(co.id, (c) => cancelChangeOrder(c, today));
          onChanged();
        },
      },
    ]);
  }

  function handleDelete(co: ChangeOrder) {
    Alert.alert("Delete this change order?", "It was never sent, so no record is needed.", [
      { text: "Keep it", style: "cancel" },
      {
        text: "Delete",
        style: "destructive",
        onPress: async () => {
          const jobs = await loadJobs();
          const updated = jobs.map((j): Job =>
            j.id === job.id
              ? { ...j, changeOrders: (j.changeOrders ?? []).filter((c) => !(c.id === co.id && changeOrderStatus(c) === "pending")) }
              : j,
          );
          await saveJobs(updated);
          onChanged();
        },
      },
    ]);
  }

  function rowActions(co: ChangeOrder) {
    const status = changeOrderStatus(co);
    const actions: { text: string; onPress: () => void; style?: "destructive" | "cancel" }[] = [];
    if (status === "pending" || status === "awaiting") {
      actions.push({ text: status === "pending" ? "Send for approval" : "Re-send link", onPress: () => handleSend(co) });
      actions.push({ text: "Mark approved (on site)", onPress: () => setDecisionTarget({ id: co.id, decision: "approved" }) });
      actions.push({ text: "Mark declined", onPress: () => setDecisionTarget({ id: co.id, decision: "declined" }) });
      actions.push({ text: "Cancel change order", style: "destructive", onPress: () => handleCancel(co) });
    }
    if (status === "pending") {
      actions.push({ text: "Edit", onPress: () => onEdit(co.id) });
      actions.push({ text: "Delete", style: "destructive", onPress: () => handleDelete(co) });
    }
    if (actions.length === 0) return; // approved/declined/cancelled: history row, no actions
    Alert.alert(co.title, formatQuote(co.amount), [...actions, { text: "Close", style: "cancel" }]);
  }

  return (
    <Card style={styles.card}>
      <SectionHeader title="Change orders" />
      {cos.map((co) => {
        const status = changeOrderStatus(co);
        return (
          <TouchableOpacity key={co.id} style={styles.row} onPress={() => rowActions(co)} disabled={busy}>
            <View style={styles.rowText}>
              <Text style={styles.rowTitle} numberOfLines={1}>{co.title}</Text>
              {co.manualDecision?.note ? (
                <Text style={styles.rowNote} numberOfLines={1}>{co.manualDecision.note}</Text>
              ) : null}
            </View>
            <Text style={styles.rowAmount}>{formatQuote(co.amount)}</Text>
            <Badge label={STATUS_LABEL[status]} color={STATUS_BADGE[status]} />
          </TouchableOpacity>
        );
      })}
      {canAdd && (
        <View style={styles.addRow}>
          <Button title="Add change order" onPress={onAdd} />
        </View>
      )}

      <Modal visible={decisionTarget !== null} transparent animationType="fade" onRequestClose={() => setDecisionTarget(null)}>
        <View style={styles.modalBackdrop}>
          <View style={styles.modalCard}>
            <Text style={styles.modalTitle}>
              {decisionTarget?.decision === "approved" ? "Mark approved" : "Mark declined"}
            </Text>
            <Text style={styles.modalHint}>Record how the customer decided — e.g. "verbal OK on site".</Text>
            <Field label="Note (optional)" value={decisionNote} onChangeText={setDecisionNote} placeholder="verbal OK on site" />
            <View style={styles.modalButtons}>
              <Button title="Cancel" variant="secondary" onPress={() => { setDecisionTarget(null); setDecisionNote(""); }} />
              <Button title="Confirm" onPress={confirmDecision} />
            </View>
          </View>
        </View>
      </Modal>
    </Card>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    card: { marginTop: spacing.lg },
    row: { flexDirection: "row", alignItems: "center", paddingVertical: spacing.sm, gap: spacing.sm },
    rowText: { flex: 1 },
    rowTitle: { color: colors.textPrimary },
    rowNote: { color: colors.textMuted, fontSize: fontSize.sm },
    rowAmount: { color: colors.textPrimary, fontVariant: ["tabular-nums"] },
    addRow: { marginTop: spacing.sm },
    modalBackdrop: { flex: 1, backgroundColor: "rgba(0,0,0,0.5)", justifyContent: "center", padding: spacing.lg },
    modalCard: { backgroundColor: colors.background, borderRadius: 12, padding: spacing.lg },
    modalTitle: { fontSize: fontSize.lg, color: colors.textPrimary, marginBottom: spacing.xs },
    modalHint: { color: colors.textMuted, marginBottom: spacing.md },
    modalButtons: { flexDirection: "row", justifyContent: "flex-end", gap: spacing.sm, marginTop: spacing.md },
  });
}
```

Verify against the real component APIs before finishing: `Badge`'s props (`label`/`color` vs children), `Button`'s `variant` prop, `SectionHeader`'s props, `resolveCustomer`'s export location (`utils/storage` re-export vs `utils/storage/customers`), theme token names (`textPrimary`/`textMuted`), and `radius` token for the modal card (use the theme's `radius` constant instead of the literal 12 if that's the convention). Adjust to reality — the structure and behavior above are the requirement, the exact prop spellings come from the codebase.

- [ ] **Step 4: Integrate into `screens/JobDetailScreen.tsx`**

(a) Imports:

```tsx
import ChangeOrdersSection from "../components/ChangeOrdersSection";
import { approvedChangeOrderTotal, jobBillableTotal } from "../utils/changeOrders";
```

(b) In the estimate-breakdown card, directly AFTER the existing total row (the `styles.estimateTotalValue` row at ~line 354-358), add the CO arithmetic — shown only when COs change the number:

```tsx
        {approvedChangeOrderTotal(job) !== 0 && (
          <>
            <View style={styles.estimateRow}>
              <Text style={styles.estimateLabel}>Approved changes</Text>
              <Text style={styles.estimateValue}>
                {approvedChangeOrderTotal(job) > 0 ? "+" : ""}{formatQuote(approvedChangeOrderTotal(job))}
              </Text>
            </View>
            <View style={styles.estimateRow}>
              <Text style={[styles.estimateLabel, styles.estimateTotalLabel]}>Total incl. changes</Text>
              <Text style={[styles.estimateValue, styles.estimateTotalValue]}>
                {formatQuote(jobBillableTotal(job))}
              </Text>
            </View>
          </>
        )}
```

Reuse the card's existing row/label/value style names (read the surrounding JSX; if the row wrapper style is named differently, use the real name).

(c) Render the section after the estimate card (top level of the screen's ScrollView, after the block containing the estimate breakdown):

```tsx
      <ChangeOrdersSection
        job={job}
        onChanged={loadData}
        onAdd={() => navigation.navigate("AddChangeOrder", { jobId: job.id })}
        onEdit={(changeOrderId) => navigation.navigate("AddChangeOrder", { jobId: job.id, changeOrderId })}
      />
```

`loadData` = whatever function JobDetail already uses to reload the job on focus (read the screen; it exists for the approval-decision refresh). Use its real name.

- [ ] **Step 5: Run tests**

Run: `npm test -- changeOrdersSection`
Expected: PASS.

- [ ] **Step 6: Full gate, commit**

```bash
git add components/ChangeOrdersSection.tsx screens/JobDetailScreen.tsx __tests__/changeOrdersSection.test.tsx
git commit -m "feat: change-orders section + billable arithmetic on JobDetail"
```

---

### Task 10: `change.html` customer page (tradeready-legal repo — HELD)

**Files:**
- Create: `../tradeready-legal/change.html` (sibling repo) on a NEW branch `feat/change-orders-legal`

**Interfaces:**
- Consumes: `GET /api/estimate/change-view?j&co&t` and `POST /api/estimate/change-respond` (Task 4's exact shapes).
- Produces: the public page Task 3's minted URLs point at. NEVER pushed in this plan — held until the backend deploys (launch chain).

- [ ] **Step 1: Create the branch and clone the template**

```bash
cd ../tradeready-legal
git checkout main
git pull
git checkout -b feat/change-orders-legal
cp estimate.html change.html
```

- [ ] **Step 2: Adapt `change.html`**

Open `estimate.html` first and keep its structure, `esc()` helper, styling, and backend origin EXACTLY. The adaptations (find each corresponding piece in the cloned file and change only these):

1. Page `<title>` and header copy: "Estimate" → "Change Order"; the intro line becomes "Review and approve this change to your job."
2. Query parsing: read `j`, `co`, and `t` (estimate.html reads `j`/`t`; add `co`). All three missing → the existing invalid-link screen.
3. View fetch: `/api/estimate/view?j=…&t=…` → `/api/estimate/change-view?j=…&co=…&t=…`.
4. Render: keep the line-items table (the snapshot has one line: the CO title + amount). After the total row, add the context block (all values from `data.context`, money formatted with the file's existing quote-style formatter — full cent pair or none):

```html
<div class="context">
  <div><span>Job total before this change</span><span id="ctx-original"></span></div>
  <div class="change-line"><span>This change</span><span id="ctx-change"></span></div>
  <div class="new-total"><span>New job total</span><span id="ctx-new"></span></div>
</div>
```

with JS (inside the render function, after the snapshot render; `fmtMoney` = the file's existing formatter name — use the real one):

```js
if (data.context) {
  document.getElementById('ctx-original').textContent = fmtMoney(data.context.originalTotal);
  var sign = data.context.changeAmount >= 0 ? '+' : '';
  document.getElementById('ctx-change').textContent = sign + fmtMoney(data.context.changeAmount);
  document.getElementById('ctx-new').textContent = fmtMoney(data.context.newTotal);
}
```

and render `data.description` (escaped with `esc()`) as a paragraph under the CO title when present.
5. Respond POST: `/api/estimate/respond` → `/api/estimate/change-respond`; body gains `changeOrderId: co` alongside `jobId`, `token`, `decision`, `signerName`/`declineReason`.
6. Error handling: the respond error path must show the server's `error` string verbatim (it already does on estimate.html) — this is how the 409 "This change was already decided." reaches the customer.
7. Decided state: same as estimate.html (decision non-null → show approved/declined banner instead of the buttons).
8. Approve/decline button copy: "Approve this change" / "Decline". The consent line under the signature field: "By typing your name you approve this change to the original estimate."

- [ ] **Step 3: Verify the page locally (static check)**

Open the file in a browser: `start change.html` (or double-click). With no params it must render the invalid-link screen, not a JS error. Check the browser console for exceptions.

- [ ] **Step 4: Commit on the held branch — DO NOT PUSH**

```bash
git add change.html
git commit -m "feat: change-order approval page (clone of estimate.html against change-view/change-respond)"
git checkout main
cd "../TraderPro App/tradeready" 2>/dev/null || cd ../tradeready
```

The branch stays local. Pushing it is the OWNER's launch-chain step 3, after the backend deploy.

---

### Task 11: Docs + final gate + phase report

**Files:**
- Modify: `README.md` (feature list), `ARCHITECTURE.md` (data-model note)
- No code changes.

- [ ] **Step 1: README**

Add to the features section (match the file's existing bullet style, present tense, describing reality):

```md
- **Change orders** — document a mid-job scope change (title, details, amount;
  negative = descope credit), get the customer's sign-off before the extra
  work starts (e-sign link on change.html, or an on-site "verbal OK" record),
  and the approved amount flows into the job's billable total, invoice line
  items, and PDF automatically. Cancelled/declined change orders stay in the
  history. Change-order decisions arriving via link are picked up on the next
  sync pull (no push notification — same as webhook payments).
```

If the README has a "Limitations" section, add: "Change orders don't appear on the customer portal yet."

- [ ] **Step 2: ARCHITECTURE.md**

In the data-model overview where Job is described, add one line: "`changeOrders?: ChangeOrder[]` — documented scope changes with per-CO approval (server-written `approval` / device-written `manualDecision`); status derived, billable total = `estimateTotal` + approved COs (`utils/changeOrders.ts`)."

- [ ] **Step 3: Full gate, commit, counts**

Run: `npm run typecheck` → expect 0 errors.
Run: `npm test` → record the new totals (expect ~2096 + ~45-60 new tests, ~141 + 6 suites).
Run: `npm run lint` → expect 0 warnings.

```bash
git add README.md ARCHITECTURE.md
git commit -m "docs: change orders in README + ARCHITECTURE"
```

- [ ] **Step 4: Phase report to the owner — STOP**

Report Confidence Level / Missing Context / Recommended Next Step. Include:
- the final gate numbers,
- the two deliberate spec refinements (finalize keeps `existing.amount` when no COs exist — preserves the manual-adjustment property; `change_order_decided` fires on the manual channel only in v1 — link decisions have no client-side detection hook),
- the launch chain reminder: merge → deploy backend (verify `git branch --show-current` first) → push `feat/change-orders-legal` in tradeready-legal → owner device smoke (create CO → send link → approve on phone → pull → finalize picks it up; manual path offline) → rides next OTA. No migration anywhere.
- claims discipline: not listable until device-smoked.

---

## Plan self-review (completed at authoring)

1. **Spec coverage:** §2 data model → Task 1; §3 money/billable → Tasks 1, 6, 7; §4 link path → Tasks 3, 4, 5, 10; §5 manual path → Tasks 1, 9; §6 UI → Tasks 8, 9; §7 errors → Tasks 3, 4 (HTTP codes), 1 (validation); §8 testing → every task + parity (Task 2); §9 rollout → Task 11 report; §10 residuals → documented in Task 11 README copy. Telemetry (§6) → Tasks 8, 9 (created/sent/decided-manual).
2. **Placeholder scan:** the "adapt to the suite's real fixtures" instructions in Tasks 6, 7, 9 are deliberate read-the-file-first steps with the behavioral assertions fully specified — not placeholders.
3. **Type consistency:** `changeOrderStatus` / `approvedChangeOrderTotal` / `jobBillableTotal` / `canAddChangeOrder` / `validateChangeOrderInput` / `applyManualDecision` / `cancelChangeOrder` / `buildChangeOrderSnapshot` / `newChangeOrderId` (Task 1) match every later usage; backend mirror names (Task 2) match Task 4's imports; `planChangeOrderLink` (Task 3) matches its test; `createChangeOrderLink` (Task 5) matches Task 9's import; `changeOrderTotal` field (Task 6) matches its test.
