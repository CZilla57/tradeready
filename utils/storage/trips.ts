import AsyncStorage from "@react-native-async-storage/async-storage";
import { enqueueCollectionChanges, trySync } from "../sync";
import { KEYS } from "./keys";
import type { Trip } from "../../types/models";

export async function loadTrips(): Promise<Trip[]> {
  try {
    const raw = await AsyncStorage.getItem(KEYS.trips);
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

export async function saveTrips(trips: Trip[]): Promise<void> {
  const oldRaw = await AsyncStorage.getItem(KEYS.trips);
  const old: Trip[] = oldRaw ? JSON.parse(oldRaw) : [];
  await AsyncStorage.setItem(KEYS.trips, JSON.stringify(trips));
  await enqueueCollectionChanges("trips", old, trips);
  trySync();
}
