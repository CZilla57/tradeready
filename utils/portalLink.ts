// utils/portalLink.ts
// App-side plumbing for the per-customer portal link (2026-08-04 portal
// spec §3, §6). The token is minted server-side by the SAME stateless
// endpoint the booking link uses — it is a purpose-agnostic secure RNG, so
// this module re-exports the existing wrapper under a portal name instead
// of forking a second fetch wrapper. The caller writes the token onto the
// customer record; normal sync publishes it.

import { mintBookingToken } from "./bookingLink";
import type { MintResult } from "./bookingLink";

export const PORTAL_PUBLIC_BASE = "https://gettradereadyapp.com/portal.html";

export function buildPortalUrl(token: string): string {
  return `${PORTAL_PUBLIC_BASE}?p=${encodeURIComponent(token)}`;
}

export const mintPortalToken: () => Promise<MintResult> = mintBookingToken;
export type { MintResult };
