// Best-effort "City, ST" extraction from a free-text US business address,
// used to prefill the onboarding region field (device feedback 2026-07-14).
// Deliberately conservative: when the string doesn't look like it contains a
// city, return "" and let the user type — a wrong guess is worse than none.

const ZIP_RE = /^\d{5}(-\d{4})?$/;
const STATE_RE = /^[A-Za-z]{2}$/;

export function regionFromAddress(address: string): string {
  const segments = address
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);

  // A single segment is just a street line — nothing safe to infer.
  if (segments.length < 2) return "";

  const last = segments[segments.length - 1];
  const tokens = last.split(/\s+/).filter(Boolean);

  // Drop a trailing ZIP (5 or 5+4) so the state ends the token list.
  if (tokens.length > 0 && ZIP_RE.test(tokens[tokens.length - 1])) {
    tokens.pop();
  }

  if (tokens.length > 0 && STATE_RE.test(tokens[tokens.length - 1])) {
    const state = tokens.pop()!.toUpperCase();
    // City is whatever precedes the state in this segment, or the previous
    // segment in the "street, city, ST zip" format.
    const city = tokens.length > 0 ? tokens.join(" ") : segments[segments.length - 2];
    // If the "city" we found is the street line itself, don't guess.
    if (city === segments[0] && segments.length === 2) return state;
    return `${city}, ${state}`;
  }

  // No state token — fall back to the last segment (sans zip) as the city,
  // but only when it isn't the street line.
  const cityOnly = tokens.join(" ");
  return cityOnly && last !== segments[0] ? cityOnly : "";
}
