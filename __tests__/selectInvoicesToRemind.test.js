// __tests__/selectInvoicesToRemind.test.js
// First direct coverage for this pure function (previously untested). Focused
// on the job-completion gating added for pre-work deposits — a deposit
// invoice must not be auto-emailed as "overdue" while its job hasn't started
// or finished.

const { selectInvoicesToRemind } = require("../backend/lib/selectInvoicesToRemind");

const baseSettings = { autoSendEmailEnabled: true, rules: [{ days: 3 }] };
const today = new Date("2026-08-01");

function invoice(overrides) {
  return {
    id: "inv1",
    amount: 500,
    email: "jane@example.com",
    due: "2026-07-01", // well past the 3-day rule relative to `today`
    paid: false,
    ...overrides,
  };
}

describe("selectInvoicesToRemind — job-completion gating", () => {
  test("an invoice with no linked job is eligible (unchanged behavior)", () => {
    const result = selectInvoicesToRemind({
      invoices: [invoice({})],
      settings: baseSettings,
      alreadySentInvoiceIds: [],
      jobs: [],
      today,
    });
    expect(result.map((i) => i.id)).toEqual(["inv1"]);
  });

  test("a deposit invoice on a job that hasn't started is excluded", () => {
    const result = selectInvoicesToRemind({
      invoices: [invoice({ jobId: "job1" })],
      settings: baseSettings,
      alreadySentInvoiceIds: [],
      jobs: [{ id: "job1", status: "scheduled" }],
      today,
    });
    expect(result).toHaveLength(0);
  });

  test("the same invoice becomes eligible once its job is complete", () => {
    const result = selectInvoicesToRemind({
      invoices: [invoice({ jobId: "job1" })],
      settings: baseSettings,
      alreadySentInvoiceIds: [],
      jobs: [{ id: "job1", status: "complete" }],
      today,
    });
    expect(result.map((i) => i.id)).toEqual(["inv1"]);
  });

  test("an invoice whose linked job can no longer be found is eligible (fail-open)", () => {
    const result = selectInvoicesToRemind({
      invoices: [invoice({ jobId: "deleted-job" })],
      settings: baseSettings,
      alreadySentInvoiceIds: [],
      jobs: [],
      today,
    });
    expect(result.map((i) => i.id)).toEqual(["inv1"]);
  });

  test("an in_progress job's deposit invoice stays excluded even if already technically overdue", () => {
    const result = selectInvoicesToRemind({
      invoices: [invoice({ jobId: "job1", due: "2020-01-01" })],
      settings: baseSettings,
      alreadySentInvoiceIds: [],
      jobs: [{ id: "job1", status: "in_progress" }],
      today,
    });
    expect(result).toHaveLength(0);
  });

  test("an imported invoice is excluded even though an otherwise-identical non-imported invoice is returned", () => {
    // Vercel-copy parity with the backend-workers assertion below — the
    // `selectInvoicesToRemind` required at the top of this file IS the
    // backend/lib (Vercel) copy, kept dunning-consistent with the CF Workers
    // copy so neither cron auto-emails a customer over imported historical AR.
    const imported = invoice({ id: "inv-imported", importBatchId: "batch1" });
    const control = invoice({ id: "inv-control" });
    const result = selectInvoicesToRemind({
      invoices: [imported, control],
      settings: baseSettings,
      alreadySentInvoiceIds: [],
      jobs: [],
      today,
    });
    expect(result.map((i) => i.id)).toEqual(["inv-control"]);
  });
});

describe("selectInvoicesToRemind — imported invoices excluded from auto-dunning", () => {
  // This exclusion is Fix 1 of the CSV-import final-review wave, landed on
  // backend-workers/lib/selectInvoicesToRemind.js (the live CF Workers cron
  // path) — kept in parity with utils/notifications.ts' local scheduler. Test
  // against the backend-workers module specifically, distinct from the
  // `selectInvoicesToRemind` required at the top of this file.
  const { selectInvoicesToRemind: selectInvoicesToRemindWorkers } = require("../backend-workers/lib/selectInvoicesToRemind");

  test("an imported invoice is excluded even though an otherwise-identical non-imported invoice is returned", () => {
    const imported = invoice({ id: "inv-imported", importBatchId: "batch1" });
    const control = invoice({ id: "inv-control" });
    const result = selectInvoicesToRemindWorkers({
      invoices: [imported, control],
      settings: baseSettings,
      alreadySentInvoiceIds: [],
      jobs: [],
      today,
    });
    expect(result.map((i) => i.id)).toEqual(["inv-control"]);
  });
});
