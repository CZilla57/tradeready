// __tests__/onMyWay.test.js
// buildOnMyWayMessage (utils/onMyWay.ts): the fixed SMS body for the
// on-my-way deep link (widget button + Siri intent, docs/widget-plan.md
// Phase 3-4).

import { buildOnMyWayMessage } from "../utils/onMyWay";

const job = (over = {}) => ({
  id: "j1",
  customerName: "Alice Johnson",
  address: "12 Oak St",
  ...over,
});

describe("buildOnMyWayMessage", () => {
  test("uses the customer's first name, business name, and address", () => {
    expect(buildOnMyWayMessage(job(), "Bob's Plumbing")).toBe(
      "Hi Alice, it's Bob's Plumbing — I'm on my way to 12 Oak St now. See you soon!"
    );
  });

  test("first name is only the first word of a multi-word customer name", () => {
    expect(buildOnMyWayMessage(job({ customerName: "Dr. Maria Lopez" }), "Acme HVAC")).toContain(
      "Hi Dr.,"
    );
  });

  test("falls back to 'your place' when the job has no address", () => {
    expect(buildOnMyWayMessage(job({ address: "" }), "Bob's Plumbing")).toBe(
      "Hi Alice, it's Bob's Plumbing — I'm on my way to your place now. See you soon!"
    );
  });

  test("a whitespace-only address also falls back to 'your place'", () => {
    expect(buildOnMyWayMessage(job({ address: "   " }), "Bob's Plumbing")).toBe(
      "Hi Alice, it's Bob's Plumbing — I'm on my way to your place now. See you soon!"
    );
  });

  test("collapses a double space left by an empty business name", () => {
    const message = buildOnMyWayMessage(job(), "");
    expect(message).not.toMatch(/ {2,}/);
    expect(message).toBe("Hi Alice, it's — I'm on my way to 12 Oak St now. See you soon!");
  });
});
