import AsyncStorage from "@react-native-async-storage/async-storage";
import { enqueueCollectionChanges, trySync } from "../sync";
import { KEYS } from "./keys";
import type { RecurringInvoice } from "../../types/models";

export async function loadRecurringInvoices(): Promise<RecurringInvoice[]> {
  try {
    const raw = await AsyncStorage.getItem(KEYS.recurringInvoices);
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

export async function saveRecurringInvoices(rules: RecurringInvoice[]): Promise<void> {
  const oldRaw = await AsyncStorage.getItem(KEYS.recurringInvoices);
  const old: RecurringInvoice[] = oldRaw ? JSON.parse(oldRaw) : [];
  await AsyncStorage.setItem(KEYS.recurringInvoices, JSON.stringify(rules));
  await enqueueCollectionChanges("recurringInvoices", old, rules);
  trySync();
}
