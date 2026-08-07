// utils/bookingRespond.ts
// App-side wrapper for the owner's booking decisions (Phase 11 D4):
// resolve_reschedule after moving the job, or decline. Discriminated result
// instead of Alerts, mirroring utils/bookingLink.ts — Today's booking rows
// own presentation. The server frees the reservation and emails the
// customer (on decline); the device picks the status change up on the next
// pull, so callers refresh local state in memory and let sync converge.

import Constants from "expo-constants";
import { supabase } from "./supabase";

const BACKEND_URL = (Constants.expoConfig?.extra as { backendUrl?: string } | undefined)?.backendUrl;

export type BookingRespondAction = "resolve_reschedule" | "decline";

export type RespondResult =
  | { ok: true; status: string }
  | { ok: false; reason: "no-backend" | "signed-out" | "server" | "network"; message: string };

export async function respondToBooking(
  requestId: string,
  action: BookingRespondAction
): Promise<RespondResult> {
  if (!BACKEND_URL) {
    return { ok: false, reason: "no-backend", message: "Responding needs a network connection." };
  }
  try {
    const { data: sess } = await supabase.auth.getSession();
    const jwt = sess.session?.access_token;
    if (!jwt) {
      return { ok: false, reason: "signed-out", message: "Please sign in to respond." };
    }
    const res = await fetch(`${BACKEND_URL}/api/booking/respond`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${jwt}` },
      body: JSON.stringify({ requestId, action }),
    });
    const out = await res.json();
    if (!res.ok) {
      return { ok: false, reason: "server", message: out.error || "Please try again." };
    }
    return { ok: true, status: out.status as string };
  } catch {
    return { ok: false, reason: "network", message: "Please check your connection and try again." };
  }
}
