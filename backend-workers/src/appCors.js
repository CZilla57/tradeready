// Shared CORS block for the app-facing endpoints (ai-chat, pricebook-suggest,
// receipt-extract, delete-account, create-payment-link, stripe connect-status/
// create-connect-account/disconnect). On Vercel this exact block was inlined
// verbatim in each of those 8 handlers; centralizing the IDENTICAL block is
// behavior-preserving. The estimate/booking public endpoints use a different
// policy (github.io fallback, Vary: Origin, no Authorization header) — that
// one lives in lib/estimate/cors.js, deliberately NOT unified with this.
//
// Real hosts this project serves — tradeready.app was never ours (dead entry
// from the original scaffold; see lib/estimate/cors.js for the canonical list
// rationale).
const ALLOWED_ORIGINS = [
  'https://estimates.gettradereadyapp.com',
  'https://gettradereadyapp.com',
  'https://www.gettradereadyapp.com',
  'https://czilla57.github.io',
];

export function appCors(c, methods) {
  const origin = c.req.header('origin');
  c.header(
    'Access-Control-Allow-Origin',
    origin && ALLOWED_ORIGINS.includes(origin) ? origin : 'https://gettradereadyapp.com'
  );
  c.header('Access-Control-Allow-Methods', methods);
  c.header('Access-Control-Allow-Headers', 'Content-Type, Authorization');
}

// Client IP for rate limiting and consent records. cf-connecting-ip is set by
// Cloudflare's edge and can't be supplied by the caller. x-forwarded-for is
// only a fallback for local runs without the edge: Cloudflare appends to a
// caller-sent x-forwarded-for, so its first entry is attacker-chosen and
// must never win when cf-connecting-ip is present.
export function clientIp(c) {
  const edge = (c.req.header('cf-connecting-ip') || '').trim();
  if (edge) return edge;
  return (c.req.header('x-forwarded-for') || 'unknown').split(',')[0].trim() || 'unknown';
}

// Vercel's bodyParser leaves req.body undefined when absent/unparseable and
// every handler guards with `req.body || {}`; mirror that instead of letting
// c.req.json() throw.
export async function jsonBody(c) {
  return c.req.json().catch(() => undefined);
}
