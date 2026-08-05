import React from "react";
import { Alert } from "react-native";
import { render, fireEvent, waitFor, render as rtlRender } from "@testing-library/react-native";
import SettingsBusinessScreen from "../screens/SettingsBusinessScreen";
import { loadSettings, saveSettings } from "../utils/storage";
import { defaultSettings } from "../utils/storage/defaults";
import { listPhotos, photoExists } from "../utils/photoStorage";

jest.mock("../utils/storage", () => ({
  loadSettings: jest.fn(),
  saveSettings: jest.fn(() => Promise.resolve()),
}));
jest.mock("../utils/notifications", () => ({ syncNotifications: jest.fn() }));
jest.mock("../utils/photoStorage", () => ({
  deletePhoto: jest.fn(() => Promise.resolve()),
  photoExists: jest.fn(() => Promise.resolve(true)),
  listPhotos: jest.fn(() => Promise.resolve([])),
}));
jest.mock("../utils/logoPicker", () => ({ promptForLogo: jest.fn() }));
jest.mock("../context/AuthContext", () => ({
  useAuth: () => ({ session: null, initializing: false, bootstrapping: false }),
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
  // RNTL v14 render() is async — a synchronous rtlRender(...) call returns
  // before the header snippet mounts, so getByLabelText below would see an
  // empty tree. Awaiting is a test-mechanics fix only; it doesn't touch what's
  // asserted. (Cribbed from __tests__/settingsPricingScreen.test.tsx.)
  const { getByLabelText } = await rtlRender(<>{headerRight()}</>);
  await fireEvent.press(getByLabelText("Save settings"));
}

describe("SettingsBusinessScreen", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    (loadSettings as jest.Mock).mockResolvedValue(defaultSettings());
    jest.spyOn(Alert, "alert").mockImplementation(() => {});
  });

  it("renders the business fields and sweeps the logo folder on open", async () => {
    const { findByLabelText } = await render(
      <SettingsBusinessScreen navigation={navigation} route={{} as any} />
    );
    expect(await findByLabelText("Business name")).toBeTruthy();
    await waitFor(() => expect(listPhotos).toHaveBeenCalledWith("logos"));
  });

  it("a dangling logo path is treated as unset", async () => {
    (loadSettings as jest.Mock).mockResolvedValue({ ...defaultSettings(), logoPhoto: "logos/gone.jpg" });
    (photoExists as jest.Mock).mockResolvedValue(false);
    const { findByLabelText } = await render(
      <SettingsBusinessScreen navigation={navigation} route={{} as any} />
    );
    expect(await findByLabelText("Add your business logo")).toBeTruthy();
  });

  it("a malformed email blocks the save", async () => {
    const { findByLabelText } = await render(
      <SettingsBusinessScreen navigation={navigation} route={{} as any} />
    );
    await fireEvent.changeText(await findByLabelText("Email"), "not-an-email");
    await pressHeaderSave(navigation);
    await waitFor(() =>
      expect(Alert.alert).toHaveBeenCalledWith("Fix before saving", "Email doesn't look like a valid address.")
    );
    expect(saveSettings).not.toHaveBeenCalled();
  });

  it("phone input formats as (xxx) xxx-xxxx and saves", async () => {
    const { findByLabelText } = await render(
      <SettingsBusinessScreen navigation={navigation} route={{} as any} />
    );
    const phone = await findByLabelText("Phone");
    await fireEvent.changeText(phone, "5551234567");
    await pressHeaderSave(navigation);
    await waitFor(() =>
      expect(saveSettings).toHaveBeenCalledWith(
        expect.objectContaining({ phone: "(555) 123-4567" })
      )
    );
  });
});
