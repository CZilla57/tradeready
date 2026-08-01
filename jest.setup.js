// Mock Expo modules that rely on native code unavailable in the Jest/Node environment.
// jest-expo already mocks many modules; these fill in remaining gaps.

import React from "react";

jest.mock("expo-constants", () => ({
  expoConfig: {
    extra: {
      backendUrl: "https://backend-tradeready1.vercel.app",
      backendUrlIsPlaceholder: false,
      googleWebClientId: "test-web.apps.googleusercontent.com",
      googleIosClientId: "test-ios.apps.googleusercontent.com",
      posthogApiKey: "PLACEHOLDER_POSTHOG_KEY",
      sentryDsn: "PLACEHOLDER_SENTRY_DSN",
    },
  },
}));

jest.mock("expo-notifications", () => ({
  getPermissionsAsync: jest.fn(() => Promise.resolve({ status: "granted" })),
  requestPermissionsAsync: jest.fn(() => Promise.resolve({ status: "granted" })),
  getExpoPushTokenAsync: jest.fn(() => Promise.resolve({ data: "mock-token" })),
  setNotificationHandler: jest.fn(),
  setNotificationChannelAsync: jest.fn(() => Promise.resolve()),
  addNotificationReceivedListener: jest.fn(() => ({ remove: jest.fn() })),
  addNotificationResponseReceivedListener: jest.fn(() => ({ remove: jest.fn() })),
  scheduleNotificationAsync: jest.fn(() => Promise.resolve()),
  cancelScheduledNotificationAsync: jest.fn(() => Promise.resolve()),
  cancelAllScheduledNotificationsAsync: jest.fn(() => Promise.resolve()),
  AndroidImportance: { DEFAULT: 3, MAX: 5 },
  IosAuthorizationStatus: { AUTHORIZED: 2 },
}));

jest.mock("expo-secure-store", () => ({
  getItemAsync: jest.fn(() => Promise.resolve(null)),
  setItemAsync: jest.fn(() => Promise.resolve()),
  deleteItemAsync: jest.fn(() => Promise.resolve()),
}));

jest.mock("expo-file-system/legacy", () => ({
  documentDirectory: "file:///mock/",
  cacheDirectory: "file:///mock/cache/",
  readAsStringAsync: jest.fn(() => Promise.resolve("")),
  writeAsStringAsync: jest.fn(() => Promise.resolve()),
  copyAsync: jest.fn(() => Promise.resolve()),
  deleteAsync: jest.fn(() => Promise.resolve()),
  getInfoAsync: jest.fn(() => Promise.resolve({ exists: false })),
}));

jest.mock("expo-mail-composer", () => ({
  isAvailableAsync: jest.fn(() => Promise.resolve(true)),
  composeAsync: jest.fn(() => Promise.resolve({ status: "sent" })),
}));

jest.mock("expo-clipboard", () => ({
  setStringAsync: jest.fn(() => Promise.resolve()),
  getStringAsync: jest.fn(() => Promise.resolve("")),
}));

jest.mock("expo-sharing", () => ({
  isAvailableAsync: jest.fn(() => Promise.resolve(true)),
  shareAsync: jest.fn(() => Promise.resolve()),
}));

jest.mock("expo-sms", () => ({
  isAvailableAsync: jest.fn(() => Promise.resolve(true)),
  sendSMSAsync: jest.fn(() => Promise.resolve({ result: "sent" })),
}));

jest.mock("expo-print", () => ({
  printToFileAsync: jest.fn(() => Promise.resolve({ uri: "file:///mock/print.pdf" })),
  printAsync: jest.fn(() => Promise.resolve()),
}));

jest.mock("expo-image-picker", () => ({
  requestMediaLibraryPermissionsAsync: jest.fn(() => Promise.resolve({ status: "granted" })),
  launchImageLibraryAsync: jest.fn(() => Promise.resolve({ canceled: true })),
  MediaTypeOptions: { Images: "Images" },
}));

// The manipulator is native. Resolve with a small, already-within-cap image by
// default so suites that merely touch the logo path need no per-test setup;
// tests that care about resizing override the dimensions with
// mockResolvedValueOnce. Enum values match the real SaveFormat/FlipType strings.
jest.mock("expo-image-manipulator", () => ({
  manipulateAsync: jest.fn(() =>
    Promise.resolve({
      uri: "file:///mock/manipulated.png",
      width: 512,
      height: 512,
      base64: "PNGDATA",
    })
  ),
  SaveFormat: { JPEG: "jpeg", PNG: "png", WEBP: "webp" },
  FlipType: { Vertical: "vertical", Horizontal: "horizontal" },
}));

jest.mock("expo-image", () => {
  const { View } = require("react-native");
  return { Image: View };
});

jest.mock("@react-native-async-storage/async-storage", () => ({
  getItem: jest.fn(() => Promise.resolve(null)),
  setItem: jest.fn(() => Promise.resolve()),
  removeItem: jest.fn(() => Promise.resolve()),
  clear: jest.fn(() => Promise.resolve()),
  getAllKeys: jest.fn(() => Promise.resolve([])),
  multiGet: jest.fn(() => Promise.resolve([])),
  multiSet: jest.fn(() => Promise.resolve()),
  multiRemove: jest.fn(() => Promise.resolve()),
}));

jest.mock("expo-network", () => ({
  getNetworkStateAsync: jest.fn(() =>
    Promise.resolve({ isConnected: true, isInternetReachable: true })
  ),
}));

jest.mock("expo-apple-authentication", () => {
  const { View } = require("react-native");
  return {
    isAvailableAsync: jest.fn(() => Promise.resolve(true)),
    signInAsync: jest.fn(() =>
      Promise.resolve({ identityToken: "apple-id-token", fullName: null, email: null })
    ),
    AppleAuthenticationScope: { FULL_NAME: 0, EMAIL: 1 },
    AppleAuthenticationButtonType: { SIGN_IN: 0, CONTINUE: 1, SIGN_UP: 2 },
    AppleAuthenticationButtonStyle: { WHITE: 0, WHITE_OUTLINE: 1, BLACK: 2 },
    AppleAuthenticationButton: (props) => <View {...props} />,
  };
});

jest.mock("@react-native-google-signin/google-signin", () => ({
  GoogleSignin: {
    configure: jest.fn(),
    hasPlayServices: jest.fn(() => Promise.resolve(true)),
    signIn: jest.fn(() =>
      Promise.resolve({ type: "success", data: { idToken: "google-id-token" } })
    ),
  },
  statusCodes: {
    SIGN_IN_CANCELLED: "SIGN_IN_CANCELLED",
    IN_PROGRESS: "IN_PROGRESS",
    PLAY_SERVICES_NOT_AVAILABLE: "PLAY_SERVICES_NOT_AVAILABLE",
  },
}));

jest.mock("expo-crypto", () => ({
  digestStringAsync: jest.fn(() => Promise.resolve("hashed-nonce")),
  randomUUID: jest.fn(() => "11111111-1111-1111-1111-111111111111"),
  CryptoDigestAlgorithm: { SHA256: "SHA-256" },
}));

jest.mock("@supabase/supabase-js", () => ({
  createClient: jest.fn(() => ({
    auth: {
      getSession: jest.fn(() => Promise.resolve({ data: { session: null } })),
      onAuthStateChange: jest.fn(() => ({ data: { subscription: { unsubscribe: jest.fn() } } })),
      signInWithPassword: jest.fn(),
      signInWithIdToken: jest.fn(() => Promise.resolve({ data: {}, error: null })),
      signOut: jest.fn(),
    },
    from: jest.fn(() => ({
      select: jest.fn().mockReturnThis(),
      insert: jest.fn().mockReturnThis(),
      update: jest.fn().mockReturnThis(),
      upsert: jest.fn().mockReturnThis(),
      delete: jest.fn().mockReturnThis(),
      eq: jest.fn().mockReturnThis(),
      gt: jest.fn().mockReturnThis(),
      order: jest.fn().mockReturnThis(),
      single: jest.fn(() => Promise.resolve({ data: null, error: null })),
      maybeSingle: jest.fn(() => Promise.resolve({ data: null, error: null })),
    })),
  })),
}));

jest.mock("@react-native-community/datetimepicker", () => {
  const { View } = require("react-native");
  return {
    __esModule: true,
    default: (props) => <View testID="mock-datetime-picker" {...props} />,
  };
});

jest.mock("@sentry/react-native", () => ({
  init: jest.fn(),
  wrap: jest.fn((component) => component),
  captureException: jest.fn(),
  setUser: jest.fn(),
  withScope: jest.fn((cb) => cb({ setExtra: jest.fn() })),
  Severity: { Error: "error", Warning: "warning" },
}));

// The Ionicons component is a thin wrapper over expo-font's custom font
// loading, which pulls in expo-asset — not installed, since nothing in the
// app actually needs it here (Ionicons ships pre-bundled). Render the glyph
// name as plain text instead of pulling in that chain.
jest.mock("@expo/vector-icons", () => {
  const { Text } = require("react-native");
  const Ionicons = (props) => <Text {...props}>{props.name}</Text>;
  Ionicons.glyphMap = {};
  return { Ionicons };
});

jest.mock("posthog-react-native", () => ({
  PostHogProvider: ({ children }) => children,
  usePostHog: jest.fn(() => ({
    capture: jest.fn(),
    identify: jest.fn(),
    reset: jest.fn(),
  })),
}));
