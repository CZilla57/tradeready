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

  test("returns the remote record unchanged when there is no local copy", () => {
    const remote = invoice({ payments: [pmt({ id: "p1", amount: 400 })] });
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
