import AsyncStorage from "@react-native-async-storage/async-storage";
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
  await AsyncStorage.setItem(KEYS.recurringInvoices, JSON.stringify(rules));
}
