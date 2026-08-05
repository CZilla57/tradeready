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
