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
  newPaymentId,
  materializeLegacyLedger,
  applyPayment,
  removePayment,
  paymentsInRange,
  collectedInRange,
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
  test("a float overpayment residual clamps to zero balance", () => {
    // 0.1 + 0.2 === 0.30000000000000004 — the classic float trap. Math.max(0, …)
    // already clamps the tiny negative to zero; this tests that path, not epsilon.
    const i = inv({
      amount: 0.3,
      payments: [pmt({ id: "p1", amount: 0.1 }), pmt({ id: "p2", amount: 0.2 })],
    });
    expect(isFullyPaid(i)).toBe(true);
    expect(balanceDue(i)).toBe(0);
  });
  test("a positive sub-cent shortfall still counts as fully paid (epsilon)", () => {
    // 0.003 short of the total. Only passes if isFullyPaid actually tolerates
    // PAID_EPSILON — an implementation comparing `balanceDue <= 0` would fail.
    const i = inv({ amount: 100, payments: [pmt({ amount: 99.997 })] });
    expect(balanceDue(i)).toBeGreaterThan(0);
    expect(isFullyPaid(i)).toBe(true);
    expect(isPartlyPaid(i)).toBe(false);
  });
});

describe("newPaymentId", () => {
  test("ids are unique even within the same millisecond", () => {
    const ids = new Set();
    for (let i = 0; i < 100; i++) ids.add(newPaymentId());
    expect(ids.size).toBe(100);
  });
  test("ids do not collide with the webhook's stripe_ namespace", () => {
    expect(newPaymentId().startsWith("stripe_")).toBe(false);
  });
});

describe("materializeLegacyLedger", () => {
  test("a legacy paid invoice becomes one payment for the full amount", () => {
    const ledger = materializeLegacyLedger(
      inv({ paid: true, amount: 1000, paidAt: "2026-06-15", payments: undefined }),
    );
    expect(ledger).toHaveLength(1);
    expect(ledger[0].amount).toBe(1000);
    expect(ledger[0].date).toBe("2026-06-15");
  });
  test("falls back to the due date when paidAt is absent", () => {
    const ledger = materializeLegacyLedger(
      inv({ paid: true, amount: 1000, due: "2026-07-01", payments: undefined }),
    );
    expect(ledger[0].date).toBe("2026-07-01");
  });
  test("a legacy unpaid invoice yields an empty ledger", () => {
    expect(materializeLegacyLedger(inv({ paid: false }))).toEqual([]);
  });
  test("an existing ledger is returned as a copy, not the caller's live array", () => {
    const existing = [pmt({ amount: 400 })];
    const result = materializeLegacyLedger(inv({ payments: existing }));
    expect(result).not.toBe(existing);
    expect(result).toEqual(existing);
  });
});

describe("applyPayment", () => {
  test("appends to an empty invoice and leaves it unpaid", () => {
    const result = applyPayment(inv({ amount: 1000 }), pmt({ amount: 400 }));
    expect(result.payments).toHaveLength(1);
    expect(result.paid).toBe(false);
    expect(result.paidAt).toBeUndefined();
    expect(balanceDue(result)).toBe(600);
  });
  test("the payment that closes the balance sets paid and paidAt to ITS date", () => {
    const first = applyPayment(inv({ amount: 1000 }), pmt({ id: "p1", amount: 400, date: "2026-07-01" }));
    const second = applyPayment(first, pmt({ id: "p2", amount: 600, date: "2026-07-20" }));
    expect(second.paid).toBe(true);
    expect(second.paidAt).toBe("2026-07-20");
    expect(balanceDue(second)).toBe(0);
  });
  test("does NOT erase the original amount on a legacy paid invoice", () => {
    // The bug this guards: without materializing, amountPaid would fall from
    // 1000 to 50 the moment the ledger became non-empty.
    const legacy = inv({ paid: true, amount: 1000, paidAt: "2026-06-15", payments: undefined });
    const result = applyPayment(legacy, pmt({ id: "p2", amount: 50, date: "2026-07-02" }));
    expect(amountPaid(result)).toBe(1050);
    expect(result.payments).toHaveLength(2);
  });
  test("does not mutate the input invoice", () => {
    const original = inv({ amount: 1000 });
    applyPayment(original, pmt({ amount: 400 }));
    expect(original.payments).toBeUndefined();
    expect(original.paid).toBe(false);
  });
  test("does not mutate the input invoice's existing ledger array", () => {
    const original = inv({ amount: 1000, payments: [pmt({ id: "p1", amount: 400 })] });
    applyPayment(original, pmt({ id: "p2", amount: 600 }));
    expect(original.payments).toHaveLength(1);
    expect(original.payments[0]).toEqual(pmt({ id: "p1", amount: 400 }));
  });
  test("a single payment that overshoots the total settles the invoice", () => {
    const result = applyPayment(inv({ amount: 1000 }), pmt({ id: "p1", amount: 1200, date: "2026-07-05" }));
    expect(result.paid).toBe(true);
    expect(result.paidAt).toBe("2026-07-05");
    expect(balanceDue(result)).toBe(0);
  });
  test("applying a payment to an invoice with an empty ledger AND paid:true preserves the legacy amount", () => {
    const legacy = inv({ paid: true, amount: 1000, paidAt: "2026-06-15", payments: [] });
    const result = applyPayment(legacy, pmt({ id: "p2", amount: 50, date: "2026-07-02" }));
    expect(amountPaid(result)).toBe(1050);
  });
});

describe("removePayment", () => {
  test("removing a payment restores the balance", () => {
    const withPayment = applyPayment(inv({ amount: 1000 }), pmt({ id: "p1", amount: 400 }));
    const result = removePayment(withPayment, "p1");
    expect(result.payments).toHaveLength(0);
    expect(balanceDue(result)).toBe(1000);
  });
  test("removing the closing payment un-pays the invoice", () => {
    const first = applyPayment(inv({ amount: 1000 }), pmt({ id: "p1", amount: 400, date: "2026-07-01" }));
    const settled = applyPayment(first, pmt({ id: "p2", amount: 600, date: "2026-07-20" }));
    const result = removePayment(settled, "p2");
    expect(result.paid).toBe(false);
    expect(result.paidAt).toBeUndefined();
    expect(isPartlyPaid(result)).toBe(true);
  });
  test("removing a non-closing payment from a settled invoice keeps it unpaid-but-partial", () => {
    const first = applyPayment(inv({ amount: 1000 }), pmt({ id: "p1", amount: 400, date: "2026-07-01" }));
    const settled = applyPayment(first, pmt({ id: "p2", amount: 600, date: "2026-07-20" }));
    const result = removePayment(settled, "p1");
    expect(result.paid).toBe(false);
    expect(amountPaid(result)).toBe(600);
  });
  test("an unknown payment id is a no-op", () => {
    const withPayment = applyPayment(inv({ amount: 1000 }), pmt({ id: "p1", amount: 400 }));
    const result = removePayment(withPayment, "nope");
    expect(result.payments).toHaveLength(1);
  });
  test("does not mutate the input invoice", () => {
    const withPayment = applyPayment(inv({ amount: 1000 }), pmt({ id: "p1", amount: 400 }));
    removePayment(withPayment, "p1");
    expect(withPayment.payments).toHaveLength(1);
  });
  test("removing the only payment from a settled invoice un-pays it", () => {
    const settled = applyPayment(inv({ amount: 1000 }), pmt({ id: "p1", amount: 1000, date: "2026-07-01" }));
    const result = removePayment(settled, "p1");
    expect(result.paid).toBe(false);
    expect(result.paidAt).toBeUndefined();
    expect(amountPaid(result)).toBe(0);
    expect(balanceDue(result)).toBe(1000);
  });
  test("a legacy paid invoice can be un-paid by removing its materialized entry", () => {
    const legacy = inv({ id: "i1", paid: true, amount: 1000, paidAt: "2026-06-15", payments: undefined });
    const result = removePayment(legacy, "legacy_i1");
    expect(result.paid).toBe(false);
    expect(balanceDue(result)).toBe(1000);
  });
  test("a zero-amount invoice with an emptied ledger is not auto-marked paid", () => {
    // Pins the `payments.length > 0` guard in withDerivedPaidFields: without
    // it, `0 - 0 <= PAID_EPSILON` would mark an empty ledger as settled.
    const zero = inv({ amount: 0, paid: true, payments: [pmt({ id: "p1", amount: 0 })] });
    const result = removePayment(zero, "p1");
    expect(result.paid).toBe(false);
  });
});

describe("paidAt ordering — insertion order, not date order (pinned intentional behavior)", () => {
  test("a backdated payment recorded second still closes on ITS date, even though it precedes the first payment's date", () => {
    // p1 is recorded first with a LATER date; p2 is recorded second (backdated)
    // with an EARLIER date. Insertion order means p2 — the one that arrives
    // and crosses the balance — is the closing payment, even though its date
    // is earlier than p1's. This is the intended reading of "the payment that
    // closed the balance": it walks recording order, not calendar order.
    const first = applyPayment(inv({ amount: 1000 }), pmt({ id: "p1", amount: 400, date: "2026-07-20" }));
    const second = applyPayment(first, pmt({ id: "p2", amount: 600, date: "2026-07-01" }));
    expect(second.paid).toBe(true);
    expect(second.paidAt).toBe("2026-07-01");
  });
});

describe("paymentsInRange / collectedInRange", () => {
  const JULY_START = new Date(2026, 6, 1);
  const JULY_END = new Date(2026, 6, 31);

  test("includes payments inside the window", () => {
    const i = inv({ amount: 1000, payments: [pmt({ amount: 400, date: "2026-07-10" })] });
    expect(paymentsInRange(i, JULY_START, JULY_END)).toHaveLength(1);
  });
  test("excludes payments outside the window", () => {
    const i = inv({ amount: 1000, payments: [pmt({ amount: 400, date: "2026-06-10" })] });
    expect(paymentsInRange(i, JULY_START, JULY_END)).toHaveLength(0);
  });
  test("splits a part-paid invoice across two months", () => {
    const i = inv({
      amount: 1000,
      payments: [
        pmt({ id: "p1", amount: 400, date: "2026-06-20" }),
        pmt({ id: "p2", amount: 600, date: "2026-07-05" }),
      ],
    });
    expect(collectedInRange([i], JULY_START, JULY_END)).toBe(600);
    expect(collectedInRange([i], new Date(2026, 5, 1), new Date(2026, 5, 30))).toBe(400);
  });
  test("a legacy paid invoice buckets on paidAt, matching the old Money-tab math", () => {
    const i = inv({ paid: true, amount: 1000, paidAt: "2026-07-15", due: "2026-06-01" });
    expect(collectedInRange([i], JULY_START, JULY_END)).toBe(1000);
  });
  test("a legacy paid invoice with no paidAt falls back to due, as the old math did", () => {
    const i = inv({ paid: true, amount: 1000, paidAt: undefined, due: "2026-07-15" });
    expect(collectedInRange([i], JULY_START, JULY_END)).toBe(1000);
  });
  test("a legacy unpaid invoice contributes nothing", () => {
    expect(collectedInRange([inv({ paid: false, due: "2026-07-15" })], JULY_START, JULY_END)).toBe(0);
  });
  test("sums across several invoices", () => {
    const a = inv({ id: "a", amount: 1000, payments: [pmt({ id: "p1", amount: 400, date: "2026-07-10" })] });
    const b = inv({ id: "b", paid: true, amount: 250, paidAt: "2026-07-11" });
    expect(collectedInRange([a, b], JULY_START, JULY_END)).toBe(650);
  });
});
