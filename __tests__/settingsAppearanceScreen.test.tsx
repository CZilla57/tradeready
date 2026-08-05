import React from "react";
import { render, fireEvent } from "@testing-library/react-native";
import SettingsAppearanceScreen from "../screens/SettingsAppearanceScreen";

const mockSetTheme = jest.fn();

jest.mock("../hooks/useTheme", () => {
  const theme = jest.requireActual("../utils/theme");
  return {
    useTheme: () => ({
      colors: theme.colors,
      shadow: { card: {} } as any,
      preference: "system",
      setTheme: mockSetTheme,
    }),
  };
});

const navigation = {
  setOptions: jest.fn(),
  addListener: jest.fn(() => jest.fn()),
  getParent: jest.fn(() => undefined),
  popToTop: jest.fn(),
  dispatch: jest.fn(),
  navigate: jest.fn(),
} as any;

describe("SettingsAppearanceScreen", () => {
  it("renders the three options with the preference selected", async () => {
    const { getByLabelText } = await render(
      <SettingsAppearanceScreen navigation={navigation} route={{} as any} />
    );
    expect(getByLabelText("Light appearance")).toBeTruthy();
    expect(getByLabelText("System appearance").props.accessibilityState.selected).toBe(true);
    expect(getByLabelText("Dark appearance").props.accessibilityState.selected).toBe(false);
  });

  it("tapping an option calls setTheme immediately", async () => {
    const { getByLabelText } = await render(
      <SettingsAppearanceScreen navigation={navigation} route={{} as any} />
    );
    fireEvent.press(getByLabelText("Dark appearance"));
    expect(mockSetTheme).toHaveBeenCalledWith("dark");
  });
});
