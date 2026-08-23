// Freezes an estimate into the shape the public viewer renders, using the single
// source of pricing math (computeEstimateBreakdown). Pure + unit-tested.

import { computeEstimateBreakdown, directCostLabel } from "./pricingEngine";
import type { Job, Customer, Settings, EstimateApprovalSnapshot } from "../types/models";

export function buildEstimateSnapshot(
  job: Job,
  customer: Pick<Customer, "name">,
  settings: Pick<Settings, "businessName">,
): EstimateApprovalSnapshot {
  const { laborCost, materialCost, overheadLine, hasMaterials, directCostLines } = computeEstimateBreakdown(job);
  const lineItems: { label: string; amount: number }[] = [
    { label: `Labor (${job.laborHours} hrs @ $${job.laborRate}/hr)`, amount: laborCost },
  ];
  if (hasMaterials) {
    lineItems.push({ label: `Materials (${job.materials.length} item${job.materials.length !== 1 ? "s" : ""})`, amount: materialCost });
  }
  for (const dc of directCostLines.filter((l) => l.customerVisible)) {
    lineItems.push({ label: directCostLabel(dc), amount: dc.amount });
  }
  if (overheadLine > 0) lineItems.push({ label: "Overhead & operating costs", amount: overheadLine });

  return {
    businessName: settings.businessName || "Your tradesperson",
    customerName: customer.name || job.customerName,
    jobTitle: job.title,
    lineItems,
    total: job.estimateTotal,
    currency: "USD",
  };
}
