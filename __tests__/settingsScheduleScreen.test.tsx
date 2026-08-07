// __tests__/settingsScheduleScreen.test.tsx
// Settings → Schedule (Phase 11 A5): the 12th form subpage on the
// useSettingsDraft contract. Renders resolved defaults when
// Settings.schedule is absent, edits write an explicit schedule object,
// work-day chips toggle ISO days, and blackouts commit through the add
// form. Sanitizing garbage input stays resolveSchedule's job (tested in
// scheduleConfig.test.ts) — this page persists what the user chose.

import React from "react";
import { Alert } from "react-native";
import { render, fireEvent, waitFor, render as rtlRender } from "@testing-library/react-native";
import SettingsScheduleScreen from "../screens/SettingsScheduleScreen";
import { loadSettings, saveSettings } from "../utils/storage";
import { defaultSettings } from "../utils/storage/defaults";
import type { Settings } from "../types/models";

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
  // RNTL v14 render() is async — awaiting is test mechanics only
  // (cribbed from __tests__/settingsPricingScreen.test.tsx).
  const { getByLabelText } = await rtlRender(<>{headerRight()}</>);
  await fireEvent.press(getByLabelText("Save settings"));
}

function savedSettings(): Settings {
  const calls = (saveSettings as jest.Mock).mock.calls;
  return calls[calls.length - 1][0];
}

describe("SettingsScheduleScreen", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    (loadSettings as jest.Mock).mockResolvedValue(defaultSettings());
    jest.spyOn(Alert, "alert").mockImplementation(() => {});
  });

  it("renders resolved defaults when schedule is absent", async () => {
    const { findByText } = await render(
      <SettingsScheduleScreen navigation={navigation} route={{} as any} />
    );
    expect(await findByText("8:00 AM")).toBeTruthy();
    expect(await findByText("5:00 PM")).toBeTruthy();
    // Mon–Sat default: Sunday chip unselected
    expect(await findByText("Working hours")).toBeTruthy();
  });

  it("toggling the Sunday chip saves workDays including 7", async () => {
    const { findByLabelText } = await render(
      <SettingsScheduleScreen navigation={navigation} route={{} as any} />
    );
    await fireEvent.press(await findByLabelText("Sunday"));
    await pressHeaderSave(navigation);
    await waitFor(() => expect(saveSettings).toHaveBeenCalled());
    expect(savedSettings().schedule?.workDays).toEqual([1, 2, 3, 4, 5, 6, 7]);
  });

  it("editing buffer minutes saves an explicit number", async () => {
    const { findByLabelText } = await render(
      <SettingsScheduleScreen navigation={navigation} route={{} as any} />
    );
    await fireEvent.changeText(await findByLabelText("Buffer between jobs (minutes)"), "30");
    await pressHeaderSave(navigation);
    await waitFor(() => expect(saveSettings).toHaveBeenCalled());
    expect(savedSettings().schedule?.bufferMinutes).toBe(30);
  });

  it("adding a time-off period commits a blackout with an id", async () => {
    const { findByText, findByLabelText } = await render(
      <SettingsScheduleScreen navigation={navigation} route={{} as any} />
    );
    // Add form defaults both dates to today; commit as-is with a reason.
    await fireEvent.changeText(await findByLabelText("Reason (optional)"), "Vacation");
    await fireEvent.press(await findByText("Add time off"));
    await pressHeaderSave(navigation);
    await waitFor(() => expect(saveSettings).toHaveBeenCalled());
    const blackouts = savedSettings().schedule?.blackouts ?? [];
    expect(blackouts).toHaveLength(1);
    expect(blackouts[0].id).toBeTruthy();
    expect(blackouts[0].start).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    expect(blackouts[0].end).toBe(blackouts[0].start);
    expect(blackouts[0].reason).toBe("Vacation");
  });

  it("removing an existing blackout saves without it", async () => {
    (loadSettings as jest.Mock).mockResolvedValue({
      ...defaultSettings(),
      schedule: {
        blackouts: [{ id: "b1", start: "2026-08-10", end: "2026-08-12", reason: "Trip" }],
      },
    });
    const { findByLabelText } = await render(
      <SettingsScheduleScreen navigation={navigation} route={{} as any} />
    );
    await fireEvent.press(await findByLabelText("Remove time off Trip"));
    await pressHeaderSave(navigation);
    await waitFor(() => expect(saveSettings).toHaveBeenCalled());
    expect(savedSettings().schedule?.blackouts).toEqual([]);
  });
});
