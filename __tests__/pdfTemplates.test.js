// __tests__/pdfTemplates.test.js
// First coverage for the invoice PDF builder.
//
// The load-bearing property is BYTE-IDENTICAL OUTPUT FOR PRE-EXISTING
// INVOICES. These documents get emailed and archived, so a silent rendering
// change to historical invoices would be its own problem. Every new element is
// gated, and the first three tests are what prove it.
//
// The customer's copy also deliberately excludes voided payments (internal
// bookkeeping — a mistyped entry, a bounced cheque) and the synthesized
// legacy_<id> entry (internal language about an app migration).

import { invoiceHtml } from "../utils/pdfTemplates";

const inv = (over) => ({
  id: "i1", customer: "Acme", number: "INV-1", desc: "Work done",
  email: "", phone: "", amount: 1000, due: "2026-07-01", paid: false, ...over,
});

const pmt = (over) => ({ id: "p1", amount: 400, date: "2026-06-20", method: "cash", ...over });

describe("invoiceHtml — pre-existing invoices are unchanged", () => {
  test("an untouched unpaid invoice keeps the single TOTAL DUE line", () => {
    const html = invoiceHtml(inv());
    expect(html).toContain("TOTAL DUE");
    expect(html).not.toContain("BALANCE DUE");
    expect(html).not.toContain("Paid to date");
    expect(html).toContain("Outstanding");
  });

  test("a legacy paid invoice keeps the single TOTAL DUE line and shows no history", () => {
    const html = invoiceHtml(inv({ paid: true, paidAt: "2026-06-15", payments: undefined }));
    expect(html).toContain("TOTAL DUE");
    expect(html).not.toContain("BALANCE DUE");
    // The synthesized legacy_ entry must never reach the customer's copy.
    expect(html).not.toContain("Recorded before payment history");
    expect(html).not.toContain("Payment history");
    expect(html).toContain("Paid");
  });

  test("a fully-paid ledger invoice keeps the single total but DOES show history", () => {
    const html = invoiceHtml(inv({
      paid: true,
      payments: [pmt({ id: "p1", amount: 400, date: "2026-06-20" }),
                 pmt({ id: "p2", amount: 600, date: "2026-07-20" })],
    }));
    expect(html).toContain("TOTAL DUE");
    expect(html).not.toContain("BALANCE DUE");
    expect(html).toContain("Payment history");
    expect(html).toContain("$400.00");
    expect(html).toContain("$600.00");
  });
});

describe("invoiceHtml — partly paid", () => {
  const partly = () => inv({ payments: [pmt({ amount: 400 })] });

  test("renders all three total lines with the right numbers", () => {
    const html = invoiceHtml(partly());
    expect(html).toContain("Invoice total");
    expect(html).toContain("Paid to date");
    expect(html).toContain("BALANCE DUE");
    expect(html).toContain("$1,000.00");   // invoice total
    expect(html).toContain("$400.00");     // paid to date
    expect(html).toContain("$600.00");     // balance
    expect(html).not.toContain("TOTAL DUE");
  });

  test("shows the Partly paid badge, not Paid or Outstanding", () => {
    const html = invoiceHtml(partly());
    expect(html).toContain("Partly paid");
    expect(html).toContain("badge-partial");
  });

  test("shows the payment history table", () => {
    const html = invoiceHtml(partly());
    expect(html).toContain("Payment history");
    expect(html).toContain("Cash");
  });
});

describe("invoiceHtml — history exclusions", () => {
  test("a voided payment does not appear on the customer's copy", () => {
    const html = invoiceHtml(inv({
      payments: [pmt({ id: "p1", amount: 400, date: "2026-06-20" }),
                 pmt({ id: "p2", amount: 250, date: "2026-06-25", voidedAt: "2026-07-01" })],
    }));
    expect(html).toContain("$400.00");
    expect(html).not.toContain("$250.00");
    expect(html).not.toContain("void");
    expect(html).not.toContain("Void");
  });

  test("a voided payment is excluded from the paid-to-date figure", () => {
    const html = invoiceHtml(inv({
      payments: [pmt({ id: "p1", amount: 400, date: "2026-06-20" }),
                 pmt({ id: "p2", amount: 250, date: "2026-06-25", voidedAt: "2026-07-01" })],
    }));
    // Balance is 1000 - 400 = 600, not 350.
    expect(html).toContain("$600.00");
    expect(html).not.toContain("$350.00");
  });

  test("an invoice whose only payment is voided renders as untouched", () => {
    const html = invoiceHtml(inv({
      payments: [pmt({ id: "p1", amount: 400, voidedAt: "2026-07-01" })],
    }));
    expect(html).toContain("TOTAL DUE");
    expect(html).not.toContain("BALANCE DUE");
    expect(html).not.toContain("Payment history");
  });
});
