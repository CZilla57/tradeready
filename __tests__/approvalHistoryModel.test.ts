// Phase 0 task 2 (ESTIMATE_WORKFLOW_ROADMAP.md): the additive job-blob fields
// approvalHistory + approval.sharedAt/withdrawnAt are shared, append-only state
// that both the client (mobile) and the server writers carry unchanged. TS
// types erase at runtime, so the meaningful "parity" is that the client-side
// reconciler preserves these fields on a round-trip rather than dropping them.
// (The Worker-write and customer-endpoint sides are pinned in
// estimateRouteConditionalWorkers.test.js.)

import { applyDecisionsToJobs } from "../utils/storage/estimateApprovals";
import type { Job, EstimateApproval } from "../types/models";

const snapshot = {
  businessName: "Acme",
  customerName: "Dana",
  jobTitle: "Deck",
  lineItems: [{ label: "Labor", amount: 500 }],
  total: 500,
  currency: "USD",
};

const approval = (over: Partial<EstimateApproval> = {}): EstimateApproval => ({
  token: "TOK",
  sentAt: "2026-09-02T00:00:00.000Z",
  snapshot,
  ...over,
});

function job(over: Partial<Job> = {}): Job {
  return {
    id: "j1",
    customerId: "c1",
    customerName: "Dana",
    title: "Deck",
    description: "",
    status: "estimate_sent",
    scheduledDate: null,
    scheduledStartTime: null,
    scheduledEndTime: null,
    address: "",
    estimateTotal: 500,
    laborHours: 0,
    laborRate: 0,
    materials: [],
    materialMarkup: 0,
    overhead: 0,
    margin: 0,
    notes: "",
    invoiceId: null,
    createdAt: "2026-09-01",
    ...over,
  } as Job;
}

describe("additive approval fields survive the client reconciler", () => {
  it("preserves approvalHistory and the active sharedAt when a decision advances status", () => {
    const history: EstimateApproval[] = [
      approval({ token: "OLD", decision: "declined", consentAt: "c0", withdrawnAt: "2026-08-30T00:00:00.000Z" }),
    ];
    const input = job({
      status: "estimate_sent",
      approval: approval({ decision: "approved", consentAt: "c1", sharedAt: "2026-09-02T01:00:00.000Z" }),
      approvalHistory: history,
    });

    const { jobs, changed } = applyDecisionsToJobs([input]);

    expect(changed).toBe(true); // status advanced off estimate_sent
    const out = jobs[0];
    expect(out.status).not.toBe("estimate_sent");
    // The reconciler only touches status — every additive field rides through.
    expect(out.approvalHistory).toBe(history);
    expect(out.approval?.sharedAt).toBe("2026-09-02T01:00:00.000Z");
    expect(out.approval?.withdrawnAt).toBeUndefined();
    expect(out.approvalHistory?.[0]).toMatchObject({ token: "OLD", withdrawnAt: "2026-08-30T00:00:00.000Z" });
  });

  it("leaves a job with no decision (and its history) completely untouched", () => {
    const input = job({
      approval: approval({ sharedAt: "2026-09-02T01:00:00.000Z" }), // shared, awaiting
      approvalHistory: [approval({ token: "OLD", decision: "declined" })],
    });
    const { jobs, changed } = applyDecisionsToJobs([input]);
    expect(changed).toBe(false);
    expect(jobs[0]).toBe(input); // same reference — nothing rewritten
  });
});
