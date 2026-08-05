import React from "react";
import { Alert } from "react-native";
import { render, fireEvent, waitFor } from "@testing-library/react-native";
import SettingsAccountScreen from "../screens/SettingsAccountScreen";
import { clearAllUserData } from "../utils/storage";
import { supabase } from "../utils/supabase";

jest.mock("../utils/storage", () => ({
  clearSampleData: jest.fn(() => Promise.resolve()),
  clearAllUserData: jest.fn(() => Promise.resolve()),
}));
jest.mock("../utils/supabase", () => ({
  supabase: {
    auth: {
      getSession: jest.fn(() => Promise.resolve({ data: { session: null } })),
      signOut: jest.fn(() => Promise.resolve()),
    },
  },
}));
jest.mock("../utils/sync", () => ({ syncIfOnline: jest.fn(() => Promise.resolve()) }));
jest.mock("../context/SyncStatusContext", () => ({
  useSyncStatusContext: () => ({ pendingCount: 0 }),
}));

const navigation = {
  setOptions: jest.fn(),
  addListener: jest.fn(() => jest.fn()),
  getParent: jest.fn(() => undefined),
  popToTop: jest.fn(),
  dispatch: jest.fn(),
} as any;

describe("SettingsAccountScreen", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    jest.spyOn(Alert, "alert").mockImplementation(() => {});
  });

  it("renders the three account actions", async () => {
    const { findByLabelText } = await render(
      <SettingsAccountScreen navigation={navigation} route={{} as any} />
    );
    expect(await findByLabelText("Clear sample data")).toBeTruthy();
    expect(await findByLabelText("Sign out")).toBeTruthy();
    expect(await findByLabelText("Delete account")).toBeTruthy();
  });

  it("sign out with no pending changes confirms, then wipes and signs out", async () => {
    const { findByLabelText } = await render(
      <SettingsAccountScreen navigation={navigation} route={{} as any} />
    );
    fireEvent.press(await findByLabelText("Sign out"));
    const buttons = (Alert.alert as jest.Mock).mock.calls.at(-1)[2];
    await buttons.find((b: any) => b.text === "Sign out").onPress();
    await waitFor(() => expect(clearAllUserData).toHaveBeenCalledTimes(1));
    expect(supabase.auth.signOut).toHaveBeenCalledTimes(1);
  });

  it("delete is disabled until the confirm phrase matches", async () => {
    const { findByLabelText, getByLabelText } = await render(
      <SettingsAccountScreen navigation={navigation} route={{} as any} />
    );
    await fireEvent.press(await findByLabelText("Delete account"));
    const deleteBtn = getByLabelText("Delete my account");
    expect(deleteBtn.props.accessibilityState.disabled).toBe(true);
    await fireEvent.changeText(
      getByLabelText(/to confirm account deletion$/),
      "DELETE"
    );
    expect(getByLabelText("Delete my account").props.accessibilityState.disabled).toBe(false);
  });
});
