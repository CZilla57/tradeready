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
import { saveInvoices, saveJobs, saveCustomers, saveExpenses } from "./collections";

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
  // other devices or after reinstall.
  await Promise.all([
    saveInvoices([]),
    saveJobs([]),
    saveCustomers([]),
    saveExpenses([]),
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
}
