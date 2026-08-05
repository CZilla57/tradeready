// Workers port of backend/api/receipt-extract.js — proxies Groq vision for
// receipt scanning (expense form pre-fill), using a server-side API key so
// users without their own Anthropic key can still scan receipts. Groq, not
// Anthropic, because GROQ_API_KEY was already funded and configured (ai-chat)
// while no ANTHROPIC_API_KEY has ever been set — see the tradeready-ai-layer
// skill for the routing rationale. The user's-own-key path (utils/
// receiptOCR.ts, no user key set here) is unaffected and still calls
// Anthropic directly.
//
// Auth: Supabase JWT via "Authorization: Bearer <token>"
//
// Required bindings: GROQ_API_KEY, SUPABASE_URL, SUPABASE_ANON_KEY
//
// The client (utils/receiptOCR.ts) validates/clamps the extraction fields; this
// endpoint only authenticates, rate-limits, caps the payload, and relays the
// model's JSON object.

import { createRateLimiter, validateReceiptPayload } from '../../lib/guards.js';
import { enforceDailyCap } from '../../lib/aiUsage.js';
import { appCors, jsonBody } from '../appCors.js';

// Groq's only vision-capable model as of 2026-07-30 (verified against
// console.groq.com/docs/vision — do not assume llama-3.1-8b-instant, the
// text-only model used elsewhere in this backend, supports images).
const GROQ_VISION_MODEL = 'qwen/qwen3.6-27b';

// 5 scans per user per minute — vision calls are the most expensive proxy
// requests, and even a stack of paper receipts is one scan every ~12 seconds.
const allowRequest = createRateLimiter({ limit: 5 });

export async function receiptExtractHandler(c) {
  appCors(c, 'POST, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 204);
  if (c.req.method !== 'POST') return c.json({ error: 'Method not allowed' }, 405);

  const { GROQ_API_KEY, SUPABASE_URL, SUPABASE_ANON_KEY } = c.env;
  if (!GROQ_API_KEY || !SUPABASE_URL || !SUPABASE_ANON_KEY) {
    return c.json({ error: 'Server misconfiguration.' }, 500);
  }

  const auth = c.req.header('authorization');
  if (!auth || !auth.startsWith('Bearer ')) {
    return c.json({ error: 'Missing or invalid authorization header.' }, 401);
  }
  const userJwt = auth.slice(7);

  const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: `Bearer ${userJwt}`, apikey: SUPABASE_ANON_KEY },
  });
  if (!userRes.ok) {
    return c.json({ error: 'Invalid or expired session.' }, 401);
  }

  const user = await userRes.json().catch(() => null);
  const rateKey = (user && user.id) || c.req.header('x-forwarded-for') || 'anonymous';
  if (!allowRequest(rateKey)) {
    return c.json({ error: 'Too many requests. Please wait a minute and try again.' }, 429);
  }

  const body = await jsonBody(c);
  const invalid = validateReceiptPayload(body);
  if (invalid) {
    return c.json({ error: invalid }, 400);
  }

  // Durable per-user daily cap — second layer behind the in-memory limiter
  // (see lib/aiUsage.js). Runs after validation so malformed requests
  // never consume quota; fails open on counter-infrastructure errors.
  if (user && user.id) {
    const cap = await enforceDailyCap(c.env, user.id, 'receipt-extract');
    if (!cap.allowed) {
      return c.json({ error: cap.error }, 429);
    }
  }

  const { imageBase64, mediaType } = body;

  try {
    const aiRes = await fetch('https://api.groq.com/openai/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${GROQ_API_KEY}`,
      },
      body: JSON.stringify({
        model: GROQ_VISION_MODEL,
        max_tokens: 300,
        messages: [
          {
            role: 'user',
            content: [
              { type: 'text', text: buildReceiptPrompt() },
              { type: 'image_url', image_url: { url: `data:${mediaType};base64,${imageBase64}` } },
            ],
          },
        ],
      }),
    });

    const data = await aiRes.json();
    if (data.error) {
      console.error('[receipt-extract] provider error:', data.error.message);
      return c.json({ error: 'AI provider error. Please try again.' }, 502);
    }

    const text = data.choices?.[0]?.message?.content || '';
    if (!text) {
      return c.json({ error: 'No response from AI' }, 502);
    }

    const jsonMatch = text.match(/\{[\s\S]*\}/);
    if (!jsonMatch) {
      return c.json({ error: 'Could not parse AI response' }, 502);
    }

    let extraction;
    try {
      extraction = JSON.parse(jsonMatch[0]);
    } catch {
      return c.json({ error: 'Could not parse AI response' }, 502);
    }
    return c.json(extraction, 200);
  } catch {
    return c.json({ error: 'Failed to reach AI provider.' }, 502);
  }
}

// Mirrors buildReceiptPrompt in utils/receiptOCR.ts (client/server prompt
// copies are the established pattern — see pricebookSuggest.js). Keep the
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
