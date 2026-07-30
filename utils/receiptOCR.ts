// utils/receiptOCR.ts
// Receipt scanning for the expense form (roadmap #5): read an attached receipt
// photo and extract merchant / amount / date / category so AddExpenseModal can
// pre-fill the form for the user to review. Same client-key / backend-fallback
// split as pricebookAI.ts: user's own anthropicKey → Claude vision via the
// shared generateMessage transport; otherwise the Vercel `receipt-extract`
// endpoint (server-side ANTHROPIC_API_KEY behind Supabase JWT auth).
//
// Contract: extractReceipt NEVER throws. Every failure mode — oversize image,
// unsupported mime type, no session, network/API error, unparseable reply —
// returns null, and the caller falls back to plain manual entry.

import Constants from "expo-constants";
import { generateMessage } from "./anthropicMessage";
import { supabase } from "./supabase";
import { loadSettings } from "./storage/settings";
import { EXPENSE_CATEGORIES } from "./moneyUtils";
import type { ExpenseCategoryId } from "../types/models";

const backendUrl = Constants.expoConfig?.extra?.backendUrl;

/**
 * Hard cap on the base64 payload (~3.7 MB decoded). Stays under Vercel's
 * 4.5 MB request-body limit and Anthropic's 5 MB image limit with margin;
 * the backend enforces the same cap independently (backend/lib/guards.js).
 */
export const MAX_RECEIPT_BASE64_CHARS = 5_000_000;

export type ReceiptMediaType = "image/jpeg" | "image/png";

export interface ReceiptExtraction {
  /** Merchant/vendor name, trimmed, capped at 80 chars. */
  merchant: string | null;
  /** Receipt total (including tax) — finite and > 0. */
  amount: number | null;
  /** "YYYY-MM-DD", validated as a real calendar date. */
  date: string | null;
  /** One of the 8 EXPENSE_CATEGORIES ids. */
  category: ExpenseCategoryId | null;
  confidence: "high" | "low";
}

/** Which transport produced a result — analytics only, never sent anywhere. */
export type ReceiptScanRoute = "user_key" | "backend";

export interface ReceiptScanResult {
  extraction: ReceiptExtraction;
  route: ReceiptScanRoute;
}

const CATEGORY_IDS = new Set<string>(EXPENSE_CATEGORIES.map((c) => c.id));

const MERCHANT_MAX_CHARS = 80;

export function buildReceiptPrompt(): string {
  const categoryLines = [
    "materials — building materials, parts, supplies (hardware stores, suppliers)",
    "tools — tools and equipment purchases or rentals",
    "fuel — gas stations, fuel, vehicle and transport costs",
    "labor — payments to subcontractors or hired help",
    "insurance — insurance premiums",
    "software — software, apps, subscriptions",
    "marketing — advertising, printing, promotional costs",
    "other — anything that fits none of the above",
  ]
    .map((l) => `  - ${l}`)
    .join("\n");

  return `You are reading a photo of a purchase receipt for a small trades business's expense log.

Extract what you can see and respond ONLY with a JSON object (no markdown, no explanation outside the JSON) in this exact format:
{
  "merchant": "<store or vendor name, or null>",
  "amount": <the receipt TOTAL including tax as a number, or null>,
  "date": "<purchase date as YYYY-MM-DD, or null>",
  "category": "<one of the ids below, or null>",
  "confidence": "<high or low>"
}

Category ids:
${categoryLines}

Rules:
- amount is the final TOTAL paid, not the subtotal.
- Use null for any field you cannot read clearly — never guess a value you can't see.
- confidence is "low" when the image is blurry, cropped, or partly unreadable.`;
}

/**
 * Pure parser/validator for the model's reply. Each field is validated
 * independently — a junk field becomes null without sinking the rest. Returns
 * null only when nothing useful (merchant, amount, date all null) came back.
 */
export function parseReceiptExtraction(text: string): ReceiptExtraction | null {
  const jsonMatch = typeof text === "string" ? text.match(/\{[\s\S]*\}/) : null;
  if (!jsonMatch) return null;

  let raw: Record<string, unknown>;
  try {
    raw = JSON.parse(jsonMatch[0]);
  } catch {
    return null;
  }
  if (!raw || typeof raw !== "object") return null;

  const merchant =
    typeof raw.merchant === "string" && raw.merchant.trim()
      ? raw.merchant.trim().slice(0, MERCHANT_MAX_CHARS)
      : null;

  const amount =
    typeof raw.amount === "number" && Number.isFinite(raw.amount) && raw.amount > 0
      ? raw.amount
      : null;

  const date = isValidIsoDate(raw.date) ? (raw.date as string) : null;

  const category =
    typeof raw.category === "string" && CATEGORY_IDS.has(raw.category)
      ? (raw.category as ExpenseCategoryId)
      : null;

  if (merchant === null && amount === null && date === null) return null;

  return {
    merchant,
    amount,
    date,
    category,
    confidence: raw.confidence === "high" ? "high" : "low",
  };
}

function isValidIsoDate(value: unknown): boolean {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00`);
  if (Number.isNaN(parsed.getTime())) return false;
  // Reject rollovers like 2026-02-31 → Mar 2 (Date accepts them silently).
  return parsed.toISOString().slice(0, 10) === value || localIsoDate(parsed) === value;
}

function localIsoDate(d: Date): string {
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${d.getFullYear()}-${m}-${day}`;
}

/**
 * Split a data URI (from readPhotoAsDataUri) into media type + raw base64.
 * Returns null for anything that isn't a supported image data URI.
 */
export function splitDataUri(
  dataUri: string
): { mediaType: ReceiptMediaType; base64: string } | null {
  const match = /^data:(image\/jpeg|image\/png);base64,(.+)$/s.exec(dataUri || "");
  if (!match) return null;
  return { mediaType: match[1] as ReceiptMediaType, base64: match[2] };
}

/**
 * Extract expense fields from a receipt photo. `dataUri` comes from
 * readPhotoAsDataUri (utils/photoStorage.ts). Never throws; null means "no
 * extraction — carry on with manual entry".
 */
export async function extractReceipt(dataUri: string): Promise<ReceiptScanResult | null> {
  const split = splitDataUri(dataUri);
  if (!split) return null;
  if (split.base64.length > MAX_RECEIPT_BASE64_CHARS) return null;

  try {
    const settings = await loadSettings();

    if (settings?.anthropicKey) {
      const text = await generateMessage({
        prompt: buildReceiptPrompt(),
        apiKey: settings.anthropicKey,
        max_tokens: 300,
        image: { base64: split.base64, mediaType: split.mediaType },
        fallback: () => "",
      });
      const extraction = text ? parseReceiptExtraction(text) : null;
      return extraction ? { extraction, route: "user_key" } : null;
    }

    const extraction = await extractViaBackend(split.base64, split.mediaType);
    return extraction ? { extraction, route: "backend" } : null;
  } catch {
    return null;
  }
}

async function extractViaBackend(
  base64: string,
  mediaType: ReceiptMediaType
): Promise<ReceiptExtraction | null> {
  if (!backendUrl) return null;

  const { data: sessionData } = await supabase.auth.getSession();
  const token = sessionData?.session?.access_token;
  if (!token) return null;

  try {
    const res = await fetch(`${backendUrl}/api/receipt-extract`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({ imageBase64: base64, mediaType }),
    });

    if (!res.ok) return null;
    const body = await res.json();
    // The endpoint returns the model's JSON object; run it through the same
    // clamp table as the client-key path — one validation home.
    return parseReceiptExtraction(JSON.stringify(body));
  } catch {
    return null;
  }
}
