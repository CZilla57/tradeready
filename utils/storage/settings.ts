// utils/storage/settings.ts
// Settings are split across two stores: the bulk lives in AsyncStorage, while
// the three sensitive credential fields go to the iOS Keychain / Android
// Keystore via SecureStore. load/saveSettings hide that split from callers —
// they always see one merged Settings object.

import AsyncStorage from "@react-native-async-storage/async-storage";
import * as SecureStore from "expo-secure-store";
import { enqueue, trySync } from "../sync";
import { syncNotifications } from "../notifications";
import { KEYS } from "./keys";
import { defaultSettings } from "./defaults";
import type { Settings } from "../../types/models";

// Fields that must live in SecureStore rather than plain AsyncStorage. Both
// load/saveSettings strip these out before hitting AsyncStorage and delegate to
// SecureStore. Exported so clearAllUserData (lifecycle) can purge them too.
export const SECURE_FIELDS = ["providerKey", "anthropicKey", "groqKey"] as const;

type SecureField = (typeof SECURE_FIELDS)[number];
type SecureFields = Record<SecureField, string>;

async function loadSecureFields(): Promise<SecureFields> {
  const result = {} as SecureFields;
  for (const field of SECURE_FIELDS) {
    try {
      result[field] = (await SecureStore.getItemAsync(field)) || "";
    } catch {
      result[field] = "";
    }
  }
  // Migrate legacy "geminiKey" to "groqKey" if needed
  if (!result.groqKey) {
    try {
      const legacy = await SecureStore.getItemAsync("geminiKey");
      if (legacy) {
        await SecureStore.setItemAsync("groqKey", legacy);
        await SecureStore.deleteItemAsync("geminiKey");
        result.groqKey = legacy;
      }
    } catch {}
  }
  return result;
}

async function saveSecureFields(settings: Settings): Promise<void> {
  for (const field of SECURE_FIELDS) {
    try {
      await SecureStore.setItemAsync(field, settings[field] || "");
    } catch {
      // SecureStore unavailable in some simulators — silently degrade
    }
  }
}

export async function loadSettings(): Promise<Settings> {
  try {
    const [raw, secureFields] = await Promise.all([
      AsyncStorage.getItem(KEYS.settings),
      loadSecureFields(),
    ]);
    const base: Settings = raw ? JSON.parse(raw) : defaultSettings();
    return { ...base, ...secureFields };
  } catch {
    return defaultSettings();
  }
}

export async function saveSettings(settings: Settings): Promise<void> {
  const publicSettings: Partial<Settings> = { ...settings };
  for (const field of SECURE_FIELDS) {
    delete publicSettings[field];
  }
  await Promise.all([
    AsyncStorage.setItem(KEYS.settings, JSON.stringify(publicSettings)),
    saveSecureFields(settings),
  ]);
  await enqueue("settings", "upsert", "settings", publicSettings);
  trySync();
  syncNotifications();
}
