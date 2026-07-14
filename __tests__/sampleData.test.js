// Sample-data id namespacing. Legacy seeds shipped fixed ids (c1, j1, "1"…);
// on per-user cloud tables with a global PK those collide across accounts and
// RLS rejects every push (the wedged "7 changes pending" TestFlight finding).

const {
  LEGACY_SAMPLE_IDS,
  freshSampleSuffix,
  isSampleId,
  rewriteSampleIds,
  relinkCustomerIds,
} = require("../utils/sampleData");

describe("freshSampleSuffix", () => {
  test("produces distinct, pattern-conforming suffixes", () => {
    const a = freshSampleSuffix();
    const b = freshSampleSuffix();
    expect(a).toMatch(/^s[a-z0-9]+$/);
    expect(a).not.toBe(b);
  });
});

describe("isSampleId", () => {
  test("matches legacy fixed ids", () => {
    for (const id of ["c1", "c2", "c3", "j1", "j2", "j3", "1", "2", "3", "4"]) {
      expect(isSampleId(id)).toBe(true);
    }
  });

  test("matches namespaced sample ids", () => {
    expect(isSampleId("c1-sabc123")).toBe(true);
    expect(isSampleId("4-sz9y8x7")).toBe(true);
  });

  test("never matches real record ids", () => {
    expect(isSampleId("c1759171200000_1")).toBe(false); // real customer id shape
    expect(isSampleId("c10")).toBe(false);
    expect(isSampleId("42")).toBe(false);
    expect(isSampleId("INV-0042")).toBe(false);
    expect(isSampleId("j1759171200000")).toBe(false);
    expect(isSampleId("")).toBe(false);
  });
});

describe("rewriteSampleIds", () => {
  test("namespaces legacy ids and records the mapping", () => {
    const idMap = {};
    const { changed, records } = rewriteSampleIds(
      [{ id: "c1", name: "A" }, { id: "c1759171200000_1", name: "Real" }],
      "sabc123",
      idMap
    );
    expect(changed).toBe(true);
    expect(records[0].id).toBe("c1-sabc123");
    expect(records[1].id).toBe("c1759171200000_1"); // untouched
    expect(idMap).toEqual({ c1: "c1-sabc123" });
  });

  test("no-ops (changed=false) when nothing is legacy", () => {
    const idMap = {};
    const input = [{ id: "c1-solddone", name: "already namespaced" }];
    const { changed, records } = rewriteSampleIds(input, "snew", idMap);
    expect(changed).toBe(false);
    expect(records[0].id).toBe("c1-solddone");
    expect(idMap).toEqual({});
  });
});

describe("relinkCustomerIds", () => {
  test("follows the rewrite map on job.customerId", () => {
    const { changed, records } = relinkCustomerIds(
      [
        { id: "j1-sabc123", customerId: "c2" },
        { id: "jreal", customerId: "c1759171200000_1" },
        { id: "j2-sabc123" }, // no customerId at all
      ],
      { c2: "c2-sabc123" }
    );
    expect(changed).toBe(true);
    expect(records[0].customerId).toBe("c2-sabc123");
    expect(records[1].customerId).toBe("c1759171200000_1");
    expect(records[2].customerId).toBeUndefined();
  });

  test("no-ops when the map has nothing to apply", () => {
    const { changed } = relinkCustomerIds([{ id: "j1", customerId: "cX" }], {});
    expect(changed).toBe(false);
  });
});

describe("LEGACY_SAMPLE_IDS", () => {
  test("covers exactly the shipped seed ids", () => {
    expect([...LEGACY_SAMPLE_IDS].sort()).toEqual(
      ["1", "2", "3", "4", "c1", "c2", "c3", "j1", "j2", "j3"].sort()
    );
  });
});
