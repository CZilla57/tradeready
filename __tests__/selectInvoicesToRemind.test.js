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
});
