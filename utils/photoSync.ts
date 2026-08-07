// Job-photo cross-device sync orchestration (2026-08-06 R2 sync spec).
//
// Local-first INVARIANT: nothing here is ever awaited on a render path. The
// device always renders photos from disk (utils/photoStorage.jobPhotoUri); this
// module mirrors those bytes to the R2 `tradeready-photos` bucket in the
// background (via backend-workers PUT/GET/DELETE /api/photos/:photoId) so photos
// survive reinstall and appear on a user's other devices.
//
// Phase 3 (this file at first landing): capture + compress + upload of photos
// created ON this device, plus the one-time adoption migration that drains the
// legacy Job.photos URI arrays. Download/backfill of photos created on OTHER
// devices is Phase 4.

import * as FileSystem from "expo-file-system/legacy";
import Constants from "expo-constants";
import { supabase } from "./supabase";
import { loadJobs, saveJobs, loadJobPhotos, saveJobPhotos } from "./storage";
import {
  jobPhotoUri,
  saveCompressedJobPhoto,
  photoExists,
  deletePhoto,
} from "./photoStorage";
import { reportError } from "./analytics";
import type { JobPhoto } from "../types/models";

const BACKEND_URL: string = Constants.expoConfig?.extra?.backendUrl ?? "";
const BACKEND_URL_IS_PLACEHOLDER: boolean =
  Constants.expoConfig?.extra?.backendUrlIsPlaceholder ?? true;

function backendReady(): boolean {
  return !!BACKEND_URL && !BACKEND_URL_IS_PLACEHOLDER;
}

/** `p<timestamp>_<base36-rand>` — matches the backend PHOTO_ID_RE and IS the filename. */
export function newPhotoId(): string {
  return `p${Date.now()}_${Math.random().toString(36).slice(2) || "x"}`;
}

/**
 * Capture path: compress a picked image to a deterministic local file, create a
 * JobPhoto record (instant, offline-safe), then fire-and-forget the upload.
 * Returns the new record, or null if the image couldn't be saved locally.
 */
export async function attachJobPhoto(
  jobId: string,
  tempUri: string,
): Promise<JobPhoto | null> {
  const id = newPhotoId();
  const dims = await saveCompressedJobPhoto(tempUri, id);
  if (!dims) return null;

  const record: JobPhoto = {
    id,
    jobId,
    createdAt: new Date().toISOString(),
    width: dims.width,
    height: dims.height,
  };
  const photos = await loadJobPhotos();
  await saveJobPhotos([...photos, record]);
  void uploadPendingPhotos();
  return record;
}

/**
 * Upload every JobPhoto that has a local file but no confirmed R2 copy
 * (uploadedAt absent). Fire-and-forget; never throws. Triggered after an
 * attach, on app foreground, and after a pull (Phase 4). Records without a
 * local file are skipped here — they belong to another device and are the
 * download path's job (Phase 4).
 */
export async function uploadPendingPhotos(): Promise<void> {
  try {
    if (!backendReady()) return;
    const photos = await loadJobPhotos();
    const pending = photos.filter((p) => !p.uploadedAt);
    if (pending.length === 0) return;

    const { data: { session } } = await supabase.auth.getSession();
    const token = session?.access_token;
    if (!token) return;

    const uploaded = new Map<string, string>(); // photoId -> uploadedAt ISO
    for (const p of pending) {
      const uri = jobPhotoUri(p.id);
      if (!(await photoExists(uri))) continue; // another device's record — Phase 4 downloads it
      try {
        const res = await FileSystem.uploadAsync(`${BACKEND_URL}/api/photos/${p.id}`, uri, {
          httpMethod: "PUT",
          uploadType: FileSystem.FileSystemUploadType.BINARY_CONTENT,
          headers: { Authorization: `Bearer ${token}`, "Content-Type": "image/jpeg" },
        });
        if (res.status >= 200 && res.status < 300) {
          uploaded.set(p.id, new Date().toISOString());
        }
      } catch (err) {
        reportError(err, { context: "uploadPendingPhotos", photoId: p.id });
      }
    }
    if (uploaded.size === 0) return;

    // Re-read before saving so a concurrent attach isn't clobbered; stamp only
    // the records we actually confirmed, only if still unstamped.
    const latest = await loadJobPhotos();
    const merged = latest.map((p) =>
      uploaded.has(p.id) && !p.uploadedAt ? { ...p, uploadedAt: uploaded.get(p.id) } : p,
    );
    await saveJobPhotos(merged);
  } catch (err) {
    reportError(err, { context: "uploadPendingPhotos" });
  }
}

/** Best-effort R2 delete for one photo. A failed delete leaves an orphan
 * (pennies; swept at account deletion) rather than blocking the local delete. */
async function deleteRemotePhoto(photoId: string): Promise<void> {
  try {
    if (!backendReady()) return;
    const { data: { session } } = await supabase.auth.getSession();
    const token = session?.access_token;
    if (!token) return;
    await fetch(`${BACKEND_URL}/api/photos/${photoId}`, {
      method: "DELETE",
      headers: { Authorization: `Bearer ${token}` },
    });
  } catch (err) {
    reportError(err, { context: "deleteRemotePhoto", photoId });
  }
}

/**
 * Delete one photo everywhere: record (soft-deletes via the save-path diff),
 * local file, and R2 (best-effort). The record delete is what syncs to other
 * devices.
 */
export async function deleteJobPhoto(photoId: string): Promise<void> {
  const photos = await loadJobPhotos();
  await saveJobPhotos(photos.filter((p) => p.id !== photoId));
  await deletePhoto(jobPhotoUri(photoId));
  void deleteRemotePhoto(photoId);
}

/**
 * One-time adoption migration draining legacy `Job.photos` URI arrays into the
 * synced `jobPhotos` collection. Flag-free + idempotent (storage-and-sync §7):
 * once every Job.photos is empty a second run is a zero-write fast return.
 * Wired into the App.tsx sign-in chain alongside migrateCustomerIdentity.
 */
export async function migrateLegacyJobPhotos(): Promise<void> {
  try {
    const jobs = await loadJobs();
    if (!jobs.some((j) => j.photos && j.photos.length > 0)) return; // fast path / idempotent

    const existing = await loadJobPhotos();
    const newRecords: JobPhoto[] = [];
    let jobsChanged = false;

    const nextJobs = await Promise.all(
      jobs.map(async (j) => {
        if (!j.photos || j.photos.length === 0) return j;
        const kept: string[] = [];
        for (const uri of j.photos) {
          if (!(await photoExists(uri))) continue; // drop a dangling reference
          const id = newPhotoId();
          const dims = await saveCompressedJobPhoto(uri, id);
          if (!dims) {
            kept.push(uri); // transient failure — retry on a later run
            continue;
          }
          newRecords.push({
            id,
            jobId: j.id,
            createdAt: new Date().toISOString(),
            width: dims.width,
            height: dims.height,
          });
          await deletePhoto(uri); // reclaim the old randomly-named file
        }
        if (kept.length === j.photos.length) return j; // nothing drained
        jobsChanged = true;
        const next: typeof j = { ...j };
        if (kept.length) next.photos = kept;
        else delete next.photos;
        return next;
      }),
    );

    if (newRecords.length) await saveJobPhotos([...existing, ...newRecords]);
    if (jobsChanged) await saveJobs(nextJobs);
    if (newRecords.length) void uploadPendingPhotos();
  } catch (err) {
    reportError(err, { context: "migrateLegacyJobPhotos" });
  }
}
