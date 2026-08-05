import React from "react";
import { Alert } from "react-native";
import { render, fireEvent, waitFor, render as rtlRender } from "@testing-library/react-native";
import SettingsNotificationsScreen from "../screens/SettingsNotificationsScreen";
import { loadSettings, saveSettings } from "../utils/storage";
import { defaultSettings } from "../utils/storage/defaults";

jest.mock("../utils/storage", () => ({
  loadSettings: jest.fn(),
  saveSettings: jest.fn(() => Promise.resolve()),
}));
jest.mock("../utils/notifications", () => ({ syncNotifications: jest.fn() }));

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
  // RNTL v14 render() is async — a synchronous rtlRender(...) call returns
  // before the header snippet mounts, so getByLabelText below would see an
  // empty tree. Awaiting is a test-mechanics fix only; it doesn't touch what's
  // asserted (crib from __tests__/settingsPricingScreen.test.tsx).
  const { getByLabelText } = await rtlRender(<>{headerRight()}</>);
  await fireEvent.press(getByLabelText("Save settings"));
}

describe("SettingsNotificationsScreen", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    (loadSettings as jest.Mock).mockResolvedValue({ ...defaultSettings(), rules: [{ days: 7 }] });
    jest.spyOn(Alert, "alert").mockImplementation(() => {});
  });

  it("renders the reminder rule and the automation toggles", async () => {
    const { findByLabelText } = await render(
      <SettingsNotificationsScreen navigation={navigation} route={{} as any} />
    );
    expect((await findByLabelText("Reminder rule 1: days past due")).props.value).toBe("7");
    expect(await findByLabelText("Appointment reminders")).toBeTruthy();
    expect(await findByLabelText("Estimate follow-up reminders")).toBeTruthy();
  });

  it("an IN-PROGRESS rule edit (no blur) is folded into the save", async () => {
    const { findByLabelText } = await render(
      <SettingsNotificationsScreen navigation={navigation} route={{} as any} />
    );
    // Type without blurring — the raw text lives only in ruleDrafts.
    await fireEvent.changeText(await findByLabelText("Reminder rule 1: days past due"), "14");
    await pressHeaderSave(navigation);
    await waitFor(() =>
      expect(saveSettings).toHaveBeenCalledWith(
        expect.objectContaining({ rules: [{ days: 14 }] })
      )
    );
  });

  it("a toggle flip rides the draft and saves", async () => {
    const { findByLabelText } = await render(
      <SettingsNotificationsScreen navigation={navigation} route={{} as any} />
    );
    const toggle = await findByLabelText("Appointment reminders");
    await fireEvent(toggle, "valueChange", true);
    await pressHeaderSave(navigation);
    await waitFor(() =>
      expect(saveSettings).toHaveBeenCalledWith(
        expect.objectContaining({ appointmentRemindersEnabled: true })
      )
    );
  });
});
