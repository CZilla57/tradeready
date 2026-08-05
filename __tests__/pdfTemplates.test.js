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
//
// toContain/not.toContain assertions can pin CONTENT but cannot detect a
// whitespace-only regression — see the golden-fixture block below, which is
// what actually proves byte-identity.

import { invoiceHtml, estimateHtml } from "../utils/pdfTemplates";
import {
  GOLDEN_UNTOUCHED_UNPAID,
  GOLDEN_LEGACY_PAID,
  GOLDEN_VOIDED_ONLY,
  GOLDEN_ESTIMATE,
} from "../__fixtures__/invoiceHtmlGolden";

const inv = (over) => ({
  id: "i1", customer: "Acme", number: "INV-1", desc: "Work done",
  email: "", phone: "", amount: 1000, due: "2026-07-01", paid: false, ...over,
});

const pmt = (over) => ({ id: "p1", amount: 400, date: "2026-06-20", method: "cash", ...over });

// Pinned to the same instant used to capture the goldens in
// __fixtures__/invoiceHtmlGolden.js. invoiceHtml/estimateHtml stamp an issue
// date from `new Date()`, so the clock must match exactly or the comparison
// fails spuriously every day.
const PINNED_NOW = new Date(2026, 6, 15, 12, 0, 0);

beforeEach(() => {
  jest.useFakeTimers();
  jest.setSystemTime(PINNED_NOW);
});

afterEach(() => {
  jest.useRealTimers();
});

describe("invoiceHtml — byte-identical to commit fbadd88 (pre-balance-block)", () => {
  // These goldens were captured by running fbadd88's pdfTemplates.ts (the
  // last commit before db70741 added the balance block, the Partly-paid
  // badge, and the payment-history table) against these exact three shapes.
  // A diff here means an already-emailed, archived customer PDF would
  // re-render differently than what the customer originally received —
  // exactly the regression Finding 1 found (extra blank lines around the
  // total block, introduced by the template-literal restructuring).
  // One deliberate departure from fbadd88 output: due dates render the
  // entered calendar date in every timezone (fmtDate → parseLocalDate,
  // re-pinned 2026-08-02 — see the fixture header). fbadd88 rendered them
  // a day early on US machines, which is the bug, not the baseline.
  test("an untouched unpaid invoice renders byte-identically to pre-change output", () => {
    expect(invoiceHtml(inv())).toBe(GOLDEN_UNTOUCHED_UNPAID);
  });

  test("a legacy paid invoice renders byte-identically to pre-change output", () => {
    expect(invoiceHtml(inv({ paid: true, paidAt: "2026-06-15", payments: undefined }))).toBe(GOLDEN_LEGACY_PAID);
  });

  test("an invoice whose only payment is voided renders byte-identically to pre-change output", () => {
    expect(invoiceHtml(inv({
      payments: [pmt({ id: "p1", amount: 400, voidedAt: "2026-07-01" })],
    }))).toBe(GOLDEN_VOIDED_ONLY);
  });
});

describe("estimateHtml — byte-identical to commit fbadd88 (Finding 3: CSS relocation)", () => {
  // Moving the invoice-only CSS (badge-partial/history/sub-row) out of
  // BASE_CSS must not change estimateHtml's output at all — estimateHtml
  // never referenced those classes, so this pins that the relocation didn't
  // leak anything back in.
  test("renders byte-identically to pre-change output", () => {
    const job = {
      id: "j1",
      title: "Kitchen faucet repair",
      customerName: "Acme",
      laborHours: 2,
      laborRate: 50,
      materials: [],
      materialMarkup: 0,
      estimateTotal: 150,
    };
    expect(estimateHtml(job)).toBe(GOLDEN_ESTIMATE);
  });
});

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

describe("invoiceHtml — change order line items", () => {
  test("renders change-order line items on the invoice", () => {
    const html = invoiceHtml(inv({
      lineItems: [
        { description: "Labor — 4 hrs @ $85/hr", amount: 340, category: "labor" },
        { description: "Change order — Rotted subfloor", amount: 850, category: "other" },
      ],
    }));
    expect(html).toContain("Change order — Rotted subfloor");
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
