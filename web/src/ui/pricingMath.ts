// web/src/ui/pricingMath.ts
//
// A web-side reimplementation of the estimate math in utils/pricingEngine.ts
// (`calculateEstimate` + `computeDirectCosts`). The mobile module can't be
// imported here: it pulls `BadgeColor` from `../components/UI`, a React Native
// component module, so resolving it drags RN into the web build — the same
// reason `invoiceMath.ts` and `changeOrderMath.ts` exist. This is a faithful,
// behavior-preserving copy of the PURE pricing functions only (no status/trade
// tables, no prompt builder); it's pinned to the mobile engine's own test
// values in `pricingMath.test.ts`.
//
// Keep in lockstep with utils/pricingEngine.ts. The formula, verbatim:
//   Labor cost      = hours × (emergency ? rate × multiplier : rate)
//   Materials cost  = Σ(qty × unitCost) × (1 + markup%)
//   Travel fee      = miles × fee per mile
//   Subtotal        = labor + materials + travel + in-margin-base direct costs
//   Overhead        = subtotal × overhead%
//   TOTAL (pre-tax) = (subtotal + overhead) ÷ (1 − margin%)   ← margin is a share OF THE PRICE
//   …then the minimum-fee floor on the margined portion, pass-through at cost,
//   and tax on the taxable base.

import type {
  DirectCostLine,
  EstimateBreakdown,
  EstimateInput,
  JobCostCategory,
  JobCostInput,
  JobCostMarkupPolicy,
} from '@shared/types/models';
import { parseNumberInput } from '@shared/utils/numberInput';

// A true margin of 100% divides by zero (price → ∞); above it goes negative.
// Cap just below 100% — above any real trade margin — so the divide is defined.
const MARGIN_CEILING = 99;

function round(n: number): number {
  return Math.round(n * 100) / 100;
}

/** Default markup policy for a direct-cost category. Only permits pass through. */
export function defaultMarkupPolicyForCategory(
  category: JobCostCategory,
): JobCostMarkupPolicy {
  return category === 'permit' ? 'passthrough' : 'in_margin_base';
}

interface DirectCostTotals {
  marginBase: number;
  passthrough: number;
  nonTaxablePassthrough: number;
  costBasis: number;
  lines: DirectCostLine[];
}

export function computeDirectCosts(
  jobCosts: JobCostInput[] = [],
): DirectCostTotals {
  let marginBase = 0;
  let passthrough = 0;
  let nonTaxablePassthrough = 0;
  let costBasis = 0;
  const lines: DirectCostLine[] = [];

  for (const c of jobCosts) {
    const qty = parseNumberInput(c.quantity, 0);
    const unit = parseNumberInput(c.unitCost, 0);
    const markup = parseNumberInput(c.markupPercent, 0);
    const policy: JobCostMarkupPolicy =
      c.markupPolicy ?? defaultMarkupPolicyForCategory(c.category);
    const taxable = c.taxable === true;
    // Absent means visible: a cost with no explicit flag is itemised.
    const customerVisible = c.customerVisible !== false;
    const base = qty * unit;
    const amount = policy === 'in_margin_base' ? base * (1 + markup / 100) : base;

    costBasis += base;
    if (policy === 'in_margin_base') {
      marginBase += amount;
    } else {
      passthrough += amount;
      if (!taxable) nonTaxablePassthrough += amount;
    }

    lines.push({
      id: c.id,
      label: c.label ?? '',
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
  materials = [],
  materialMarkup = 20,
  jobCosts = [],
  overheadPercent = 15,
  marginPercent = 20,
  travelMiles = 0,
  travelFeePerMile = 0,
  isEmergency = false,
  emergencyMultiplier = 1.5,
  minimumJobFee = 75,
  taxPercent = 0,
}: EstimateInput): EstimateBreakdown {
  // Labor
  const effectiveLaborRate = isEmergency
    ? laborRate * emergencyMultiplier
    : laborRate;
  const laborCost = laborHours * effectiveLaborRate;

  // Materials
  const materialBaseCost = materials.reduce(
    (sum, m) =>
      sum +
      (parseFloat(String(m.quantity)) || 0) *
        (parseFloat(String(m.unitCost)) || 0),
    0,
  );
  const materialCost = materialBaseCost * (1 + materialMarkup / 100);

  // Travel
  const travelCost = travelMiles * travelFeePerMile;

  // Direct costs — margin base vs pass-through at cost.
  const direct = computeDirectCosts(jobCosts);

  // Subtotal before overhead and margin.
  const subtotal = laborCost + materialCost + travelCost + direct.marginBase;

  // Overhead.
  const overheadCost = subtotal * (overheadPercent / 100);

  // TRUE margin: profit is a share OF THE PRICE, not a markup on cost.
  const profitBase = subtotal + overheadCost;
  const safeMargin = Math.min(Math.max(marginPercent, 0), MARGIN_CEILING);
  const preTaxTotal = profitBase / (1 - safeMargin / 100);
  const profit = preTaxTotal - profitBase;

  // Minimum fee applies to the MARGINED portion; pass-through added at cost on top.
  const marginedFloored = Math.max(preTaxTotal, minimumJobFee);
  const totalBeforeTax = marginedFloored + direct.passthrough;

  // Tax — non-taxable pass-through excluded from the taxed base.
  const taxBase = totalBeforeTax - direct.nonTaxablePassthrough;
  const taxAmount = taxBase * (taxPercent / 100);
  const total = totalBeforeTax + taxAmount;

  // Effective hourly rate: materials/travel/direct excluded (not labor earnings).
  const directCostTotal = direct.marginBase + direct.passthrough;
  const effectiveHourlyRate =
    laborHours > 0
      ? (total - materialCost - travelCost - directCostTotal) / laborHours
      : 0;

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

/**
 * The recomputed estimate TOTAL for a saved-service / recurring-job pricing
 * edit — the single number those blobs store in `estimateTotal`. Materials use
 * the model's `Material` shape (name/quantity/unitCost), which `calculateEstimate`
 * reads structurally. `travelMiles`/`isEmergency`/`tax` aren't part of those
 * blobs, so they stay at the engine defaults (0 / false / 0), reproducing the
 * mobile save path which prices from the same stored fields.
 */
export function estimateTotalFromPricing(input: EstimateInput): number {
  return calculateEstimate(input).total;
}
