// Cooldown gate for the signup-confirmation "Resend email" action.
// Supabase rate-limits resend to roughly one per minute per address, so the
// UI enforces the same window instead of letting the user trip a server error.
// Pure functions with an injected clock (same pattern as utils/dateHelpers.ts).

export const RESEND_COOLDOWN_MS = 60_000;

export function canResend(lastSentAtMs: number | null, nowMs: number = Date.now()): boolean {
  if (lastSentAtMs === null) return true;
  return nowMs - lastSentAtMs >= RESEND_COOLDOWN_MS;
}

export function resendSecondsRemaining(lastSentAtMs: number | null, nowMs: number = Date.now()): number {
  if (lastSentAtMs === null) return 0;
  const remainingMs = RESEND_COOLDOWN_MS - (nowMs - lastSentAtMs);
  return remainingMs > 0 ? Math.ceil(remainingMs / 1000) : 0;
}
