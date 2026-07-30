import { Alert } from "react-native";
import * as ImagePicker from "expo-image-picker";
import { persistPhoto } from "./photoStorage";

// Copy the chosen image into app storage and hand back the persisted path.
// Shared tail of both pick branches; a cancelled or empty result is a no-op.
async function persistPicked(
  result: { canceled: boolean; assets?: { uri: string }[] | null },
  onPicked: (uri: string) => void,
): Promise<void> {
  if (result.canceled || !result.assets?.[0]) return;
  onPicked(await persistPhoto(result.assets[0].uri, "logos"));
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
