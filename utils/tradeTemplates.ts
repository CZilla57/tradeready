// utils/tradeTemplates.ts
// Phase 4 — trade-aware pricebook templates.
//
// A template is STRUCTURE, never market data. It offers a scope checklist
// (questions the owner answers) and empty, editable placeholder lines
// (materials at $0, direct-cost lines at $0 with the right category/policy) so
// the owner is reminded WHAT to price without the app inventing HOW MUCH.
//
// Load-bearing guardrail (pinned by tradeTemplates.test.ts): no template may
// contain a rate, quantity, waste %, coverage figure, minimum, or legal
// requirement. The checklist asks "permit needed? price it" — it never asserts
// that a permit is required. Templates are code (not user records): applying
// one only seeds form state; nothing here persists or syncs.

import type { JobCost, JobCostCategory, JobCostMarkupPolicy, Material, TradeId } from "../types/models";

export interface TradeTemplateJobCost {
  label: string;
  category: JobCostCategory;
  markupPolicy: JobCostMarkupPolicy;
}

export interface TradeTemplate {
  /** Stable id, also the article trade key (e.g. "drywall"). */
  id: string;
  /** Display name — no numbers. */
  name: string;
  /** Trades this template is most relevant to (drives "for your trade" sort). */
  trades: TradeId[];
  /** Reminder questions the owner answers; never assertions or figures. */
  scopeChecklist: string[];
  /** Named placeholder materials seeded at qty 1 / $0. */
  seedMaterials: { name: string }[];
  /** Direct-cost lines seeded at qty 1 / $0 with a category + policy. */
  seedJobCosts: TradeTemplateJobCost[];
}

// Every checklist item is a QUESTION. Every seed is a placeholder. No figures.
export const TRADE_TEMPLATES: TradeTemplate[] = [
  {
    id: "handyman",
    name: "Handyman job",
    trades: ["handyman"],
    scopeChecklist: [
      "Does the price cover your minimum visit or trip out?",
      "Are you quoting flat or hourly — and have you decided which to show?",
      "If bundling several small tasks, is each one listed?",
      "Is supply-run and drive time included in the hours?",
    ],
    seedMaterials: [],
    seedJobCosts: [],
  },
  {
    id: "painting",
    name: "Painting job",
    trades: ["painting"],
    scopeChecklist: [
      "Have you measured the paintable area?",
      "Are surface prep hours counted in labor?",
      "How many coats does this job need?",
      "Are you using an interior or exterior rate?",
      "Have you entered product coverage for paint needed?",
    ],
    seedMaterials: [{ name: "Paint" }, { name: "Primer" }, { name: "Sundries (tape, filler, sleeves)" }],
    seedJobCosts: [],
  },
  {
    id: "drywall",
    name: "Drywall job",
    trades: ["carpenter", "handyman", "plasterer"],
    scopeChecklist: [
      "Which stages does the price cover — hang, finish, texture?",
      "Is the level of finish agreed with the customer?",
      "Are return trips the drying time forces counted as labor?",
      "For a patch, does it meet your minimum job price?",
      "Have you entered a waste allowance for offcuts?",
    ],
    seedMaterials: [{ name: "Drywall sheets" }, { name: "Joint compound" }, { name: "Tape / corner bead" }],
    seedJobCosts: [{ label: "Debris disposal", category: "disposal", markupPolicy: "in_margin_base" }],
  },
  {
    id: "flooring",
    name: "Flooring job",
    trades: ["carpenter", "handyman"],
    scopeChecklist: [
      "Have you measured the area, including closets and nooks?",
      "Have you entered a waste / overage allowance for the pattern?",
      "Is tear-out priced as its own line, with disposal?",
      "Is a subfloor-prep allowance included or clearly excluded?",
      "Are transitions, trim, and stairs accounted for?",
      "Is the flooring customer-supplied or supplied by you?",
    ],
    seedMaterials: [{ name: "Flooring material" }, { name: "Underlayment / adhesive" }, { name: "Transitions / trim" }],
    seedJobCosts: [
      { label: "Old-floor disposal", category: "disposal", markupPolicy: "in_margin_base" },
      { label: "Delivery", category: "delivery", markupPolicy: "in_margin_base" },
    ],
  },
  {
    id: "landscaping",
    name: "Landscaping job",
    trades: ["landscaping"],
    scopeChecklist: [
      "Is on-site time counted for this visit?",
      "Is the drive the stop costs you included?",
      "Does your overhead percent carry equipment and fuel?",
      "For bulk material, have you measured by volume?",
      "Is debris disposal priced as its own line?",
      "Is this a one-off or part of a recurring schedule?",
    ],
    seedMaterials: [{ name: "Bulk material (mulch / soil / gravel)" }, { name: "Plants" }],
    seedJobCosts: [{ label: "Green-waste disposal", category: "disposal", markupPolicy: "in_margin_base" }],
  },
  {
    id: "electrical",
    name: "Electrical job",
    trades: ["electrical"],
    scopeChecklist: [
      "Is a service-call or diagnostic fee included?",
      "Is the permit fee, and the time to pull it, priced?",
      "Is a separate inspection return trip accounted for?",
      "Is this after-hours or an emergency call?",
      "Could this be saved as a reusable flat-rate task?",
    ],
    seedMaterials: [{ name: "Wire / cable" }, { name: "Devices / fixtures" }],
    seedJobCosts: [{ label: "Permit fee", category: "permit", markupPolicy: "passthrough" }],
  },
  {
    id: "plumbing",
    name: "Plumbing job",
    trades: ["plumbing"],
    scopeChecklist: [
      "Is a service-call or trip fee included?",
      "For nights, weekends, or urgent work, is your emergency pricing applied?",
      "Is the permit fee, and the time to pull it, priced?",
      "Is haul-away or disposal of the old unit included?",
      "Is the fixture customer-supplied or supplied by you?",
      "Could this be saved as a reusable flat-rate task?",
    ],
    seedMaterials: [{ name: "Fittings / supply lines" }, { name: "Fixture / unit" }],
    seedJobCosts: [
      { label: "Permit fee", category: "permit", markupPolicy: "passthrough" },
      { label: "Haul-away / disposal", category: "disposal", markupPolicy: "in_margin_base" },
    ],
  },
];

/**
 * All templates, browsable, with the ones relevant to `trade` sorted first so
 * the owner sees theirs at the top without losing access to the rest.
 */
export function templatesForTrade(trade: TradeId): TradeTemplate[] {
  return [...TRADE_TEMPLATES].sort((a, b) => {
    const aRel = a.trades.includes(trade) ? 0 : 1;
    const bRel = b.trades.includes(trade) ? 0 : 1;
    return aRel - bRel;
  });
}

/**
 * Turn a template into empty, editable seed lines for the pricebook form.
 * Pure — takes an id base so ids are deterministic in tests. Materials seed at
 * qty 1 / $0; direct costs seed at qty 1 / $0 / 0% markup, visible + non-taxable.
 * The template supplies NO amount — the owner fills every number.
 */
export function applyTemplate(
  template: TradeTemplate,
  idBase: number = Date.now(),
): { materials: Material[]; jobCosts: JobCost[] } {
  const materials: Material[] = template.seedMaterials.map((m, i) => ({
    id: `m${idBase}-${i}`,
    name: m.name,
    quantity: 1,
    unitCost: 0,
  }));
  const jobCosts: JobCost[] = template.seedJobCosts.map((c, i) => ({
    id: `jc${idBase}-${i}`,
    label: c.label,
    category: c.category,
    quantity: 1,
    unitCost: 0,
    markupPercent: 0,
    markupPolicy: c.markupPolicy,
    taxable: false,
    customerVisible: true,
  }));
  return { materials, jobCosts };
}
