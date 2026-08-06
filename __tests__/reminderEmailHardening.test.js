// __tests__/reminderEmailHardening.test.js
// Hardening tests for the unattended reminder-email path (2026-08-02 audit):
// payment-link host allowlist, recipient plausibility, From-phrase
// sanitization, and reminder-day clamping. Every URL/token fixture here is
// deliberately fake and low-entropy — realistic secret shapes trip the
// gitleaks history scan.
const {
  buildReminderEmail,
  isAllowedPaymentLink,
  sanitizeFromPhrase,
} = require("../backend/lib/reminderEmail");
const {
  selectInvoicesToRemind,
  isPlausibleEmail,
} = require("../backend/lib/selectInvoicesToRemind");
// backend-workers/lib/reminderEmail.js is the byte-identical mirror the live
// cron actually runs — header-safety assertions pin both copies.
const workers = require("../backend-workers/lib/reminderEmail");

// Fixed "today" so daysPastDue is deterministic (matches reminderLogic.test.js).
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

// Every link fixture is minted for the exact $1,200 balance so it passes the
// amount-match gate — these tests isolate the HOST decision.
function linkInv(url) {
  return inv({ paymentLinkUrl: url, paymentLinkAmount: 1200 });
}

const settings = {
  autoSendEmailEnabled: true,
  rules: [{ days: 7 }],
  businessName: "Bob Plumbing",
  contactName: "Bob",
  email: "bob@bobplumbing.com",
  phone: "(555) 123-4567",
};

describe("payment-link host allowlist", () => {
  test.each([
    "https://buy.stripe.com/fake-link-001",
    "https://checkout.stripe.com/c/fake-link-001",
    "https://paypal.me/fakebob",
    "https://venmo.com/fakebob",
    "https://square.link/u/fake-link-001",
    "https://checkout.square.site/fake-link-001",
  ])("keeps an allowlisted link: %s", (url) => {
    const email = buildReminderEmail({ invoice: linkInv(url), settings, today: TODAY });
    expect(email.text).toContain("pay securely here");
    expect(email.text).toContain(url);
  });

  test("keeps a www.-prefixed allowlisted host", () => {
    const url = "https://www.buy.stripe.com/fake-link-001";
    const email = buildReminderEmail({ invoice: linkInv(url), settings, today: TODAY });
    expect(email.text).toContain(url);
  });

  test("host matching is case-insensitive", () => {
    const url = "https://BUY.STRIPE.COM/fake-link-001";
    const email = buildReminderEmail({ invoice: linkInv(url), settings, today: TODAY });
    expect(email.text).toContain("pay securely here");
  });

  test("DROPS a squareup.com/pay link but still sends the reminder", () => {
    // Pre-2026-08 builds cached squareup.com/pay/<access token> links — the
    // whole reason squareup.com is excluded. The LINE goes; the email stays.
    const url = "https://squareup.com/pay/FAKE-CACHED-TOKEN-0000";
    const email = buildReminderEmail({ invoice: linkInv(url), settings, today: TODAY });
    expect(email.text).not.toContain("squareup.com");
    expect(email.text).not.toContain("pay securely here");
    // The reminder itself is intact.
    expect(email.subject).toBe("Payment reminder – INV-001");
    expect(email.text).toContain("INV-001");
    expect(email.text).toContain("$1,200.00");
    expect(email.text).toMatch(/14 days overdue/);
  });

  test.each([
    ["javascript: scheme", "javascript:alert(1)"],
    ["data: scheme", "data:text/html,fake-payload"],
    ["http on an allowlisted host", "http://buy.stripe.com/fake-link-001"],
    ["unknown host", "https://evil.example/pay/fake-link-001"],
    ["allowlisted host as a subdomain of an attacker domain", "https://buy.stripe.com.evil.example/fake-link-001"],
    ["unparseable URL", "not a url at all"],
  ])("DROPS a disallowed link (%s) without dropping the email", (_label, url) => {
    const email = buildReminderEmail({ invoice: linkInv(url), settings, today: TODAY });
    expect(email.text).not.toContain("pay securely here");
    expect(email.subject).toBe("Payment reminder – INV-001");
    expect(email.text).toContain("INV-001");
  });

  test("isAllowedPaymentLink fails closed on non-string junk", () => {
    expect(isAllowedPaymentLink(undefined)).toBe(false);
    expect(isAllowedPaymentLink(null)).toBe(false);
    expect(isAllowedPaymentLink(42)).toBe(false);
  });
});

describe("recipient plausibility", () => {
  test("a valid single address is still selected", () => {
    const out = selectInvoicesToRemind({ invoices: [inv()], settings, alreadySentInvoiceIds: [], today: TODAY });
    expect(out.map((i) => i.id)).toEqual(["i1"]);
  });

  test.each([
    ["comma-separated list", "alice@example.com, bob@example.com"],
    ["embedded space", "alice @example.com"],
    ["embedded newline", "alice@example.com\nbcc-fake@evil.example"],
    ["embedded CR", "alice@example.com\rbcc-fake@evil.example"],
    ["missing @", "alice.example.com"],
    ["missing domain dot", "alice@example"],
    ["angle-bracket form", "<alice@example.com>"],
  ])("skips an invoice whose email is invalid (%s) without throwing", (_label, email) => {
    const run = () =>
      selectInvoicesToRemind({ invoices: [inv({ email })], settings, alreadySentInvoiceIds: [], today: TODAY });
    expect(run).not.toThrow();
    expect(run()).toEqual([]);
  });

  test("isPlausibleEmail rejects non-strings and empties", () => {
    expect(isPlausibleEmail("alice@example.com")).toBe(true);
    expect(isPlausibleEmail("")).toBe(false);
    expect(isPlausibleEmail(undefined)).toBe(false);
    expect(isPlausibleEmail(null)).toBe(false);
  });
});

describe("From-phrase sanitization", () => {
  test("an honest business name passes through untouched", () => {
    const email = buildReminderEmail({ invoice: inv(), settings, today: TODAY });
    expect(email.from).toBe("Bob Plumbing via TradeReady <reminders@gettradereadyapp.com>");
  });

  test("strips double quotes from the display name", () => {
    const email = buildReminderEmail({
      invoice: inv(),
      settings: { ...settings, businessName: 'Bob "Totally Legit" Plumbing' },
      today: TODAY,
    });
    expect(email.from).toBe("Bob Totally Legit Plumbing via TradeReady <reminders@gettradereadyapp.com>");
  });

  test("strips angle brackets — the only < > in From belong to the real sender", () => {
    const email = buildReminderEmail({
      invoice: inv(),
      settings: { ...settings, businessName: "Bob <fake-sender@evil.example> Plumbing" },
      today: TODAY,
    });
    expect(email.from.match(/</g)).toHaveLength(1);
    expect(email.from.match(/>/g)).toHaveLength(1);
    expect(email.from).toContain("<reminders@gettradereadyapp.com>");
  });

  test("strips CR/LF — the From phrase can never smuggle a second header", () => {
    const email = buildReminderEmail({
      invoice: inv(),
      settings: { ...settings, businessName: "Bob Plumbing\r\nX-Fake-Header: injected" },
      today: TODAY,
    });
    expect(email.from).not.toMatch(/[\r\n]/);
  });

  test("a name that sanitizes away entirely degrades to the bare neutral sender", () => {
    for (const businessName of ['"<>"', "", undefined]) {
      const email = buildReminderEmail({
        invoice: inv(),
        settings: { ...settings, businessName },
        today: TODAY,
      });
      expect(email.from).toBe("TradeReady <reminders@gettradereadyapp.com>");
    }
  });

  test("caps the phrase length", () => {
    expect(sanitizeFromPhrase("A".repeat(500))).toHaveLength(80);
  });
});

describe("subject header safety", () => {
  // Mirrors the invoiceEmailHardening.test.js subject test: invoice.number is
  // user-synced data landing in a mail header.
  test.each([
    ["backend (Vercel)", buildReminderEmail],
    ["backend-workers (live cron)", workers.buildReminderEmail],
  ])("subject is header-safe: CR/LF in synced data cannot smuggle a header (%s)", (_label, build) => {
    const email = build({
      invoice: inv({ number: "INV-1\r\nBcc: a@b.c" }),
      settings,
      today: TODAY,
    });
    expect(email.subject).not.toMatch(/[\r\n]/);
  });
});

describe("reminder-day clamping", () => {
  test("a lone negative rule is treated as no rules — an overdue invoice does NOT fire", () => {
    const out = selectInvoicesToRemind({
      invoices: [inv()],
      settings: { ...settings, rules: [{ days: -5 }] },
      alreadySentInvoiceIds: [],
      today: TODAY,
    });
    expect(out).toEqual([]);
  });

  test("a lone negative rule cannot fire an invoice that is not even due yet", () => {
    // The actual exploit: earliest = -1000 made daysPastDue >= earliest true
    // for EVERY invoice, including future due dates, on every run.
    const out = selectInvoicesToRemind({
      invoices: [inv({ due: "2026-07-25" })], // due 10 days AFTER TODAY
      settings: { ...settings, rules: [{ days: -1000 }] },
      alreadySentInvoiceIds: [],
      today: TODAY,
    });
    expect(out).toEqual([]);
  });

  test("a negative rule alongside a valid one is ignored, not honored", () => {
    const mixed = { ...settings, rules: [{ days: -5 }, { days: 7 }] };
    // 14 days overdue — clears the valid 7-day rule, fires.
    const fires = selectInvoicesToRemind({ invoices: [inv()], settings: mixed, alreadySentInvoiceIds: [], today: TODAY });
    expect(fires.map((i) => i.id)).toEqual(["i1"]);
    // ~3 days overdue — under the valid rule; the -5 must not lower the bar.
    const held = selectInvoicesToRemind({
      invoices: [inv({ due: "2026-07-12" })],
      settings: mixed,
      alreadySentInvoiceIds: [],
      today: TODAY,
    });
    expect(held).toEqual([]);
  });

  test("valid day counts still fire, including zero", () => {
    // 0 is a legitimate "remind the day it goes past due" rule — the clamp is
    // >= 0, not > 0. (Tested against a clearly overdue invoice so the whole-
    // day math stays timezone-independent.)
    const out = selectInvoicesToRemind({
      invoices: [inv()],
      settings: { ...settings, rules: [{ days: 0 }] },
      alreadySentInvoiceIds: [],
      today: TODAY,
    });
    expect(out.map((i) => i.id)).toEqual(["i1"]);
  });
});
