import { buildJobImport, mapJobStatus } from "../utils/importEngine";
import type { Customer, Job } from "../types/models";

describe("mapJobStatus", () => {
  test("maps common foreign statuses", () => {
    expect(mapJobStatus("Lead").status).toBe("lead");
    expect(mapJobStatus("Estimate Sent").status).toBe("estimate_sent");
    expect(mapJobStatus("In Progress").status).toBe("in_progress");
    expect(mapJobStatus("Completed").status).toBe("complete");
    expect(mapJobStatus("Paid").status).toBe("paid");
    expect(mapJobStatus("Cancelled").status).toBe("declined");
  });
  test("flags unrecognised status as lead", () => {
    const r = mapJobStatus("Zorp");
    expect(r.status).toBe("lead");
    expect(r.recognized).toBe(false);
  });
});

describe("buildJobImport", () => {
  const mapping = ["title", "customerName", "status", "scheduledDate"];
  test("creates a job, joins/creates the customer, assigns status directly", () => {
    const existingCustomers: Customer[] = [];
    const existingJobs: Job[] = [];
    const rows = [["Fix sink", "Grace Hopper", "Completed", "07/04/2026"]];
    const res = buildJobImport(rows, mapping, existingCustomers, existingJobs, "b1", "MDY");

    expect(res.jobs).toHaveLength(1);
    const job = res.jobs[0];
    expect(job.title).toBe("Fix sink");
    expect(job.status).toBe("complete");
    expect(job.scheduledDate).toBe("2026-07-04");
    expect(job.estimateSentAt).toBeUndefined();     // no nudges on imports
    expect(job.materials).toEqual([]);
    expect(job.importBatchId).toBe("b1");

    const cust = res.customers.find((c) => c.name === "Grace Hopper")!;
    expect(cust).toBeTruthy();
    expect(cust.importBatchId).toBe("b1");          // created in this batch
    expect(job.customerId).toBe(cust.id);           // linked
    expect(job.customerName).toBe("Grace Hopper");
  });

  test("skips a row missing title or customer", () => {
    const res = buildJobImport([["", "X"]], mapping, [], [], "b", "MDY");
    expect(res.counts.skip).toBe(1);
    expect(res.jobs).toHaveLength(0);
  });

  test("flags an unrecognised status but still imports", () => {
    const res = buildJobImport([["Job A", "Cust", "Zorp", ""]], mapping, [], [], "b", "MDY");
    expect(res.jobs[0].status).toBe("lead");
    expect(res.counts.flag).toBe(1);
  });
});
