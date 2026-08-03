// Durable per-user daily usage cap for the AI proxy endpoints — the second
// layer behind the in-memory per-instance limiter in guards.js (security
// roadmap item 8). Counts live in the ai_usage_log Supabase table
// (supabase/migrations/20260803_ai_usage_log.sql), written with the service
// role exactly like backend/lib/estimateStore.js. NOT routed by Vercel
// (lives under lib/, not api/).
//
// Design: one row is INSERTed per allowed request; the gate is a HEAD count of
// today's (UTC) rows for that user + endpoint. No read-modify-write on a
// counter row, so there is no lost-update race — concurrent requests can
// overshoot the cap by at most the concurrency factor, which is fine for a
// cost ceiling. Availability-first posture: any counter-infrastructure failure
// (Supabase unreachable, table missing, unparseable response) fails OPEN with
// a console.warn — only a cleanly-read at/over-cap count blocks with 429.
//
// Required Vercel env vars (already set for other endpoints):
//   SUPABASE_URL
//   SUPABASE_SERVICE_ROLE_KEY

// Owner-tunable daily caps per endpoint. PROVISIONAL numbers — tune against
// real usage in the Groq console / Vercel logs. Rationale for the defaults:
//   ai-chat: conversational, one row per user turn; 200/day is ~4x a very
//     heavy legitimate day and the cheapest call (600 max_tokens text).
//   pricebook-suggest: one-shot per pricebook entry; building an entire
//     pricebook in one sitting is a few dozen entries, so 100/day is generous.
//   receipt-extract: vision — the most expensive proxy call; a big catch-up
//     bookkeeping day is maybe 50 receipts, so 100/day leaves headroom.
const DAILY_CAPS = {
  "ai-chat": 200,
  "pricebook-suggest": 100,
  "receipt-extract": 100,
};

// Client-safe message. Distinct from the per-minute limiter's "wait a minute"
// 429 so support/users can tell the two apart.
const DAILY_CAP_MESSAGE =
  "Daily AI limit reached. Your limit resets at midnight UTC — please try again tomorrow.";

// Returns { allowed: true } or { allowed: false, error: <client-safe string> }.
// When allowed, the request has already been recorded (best-effort — a failed
// insert warns but never blocks).
async function enforceDailyCap(userId, endpoint) {
  const cap = DAILY_CAPS[endpoint];
  if (!cap || !userId) return { allowed: true }; // unknown endpoint / no attributable user → nothing to meter

  const SUPABASE_URL = process.env.SUPABASE_URL;
  const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!SUPABASE_URL || !SERVICE_KEY) {
    console.warn("[aiUsage] SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY not set — daily cap disabled (fail-open).");
    return { allowed: true };
  }

  const baseUrl = `${SUPABASE_URL}/rest/v1/ai_usage_log`;
  const authHeaders = {
    Authorization: `Bearer ${SERVICE_KEY}`,
    apikey: SERVICE_KEY,
  };

  const dayStart = new Date();
  dayStart.setUTCHours(0, 0, 0, 0);

  let count;
  try {
    const res = await fetch(
      `${baseUrl}?user_id=eq.${encodeURIComponent(userId)}&endpoint=eq.${encodeURIComponent(endpoint)}&created_at=gte.${encodeURIComponent(dayStart.toISOString())}&select=id`,
      {
        method: "HEAD",
        headers: { ...authHeaders, Prefer: "count=exact", "Range-Unit": "items", Range: "0-0" },
      }
    );
    if (!res.ok) throw new Error(`count request failed: ${res.status}`);
    // PostgREST reports the total after the slash: "0-0/42", or "*/0" for none.
    const contentRange = res.headers.get("content-range") || "";
    count = parseInt(contentRange.split("/")[1], 10);
    if (Number.isNaN(count)) throw new Error(`unparseable content-range "${contentRange}"`);
  } catch (err) {
    console.warn(
      `[aiUsage] daily-cap check failed for ${endpoint} — allowing request (fail-open):`,
      err && err.message
    );
    return { allowed: true };
  }

  if (count >= cap) {
    return { allowed: false, error: DAILY_CAP_MESSAGE };
  }

  // Record this allowed request. Best-effort: a failed insert must never block.
  try {
    const res = await fetch(baseUrl, {
      method: "POST",
      headers: { ...authHeaders, "Content-Type": "application/json", Prefer: "return=minimal" },
      body: JSON.stringify({ user_id: userId, endpoint }),
    });
    if (!res.ok) throw new Error(`insert failed: ${res.status}`);
  } catch (err) {
    console.warn("[aiUsage] failed to record usage row (request still allowed):", err && err.message);
  }
  return { allowed: true };
}

module.exports = { enforceDailyCap, DAILY_CAPS, DAILY_CAP_MESSAGE };
