// backend-workers/lib/estimate/cors.js
// Origin allowlist for the browser-facing estimate + booking endpoints.
// Workers port of backend/lib/estimate/cors.js: applyCors takes the Hono
// context (headers set via c.header) and the ESTIMATE_PUBLIC_ORIGIN escape
// hatch is read per-request from c.env instead of module-level process.env.
//
// Deliberately an allowlist of BOTH the github.io host and the branded custom
// domain, not a swap. Moving the approval page to a custom domain otherwise
// needs a flag day: change it here first and links in already-sent emails break;
// change DNS first and newly minted links point at a host that isn't serving
// yet. Accepting both means the page works from whichever host serves it,
// including while GitHub Pages is 301-ing the old URLs to the new domain.
//
// createLink is NOT included here — the app calls it with a native fetch, where
// CORS does not apply.

const GITHUB_PAGES_ORIGIN = 'https://czilla57.github.io';

// Every host the approval page has been or will be served from, kept as a
// cumulative list rather than swapped one-for-one.
//
// GitHub Pages allows a single custom domain per repo and 301s the others to
// it, so a link minted under an old host still lands on the current one — but
// the browser then reports the CURRENT host as the Origin. Retiring an entry
// here would therefore break links that are already in customers' inboxes, and
// the failure is silent (the page renders, then claims the link is invalid).
// Entries are cheap; leave them.
const ALLOWED_ORIGINS = [
  GITHUB_PAGES_ORIGIN,                          // original Pages host
  'https://estimates.gettradereadyapp.com',     // first branded host
  'https://gettradereadyapp.com',               // apex — the intended home
  'https://www.gettradereadyapp.com',           // www, in case it serves directly
];

/**
 * The value to send back in Access-Control-Allow-Origin.
 *
 * Echoes the caller's origin when it is allowed. Falls back to the github.io
 * host for anything else (including a missing Origin header, which is what
 * curl and same-origin requests send) so the header is never empty and never
 * a wildcard. `extraOrigin` is the ESTIMATE_PUBLIC_ORIGIN escape hatch for a
 * host not anticipated here; additive, never a replacement.
 */
function pickAllowedOrigin(origin, extraOrigin) {
  if (ALLOWED_ORIGINS.includes(origin)) return origin;
  if (extraOrigin && origin === extraOrigin) return origin;
  return GITHUB_PAGES_ORIGIN;
}

/**
 * Applies the CORS headers shared by view and respond. `Vary: Origin` matters
 * because the response now differs by origin — without it a cache could serve
 * one host's header to the other and break the page.
 */
function applyCors(c, methods) {
  c.header('Access-Control-Allow-Origin', pickAllowedOrigin(c.req.header('origin'), c.env.ESTIMATE_PUBLIC_ORIGIN));
  c.header('Vary', 'Origin');
  c.header('Access-Control-Allow-Methods', methods);
  c.header('Access-Control-Allow-Headers', 'Content-Type');
}

module.exports = { ALLOWED_ORIGINS, GITHUB_PAGES_ORIGIN, pickAllowedOrigin, applyCors };
