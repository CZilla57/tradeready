// __tests__/bookingLinkSettings.test.tsx
// Settings → Booking link: mint saves {token, enabled:true} through
// saveSettings; the toggle flips enabled in place; "new link" replaces the
// token. The section follows the Stripe-Connect immediate-action precedent —
// loadSettings/saveSettings at action time, local section state — so none of
// this should ever touch the screen's draft/dirty save path.

import React from "react";
import { render, fireEvent, waitFor } from "@testing-library/react-native";
import { Alert } from "react-native";
import SettingsScreen from "../screens/SettingsScreen";
import { loadSettings, saveSettings } from "../utils/storage";
import { defaultSettings } from "../utils/storage/defaults";
import { mintBookingToken, buildBookingUrl } from "../utils/bookingLink";

jest.mock("../utils/storage", () => ({
  loadSettings: jest.fn(),
  saveSettings: jest.fn(() => Promise.resolve()),
  clearSampleData: jest.fn(() => Promise.resolve()),
  clearAllUserData: jest.fn(() => Promise.resolve()),
}));

// Only mintBookingToken is faked — buildBookingUrl stays real so the test
// asserts against the actual URL format instead of a duplicated literal.
jest.mock("../utils/bookingLink", () => ({
  ...jest.requireActual("../utils/bookingLink"),
  mintBookingToken: jest.fn(),
}));

jest.mock("../context/AuthContext", () => ({
  useAuth: () => ({ session: null, initializing: false, bootstrapping: false }),
}));

jest.mock("../context/SubscriptionContext", () => ({
  useSubscription: () => ({
    isSubscribed: false,
    isTrialing: false,
    isLoading: false,
    customerInfo: null,
    refresh: jest.fn(),
    updateFromPurchase: jest.fn(),
  }),
}));

const navigation = {
  setOptions: jest.fn(),
  addListener: jest.fn(() => jest.fn()),
  getParent: jest.fn(() => undefined),
  popToTop: jest.fn(),
  dispatch: jest.fn(),
} as any;

const TOKEN = "f".repeat(48);

function settingsWithBooking(enabled: boolean) {
  return { ...defaultSettings(), bookingLink: { token: TOKEN, enabled } };
}

describe("Settings booking link section", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    (loadSettings as jest.Mock).mockResolvedValue(defaultSettings());
    (saveSettings as jest.Mock).mockResolvedValue(undefined);
  });

  it("renders 'Create my booking link' when settings.bookingLink is absent", async () => {
    const { findByText } = await render(
      <SettingsScreen navigation={navigation} route={{} as any} />
    );
    expect(await findByText("Create my booking link")).toBeTruthy();
  });

  it("tapping create calls mintBookingToken and saves the new bookingLink", async () => {
    (mintBookingToken as jest.Mock).mockResolvedValue({ ok: true, token: TOKEN });

    const { findByText } = await render(
      <SettingsScreen navigation={navigation} route={{} as any} />
    );
    const createBtn = await findByText("Create my booking link");
    await fireEvent.press(createBtn);

    await waitFor(() => expect(saveSettings).toHaveBeenCalledTimes(1));
    expect(mintBookingToken).toHaveBeenCalledTimes(1);
    expect(saveSettings).toHaveBeenCalledWith(
      expect.objectContaining({ bookingLink: { token: TOKEN, enabled: true } })
    );
  });

  it("with a bookingLink present, renders the URL and an ON 'Accepting requests' toggle", async () => {
    (loadSettings as jest.Mock).mockResolvedValue(settingsWithBooking(true));

    const { findByText, getByLabelText } = await render(
      <SettingsScreen navigation={navigation} route={{} as any} />
    );

    expect(await findByText(buildBookingUrl(TOKEN))).toBeTruthy();
    expect(getByLabelText("Accepting requests").props.value).toBe(true);
  });

  it("flipping the toggle saves the same token with enabled: false", async () => {
    (loadSettings as jest.Mock).mockResolvedValue(settingsWithBooking(true));

    const { findByLabelText } = await render(
      <SettingsScreen navigation={navigation} route={{} as any} />
    );
    const toggle = await findByLabelText("Accepting requests");
    await fireEvent(toggle, "valueChange", false);

    await waitFor(() => expect(saveSettings).toHaveBeenCalledTimes(1));
    expect(saveSettings).toHaveBeenCalledWith(
      expect.objectContaining({ bookingLink: { token: TOKEN, enabled: false } })
    );
  });

  it("a mint failure shows an Alert and saves nothing", async () => {
    (mintBookingToken as jest.Mock).mockResolvedValue({
      ok: false,
      reason: "network",
      message: "Please check your connection and try again.",
    });
    const alertSpy = jest.spyOn(Alert, "alert").mockImplementation(() => {});

    const { findByText } = await render(
      <SettingsScreen navigation={navigation} route={{} as any} />
    );
    const createBtn = await findByText("Create my booking link");
    await fireEvent.press(createBtn);

    await waitFor(() => expect(alertSpy).toHaveBeenCalledTimes(1));
    expect(alertSpy).toHaveBeenCalledWith(
      "Couldn't create link",
      "Please check your connection and try again."
    );
    expect(saveSettings).not.toHaveBeenCalled();
  });

  // Regression (review finding): bookingLink lives in the Settings blob, but
  // the section keeps it in its own local state, outside the screen's `s`
  // draft. If a successful create/toggle only updated that local state and
  // never patched `s`/`savedSnapshot`, then an UNRELATED edit + the screen's
  // normal "Save settings" would write out `s` with its stale (pre-booking)
  // bookingLink — silently deleting the link (or reverting the toggle) the
  // user had just persisted. Pins that a later handleSave carries the new
  // bookingLink forward instead of clobbering it.
  it("a later 'Save settings' does not revert a just-created booking link", async () => {
    jest.spyOn(Alert, "alert").mockImplementation(() => {});
    (mintBookingToken as jest.Mock).mockResolvedValue({ ok: true, token: TOKEN });

    const { findByText, findByLabelText } = await render(
      <SettingsScreen navigation={navigation} route={{} as any} />
    );

    // Create the booking link.
    const createBtn = await findByText("Create my booking link");
    await fireEvent.press(createBtn);
    await waitFor(() => expect(saveSettings).toHaveBeenCalledTimes(1));

    // An unrelated edit elsewhere on the screen — this is what makes the
    // header/inline "Save settings" path live.
    const businessNameField = await findByLabelText("Business name");
    await fireEvent.changeText(businessNameField, "New Business Name");

    // The screen's normal save path (not the booking section).
    const saveBtn = await findByLabelText("Save settings");
    await fireEvent.press(saveBtn);

    await waitFor(() => expect(saveSettings).toHaveBeenCalledTimes(2));
    expect(saveSettings).toHaveBeenLastCalledWith(
      expect.objectContaining({
        businessName: "New Business Name",
        bookingLink: { token: TOKEN, enabled: true },
      })
    );
  });
});
