import React from "react";
import { render, fireEvent, waitFor, render as rtlRender } from "@testing-library/react-native";
import SettingsPaymentsScreen from "../screens/SettingsPaymentsScreen";
import { loadSettings, saveSettings } from "../utils/storage";
import { defaultSettings } from "../utils/storage/defaults";
import { fetchStripeConnectStatus } from "../utils/stripeStatus";

jest.mock("../utils/storage", () => ({
  loadSettings: jest.fn(),
  saveSettings: jest.fn(() => Promise.resolve()),
}));
jest.mock("../utils/notifications", () => ({ syncNotifications: jest.fn() }));
jest.mock("../utils/stripeStatus", () => ({
  fetchStripeConnectStatus: jest.fn(() => Promise.resolve({ connected: false })),
}));

const navigation = {
  setOptions: jest.fn(),
  addListener: jest.fn(() => jest.fn()),
  getParent: jest.fn(() => undefined),
  popToTop: jest.fn(),
  dispatch: jest.fn(),
} as any;

async function pressHeaderSave(nav: any) {
  const calls = (nav.setOptions as jest.Mock).mock.calls;
  const headerRight = calls[calls.length - 1][0].headerRight;
  // RNTL v14 render() is async — the brief's synchronous rtlRender(...) call
  // returned before the header snippet mounted, so getByLabelText below saw
  // an empty tree. Awaiting is a test-mechanics fix only; it doesn't touch
  // what's asserted. (crib from __tests__/settingsPricingScreen.test.tsx)
  const { getByLabelText } = await rtlRender(<>{headerRight()}</>);
  await fireEvent.press(getByLabelText("Save settings"));
}

describe("SettingsPaymentsScreen", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    (loadSettings as jest.Mock).mockResolvedValue(defaultSettings());
  });

  it("fetches Stripe status on mount and shows the connect button when disconnected", async () => {
    const { findByLabelText } = await render(
      <SettingsPaymentsScreen navigation={navigation} route={{} as any} />
    );
    expect(await findByLabelText("Connect Stripe account")).toBeTruthy();
    expect(fetchStripeConnectStatus).toHaveBeenCalledTimes(1);
  });

  it("selecting a non-Stripe provider shows its key input; saving persists it under providerKeys", async () => {
    const { findByLabelText } = await render(
      <SettingsPaymentsScreen navigation={navigation} route={{} as any} />
    );
    await fireEvent.press(await findByLabelText("Venmo"));
    const keyInput = await findByLabelText("Venmo link or username");
    await fireEvent.changeText(keyInput, "my-venmo");
    await pressHeaderSave(navigation);
    await waitFor(() =>
      expect(saveSettings).toHaveBeenCalledWith(
        expect.objectContaining({
          provider: "venmo",
          providerKeys: expect.objectContaining({ venmo: "my-venmo" }),
        })
      )
    );
  });

  it("a legacy providerKey is backfilled into providerKeys on load", async () => {
    (loadSettings as jest.Mock).mockResolvedValue({
      ...defaultSettings(),
      provider: "venmo",
      providerKey: "legacy-handle",
      providerKeys: undefined,
    });
    const { findByLabelText } = await render(
      <SettingsPaymentsScreen navigation={navigation} route={{} as any} />
    );
    expect((await findByLabelText("Venmo link or username")).props.value).toBe("legacy-handle");
  });
});
