// Mock Expo modules that rely on native code unavailable in the Jest/Node environment.
// jest-expo already mocks many modules; these fill in remaining gaps.

jest.mock("expo-notifications", () => ({
  getPermissionsAsync: jest.fn(() => Promise.resolve({ status: "granted" })),
  requestPermissionsAsync: jest.fn(() => Promise.resolve({ status: "granted" })),
  getExpoPushTokenAsync: jest.fn(() => Promise.resolve({ data: "mock-token" })),
  setNotificationHandler: jest.fn(),
  setNotificationChannelAsync: jest.fn(() => Promise.resolve()),
  addNotificationReceivedListener: jest.fn(() => ({ remove: jest.fn() })),
  addNotificationResponseReceivedListener: jest.fn(() => ({ remove: jest.fn() })),
  scheduleNotificationAsync: jest.fn(() => Promise.resolve()),
  cancelAllScheduledNotificationsAsync: jest.fn(() => Promise.resolve()),
  AndroidImportance: { DEFAULT: 3, MAX: 5 },
  IosAuthorizationStatus: { AUTHORIZED: 2 },
}));

jest.mock("expo-secure-store", () => ({
  getItemAsync: jest.fn(() => Promise.resolve(null)),
  setItemAsync: jest.fn(() => Promise.resolve()),
  deleteItemAsync: jest.fn(() => Promise.resolve()),
}));

jest.mock("expo-file-system", () => ({
  documentDirectory: "file:///mock/",
  cacheDirectory: "file:///mock/cache/",
  readAsStringAsync: jest.fn(() => Promise.resolve("")),
  writeAsStringAsync: jest.fn(() => Promise.resolve()),
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

jest.mock("@supabase/supabase-js", () => ({
  createClient: jest.fn(() => ({
    auth: {
      getSession: jest.fn(() => Promise.resolve({ data: { session: null } })),
      onAuthStateChange: jest.fn(() => ({ data: { subscription: { unsubscribe: jest.fn() } } })),
      signInWithPassword: jest.fn(),
      signOut: jest.fn(),
    },
    from: jest.fn(() => ({
      select: jest.fn().mockReturnThis(),
      insert: jest.fn().mockReturnThis(),
      update: jest.fn().mockReturnThis(),
      delete: jest.fn().mockReturnThis(),
      eq: jest.fn().mockReturnThis(),
      order: jest.fn().mockReturnThis(),
      single: jest.fn(() => Promise.resolve({ data: null, error: null })),
    })),
  })),
}));
