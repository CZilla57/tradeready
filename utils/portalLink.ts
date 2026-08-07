// utils/portalLink.ts
// App-side plumbing for the per-customer portal link. Phase 12D: tokens are
// SERVER-OWNED (portal_tokens table) — managePortal is the owner-side wrapper
// for mint / set_enabled / rotate, and the server row is the auth authority.
// The caller still writes a DISPLAY COPY onto the customer record (URL row +
// share sheet work offline); normal sync publishes it. Discriminated result
// instead of Alerts (bookingLink / estimateApprovalLink convention).

import Constants from "expo-constants";
import { supabase } from "./supabase";

const BACKEND_URL = (Constants.expoConfig?.extra as { backendUrl?: string } | undefined)?.backendUrl;

export const PORTAL_PUBLIC_BASE = "https://gettradereadyapp.com/portal.html";

export function buildPortalUrl(token: string): string {
  return `${PORTAL_PUBLIC_BASE}?p=${encodeURIComponent(token)}`;
}

export type ManageResult =
  | { ok: true; token?: string; enabled?: boolean }
  | { ok: false; reason: "already-exists" | "no-backend" | "signed-out" | "server" | "network"; message: string };

export async function managePortal(
  action: "mint" | "set_enabled" | "rotate",
  customerId: string,
  enabled?: boolean,
): Promise<ManageResult> {
  if (!BACKEND_URL) {
    return { ok: false, reason: "no-backend", message: "Portal links need a network connection." };
  }
  try {
    const { data: sess } = await supabase.auth.getSession();
    const jwt = sess.session?.access_token;
    if (!jwt) {
      return { ok: false, reason: "signed-out", message: "Please sign in to manage portal links." };
    }
    const res = await fetch(`${BACKEND_URL}/api/estimate/portal-manage`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${jwt}` },
      body: JSON.stringify(enabled === undefined ? { action, customerId } : { action, customerId, enabled }),
    });
    const out = await res.json();
    if (res.status === 409) {
      return { ok: false, reason: "already-exists", message: "This customer already has a portal link." };
    }
    if (!res.ok) {
      return { ok: false, reason: "server", message: out.error || "Please try again." };
    }
    return { ok: true, token: out.token as string | undefined, enabled: out.enabled as boolean | undefined };
  } catch {
    return { ok: false, reason: "network", message: "Please check your connection and try again." };
  }
}
