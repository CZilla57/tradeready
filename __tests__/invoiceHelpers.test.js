import {
  daysPastDue,
  getStatus,
  formatCurrency,
  buildPaymentLink,
} from "../utils/invoiceHelpers";

// Pin "today" so date-dependent tests are deterministic.
// Use Date constructor with explicit year/month/day so the mock is midnight in
// local time — the same reference point that daysPastDue uses.
const MOCK_TODAY = new Date(2025, 5, 15); // months are 0-indexed: 5 = June

beforeAll(() => {
  jest.useFakeTimers();
  jest.setSystemTime(MOCK_TODAY);
});

afterAll(() => {
  jest.useRealTimers();
});

describe("daysPastDue", () => {
  test("returns positive days when due date is in the past", () => {
    const days = daysPastDue("2025-06-01"); // 14 days ago
    expect(days).toBe(14);
  });

  test("returns 0 when due today", () => {
    const days = daysPastDue("2025-06-15");
    expect(days).toBe(0);
  });

  test("returns negative when due in the future", () => {
    const days = daysPastDue("2025-06-20");
    expect(days).toBeLessThan(0);
  });
});

describe("getStatus", () => {
  test("paid invoice always returns Paid regardless of due date", () => {
    const status = getStatus({ paid: true, due: "2020-01-01" });
    expect(status.label).toBe("Paid");
    expect(status.color).toBe("success");
    expect(status.days).toBe(0);
  });

  test("due today shows 'Due today'", () => {
    const status = getStatus({ paid: false, due: "2025-06-15" });
    expect(status.label).toBe("Due today");
    expect(status.color).toBe("accent");
  });

  test("overdue 14 days shows warning color", () => {
    const status = getStatus({ paid: false, due: "2025-06-01" });
    expect(status.label).toBe("14d overdue");
    expect(status.color).toBe("warning");
    expect(status.days).toBe(14);
  });

  test("overdue 15+ days shows danger color", () => {
    const status = getStatus({ paid: false, due: "2025-05-31" }); // 15 days ago
    expect(status.color).toBe("danger");
  });

  test("upcoming invoice shows 'Due soon'", () => {
    const status = getStatus({ paid: false, due: "2025-06-20" });
    expect(status.label).toBe("Due soon");
    expect(status.color).toBe("accent");
  });
});

describe("formatCurrency", () => {
  test("formats whole dollars without cents", () => {
    expect(formatCurrency(1500)).toMatch(/^\$1,500/);
  });

  test("formats zero", () => {
    expect(formatCurrency(0)).toMatch(/^\$0/);
  });

  test("large number has comma separator", () => {
    expect(formatCurrency(10000)).toMatch(/10,000/);
  });
});

describe("buildPaymentLink", () => {
  const invoice = {
    number: "INV-001",
    desc: "Plumbing repair",
    amount: 350,
    email: "customer@example.com",
  };

  test("stripe throws — no valid client-side fallback (providerKey is backend token, not a Stripe link slug)", () => {
    expect(() => buildPaymentLink(invoice, "stripe", "test_abc123")).toThrow(
      /backend to be configured/
    );
  });

  test("venmo link includes amount and username", () => {
    const link = buildPaymentLink(invoice, "venmo", "mytrades");
    expect(link).toContain("venmo.com");
    expect(link).toContain("350.00");
  });

  test("paypal link references invoice number", () => {
    const link = buildPaymentLink(invoice, "paypal", "");
    expect(link).toContain("paypal.com");
    expect(link).toContain("INV-001");
  });

  test("square link includes amount", () => {
    const link = buildPaymentLink(invoice, "square", "sq_key");
    expect(link).toContain("squareup.com");
    expect(link).toContain("350.00");
  });

  test("unknown provider uses providerKey as base URL", () => {
    const link = buildPaymentLink(invoice, "custom", "https://mypayments.com");
    expect(link).toContain("mypayments.com");
    expect(link).toContain("INV-001");
  });

  test("unknown provider with empty key uses YOUR_KEY default", () => {
    // The source does: const key = providerKey || "YOUR_KEY"
    // so an empty string still gets the "YOUR_KEY" sentinel, not the placeholder URL.
    const link = buildPaymentLink(invoice, "custom", "");
    expect(link).toContain("YOUR_KEY");
    expect(link).toContain("INV-001");
  });
});
