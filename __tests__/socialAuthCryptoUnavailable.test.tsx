// Regression guard for the final-review finding on feat/social-signin's Critical fix
// (see __tests__/socialAuthUnavailable.test.tsx for the google-signin half of this):
// utils/socialAuth.ts also lazy-requires expo-crypto — used ONLY by the Apple flow,
// to hash the nonce Apple's native sheet requires. expo-crypto's default export is
// requireNativeModule('ExpoCrypto') at module scope, which throws the same way
// TurboModuleRegistry.getEnforcing does when the native module is absent (Expo Go,
// bare Jest, or any existing production install the instant an OTA ships from a
// build without the module linked). Metro doesn't tree-shake, so a regression back
// to a static `import * as Crypto from "expo-crypto"` would crash the whole bundle
// on render — and critically, socialAuthUnavailable.test.tsx would NOT catch it,
// because that file only throws from the google-signin mock, never from expo-crypto.
//
// This file is deliberately a SIBLING of socialAuthUnavailable.test.tsx rather than
// a shared file: jest.mock calls are hoisted file-wide, so mocking expo-crypto to
// throw here — while leaving @react-native-google-signin/google-signin on its
// normal jest.setup.js mock — isolates the expo-crypto failure from the
// google-signin failure. Combining both throwing mocks in one file would still
// catch a static-import regression, but it would no longer prove which native
// module regressed, and it would silently stop covering "google-signin fine,
// crypto broken" as its own scenario.
//
// Per utils/socialAuth.ts: Apple's button visibility (`appleAvailable` in
// AuthScreen.tsx) comes solely from AppleAuthentication.isAvailableAsync() — it
// does not depend on CRYPTO_AVAILABLE at all. So the meaningful assertion here
// isn't "the Apple button disappears" (it doesn't, and shouldn't); it's that the
// screen still renders, the button is still offered, and the underlying
// signInWithApple() call degrades to a clean error result instead of throwing
// (which is what a regression back to a static expo-crypto import would do —
// it would crash on render, before signInWithApple() is ever reachable).
import React from "react";
import { render } from "@testing-library/react-native";
import AuthScreen from "../screens/AuthScreen";
import * as socialAuth from "../utils/socialAuth";

jest.mock("expo-crypto", () => {
  throw new Error("Cannot find native module 'ExpoCrypto'");
});

jest.mock("react-native-safe-area-context", () => ({
  useSafeAreaInsets: () => ({ top: 0, bottom: 0, left: 0, right: 0 }),
  SafeAreaProvider: ({ children }: { children: React.ReactNode }) => children,
}));

// Same workaround as __tests__/AuthScreen.test.tsx / __tests__/socialAuthUnavailable.test.tsx.
jest.mock("@expo/vector-icons", () => ({
  Ionicons: "Ionicons",
}));

describe("socialAuth when the expo-crypto native module is unavailable", () => {
  it("does not throw on import and signInWithApple fails cleanly instead of touching a null Crypto", async () => {
    const res = await socialAuth.signInWithApple();
    expect(res).toEqual({ ok: false, error: expect.any(String) });
  });
});

describe("AuthScreen when the expo-crypto native module is unavailable", () => {
  it("still renders without crashing and still offers the Apple button, since its visibility is independent of crypto", async () => {
    const { findByTestId } = await render(<AuthScreen />);
    expect(await findByTestId("apple-signin-button")).toBeTruthy();
  });
});
