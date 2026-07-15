// Deterministic estimate document for the Pricing Calculator's Estimate tab.
//
// Beta finding (2026-07-14): asking the model to write the WHOLE document let
// it garble the arithmetic (especially on the keyless 8B-model path) and the
// formatting read cheap. Now the document is assembled here — every number
// comes from the pricing engine's breakdown and is formatted with formatQuote
// — and AI contributes only the scope-of-work paragraph, sanitized so it can
// never smuggle prices back in. With no AI at all, cannedScope() keeps the
// document complete and professional.
//
// Deliberate: the customer document folds overheadCost + profit into one
// "Overhead & operating costs" line (app convention — lines sum to the
// total), and NEVER includes the low/high price range — that is an internal
// pricing aid; printing "low" invites anchoring.

import { formatQuote } from "./format";
import type { EstimateBreakdown } from "../types/models";

const VALID_DAYS = 30;

interface EstimateDocumentInput {
  businessName: string;
  contactName: string;
  phone?: string;
  email?: string;
  customerName: string;
  customerAddress?: string;
  jobTitle: string;
  laborHours: number;
  laborRate: number;
  materialsCount: number;
  breakdown: EstimateBreakdown;
  scope: string;
  now?: Date;
}

export function buildEstimateDocument({
  businessName,
  contactName,
  phone,
  email,
  customerName,
  customerAddress,
  jobTitle,
  laborHours,
  laborRate,
  materialsCount,
  breakdown,
  scope,
  now = new Date(),
}: EstimateDocumentInput): string {
  const date = now.toLocaleDateString("en-US", {
    month: "long",
    day: "numeric",
    year: "numeric",
  });

  const contactLine = [contactName, phone, email].filter(Boolean).join(" | ");
  const operatingLine = breakdown.overheadCost + breakdown.profit;

  const lines: string[] = [
    `ESTIMATE — ${jobTitle}`,
    "",
    businessName,
    contactLine,
    date,
    "",
    "PREPARED FOR",
    customerName,
  ];
  if (customerAddress?.trim()) lines.push(customerAddress.trim());

  lines.push("", "SCOPE OF WORK", scope, "", "PRICING");
  lines.push(`Labor (${laborHours} hrs @ $${laborRate}/hr): ${formatQuote(breakdown.laborCost)}`);
  if (breakdown.materialCost > 0) {
    lines.push(
      `Materials (${materialsCount} item${materialsCount === 1 ? "" : "s"}, incl. markup): ${formatQuote(breakdown.materialCost)}`
    );
  }
  if (breakdown.travelCost > 0) {
    lines.push(`Travel: ${formatQuote(breakdown.travelCost)}`);
  }
  if (operatingLine > 0) {
    lines.push(`Overhead & operating costs: ${formatQuote(operatingLine)}`);
  }
  if (breakdown.taxAmount > 0) {
    lines.push(`Tax: ${formatQuote(breakdown.taxAmount)}`);
  }
  lines.push("—".repeat(30));
  lines.push(`TOTAL: ${formatQuote(breakdown.total)}`);
  if (breakdown.hitMinimum) {
    lines.push("(Our minimum job fee applies to this work.)");
  }

  lines.push(
    "",
    `This estimate is valid for ${VALID_DAYS} days from the date above. Final pricing may adjust if the scope of work changes.`,
    "",
    "Thank you for the opportunity — we'd love to earn your business.",
    `${contactName}, ${businessName}`
  );

  return lines.join("\n");
}

// Guards the AI-written scope paragraph: blank, price-smuggling, or rambling
// output falls back to the deterministic sentence.
export function sanitizeScope(text: string, fallback: string): string {
  const trimmed = (text || "").trim();
  if (!trimmed) return fallback;
  if (/\$\s*\d/.test(trimmed)) return fallback;
  if (trimmed.length > 600) return fallback;
  return trimmed;
}

export function cannedScope({
  jobTitle,
  description,
}: {
  jobTitle: string;
  description?: string;
}): string {
  const base = description?.trim() ? description.trim() : jobTitle;
  return `${base} — includes all labor and materials listed below, completed to a professional standard with site cleanup on completion.`;
}

// The one thing AI is asked to write: prose about the work, never numbers.
export function buildScopePrompt({
  jobTitle,
  description,
  trade,
}: {
  jobTitle: string;
  description?: string;
  trade?: string;
}): string {
  return `Write a 2-3 sentence "scope of work" paragraph for a customer estimate from a ${trade || "trade"} business.
Job: ${jobTitle}
${description?.trim() ? `Details: ${description.trim()}` : ""}
Describe what the work includes and the standard of workmanship, in plain confident language.
STRICT RULES: no prices, no dollar amounts, no numbers, no greeting, no sign-off — the paragraph only.`;
}
