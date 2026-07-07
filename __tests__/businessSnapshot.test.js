// __tests__/businessSnapshot.test.js
// Tests for aggregateSnapshot — the pure aggregation inside getBusinessSnapshot.
// Uses a pinned clock (July 6 2026) so revenue-window comparisons are deterministic.
// isOverdue() routes through daysPastDue (which calls new Date()), so we also pin
// the Jest system clock to the same moment.

import { aggregateSnapshot } from "../utils/businessSnapshot";

const NOW = new Date(2026, 6, 6); // July 6 2026

beforeAll(() => {
  jest.useFakeTimers();
  jest.setSystemTime(NOW);
});

afterAll(() => {
  jest.useRealTimers();
});

const inv = (over) => ({
  id: "i", customer: "C", number: "INV-1", amount: 0,
  due: "2026-07-01", email: "", phone: "", desc: "", paid: false, ...over,
});

const job = (over) => ({
  id: "j", customerId: "", customerName: "",
  title: "", description: "", status: "lead",
  scheduledDate: null, scheduledStartTime: null, scheduledEndTime: null,
  address: "", estimateTotal: 0, laborHours: 0, laborRate: 85,
  materials: [], materialMarkup: 20, overhead: 15, margin: 20,
  notes: "", invoiceId: null, createdAt: "2026-07-01", ...over,
});

const cust = (over) => ({ id: "", name: "", email: "", phone: "", address: "", notes: "", ...over });

describe("aggregateSnapshot", () => {
  test("revenueThisMonth and revenueLastMonth bucket by paidAt", () => {
    const snap = aggregateSnapshot(
      [
        inv({ id: "i1", paid: true, paidAt: "2026-07-02", amount: 500 }),
        inv({ id: "i2", paid: true, paidAt: "2026-06-30", amount: 200 }),
        inv({ id: "i3", paid: true, paidAt: "2026-05-15", amount: 100 }), // older — neither bucket
      ],
      [], [], NOW,
    );
    expect(snap.revenueThisMonth).toBe(500);
    expect(snap.revenueLastMonth).toBe(200);
  });

  test("falls back to due date when paidAt is absent", () => {
    const snap = aggregateSnapshot(
      [inv({ id: "i1", paid: true, due: "2026-07-05", amount: 300 })],
      [], [], NOW,
    );
    expect(snap.revenueThisMonth).toBe(300);
  });

  test("outstanding and overdue totals from unpaid invoices", () => {
    const snap = aggregateSnapshot(
      [
        inv({ id: "i1", paid: false, due: "2026-06-01", amount: 150 }), // overdue
        inv({ id: "i2", paid: false, due: "2026-07-06", amount: 100 }), // due today — NOT overdue
        inv({ id: "i3", paid: false, due: "2026-08-01", amount: 200 }), // future
      ],
      [], [], NOW,
    );
    expect(snap.outstandingTotal).toBe(450);
    expect(snap.overdueTotal).toBe(150);
    expect(snap.overdueCount).toBe(1);
  });

  test("active jobs counted by status; done jobs excluded", () => {
    const snap = aggregateSnapshot(
      [],
      [
        job({ id: "j1", status: "lead" }),
        job({ id: "j2", status: "lead" }),
        job({ id: "j3", status: "scheduled" }),
        job({ id: "j4", status: "complete" }), // done — not counted in active
      ],
      [], NOW,
    );
    expect(snap.activeJobsByStatus).toEqual({ lead: 2, scheduled: 1 });
  });

  test("avgCompletedJobValue averages estimateTotal for done jobs", () => {
    const snap = aggregateSnapshot(
      [],
      [
        job({ id: "j1", status: "complete", estimateTotal: 1000 }),
        job({ id: "j2", status: "paid", estimateTotal: 500 }),
        job({ id: "j3", status: "lead", estimateTotal: 800 }), // active — excluded
      ],
      [], NOW,
    );
    expect(snap.avgCompletedJobValue).toBe(750);
  });

  test("avgCompletedJobValue is 0 when no done jobs", () => {
    expect(aggregateSnapshot([], [], [], NOW).avgCompletedJobValue).toBe(0);
  });

  test("topCustomers reflects lifetime spend and amounts owed", () => {
    const snap = aggregateSnapshot(
      [
        inv({ id: "i1", customer: "A", customerId: "cA", amount: 500, paid: true, paidAt: "2026-01-01" }),
        inv({ id: "i2", customer: "B", customerId: "cB", amount: 200, paid: false, due: "2026-08-01" }),
      ],
      [],
      [cust({ id: "cA", name: "A" }), cust({ id: "cB", name: "B" })],
      NOW,
    );
    expect(snap.topCustomers[0]).toMatchObject({ name: "A", lifetimeSpend: 500, amountOwed: 0 });
    expect(snap.topCustomers[1]).toMatchObject({ name: "B", lifetimeSpend: 0, amountOwed: 200 });
    expect(snap.totalCustomers).toBe(2);
  });

  test("empty inputs produce an all-zero snapshot", () => {
    const snap = aggregateSnapshot([], [], [], NOW);
    expect(snap.revenueThisMonth).toBe(0);
    expect(snap.outstandingTotal).toBe(0);
    expect(snap.overdueCount).toBe(0);
    expect(snap.activeJobsByStatus).toEqual({});
    expect(snap.topCustomers).toEqual([]);
    expect(snap.avgCompletedJobValue).toBe(0);
    expect(snap.totalCustomers).toBe(0);
  });
});
