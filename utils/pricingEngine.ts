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
//   TOTAL (pre-tax) = (subtotal + overhead) ÷ (1 − margin%)   ← TRUE margin: profit is a share OF THE PRICE
//   Profit          = TOTAL − (subtotal + overhead)           (equals margin% of TOTAL)
//   Tax             = total × tax% (if applicable — varies by state/trade)

import type {
  Customer,
  DirectCostLine,
  EstimateBreakdown,
  EstimateInput,
  EstimateMaterialInput,
  Job,
  JobCostCategory,
  JobCostInput,
  JobCostMarkupPolicy,
  JobEstimateBreakdown,
  JobStatus,
  LaborTimeBreakdown,
  PriceRange,
  Settings,
  TradeId,
} from "../types/models";
import type { BadgeColor } from "../components/UI";
import { parseNumberInput } from "./numberInput";

// ── Main calculation ───────────────────────────────────────────────────────

// A true margin of 100% is a division by zero (price → ∞) and anything above
// goes negative. Cap margin just below 100% — well above any real trade margin —
// so the divide is always defined. Documented, deliberate ceiling.
const MARGIN_CEILING = 99;

// ── Direct-cost lines (Phase 2) ──────────────────────────────────────────────
// Permits, disposal, rental, subcontractor, delivery, trip/travel, misc — the
// costs the trade guides teach owners to price explicitly. Each line declares a
// markupPolicy that decides how it enters the price:
//   • "in_margin_base"  → joins the subtotal (after an optional handling markup),
//                          so it earns overhead + margin — "priced into the job".
//   • "passthrough"     → billed at cost on TOP of the margined price, with no
//                          overhead/margin — the guides' "permit passed through
//                          at cost, outside the margin math".

/** Default policy for a category. Only permits pass through by default. */
export function defaultMarkupPolicyForCategory(category: JobCostCategory): JobCostMarkupPolicy {
  return category === "permit" ? "passthrough" : "in_margin_base";
}

interface DirectCostTotals {
  /** Σ "in_margin_base" amounts (after handling markup) added to the subtotal. */
  marginBase: number;
  /** Σ "passthrough" amounts, added at cost after the margin divide. */
  passthrough: number;
  /** Σ "passthrough" amounts on non-taxable lines (excluded from the taxed base). */
  nonTaxablePassthrough: number;
  /**
   * Σ raw cost basis (qty × unitCost) across ALL lines, markup excluded — the
   * money the owner actually pays out. For a pass-through this equals its
   * amount; for a marked-up line the markup is margin, not cost (mirrors how
   * materials cost uses the pre-markup base). Used by the profitability layer.
   */
  costBasis: number;
  /** Per-line customer-facing amounts, for deterministic rendering. */
  lines: DirectCostLine[];
}

export function computeDirectCosts(jobCosts: JobCostInput[] = []): DirectCostTotals {
  let marginBase = 0;
  let passthrough = 0;
  let nonTaxablePassthrough = 0;
  let costBasis = 0;
  const lines: DirectCostLine[] = [];

  for (const c of jobCosts) {
    const qty = parseNumberInput(c.quantity, 0);
    const unit = parseNumberInput(c.unitCost, 0);
    const markup = parseNumberInput(c.markupPercent, 0);
    const policy: JobCostMarkupPolicy = c.markupPolicy ?? defaultMarkupPolicyForCategory(c.category);
    const taxable = c.taxable === true;
    // Absent means visible: a cost with no explicit flag is itemised to the
    // customer (matches JobCost's documented default).
    const customerVisible = c.customerVisible !== false;
    const base = qty * unit;
    const amount = policy === "in_margin_base" ? base * (1 + markup / 100) : base;

    costBasis += base;
    if (policy === "in_margin_base") {
      marginBase += amount;
    } else {
      passthrough += amount;
      if (!taxable) nonTaxablePassthrough += amount;
    }

    lines.push({
      id: c.id,
      label: c.label ?? "",
      category: c.category,
      amount: round(amount),
      markupPolicy: policy,
      taxable,
      customerVisible,
    });
  }

  return { marginBase, passthrough, nonTaxablePassthrough, costBasis, lines };
}

export function calculateEstimate({
  laborHours = 0,
  laborRate = 85,
  materials = [], // [{ name, quantity, unitCost }]
  materialMarkup = 20, // percent
  jobCosts = [],
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

  // Direct costs — split into the margin base vs pass-through at cost.
  const direct = computeDirectCosts(jobCosts);

  // Subtotal before overhead and margin (in-margin-base direct costs join here).
  const subtotal = laborCost + materialCost + travelCost + direct.marginBase;

  // Overhead (covers insurance, truck payment, tools, phone, etc.)
  const overheadCost = subtotal * (overheadPercent / 100);

  // TRUE margin: profit is a share OF THE PRICE, not a markup on cost.
  //   price = cost ÷ (1 − margin);  profit = price − cost.
  // Clamp margin into [0, MARGIN_CEILING] here — not just in callers like
  // calculatePriceRange (which loosens margin by +5) — so every path is safe
  // from the division-by-zero / negative-price cases at/above 100%.
  const profitBase = subtotal + overheadCost; // total marginable cost
  const safeMargin = Math.min(Math.max(marginPercent, 0), MARGIN_CEILING);
  const preTaxTotal = profitBase / (1 - safeMargin / 100); // margined portion (pre-min, pre-passthrough)
  const profit = preTaxTotal - profitBase;

  // Apply the minimum job fee to the MARGINED portion (which represents your
  // labor + costs + profit), THEN add pass-through costs at cost on top — a
  // permit pass-through must not let a tiny job satisfy the labor floor.
  const marginedFloored = Math.max(preTaxTotal, minimumJobFee);
  const totalBeforeTax = marginedFloored + direct.passthrough;

  // Tax (only applies if taxPercent > 0 — varies by state and job type).
  // Non-taxable pass-through (e.g. a permit passed through at cost) is excluded
  // from the taxed base.
  const taxBase = totalBeforeTax - direct.nonTaxablePassthrough;
  const taxAmount = taxBase * (taxPercent / 100);
  const total = totalBeforeTax + taxAmount;

  // Hourly effective rate (useful sanity check — what am I actually making/hr?).
  // Materials, travel, and direct costs are excluded — they aren't labor earnings.
  const directCostTotal = direct.marginBase + direct.passthrough;
  const effectiveHourlyRate =
    laborHours > 0 ? (total - materialCost - travelCost - directCostTotal) / laborHours : 0;

  return {
    laborCost: round(laborCost),
    materialBaseCost: round(materialBaseCost),
    materialMarkupAmount: round(materialCost - materialBaseCost),
    materialCost: round(materialCost),
    travelCost: round(travelCost),
    directCostMarginBase: round(direct.marginBase),
    directCostPassthrough: round(direct.passthrough),
    directCostLines: direct.lines,
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
  jobCosts?: JobCostInput[];
  overheadPercent: string;
  marginPercent: string;
  travelMiles: string;
  isEmergency: boolean;
  taxPercent: string;
}

export function buildEstimateInput(
  form: EstimateInputForm,
  settings: Settings | null | undefined,
): Required<EstimateInput> {
  return {
    laborHours: parseNumberInput(form.laborHours, 0),
    laborRate: parseNumberInput(form.laborRate, 85),
    materials: form.materials,
    materialMarkup: parseNumberInput(form.materialMarkup, 20),
    jobCosts: form.jobCosts ?? [],
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

// ── Labor time breakdown (Phase 3) ───────────────────────────────────────────
// The optional breakdown is an INPUT AID: its four billable buckets sum to the
// job's laborHours (the engine's single canonical labor input). Drying/curing/
// waiting time lives in nonBillableNote and is never costed.

export function sumLaborBreakdown(b: Partial<LaborTimeBreakdown> | null | undefined): number {
  if (!b) return 0;
  const sum =
    parseNumberInput(b.onSiteHours, 0) +
    parseNumberInput(b.driveHours, 0) +
    parseNumberInput(b.supplyRunHours, 0) +
    parseNumberInput(b.setupCleanupHours, 0);
  return round(sum);
}

// ── Time & trip conflict warnings (Phase 3) ──────────────────────────────────
// Travel can be charged three ways now — drive time as labor, a per-mile fee,
// and a travel/delivery direct-cost line. These are SOFT warnings (an owner may
// legitimately do more than one); the app only surfaces the overlap.

const TRAVEL_COST_CATEGORIES: ReadonlySet<JobCostCategory> = new Set(["travel", "delivery"]);

export function getTimeAndTripWarnings(input: {
  driveHours?: number;
  travelMiles?: number;
  jobCosts?: { category: JobCostCategory }[];
}): string[] {
  const drive = parseNumberInput(input.driveHours, 0);
  const miles = parseNumberInput(input.travelMiles, 0);
  const hasTravelCostLine = (input.jobCosts || []).some((c) => TRAVEL_COST_CATEGORIES.has(c.category));
  const warnings: string[] = [];

  if (drive > 0 && miles > 0) {
    warnings.push(
      "You're billing drive time as labor AND a per-mile travel fee — make sure you mean to charge both.",
    );
  }
  if (drive > 0 && hasTravelCostLine) {
    warnings.push(
      "You're billing drive time as labor and also a travel/delivery cost line — check you're not double-charging.",
    );
  }
  if (drive === 0 && miles > 0 && hasTravelCostLine) {
    warnings.push(
      "You have a per-mile travel fee and a travel/delivery cost line — make sure you're not charging travel twice.",
    );
  }

  return warnings;
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

  // Customer-visible direct costs render as their own lines; the overhead line
  // stays the residual so labor + materials + visible direct + overhead always
  // sum to the trusted stored total. Hidden direct costs fold into the residual.
  const { lines } = computeDirectCosts(job.jobCosts || []);
  const visibleDirectTotal = lines
    .filter((l) => l.customerVisible)
    .reduce((sum, l) => sum + l.amount, 0);
  const overheadLine = estimateTotal - laborCost - materialCost - visibleDirectTotal;

  return {
    laborCost,
    materialBaseCost,
    materialCost,
    directCostLines: lines,
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
  customer: Pick<Customer, "name" | "address">;
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
  { label: string; color: BadgeColor; next: JobStatus | null }
> = {
  lead: { label: "Lead", color: "muted", next: "estimate_sent" },
  estimate_sent: { label: "Estimate sent", color: "accent", next: "approved" },
  approved: { label: "Approved", color: "success", next: "scheduled" },
  scheduled: { label: "Scheduled", color: "warning", next: "in_progress" },
  in_progress: { label: "In Progress", color: "accent", next: "complete" },
  complete: { label: "Complete", color: "success", next: "invoiced" },
  invoiced: { label: "Invoiced", color: "accent", next: "paid" },
  paid: { label: "Paid", color: "success", next: null },
  // Branch off estimate_sent — reached only via a customer decline, never via the
  // linear `.next` walk. `next: null` so JobDetail's "advance" action treats it as
  // an endpoint (re-sending a revised estimate is a separate explicit reset).
  declined: { label: "Declined", color: "danger", next: null },
};

// Direct-cost categories (Phase 2) — id + human label for pickers and for
// rendering a line that has no user-entered label.
export const JOB_COST_CATEGORIES: { id: JobCostCategory; label: string }[] = [
  { id: "permit", label: "Permit" },
  { id: "disposal", label: "Disposal" },
  { id: "rental", label: "Equipment rental" },
  { id: "subcontractor", label: "Subcontractor" },
  { id: "delivery", label: "Delivery" },
  { id: "travel", label: "Travel" },
  { id: "other", label: "Other cost" },
];

/** Display label for a direct-cost line: the user's label, else the category. */
export function directCostLabel(line: { label?: string; category: JobCostCategory }): string {
  const own = (line.label || "").trim();
  if (own) return own;
  return JOB_COST_CATEGORIES.find((c) => c.id === line.category)?.label || "Cost";
}

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
