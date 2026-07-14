// Human-readable copy for raw Supabase auth errors. The beta pass surfaced
// "email rate limit exceeded" verbatim in the UI — accurate, but useless to a
// tradesperson. Map the known cases; pass everything else through untouched.

const RATE_LIMIT_COPY =
  "Too many emails sent — check your inbox for the most recent link (it still works), or wait a few minutes and try again.";

export function friendlyAuthError(raw: string): string {
  const msg = (raw || "").trim();
  if (!msg) return "Something went wrong. Please try again.";

  const lower = msg.toLowerCase();
  if (
    lower.includes("rate limit") ||
    lower.includes("rate_limit") ||
    lower.includes("you can only request this after")
  ) {
    return RATE_LIMIT_COPY;
  }
  if (lower.includes("invalid login credentials")) {
    return "Email or password is incorrect.";
  }
  return msg;
}
