// Vercel serverless function — proxies Anthropic vision for receipt scanning
// (expense form pre-fill), using a server-side API key so users without their
// own Anthropic key can still scan receipts.
//
// Auth: Supabase JWT via "Authorization: Bearer <token>"
//
// Required Vercel env vars:
//   ANTHROPIC_API_KEY
//   SUPABASE_URL
//   SUPABASE_ANON_KEY
//
// The client (utils/receiptOCR.ts) validates/clamps the extraction fields; this
// endpoint only authenticates, rate-limits, caps the payload, and relays the
// model's JSON object.

const { createRateLimiter, validateReceiptPayload } = require("../lib/guards");

const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY;
const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY;

const ANTHROPIC_MODEL = "claude-sonnet-4-6";
const ANTHROPIC_VERSION = "2023-06-01";

const ALLOWED_ORIGINS = ["https://tradeready.app"];

// 5 scans per user per minute — vision calls are the most expensive proxy
// requests, and even a stack of paper receipts is one scan every ~12 seconds.
const allowRequest = createRateLimiter({ limit: 5 });

module.exports = async function handler(req, res) {
  const origin = req.headers["origin"];
  res.setHeader("Access-Control-Allow-Origin", origin && ALLOWED_ORIGINS.includes(origin) ? origin : "https://tradeready.app");
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");
  if (req.method === "OPTIONS") return res.status(204).end();
  if (req.method !== "POST") return res.status(405).json({ error: "Method not allowed" });

  if (!ANTHROPIC_API_KEY || !SUPABASE_URL || !SUPABASE_ANON_KEY) {
    return res.status(500).json({ error: "Server misconfiguration." });
  }

  const auth = req.headers["authorization"];
  if (!auth || !auth.startsWith("Bearer ")) {
    return res.status(401).json({ error: "Missing or invalid authorization header." });
  }
  const userJwt = auth.slice(7);

  const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: `Bearer ${userJwt}`, apikey: SUPABASE_ANON_KEY },
  });
  if (!userRes.ok) {
    return res.status(401).json({ error: "Invalid or expired session." });
  }

  const user = await userRes.json().catch(() => null);
  const rateKey = (user && user.id) || req.headers["x-forwarded-for"] || "anonymous";
  if (!allowRequest(rateKey)) {
    return res.status(429).json({ error: "Too many requests. Please wait a minute and try again." });
  }

  const invalid = validateReceiptPayload(req.body);
  if (invalid) {
    return res.status(400).json({ error: invalid });
  }

  const { imageBase64, mediaType } = req.body;

  try {
    const aiRes = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": ANTHROPIC_API_KEY,
        "anthropic-version": ANTHROPIC_VERSION,
      },
      body: JSON.stringify({
        model: ANTHROPIC_MODEL,
        max_tokens: 300,
        messages: [
          {
            role: "user",
            content: [
              {
                type: "image",
                source: { type: "base64", media_type: mediaType, data: imageBase64 },
              },
              { type: "text", text: buildReceiptPrompt() },
            ],
          },
        ],
      }),
    });

    const data = await aiRes.json();
    if (data.error) {
      console.error("[receipt-extract] provider error:", data.error.message);
      return res.status(502).json({ error: "AI provider error. Please try again." });
    }

    const text = data.content?.map((b) => b.text || "").join("") || "";
    if (!text) {
      return res.status(502).json({ error: "No response from AI" });
    }

    const jsonMatch = text.match(/\{[\s\S]*\}/);
    if (!jsonMatch) {
      return res.status(502).json({ error: "Could not parse AI response" });
    }

    let extraction;
    try {
      extraction = JSON.parse(jsonMatch[0]);
    } catch {
      return res.status(502).json({ error: "Could not parse AI response" });
    }
    return res.status(200).json(extraction);
  } catch {
    return res.status(502).json({ error: "Failed to reach AI provider." });
  }
};

// Mirrors buildReceiptPrompt in utils/receiptOCR.ts (client/server prompt
// copies are the established pattern — see pricebook-suggest.js). Keep the
// category ids in lockstep with EXPENSE_CATEGORIES (utils/moneyUtils.ts).
function buildReceiptPrompt() {
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
  - materials — building materials, parts, supplies (hardware stores, suppliers)
  - tools — tools and equipment purchases or rentals
  - fuel — gas stations, fuel, vehicle and transport costs
  - labor — payments to subcontractors or hired help
  - insurance — insurance premiums
  - software — software, apps, subscriptions
  - marketing — advertising, printing, promotional costs
  - other — anything that fits none of the above

Rules:
- amount is the final TOTAL paid, not the subtotal.
- Use null for any field you cannot read clearly — never guess a value you can't see.
- confidence is "low" when the image is blurry, cropped, or partly unreadable.`;
}
