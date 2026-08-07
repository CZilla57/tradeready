# Portal Completion Phase A (read-only additions) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the read-only Phase 12 portal capabilities — appointments (+ manage link), add-to-calendar ICS, change-order listing, and explicit paid-to-date — to the Workers `portal-view` family, with the Workers portal getting direct test coverage for the first time.

**Architecture:** Extract the portal response assembly out of the Hono route into a pure CommonJS module in `backend-workers/lib/estimate/` (the booking-manage convention), so the whitelist — the security boundary — is directly testable. Add one read-only store query (customer's bookingRequests) and one new read-only endpoint (`portal-ics`) that emits floating-local-time VEVENTs for owner-scheduled jobs. **Workers-only** — the frozen Vercel twin keeps serving the v1 shape; portal.html only calls Workers.

**Tech Stack:** Cloudflare Workers (Hono), plain CommonJS libs, Jest (root `__tests__/`, fetch-mocked per `bookingManage.test.js`), PostgREST via service role.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-07-portal-completion-design.md` §1–§4 (owner-approved 2026-08-07, "proceed as recommended").
- Additive-only response changes: the four existing top-level keys and every existing field keep their exact v1 values — old portal.html must keep working.
- Whitelist discipline: every section constructed key-by-key, NO spreads; exact-keys tests.
- `portalStore.js` stays READ-ONLY by contract (new fn is a read).
- Pay-link amount gate (`!paid` + `isAllowedPaymentLink` + `PAID_EPSILON` match) must survive byte-for-byte.
- Oracle-free errors: unknown token, wrong job, unscheduled job → identical 404 `{ error: 'This link is invalid.' }`.
- Owner-naive dates: string comparison only, never `new Date('YYYY-MM-DD')` local-frame parsing (FA-039).
- No new dependencies. No Vercel (`backend/`) changes. No `types/models.ts` changes (Phase A touches no persisted shapes).
- Gate green before every commit: `npm run typecheck` (0), `npm test` (all), `npm run lint` (0 warnings). Baseline 2552 tests / 188 suites.
- Branch: `feat/portal-completion` off master `6dd0b6d`. Do not touch the unrelated dirty files (`.claude/launch.json`, untracked docs) — commit only files this plan names.

---

### Task 1: Pure response assembler (`portalAssemble.js`)

**Files:**
- Create: `backend-workers/lib/estimate/portalAssemble.js`
- Test: `__tests__/portalAssembleWorkers.test.js`

**Interfaces:**
- Consumes: `balanceDue`, `amountPaid`, `PAID_EPSILON` from `backend-workers/lib/paymentMath.js`; `isAllowedPaymentLink` from `backend-workers/lib/reminderEmail.js`; `changeOrderStatus` from `backend-workers/lib/estimate/changeOrderMath.js`.
- Produces: `assemblePortalView({ businessName, customerRow, jobRows, invoiceRows, requestRows, token, apiOrigin, nowMs }) → response object` — consumed by Task 3's route and (shape only) by Task 5's page work in a later phase.

- [ ] **Step 1: Write the failing test** — `__tests__/portalAssembleWorkers.test.js`:

```js
// __tests__/portalAssembleWorkers.test.js
// Phase 12A: the Workers portal response assembler. The whitelist IS the
// security boundary — these tests pin the exact keys of every section and
// the v1 fields' exact values (old portal.html must keep working), plus the
// new appointments / changeOrders / amountPaid additions. First direct test
// coverage of the Workers portal (v1 tests pin only the Vercel twin).

const { assemblePortalView } = require("../backend-workers/lib/estimate/portalAssemble.js");

const NOW_MS = Date.UTC(2026, 7, 10, 12, 0); // "today" = 2026-08-10 UTC
const TOKEN = "p".repeat(48);
const ORIGIN = "https://tradeready-backend.tradeready.workers.dev";

const customerRow = { user_id: "u1", id: "c1", data: { name: "D".repeat(150), phone: "555-1", notes: "private" } };

const jobRows = [
  // In-window scheduled job, booked-originated (manageUrl expected)
  { id: "j_sched", data: { title: "Water heater swap", customerId: "c1", status: "scheduled", scheduledDate: "2026-08-12", scheduledStartTime: "09:00", scheduledEndTime: "10:30", laborRate: 95, notes: "gate code 1234" } },
  // In-window, later same day (sort check), no times
  { id: "j_sched2", data: { title: "Estimate visit", customerId: "c1", status: "approved", scheduledDate: "2026-08-12" } },
  // Yesterday (in window via lookback pad)
  { id: "j_yday", data: { title: "Yesterday", customerId: "c1", status: "in_progress", scheduledDate: "2026-08-09", scheduledStartTime: "08:00" } },
  // Out of window: past
  { id: "j_past", data: { title: "Old", customerId: "c1", status: "complete", scheduledDate: "2026-07-01" } },
  // Out of window: beyond 60d
  { id: "j_far", data: { title: "Far", customerId: "c1", status: "scheduled", scheduledDate: "2026-12-01" } },
  // Archived and declined must be invisible
  { id: "j_arch", data: { title: "Arch", customerId: "c1", status: "scheduled", scheduledDate: "2026-08-12", archived: true } },
  { id: "j_decl", data: { title: "Decl", customerId: "c1", status: "declined", scheduledDate: "2026-08-12" } },
  // Malformed date must be invisible
  { id: "j_bad", data: { title: "Bad", customerId: "c1", status: "scheduled", scheduledDate: "soon" } },
  // Estimate-carrying job (v1 behavior unchanged)
  { id: "j_est", data: { title: "Fence", customerId: "c1", approval: { token: "t".repeat(48), snapshot: { jobTitle: "Fence build", total: 2400 } } } },
  // Change-order-carrying job: awaiting + approved + cancelled + linkless
  { id: "j_co", data: {
      title: "Kitchen remodel", customerId: "c1", status: "in_progress",
      changeOrders: [
        { id: "co_wait", title: "Extra outlet", amount: 150, createdAt: "2026-08-08", approval: { token: "a".repeat(48), sentAt: "2026-08-08" } },
        { id: "co_appr", title: "Descope tile", amount: -300, createdAt: "2026-08-08", approval: { token: "b".repeat(48), sentAt: "2026-08-08", decision: "approved", consentAt: "2026-08-09T01:00:00.000Z" } },
        { id: "co_canc", title: "Cancelled", amount: 50, createdAt: "2026-08-08", cancelledAt: "2026-08-09", approval: { token: "c".repeat(48), sentAt: "2026-08-08" } },
        { id: "co_nolink", title: "Verbal only", amount: 75, createdAt: "2026-08-08", manualDecision: { decision: "approved", decidedAt: "2026-08-08" } },
      ],
    } },
];

const invoiceRows = [
  // Partially paid via ledger, current link on an allowlisted host
  { id: "i1", data: { number: "INV-0001", amount: 1000, customerId: "c1", due: "2026-08-20",
      payments: [{ id: "p1", amount: 400, date: "2026-08-01", method: "cash" }],
      paymentLinkUrl: "https://buy.stripe.com/x", paymentLinkAmount: 600 } },
  // Legacy paid invoice (empty ledger, paid flag) — amountPaid uses the fallback
  { id: "i2", data: { number: "INV-0002", amount: 500, customerId: "c1", paid: true, paidAt: "2026-07-30" } },
  // Stale link amount → link suppressed
  { id: "i3", data: { number: "INV-0003", amount: 800, customerId: "c1",
      payments: [{ id: "p2", amount: 200, date: "2026-08-02", method: "cash" }],
      paymentLinkUrl: "https://buy.stripe.com/y", paymentLinkAmount: 800 } },
];

const requestRows = [
  { id: "bk1", data: { status: "confirmed", kind: "booked", manageToken: "m".repeat(48), convertedJobId: "j_sched", convertedCustomerId: "c1" } },
  // Cancelled booking → no manage link
  { id: "bk2", data: { status: "cancelled", kind: "booked", manageToken: "x".repeat(48), convertedJobId: "j_sched2", convertedCustomerId: "c1" } },
];

function assemble(over = {}) {
  return assemblePortalView({
    businessName: "B".repeat(150), customerRow, jobRows, invoiceRows, requestRows,
    token: TOKEN, apiOrigin: ORIGIN, nowMs: NOW_MS, ...over,
  });
}

describe("assemblePortalView — whitelist boundary", () => {
  test("top level has exactly the six keys", () => {
    expect(Object.keys(assemble()).sort()).toEqual(
      ["appointments", "businessName", "changeOrders", "customerName", "estimates", "invoices"]
    );
  });

  test("names are capped at 120", () => {
    const out = assemble();
    expect(out.businessName).toBe("B".repeat(120));
    expect(out.customerName).toBe("D".repeat(120));
  });

  test("every section's items carry exactly the whitelisted keys", () => {
    const out = assemble();
    for (const a of out.appointments)
      expect(Object.keys(a).sort()).toEqual(["date", "end", "icsUrl", "jobRef", "manageUrl", "start", "title"]);
    for (const e of out.estimates)
      expect(Object.keys(e).sort()).toEqual(["approvalUrl", "decision", "title", "total"]);
    for (const co of out.changeOrders)
      expect(Object.keys(co).sort()).toEqual(["amount", "changeUrl", "jobTitle", "status", "title"]);
    for (const i of out.invoices)
      expect(Object.keys(i).sort()).toEqual(["amount", "amountPaid", "balanceDue", "due", "number", "paid", "paidAt", "paymentLinkUrl"]);
  });

  test("nothing sensitive crosses the wire", () => {
    const flat = JSON.stringify(assemble());
    expect(flat).not.toContain("gate code");   // job notes
    expect(flat).not.toContain("private");     // customer notes
    expect(flat).not.toContain("555-1");       // contact info
    expect(flat).not.toContain("laborRate");   // pricing internals
  });
});

describe("appointments", () => {
  test("window + archived/declined/malformed filtering and (date,start) sort", () => {
    const ids = assemble().appointments.map((a) => a.jobRef);
    expect(ids).toEqual(["j_yday", "j_sched", "j_sched2"]);
  });

  test("fields, ics url, and manage link only for active bookings", () => {
    const [, sched, sched2] = assemble().appointments;
    expect(sched).toEqual({
      title: "Water heater swap", date: "2026-08-12", start: "09:00", end: "10:30",
      jobRef: "j_sched",
      icsUrl: `${ORIGIN}/api/estimate/portal-ics?p=${TOKEN}&j=j_sched`,
      manageUrl: `https://gettradereadyapp.com/booking.html?m=${"m".repeat(48)}`,
    });
    expect(sched2.start).toBeNull();
    expect(sched2.end).toBeNull();
    expect(sched2.manageUrl).toBeNull(); // its booking was cancelled
  });
});

describe("change orders", () => {
  test("only link-carrying, non-cancelled COs; derived status; signed amount; change URL", () => {
    const cos = assemble().changeOrders;
    expect(cos).toEqual([
      { jobTitle: "Kitchen remodel", title: "Extra outlet", amount: 150, status: "awaiting",
        changeUrl: `https://gettradereadyapp.com/change.html?j=j_co&co=co_wait&t=${"a".repeat(48)}` },
      { jobTitle: "Kitchen remodel", title: "Descope tile", amount: -300, status: "approved",
        changeUrl: `https://gettradereadyapp.com/change.html?j=j_co&co=co_appr&t=${"b".repeat(48)}` },
    ]);
  });
});

describe("estimates (v1 behavior unchanged)", () => {
  test("only approval-carrying jobs, frozen snapshot values", () => {
    expect(assemble().estimates).toEqual([
      { title: "Fence build", total: 2400, decision: null,
        approvalUrl: `https://gettradereadyapp.com/estimate.html?j=j_est&t=${"t".repeat(48)}` },
    ]);
  });
});

describe("invoices", () => {
  test("v1 fields byte-identical + amountPaid from the ledger", () => {
    const [i1, i2, i3] = assemble().invoices;
    expect(i1).toEqual({
      number: "INV-0001", amount: 1000, amountPaid: 400, balanceDue: 600,
      due: "2026-08-20", paid: false, paidAt: null,
      paymentLinkUrl: "https://buy.stripe.com/x",
    });
    // Legacy fallback: paid flag + empty ledger reads as fully paid
    expect(i2.amountPaid).toBe(500);
    expect(i2.balanceDue).toBe(0);
    expect(i2.paymentLinkUrl).toBeNull();
    // Stale cached amount (800 vs balance 600) → link suppressed
    expect(i3.amountPaid).toBe(200);
    expect(i3.paymentLinkUrl).toBeNull();
  });

  test("disallowed host is dropped even when the amount matches", () => {
    const out = assemble({ invoiceRows: [{ id: "i4", data: {
      number: "INV-0004", amount: 100, customerId: "c1",
      paymentLinkUrl: "https://squareup.com/pay/tok", paymentLinkAmount: 100 } }] });
    expect(out.invoices[0].paymentLinkUrl).toBeNull();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npx jest portalAssembleWorkers -t "" 2>&1 | tail -5` (from `tradeready/`)
Expected: FAIL — `Cannot find module '../backend-workers/lib/estimate/portalAssemble.js'`

- [ ] **Step 3: Implement** — `backend-workers/lib/estimate/portalAssemble.js`:

```js
// Pure assembly of the portal-view response (Phase 12A). Extracted from the
// route handler so the whitelist — the security boundary — is directly
// testable without a Hono context. The rows this consumes also carry contact
// info, rates, notes and other internal data; every section is constructed
// key-by-key (no spreads) and nothing beyond the whitelist may cross.
// Workers-only: the frozen Vercel twin keeps serving the v1 shape, so this
// deliberately has no backend/ mirror.

const { balanceDue, amountPaid, PAID_EPSILON } = require('../paymentMath.js');
const { isAllowedPaymentLink } = require('../reminderEmail.js');
const { changeOrderStatus } = require('./changeOrderMath.js');

const ESTIMATE_PAGE = 'https://gettradereadyapp.com/estimate.html';
const CHANGE_PAGE = 'https://gettradereadyapp.com/change.html';
const BOOKING_MANAGE_PAGE = 'https://gettradereadyapp.com/booking.html';

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const DAY_MS = 86_400_000;
// The window is padded a day behind "today" so an owner-naive date can never
// drop out early just because the server clock sits in a different zone.
const APPOINTMENT_LOOKBACK_DAYS = 1;
const APPOINTMENT_WINDOW_DAYS = 60;

// A manage link is only offered while the booking is still actionable on the
// shipped manage page's state machine.
const ACTIVE_BOOKING_STATUSES = new Set(['booked', 'confirmed', 'reschedule_requested']);

function isoDateUTC(ms) {
  return new Date(ms).toISOString().slice(0, 10);
}

function cap(value, n) {
  return String(value || '').slice(0, n);
}

function buildAppointments(jobRows, requestRows, { token, apiOrigin, nowMs }) {
  const minDate = isoDateUTC(nowMs - APPOINTMENT_LOOKBACK_DAYS * DAY_MS);
  const maxDate = isoDateUTC(nowMs + APPOINTMENT_WINDOW_DAYS * DAY_MS);
  const manageByJobId = new Map();
  for (const r of Array.isArray(requestRows) ? requestRows : []) {
    const d = r && r.data;
    if (!d || !d.manageToken || d.kind !== 'booked' || !d.convertedJobId) continue;
    if (!ACTIVE_BOOKING_STATUSES.has(d.status)) continue;
    manageByJobId.set(d.convertedJobId, d.manageToken);
  }
  return jobRows
    .filter((r) => {
      const d = r && r.data;
      if (!d || d.archived || d.status === 'declined') return false;
      const date = d.scheduledDate;
      if (typeof date !== 'string' || !DATE_RE.test(date)) return false;
      // Owner-naive string comparison on purpose (FA-039) — never Date-parse.
      return date >= minDate && date <= maxDate;
    })
    .sort((a, b) => {
      const ka = `${a.data.scheduledDate}|${a.data.scheduledStartTime || ''}`;
      const kb = `${b.data.scheduledDate}|${b.data.scheduledStartTime || ''}`;
      return ka < kb ? -1 : ka > kb ? 1 : 0;
    })
    .map((r) => {
      const d = r.data;
      const manageToken = manageByJobId.get(r.id) || null;
      return {
        title: cap(d.title, 200),
        date: d.scheduledDate,
        start: d.scheduledStartTime || null,
        end: d.scheduledEndTime || null,
        // Job ids already cross the wire inside approvalUrl — not a new exposure.
        jobRef: String(r.id),
        icsUrl: `${apiOrigin}/api/estimate/portal-ics?p=${encodeURIComponent(token)}&j=${encodeURIComponent(r.id)}`,
        manageUrl: manageToken ? `${BOOKING_MANAGE_PAGE}?m=${encodeURIComponent(manageToken)}` : null,
      };
    });
}

// Only jobs with an approval link are customer-visible estimates — the
// frozen snapshot plus the shipped approval page. Internal jobs stay
// invisible. (v1 behavior, moved verbatim from the route.)
function buildEstimates(jobRows) {
  return jobRows
    .filter((r) => r.data && r.data.approval && r.data.approval.token)
    .map((r) => ({
      title: cap(r.data.approval.snapshot?.jobTitle || r.data.title, 200),
      total: Number(r.data.approval.snapshot?.total || 0),
      decision: r.data.approval.decision || null,
      approvalUrl: `${ESTIMATE_PAGE}?j=${encodeURIComponent(r.id)}&t=${encodeURIComponent(r.data.approval.token)}`,
    }));
}

// Mirrors the estimates rule: no approval token → the CO is internal and
// invisible. Cancelled COs are owner bookkeeping, not customer state.
function buildChangeOrders(jobRows) {
  const out = [];
  for (const r of jobRows) {
    const d = r && r.data;
    if (!d || !Array.isArray(d.changeOrders)) continue;
    for (const co of d.changeOrders) {
      if (!co || !co.approval || !co.approval.token) continue;
      const status = changeOrderStatus(co);
      if (status === 'cancelled') continue;
      out.push({
        jobTitle: cap(d.title, 200),
        title: cap(co.title, 200),
        amount: Number(co.amount || 0),
        status,
        changeUrl: `${CHANGE_PAGE}?j=${encodeURIComponent(r.id)}&co=${encodeURIComponent(co.id)}&t=${encodeURIComponent(co.approval.token)}`,
      });
    }
  }
  return out;
}

function buildInvoices(invoiceRows) {
  return invoiceRows.map((r) => {
    const inv = r.data || {};
    const link = inv.paymentLinkUrl;
    const due = balanceDue(inv);
    // Mirrors linkCurrent in reminderEmail.js: a cached link is only shown
    // when it was minted for the CURRENT balance. A link cached before a
    // partial payment (or for a deposit) charges a different amount than the
    // portal displays, and there's no owner in the loop here to catch the
    // customer being overcharged. An absent/unparseable paymentLinkAmount
    // fails the match and drops the link — fail closed, same as the email.
    const linkAmount = Number(inv.paymentLinkAmount);
    const linkCurrent =
      !inv.paid &&
      isAllowedPaymentLink(link) &&
      Number.isFinite(linkAmount) &&
      Math.abs(linkAmount - due) <= PAID_EPSILON;
    return {
      number: String(inv.number || ''),
      amount: Number(inv.amount || 0),
      // Explicit paid-to-date (Phase 12A): same ledger math as balanceDue,
      // including the legacy paid-flag fallback, so the two never disagree.
      amountPaid: amountPaid(inv),
      balanceDue: due,
      due: inv.due || null,
      paid: !!inv.paid,
      paidAt: inv.paidAt || null,
      // Same host allowlist as the dunning email — a tampered or legacy link
      // can never turn the portal into a phishing surface. Paid invoices get
      // no link at all. Same current-balance gate as the dunning email — see
      // linkCurrent above.
      paymentLinkUrl: linkCurrent ? link : null,
    };
  });
}

function assemblePortalView({ businessName, customerRow, jobRows, invoiceRows, requestRows, token, apiOrigin, nowMs }) {
  return {
    businessName: cap(businessName, 120),
    customerName: cap(customerRow.data?.name, 120),
    appointments: buildAppointments(jobRows, requestRows, { token, apiOrigin, nowMs }),
    estimates: buildEstimates(jobRows),
    changeOrders: buildChangeOrders(jobRows),
    invoices: buildInvoices(invoiceRows),
  };
}

module.exports = { assemblePortalView };
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npx jest portalAssembleWorkers 2>&1 | tail -5`
Expected: PASS, 10 tests.

- [ ] **Step 5: Full gate, then commit**

Run: `npm run typecheck && npm test -- --silent && npm run lint` — all green.

```bash
git add backend-workers/lib/estimate/portalAssemble.js __tests__/portalAssembleWorkers.test.js
git commit -m "feat(portal): pure Workers response assembler - appointments, change orders, amountPaid"
```

---

### Task 2: `fetchCustomerBookingRequests` store read

**Files:**
- Modify: `backend-workers/lib/estimate/portalStore.js` (add one fn + export)
- Test: `__tests__/portalStoreWorkers.test.js` (new — first Workers-store coverage; pins ALL five query URLs)

**Interfaces:**
- Produces: `fetchCustomerBookingRequests(env, userId, customerId) → Promise<rows>` — consumed by Task 3.

- [ ] **Step 1: Write the failing test** — `__tests__/portalStoreWorkers.test.js`:

```js
// __tests__/portalStoreWorkers.test.js
// Phase 12A: first direct coverage of the WORKERS portal store (v1 tests pin
// only the Vercel twin). The URL strings ARE the tenant-isolation boundary —
// every jobs/invoices/bookingRequests query must filter by BOTH user_id and
// customerId, and the token lookup must require enabled=true.

const store = require("../backend-workers/lib/estimate/portalStore.js");

const ENV = { SUPABASE_URL: "https://supa.test", SUPABASE_SERVICE_ROLE_KEY: "srk" };

function mockFetch(rows = []) {
  global.fetch = jest.fn(async () => ({ ok: true, status: 200, json: async () => rows, text: async () => "[]" }));
  return global.fetch;
}

afterEach(() => { delete global.fetch; });

test("token lookup filters token + enabled + not-deleted and uses the service role", async () => {
  const f = mockFetch([{ user_id: "u1", id: "c1", data: {} }]);
  const row = await store.lookupCustomerByPortalToken(ENV, "tok");
  expect(row).toEqual({ user_id: "u1", id: "c1", data: {} });
  const [url, init] = f.mock.calls[0];
  expect(url).toContain("customers?data->portal->>token=eq.tok");
  expect(url).toContain("data->portal->>enabled=eq.true");
  expect(url).toContain("deleted=eq.false");
  expect(init.headers.Authorization).toBe("Bearer srk");
});

test("unknown token resolves null (no oracle)", async () => {
  mockFetch([]);
  expect(await store.lookupCustomerByPortalToken(ENV, "nope")).toBeNull();
});

test.each([
  ["fetchCustomerJobs", "jobs"],
  ["fetchCustomerInvoices", "invoices"],
  ["fetchCustomerBookingRequests", "bookingRequests"],
])("%s scopes by BOTH user_id and customerId", async (fn, table) => {
  const f = mockFetch([]);
  await store[fn](ENV, "u1", "c1");
  const url = String(f.mock.calls[0][0]);
  expect(url).toContain(`${table}?user_id=eq.u1`);
  expect(url).toContain(
    table === "bookingRequests" ? "data->>convertedCustomerId=eq.c1" : "data->>customerId=eq.c1"
  );
  expect(url).toContain("deleted=eq.false");
});

test("business name read selects only data", async () => {
  const f = mockFetch([{ data: { businessName: "Ace" } }]);
  expect(await store.fetchBusinessName(ENV, "u1")).toBe("Ace");
  expect(String(f.mock.calls[0][0])).toContain("settings?user_id=eq.u1&select=data");
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx jest portalStoreWorkers 2>&1 | tail -5`
Expected: FAIL — `store.fetchCustomerBookingRequests is not a function` (the other four pass).

- [ ] **Step 3: Implement** — in `backend-workers/lib/estimate/portalStore.js`, after `fetchCustomerInvoices`:

```js
// This customer's booking requests — used only to attach the shipped
// manage-page link to appointments that originated as bookings. Read-only
// like everything else here; scoped by BOTH user_id and the converted
// customer id so a portal token can never see another customer's bookings.
async function fetchCustomerBookingRequests(env, userId, customerId) {
  return get(
    env,
    `bookingRequests?user_id=eq.${encodeURIComponent(userId)}&data->>convertedCustomerId=eq.${encodeURIComponent(customerId)}&deleted=eq.false&select=id,data`
  );
}
```

and extend the export line:

```js
module.exports = { lookupCustomerByPortalToken, fetchBusinessName, fetchCustomerJobs, fetchCustomerInvoices, fetchCustomerBookingRequests };
```

- [ ] **Step 4: Run to verify it passes** — `npx jest portalStoreWorkers 2>&1 | tail -5` → PASS (6 tests).

- [ ] **Step 5: Full gate, then commit**

```bash
git add backend-workers/lib/estimate/portalStore.js __tests__/portalStoreWorkers.test.js
git commit -m "feat(portal): customer bookingRequests read + Workers portal store coverage"
```

---

### Task 3: Rewire the `portal-view` route through the assembler

**Files:**
- Modify: `backend-workers/src/routes/estimate/portalView.js`

**Interfaces:**
- Consumes: Task 1's `assemblePortalView`, Task 2's `fetchCustomerBookingRequests`.
- Route contract (CORS → OPTIONS 200 → 405 → 429 → 400 → 404 → 500) is byte-identical to v1.

- [ ] **Step 1: Rewrite the handler body.** Replace the whole file's post-lookup section (lines 45–106) and trim the imports; the file becomes:

```js
// GET /api/estimate/portal-view?p=<token> — Workers port of
// backend/lib/estimate/portalView.js (v1) + the Phase 12A read additions
// (appointments, change orders, amountPaid), which are Workers-only.
// READ-ONLY — the portal's approve/decline, Pay, and booking-manage actions
// all reuse shipped pages and links; this handler only assembles a
// WHITELISTED view. The whitelist (lib/estimate/portalAssemble.js) is the
// security boundary: the rows it reads also carry contact info, rates,
// notes and other customers' data — none of which may cross the wire to an
// anonymous caller.

import { applyCors } from '../../../lib/estimate/cors.js';
import { createRateLimiter } from '../../../lib/guards.js';
import {
  lookupCustomerByPortalToken,
  fetchBusinessName,
  fetchCustomerJobs,
  fetchCustomerInvoices,
  fetchCustomerBookingRequests,
} from '../../../lib/estimate/portalStore.js';
import { assemblePortalView } from '../../../lib/estimate/portalAssemble.js';
import { clientIp } from '../../appCors.js';

const allow = createRateLimiter({ limit: 30 });

export async function portalViewHandler(c) {
  applyCors(c, 'GET, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'GET') return c.json({ error: 'Method not allowed' }, 405);

  const ip = clientIp(c);
  if (!allow(ip)) return c.json({ error: 'Too many requests.' }, 429);

  const token = c.req.query('p');
  if (!token) return c.json({ error: 'Missing link parameters.' }, 400);

  let row;
  try {
    row = await lookupCustomerByPortalToken(c.env, String(token));
  } catch (err) {
    console.error('[estimate/portal-view] lookup failed:', err.message);
    return c.json({ error: 'Database error' }, 500);
  }
  if (!row) return c.json({ error: 'This link is invalid.' }, 404);

  let businessName, jobRows, invoiceRows, requestRows;
  try {
    [businessName, jobRows, invoiceRows, requestRows] = await Promise.all([
      fetchBusinessName(c.env, row.user_id),
      fetchCustomerJobs(c.env, row.user_id, row.id),
      fetchCustomerInvoices(c.env, row.user_id, row.id),
      fetchCustomerBookingRequests(c.env, row.user_id, row.id),
    ]);
  } catch (err) {
    console.error('[estimate/portal-view] fetch failed:', err.message);
    return c.json({ error: 'Database error' }, 500);
  }

  return c.json(
    assemblePortalView({
      businessName,
      customerRow: row,
      jobRows,
      invoiceRows,
      requestRows,
      token: String(token),
      apiOrigin: new URL(c.req.url).origin,
      nowMs: Date.now(),
    }),
    200
  );
}
```

- [ ] **Step 2: Full gate** — `npm run typecheck && npm test -- --silent && npm run lint`. The existing Vercel suites (`portalView.test.js` etc.) and Task 1/2 suites all stay green.

- [ ] **Step 3: Commit**

```bash
git add backend-workers/src/routes/estimate/portalView.js
git commit -m "feat(portal): route portal-view through the assembler with booking-manage links"
```

---

### Task 4: Floating-local-time job ICS builder

**Files:**
- Modify: `backend-workers/lib/booking/ics.js` (add `buildJobIcs`, keep `buildIcs` untouched)
- Test: `__tests__/portalIcsWorkers.test.js` (builder half; Task 5 adds the core half to the same file)

**Interfaces:**
- Produces: `buildJobIcs({ businessName, title, date, start, end, uid, stampUtc }) → string` — consumed by Task 5.

- [ ] **Step 1: Write the failing test** — create `__tests__/portalIcsWorkers.test.js`:

```js
// __tests__/portalIcsWorkers.test.js
// Phase 12A: add-to-calendar for owner-scheduled job appointments.
// buildJobIcs emits FLOATING local time (no Z, no TZID) on purpose — owner-
// naive schedule strings carry no zone, and a local-trades appointment
// renders correctly at face value (spec §4, decision D6). portalIcsCore is
// oracle-free: unknown token, foreign job, and unscheduled job are the same
// 404 as the portal view.

const { buildJobIcs } = require("../backend-workers/lib/booking/ics.js");

const STAMP = "2026-08-10T12:00:00.000Z";

describe("buildJobIcs", () => {
  test("timed event: floating DTSTART/DTEND, no Z, escaped summary", () => {
    const ics = buildJobIcs({
      businessName: "Ace; Plumbing", title: "Heater, swap", date: "2026-08-12",
      start: "09:00", end: "10:30", uid: "j1@tradeready-portal", stampUtc: STAMP,
    });
    expect(ics).toContain("DTSTART:20260812T090000\r\n");
    expect(ics).toContain("DTEND:20260812T103000\r\n");
    expect(ics).toContain("SUMMARY:Heater\\, swap — Ace\\; Plumbing");
    expect(ics).toContain("DTSTAMP:20260810T120000Z");
    expect(ics).not.toMatch(/DTSTART:[^\r]*Z/);
    expect(ics).toContain("UID:j1@tradeready-portal");
  });

  test("missing or inverted end falls back to start + 60 minutes", () => {
    const noEnd = buildJobIcs({ businessName: "B", title: "T", date: "2026-08-12", start: "09:00", end: null, uid: "u", stampUtc: STAMP });
    expect(noEnd).toContain("DTEND:20260812T100000");
    const inverted = buildJobIcs({ businessName: "B", title: "T", date: "2026-08-12", start: "09:00", end: "08:00", uid: "u", stampUtc: STAMP });
    expect(inverted).toContain("DTEND:20260812T100000");
    const nearMidnight = buildJobIcs({ businessName: "B", title: "T", date: "2026-08-12", start: "23:30", end: null, uid: "u", stampUtc: STAMP });
    expect(nearMidnight).toContain("DTEND:20260812T235900"); // clamped, never rolls over
  });

  test("no start time → all-day event with exclusive DTEND (month rollover safe)", () => {
    const ics = buildJobIcs({ businessName: "B", title: "T", date: "2026-08-31", start: null, end: null, uid: "u", stampUtc: STAMP });
    expect(ics).toContain("DTSTART;VALUE=DATE:20260831");
    expect(ics).toContain("DTEND;VALUE=DATE:20260901");
  });

  test("no title falls back to a generic summary", () => {
    const ics = buildJobIcs({ businessName: "Ace", title: "", date: "2026-08-12", start: null, end: null, uid: "u", stampUtc: STAMP });
    expect(ics).toContain("SUMMARY:Appointment — Ace");
  });
});
```

- [ ] **Step 2: Run to verify it fails** — `npx jest portalIcsWorkers 2>&1 | tail -5` → FAIL (`buildJobIcs` is not a function).

- [ ] **Step 3: Implement** — append to `backend-workers/lib/booking/ics.js` before the export, and extend the export:

```js
// Floating-local-time single event for an owner-scheduled job appointment
// (Phase 12A). Owner-naive date/time strings carry no zone, so the event is
// emitted WITHOUT Z/TZID and calendar apps render it at face value in the
// viewer's zone — correct for a local-trades appointment. Booked-slot
// appointments keep using buildIcs above (real UTC instants). No start time
// → all-day event (DTEND exclusive per RFC 5545 §3.6.1).

function icsDate(ymd) {
  return String(ymd).replace(/-/g, '');
}

function icsFloating(ymd, hm) {
  return `${icsDate(ymd)}T${String(hm).replace(':', '')}00`;
}

function addMinutesClamped(hm, minutes) {
  const [h, m] = String(hm).split(':').map(Number);
  const total = Math.min(h * 60 + m + minutes, 23 * 60 + 59);
  return `${String(Math.floor(total / 60)).padStart(2, '0')}:${String(total % 60).padStart(2, '0')}`;
}

function nextDate(ymd) {
  const [y, m, d] = String(ymd).split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d) + 86_400_000).toISOString().slice(0, 10);
}

function buildJobIcs({ businessName, title, date, start, end, uid, stampUtc }) {
  const summary = icsEscape(title ? `${title} — ${businessName}` : `Appointment — ${businessName}`);
  const timing = start
    ? [
        `DTSTART:${icsFloating(date, start)}`,
        `DTEND:${icsFloating(date, end && end > start ? end : addMinutesClamped(start, 60))}`,
      ]
    : [
        `DTSTART;VALUE=DATE:${icsDate(date)}`,
        `DTEND;VALUE=DATE:${icsDate(nextDate(date))}`,
      ];
  const lines = [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//TradeReady//Portal//EN',
    'CALSCALE:GREGORIAN',
    'METHOD:PUBLISH',
    'BEGIN:VEVENT',
    `UID:${icsEscape(uid)}`,
    `DTSTAMP:${icsTime(stampUtc)}`,
    ...timing,
    `SUMMARY:${summary}`,
    'END:VEVENT',
    'END:VCALENDAR',
  ];
  return lines.join('\r\n') + '\r\n';
}

module.exports = { buildIcs, buildJobIcs };
```

(Delete the old `module.exports = { buildIcs };` line — there must be exactly one export statement.)

- [ ] **Step 4: Run to verify it passes** — `npx jest portalIcsWorkers 2>&1 | tail -5` → PASS. Also `npx jest bookingManage 2>&1 | tail -3` → still PASS (buildIcs untouched).

- [ ] **Step 5: Full gate, then commit**

```bash
git add backend-workers/lib/booking/ics.js __tests__/portalIcsWorkers.test.js
git commit -m "feat(portal): floating-local-time job ICS builder"
```

---

### Task 5: `portal-ics` endpoint (core + route + registration)

**Files:**
- Create: `backend-workers/lib/estimate/portalIcs.js`
- Create: `backend-workers/src/routes/estimate/portalIcs.js`
- Modify: `backend-workers/src/index.js` (import + one route line, BEFORE the `/api/estimate/:action` catch-all)
- Test: extend `__tests__/portalIcsWorkers.test.js`

**Interfaces:**
- Consumes: Task 2's store reads, Task 4's `buildJobIcs`.
- Produces: `portalIcsCore(env, { token, jobId, stampUtc }) → { ok:false, status, error } | { ok:true, ics }`; route `GET /api/estimate/portal-ics?p=&j=`.

- [ ] **Step 1: Extend the test file** — append to `__tests__/portalIcsWorkers.test.js`:

```js
const { portalIcsCore } = require("../backend-workers/lib/estimate/portalIcs.js");

const ENV = { SUPABASE_URL: "https://supa.test", SUPABASE_SERVICE_ROLE_KEY: "srk" };
const TOKEN = "p".repeat(48);

function mockPortalBackend({ customerRows = [], jobRows = [], settingsRows = [] } = {}) {
  global.fetch = jest.fn(async (url) => {
    const u = String(url);
    const body = u.includes("/rest/v1/customers") ? customerRows
      : u.includes("/rest/v1/jobs") ? jobRows
      : u.includes("/rest/v1/settings") ? settingsRows
      : [];
    return { ok: true, status: 200, json: async () => body, text: async () => "[]" };
  });
}

afterEach(() => { delete global.fetch; });

describe("portalIcsCore", () => {
  const customer = { user_id: "u1", id: "c1", data: { name: "Dana" } };
  const schedJob = { id: "j1", data: { title: "Heater", customerId: "c1", scheduledDate: "2026-08-12", scheduledStartTime: "09:00", scheduledEndTime: "10:00" } };

  test("unknown token → oracle-free 404", async () => {
    mockPortalBackend({ customerRows: [] });
    expect(await portalIcsCore(ENV, { token: TOKEN, jobId: "j1", stampUtc: STAMP }))
      .toEqual({ ok: false, status: 404, error: "This link is invalid." });
  });

  test("job not in this customer's rows → same 404", async () => {
    mockPortalBackend({ customerRows: [customer], jobRows: [schedJob] });
    expect((await portalIcsCore(ENV, { token: TOKEN, jobId: "other", stampUtc: STAMP })).status).toBe(404);
  });

  test("unscheduled job → same 404", async () => {
    mockPortalBackend({ customerRows: [customer], jobRows: [{ id: "j2", data: { title: "NoSched", customerId: "c1" } }] });
    expect((await portalIcsCore(ENV, { token: TOKEN, jobId: "j2", stampUtc: STAMP })).status).toBe(404);
  });

  test("scheduled job → floating VEVENT with the business name", async () => {
    mockPortalBackend({ customerRows: [customer], jobRows: [schedJob], settingsRows: [{ data: { businessName: "Ace" } }] });
    const out = await portalIcsCore(ENV, { token: TOKEN, jobId: "j1", stampUtc: STAMP });
    expect(out.ok).toBe(true);
    expect(out.ics).toContain("DTSTART:20260812T090000");
    expect(out.ics).toContain("SUMMARY:Heater — Ace");
    expect(out.ics).toContain("UID:j1@tradeready-portal");
  });
});
```

- [ ] **Step 2: Run to verify it fails** — `npx jest portalIcsWorkers 2>&1 | tail -5` → FAIL (module not found).

- [ ] **Step 3: Implement the core** — `backend-workers/lib/estimate/portalIcs.js`:

```js
// Portal add-to-calendar read (Phase 12A): resolve the portal token, prove
// the job belongs to that customer AND is actually scheduled, and emit one
// floating-local-time VEVENT. Every failure is the same oracle-free 404 the
// portal view uses. READ-ONLY like the whole portal family.

const {
  lookupCustomerByPortalToken,
  fetchBusinessName,
  fetchCustomerJobs,
} = require('./portalStore.js');
const { buildJobIcs } = require('../booking/ics.js');

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const INVALID = { ok: false, status: 404, error: 'This link is invalid.' };

async function portalIcsCore(env, { token, jobId, stampUtc }) {
  const row = await lookupCustomerByPortalToken(env, String(token));
  if (!row) return INVALID;
  const jobs = await fetchCustomerJobs(env, row.user_id, row.id);
  const job = jobs.find((r) => r.id === String(jobId));
  const d = job && job.data;
  if (!d || d.archived || typeof d.scheduledDate !== 'string' || !DATE_RE.test(d.scheduledDate)) {
    return INVALID;
  }
  const businessName = await fetchBusinessName(env, row.user_id);
  const ics = buildJobIcs({
    businessName: String(businessName || '').slice(0, 120),
    title: String(d.title || '').slice(0, 200),
    date: d.scheduledDate,
    start: d.scheduledStartTime || null,
    end: d.scheduledEndTime || null,
    uid: `${String(jobId).slice(0, 24)}@tradeready-portal`,
    stampUtc,
  });
  return { ok: true, ics };
}

module.exports = { portalIcsCore };
```

- [ ] **Step 4: Implement the route** — `backend-workers/src/routes/estimate/portalIcs.js`:

```js
// GET /api/estimate/portal-ics?p=<token>&j=<jobId> — "Add to calendar" for a
// portal appointment (Phase 12A). Consumed as a plain link (like booking
// manage's ?format=ics), so CORS is irrelevant to the download itself; the
// shared estimate CORS is applied anyway for family consistency.

import { applyCors } from '../../../lib/estimate/cors.js';
import { createRateLimiter } from '../../../lib/guards.js';
import { portalIcsCore } from '../../../lib/estimate/portalIcs.js';
import { clientIp } from '../../appCors.js';

const allow = createRateLimiter({ limit: 30 });

export async function portalIcsHandler(c) {
  applyCors(c, 'GET, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'GET') return c.json({ error: 'Method not allowed' }, 405);
  if (!allow(clientIp(c))) return c.json({ error: 'Too many requests.' }, 429);

  const token = c.req.query('p');
  const jobId = c.req.query('j');
  if (!token || !jobId) return c.json({ error: 'Missing link parameters.' }, 400);

  let out;
  try {
    out = await portalIcsCore(c.env, { token, jobId, stampUtc: new Date().toISOString() });
  } catch (err) {
    console.error('[estimate/portal-ics] failed:', err.message);
    return c.json({ error: 'Database error' }, 500);
  }
  if (!out.ok) return c.json({ error: out.error }, out.status);
  return c.body(out.ics, 200, {
    'Content-Type': 'text/calendar; charset=utf-8',
    'Content-Disposition': 'attachment; filename="appointment.ics"',
  });
}
```

- [ ] **Step 5: Register the route** — in `backend-workers/src/index.js`, add the import beside the other estimate imports (after line 44):

```js
import { portalIcsHandler } from './routes/estimate/portalIcs.js';
```

and the route line immediately after `portal-view` (line 75), before the `:action` catch-all:

```js
app.all('/api/estimate/portal-ics', portalIcsHandler);
```

- [ ] **Step 6: Run to verify it passes** — `npx jest portalIcsWorkers 2>&1 | tail -5` → PASS (8 tests total in the file).

- [ ] **Step 7: Full gate, then commit**

```bash
git add backend-workers/lib/estimate/portalIcs.js backend-workers/src/routes/estimate/portalIcs.js backend-workers/src/index.js __tests__/portalIcsWorkers.test.js
git commit -m "feat(portal): portal-ics endpoint for appointment add-to-calendar"
```

---

## Out of this plan (later Phase 12 sub-phases, planned at their own gates)

- **B:** photos (`JobPhoto.customerVisible`, signed URLs, `PORTAL_URL_SIGNING_SECRET`, JobDetail toggle)
- **C:** `portal-request` write path + `portal_access_log`
- **D:** `portal_tokens` server-owned table + mint/manage endpoints + CustomerDetail rework
- **E:** portal.html sections (tradeready-legal), deploy, owner smoke script

Deployment note for Phase A alone: it is safe to deploy the Worker at any point after merge — all changes are additive JSON keys plus one new endpoint; the live portal.html simply ignores them until Phase E ships.

## Self-review notes

- Spec coverage: §1 rows 1–5 map to Tasks 1–5; §2 proposed schema matches Task 1's exact-keys tests (photos deliberately absent — Phase B); §4 ICS decision D6 → Task 4.
- Type consistency: `assemblePortalView` param names match Task 3's call site; `portalIcsCore` return shape matches Task 5's route mapping; `buildJobIcs` args match core call.
- The `nextApproval`/write-path surface is untouched — Phase A adds zero write paths, keeping portalStore's READ-ONLY contract literal.
