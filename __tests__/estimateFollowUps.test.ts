// __tests__/estimateFollowUps.test.ts
// Pure-selector tests for estimate follow-up nudges. All date math is
// LOCAL-frame (FA-039): fixed `now` Dates are constructed with the
// components constructor, never ISO strings.
import {
  FOLLOW_UP_DAYS,
  estimateSentDate,
  stampEstimateSent,
  selectEstimateFollowUps,
  selectAwaitingFollowUp,
  awaitingResponseLabel,
  buildFollowUpMessage,
} from "../utils/estimateFollowUps";
import type { Job } from "../types/models";

function makeJob(overrides: Partial<Job> = {}): Job {
  return {
    id: "j1",
    customerId: "c1",
    customerName: "Dave Smith",
    title: "Water heater swap",
    description: "",
    status: "estimate_sent",
    scheduledDate: null,
    scheduledStartTime: null,
    scheduledEndTime: null,
    address: "",
    estimateTotal: 850,
    laborHours: 3,
    laborRate: 85,
    materials: [],
    materialMarkup: 20,
    overhead: 15,
    margin: 20,
    notes: "",
    invoiceId: null,
    createdAt: "2026-07-01",
    ...overrides,
  };
}

describe("estimateSentDate", () => {
  test("prefers estimateSentAt over approval.sentAt", () => {
    const job = makeJob({
      estimateSentAt: "2026-08-01",
      approval: { token: "t", sentAt: "2026-07-20T14:00:00.000Z", snapshot: {} as never },
    });
    expect(estimateSentDate(job)).toEqual(new Date(2026, 7, 1));
  });

  test("falls back to approval.sentAt (ISO timestamp) when estimateSentAt is absent", () => {
    const job = makeJob({
      approval: { token: "t", sentAt: "2026-07-20T14:00:00.000Z", snapshot: {} as never },
    });
    const d = estimateSentDate(job);
    expect(d).not.toBeNull();
    expect(d!.getTime()).toBe(new Date("2026-07-20T14:00:00.000Z").getTime());
  });

  test("returns null when neither field exists (legacy manual send)", () => {
    expect(estimateSentDate(makeJob())).toBeNull();
  });

  test("returns null for an unparseable date instead of NaN math", () => {
    expect(estimateSentDate(makeJob({ estimateSentAt: "garbage" }))).toBeNull();
  });
});

describe("stampEstimateSent", () => {
  test("sets status and a local YYYY-MM-DD stamp from `now`", () => {
    const job = makeJob({ status: "lead" });
    const stamped = stampEstimateSent(job, new Date(2026, 7, 1, 16, 30));
    expect(stamped.status).toBe("estimate_sent");
    expect(stamped.estimateSentAt).toBe("2026-08-01");
  });

  test("preserves every other field", () => {
    const job = makeJob({ notes: "keep me" });
    const stamped = stampEstimateSent(job, new Date(2026, 7, 1));
    expect(stamped.notes).toBe("keep me");
    expect(stamped.id).toBe(job.id);
  });
});

describe("selectEstimateFollowUps", () => {
  // Sent Aug 1 → fire Aug 4, 9:00am LOCAL.
  const now = new Date(2026, 7, 2, 12, 0); // Aug 2 noon

  test("selects a silent estimate with a future fire date at sent+3d 9am local", () => {
    const out = selectEstimateFollowUps([makeJob({ estimateSentAt: "2026-08-01" })], now);
    expect(out).toHaveLength(1);
    expect(out[0]).toEqual({
      jobId: "j1",
      customerName: "Dave Smith",
      jobTitle: "Water heater swap",
      fireDate: new Date(2026, 7, 4, 9, 0, 0, 0),
    });
  });

  test("skips jobs not in estimate_sent", () => {
    const out = selectEstimateFollowUps(
      [makeJob({ status: "approved", estimateSentAt: "2026-08-01" })],
      now,
    );
    expect(out).toHaveLength(0);
  });

  test("skips jobs with no resolvable sent date (legacy)", () => {
    expect(selectEstimateFollowUps([makeJob()], now)).toHaveLength(0);
  });

  test("excludes past fire dates — this is the one-shot mechanism", () => {
    const out = selectEstimateFollowUps(
      [makeJob({ estimateSentAt: "2026-07-20" })],
      now,
    );
    expect(out).toHaveLength(0);
  });

  test("sorts soonest-first", () => {
    const out = selectEstimateFollowUps(
      [
        makeJob({ id: "late", estimateSentAt: "2026-08-02" }),
        makeJob({ id: "soon", estimateSentAt: "2026-08-01" }),
      ],
      now,
    );
    expect(out.map((r) => r.jobId)).toEqual(["soon", "late"]);
  });
});

describe("selectAwaitingFollowUp", () => {
  test("includes estimates silent >= FOLLOW_UP_DAYS, excludes younger ones", () => {
    const now = new Date(2026, 7, 10, 12, 0);
    const old = makeJob({ id: "old", estimateSentAt: "2026-08-01" }); // 9+ days
    const young = makeJob({ id: "young", estimateSentAt: "2026-08-09" }); // 1.5 days
    const out = selectAwaitingFollowUp([old, young], now);
    expect(out.map((j) => j.id)).toEqual(["old"]);
  });

  test("excludes non-estimate_sent and legacy no-date jobs", () => {
    const now = new Date(2026, 7, 10, 12, 0);
    const out = selectAwaitingFollowUp(
      [makeJob({ status: "approved", estimateSentAt: "2026-08-01" }), makeJob()],
      now,
    );
    expect(out).toHaveLength(0);
  });

  test("day-3 pre-9am: appears in BOTH selectors (intentional overlap, see spec)", () => {
    const now = new Date(2026, 7, 4, 8, 0); // day 3, 8:00am
    const job = makeJob({ estimateSentAt: "2026-08-01" });
    expect(selectAwaitingFollowUp([job], now)).toHaveLength(1);
    expect(selectEstimateFollowUps([job], now)).toHaveLength(1);
  });
});

describe("awaitingResponseLabel", () => {
  test("singular and plural", () => {
    expect(awaitingResponseLabel(1)).toBe("1 estimate awaiting response");
    expect(awaitingResponseLabel(3)).toBe("3 estimates awaiting response");
  });
});

describe("buildFollowUpMessage", () => {
  test("includes first name, job title, and formatQuote amount", () => {
    const msg = buildFollowUpMessage(makeJob(), "Dave");
    expect(msg).toContain("Hi Dave");
    expect(msg).toContain("Water heater swap");
    expect(msg).toContain("$850");
  });

  test("FOLLOW_UP_DAYS is 3 (spec constant — Settings copy and notification body cite it)", () => {
    expect(FOLLOW_UP_DAYS).toBe(3);
  });
});
