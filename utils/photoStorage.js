import * as FileSystem from "expo-file-system";

// Copies a photo from a (possibly temporary) URI into the app's permanent
// document directory so the OS never clears it under storage pressure.
// Returns the permanent URI to store in AsyncStorage.
export async function persistPhoto(tempUri, folder = "photos") {
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

// Deletes a photo file that was previously saved by persistPhoto.
// Safe to call even if the file no longer exists.
export async function deletePhoto(uri) {
  try {
    await FileSystem.deleteAsync(uri, { idempotent: true });
  } catch {
    // File already gone — not an error
  }
}
