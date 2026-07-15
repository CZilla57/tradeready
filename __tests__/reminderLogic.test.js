// __tests__/reminderLogic.test.js
// Unit tests for the Phase 2 backend reminder logic. The backend modules are
// plain CommonJS with no RN/Expo imports, so the app's Jest can require them
// directly — this keeps Phase 2 under the single app gate with no new deps.
const { daysPastDue, formatMoney } = require("../backend/lib/overdue");
const { selectInvoicesToRemind } = require("../backend/lib/selectInvoicesToRemind");
const { buildReminderEmail } = require("../backend/lib/reminderEmail");

// Fixed "today" so daysPastDue is deterministic. Local-time date (matches the
// app's daysPastDue, which uses setHours(0,0,0,0) in local time).
const TODAY = new Date(2026, 6, 15); // 2026-07-15

function inv(overrides = {}) {
  return {
    id: "i1",
    customer: "Alice",
    number: "INV-001",
    amount: 1200,
    due: "2026-07-01", // 14 days before TODAY
    email: "alice@example.com",
    paid: false,
    ...overrides,
  };
}

const settings = {
  autoSendEmailEnabled: true,
  rules: [{ days: 7 }, { days: 30 }],
  businessName: "Bob Plumbing",
  contactName: "Bob",
  email: "bob@bobplumbing.com",
  phone: "(555) 123-4567",
  paymentNotes: "We accept card, check, or bank transfer.",
};

describe("daysPastDue", () => {
  // Pass local Date objects (not "YYYY-MM-DD" strings) so the whole-day math is
  // timezone-independent — string dates parse as UTC and can shift the count by
  // a day depending on the machine TZ (see the repo's date-mock note).
  test("counts whole days from due to today", () => {
    expect(daysPastDue(new Date(2026, 6, 1), TODAY)).toBe(14);
    expect(daysPastDue(new Date(2026, 6, 15), TODAY)).toBe(0);
    expect(daysPastDue(new Date(2026, 6, 20), TODAY)).toBe(-5);
  });
});

describe("formatMoney", () => {
  test("formats a number as USD currency", () => {
    expect(formatMoney(1200)).toBe("$1,200.00");
  });
});

describe("selectInvoicesToRemind", () => {
  test("selects an eligible overdue invoice", () => {
    const out = selectInvoicesToRemind({ invoices: [inv()], settings, alreadySentInvoiceIds: [], today: TODAY });
    expect(out.map((i) => i.id)).toEqual(["i1"]);
  });

  test("returns none when the feature is off", () => {
    const out = selectInvoicesToRemind({ invoices: [inv()], settings: { ...settings, autoSendEmailEnabled: false }, alreadySentInvoiceIds: [], today: TODAY });
    expect(out).toEqual([]);
  });

  test("returns none when there are no reminder rules", () => {
    const out = selectInvoicesToRemind({ invoices: [inv()], settings: { ...settings, rules: [] }, alreadySentInvoiceIds: [], today: TODAY });
    expect(out).toEqual([]);
  });

  test("does not throw on a malformed (null) rule entry", () => {
    // A null/undefined rule element must not throw and abort the whole cron run;
    // it is treated as non-finite and the invoice is simply skipped.
    expect(() =>
      selectInvoicesToRemind({ invoices: [inv()], settings: { ...settings, rules: [null] }, alreadySentInvoiceIds: [], today: TODAY })
    ).not.toThrow();
    const out = selectInvoicesToRemind({ invoices: [inv()], settings: { ...settings, rules: [null] }, alreadySentInvoiceIds: [], today: TODAY });
    expect(out).toEqual([]);
  });

  test("excludes paid invoices", () => {
    const out = selectInvoicesToRemind({ invoices: [inv({ paid: true })], settings, alreadySentInvoiceIds: [], today: TODAY });
    expect(out).toEqual([]);
  });

  test("excludes invoices with no email", () => {
    const out = selectInvoicesToRemind({ invoices: [inv({ email: "" })], settings, alreadySentInvoiceIds: [], today: TODAY });
    expect(out).toEqual([]);
  });

  test("excludes invoices not yet at the earliest rule age", () => {
    // Earliest rule is 7 days; this invoice is only ~3 days overdue.
    const out = selectInvoicesToRemind({ invoices: [inv({ due: "2026-07-12" })], settings, alreadySentInvoiceIds: [], today: TODAY });
    expect(out).toEqual([]);
  });

  test("excludes invoices already reminded", () => {
    const out = selectInvoicesToRemind({ invoices: [inv()], settings, alreadySentInvoiceIds: ["i1"], today: TODAY });
    expect(out).toEqual([]);
  });
});

describe("buildReminderEmail", () => {
  test("builds a transactional reminder with the right envelope", () => {
    const email = buildReminderEmail({ invoice: inv(), settings, today: TODAY });
    expect(email.from).toBe("Bob Plumbing via TradeReady <reminders@gettradereadyapp.com>");
    expect(email.to).toEqual(["alice@example.com"]);
    expect(email.reply_to).toBe("bob@bobplumbing.com");
    expect(email.subject).toBe("Payment reminder – INV-001");
    expect(email.text).toContain("INV-001");
    expect(email.text).toMatch(/\d+ days past due/);
    expect(email.text).toContain("$1,200.00");
    expect(email.text).toContain("reply to this email");
  });

  test("includes the payment link only when present", () => {
    const withLink = buildReminderEmail({ invoice: inv({ paymentLinkUrl: "https://pay.example/abc" }), settings, today: TODAY });
    expect(withLink.text).toContain("https://pay.example/abc");
    const without = buildReminderEmail({ invoice: inv(), settings, today: TODAY });
    expect(without.text).not.toContain("pay securely here");
  });

  test("omits reply_to when the business has no email", () => {
    const email = buildReminderEmail({ invoice: inv(), settings: { ...settings, email: "" }, today: TODAY });
    expect(email.reply_to).toBeUndefined();
  });
});
