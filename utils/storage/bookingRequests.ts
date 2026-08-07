import AsyncStorage from "@react-native-async-storage/async-storage";
import { enqueueCollectionChanges, trySync } from "../sync";
import { KEYS } from "./keys";
import type { BookingRequest } from "../../types/models";

export async function loadBookingRequests(): Promise<BookingRequest[]> {
  try {
    const raw = await AsyncStorage.getItem(KEYS.bookingRequests);
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

/**
 * Owner dismissal of a portal change request (Phase 12C): stamps handledAt
 * through the normal synced save path so every device drops the Today row.
 * No-op for unknown ids and already-handled rows (a save re-enqueues the
 * whole collection — never write when nothing changed).
 */
export async function markBookingRequestHandled(requestId: string, nowIso: string): Promise<void> {
  const requests = await loadBookingRequests();
  const idx = requests.findIndex((r) => r.id === requestId);
  if (idx === -1 || requests[idx].handledAt) return;
  const next = requests.slice();
  next[idx] = { ...next[idx], handledAt: nowIso };
  await saveBookingRequests(next);
}

export async function saveBookingRequests(requests: BookingRequest[]): Promise<void> {
  const oldRaw = await AsyncStorage.getItem(KEYS.bookingRequests);
  const old: BookingRequest[] = oldRaw ? JSON.parse(oldRaw) : [];
  await AsyncStorage.setItem(KEYS.bookingRequests, JSON.stringify(requests));
  await enqueueCollectionChanges("bookingRequests", old, requests);
  trySync();
}
