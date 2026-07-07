// __tests__/jobStatusDisplay.test.js
// Roadmap #7 (7.2): the Today-tab job-status badge mapping, extracted from
// TodayScreen. Regression-guards the confirmed bug where the inline copy keyed
// "completed" (real status is "complete") and omitted approved/invoiced/paid,
// so those badges fell back to a raw grey label.

import { getJobStatusDisplay } from "../utils/jobStatusDisplay";
import { colors } from "../utils/theme";
import { JOB_STATUSES } from "../utils/pricingEngine";

describe("getJobStatusDisplay", () => {
  test("every real JobStatus resolves to a proper label + palette color (not the grey fallback)", () => {
    for (const status of Object.keys(JOB_STATUSES)) {
      const { label, color } = getJobStatusDisplay(status);
      // A real config never falls back to the raw status string as its label.
      expect(label).not.toBe(status);
      expect(typeof color).toBe("string");
      expect(color).toMatch(/^#[0-9A-Fa-f]{6}$/);
    }
  });

  test("'complete' (not 'completed') is the key — the fixed bug", () => {
    expect(getJobStatusDisplay("complete")).toEqual({
      label: "Completed",
      color: colors.statusComplete,
    });
    // The old typo key no longer exists, so it takes the grey fallback.
    expect(getJobStatusDisplay("completed").color).toBe(colors.statusLead);
  });

  test("previously-missing statuses now have configs", () => {
    expect(getJobStatusDisplay("approved")).toEqual({ label: "Approved", color: colors.statusApproved });
    expect(getJobStatusDisplay("invoiced")).toEqual({ label: "Invoiced", color: colors.statusInvoiced });
    expect(getJobStatusDisplay("paid")).toEqual({ label: "Paid", color: colors.statusPaid });
  });

  test("carried-over statuses keep their label + color", () => {
    expect(getJobStatusDisplay("lead")).toEqual({ label: "Lead", color: colors.statusLead });
    expect(getJobStatusDisplay("estimate_sent")).toEqual({ label: "Estimate Sent", color: colors.statusEstimate });
    expect(getJobStatusDisplay("scheduled")).toEqual({ label: "Scheduled", color: colors.statusScheduled });
    expect(getJobStatusDisplay("in_progress")).toEqual({ label: "In Progress", color: colors.statusInProgress });
  });

  test("unknown status falls back to a grey pill labelled with the raw value", () => {
    expect(getJobStatusDisplay("nonsense")).toEqual({ label: "nonsense", color: colors.statusLead });
  });
});
