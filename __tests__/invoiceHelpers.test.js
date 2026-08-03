import {
  daysPastDue,
  getStatus,
  buildPaymentLink,
  generateOutreachMessage,
  buildGenericEstimateMessage,
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

  test("counts calendar days exactly across a spring-forward DST boundary", () => {
    // US DST starts 2025-03-09. In a DST-observing zone the interval from
    // Mar 1 local midnight to Mar 15 local midnight is 14 days minus one
    // hour — Math.round must still report 14 (floor would say 13). In
    // non-DST zones (e.g. UTC on CI) this is trivially exact either way.
    jest.setSystemTime(new Date(2025, 2, 15)); // March 15
    expect(daysPastDue("2025-03-01")).toBe(14);
    jest.setSystemTime(MOCK_TODAY); // restore for later tests
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

describe("buildPaymentLink", () => {
  const invoice = {
    number: "INV-001",
    desc: "Plumbing repair",
    amount: 350,
    email: "customer@example.com",
  };

  test("stripe throws — no valid client-side fallback (providerKey is backend token, not a Stripe link slug)", () => {
    expect(() => buildPaymentLink(invoice, "stripe", "test_abc123", 350)).toThrow(
      /backend to be configured/
    );
  });

  test("venmo link includes amount and username", () => {
    const link = buildPaymentLink(invoice, "venmo", "mytrades", 350);
    expect(link).toContain("venmo.com");
    expect(link).toContain("350.00");
  });

  test("paypal.me link uses username and amount", () => {
    const link = buildPaymentLink(invoice, "paypal", "johndoe", 350);
    expect(link).toContain("paypal.me/johndoe");
    expect(link).toContain("350.00");
  });

  test("square uses the stored payment-page link, never squareup.com/pay", () => {
    const link = buildPaymentLink(invoice, "square", "https://square.link/u/abc123", 350);
    expect(link).toContain("square.link/u/abc123");
    expect(link).toContain("350.00");
    expect(link).not.toContain("squareup.com/pay");
  });

  test("square NEVER emits a legacy stored Access Token", () => {
    const link = buildPaymentLink(invoice, "square", "EAAAl_legacy_access_token", 350);
    expect(link).not.toContain("EAAAl_legacy_access_token");
  });

  test("unknown provider uses providerKey as base URL", () => {
    const link = buildPaymentLink(invoice, "custom", "https://mypayments.com", 350);
    expect(link).toContain("mypayments.com");
    expect(link).toContain("INV-001");
  });

  test("unknown provider with empty key falls back to example placeholder URL", () => {
    const link = buildPaymentLink(invoice, "custom", "", 350);
    expect(link).toContain("yourpaymentpage.com");
    expect(link).toContain("INV-001");
  });
});

describe("getStatus — partly paid", () => {
  const partly = (over) => ({
    id: "i1", customer: "Acme", number: "INV-1", desc: "", email: "", phone: "",
    amount: 1000, paid: false,
    payments: [{ id: "p1", amount: 400, date: "2025-06-01", method: "cash" }],
    ...over,
  });

  test("a partly-paid invoice not yet due reads 'Partly paid'", () => {
    const s = getStatus(partly({ due: "2025-06-20" }));
    expect(s.label).toBe("Partly paid");
    expect(s.color).toBe("accent");
  });

  test("a partly-paid invoice due today reads 'Partly paid'", () => {
    const s = getStatus(partly({ due: "2025-06-15" }));
    expect(s.label).toBe("Partly paid");
  });

  test("a partly-paid invoice PAST DUE still reads overdue, not 'Partly paid'", () => {
    // Overdue is the more urgent signal; the balance is shown next to the badge.
    const s = getStatus(partly({ due: "2025-06-01" }));
    expect(s.label).toMatch(/overdue/);
  });

  test("a fully-paid invoice still reads 'Paid'", () => {
    const s = getStatus(partly({
      due: "2025-06-01", paid: true,
      payments: [{ id: "p1", amount: 1000, date: "2025-06-01", method: "cash" }],
    }));
    expect(s.label).toBe("Paid");
  });

  test("an untouched unpaid invoice is unaffected", () => {
    const s = getStatus({ ...partly({ due: "2025-06-20" }), payments: undefined });
    expect(s.label).toBe("Due soon");
  });
});

describe("collection surfaces use the remaining balance", () => {
  // Dates below are chosen relative to MOCK_TODAY (2025-06-15, pinned above):
  // "2025-06-01" is 14 days in the past (overdue), matching the getStatus
  // conventions already used in this file.
  const partly = (over) => ({
    id: "i1", customer: "Acme", number: "INV-1", desc: "Work", email: "a@b.com", phone: "",
    amount: 1000, paid: false,
    payments: [{ id: "p1", amount: 400, date: "2025-06-01", method: "cash" }],
    ...over,
  });

  test("buildPaymentLink charges the requested amount — the caller passes the balance", () => {
    // The amount is now an explicit parameter (deposits can request less);
    // OutreachScreen derives the default as roundToCents(balanceDue(invoice)).
    const url = buildPaymentLink(partly({ due: "2025-08-01" }), "paypal", "someone", 600);
    expect(url).toContain("600");
    expect(url).not.toContain("1000");
  });

  test("the outreach message shows BOTH the balance and the invoice total", async () => {
    // No apiKey → generateOutreachMessage falls back to the generic builder,
    // which is the public entry point for this (buildGenericMessage itself
    // is not exported).
    const msg = await generateOutreachMessage({
      invoice: partly({ due: "2025-06-01" }), channel: "text", biz: { businessName: "Acme Co" },
    });
    expect(msg).toContain("$600.00");
    expect(msg).toContain("$1,000.00");
  });

  test("an untouched invoice's message is unchanged — one number only", async () => {
    const msg = await generateOutreachMessage({
      invoice: { ...partly({ due: "2025-06-01" }), payments: undefined },
      channel: "text", biz: { businessName: "Acme Co" },
    });
    expect(msg).toContain("$1,000.00");
    expect(msg).not.toContain("still outstanding");
  });

  test("a payment plan splits the REMAINING balance, not the original total", async () => {
    const msg = await generateOutreachMessage({
      invoice: partly({ due: "2025-06-01" }), channel: "text", biz: {},
      paymentPlan: { enabled: true, installments: 3, frequency: "Monthly" },
    });
    // $600 / 3 = $200, not $1000 / 3 = $333.33
    expect(msg).toContain("$200.00");
    expect(msg).not.toContain("$333.33");
  });
});

describe("deposit-aware outreach messages", () => {
  const unpaid = (over) => ({
    id: "i1", customer: "Acme", number: "INV-1", desc: "Work", email: "a@b.com", phone: "",
    amount: 1000, paid: false, due: "2025-06-20",
    ...over,
  });

  test("a deposit ask names the deposit amount and its percentage", async () => {
    const msg = await generateOutreachMessage({
      invoice: unpaid(), channel: "text", biz: { businessName: "Acme Co" },
      deposit: { amount: 500, percent: 50 },
    });
    expect(msg).toContain("deposit of $500.00");
    expect(msg).toContain("(50% of the total)");
  });

  test("a fixed-amount deposit omits the percentage", async () => {
    const msg = await generateOutreachMessage({
      invoice: unpaid(), channel: "text", biz: { businessName: "Acme Co" },
      deposit: { amount: 250 },
    });
    expect(msg).toContain("deposit of $250.00");
    expect(msg).not.toContain("% of the total");
  });

  test("with a payment link, the message says the link is for the deposit amount", async () => {
    const msg = await generateOutreachMessage({
      invoice: unpaid(), channel: "text", biz: { businessName: "Acme Co" },
      deposit: { amount: 500, percent: 50 },
      paymentLink: "https://pay.stripe.com/deposit_500",
    });
    expect(msg).toContain("the payment link is for that amount");
    expect(msg).toContain("https://pay.stripe.com/deposit_500");
  });

  test("the email variant carries the deposit line too", async () => {
    const msg = await generateOutreachMessage({
      invoice: unpaid(), channel: "email", biz: { businessName: "Acme Co", contactName: "Sam", phone: "555" },
      deposit: { amount: 500, percent: 50 },
      paymentLink: "https://pay.stripe.com/deposit_500",
    });
    expect(msg).toContain("deposit of $500.00");
    expect(msg).toContain("the payment link below is for that amount");
  });

  test("no deposit param means no deposit language (existing messages unchanged)", async () => {
    const msg = await generateOutreachMessage({
      invoice: unpaid(), channel: "text", biz: { businessName: "Acme Co" },
    });
    expect(msg).not.toContain("deposit");
  });
});

describe("buildGenericEstimateMessage", () => {
  it('includes the approval link in the generic estimate message', () => {
    const msg = buildGenericEstimateMessage({
      job: { title: 'X', laborHours: 1, laborRate: 1, materials: [], materialMarkup: 0, overhead: 0, margin: 0, estimateTotal: 1 },
      customer: { name: 'Sam' }, channel: 'text', biz: { businessName: 'Ace', phone: '5551234' },
      approvalLink: 'https://example.test/e?j=1&t=2',
    });
    expect(msg).toContain('https://example.test/e?j=1&t=2');
  });
});
