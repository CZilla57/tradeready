import React from "react";
import { Alert } from "react-native";
import { render, fireEvent, waitFor, render as rtlRender } from "@testing-library/react-native";
import SettingsPricingScreen from "../screens/SettingsPricingScreen";
import { loadSettings, saveSettings } from "../utils/storage";
import { defaultSettings } from "../utils/storage/defaults";
import { markSetupTaskDone } from "../utils/setupChecklist";

jest.mock("../utils/storage", () => ({
  loadSettings: jest.fn(),
  saveSettings: jest.fn(() => Promise.resolve()),
}));
jest.mock("../utils/notifications", () => ({ syncNotifications: jest.fn() }));
jest.mock("../utils/setupChecklist", () => ({ markSetupTaskDone: jest.fn() }));

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
  // what's asserted.
  const { getByLabelText } = await rtlRender(<>{headerRight()}</>);
  await fireEvent.press(getByLabelText("Save settings"));
}

describe("SettingsPricingScreen", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    (loadSettings as jest.Mock).mockResolvedValue({ ...defaultSettings(), laborRate: 85 });
    jest.spyOn(Alert, "alert").mockImplementation(() => {});
  });

  it("renders pricing fields from settings", async () => {
    const { findByLabelText } = await render(
      <SettingsPricingScreen navigation={navigation} route={{} as any} />
    );
    expect((await findByLabelText("Your hourly labor rate ($)")).props.value).toBe("85");
  });

  it("a $0 labor rate blocks the save", async () => {
    const { findByLabelText } = await render(
      <SettingsPricingScreen navigation={navigation} route={{} as any} />
    );
    await fireEvent.changeText(await findByLabelText("Your hourly labor rate ($)"), "0");
    await pressHeaderSave(navigation);
    await waitFor(() =>
      expect(Alert.alert).toHaveBeenCalledWith("Fix before saving", "Hourly labor rate must be greater than $0.")
    );
    expect(saveSettings).not.toHaveBeenCalled();
  });

  it("a valid save persists and marks the rate task done", async () => {
    const { findByLabelText } = await render(
      <SettingsPricingScreen navigation={navigation} route={{} as any} />
    );
    await fireEvent.changeText(await findByLabelText("Material markup (%)"), "35");
    await pressHeaderSave(navigation);
    await waitFor(() => expect(saveSettings).toHaveBeenCalledTimes(1));
    expect(saveSettings).toHaveBeenCalledWith(expect.objectContaining({ materialMarkup: 35 }));
    expect(markSetupTaskDone).toHaveBeenCalledWith("rate");
  });
});
