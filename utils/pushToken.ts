// utils/pushToken.ts
// Registers the device's Expo push token into the synced settings blob so
// the backend can send owner alerts (first use: booking requests, spec §7).
// Graceful-degradation contract: in Expo Go, without the iOS push
// entitlement, without permission, or offline, this is a SILENT no-op — the
// pipeline lights up at the next EAS build without any code change. Never
// prompts (the invoice-reminder flow owns the permission ask), and saves
// only on change (a settings save re-enqueues the whole blob).

import { Platform } from "react-native";
import * as Notifications from "expo-notifications";
import Constants from "expo-constants";
import { loadSettings, saveSettings } from "./storage";

export async function registerPushToken(): Promise<void> {
  try {
    const perms = await Notifications.getPermissionsAsync();
    if (!perms.granted) return;

    const projectId = (Constants.expoConfig?.extra as { eas?: { projectId?: string } } | undefined)?.eas?.projectId;
    const token = (await Notifications.getExpoPushTokenAsync(projectId ? { projectId } : undefined)).data;
    if (!token) return;

    const settings = await loadSettings();
    if (settings.pushToken?.token === token) return;
    await saveSettings({
      ...settings,
      pushToken: {
        token,
        platform: Platform.OS === "android" ? "android" : "ios",
        updatedAt: new Date().toISOString(),
      },
    });
  } catch {
    // Expected wherever push isn't available; alerts fall back to email.
  }
}
