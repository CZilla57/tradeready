// utils/emailHtml — the shared escape-and-linkify for HTML email bodies.
// The label table is customer-facing copy; the escaping is the security edge
// (user-edited text goes straight into an HTML body).

const { emailHtmlFromText, labelForUrl } = require("../utils/emailHtml");

describe("labelForUrl", () => {
  it.each([
    ["https://gettradereadyapp.com/estimate.html?j=j1&t=tok", "View & approve your estimate"],
    ["https://gettradereadyapp.com/change.html?j=j1&co=c1&t=tok", "Review & approve this change"],
    ["https://gettradereadyapp.com/portal.html?p=tok", "View your jobs & invoices"],
    ["https://gettradereadyapp.com/book.html?b=tok", "Request a booking"],
    ["https://buy.stripe.com/abc123", "Pay online securely"],
    ["https://paypal.me/joe/850", "Pay with PayPal"],
    ["https://venmo.com/joe?txn=pay", "Pay with Venmo"],
    ["https://squareup.com/pay/xyz", "Pay online"],
  ])("labels %s", (url, label) => {
    expect(labelForUrl(url)).toBe(label);
  });

  it("returns null for unknown URLs", () => {
    expect(labelForUrl("https://example.com/anything")).toBeNull();
  });
});

describe("emailHtmlFromText", () => {
  it("escapes plain text and converts newlines to <br>", () => {
    expect(emailHtmlFromText('Hi "Dana" & Sam,\nSee below.')).toBe(
      "Hi &quot;Dana&quot; &amp; Sam,<br>See below.",
    );
  });

  it("replaces a known link with a labeled anchor — the raw URL never shows as text", () => {
    const url = "https://gettradereadyapp.com/estimate.html?j=j1&t=abcdef";
    const html = emailHtmlFromText(`View and approve your estimate here:\n${url}`);
    expect(html).toContain(
      '<a href="https://gettradereadyapp.com/estimate.html?j=j1&amp;t=abcdef">View &amp; approve your estimate</a>',
    );
    expect(html).not.toContain(url); // raw unescaped URL gone from visible text
  });

  it("keeps unknown URLs clickable with the URL as the label", () => {
    const html = emailHtmlFromText("Pay here: https://example.com/pay?a=1&b=2");
    expect(html).toBe(
      'Pay here: <a href="https://example.com/pay?a=1&amp;b=2">https://example.com/pay?a=1&amp;b=2</a>',
    );
  });

  it("leaves sentence punctuation after the URL out of the link", () => {
    const html = emailHtmlFromText("Pay at https://buy.stripe.com/abc.");
    expect(html).toBe('Pay at <a href="https://buy.stripe.com/abc">Pay online securely</a>.');
  });

  it("handles multiple links in one body", () => {
    const html = emailHtmlFromText(
      "Estimate: https://x.com/estimate.html?j=1&t=2 and pay https://buy.stripe.com/z",
    );
    expect(html).toContain(">View &amp; approve your estimate</a>");
    expect(html).toContain(">Pay online securely</a>");
  });

  it("passes through a body with no URLs unchanged (beyond escaping)", () => {
    expect(emailHtmlFromText("Just a note, no links.")).toBe("Just a note, no links.");
  });
});
