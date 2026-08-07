import { buildCustomerImport, stripBatch } from "../utils/importEngine";
import type { Customer } from "../types/models";

const cols = (m: (string | null)[]) => m;

describe("buildCustomerImport", () => {
  test("creates new customers and stamps importBatchId only on created records", () => {
    const existing: Customer[] = [
      { id: "c1", name: "Ada Lovelace", email: "ada@x.com", phone: "", address: "", notes: "" },
    ];
    const rows = [
      ["Ada Lovelace", "", "555-9"],   // matches existing -> backfill phone, NOT stamped
      ["Grace Hopper", "grace@x.com", "555-2"], // new -> stamped
    ];
    const res = buildCustomerImport(rows, cols(["name", "email", "phone"]), existing, "batch1");

    const ada = res.records.find((c) => c.name === "Ada Lovelace")!;
    const grace = res.records.find((c) => c.name === "Grace Hopper")!;
    expect(ada.phone).toBe("555-9");            // blank field backfilled
    expect(ada.importBatchId).toBeUndefined();  // pre-existing: never stamped
    expect(grace.importBatchId).toBe("batch1"); // created: stamped
    expect(res.counts).toMatchObject({ created: 1, matched: 1, skip: 0 });
  });

  test("skips rows with no usable name", () => {
    const res = buildCustomerImport([["", "x@y.com"]], cols(["name", "email"]), [], "b");
    expect(res.counts.skip).toBe(1);
    expect(res.records).toHaveLength(0);
  });

  test("joins multiple headers mapped to name", () => {
    const res = buildCustomerImport([["Grace", "Hopper"]], cols(["name", "name"]), [], "b");
    expect(res.records[0].name).toBe("Grace Hopper");
  });
});

describe("stripBatch", () => {
  test("removes only records carrying the batch id", () => {
    const recs = [
      { id: "1", importBatchId: "b" },
      { id: "2" },
      { id: "3", importBatchId: "b" },
      { id: "4", importBatchId: "other" },
    ];
    expect(stripBatch(recs, "b").map((r) => r.id)).toEqual(["2", "4"]);
  });
});
