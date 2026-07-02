// utils/pricingEngine.js
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

// ── Main calculation ───────────────────────────────────────────────────────

export function calculateEstimate({
  laborHours = 0,
  laborRate = 85,
  materials = [],           // [{ name, quantity, unitCost }]
  materialMarkup = 20,      // percent
  overheadPercent = 15,     // percent
  marginPercent = 20,       // percent
  travelMiles = 0,
  travelFeePerMile = 0,
  isEmergency = false,
  emergencyMultiplier = 1.5,
  minimumJobFee = 75,
  taxPercent = 0,
}) {
  // Labor
  const effectiveLaborRate = isEmergency ? laborRate * emergencyMultiplier : laborRate;
  const laborCost = laborHours * effectiveLaborRate;

  // Materials
  const materialBaseCost = materials.reduce(
    (sum, m) => sum + (parseFloat(m.quantity) || 0) * (parseFloat(m.unitCost) || 0),
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

// ── Price range ────────────────────────────────────────────────────────────
// Returns a low/high range rather than a single number.
// Low = tighten margin by 5%, high = loosen by 5%.
// Gives the worker flexibility in how they present to a customer.

export function calculatePriceRange(params) {
  const base = calculateEstimate(params);
  const low = calculateEstimate({ ...params, marginPercent: Math.max(0, params.marginPercent - 5) });
  const high = calculateEstimate({ ...params, marginPercent: params.marginPercent + 5 });
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

export function breakEvenPrice(params) {
  const result = calculateEstimate({ ...params, marginPercent: 0 });
  return result.totalBeforeTax;
}

// ── Sanity checks ──────────────────────────────────────────────────────────
// Returns warnings if something looks off about the estimate.

export function getSanityWarnings({ total, laborHours, laborRate, materials, params }) {
  const warnings = [];
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
    warnings.push(
      "Less than 30 minutes of labor — don't forget setup, cleanup, and drive time."
    );
  }

  return warnings;
}

// ── Prompt builder for Claude ──────────────────────────────────────────────
// Builds the prompt that asks Claude to write a professional estimate document.

export function buildEstimatePrompt({ job, customer, breakdown, settings, range }) {
  const materialsList = job.materials.length > 0
    ? job.materials.map(m => `  - ${m.name} (qty: ${m.quantity}) @ $${m.unitCost} each`).join("\n")
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

function round(n) {
  return Math.round(n * 100) / 100;
}

export function formatCurrency(n) {
  return n.toLocaleString("en-US", {
    style: "currency",
    currency: "USD",
    minimumFractionDigits: 0,
    maximumFractionDigits: 2,
  });
}

// Readable label for each job status
export const JOB_STATUSES = {
  lead:           { label: "Lead",           color: "muted",   next: "estimate_sent" },
  estimate_sent:  { label: "Estimate sent",  color: "accent",  next: "approved" },
  approved:       { label: "Approved",       color: "success", next: "scheduled" },
  scheduled:      { label: "Scheduled",      color: "warning", next: "in_progress" },
  in_progress:    { label: "In Progress",    color: "accent",  next: "complete" },
  complete:       { label: "Complete",       color: "success", next: "invoiced" },
  invoiced:       { label: "Invoiced",       color: "accent",  next: "paid" },
  paid:           { label: "Paid",           color: "success", next: null },
};

export const TRADE_TYPES = [
  { id: "plumbing",    label: "Plumbing" },
  { id: "electrical",  label: "Electrical" },
  { id: "hvac",        label: "HVAC" },
  { id: "landscaping", label: "Landscaping" },
  { id: "cleaning",    label: "Cleaning" },
  { id: "painting",    label: "Painting" },
  { id: "handyman",    label: "Handyman" },
  { id: "other",       label: "Other" },
];
