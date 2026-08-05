import React from "react";
import { Linking } from "react-native";
import { render, fireEvent, waitFor } from "@testing-library/react-native";
import SettingsHubScreen from "../screens/SettingsHubScreen";
import { fetchStripeConnectStatus } from "../utils/stripeStatus";
import { composeEmail } from "../utils/messaging";

jest.mock("../utils/stripeStatus", () => ({
  fetchStripeConnectStatus: jest.fn(() => Promise.resolve({ connected: true, display_name: "Acme LLC" })),
}));
jest.mock("../utils/messaging", () => ({ composeEmail: jest.fn(() => Promise.resolve(true)) }));
jest.mock("../context/SubscriptionContext", () => ({
  useSubscription: () => ({ isSubscribed: false, isTrialing: true }),
}));

const navigation = {
  setOptions: jest.fn(),
  addListener: jest.fn(() => jest.fn()),
  getParent: jest.fn(() => undefined),
  popToTop: jest.fn(),
  dispatch: jest.fn(),
  navigate: jest.fn(),
} as any;

// Every navigating row and its target route — a missed App.tsx
// registration surfaces as a runtime crash, so this table is the map.
const NAV_ROWS: [string, string][] = [
  ["Business profile", "SettingsBusiness"],
  ["Pricing defaults", "SettingsPricing"],
  ["Invoice numbering", "SettingsInvoiceNumbering"],
  ["Payments", "SettingsPayments"],
  ["Booking link", "SettingsBooking"],
  ["Appearance", "SettingsAppearance"],
  ["AI Assistant", "SettingsAI"],
  ["Notifications", "SettingsNotifications"],
  ["Review requests", "SettingsReviews"],
  ["Subscription", "SettingsSubscription"],
  ["Account", "SettingsAccount"],
];

describe("SettingsHubScreen", () => {
  beforeEach(() => jest.clearAllMocks());

  it("every menu row navigates to its subpage route", async () => {
    const { findByLabelText } = await render(
      <SettingsHubScreen navigation={navigation} route={{} as any} />
    );
    for (const [label, route] of NAV_ROWS) {
      fireEvent.press(await findByLabelText(label));
      expect(navigation.navigate).toHaveBeenLastCalledWith(route);
    }
  });

  it("shows the Stripe and subscription status subtitles", async () => {
    const { findByText } = await render(
      <SettingsHubScreen navigation={navigation} route={{} as any} />
    );
    expect(await findByText("Connected — Acme LLC")).toBeTruthy();
    expect(await findByText("Free trial active")).toBeTruthy();
    await waitFor(() => expect(fetchStripeConnectStatus).toHaveBeenCalled());
  });

  it("Contact Support composes the support email; legal rows open their URLs", async () => {
    const openURL = jest.spyOn(Linking, "openURL").mockResolvedValue(true as any);
    const { findByLabelText } = await render(
      <SettingsHubScreen navigation={navigation} route={{} as any} />
    );
    fireEvent.press(await findByLabelText("Contact support by email"));
    expect(composeEmail).toHaveBeenCalledWith(
      expect.objectContaining({ recipients: ["support@gettradereadyapp.com"] })
    );
    fireEvent.press(await findByLabelText("Privacy Policy"));
    fireEvent.press(await findByLabelText("Terms of Service"));
    expect(openURL).toHaveBeenCalledTimes(2);
  });
});
