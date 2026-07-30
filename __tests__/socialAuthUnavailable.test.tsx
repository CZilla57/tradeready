// Regression guard for the final-review Critical finding on feat/social-signin:
// utils/socialAuth.ts used to statically import
// @react-native-google-signin/google-signin and expo-crypto. Both throw at
// MODULE-EVALUATION time (not call time) when their native module isn't
// linked — Expo Go, bare Jest, and every existing production install the
// instant an OTA ships from a build without these native modules. Metro
// doesn't tree-shake, so the throw happens before any React code runs,
// taking the whole app down via App.tsx -> AuthScreen -> socialAuth.
//
// This file does NOT mock ../utils/socialAuth (unlike __tests__/AuthScreen.test.tsx,
// which mocks it wholesale for its own unrelated assertions) — it exercises the
// real lazy-require guard end to end by making the google-signin require throw
// the same way TurboModuleRegistry.getEnforcing does when the native module is
// absent. If the guard regresses back to a static import, this test crashes on
// render instead of merely failing an assertion.
import React from "react";
import { render } from "@testing-library/react-native";
import AuthScreen from "../screens/AuthScreen";
import * as socialAuth from "../utils/socialAuth";

jest.mock("@react-native-google-signin/google-signin", () => {
  throw new Error("Cannot find native module 'RNGoogleSignin'");
});

jest.mock("react-native-safe-area-context", () => ({
  useSafeAreaInsets: () => ({ top: 0, bottom: 0, left: 0, right: 0 }),
  SafeAreaProvider: ({ children }: { children: React.ReactNode }) => children,
}));

// Same workaround as __tests__/AuthScreen.test.tsx / __tests__/SyncBanner.test.tsx.
jest.mock("@expo/vector-icons", () => ({
  Ionicons: "Ionicons",
}));

describe("socialAuth when the google-signin native module is unavailable", () => {
  it("does not throw on import and reports Google as unavailable", () => {
    expect(socialAuth.SOCIAL_GOOGLE_AVAILABLE).toBe(false);
  });

  it("signInWithGoogle fails cleanly instead of touching a null GoogleSignin", async () => {
    const res = await socialAuth.signInWithGoogle();
    expect(res).toEqual({ ok: false, error: expect.any(String) });
  });
});

describe("AuthScreen when the google-signin native module is unavailable", () => {
  it("still renders without crashing and hides the Google button", async () => {
    const { queryByLabelText, findByTestId } = await render(<AuthScreen />);
    // Apple's own availability is independent of google-signin, so it should
    // still be offered (expo-apple-authentication's global jest.setup.js mock
    // resolves isAvailableAsync() to true).
    expect(await findByTestId("apple-signin-button")).toBeTruthy();
    expect(queryByLabelText("Continue with Google")).toBeNull();
  });
});
