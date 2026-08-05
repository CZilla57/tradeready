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
