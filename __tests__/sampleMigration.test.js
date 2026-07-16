// __tests__/sampleMigration.test.js
// Recurring rules were left out of the sample-id remap until 2026-07-16, so a
// rule could dangle at a customerId the customers pass rewrote in an earlier
// run — and every job it generated inherited the dangling link ("no email on
// file" at estimate time). relinkDanglingRuleCustomers heals rules via the
// same-run idMap, else the normalized-name join, and never touches real ids.

import { relinkDanglingRuleCustomers } from "../utils/storage/sampleMigration";

// Isolate from sync side-effects (the module imports pruneQueueRecords).
jest.mock("../utils/sync", () => ({
  enqueue: jest.fn(),
  enqueueCollectionChanges: jest.fn(),
  trySync: jest.fn(),
  pruneQueueRecords: jest.fn(),
}));
jest.mock("../utils/notifications", () => ({ syncNotifications: jest.fn() }));

const customers = [
  { id: "c1-snew", name: "Riverside Bakery", email: "owner@riversidebakery.com" },
  { id: "c1751000000000_1", name: "Tom Nguyen", email: "tom@x.com" },
];

const rule = (overrides) => ({
  id: "rj_1",
  customerId: "",
  customerName: "",
  title: "Monthly service",
  ...overrides,
});

describe("relinkDanglingRuleCustomers", () => {
  test("same-run remaps follow the idMap", () => {
    const { changed, records } = relinkDanglingRuleCustomers(
      [rule({ customerId: "c1", customerName: "Riverside Bakery" })],
      customers,
      { c1: "c1-snew" },
    );
    expect(changed).toBe(true);
    expect(records[0].customerId).toBe("c1-snew");
  });

  test("stale sample-id dangles heal via the name join", () => {
    const { changed, records } = relinkDanglingRuleCustomers(
      [rule({ customerId: "c1-soldgone", customerName: "riverside bakery" })],
      customers,
      {},
    );
    expect(changed).toBe(true);
    expect(records[0].customerId).toBe("c1-snew");
  });

  test("sample ids that still exist are untouched", () => {
    const { changed } = relinkDanglingRuleCustomers(
      [rule({ customerId: "c1-snew", customerName: "Riverside Bakery" })],
      customers,
      {},
    );
    expect(changed).toBe(false);
  });

  test("real (non-sample) customerIds are never repointed, even when dangling", () => {
    const { changed, records } = relinkDanglingRuleCustomers(
      [rule({ customerId: "c1699000000000_9", customerName: "Riverside Bakery" })],
      customers,
      {},
    );
    expect(changed).toBe(false);
    expect(records[0].customerId).toBe("c1699000000000_9");
  });

  test("no name match leaves the rule unchanged; empty rules pass through", () => {
    const { changed, records } = relinkDanglingRuleCustomers(
      [
        rule({ customerId: "j1-sgone", customerName: "Nobody Known" }),
        rule({ customerId: "", customerName: "Riverside Bakery" }),
      ],
      customers,
      {},
    );
    expect(changed).toBe(false);
    expect(records[0].customerId).toBe("j1-sgone");
    expect(records[1].customerId).toBe("");
  });

  test("idempotent: a healed set reports no change on the second pass", () => {
    const first = relinkDanglingRuleCustomers(
      [rule({ customerId: "c1-soldgone", customerName: "Tom Nguyen" })],
      customers,
      {},
    );
    const second = relinkDanglingRuleCustomers(first.records, customers, {});
    expect(first.changed).toBe(true);
    expect(second.changed).toBe(false);
    expect(second.records[0].customerId).toBe("c1751000000000_1");
  });
});
