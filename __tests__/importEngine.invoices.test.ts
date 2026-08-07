// Pure-builder tests for invoice CSV import. See utils/importEngine.ts
// (buildInvoiceImport) for the money-semantics contract: legacy paid
// derivation (no fabricated ledger), paid-claim-without-date flagging,
// derived invoice numbering via utils/invoiceNumber.ts, and unique
// UTC-embedded issue-date ids recoverable via utils/pdfTemplates.ts
// invoiceIssueDate.

import { buildInvoiceImport } from "../utils/importEngine";
import { amountPaid, balanceDue } from "../utils/invoicePayments";
import { invoiceIssueDate } from "../utils/pdfTemplates";
import type { Customer, Invoice } from "../types/models";

// Column layout used by most cases below: customer, amount, number, due, paidAt.
const mapping = ["customer", "amount", "number", "due", "paidAt"];
const FIXED_NOW = Date.UTC(2026, 7, 1, 15, 0, 0); // 2026-08-01T15:00:00Z — deterministic clock

describe("buildInvoiceImport — paid semantics", () => {
  test("a paid invoice with a parseable paid date has NO fabricated ledger; legacy derivation matches", () => {
    const rows = [["Ada", "500", "INV-1", "06/01/2026", "06/15/2026"]];
    const res = buildInvoiceImport(rows, mapping, [], [], "b1", "MDY", undefined, FIXED_NOW);
    expect(res.invoices).toHaveLength(1);
    const inv = res.invoices[0];
    expect(inv.paid).toBe(true);
    expect(inv.paidAt).toBe("2026-06-15");
    expect(inv.payments).toBeUndefined();
    expect(amountPaid(inv)).toBe(500);
    expect(balanceDue(inv)).toBe(0);
    expect(inv.importBatchId).toBe("b1");
    expect(res.counts.ok).toBe(1);
    expect(res.counts.flag).toBe(0);
  });

  test("a paid CLAIM with no parseable paid date imports outstanding and flags the row", () => {
    const rows = [["Ada", "500", "INV-2", "06/01/2026", "Yes"]];
    const res = buildInvoiceImport(rows, mapping, [], [], "b2", "MDY", undefined, FIXED_NOW);
    const inv = res.invoices[0];
    expect(inv.paid).toBe(false);
    expect(inv.paidAt).toBeUndefined();
    expect(balanceDue(inv)).toBe(500);
    expect(res.counts.flag).toBe(1);
    const flagOutcome = res.outcomes.find((o) => o.status === "flag");
    expect(flagOutcome?.reason).toMatch(/paid but no paid date/i);
  });

  test("a plain open invoice (blank paid-date cell, no claim) is outstanding and NOT flagged", () => {
    const rows = [["Ada", "500", "INV-3", "06/01/2026", ""]];
    const res = buildInvoiceImport(rows, mapping, [], [], "b3", "MDY", undefined, FIXED_NOW);
    const inv = res.invoices[0];
    expect(inv.paid).toBe(false);
    expect(inv.due).toBe("2026-06-01");
    expect(res.counts.flag).toBe(0);
    expect(res.counts.ok).toBe(1);
  });

  test("an open invoice with no mapped/parseable due date falls back to today's local date", () => {
    const rows = [["Ada", "500", "", "not-a-date", ""]];
    const res = buildInvoiceImport(rows, mapping, [], [], "b4", "MDY", undefined, FIXED_NOW);
    const inv = res.invoices[0];
    expect(inv.due).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });
});

describe("buildInvoiceImport — numbering", () => {
  test("unmapped invoice numbers get sequential, distinct, correctly-shaped derived numbers", () => {
    const rows = [
      ["Ada", "100"],
      ["Bo", "200"],
    ];
    const res = buildInvoiceImport(rows, ["customer", "amount"], [], [], "b", null, undefined, FIXED_NOW);
    expect(res.invoices).toHaveLength(2);
    const [n1, n2] = res.invoices.map((i) => i.number);
    expect(n1).toMatch(/^INV-/);
    expect(n2).toMatch(/^INV-/);
    expect(n1).not.toBe(n2);
  });

  test("a mapped invoice number is kept verbatim", () => {
    const rows = [["Ada", "100", "CUSTOM-99"]];
    const res = buildInvoiceImport(
      rows,
      ["customer", "amount", "number"],
      [],
      [],
      "b",
      null,
      undefined,
      FIXED_NOW,
    );
    expect(res.invoices[0].number).toBe("CUSTOM-99");
  });
});

describe("buildInvoiceImport — invoice id uniqueness + issue-date recovery", () => {
  test("two rows sharing the same source date get DISTINCT ids that both round-trip via invoiceIssueDate", () => {
    const rows = [
      ["Ada", "100", "", "07/04/2026", ""],
      ["Bo", "200", "", "07/04/2026", ""],
    ];
    const res = buildInvoiceImport(rows, mapping, [], [], "b", "MDY", undefined, FIXED_NOW);
    expect(res.invoices).toHaveLength(2);
    const [a, b] = res.invoices;
    expect(a.id).not.toBe(b.id);
    expect(invoiceIssueDate(a.id).slice(0, 10)).toBe("2026-07-04");
    expect(invoiceIssueDate(b.id).slice(0, 10)).toBe("2026-07-04");
  });

  test("a row that would collide with an EXISTING invoice's id gets a distinct id that still round-trips", () => {
    // Pin the same date + row index + nowMs that a fresh import would compute
    // for row 0, then plant an existing invoice with exactly that id — a
    // cross-session same-ms-same-date collision.
    const collidingRows = [["Ada", "100", "", "07/04/2026", ""]];
    const probe = buildInvoiceImport(collidingRows, mapping, [], [], "probe", "MDY", undefined, FIXED_NOW);
    const collidingId = probe.invoices[0].id;
    const existingInvoices: Invoice[] = [
      {
        id: collidingId,
        customer: "Someone Else",
        customerId: "c-old",
        number: "INV-0",
        amount: 1,
        due: "2026-01-01",
        email: "",
        phone: "",
        desc: "",
        paid: false,
      },
    ];

    const res = buildInvoiceImport(collidingRows, mapping, [], existingInvoices, "b5", "MDY", undefined, FIXED_NOW);
    const inv = res.invoices.find((i) => i.customer === "Ada")!;

    expect(inv.id).not.toBe(collidingId);
    expect(invoiceIssueDate(inv.id).slice(0, 10)).toBe("2026-07-04");
  });
});

describe("buildInvoiceImport — required fields", () => {
  test("skips rows missing customer or amount", () => {
    const rows = [
      ["", "100", "", "", ""],
      ["Ada", "", "", "", ""],
    ];
    const res = buildInvoiceImport(rows, mapping, [], [], "b", "MDY", undefined, FIXED_NOW);
    expect(res.counts.skip).toBe(2);
    expect(res.invoices).toHaveLength(0);
  });
});

describe("buildInvoiceImport — customer join", () => {
  test("creates a new customer stamped with the batch id when no match exists", () => {
    const rows = [["Grace Hopper", "500", "", "", ""]];
    const res = buildInvoiceImport(rows, mapping, [], [], "b1", "MDY", undefined, FIXED_NOW);
    const cust = res.customers.find((c) => c.name === "Grace Hopper");
    expect(cust).toBeTruthy();
    expect(cust!.importBatchId).toBe("b1");
    expect(res.invoices[0].customerId).toBe(cust!.id);
    expect(res.invoices[0].customer).toBe("Grace Hopper");
  });

  test("joins an existing customer without stamping it or altering its data", () => {
    const existingCustomers: Customer[] = [
      { id: "c1", name: "Grace Hopper", email: "grace@example.com", phone: "555-1000", address: "1 Main St", notes: "VIP" },
    ];
    const rows = [["Grace Hopper", "500", "", "", ""]];
    const res = buildInvoiceImport(rows, mapping, existingCustomers, [], "b2", "MDY", undefined, FIXED_NOW);
    expect(res.customers).toHaveLength(1);
    const cust = res.customers[0];
    expect(cust.id).toBe("c1");
    expect(cust.importBatchId).toBeUndefined();
    expect(cust.email).toBe("grace@example.com");
    expect(cust.notes).toBe("VIP");
    expect(res.invoices[0].customerId).toBe("c1");
    expect(res.invoices[0].email).toBe("grace@example.com"); // snapshot backfilled from joined customer
  });
});
