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
  mergePaymentLedgers,
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

  test("applying the same payment id twice is a no-op (idempotent)", () => {
    const once = applyPayment(inv({ amount: 1000 }), pmt({ id: "p1", amount: 400, date: "2026-07-01" }));
    const twice = applyPayment(once, pmt({ id: "p1", amount: 400, date: "2026-07-01" }));
    expect(twice.payments).toHaveLength(1);
    expect(amountPaid(twice)).toBe(400);
  });

  test("a duplicate id does not overwrite the existing entry", () => {
    const once = applyPayment(inv({ amount: 1000 }), pmt({ id: "p1", amount: 400, date: "2026-07-01" }));
    const twice = applyPayment(once, pmt({ id: "p1", amount: 999, date: "2026-12-25", method: "card" }));
    expect(twice.payments).toHaveLength(1);
    expect(twice.payments[0].amount).toBe(400);
    expect(twice.payments[0].date).toBe("2026-07-01");
    expect(amountPaid(twice)).toBe(400);
  });

  test("a re-applied closing payment does not un-settle or double-count", () => {
    const first = applyPayment(inv({ amount: 1000 }), pmt({ id: "p1", amount: 400, date: "2026-07-01" }));
    const settled = applyPayment(first, pmt({ id: "p2", amount: 600, date: "2026-07-20" }));
    const replayed = applyPayment(settled, pmt({ id: "p2", amount: 600, date: "2026-07-20" }));
    expect(replayed.paid).toBe(true);
    expect(replayed.paidAt).toBe("2026-07-20");
    expect(amountPaid(replayed)).toBe(1000);
    expect(replayed.payments).toHaveLength(2);
  });

  test("a duplicate of a legacy materialized entry is not appended", () => {
    const legacy = inv({ id: "i1", paid: true, amount: 1000, paidAt: "2026-06-15", payments: undefined });
    const result = applyPayment(legacy, pmt({ id: "legacy_i1", amount: 1000, date: "2026-06-15" }));
    expect(result.payments).toHaveLength(1);
    expect(amountPaid(result)).toBe(1000);
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
