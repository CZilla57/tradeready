import * as FileSystem from "expo-file-system/legacy";

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
