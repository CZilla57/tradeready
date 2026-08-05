// utils/stripeStatus.ts
// Stripe Connect status for the signed-in user — shared by the Settings
// hub (Payments row subtitle) and SettingsPaymentsScreen. Never throws.
// Owns the setup checklist's "stripe" completion signal, exactly where the
// old SettingsScreen fetch fired it.
import Constants from "expo-constants";
import { supabase } from "./supabase";
import { markSetupTaskDone } from "./setupChecklist";

const VERCEL_URL = Constants.expoConfig?.extra?.backendUrl ?? "";

export interface StripeStatus {
  connected: boolean;
  details_submitted?: boolean;
  display_name?: string;
  _error?: string;
}

export async function fetchStripeConnectStatus(): Promise<StripeStatus> {
  if (!VERCEL_URL) return { connected: false };
  try {
    const { data: { session } } = await supabase.auth.getSession();
    if (!session?.access_token) return { connected: false };
    const res = await fetch(`${VERCEL_URL}/api/stripe/connect-status`, {
      headers: { Authorization: `Bearer ${session.access_token}` },
    });
    const data = await res.json();
    if (res.ok) {
      if (data?.connected) markSetupTaskDone("stripe");
      return data;
    }
    return { connected: false, _error: data?.error };
  } catch {
    return { connected: false };
  }
}
