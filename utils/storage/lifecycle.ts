// utils/storage/lifecycle.ts
// App-lifecycle storage operations that span multiple collections: onboarding
// state, clearing the sample data after onboarding, and the full local wipe on
// sign-out. These go through the collection save functions (not raw
// AsyncStorage) so deletes are enqueued and synced.

import AsyncStorage from "@react-native-async-storage/async-storage";
import * as SecureStore from "expo-secure-store";
import { KEYS, SECURE_FIELDS, REMINDER_PROMPT_KEY } from "./keys";
import { loadSettings } from "./settings";
import { defaultSettings, defaultInvoices, resetSampleSeed } from "./defaults";
import {
  loadInvoices, loadJobs, loadCustomers, loadExpenses,
  saveInvoices, saveJobs, saveCustomers, saveExpenses,
} from "./collections";
import { isSampleId } from "../sampleData";
import { clearWidgetSnapshot } from "../widgetBridge";
import { SESSION_STORAGE_KEY } from "../secureStoreAdapter";
import { REVIEW_REQUESTS_STORAGE_KEY } from "../reviewRequest";
import { DISMISSED_DUPLICATES_STORAGE_KEY } from "../duplicateCustomers";
import { INSIGHT_MUTES_STORAGE_KEY } from "../insightMutes";
import { ONBOARDING_DRAFT_KEY } from "../onboardingDraft";
import { SETUP_CHECKLIST_STATE_KEY } from "../setupChecklist";
import type { TradeId } from "../../types/models";

// --- Onboarding ---

export async function isOnboardingComplete(): Promise<boolean> {
  try {
    const val = await AsyncStorage.getItem("onboardingComplete");
    if (val === "true") return true;
    // Graceful fallback: users who set up the app before onboarding existed
    const settings = await loadSettings();
    return settings.businessName !== defaultSettings().businessName;
  } catch {
    return false;
  }
}

export async function markOnboardingComplete(): Promise<void> {
  await AsyncStorage.setItem("onboardingComplete", "true");
}

// --- Starting-point choice (post-paywall, 2026-08-03 flow restructure) ---
//
// The wizard now stops after personalization; the sample-vs-fresh choice moved
// BEHIND the subscription decision. The stage key tracks only the gap between
// the two: "personalized" means the wizard finished but no starting point was
// chosen yet. An ABSENT key means the choice is not owed — that covers users
// who onboarded under the old flow (they already chose during onboarding) and
// returning users whose local state was wiped and restored from the cloud, so
// neither group can be re-prompted into re-seeding sample data.

const ONBOARDING_STAGE_KEY = "onboardingStage";

export async function markOnboardingPersonalized(): Promise<void> {
  await AsyncStorage.setItem(ONBOARDING_STAGE_KEY, "personalized");
}

export async function isStartChoiceComplete(): Promise<boolean> {
  try {
    return (await AsyncStorage.getItem(ONBOARDING_STAGE_KEY)) !== "personalized";
  } catch {
    return true;
  }
}

export async function completeStartChoice(
  choice: "sample" | "fresh",
  trade: TradeId
): Promise<void> {
  if (choice === "fresh") {
    await clearSampleData();
  } else {
    // Re-save the invoice seeds so their descriptions match the chosen trade
    // and the sample set syncs like the pre-restructure onboarding did.
    await saveInvoices(defaultInvoices(trade));
  }
  await AsyncStorage.setItem(ONBOARDING_STAGE_KEY, "done");
}

export async function clearSampleData(): Promise<void> {
  // Use the save functions so each collection's deletes are enqueued and
  // synced to the cloud — prevents sample records from re-appearing on
  // other devices or after reinstall. Filters by sample id (legacy or
  // namespaced — utils/sampleData.ts) rather than saving empty arrays: the
  // Settings alert promises "your own data is not affected", and until
  // 2026-07-14 this wiped the user's real records along with the samples.
  const [invoices, jobs, customers, expenses] = await Promise.all([
    loadInvoices(),
    loadJobs(),
    loadCustomers(),
    loadExpenses(),
  ]);
  await Promise.all([
    saveInvoices(invoices.filter(r => !isSampleId(r.id))),
    saveJobs(jobs.filter(r => !isSampleId(r.id))),
    saveCustomers(customers.filter(r => !isSampleId(r.id))),
    saveExpenses(expenses.filter(r => !isSampleId(r.id))),
    AsyncStorage.removeItem(KEYS.customerNotes),
  ]);
}

// Wipes all local user data on sign-out so the next user to sign in on this
// device cannot inherit another user's records or trigger an accidental cloud push.
export async function clearAllUserData(): Promise<void> {
  // Rotate the sample-id namespace before the wipe: any read after this
  // re-seeds, and reusing this launch's suffix would collide with seed rows
  // the outgoing account may have already pushed (see defaults.ts).
  resetSampleSeed();

  const allKeys = await AsyncStorage.getAllKeys();
  const initDoneKeys = allKeys.filter(k => k.startsWith("__initDone_"));

  await AsyncStorage.multiRemove([
    ...Object.values(KEYS),
    // Feature-local keys outside KEYS: review-request records carry customer
    // name/phone/email snapshots, and dismissed-duplicate keys pair this
    // account's record ids — neither may leak to the next account.
    REVIEW_REQUESTS_STORAGE_KEY,
    DISMISSED_DUPLICATES_STORAGE_KEY,
    // Insight mutes embed this account's job/customer/invoice ids; a stale
    // mute leaking into the next account would silently hide its insights.
    INSIGHT_MUTES_STORAGE_KEY,
    "__syncQueue",
    // v2 keeps the existing key but changes its value to a versioned,
    // database-clock cursor. Clearing it remains part of the account boundary.
    "__lastSyncedAt",
    "__dataOwner",
    "onboardingComplete",
    ONBOARDING_STAGE_KEY,
    ONBOARDING_DRAFT_KEY,
    SETUP_CHECKLIST_STATE_KEY,
    REMINDER_PROMPT_KEY,
    ...initDoneKeys,
  ]);
  // Widget bridge: wipe the App Group container so the next account on this
  // device can't see this account's next job/customer in a home-screen widget
  // (no-op until the native module ships — utils/widgetBridge.ts). Never
  // throws, so it can't block the rest of the wipe.
  await clearWidgetSnapshot();

  for (const field of SECURE_FIELDS) {
    try { await SecureStore.deleteItemAsync(field); } catch {}
  }
  // Clean up legacy key in case migration never ran
  try { await SecureStore.deleteItemAsync("geminiKey"); } catch {}

  // Clean up the (possibly chunked) Supabase auth session. supabase.auth.signOut()
  // also clears its own key, but this runs first in the sign-out flow and is a
  // safety net if that call fails or is skipped (e.g. account deletion, offline).
  // Bounded loop (max 10 chunks =~ 20KB) rather than probing with getItemAsync
  // first — this is cleanup, so a couple of wasted no-op deletes are cheaper
  // and simpler than an extra round-trip per key, and a missed chunk is harmless.
  await SecureStore.deleteItemAsync(SESSION_STORAGE_KEY).catch(() => {});
  for (let i = 1; i <= 10; i++) {
    await SecureStore.deleteItemAsync(`${SESSION_STORAGE_KEY}_chunk_${i}`).catch(() => {});
  }
}
