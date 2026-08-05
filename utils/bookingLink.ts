// utils/bookingLink.ts
// App-side plumbing for the public booking link (2026-08-04 spec §4, §8).
// The token itself is minted SERVER-side (the device has no secure RNG) and
// stored in the settings blob by the caller; this module only talks to the
// mint endpoint and builds the shareable URL. Discriminated result instead of
// Alerts, mirroring utils/estimateApprovalLink.ts, so the Settings screen
// owns presentation.

import Constants from "expo-constants";
import { supabase } from "./supabase";

const BACKEND_URL = (Constants.expoConfig?.extra as { backendUrl?: string } | undefined)?.backendUrl;

export const BOOKING_PUBLIC_BASE = "https://gettradereadyapp.com/book.html";

export type MintResult =
  | { ok: true; token: string }
  | { ok: false; reason: "no-backend" | "signed-out" | "server" | "network"; message: string };

export function buildBookingUrl(token: string): string {
  return `${BOOKING_PUBLIC_BASE}?b=${encodeURIComponent(token)}`;
}

export async function mintBookingToken(): Promise<MintResult> {
  if (!BACKEND_URL) {
    return { ok: false, reason: "no-backend", message: "Booking links need a network connection." };
  }
  try {
    const { data: sess } = await supabase.auth.getSession();
    const jwt = sess.session?.access_token;
    if (!jwt) {
      return { ok: false, reason: "signed-out", message: "Please sign in to create a booking link." };
    }
    const res = await fetch(`${BACKEND_URL}/api/booking/mint`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${jwt}` },
    });
    const out = await res.json();
    if (!res.ok) {
      return { ok: false, reason: "server", message: out.error || "Please try again." };
    }
    return { ok: true, token: out.token as string };
  } catch {
    return { ok: false, reason: "network", message: "Please check your connection and try again." };
  }
}
