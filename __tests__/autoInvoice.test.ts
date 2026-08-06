// __tests__/autoInvoice.test.ts
// The auto-invoice-on-complete flow and its shared invoice-from-job derivation
// (utils/autoInvoice.ts — 2026-08-03 spec). Pins:
//   1. Tracked-time billing gates: hourly-priced labor only, done statuses
//      only, completed sessions only, 2-decimal rounding.
//   2. The billable breakdown keeps the residual invariant — line items sum
//      to the invoice total — in both directions of the hour delta.
//   3. shouldAutoInvoice's opt-in + clean-create gates.
//   4. createAutoInvoiceForJob end-to-end: invoice saved, job advanced
//      complete → invoiced, running timer clocked out, null on unmet gates.

import AsyncStorage from "@react-native-async-storage/async-storage";
import {
  defaultDueDate,
  billableLaborHours,
  computeBillableBreakdown,
  buildInvoiceLineItems,
  prefillInvoiceDraftFromJob,
  shouldAutoInvoice,
  createAutoInvoiceForJob,
} from "../utils/autoInvoice";
import { roundToCents } from "../utils/invoicePayments";
import { resolvePaymentLink } from "../utils/invoiceHelpers";
import type { Job, Invoice, Settings, Customer, ChangeOrder } from "../types/models";

// Isolate storage from sync/notification/widget side-effects, same as
// storage.test.js — these tests assert on AsyncStorage state only.
jest.mock("../utils/sync", () => ({
  enqueue: jest.fn(),
  enqueueCollectionChanges: jest.fn(),
  trySync: jest.fn(),
}));

jest.mock("../utils/notifications", () => ({
  syncNotifications: jest.fn(),
}));

jest.mock("../utils/widgetBridge", () => ({
  refreshWidgetSnapshot: jest.fn().mockResolvedValue(undefined),
  clearWidgetSnapshot: jest.fn().mockResolvedValue(undefined),
}));

jest.mock("../utils/analytics", () => ({
  track: jest.fn(),
  reportError: jest.fn(),
}));

// requireActual is load-bearing: utils/storage/settings.ts imports
// isSquarePaymentLink from this same module — a bare factory would replace
// it with undefined and break every loadSettings call in this suite.
jest.mock("../utils/invoiceHelpers", () => ({
  ...jest.requireActual("../utils/invoiceHelpers"),
  resolvePaymentLink: jest.fn(),
  getProviderKey: jest.fn().mockReturnValue(""),
}));

// ── Fixtures ─────────────────────────────────────────────────────────────────

// The worked example from the trade-business docs: 4h @ $85 labor ($340),
// $300 materials +20% markup ($360), estimateTotal $966 → residual $266.
function makeJob(overrides: Partial<Job> = {}): Job {
  return {
    id: "j1",
    title: "Water heater swap",
    customerName: "Jane Smith",
    customerId: "c1",
    status: "complete",
    laborHours: 4,
    laborRate: 85,
    materials: [
      { name: "Heater", quantity: 1, unitCost: 200 },
      { name: "Fittings", quantity: 2, unitCost: 50 },
    ],
    materialMarkup: 20,
    estimateTotal: 966,
    ...overrides,
  } as Job;
}

/** hours → a closed session of exactly that length. */
function closedSession(hours: number, startIso = "2026-08-01T08:00:00.000Z") {
  const start = new Date(startIso);
  const end = new Date(start.getTime() + hours * 3600000);
  return { start: start.toISOString(), end: end.toISOString() };
}

function makeSettings(overrides: Partial<Settings> = {}): Settings {
  return { autoInvoiceOnComplete: true, ...overrides } as Settings;
}

// ── defaultDueDate ────────────────────────────────────────────────────────────

describe("defaultDueDate", () => {
  test("is 30 days after the given date, YYYY-MM-DD", () => {
    expect(defaultDueDate(new Date("2026-08-03T12:00:00Z"))).toBe("2026-09-02");
  });
});

// ── billableLaborHours ────────────────────────────────────────────────────────

describe("billableLaborHours", () => {
  test("no sessions → estimated hours, not tracked", () => {
    expect(billableLaborHours(makeJob())).toEqual({ hours: 4, usedTrackedTime: false });
  });

  test("completed sessions on a done, hourly-priced job → tracked hours", () => {
    const job = makeJob({ timeSessions: [closedSession(5.5)] });
    expect(billableLaborHours(job)).toEqual({ hours: 5.5, usedTrackedTime: true });
  });

  test("multiple sessions accumulate; a still-open session is excluded", () => {
    const job = makeJob({
      timeSessions: [
        closedSession(2),
        closedSession(1.5, "2026-08-01T13:00:00.000Z"),
        { start: "2026-08-01T16:00:00.000Z", end: null },
      ],
    });
    expect(billableLaborHours(job)).toEqual({ hours: 3.5, usedTrackedTime: true });
  });

  test("flat-priced job (laborHours 0) never bills tracked time", () => {
    const job = makeJob({ laborHours: 0, timeSessions: [closedSession(3)] });
    expect(billableLaborHours(job)).toEqual({ hours: 0, usedTrackedTime: false });
  });

  test("laborRate 0 never bills tracked time", () => {
    const job = makeJob({ laborRate: 0, timeSessions: [closedSession(3)] });
    expect(billableLaborHours(job)).toEqual({ hours: 4, usedTrackedTime: false });
  });

  test("pre-complete status (deposit territory) bills the estimate", () => {
    const job = makeJob({ status: "in_progress", timeSessions: [closedSession(3)] });
    expect(billableLaborHours(job)).toEqual({ hours: 4, usedTrackedTime: false });
  });

  test("tracked hours round to 2 decimals", () => {
    // 1h 10m 30s = 1.175h → 1.18
    const job = makeJob({ timeSessions: [closedSession(1.175)] });
    expect(billableLaborHours(job)).toEqual({ hours: 1.18, usedTrackedTime: true });
  });

  test("tracked time rounding to 0.00 falls back to the estimate", () => {
    // 10 seconds tracked rounds to 0 hours — not a billable replacement.
    const job = makeJob({ timeSessions: [closedSession(10 / 3600)] });
    expect(billableLaborHours(job)).toEqual({ hours: 4, usedTrackedTime: false });
  });
});

// ── computeBillableBreakdown ──────────────────────────────────────────────────

describe("computeBillableBreakdown", () => {
  test("without tracked time, mirrors the quoted breakdown", () => {
    const b = computeBillableBreakdown(makeJob());
    expect(b).toMatchObject({
      laborHours: 4,
      laborCost: 340,
      materialCost: 360,
      overheadLine: 266,
      usedTrackedTime: false,
      total: 966,
    });
  });

  test("tracked over estimate: total rises by the hour delta at the labor rate", () => {
    const b = computeBillableBreakdown(makeJob({ timeSessions: [closedSession(5.5)] }));
    expect(b.laborHours).toBe(5.5);
    expect(b.laborCost).toBe(467.5);
    expect(b.total).toBe(1093.5); // 966 + 1.5h × $85
    // Residual invariant: lines still sum to the total.
    expect(b.laborCost + b.materialCost + b.overheadLine).toBeCloseTo(b.total, 2);
  });

  test("tracked under estimate: total drops by the hour delta", () => {
    const b = computeBillableBreakdown(makeJob({ timeSessions: [closedSession(2)] }));
    expect(b.laborCost).toBe(170);
    expect(b.total).toBe(796); // 966 − 2h × $85
    expect(b.laborCost + b.materialCost + b.overheadLine).toBeCloseTo(b.total, 2);
  });
});

// ── buildInvoiceLineItems ─────────────────────────────────────────────────────

describe("buildInvoiceLineItems", () => {
  test("labor line bills tracked hours and lines sum to the billable total", () => {
    const job = makeJob({ timeSessions: [closedSession(5.5)] });
    const items = buildInvoiceLineItems(job);
    expect(items).toHaveLength(3);
    expect(items[0]).toEqual({
      description: "Labor — 5.5 hrs @ $85/hr",
      amount: 467.5,
      category: "labor",
    });
    expect(items[1]).toMatchObject({ amount: 360, category: "materials" });
    expect(items[2]).toMatchObject({ amount: 266, category: "overhead" });
    const sum = items.reduce((s, i) => s + i.amount, 0);
    expect(sum).toBeCloseTo(computeBillableBreakdown(job).total, 2);
  });

  test("without tracked time, matches the historical estimated-hours line", () => {
    const items = buildInvoiceLineItems(makeJob());
    expect(items[0]).toEqual({
      description: "Labor — 4 hrs @ $85/hr",
      amount: 340,
      category: "labor",
    });
  });
});

// ── shouldAutoInvoice ─────────────────────────────────────────────────────────

describe("shouldAutoInvoice", () => {
  test("all gates met → true", () => {
    expect(shouldAutoInvoice(makeJob(), makeSettings())).toBe(true);
  });

  test("toggle off (or absent) → false", () => {
    expect(shouldAutoInvoice(makeJob(), makeSettings({ autoInvoiceOnComplete: false }))).toBe(false);
    expect(shouldAutoInvoice(makeJob(), {} as Settings)).toBe(false);
  });

  test("existing invoice (deposit awaiting finalize) → false", () => {
    expect(shouldAutoInvoice(makeJob({ invoiceId: "inv9" }), makeSettings())).toBe(false);
  });

  test("no estimate total → false", () => {
    expect(shouldAutoInvoice(makeJob({ estimateTotal: 0 }), makeSettings())).toBe(false);
  });

  test("blank customer name → false", () => {
    expect(shouldAutoInvoice(makeJob({ customerName: "  " }), makeSettings())).toBe(false);
  });
});

// ── createAutoInvoiceForJob (end-to-end against mocked AsyncStorage) ──────────

let store: Record<string, string>;

function seed(jobs: Job[], invoices: Invoice[], customers: Customer[], settings: Partial<Settings>) {
  store = {
    jobs: JSON.stringify(jobs),
    invoices: JSON.stringify(invoices),
    customers: JSON.stringify(customers),
    expenses: JSON.stringify([]),
    settings: JSON.stringify(settings),
  };
}

const janeRecord = { id: "c1", name: "Jane Smith", email: "jane@example.com", phone: "555-0100" } as Customer;

beforeEach(() => {
  jest.clearAllMocks();
  store = {};
  (AsyncStorage.getItem as jest.Mock).mockImplementation((k: string) =>
    Promise.resolve(store[k] ?? null)
  );
  (AsyncStorage.setItem as jest.Mock).mockImplementation((k: string, v: string) => {
    store[k] = v;
    return Promise.resolve();
  });
});

function storedJobs(): Job[] {
  return JSON.parse(store.jobs);
}
function storedInvoices(): Invoice[] {
  return JSON.parse(store.invoices);
}

describe("createAutoInvoiceForJob", () => {
  test("happy path: saves the invoice and advances the job to invoiced", async () => {
    const job = makeJob({ timeSessions: [closedSession(5.5)] });
    seed([job], [], [janeRecord], { autoInvoiceOnComplete: true });

    const result = await createAutoInvoiceForJob("j1");

    expect(result).toBeTruthy();
    const invoiceId = result!.invoiceId;
    expect(result!.number).toBe("INV-0001");
    const invoices = storedInvoices();
    expect(invoices).toHaveLength(1);
    expect(invoices[0]).toMatchObject({
      id: invoiceId,
      customer: "Jane Smith",
      customerId: "c1",
      number: "INV-0001",
      amount: 1093.5,
      email: "jane@example.com",
      phone: "555-0100",
      desc: "Water heater swap",
      paid: false,
      jobId: "j1",
    });
    expect(invoices[0].lineItems).toHaveLength(3);

    const savedJob = storedJobs().find((j) => j.id === "j1");
    expect(savedJob?.status).toBe("invoiced");
    expect(savedJob?.invoiceId).toBe(invoiceId);
  });

  test("a still-running timer is clocked out and billed", async () => {
    // Open session started exactly 2h ago; clock-out happens at "now", so the
    // billed hours land at 2.0 (rounding absorbs test-execution drift).
    const job = makeJob({
      timeSessions: [{ start: new Date(Date.now() - 2 * 3600000).toISOString(), end: null }],
    });
    seed([job], [], [janeRecord], { autoInvoiceOnComplete: true });

    const result = await createAutoInvoiceForJob("j1");

    expect(result).toBeTruthy();
    const savedJob = storedJobs().find((j) => j.id === "j1");
    expect(savedJob?.timeSessions?.[0]?.end).toBeTruthy();
    expect(storedInvoices()[0].amount).toBe(796); // 966 − 2h × $85
  });

  test("toggle off → null and nothing written", async () => {
    seed([makeJob()], [], [janeRecord], { autoInvoiceOnComplete: false });

    expect(await createAutoInvoiceForJob("j1")).toBeNull();
    expect(storedInvoices()).toHaveLength(0);
    expect(storedJobs()[0].status).toBe("complete");
  });

  test("job not at complete → null (deposit territory stays manual)", async () => {
    seed([makeJob({ status: "in_progress" })], [], [janeRecord], { autoInvoiceOnComplete: true });
    expect(await createAutoInvoiceForJob("j1")).toBeNull();
    expect(storedInvoices()).toHaveLength(0);
  });

  test("existing deposit invoice → null (finalize keeps the manual screen)", async () => {
    const deposit = { id: "inv9", customer: "Jane Smith", number: "INV-0009", amount: 100, due: "2026-08-10", email: "", phone: "", desc: "", paid: false } as Invoice;
    seed([makeJob({ invoiceId: "inv9" })], [deposit], [janeRecord], { autoInvoiceOnComplete: true });

    expect(await createAutoInvoiceForJob("j1")).toBeNull();
    expect(storedInvoices()).toHaveLength(1);
  });

  test("no matching customer record → one is created and linked", async () => {
    seed([makeJob({ customerId: undefined })], [], [], { autoInvoiceOnComplete: true });

    const result = await createAutoInvoiceForJob("j1");

    expect(result).toBeTruthy();
    const customers: Customer[] = JSON.parse(store.customers);
    expect(customers).toHaveLength(1);
    expect(customers[0].name).toBe("Jane Smith");
    expect(storedInvoices()[0].customerId).toBe(customers[0].id);
  });
});

// ── auto-email stamping (2026-08-06 spec) ─────────────────────────────────────
// Fully-automatic emailing: when BOTH toggles are on and the resolved customer
// record has an email, the saved invoice carries autoEmailRequestedAt and the
// result reports autoEmailQueued so JobDetail can skip the send screen.

describe("createAutoInvoiceForJob auto-email stamping", () => {
  test("both toggles on + customer email → stamped and queued", async () => {
    seed([makeJob()], [], [janeRecord], {
      autoInvoiceOnComplete: true,
      autoEmailInvoiceOnComplete: true,
    });

    const result = await createAutoInvoiceForJob("j1");

    expect(result).toMatchObject({ autoEmailQueued: true, email: "jane@example.com" });
    const stamped = storedInvoices()[0].autoEmailRequestedAt;
    expect(stamped).toBeTruthy();
    expect(Number.isFinite(Date.parse(stamped as string))).toBe(true);
  });

  test("email toggle off (or absent) → no stamp, not queued", async () => {
    seed([makeJob()], [], [janeRecord], { autoInvoiceOnComplete: true });

    const result = await createAutoInvoiceForJob("j1");

    expect(result).toMatchObject({ autoEmailQueued: false, email: "" });
    expect(storedInvoices()[0].autoEmailRequestedAt).toBeUndefined();
  });

  test("customer without an email → no stamp (manual send screen path)", async () => {
    const noEmail = { id: "c1", name: "Jane Smith", email: "", phone: "555-0100" } as Customer;
    seed([makeJob()], [], [noEmail], {
      autoInvoiceOnComplete: true,
      autoEmailInvoiceOnComplete: true,
    });

    const result = await createAutoInvoiceForJob("j1");

    expect(result).toMatchObject({ autoEmailQueued: false, email: "" });
    expect(storedInvoices()[0].autoEmailRequestedAt).toBeUndefined();
  });
});

// ── prefillInvoiceDraftFromJob ────────────────────────────────────────────────

describe("prefillInvoiceDraftFromJob", () => {
  test("derives the same values the manual screen prefills", () => {
    const job = makeJob({ timeSessions: [closedSession(5.5)] });
    const draft = prefillInvoiceDraftFromJob(job, [], makeSettings(), janeLike());
    expect(draft).toMatchObject({
      customer: "Jane Smith",
      number: "INV-0001",
      amount: 1093.5,
      email: "jane@example.com",
      phone: "555-0100",
      desc: "Water heater swap",
      usedTrackedTime: true,
      billedHours: 5.5,
    });
    expect(draft.due).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });

  function janeLike(): Customer {
    return { id: "c1", name: "Jane Smith", email: "jane@example.com", phone: "555-0100" } as Customer;
  }
});

// ── change orders in billing ──────────────────────────────────────────────────
// 2026-08-05 spec: approved change orders flow into computeBillableBreakdown's
// total and get appended as `other`-category invoice lines, after
// labor/materials/overhead — so all three invoice paths pick them up from
// this single home.

function approvedCo(id: string, amount: number): ChangeOrder {
  return {
    id,
    title: `CO ${id}`,
    amount,
    createdAt: "2026-08-01",
    manualDecision: { decision: "approved", decidedAt: "2026-08-01" },
  };
}

describe("change orders in billing", () => {
  test("computeBillableBreakdown adds approved COs to the total (and reports them)", () => {
    const job = makeJob({
      estimateTotal: 2400,
      changeOrders: [
        approvedCo("coA", 850),
        { id: "coP", title: "p", amount: 999, createdAt: "2026-08-01" },
      ],
    });
    const b = computeBillableBreakdown(job);
    expect(b.changeOrderTotal).toBe(850);
    expect(b.total).toBe(3250);
  });

  test("buildInvoiceLineItems appends one line per approved CO and lines sum to total", () => {
    const job = makeJob({
      estimateTotal: 2400,
      changeOrders: [approvedCo("coA", 850), approvedCo("coB", -100)],
    });
    const items = buildInvoiceLineItems(job);
    const coLines = items.filter((i) => i.category === "other");
    expect(coLines).toEqual([
      { description: "Change order — CO coA", amount: 850, category: "other" },
      { description: "Change order — CO coB", amount: -100, category: "other" },
    ]);
    const sum = items.reduce((s, i) => s + i.amount, 0);
    expect(sum).toBeCloseTo(computeBillableBreakdown(job).total, 2);
  });

  test("legacy job without changeOrders is byte-identical to before", () => {
    const job = makeJob({ estimateTotal: 2400 });
    expect(computeBillableBreakdown(job).changeOrderTotal).toBe(0);
    expect(computeBillableBreakdown(job).total).toBe(2400);
    expect(buildInvoiceLineItems(job).some((i) => i.category === "other")).toBe(false);
  });

  test("tracked time and an approved CO compose in the same total", () => {
    // Quoted: 4h @ $85 ($340 labor) baked into estimateTotal 966. Tracked
    // time replaces those 4h with 5.5h ($467.50), and an approved $500 CO
    // adds on top — both deltas must land in the same total.
    const estimateTotal = 966;
    const originalLaborCost = 340; // 4h × $85, quoted
    const trackedLaborCost = 467.5; // 5.5h × $85, tracked
    const coAmount = 500;
    const job = makeJob({
      estimateTotal,
      timeSessions: [closedSession(5.5)],
      changeOrders: [approvedCo("coA", coAmount)],
    });

    const b = computeBillableBreakdown(job);

    expect(b.usedTrackedTime).toBe(true);
    expect(b.laborHours).toBe(5.5);
    expect(b.laborCost).toBe(trackedLaborCost);
    expect(b.changeOrderTotal).toBe(coAmount);
    expect(b.total).toBe(
      roundToCents(estimateTotal + trackedLaborCost - originalLaborCost + coAmount)
    );
    expect(b.total).toBe(1593.5);
  });
});

// ── payment-link mint at creation (2026-08-06 spec) ──────────────────────────
// Queued auto-invoices get a best-effort link mint so the backend email can
// include a pay link (it only ever includes a cached link matching the
// balance). Fire-and-forget: failures degrade to a link-less email.

describe("auto-invoice payment-link mint", () => {
  const flushAsync = () => new Promise((r) => setTimeout(r, 0));

  test("queued invoice gets paymentLinkUrl/Amount cached for the full amount", async () => {
    (resolvePaymentLink as jest.Mock).mockResolvedValue("https://buy.stripe.com/test_abc");
    seed([makeJob()], [], [janeRecord], {
      autoInvoiceOnComplete: true,
      autoEmailInvoiceOnComplete: true,
      provider: "stripe",
    });

    const result = await createAutoInvoiceForJob("j1");
    await flushAsync();

    expect(result?.autoEmailQueued).toBe(true);
    const inv = storedInvoices()[0];
    expect(inv.paymentLinkUrl).toBe("https://buy.stripe.com/test_abc");
    expect(inv.paymentLinkAmount).toBe(inv.amount);
  });

  test("not queued → no mint attempted", async () => {
    (resolvePaymentLink as jest.Mock).mockResolvedValue("https://buy.stripe.com/test_abc");
    seed([makeJob()], [], [janeRecord], { autoInvoiceOnComplete: true, provider: "stripe" });

    await createAutoInvoiceForJob("j1");
    await flushAsync();

    expect(resolvePaymentLink).not.toHaveBeenCalled();
    expect(storedInvoices()[0].paymentLinkUrl).toBeUndefined();
  });

  test("mint failure degrades silently: invoice saved, no link, error reported", async () => {
    (resolvePaymentLink as jest.Mock).mockRejectedValue(new Error("offline"));
    seed([makeJob()], [], [janeRecord], {
      autoInvoiceOnComplete: true,
      autoEmailInvoiceOnComplete: true,
      provider: "stripe",
    });

    const result = await createAutoInvoiceForJob("j1");
    await flushAsync();

    expect(result?.autoEmailQueued).toBe(true);
    expect(storedInvoices()[0].paymentLinkUrl).toBeUndefined();
    const { reportError } = jest.requireMock("../utils/analytics");
    expect(reportError).toHaveBeenCalled();
  });
});
