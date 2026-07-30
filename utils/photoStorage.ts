import * as FileSystem from "expo-file-system/legacy";
import { reportError } from "./analytics";

export async function persistPhoto(tempUri: string, folder = "photos"): Promise<string> {
  const dir = `${FileSystem.documentDirectory}${folder}/`;
  const info = await FileSystem.getInfoAsync(dir);
  if (!info.exists) {
    await FileSystem.makeDirectoryAsync(dir, { intermediates: true });
  }
  const filename = `${Date.now()}_${Math.random().toString(36).slice(2)}.jpg`;
  const dest = `${dir}${filename}`;
  await FileSystem.copyAsync({ from: tempUri, to: dest });
  return dest;
}

/**
 * `persistPhoto` that reports failure instead of rejecting.
 *
 * Every caller runs inside an async Alert button handler, where a rejection
 * becomes an unhandled promise rejection: the user picks an image and simply
 * nothing happens, with no error and no telemetry. `copyAsync` can genuinely
 * fail — a corrupt asset, a full disk, an iCloud photo that never finishes
 * downloading — so this returns `null` and records the failure instead.
 *
 * The nullable return is deliberate: it makes the compiler force a guard at the
 * call sites that feed a `string` into persisted data. An unguarded `null`
 * reaching storage would be worse than the silent no-op this replaces.
 *
 * Callers own the user-facing message, because what was lost differs (a logo, a
 * job photo, a receipt).
 */
export async function persistPhotoSafe(tempUri: string, folder: string): Promise<string | null> {
  try {
    return await persistPhoto(tempUri, folder);
  } catch (err) {
    reportError(err, { context: "persistPhoto", folder });
    return null;
  }
}

/**
 * Absolute URIs of every file in a photo folder, or `[]` if the folder does not
 * exist yet. Paths are built exactly as `persistPhoto` builds them, so they
 * compare equal to a stored path for the same file.
 *
 * Reports an unreadable folder as empty rather than throwing: callers use this
 * to reclaim disk, and a failed listing should skip the reclaim, never break the
 * screen that triggered it.
 */
export async function listPhotos(folder: string): Promise<string[]> {
  const dir = `${FileSystem.documentDirectory}${folder}/`;
  try {
    const info = await FileSystem.getInfoAsync(dir);
    if (!info.exists) return [];
    const names = await FileSystem.readDirectoryAsync(dir);
    return names.map((name) => `${dir}${name}`);
  } catch {
    return [];
  }
}

export async function deletePhoto(uri: string): Promise<void> {
  try {
    await FileSystem.deleteAsync(uri, { idempotent: true });
  } catch {
    // File already gone — not an error
  }
}

// A logo/photo path is an absolute documentDirectory URI, which does not survive
// a reinstall or a move to a new device (iOS reassigns the app-container UUID) —
// and settings sync carries the path across devices. Callers use this to tell a
// genuinely-unset image apart from a dangling reference.
export async function photoExists(uri: string): Promise<boolean> {
  try {
    const info = await FileSystem.getInfoAsync(uri);
    return info.exists;
  } catch {
    return false;
  }
}

export async function readPhotoAsDataUri(uri: string): Promise<string | null> {
  try {
    const info = await FileSystem.getInfoAsync(uri);
    if (!info.exists) return null;
    const base64 = await FileSystem.readAsStringAsync(uri, {
      encoding: FileSystem.EncodingType.Base64,
    });
    const ext = uri.split('.').pop()?.toLowerCase() ?? 'jpeg';
    const mime = ext === 'png' ? 'image/png' : 'image/jpeg';
    return `data:${mime};base64,${base64}`;
  } catch {
    return null;
  }
}
