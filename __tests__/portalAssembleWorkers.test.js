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

const photoRows = [
  // Visible + uploaded → served
  { id: "p1_vis", data: { id: "p1_vis", jobId: "j_sched", createdAt: "2026-08-08", uploadedAt: "2026-08-08", customerVisible: true } },
  // Absent flag → hidden (fail closed)
  { id: "p2_absent", data: { id: "p2_absent", jobId: "j_sched", createdAt: "2026-08-08", uploadedAt: "2026-08-08" } },
  // Explicitly hidden
  { id: "p3_off", data: { id: "p3_off", jobId: "j_sched", createdAt: "2026-08-08", uploadedAt: "2026-08-08", customerVisible: false } },
  // Visible but not yet uploaded → bytes unknown, never offered
  { id: "p4_pending", data: { id: "p4_pending", jobId: "j_sched", createdAt: "2026-08-08", customerVisible: true } },
];

const SECRET = "s".repeat(32);

function assemble(over = {}) {
  return assemblePortalView({
    businessName: "B".repeat(150), customerRow, jobRows, invoiceRows, requestRows, photoRows,
    token: TOKEN, apiOrigin: ORIGIN, nowMs: NOW_MS, userId: "u1", photoSecret: SECRET, ...over,
  });
}

describe("assemblePortalView — whitelist boundary", () => {
  test("top level has exactly the seven keys", () => {
    expect(Object.keys(assemble()).sort()).toEqual(
      ["appointments", "businessName", "changeOrders", "customerName", "estimates", "invoices", "photos"]
    );
  });

  test("names are capped at 120", () => {
    const out = assemble();
    expect(out.businessName).toBe("B".repeat(120));
    expect(out.customerName).toBe("D".repeat(120));
  });

  test("every section's items carry exactly the whitelisted keys", () => {
    const out = assemble();
    expect(out.appointments.length).toBeGreaterThan(0);
    expect(out.estimates.length).toBeGreaterThan(0);
    expect(out.changeOrders.length).toBeGreaterThan(0);
    expect(out.invoices.length).toBeGreaterThan(0);
    for (const a of out.appointments)
      expect(Object.keys(a).sort()).toEqual(["date", "end", "icsUrl", "jobRef", "manageUrl", "start", "title"]);
    for (const e of out.estimates)
      expect(Object.keys(e).sort()).toEqual(["approvalUrl", "decision", "title", "total"]);
    for (const co of out.changeOrders)
      expect(Object.keys(co).sort()).toEqual(["amount", "changeUrl", "jobTitle", "status", "title"]);
    for (const i of out.invoices)
      expect(Object.keys(i).sort()).toEqual(["amount", "amountPaid", "balanceDue", "due", "number", "paid", "paidAt", "paymentLinkUrl"]);
    expect(out.photos.length).toBeGreaterThan(0);
    for (const p of out.photos)
      expect(Object.keys(p).sort()).toEqual(["jobTitle", "url"]);
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
    // Time-less appointments sort first within a day, like all-day calendar rows.
    expect(ids).toEqual(["j_yday", "j_sched2", "j_sched"]);
  });

  test("fields, ics url, and manage link only for active bookings", () => {
    const [, sched2, sched] = assemble().appointments;
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

describe("photos (Phase 12B — fail closed)", () => {
  const { verifyPhotoSignature, PHOTO_URL_TTL_SEC } = require("../backend-workers/lib/photoSign.js");

  test("only explicitly-visible, uploaded photos are served, with job title", () => {
    const out = assemble().photos;
    expect(out).toHaveLength(1);
    expect(out[0].jobTitle).toBe("Water heater swap");
    expect(out[0].url).toContain(`${ORIGIN}/api/photos-public/p1_vis?u=u1&e=`);
  });

  test("the embedded signature verifies for exactly the signed inputs", () => {
    const url = new URL(assemble().photos[0].url);
    const expiresAtSec = url.searchParams.get("e");
    const sig = url.searchParams.get("s");
    expect(Number(expiresAtSec)).toBe(Math.floor(NOW_MS / 1000) + PHOTO_URL_TTL_SEC);
    expect(verifyPhotoSignature({ secret: SECRET, userId: "u1", photoId: "p1_vis", expiresAtSec, sig, nowMs: NOW_MS })).toBe(true);
    expect(verifyPhotoSignature({ secret: SECRET, userId: "u1", photoId: "p2_absent", expiresAtSec, sig, nowMs: NOW_MS })).toBe(false);
  });

  test("no secret → empty photos section, everything else intact", () => {
    const out = assemble({ photoSecret: undefined });
    expect(out.photos).toEqual([]);
    expect(out.invoices.length).toBeGreaterThan(0);
  });
});
