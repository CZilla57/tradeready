// utils/duplicateCustomers.ts
// Possible-duplicate detection behind the Customers-list prompt that routes
// into the merge flow (utils/customerMerge.ts). Two active customers look like
// duplicates when their normalized names match, their phones match digit-for-
// digit, or their emails match case-insensitively. Detection is pure; the
// per-pair dismissals persist under a feature-local AsyncStorage key that
// clearAllUserData MUST wipe (utils/storage/lifecycle.ts) — customer names in
// dismissal keys are not, but the keys pair this account's record ids, and a
// stale dismissal leaking into the next account would silently hide its
// legitimate prompt.

import AsyncStorage from "@react-native-async-storage/async-storage";
import type { Customer } from "../types/models";
import { isArchived } from "./archive";

export const DISMISSED_DUPLICATES_STORAGE_KEY = "dismissed_duplicate_pairs";

export type DuplicateReason = "name" | "phone" | "email";

export interface DuplicatePair {
  a: Customer;
  b: Customer;
  reason: DuplicateReason;
  /** Stable id-order-independent key — what dismissals are stored against. */
  key: string;
}

export function pairKey(id1: string, id2: string): string {
  return id1 < id2 ? `${id1}|${id2}` : `${id2}|${id1}`;
}

const nameKey = (s: string | null | undefined): string =>
  (s || "").trim().toLowerCase().replace(/\s+/g, " ");

const phoneKey = (s: string | null | undefined): string => {
  const digits = (s || "").replace(/\D/g, "");
  // Short digit runs ("911", extension fragments) match too easily to mean
  // "same person".
  return digits.length >= 7 ? digits : "";
};

const emailKey = (s: string | null | undefined): string => (s || "").trim().toLowerCase();

function matchReason(a: Customer, b: Customer): DuplicateReason | null {
  if (nameKey(a.name) && nameKey(a.name) === nameKey(b.name)) return "name";
  if (phoneKey(a.phone) && phoneKey(a.phone) === phoneKey(b.phone)) return "phone";
  if (emailKey(a.email) && emailKey(a.email) === emailKey(b.email)) return "email";
  return null;
}

/** Every active-customer pair that looks like the same person, in list order. */
export function findDuplicateCustomerPairs(customers: Customer[]): DuplicatePair[] {
  const active = customers.filter((c) => c.id && !isArchived(c));
  const pairs: DuplicatePair[] = [];
  for (let i = 0; i < active.length; i++) {
    for (let j = i + 1; j < active.length; j++) {
      const reason = matchReason(active[i], active[j]);
      if (reason) {
        pairs.push({ a: active[i], b: active[j], reason, key: pairKey(active[i].id, active[j].id) });
      }
    }
  }
  return pairs;
}

export function filterUndismissed(pairs: DuplicatePair[], dismissedKeys: Iterable<string>): DuplicatePair[] {
  const dismissed = new Set(dismissedKeys);
  return pairs.filter((p) => !dismissed.has(p.key));
}

export async function loadDismissedPairs(): Promise<string[]> {
  try {
    const raw = await AsyncStorage.getItem(DISMISSED_DUPLICATES_STORAGE_KEY);
    const parsed = raw ? JSON.parse(raw) : [];
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

export async function dismissPair(key: string): Promise<void> {
  const current = await loadDismissedPairs();
  if (current.includes(key)) return;
  await AsyncStorage.setItem(DISMISSED_DUPLICATES_STORAGE_KEY, JSON.stringify([...current, key]));
}
