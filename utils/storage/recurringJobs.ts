import AsyncStorage from "@react-native-async-storage/async-storage";
import { KEYS } from "./keys";
import type { RecurringJob } from "../../types/models";

export async function loadRecurringJobs(): Promise<RecurringJob[]> {
  try {
    const raw = await AsyncStorage.getItem(KEYS.recurringJobs);
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

export async function saveRecurringJobs(rules: RecurringJob[]): Promise<void> {
  await AsyncStorage.setItem(KEYS.recurringJobs, JSON.stringify(rules));
}
