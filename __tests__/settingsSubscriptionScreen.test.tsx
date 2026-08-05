import React from "react";
import { render, fireEvent } from "@testing-library/react-native";
import SettingsSubscriptionScreen from "../screens/SettingsSubscriptionScreen";

const mockSub = { isSubscribed: false, isTrialing: false };
jest.mock("../context/SubscriptionContext", () => ({
  useSubscription: () => mockSub,
}));
jest.mock("../utils/subscription", () => ({
  openManageSubscriptions: jest.fn(() => Promise.resolve(true)),
}));

const rootNavigate = jest.fn();
const navigation = {
  setOptions: jest.fn(),
  addListener: jest.fn(() => jest.fn()),
  getParent: jest.fn(() => ({ getParent: () => ({ navigate: rootNavigate }) })),
  popToTop: jest.fn(),
  dispatch: jest.fn(),
} as any;

describe("SettingsSubscriptionScreen", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockSub.isSubscribed = false;
    mockSub.isTrialing = false;
  });

  it("unsubscribed: Subscribe navigates to the root PaywallModal", async () => {
    const { findByLabelText } = await render(
      <SettingsSubscriptionScreen navigation={navigation} route={{} as any} />
    );
    fireEvent.press(await findByLabelText("Subscribe"));
    expect(rootNavigate).toHaveBeenCalledWith("PaywallModal", { canDismiss: true });
  });

  it("subscribed: shows the active status and Manage button", async () => {
    mockSub.isSubscribed = true;
    const { findByText, findByLabelText } = await render(
      <SettingsSubscriptionScreen navigation={navigation} route={{} as any} />
    );
    expect(await findByText("Subscription active")).toBeTruthy();
    expect(await findByLabelText("Manage subscription")).toBeTruthy();
  });
});
