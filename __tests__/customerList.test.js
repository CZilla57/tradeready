// __tests__/customerList.test.js
// Roadmap #7 (7.7): the unified customer list (roadmap #5 join + rollup),
// extracted from CustomersScreen. Locks in the id → name → derived-key join and
// the paid/unpaid spend rollup so the #5 identity behavior can't silently drift.

import { buildCustomerList } from "../utils/customerList";

const cust = (over) => ({ id: "", name: "", email: "", phone: "", address: "", notes: "", ...over });
const inv = (over) => ({
  id: "i", customer: "", number: "INV", amount: 0, due: "2026-01-01",
  email: "", phone: "", desc: "", paid: false, ...over,
});

describe("buildCustomerList", () => {
  test("joins invoices to a record by customerId and rolls up paid vs unpaid", () => {
    const list = buildCustomerList(
      [
        inv({ id: "i1", customer: "Acme", customerId: "c1", amount: 100, paid: true }),
        inv({ id: "i2", customer: "Acme", customerId: "c1", amount: 50, paid: false }),
      ],
      [cust({ id: "c1", name: "Acme", notes: "hi" })],
    );
    expect(list).toHaveLength(1);
    expect(list[0]).toMatchObject({
      id: "c1",
      totalSpent: 100,
      totalOwed: 50,
      isManual: true,
      notes: "hi",
    });
    expect(list[0].invoices).toHaveLength(2);
  });

  test("falls back to a normalized-name match when the invoice has no customerId", () => {
    const list = buildCustomerList(
      [inv({ id: "i1", customer: "  ACME ", amount: 200, paid: true })],
      [cust({ id: "c1", name: "Acme" })],
    );
    expect(list).toHaveLength(1);
    expect(list[0].id).toBe("c1"); // matched the record, not a derived key
    expect(list[0].totalSpent).toBe(200);
  });

  test("derives a name-keyed entry for an invoice-only customer", () => {
    const list = buildCustomerList(
      [inv({ id: "i1", customer: "Bob", amount: 75, paid: false })],
      [],
    );
    expect(list).toHaveLength(1);
    expect(list[0]).toMatchObject({ id: "bob", name: "Bob", totalOwed: 75, isManual: false });
  });

  test("sorts by lifetime spend, descending", () => {
    const list = buildCustomerList(
      [
        inv({ id: "i1", customer: "A", customerId: "cA", amount: 300, paid: true }),
        inv({ id: "i2", customer: "B", customerId: "cB", amount: 500, paid: true }),
      ],
      [cust({ id: "cA", name: "A" }), cust({ id: "cB", name: "B" })],
    );
    expect(list.map((c) => c.id)).toEqual(["cB", "cA"]);
  });

  test("a manual record with no invoices still appears with zero totals", () => {
    const list = buildCustomerList([], [cust({ id: "c1", name: "Empty", notes: "n" })]);
    expect(list).toEqual([
      expect.objectContaining({
        id: "c1", name: "Empty", notes: "n",
        invoices: [], totalSpent: 0, totalOwed: 0, isManual: true,
      }),
    ]);
  });

  test("backfills contact info from invoices onto a bare record", () => {
    const list = buildCustomerList(
      [inv({ id: "i1", customer: "Acme", customerId: "c1", email: "a@x.com", phone: "555", paid: true })],
      [cust({ id: "c1", name: "Acme", email: "", phone: "" })],
    );
    expect(list[0]).toMatchObject({ email: "a@x.com", phone: "555" });
  });

  test("skips an invoice with no customer name and no id", () => {
    expect(buildCustomerList([inv({ id: "i1", customer: "", amount: 100 })], [])).toEqual([]);
  });
});
