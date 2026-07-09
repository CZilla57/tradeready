// utils/storage/pricebook.ts
// The pricebook collection — reusable estimate line-item templates.
// Follows the same synced-collection pattern as invoices/jobs/customers/expenses
// (see ./collections.ts): load falls back to [] on a cold cache; save writes
// AsyncStorage, diffs old→new into the sync queue, and kicks a background sync.

import AsyncStorage from "@react-native-async-storage/async-storage";
import { enqueueCollectionChanges, trySync } from "../sync";
import { KEYS } from "./keys";
import type { PricebookEntry } from "../../types/models";

export async function loadPricebook(): Promise<PricebookEntry[]> {
  try {
    const raw = await AsyncStorage.getItem(KEYS.pricebook);
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

export async function savePricebook(entries: PricebookEntry[]): Promise<void> {
  const oldRaw = await AsyncStorage.getItem(KEYS.pricebook);
  const old: PricebookEntry[] = oldRaw ? JSON.parse(oldRaw) : [];
  await AsyncStorage.setItem(KEYS.pricebook, JSON.stringify(entries));
  await enqueueCollectionChanges("pricebook", old, entries);
  trySync();
}
