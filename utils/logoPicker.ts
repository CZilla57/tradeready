import { Alert } from "react-native";
import * as ImagePicker from "expo-image-picker";
import { persistPhotoSafe } from "./photoStorage";

// Copy the chosen image into app storage and hand back the persisted path.
// Shared tail of both pick branches; a cancelled or empty result is a no-op.
// A failed copy tells the user their logo is unchanged rather than leaving the
// tap looking ignored, and never calls onPicked — so no caller records a path
// to a file that was not written.
async function persistPicked(
  result: { canceled: boolean; assets?: { uri: string }[] | null },
  onPicked: (uri: string) => void,
): Promise<void> {
  if (result.canceled || !result.assets?.[0]) return;
  const uri = await persistPhotoSafe(result.assets[0].uri, "logos");
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
