import AsyncStorage from "@react-native-async-storage/async-storage";
import { enqueueCollectionChanges, trySync } from "../sync";
import { KEYS } from "./keys";
import type { JobPhoto } from "../../types/models";

// Synced collection of per-job photo records (2026-08-06 job-photo R2 sync
// spec). Same load/save contract as every other collection: the local write is
// instant/offline-safe, the diff is enqueued, and a background push+pull is
// fire-and-forgotten. The actual image bytes live on device disk + R2 (see
// utils/photoSync.ts) — these records only carry metadata.

export async function loadJobPhotos(): Promise<JobPhoto[]> {
  try {
    const raw = await AsyncStorage.getItem(KEYS.jobPhotos);
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

export async function saveJobPhotos(photos: JobPhoto[]): Promise<void> {
  const oldRaw = await AsyncStorage.getItem(KEYS.jobPhotos);
  const old: JobPhoto[] = oldRaw ? JSON.parse(oldRaw) : [];
  await AsyncStorage.setItem(KEYS.jobPhotos, JSON.stringify(photos));
  await enqueueCollectionChanges("jobPhotos", old, photos);
  trySync();
}

/**
 * Flip a photo's portal visibility (Phase 12B). Goes through the normal
 * load → map → save path so the change diff-enqueues and syncs like any
 * other record edit. Returns the updated record, or null for an unknown id.
 */
export async function setJobPhotoVisibility(photoId: string, visible: boolean): Promise<JobPhoto | null> {
  const photos = await loadJobPhotos();
  const idx = photos.findIndex((p) => p.id === photoId);
  if (idx === -1) return null;
  const updated: JobPhoto = { ...photos[idx], customerVisible: visible };
  const next = photos.slice();
  next[idx] = updated;
  await saveJobPhotos(next);
  return updated;
}
