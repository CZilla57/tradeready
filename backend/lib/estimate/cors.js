// backend/lib/estimate/cors.js
// Origin allowlist for the two browser-facing estimate endpoints (view, respond).
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

// Override per-environment if the branded host ever changes; the default is the
// domain the CNAME in the tradeready-legal repo points at.
const BRANDED_ORIGIN = process.env.ESTIMATE_PUBLIC_ORIGIN || 'https://estimates.gettradereadyapp.com';

const ALLOWED_ORIGINS = [GITHUB_PAGES_ORIGIN, BRANDED_ORIGIN];

/**
 * The value to send back in Access-Control-Allow-Origin.
 *
 * Echoes the caller's origin when it is allowed. Falls back to the github.io
 * host for anything else (including a missing Origin header, which is what
 * curl and same-origin requests send) so the header is never empty and never
 * a wildcard.
 */
function pickAllowedOrigin(origin) {
  return ALLOWED_ORIGINS.includes(origin) ? origin : GITHUB_PAGES_ORIGIN;
}

/**
 * Applies the CORS headers shared by view and respond. `Vary: Origin` matters
 * because the response now differs by origin — without it a cache could serve
 * one host's header to the other and break the page.
 */
function applyCors(req, res, methods) {
  res.setHeader('Access-Control-Allow-Origin', pickAllowedOrigin(req.headers?.origin));
  res.setHeader('Vary', 'Origin');
  res.setHeader('Access-Control-Allow-Methods', methods);
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
}

module.exports = { ALLOWED_ORIGINS, GITHUB_PAGES_ORIGIN, BRANDED_ORIGIN, pickAllowedOrigin, applyCors };
