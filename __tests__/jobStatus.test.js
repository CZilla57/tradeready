// __tests__/jobStatus.test.js
// Roadmap #7 (7.3): the approved→scheduled auto-transition (jobs defect #1).
// AddJobScreen used to save a scheduledDate without ever advancing the status,
// so an approved job stayed "approved" while holding a schedule.

import { advanceStatusForSchedule } from "../utils/jobStatus";
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
