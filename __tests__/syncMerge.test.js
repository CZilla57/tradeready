// __tests__/syncMerge.test.js
// Which tables merge and which replace. The invoices table unions payment
// ledgers (see mergePaymentLedgers); EVERY other table keeps the historical
// whole-record replace, and a test pins that so a future edit can't quietly
// widen merge behaviour to collections that don't expect it.

import { mergeRemoteRecord } from "../utils/syncMerge";

const invoice = (over) => ({
  id: "i1", customer: "Acme", number: "INV-1", desc: "", email: "", phone: "",
  amount: 1000, due: "2026-07-01", paid: false, ...over,
});

const pmt = (over) => ({ id: "p1", amount: 500, date: "2026-07-01", method: "cash", ...over });

describe("mergeRemoteRecord — invoices", () => {
  test("unions payments from both sides", () => {
    const local = invoice({ payments: [pmt({ id: "p1", amount: 400 })] });
    const remote = invoice({ payments: [pmt({ id: "stripe_cs_1", amount: 300, date: "2026-07-05" })] });
    const result = mergeRemoteRecord("invoices", local, remote);
    expect(result.payments).toHaveLength(2);
  });

  // Was "returns the remote record unchanged when there is no local copy".
  // Renamed because the contract itself changed: a `!local` remote invoice is
  // no longer passed through verbatim — it's routed through reconcilePaidFields
  // like every other invoice, so a stale `paid` from a queued device write that
  // predates a webhook payment doesn't survive onto a fresh install. Identity
  // is no longer guaranteed here; see the LEGACY test below for where it still
  // holds (empty ledger).
  test("derives paid from the ledger when there is no local copy, preserving the ledger", () => {
    const remote = invoice({ payments: [pmt({ id: "p1", amount: 400 })] });
    const result = mergeRemoteRecord("invoices", undefined, remote);
    expect(result).not.toBe(remote);
    expect(result.payments).toEqual(remote.payments);
    expect(result.paid).toBe(false); // $400 paid of $1000 due — not settled
  });

  test("a remote invoice with no local copy has paid derived from its ledger", () => {
    const remote = invoice({
      amount: 1000, paid: false,
      payments: [{ id: "p1", amount: 1000, date: "2026-07-01", method: "cash" }],
    });
    expect(mergeRemoteRecord("invoices", undefined, remote).paid).toBe(true);
  });

  test("a stale paid:true on a remote invoice with no local copy is re-opened", () => {
    const remote = invoice({
      amount: 1000, paid: true, paidAt: "2026-07-01",
      payments: [{ id: "p1", amount: 400, date: "2026-07-01", method: "cash" }],
    });
    const result = mergeRemoteRecord("invoices", undefined, remote);
    expect(result.paid).toBe(false);
    expect(result.paidAt).toBeUndefined();
  });

  test("a LEGACY remote invoice with no local copy passes through by reference", () => {
    // reconcilePaidFields returns the same object when the ledger is empty, so
    // legacy invoices are untouched and cheap.
    const remote = invoice({ amount: 1000, paid: true, paidAt: "2026-06-15" });
    expect(mergeRemoteRecord("invoices", undefined, remote)).toBe(remote);
  });
});

describe("mergeRemoteRecord — every other table replaces", () => {
  test.each(["jobs", "customers", "expenses", "pricebook"])(
    "%s takes the remote record wholesale, ignoring local",
    (table) => {
      const local = { id: "x1", title: "local version", payments: [pmt({ id: "p1" })] };
      const remote = { id: "x1", title: "remote version" };
      const result = mergeRemoteRecord(table, local, remote);
      // Identity, not just equality: these tables must not be reconstructed.
      expect(result).toBe(remote);
      expect(result.title).toBe("remote version");
      expect(result.payments).toBeUndefined();
    },
  );

  test("an unknown table name also replaces (safe default)", () => {
    const remote = { id: "x1", v: 2 };
    expect(mergeRemoteRecord("something_new", { id: "x1", v: 1 }, remote)).toBe(remote);
  });
});
