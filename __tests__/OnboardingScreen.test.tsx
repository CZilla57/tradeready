// __tests__/OnboardingScreen.test.tsx
// The slimmed two-step wizard (2026-08-03 flow restructure):
//   - the welcome step discloses the subscription/trial up front,
//   - Continue is always tappable and an invalid tap REVEALS the required
//     -field errors instead of being silently disabled,
//   - finishing saves personalization only (with the session-email prefill)
//     and stamps stage "personalized" so the start choice is owed post-paywall.

import React from "react";
import { render, fireEvent, waitFor } from "@testing-library/react-native";
import OnboardingScreen from "../screens/OnboardingScreen";
import {
  saveSettings,
  markOnboardingComplete,
  markOnboardingPersonalized,
} from "../utils/storage";

jest.mock("react-native-safe-area-context", () => ({
  useSafeAreaInsets: () => ({ top: 0, bottom: 0, left: 0, right: 0 }),
  SafeAreaProvider: ({ children }: { children: React.ReactNode }) => children,
  SafeAreaView: ({ children }: { children: React.ReactNode }) => children,
}));

// Same workaround as AuthScreen.test.tsx / SyncBanner.test.tsx.
jest.mock("@expo/vector-icons", () => ({
  Ionicons: "Ionicons",
}));

jest.mock("../context/AuthContext", () => ({
  useAuth: () => ({ session: { user: { email: "jo@example.com" } } }),
}));

jest.mock("../utils/storage", () => ({
  saveSettings: jest.fn(() => Promise.resolve()),
  defaultSettings: jest.fn(() => ({
    businessName: "Your Business Name",
    contactName: "Your Name",
    email: "",
    trade: "plumbing",
    laborRate: 85,
  })),
  markOnboardingComplete: jest.fn(() => Promise.resolve()),
  markOnboardingPersonalized: jest.fn(() => Promise.resolve()),
}));

describe("OnboardingScreen", () => {
  beforeEach(() => jest.clearAllMocks());

  it("welcome step discloses the subscription and trial before any effort", async () => {
    const { getByText } = await render(<OnboardingScreen onComplete={jest.fn()} />);
    expect(getByText("Step 1 of 3 · Welcome")).toBeTruthy();
    expect(getByText(/subscription with a free trial/)).toBeTruthy();
  });

  it("an invalid Continue tap reveals required-field errors instead of being disabled", async () => {
    const onComplete = jest.fn();
    const { getByText, queryByText, getByLabelText } = await render(
      <OnboardingScreen onComplete={onComplete} />
    );

    await fireEvent.press(getByLabelText("Let's get started"));
    expect(getByText("Step 2 of 3 · Your business")).toBeTruthy();

    // Nothing typed yet; errors are hidden until the user actually tries.
    expect(queryByText("Business name is required.")).toBeNull();

    await fireEvent.press(getByLabelText("Continue"));
    expect(getByText("Business name is required.")).toBeTruthy();
    expect(getByText("Your name is required.")).toBeTruthy();
    expect(saveSettings).not.toHaveBeenCalled();
    expect(onComplete).not.toHaveBeenCalled();
  });

  it("finishing saves personalization with the email prefill and stamps the stage", async () => {
    const onComplete = jest.fn();
    const { getByLabelText } = await render(<OnboardingScreen onComplete={onComplete} />);

    await fireEvent.press(getByLabelText("Let's get started"));
    await fireEvent.changeText(getByLabelText("Business name *"), "ABC Plumbing LLC");
    await fireEvent.changeText(getByLabelText("Your name *"), "Jo Smith");
    await fireEvent.press(getByLabelText("Continue"));

    await waitFor(() => expect(onComplete).toHaveBeenCalledTimes(1));
    expect(saveSettings).toHaveBeenCalledWith(
      expect.objectContaining({
        businessName: "ABC Plumbing LLC",
        contactName: "Jo Smith",
        trade: "plumbing",
        email: "jo@example.com",
      })
    );
    expect(markOnboardingPersonalized).toHaveBeenCalledTimes(1);
    expect(markOnboardingComplete).toHaveBeenCalledTimes(1);
  });
});
