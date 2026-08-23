// Phase 4 — trade-aware pricebook templates. Templates are STRUCTURE, never
// numbers: no rates, waste %, coverage, minimums, or compliance claims. These
// tests pin the catalog shape, the guardrail (no baked figures), and the
// pure applyTemplate seeding.

import {
  TRADE_TEMPLATES,
  templatesForTrade,
  applyTemplate,
} from "../utils/tradeTemplates";

describe("TRADE_TEMPLATES catalog", () => {
  test("covers all seven article trades", () => {
    const ids = TRADE_TEMPLATES.map((t) => t.id).sort();
    expect(ids).toEqual(
      ["drywall", "electrical", "flooring", "handyman", "landscaping", "painting", "plumbing"].sort(),
    );
  });

  test("every template has a name and a non-empty scope checklist", () => {
    for (const t of TRADE_TEMPLATES) {
      expect(t.name.trim().length).toBeGreaterThan(0);
      expect(t.scopeChecklist.length).toBeGreaterThan(0);
    }
  });

  // The load-bearing guardrail: no invented rates, waste %, coverage figures,
  // minimums, or legal requirements may ship inside a template.
  test("no template bakes in a number, dollar, or percent (guardrail)", () => {
    const forbidden = /[\d$%]/;
    for (const t of TRADE_TEMPLATES) {
      expect(t.name).not.toMatch(forbidden);
      for (const q of t.scopeChecklist) expect(q).not.toMatch(forbidden);
      for (const m of t.seedMaterials) expect(m.name).not.toMatch(forbidden);
      for (const c of t.seedJobCosts) expect(c.label).not.toMatch(forbidden);
    }
  });

  test("seeded direct costs use valid categories and policies only", () => {
    const cats = new Set(["permit", "disposal", "rental", "subcontractor", "delivery", "travel", "other"]);
    const policies = new Set(["passthrough", "in_margin_base"]);
    for (const t of TRADE_TEMPLATES) {
      for (const c of t.seedJobCosts) {
        expect(cats.has(c.category)).toBe(true);
        expect(policies.has(c.markupPolicy)).toBe(true);
      }
    }
  });

  test("electrical seeds a pass-through permit line", () => {
    const el = TRADE_TEMPLATES.find((t) => t.id === "electrical")!;
    const permit = el.seedJobCosts.find((c) => c.category === "permit");
    expect(permit).toBeDefined();
    expect(permit!.markupPolicy).toBe("passthrough");
  });
});

describe("templatesForTrade", () => {
  test("surfaces templates relevant to the trade first, but returns all", () => {
    const list = templatesForTrade("painting");
    expect(list.length).toBe(TRADE_TEMPLATES.length); // all browsable
    expect(list[0].id).toBe("painting"); // relevant one first
  });

  test("an unmapped trade still returns the full browsable catalog", () => {
    const list = templatesForTrade("cleaning");
    expect(list.length).toBe(TRADE_TEMPLATES.length);
  });
});

describe("applyTemplate", () => {
  test("seeds empty, editable material + direct-cost lines (no invented values)", () => {
    const el = TRADE_TEMPLATES.find((t) => t.id === "electrical")!;
    const { materials, jobCosts } = applyTemplate(el, 1000);

    for (const m of materials) {
      expect(m.quantity).toBe(1);
      expect(m.unitCost).toBe(0);
      expect(m.name.length).toBeGreaterThan(0);
      expect(m.id).toContain("1000");
    }
    for (const c of jobCosts) {
      expect(c.quantity).toBe(1);
      expect(c.unitCost).toBe(0);
      expect(c.markupPercent).toBe(0);
      expect(c.taxable).toBe(false);
      expect(c.customerVisible).toBe(true);
      expect(c.id).toContain("1000");
    }
  });

  test("generates unique ids across seeded lines", () => {
    const paint = TRADE_TEMPLATES.find((t) => t.id === "painting")!;
    const { materials } = applyTemplate(paint, 2000);
    const ids = materials.map((m) => m.id);
    expect(new Set(ids).size).toBe(ids.length);
  });
});
