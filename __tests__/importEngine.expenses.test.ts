// __tests__/importEngine.expenses.test.ts
import { buildExpenseImport, mapExpenseCategory } from "../utils/importEngine";

const mapping = ["amount", "date", "description", "category"];

describe("mapExpenseCategory", () => {
  test("maps by keyword to a real category id", () => {
    expect(mapExpenseCategory("Materials").id).toBe("materials");
    expect(mapExpenseCategory("Fuel").id).toBe("fuel");
    expect(mapExpenseCategory("Software & Apps").id).toBe("software");
  });
  test("unrecognised → other, flagged", () => {
    const r = mapExpenseCategory("Misc Widget");
    expect(r.id).toBe("other");
    expect(r.recognized).toBe(false);
  });
});

describe("buildExpenseImport", () => {
  test("imports an expense with parsed local date and category", () => {
    const res = buildExpenseImport([["49.99", "07/04/2026", "Home Depot", "Materials"]], mapping, [], "b1", "MDY");
    const e = res.expenses[0];
    expect(e.amount).toBe(49.99);
    expect(e.date).toBe("2026-07-04");
    expect(e.category).toBe("materials");
    expect(e.receiptUri).toBeNull();
    expect(e.importBatchId).toBe("b1");
  });
  test("skips a row with an unparseable date", () => {
    const res = buildExpenseImport([["10", "garbage", "x", ""]], mapping, [], "b", "MDY");
    expect(res.counts.skip).toBe(1);
  });
  test("flags an unknown category but imports as other", () => {
    const res = buildExpenseImport([["10", "07/04/2026", "x", "Zorp"]], mapping, [], "b", "MDY");
    expect(res.expenses[0].category).toBe("other");
    expect(res.counts.flag).toBe(1);
  });
});
