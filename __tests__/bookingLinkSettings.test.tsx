// __tests__/bookingLinkSettings.test.tsx
// Settings → Booking link: mint saves {token, enabled:true} through
// saveSettings; the toggle flips enabled in place; "new link" replaces the
// token. This page is IMMEDIATE-action, following the Stripe-Connect
// precedent — loadSettings/saveSettings at action time, local page state —
// so none of this should ever touch a draft/dirty save path (this page has
// no draft at all).

import React from "react";
import { render, fireEvent, waitFor } from "@testing-library/react-native";
import { Alert } from "react-native";
import SettingsBookingScreen from "../screens/SettingsBookingScreen";
import { loadSettings, saveSettings } from "../utils/storage";
import { defaultSettings } from "../utils/storage/defaults";
import { mintBookingToken, buildBookingUrl } from "../utils/bookingLink";

jest.mock("../utils/storage", () => ({
  loadSettings: jest.fn(),
  saveSettings: jest.fn(() => Promise.resolve()),
}));

// Only mintBookingToken is faked — buildBookingUrl stays real so the test
// asserts against the actual URL format instead of a duplicated literal.
jest.mock("../utils/bookingLink", () => ({
  ...jest.requireActual("../utils/bookingLink"),
  mintBookingToken: jest.fn(),
}));

const navigation = {
  setOptions: jest.fn(),
  addListener: jest.fn(() => jest.fn()),
  getParent: jest.fn(() => undefined),
  popToTop: jest.fn(),
  dispatch: jest.fn(),
} as any;

const TOKEN = "f".repeat(48);

describe("Bookable time slots toggle (Phase 11 C3)", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    (saveSettings as jest.Mock).mockResolvedValue(undefined);
  });

  it("enabling stamps the device timezone and the flag in one save", async () => {
    (loadSettings as jest.Mock).mockResolvedValue({
      ...defaultSettings(),
      bookingLink: { token: TOKEN, enabled: true },
    });
    const { findByLabelText } = await render(
      <SettingsBookingScreen navigation={navigation} route={{} as any} />
    );
    await fireEvent(await findByLabelText("Bookable time slots"), "valueChange", true);
    await waitFor(() => expect(saveSettings).toHaveBeenCalled());
    const saved = (saveSettings as jest.Mock).mock.calls[0][0];
    expect(saved.schedule?.bookableSlotsEnabled).toBe(true);
    expect(typeof saved.schedule?.timeZone).toBe("string");
    expect(saved.schedule?.timeZone?.length).toBeGreaterThan(0);
  });

  it("disabling flips the flag but keeps the stored timezone", async () => {
    (loadSettings as jest.Mock).mockResolvedValue({
      ...defaultSettings(),
      bookingLink: { token: TOKEN, enabled: true },
      schedule: { bookableSlotsEnabled: true, timeZone: "America/Chicago" },
    });
    const { findByLabelText } = await render(
      <SettingsBookingScreen navigation={navigation} route={{} as any} />
    );
    await fireEvent(await findByLabelText("Bookable time slots"), "valueChange", false);
    await waitFor(() => expect(saveSettings).toHaveBeenCalled());
    const saved = (saveSettings as jest.Mock).mock.calls[0][0];
    expect(saved.schedule?.bookableSlotsEnabled).toBe(false);
    expect(saved.schedule?.timeZone).toBe("America/Chicago");
  });
});

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
      <SettingsBookingScreen navigation={navigation} route={{} as any} />
    );
    expect(await findByText("Create my booking link")).toBeTruthy();
  });

  it("tapping create calls mintBookingToken and saves the new bookingLink", async () => {
    (mintBookingToken as jest.Mock).mockResolvedValue({ ok: true, token: TOKEN });

    const { findByText } = await render(
      <SettingsBookingScreen navigation={navigation} route={{} as any} />
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
      <SettingsBookingScreen navigation={navigation} route={{} as any} />
    );

    expect(await findByText(buildBookingUrl(TOKEN))).toBeTruthy();
    expect(getByLabelText("Accepting requests").props.value).toBe(true);
  });

  it("flipping the toggle saves the same token with enabled: false", async () => {
    (loadSettings as jest.Mock).mockResolvedValue(settingsWithBooking(true));

    const { findByLabelText } = await render(
      <SettingsBookingScreen navigation={navigation} route={{} as any} />
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
      <SettingsBookingScreen navigation={navigation} route={{} as any} />
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

  // The old monolith had to patch a fresh booking link into its draft so a
  // later "Save settings" wouldn't clobber it. This page's guarantee is
  // simpler: it has NO draft — it never registers a header Save at all.
  it("the booking page registers no header Save (no draft to clobber)", async () => {
    (mintBookingToken as jest.Mock).mockResolvedValue({ ok: true, token: TOKEN });
    const { findByText } = await render(
      <SettingsBookingScreen navigation={navigation} route={{} as any} />
    );
    await fireEvent.press(await findByText("Create my booking link"));
    await waitFor(() => expect(saveSettings).toHaveBeenCalledTimes(1));
    expect(navigation.setOptions).not.toHaveBeenCalled();
  });
});
