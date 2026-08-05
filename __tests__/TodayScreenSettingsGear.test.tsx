/**
 * The Settings gear in Today's header — the only tab-bar-visible entry point
 * to SettingsScreen after the 7→6 tab consolidation — must push the Settings
 * screen on the Today stack.
 */
import React from "react";
import { render, fireEvent } from "@testing-library/react-native";
import TodayScreen from "../screens/TodayScreen";

jest.mock("react-native-safe-area-context", () => ({
  useSafeAreaInsets: () => ({ top: 0, bottom: 0, left: 0, right: 0 }),
  SafeAreaProvider: ({ children }: { children: React.ReactNode }) => children,
}));

// TodayScreen only uses useFocusEffect from this module; run it as a mount effect.
// jest.requireActual (not a bare require) avoids the CommonJS-import lint rule; the
// inline wrapper with `[cb]` deps (instead of passing `cb` straight to useEffect)
// avoids the exhaustive-deps warning that fires when a hook receives a
// non-inline function reference.
jest.mock("@react-navigation/native", () => ({
  useFocusEffect: (cb: () => void | (() => void)) => {
    const { useEffect } = jest.requireActual("react");
    useEffect(() => cb(), [cb]);
  },
}));

jest.mock("../utils/storage", () => ({
  loadJobs: jest.fn(() => Promise.resolve([])),
  getExpectedEarningsForDate: jest.fn(() => Promise.resolve(0)),
  filterOverdueInvoices: jest.fn(() => []),
  loadLeadJobs: jest.fn(() => Promise.resolve([])),
  loadCustomers: jest.fn(() => Promise.resolve([])),
  loadSettings: jest.fn(() => Promise.resolve({})),
  resolveCustomer: jest.fn(() => null),
}));

jest.mock("../utils/appointmentSend", () => ({
  sendAppointmentMessage: jest.fn(() => Promise.resolve(false)),
}));

describe("TodayScreen settings gear", () => {
  it("navigates to Settings on the Today stack when pressed", async () => {
    const navigate = jest.fn();
    const navigation = { navigate, getParent: jest.fn() } as any;

    const { getByLabelText } = await render(
      <TodayScreen navigation={navigation} route={{} as any} />
    );

    fireEvent.press(getByLabelText("Open settings"));
    expect(navigate).toHaveBeenCalledWith("Settings");
  });
});
