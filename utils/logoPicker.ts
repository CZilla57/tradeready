import { Alert } from "react-native";
import * as ImagePicker from "expo-image-picker";
import * as ImageManipulator from "expo-image-manipulator";
import { persistPhotoSafe, logoResizeActions, LOGO_COMPRESS } from "./photoStorage";
import { reportError } from "./analytics";

// Only the fields the resize needs. ImagePicker always supplies width/height,
// but documents both as "can be 0" when the platform did not report them.
type PickedAsset = { uri: string; width?: number; height?: number };

// The picker's own dimensions when it gave usable ones, otherwise ask the
// manipulator. Never guess: resizing against a 0 would upscale a small logo.
async function dimensionsOf(asset: PickedAsset): Promise<{ width: number; height: number }> {
  const width = asset.width ?? 0;
  const height = asset.height ?? 0;
  if (width > 0 && height > 0) return { width, height };
  const probe = await ImageManipulator.manipulateAsync(asset.uri);
  return { width: probe.width, height: probe.height };
}

/**
 * The picked image capped at 512px on its longest side and re-encoded as PNG,
 * plus the extension its bytes now have.
 *
 * `quality: 0.8` on the picker tunes JPEG compression only and caps no
 * dimension, so a modern phone photo arrived at full 12-48MP and was stored
 * byte-for-byte — which is what produced ~40MB invoice PDF attachments.
 *
 * PNG, not JPEG: logos are commonly transparent, and JPEG would flatten that
 * onto a solid box that shows against the PDF letterhead and in dark mode.
 *
 * A manipulator failure must not cost the user their pick, so the original is
 * returned instead. The pick still succeeds (just large) and `readLogoForPdf`
 * still bounds every PDF built from it.
 */
async function shrinkForLogo(asset: PickedAsset): Promise<{ uri: string; ext: string }> {
  try {
    const { width, height } = await dimensionsOf(asset);
    const result = await ImageManipulator.manipulateAsync(
      asset.uri,
      logoResizeActions(width, height),
      { compress: LOGO_COMPRESS, format: ImageManipulator.SaveFormat.PNG },
    );
    return { uri: result.uri, ext: "png" };
  } catch (err) {
    reportError(err, { context: "shrinkLogoOnPick" });
    return { uri: asset.uri, ext: "jpg" };
  }
}

// Shrink the chosen image, copy it into app storage and hand back the persisted
// path. Shared tail of both pick branches; a cancelled or empty result is a
// no-op. A failed copy tells the user their logo is unchanged rather than
// leaving the tap looking ignored, and never calls onPicked — so no caller
// records a path to a file that was not written.
async function persistPicked(
  result: { canceled: boolean; assets?: PickedAsset[] | null },
  onPicked: (uri: string) => void,
): Promise<void> {
  if (result.canceled || !result.assets?.[0]) return;
  const shrunk = await shrinkForLogo(result.assets[0]);
  const uri = await persistPhotoSafe(shrunk.uri, "logos", shrunk.ext);
  if (!uri) {
    Alert.alert("Couldn't save that image", "Your logo wasn't changed. Please try again.");
    return;
  }
  onPicked(uri);
}

/**
 * Prompts for a business logo (camera or photo library), copies the chosen image
 * into app storage, and hands the caller the persisted path.
 *
 * Shared by OnboardingScreen and SettingsScreen. The interaction, permission
 * handling and storage folder are identical in both; only what each screen does
 * with the resulting path differs, which is why that is the callback.
 *
 * `onPicked` fires only on a successful pick — cancels and denied permissions
 * are handled here and never invoke it. The caller decides whether the path is
 * saved immediately (onboarding) or held in a draft (Settings).
 */
export function promptForLogo(onPicked: (uri: string) => void): void {
  Alert.alert("Add your logo", "", [
    {
      text: "Take Photo",
      onPress: async () => {
        const { status } = await ImagePicker.requestCameraPermissionsAsync();
        if (status !== "granted") {
          Alert.alert("Permission needed", "Camera access is required to take a photo.");
          return;
        }
        const result = await ImagePicker.launchCameraAsync({ mediaTypes: ["images"] as any, quality: 0.8 });
        await persistPicked(result, onPicked);
      },
    },
    {
      text: "Choose from Library",
      onPress: async () => {
        const { status } = await ImagePicker.requestMediaLibraryPermissionsAsync();
        if (status !== "granted") {
          Alert.alert("Permission needed", "Photo library access is required.");
          return;
        }
        const result = await ImagePicker.launchImageLibraryAsync({ mediaTypes: ["images"] as any, quality: 0.8 });
        await persistPicked(result, onPicked);
      },
    },
    { text: "Cancel", style: "cancel" },
  ]);
}
