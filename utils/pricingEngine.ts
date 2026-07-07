// utils/pricingEngine.ts
// The math that powers the estimate builder.
// All pure functions — no UI, no side effects, easy to test.
//
// The formula in plain English:
//   Labor cost      = hours × hourly rate
//   Materials cost  = sum of (quantity × unit cost) × (1 + markup%)
//   Travel fee      = miles × fee per mile (if set)
//   Subtotal        = labor + materials + travel
//   Overhead        = subtotal × overhead%   (insurance, truck, tools, etc.)
//   Profit          = (subtotal + overhead) × margin%
//   TOTAL           = subtotal + overhead + profit
//   Tax             = total × tax% (if applicable — varies by state/trade)

import type {
  Customer,
  EstimateBreakdown,
  EstimateInput,
  EstimateMaterialInput,
  Job,
  JobEstimateBreakdown,
  JobStatus,
  PriceRange,
  Settings,
  TradeId,
} from "../types/models";
import { parseNumberInput } from "./numberInput";

// ── Main calculation ───────────────────────────────────────────────────────

export function calculateEstimate({
  laborHours = 0,
  laborRate = 85,
  materials = [], // [{ name, quantity, unitCost }]
  materialMarkup = 20, // percent
  overheadPercent = 15, // percent
  marginPercent = 20, // percent
  travelMiles = 0,
  travelFeePerMile = 0,
  isEmergency = false,
  emergencyMultiplier = 1.5,
  minimumJobFee = 75,
  taxPercent = 0,
}: EstimateInput): EstimateBreakdown {
  // Labor
  const effectiveLaborRate = isEmergency ? laborRate * emergencyMultiplier : laborRate;
  const laborCost = laborHours * effectiveLaborRate;

  // Materials
  const materialBaseCost = materials.reduce(
    (sum, m) => sum + (parseFloat(String(m.quantity)) || 0) * (parseFloat(String(m.unitCost)) || 0),
    0
  );
  const materialCost = materialBaseCost * (1 + materialMarkup / 100);

  // Travel
  const travelCost = travelMiles * travelFeePerMile;

  // Subtotal before overhead and margin
  const subtotal = laborCost + materialCost + travelCost;

  // Overhead (covers insurance, truck payment, tools, phone, etc.)
  const overheadCost = subtotal * (overheadPercent / 100);

  // Profit margin on top of everything
  const profitBase = subtotal + overheadCost;
  const profit = profitBase * (marginPercent / 100);

  // Pre-tax total
  const preTaxTotal = profitBase + profit;

  // Apply minimum job fee
  const totalBeforeTax = Math.max(preTaxTotal, minimumJobFee);

  // Tax (only applies if taxPercent > 0 — varies by state and job type)
  const taxAmount = totalBeforeTax * (taxPercent / 100);
  const total = totalBeforeTax + taxAmount;

  // Hourly effective rate (useful sanity check — what am I actually making/hr?)
  const effectiveHourlyRate = laborHours > 0 ? (total - materialCost - travelCost) / laborHours : 0;

  return {
    laborCost: round(laborCost),
    materialBaseCost: round(materialBaseCost),
    materialMarkupAmount: round(materialCost - materialBaseCost),
    materialCost: round(materialCost),
    travelCost: round(travelCost),
    subtotal: round(subtotal),
    overheadCost: round(overheadCost),
    profit: round(profit),
    preTaxTotal: round(preTaxTotal),
    totalBeforeTax: round(totalBeforeTax),
    taxAmount: round(taxAmount),
    total: round(total),
    effectiveHourlyRate: round(effectiveHourlyRate),
    hitMinimum: preTaxTotal < minimumJobFee,
  };
}

// ── Form inputs → estimate params ────────────────────────────────────────────
// Maps the calculator screen's raw text inputs (+ the user's saved Settings
// defaults) into a typed EstimateInput. Uses parseNumberInput so a legitimately
// entered 0 survives — 0% overhead/margin/markup, or a $0 "no minimum" job fee —
// instead of being silently overridden by the default (the old `parseFloat(x)
// || default` bug).

export interface EstimateInputForm {
  laborHours: string;
  laborRate: string;
  materials: EstimateMaterialInput[];
  materialMarkup: string;
  overheadPercent: string;
  marginPercent: string;
  travelMiles: string;
  isEmergency: boolean;
  taxPercent: string;
}

export function buildEstimateInput(
  form: EstimateInputForm,
  settings: Settings | null | undefined,
): EstimateInput {
  return {
    laborHours: parseNumberInput(form.laborHours, 0),
    laborRate: parseNumberInput(form.laborRate, 85),
    materials: form.materials,
    materialMarkup: parseNumberInput(form.materialMarkup, 20),
    overheadPercent: parseNumberInput(form.overheadPercent, 15),
    marginPercent: parseNumberInput(form.marginPercent, 20),
    travelMiles: parseNumberInput(form.travelMiles, 0),
    travelFeePerMile: parseNumberInput(settings?.travelFeePerMile, 0),
    isEmergency: form.isEmergency,
    emergencyMultiplier: parseNumberInput(settings?.emergencyMultiplier, 1.5),
    minimumJobFee: parseNumberInput(settings?.minimumJobFee, 75),
    taxPercent: parseNumberInput(form.taxPercent, 0),
  };
}

// ── Price range ────────────────────────────────────────────────────────────
// Returns a low/high range rather than a single number.
// Low = tighten margin by 5%, high = loosen by 5%.
// Gives the worker flexibility in how they present to a customer.

export function calculatePriceRange(params: EstimateInput): PriceRange {
  const margin = params.marginPercent ?? 20;
  const base = calculateEstimate(params);
  const low = calculateEstimate({ ...params, marginPercent: Math.max(0, margin - 5) });
  const high = calculateEstimate({ ...params, marginPercent: margin + 5 });
  return {
    low: low.total,
    recommended: base.total,
    high: high.total,
    breakdown: base,
  };
}

// ── Break-even check ───────────────────────────────────────────────────────
// Tells the worker what their absolute minimum price is
// (covers costs + overhead, zero profit).

export function breakEvenPrice(params: EstimateInput): number {
  const result = calculateEstimate({ ...params, marginPercent: 0 });
  return result.totalBeforeTax;
}

// ── Saved-job breakdown ─────────────────────────────────────────────────────
// Derive the estimate line-items from a SAVED job. Overhead is the residual
// (total − labor − material) so the breakdown always sums to the stored total —
// we trust the saved total rather than re-running calculateEstimate. This is the
// single home for the breakdown math that JobDetail, SendEstimate, the estimate
// messages, and the estimate PDF all render (roadmap #3).

export function computeEstimateBreakdown(job: Job): JobEstimateBreakdown {
  const materials = job.materials || [];
  const laborCost = (job.laborHours || 0) * (job.laborRate || 0);
  const materialBaseCost = materials.reduce((sum, m) => sum + m.quantity * m.unitCost, 0);
  const materialCost = materialBaseCost * (1 + (job.materialMarkup || 0) / 100);
  const estimateTotal = job.estimateTotal || 0;
  const overheadLine = estimateTotal - laborCost - materialCost;
  return {
    laborCost,
    materialBaseCost,
    materialCost,
    overheadLine,
    estimateTotal,
    hasMaterials: materials.length > 0,
  };
}

// ── Sanity checks ──────────────────────────────────────────────────────────
// Returns warnings if something looks off about the estimate.

export function getSanityWarnings(input: {
  total?: number;
  laborHours: number;
  laborRate: number;
  materials?: EstimateMaterialInput[];
  params: EstimateInput;
}): string[] {
  const { laborHours, laborRate, params } = input;
  const warnings: string[] = [];
  const breakdown = calculateEstimate(params);

  // Warn if effective hourly rate is very low
  if (breakdown.effectiveHourlyRate > 0 && breakdown.effectiveHourlyRate < laborRate * 0.8) {
    warnings.push(
      `Your effective hourly rate on this job is $${breakdown.effectiveHourlyRate.toFixed(0)}/hr — ` +
        `below your $${laborRate}/hr target. Consider adjusting hours or price.`
    );
  }

  // Warn if materials are more than 60% of the job (unusual for most trades)
  if (breakdown.materialCost > breakdown.total * 0.6) {
    warnings.push(
      "Materials are over 60% of this job total. Double-check your markup is applied correctly."
    );
  }

  // Warn if hitting minimum job fee
  if (breakdown.hitMinimum) {
    warnings.push(
      `This job is below your minimum fee of $${params.minimumJobFee}. ` +
        `The minimum will be charged instead.`
    );
  }

  // Warn if hours seem low for complex jobs (heuristic)
  if (laborHours > 0 && laborHours < 0.5) {
    warnings.push("Less than 30 minutes of labor — don't forget setup, cleanup, and drive time.");
  }

  return warnings;
}

// ── Prompt builder for Claude ──────────────────────────────────────────────
// Builds the prompt that asks Claude to write a professional estimate document.

export function buildEstimatePrompt({
  job,
  customer,
  breakdown,
  settings,
  range,
}: {
  job: Job;
  customer: Customer;
  breakdown: EstimateBreakdown;
  settings: Settings;
  range: PriceRange;
}): string {
  const materialsList =
    job.materials.length > 0
      ? job.materials
          .map((m) => `  - ${m.name} (qty: ${m.quantity}) @ $${m.unitCost} each`)
          .join("\n")
      : "  - No materials listed";

  return `You are writing a professional job estimate on behalf of ${settings.businessName}.
Write a clean, professional estimate letter that a blue collar trade business would send to a customer.

BUSINESS INFO:
Name: ${settings.businessName}
Trade: ${settings.trade}
Contact: ${settings.contactName}
Phone: ${settings.phone}
Email: ${settings.email}

CUSTOMER:
Name: ${customer.name}
Address: ${customer.address || "Not specified"}

JOB DETAILS:
Title: ${job.title}
Description: ${job.description}
Address: ${job.address || customer.address || "Customer location"}

PRICING BREAKDOWN:
Labor: ${job.laborHours} hrs @ $${job.laborRate}/hr = $${breakdown.laborCost.toFixed(2)}
Materials (with markup): $${breakdown.materialCost.toFixed(2)}
  Items:
${materialsList}
Overhead & operating costs: $${breakdown.overheadCost.toFixed(2)}
${breakdown.travelCost > 0 ? `Travel: $${breakdown.travelCost.toFixed(2)}\n` : ""}
TOTAL ESTIMATE: $${breakdown.total.toFixed(2)}
Price range offered: $${range.low.toFixed(0)} – $${range.high.toFixed(0)}

INSTRUCTIONS:
- Write in a professional but plain-spoken tone (this is a trade business, not a law firm)
- Include a clear line-item breakdown
- State that this is an estimate and final price may vary slightly based on conditions found on site
- Mention that work comes with a [90-day] workmanship guarantee
- Include payment terms: ${settings.paymentNotes}
- End with a call to action to approve the estimate
- Do NOT include placeholder text like [DATE] — write naturally
- Format as a proper letter/document, not a chat message
- Keep it to one page equivalent

Write the full estimate document now.`;
}

// ── Helpers ────────────────────────────────────────────────────────────────

function round(n: number): number {
  return Math.round(n * 100) / 100;
}

// Readable label for each job status
export const JOB_STATUSES: Record<
  JobStatus,
  { label: string; color: string; next: JobStatus | null }
> = {
  lead: { label: "Lead", color: "muted", next: "estimate_sent" },
  estimate_sent: { label: "Estimate sent", color: "accent", next: "approved" },
  approved: { label: "Approved", color: "success", next: "scheduled" },
  scheduled: { label: "Scheduled", color: "warning", next: "in_progress" },
  in_progress: { label: "In Progress", color: "accent", next: "complete" },
  complete: { label: "Complete", color: "success", next: "invoiced" },
  invoiced: { label: "Invoiced", color: "accent", next: "paid" },
  paid: { label: "Paid", color: "success", next: null },
};

export const TRADE_TYPES: { id: TradeId; label: string }[] = [
  { id: "plumbing", label: "Plumbing" },
  { id: "electrical", label: "Electrical" },
  { id: "hvac", label: "HVAC" },
  { id: "carpenter", label: "Carpentry" },
  { id: "bricklayer", label: "Bricklaying" },
  { id: "plasterer", label: "Plastering" },
  { id: "landscaping", label: "Landscaping" },
  { id: "cleaning", label: "Cleaning" },
  { id: "painting", label: "Painting" },
  { id: "handyman", label: "Handyman" },
  { id: "other", label: "Other" },
];

const TRADE_NICKNAMES: Record<string, string> = {
  plumbing: "Dunny",
  electrical: "Sparky",
  hvac: "Fridgie",
  carpenter: "Chippy",
  bricklayer: "Brickie",
  plasterer: "Sheetie",
};

export function getTradeNickname(trade?: string): string {
  return (trade && TRADE_NICKNAMES[trade]) || "Tradie";
}
