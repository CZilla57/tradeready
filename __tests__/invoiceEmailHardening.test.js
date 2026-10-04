// __tests__/invoiceEmailHardening.test.js
// The auto-invoice email template (2026-08-06 spec) and its abuse guards —
// sibling of reminderEmailHardening.test.js. Unattended mail from the
// verified domain: sanitized From, header-safe subject, pay link only when
// amount-matched AND allowlisted.

const { buildInvoiceEmail, SENDER } = require("../backend-workers/lib/invoiceEmail");

function inv(overrides = {}) {
  return {
    id: "invA",
    customer: "Jane Smith",
    number: "INV-0001",
    amount: 500,
    due: "2026-09-05",
    email: "jane@example.com",
    phone: "",
    desc: "Water heater swap",
    paid: false,
    lineItems: [
      { description: "Labor — 4 hrs @ $85/hr", amount: 340, category: "labor" },
      { description: "Materials (2 items)", amount: 100, category: "materials" },
      { description: "Change order — Extra valve", amount: 60, category: "other" },
    ],
    ...overrides,
  };
}

const settings = {
  businessName: "Smith Plumbing",
  contactName: "Sam Smith",
  email: "sam@smithplumbing.com",
  phone: "555-0100",
  paymentNotes: "We accept check, card, or bank transfer.",
};

describe("buildInvoiceEmail", () => {
  test("payload shape: from/to/subject/text/reply_to", () => {
    const email = buildInvoiceEmail({ invoice: inv(), settings });
    expect(email.from).toBe(`Smith Plumbing via TradeReady <${SENDER}>`);
    expect(email.to).toEqual(["jane@example.com"]);
    expect(email.subject).toBe("Invoice INV-0001 from Smith Plumbing");
    expect(email.reply_to).toBe("sam@smithplumbing.com");
    expect(email.text).toContain("Hi Jane Smith");
    expect(email.text).toContain("INV-0001");
    expect(email.text).toContain("$500.00");
    expect(email.text).toContain("due 2026-09-05");
    expect(email.text).toContain("We accept check");
  });

  test("line items are listed — including the change-order line", () => {
    const { text } = buildInvoiceEmail({ invoice: inv(), settings });
    expect(text).toContain("Labor — 4 hrs @ $85/hr: $340.00");
    expect(text).toContain("Materials (2 items): $100.00");
    expect(text).toContain("Change order — Extra valve: $60.00");
  });

  test("no lineItems → no breakdown lines, total still present", () => {
    const { text } = buildInvoiceEmail({ invoice: inv({ lineItems: undefined }), settings });
    expect(text).not.toContain("  - ");
    expect(text).toContain("$500.00");
  });

  test("malformed line-item entries are tolerated", () => {
    const { text } = buildInvoiceEmail({
      invoice: inv({ lineItems: [null, { amount: 10 }, { description: "Thing" }] }),
      settings,
    });
    expect(text).toContain("Item: $10.00");
    expect(text).toContain("Thing: $0.00");
  });

  test("partial payment names both numbers", () => {
    const { text } = buildInvoiceEmail({
      invoice: inv({ payments: [{ id: "p1", amount: 200, method: "card", receivedAt: "2026-08-05" }] }),
      settings,
    });
    expect(text).toContain("$300.00 of $500.00");
  });

  test("From-phrase sanitization: quotes/angles/CRLF stripped; empty → bare sender", () => {
    // sanitizeFromPhrase DELETES ["<>\r\n] (no space substitution), then
    // collapses whitespace — so `z>\r\nBcc` fuses to `zBcc`. What matters is
    // that no header-capable character survives in the display phrase.
    const hostile = { ...settings, businessName: 'Evil" <x@y.z>\r\nBcc: a@b.c' };
    expect(buildInvoiceEmail({ invoice: inv(), settings: hostile }).from).toBe(
      `Evil x@y.zBcc: a@b.c via TradeReady <${SENDER}>`
    );
    expect(buildInvoiceEmail({ invoice: inv(), settings: { ...settings, businessName: '"<>\r\n' } }).from).toBe(
      `TradeReady <${SENDER}>`
    );
  });

  test("subject is header-safe: CR/LF in synced data cannot smuggle a header", () => {
    const { subject } = buildInvoiceEmail({
      invoice: inv({ number: "INV-1\r\nBcc: a@b.c" }),
      settings,
    });
    expect(subject).not.toMatch(/[\r\n]/);
  });

  test("no reply_to when the owner has no email", () => {
    const { reply_to } = buildInvoiceEmail({ invoice: inv(), settings: { ...settings, email: "" } });
    expect(reply_to).toBeUndefined();
  });

  test("pay link included ONLY when amount matches the balance AND host is allowlisted https", () => {
    const linked = inv({ paymentLinkUrl: "https://buy.stripe.com/abc", paymentLinkAmount: 500 });
    expect(buildInvoiceEmail({ invoice: linked, settings }).text).toContain("https://buy.stripe.com/abc");

    // Amount mismatch (e.g. minted before an edit) → line dropped.
    const mismatched = inv({ paymentLinkUrl: "https://buy.stripe.com/abc", paymentLinkAmount: 400 });
    expect(buildInvoiceEmail({ invoice: mismatched, settings }).text).not.toContain("buy.stripe.com");

    // Disallowed host (legacy Square token link) → dropped.
    const square = inv({ paymentLinkUrl: "https://squareup.com/pay/SECRET", paymentLinkAmount: 500 });
    expect(buildInvoiceEmail({ invoice: square, settings }).text).not.toContain("squareup.com");

    // http (not https) → dropped.
    const insecure = inv({ paymentLinkUrl: "http://buy.stripe.com/abc", paymentLinkAmount: 500 });
    expect(buildInvoiceEmail({ invoice: insecure, settings }).text).not.toContain("buy.stripe.com");
  });

  test("dropping the link never drops the email", () => {
    const square = inv({ paymentLinkUrl: "https://squareup.com/pay/SECRET", paymentLinkAmount: 500 });
    const email = buildInvoiceEmail({ invoice: square, settings });
    expect(email.to).toEqual(["jane@example.com"]);
    expect(email.text).toContain("$500.00");
  });

  test("attachment present → email.attachments is set", () => {
    const email = buildInvoiceEmail({
      invoice: inv(),
      settings,
      attachment: { filename: "Invoice-INV-0001.pdf", content: "JVBERi0=" },
    });
    expect(email.attachments).toEqual([
      { filename: "Invoice-INV-0001.pdf", content: "JVBERi0=" },
    ]);
  });

  test("no attachment → no attachments key (guards the plain-send path)", () => {
    const email = buildInvoiceEmail({ invoice: inv(), settings });
    expect(email.attachments).toBeUndefined();
  });
});

// Phase 24 (card-on-file spec §4.10): when an active autopay enrollment will
// charge the invoice, the email says so and rewords the pay line. The
// autopay sweep precomputes `autopay`; the builder stays pure.
describe("buildInvoiceEmail — autopay line", () => {
  const PAY = "https://gettradereadyapp.com/pay.html?t=p.fake.sig";
  const MANAGE = "https://gettradereadyapp.com/pay.html?m=m.fake.sig";
  const autopay = { card: "Visa ending 4242", chargeOn: "2026-09-05", manageUrl: MANAGE };

  test("the pay page is an allowed link host (Worker copy)", () => {
    const email = buildInvoiceEmail({ invoice: inv({ paymentLinkUrl: PAY, paymentLinkAmount: 500 }), settings });
    expect(email.text).toContain(`You can pay securely here: ${PAY}`);
  });

  test("charged-automatically line, manage link, and the reworded pay line", () => {
    const email = buildInvoiceEmail({ invoice: inv({ paymentLinkUrl: PAY, paymentLinkAmount: 500 }), settings, autopay });
    expect(email.text).toContain(
      "This invoice will be charged automatically to your Visa ending 4242 on 2026-09-05. Nothing to do.\n" +
      `Manage automatic payments: ${MANAGE}`
    );
    expect(email.text).toContain(`Prefer to pay now with another card? ${PAY}`);
    expect(email.text).not.toContain("You can pay securely here");
  });

  test("a stale pay link drops only the pay line; the autopay line stays", () => {
    const email = buildInvoiceEmail({ invoice: inv({ paymentLinkUrl: PAY, paymentLinkAmount: 400 }), settings, autopay });
    expect(email.text).toContain("charged automatically");
    expect(email.text).not.toContain("Prefer to pay now");
  });

  test("a non-allowlisted manage URL is dropped, never mailed", () => {
    const email = buildInvoiceEmail({ invoice: inv(), settings, autopay: { ...autopay, manageUrl: "https://evil.example/pay.html?m=x" } });
    expect(email.text).toContain("charged automatically");
    expect(email.text).not.toContain("evil.example");
    expect(email.text).not.toContain("Manage automatic payments");
  });

  test("no autopay → unchanged email", () => {
    const a = buildInvoiceEmail({ invoice: inv(), settings });
    const b = buildInvoiceEmail({ invoice: inv(), settings, autopay: undefined });
    expect(b).toEqual(a);
    expect(a.text).not.toContain("automatically");
  });
});
