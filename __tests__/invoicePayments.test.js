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
