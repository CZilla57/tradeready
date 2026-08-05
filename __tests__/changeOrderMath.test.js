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
