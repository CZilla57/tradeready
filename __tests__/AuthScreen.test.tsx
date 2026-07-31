import React from "react";
import { render, fireEvent, waitFor } from "@testing-library/react-native";
import AuthScreen from "../screens/AuthScreen";
import { signInWithGoogle } from "../utils/socialAuth";
import { supabase } from "../utils/supabase";
import * as analytics from "../utils/analytics";

jest.mock("react-native-safe-area-context", () => ({
  useSafeAreaInsets: () => ({ top: 0, bottom: 0, left: 0, right: 0 }),
  SafeAreaProvider: ({ children }) => children,
}));

// @expo/vector-icons@15.1.1 resolves to an expo-font version incompatible
// with this project's Expo SDK 54 install (missing expo-asset in the Jest
// module-resolution path). Mock it here rather than touch dependencies —
// same workaround as __tests__/SyncBanner.test.tsx.
jest.mock("@expo/vector-icons", () => ({
  Ionicons: "Ionicons",
}));

jest.mock("../utils/socialAuth", () => ({
  signInWithApple: jest.fn(() => Promise.resolve({ ok: true })),
  signInWithGoogle: jest.fn(() => Promise.resolve({ ok: true })),
  SOCIAL_GOOGLE_AVAILABLE: true,
}));

describe("AuthScreen social sign-in", () => {
  beforeEach(() => jest.clearAllMocks());

  it("renders the Google button and triggers Google sign-in on press", async () => {
    const { getByLabelText } = await render(<AuthScreen />);
    fireEvent.press(getByLabelText("Continue with Google"));
    await waitFor(() => expect(signInWithGoogle).toHaveBeenCalledTimes(1));
  });

  it("shows the Apple button on iOS once availability resolves", async () => {
    const { findByTestId } = await render(<AuthScreen />);
    expect(await findByTestId("apple-signin-button")).toBeTruthy();
  });

  it("tracks a password sign_in event on successful email login", async () => {
    const trackSpy = jest.spyOn(analytics, "track");
    (supabase.auth.signInWithPassword as jest.Mock).mockResolvedValueOnce({ data: {}, error: null });

    const { getByLabelText, getByRole } = await render(<AuthScreen />);
    await fireEvent.changeText(getByLabelText("Email address"), "a@b.com");
    await fireEvent.changeText(getByLabelText("Password"), "secret1");
    await fireEvent.press(getByRole("button", { name: "Sign In" }));

    await waitFor(() =>
      expect(trackSpy).toHaveBeenCalledWith("sign_in", { method: "password" })
    );
  });
});
