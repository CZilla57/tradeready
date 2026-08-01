// __tests__/jobStatus.test.js
// Roadmap #7 (7.3): the approved→scheduled auto-transition (jobs defect #1).
// AddJobScreen used to save a scheduledDate without ever advancing the status,
// so an approved job stayed "approved" while holding a schedule.

import { advanceStatusForSchedule, canSendEstimate, advanceJobsForPaidInvoices } from "../utils/jobStatus";
import { JOB_STATUSES } from "../utils/pricingEngine";

describe("advanceStatusForSchedule", () => {
  test("approved + a schedule advances to scheduled (the fix)", () => {
    expect(advanceStatusForSchedule("approved", true)).toBe("scheduled");
    // The target is exactly the pipeline's next step, not a hardcoded string.
    expect(advanceStatusForSchedule("approved", true)).toBe(JOB_STATUSES.approved.next);
  });

  test("approved without a schedule stays approved", () => {
    expect(advanceStatusForSchedule("approved", false)).toBe("approved");
  });

  test("earlier statuses do not skip approval even with a schedule", () => {
    expect(advanceStatusForSchedule("lead", true)).toBe("lead");
    expect(advanceStatusForSchedule("estimate_sent", true)).toBe("estimate_sent");
  });

  test("later statuses never regress", () => {
    expect(advanceStatusForSchedule("scheduled", true)).toBe("scheduled");
    expect(advanceStatusForSchedule("in_progress", true)).toBe("in_progress");
    expect(advanceStatusForSchedule("complete", true)).toBe("complete");
    expect(advanceStatusForSchedule("invoiced", true)).toBe("invoiced");
  });

  test("paid (whose next is null) is returned unchanged, never null", () => {
    expect(advanceStatusForSchedule("paid", true)).toBe("paid");
  });
});

const { applyEstimateDecision } = require('../utils/jobStatus');

describe('applyEstimateDecision', () => {
  it('advances estimate_sent -> approved (via the pipeline)', () => {
    expect(applyEstimateDecision('estimate_sent', 'approved')).toBe('approved');
  });
  it('advances lead -> approved defensively', () => {
    expect(applyEstimateDecision('lead', 'approved')).toBe('approved');
  });
  it('sets estimate_sent -> declined', () => {
    expect(applyEstimateDecision('estimate_sent', 'declined')).toBe('declined');
  });
  it('never regresses a job already past estimate_sent', () => {
    for (const s of ['approved', 'scheduled', 'in_progress', 'complete', 'invoiced', 'paid']) {
      expect(applyEstimateDecision(s, 'declined')).toBe(s);
      expect(applyEstimateDecision(s, 'approved')).toBe(s);
    }
  });
  it('leaves a declined job unchanged (no resurrection to approved)', () => {
    expect(applyEstimateDecision('declined', 'approved')).toBe('declined');
    expect(applyEstimateDecision('declined', 'declined')).toBe('declined');
  });
});

// Phase 1 of the estimate-approval reachability fix. Emailing an estimate from
// the Pricing Calculator advances lead → estimate_sent, and every route to
// SendEstimateScreen was gated on status === "lead" — so the approval link
// became permanently unreachable for exactly the jobs that needed it.
describe("canSendEstimate", () => {
  test("a lead with a priced estimate can reach the send screen", () => {
    expect(canSendEstimate("lead", 1200)).toBe(true);
  });

  test("an already-sent estimate can still reach it — the reachability fix", () => {
    expect(canSendEstimate("estimate_sent", 1200)).toBe(true);
  });

  test("no estimate priced yet means nothing to send", () => {
    expect(canSendEstimate("lead", 0)).toBe(false);
    expect(canSendEstimate("estimate_sent", 0)).toBe(false);
  });

  test("once the customer has decided, sending is the wrong action", () => {
    // declined has its own "Revise & re-send" path that resets state first.
    for (const s of ["approved", "declined", "scheduled", "in_progress", "complete", "invoiced", "paid"]) {
      expect(canSendEstimate(s, 1200)).toBe(false);
    }
  });
});

const {
  canRequestDeposit,
  invoiceScreenMode,
  jobChangesAfterInvoiceSave,
  invoiceScreenCopy,
} = require('../utils/jobStatus');

// Pre-work deposits: a deposit can be requested as soon as the estimate is
// approved, not just after the job is marked complete. These helpers decide
// which of CreateInvoiceFromJobScreen's three modes applies, and — critically
// — that requesting a deposit early never advances job.status.
describe('canRequestDeposit', () => {
  it('is true for approved, scheduled, and in_progress', () => {
    expect(canRequestDeposit('approved')).toBe(true);
    expect(canRequestDeposit('scheduled')).toBe(true);
    expect(canRequestDeposit('in_progress')).toBe(true);
  });

  it('is false before approval and once the job is done', () => {
    for (const s of ['lead', 'estimate_sent', 'complete', 'invoiced', 'paid', 'declined']) {
      expect(canRequestDeposit(s)).toBe(false);
    }
  });
});

describe('invoiceScreenMode', () => {
  it('is "requestDeposit" for deposit-eligible statuses with no invoice yet', () => {
    expect(invoiceScreenMode('approved', false)).toBe('requestDeposit');
    expect(invoiceScreenMode('scheduled', false)).toBe('requestDeposit');
    expect(invoiceScreenMode('in_progress', false)).toBe('requestDeposit');
  });

  it('is "create" at complete with no invoice yet', () => {
    expect(invoiceScreenMode('complete', false)).toBe('create');
  });

  it('is "finalize" at complete once a deposit invoice already exists', () => {
    expect(invoiceScreenMode('complete', true)).toBe('finalize');
  });

  it('is null for a deposit-eligible status that already has an invoice (JobDetailScreen routes to Outreach instead)', () => {
    expect(invoiceScreenMode('approved', true)).toBeNull();
    expect(invoiceScreenMode('scheduled', true)).toBeNull();
    expect(invoiceScreenMode('in_progress', true)).toBeNull();
  });

  it('is null before approval and after invoicing, regardless of invoiceId', () => {
    for (const s of ['lead', 'estimate_sent', 'invoiced', 'paid', 'declined']) {
      expect(invoiceScreenMode(s, false)).toBeNull();
      expect(invoiceScreenMode(s, true)).toBeNull();
    }
  });
});

describe('advanceJobsForPaidInvoices', () => {
  // isFullyPaid semantics (utils/invoicePayments): a legacy `paid: true` invoice
  // with no ledger synthesizes a full legacy_<id> payment; otherwise the payments
  // ledger must cover `amount`.
  const paidInvoice   = { id: 'inv1', amount: 500, paid: true };
  const ledgerPaid    = { id: 'inv2', amount: 200, paid: false, payments: [{ id: 'p1', amount: 200, date: '2026-07-30', method: 'cash' }] };
  const partlyPaid    = { id: 'inv3', amount: 300, paid: false, payments: [{ id: 'p2', amount: 100, date: '2026-07-30', method: 'cash' }] };

  it('advances an invoiced job whose linked invoice is fully paid (legacy flag)', () => {
    const jobs = [{ id: 'j1', status: 'invoiced', invoiceId: 'inv1' }];
    const out = advanceJobsForPaidInvoices(jobs, [paidInvoice]);
    expect(out[0].status).toBe('paid');
    expect(out).not.toBe(jobs); // changed → new array
  });

  it('advances on a fully-covering payment ledger too', () => {
    const jobs = [{ id: 'j1', status: 'invoiced', invoiceId: 'inv2' }];
    expect(advanceJobsForPaidInvoices(jobs, [ledgerPaid])[0].status).toBe('paid');
  });

  it('ignores a partly-paid invoice', () => {
    const jobs = [{ id: 'j1', status: 'invoiced', invoiceId: 'inv3' }];
    expect(advanceJobsForPaidInvoices(jobs, [partlyPaid])).toBe(jobs); // same ref = no-op
  });

  it('never jumps a mid-pipeline job whose DEPOSIT invoice is fully paid — the core invariant', () => {
    const jobs = [{ id: 'j1', status: 'scheduled', invoiceId: 'inv1' }];
    expect(advanceJobsForPaidInvoices(jobs, [paidInvoice])).toBe(jobs);
  });

  it('ignores jobs with no or dangling invoiceId', () => {
    const jobs = [
      { id: 'j1', status: 'invoiced', invoiceId: null },
      { id: 'j2', status: 'invoiced', invoiceId: 'gone' },
    ];
    expect(advanceJobsForPaidInvoices(jobs, [paidInvoice])).toBe(jobs);
  });

  it('handles a mixed list, advancing only the eligible job', () => {
    const jobs = [
      { id: 'j1', status: 'invoiced', invoiceId: 'inv1' },
      { id: 'j2', status: 'invoiced', invoiceId: 'inv3' },
      { id: 'j3', status: 'complete', invoiceId: null },
    ];
    const out = advanceJobsForPaidInvoices(jobs, [paidInvoice, partlyPaid]);
    expect(out.map((j) => j.status)).toEqual(['paid', 'invoiced', 'complete']);
  });
});

describe('jobChangesAfterInvoiceSave', () => {
  it('requesting a deposit early never advances status — the core invariant', () => {
    expect(jobChangesAfterInvoiceSave('requestDeposit', 'inv123', false)).toEqual({ invoiceId: 'inv123' });
  });

  it('creating at complete advances to invoiced', () => {
    expect(jobChangesAfterInvoiceSave('create', 'inv123', false)).toEqual({ status: 'invoiced', invoiceId: 'inv123' });
  });

  it('finalizing an unpaid balance advances to invoiced', () => {
    expect(jobChangesAfterInvoiceSave('finalize', 'inv123', false)).toEqual({ status: 'invoiced', invoiceId: 'inv123' });
  });

  it('finalizing an invoice the deposit already fully covered advances straight to paid', () => {
    expect(jobChangesAfterInvoiceSave('finalize', 'inv123', true)).toEqual({ status: 'paid', invoiceId: 'inv123' });
  });

  it('a fully-paid deposit request still never advances', () => {
    expect(jobChangesAfterInvoiceSave('requestDeposit', 'inv123', true)).toEqual({ invoiceId: 'inv123' });
  });
});

describe('invoiceScreenCopy', () => {
  it('returns distinct title/cta per mode', () => {
    expect(invoiceScreenCopy('requestDeposit')).toEqual({ title: 'Request Deposit', cta: 'Request deposit →' });
    expect(invoiceScreenCopy('finalize')).toEqual({ title: 'Finalize Invoice', cta: 'Finalize invoice →' });
    expect(invoiceScreenCopy('create')).toEqual({ title: 'Create Invoice', cta: 'Create invoice →' });
  });
});
