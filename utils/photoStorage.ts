import * as FileSystem from "expo-file-system/legacy";
import * as ImageManipulator from "expo-image-manipulator";
import { reportError } from "./analytics";

// `ext` is the stored file's extension, not a conversion request — the caller
// passes what the bytes actually are. readPhotoAsDataUri derives the data-URI
// mime type from it, so a resized (PNG) logo saved under `.jpg` would be
// handed to the PDF renderer mislabelled.
export async function persistPhoto(
  tempUri: string,
  folder = "photos",
  ext = "jpg",
): Promise<string> {
  const dir = `${FileSystem.documentDirectory}${folder}/`;
  const info = await FileSystem.getInfoAsync(dir);
  if (!info.exists) {
    await FileSystem.makeDirectoryAsync(dir, { intermediates: true });
  }
  const filename = `${Date.now()}_${Math.random().toString(36).slice(2)}.${ext}`;
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
export async function persistPhotoSafe(
  tempUri: string,
  folder: string,
  ext = "jpg",
): Promise<string | null> {
  try {
    return await persistPhoto(tempUri, folder, ext);
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

/** Longest side, in pixels, that a logo is allowed to keep. */
export const LOGO_MAX_DIMENSION = 512;

/**
 * Save compression for logo re-encodes. PNG is lossless, so this only tunes the
 * encoder's effort — it is kept at the picker's own 0.8 for parity.
 */
export const LOGO_COMPRESS = 0.8;

/**
 * The manipulator actions that cap a `width`x`height` image at
 * LOGO_MAX_DIMENSION on its longest side, preserving aspect ratio.
 *
 * expo-image-manipulator derives the missing dimension when only one is given,
 * so the action names whichever side is longer and lets the other follow.
 *
 * Returns no actions for an image that already fits, and for dimensions the
 * platform did not report (ImagePicker documents width/height as "can be 0"):
 * resizing on a 0 would upscale a small logo instead of shrinking a big one.
 */
export function logoResizeActions(
  width: number,
  height: number,
): ImageManipulator.Action[] {
  if (!Number.isFinite(width) || !Number.isFinite(height)) return [];
  if (width <= 0 || height <= 0) return [];
  if (Math.max(width, height) <= LOGO_MAX_DIMENSION) return [];
  return [
    width >= height
      ? { resize: { width: LOGO_MAX_DIMENSION } }
      : { resize: { height: LOGO_MAX_DIMENSION } },
  ];
}

/**
 * A logo read as a PDF-ready data URI, downscaled to at most
 * LOGO_MAX_DIMENSION on its longest side.
 *
 * Why this exists: `Print.printToFileAsync` embeds every byte of the image it is
 * handed, and the `.logo { max-height: 56px; max-width: 140px }` CSS scales the
 * *rendering* only. A phone photo used as a logo produced ~40MB invoice PDF
 * attachments (owner report, 2026-07-31). Logo files stored before the
 * pick-time cap existed are still full resolution, so the cap has to be applied
 * here too.
 *
 * PNG, not JPEG: a transparent logo re-encoded as JPEG gains a solid box, which
 * shows on the PDF's white letterhead.
 *
 * The stored file is never rewritten — the downscaled copy exists only in the
 * manipulator's cache and in the returned string. That keeps the Settings
 * draft-vs-filesystem `deletePhoto` invariant and the logo orphan sweep out of
 * play entirely.
 *
 * Two manipulator calls, not one: the resize action has to name the longer
 * side, which means the dimensions must be known first. The probe call performs
 * no transformation and its output file is discarded.
 *
 * Any manipulator failure falls back to `readPhotoAsDataUri` — exactly today's
 * behaviour. A large PDF beats a logo-less one.
 */
export async function readLogoForPdf(path: string): Promise<string | null> {
  // A logo path does not survive a reinstall; a missing file is ordinary, not a
  // failure, and must not reach reportError.
  if (!(await photoExists(path))) return null;
  try {
    const probe = await ImageManipulator.manipulateAsync(path);
    const result = await ImageManipulator.manipulateAsync(
      path,
      logoResizeActions(probe.width, probe.height),
      { compress: LOGO_COMPRESS, format: ImageManipulator.SaveFormat.PNG, base64: true },
    );
    if (!result.base64) throw new Error("manipulateAsync returned no base64 data");
    return `data:image/png;base64,${result.base64}`;
  } catch (err) {
    reportError(err, { context: "readLogoForPdf" });
    return readPhotoAsDataUri(path);
  }
}
