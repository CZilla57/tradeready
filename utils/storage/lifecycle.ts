// utils/storage/lifecycle.ts
// App-lifecycle storage operations that span multiple collections: onboarding
// state, clearing the sample data after onboarding, and the full local wipe on
// sign-out. These go through the collection save functions (not raw
// AsyncStorage) so deletes are enqueued and synced.

import AsyncStorage from "@react-native-async-storage/async-storage";
import * as SecureStore from "expo-secure-store";
import { KEYS } from "./keys";
import { SECURE_FIELDS, loadSettings } from "./settings";
import { defaultSettings } from "./defaults";
import {
  loadInvoices, loadJobs, loadCustomers, loadExpenses,
  saveInvoices, saveJobs, saveCustomers, saveExpenses,
} from "./collections";
import { isSampleId } from "../sampleData";
import { SESSION_STORAGE_KEY } from "../secureStoreAdapter";

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
  const allKeys = await AsyncStorage.getAllKeys();
  const initDoneKeys = allKeys.filter(k => k.startsWith("__initDone_"));

  await AsyncStorage.multiRemove([
    ...Object.values(KEYS),
    "__syncQueue",
    "__lastSyncedAt",
    "__dataOwner",
    "onboardingComplete",
    ...initDoneKeys,
  ]);
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
