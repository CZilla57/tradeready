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

export async function saveBookingRequests(requests: BookingRequest[]): Promise<void> {
  const oldRaw = await AsyncStorage.getItem(KEYS.bookingRequests);
  const old: BookingRequest[] = oldRaw ? JSON.parse(oldRaw) : [];
  await AsyncStorage.setItem(KEYS.bookingRequests, JSON.stringify(requests));
  await enqueueCollectionChanges("bookingRequests", old, requests);
  trySync();
}
