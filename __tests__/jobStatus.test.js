// __tests__/jobStatus.test.js
// Roadmap #7 (7.3): the approved→scheduled auto-transition (jobs defect #1).
// AddJobScreen used to save a scheduledDate without ever advancing the status,
// so an approved job stayed "approved" while holding a schedule.

import { advanceStatusForSchedule, canSendEstimate } from "../utils/jobStatus";
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
