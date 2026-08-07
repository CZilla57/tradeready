/**
 * Cross-tab deep links must preserve the target stack's initial route.
 *
 * Tabs mount lazily, and React Navigation uses a nested `screen` param as the
 * target navigator's INITIAL route unless `initial: false` is passed
 * (@react-navigation/core useNavigationBuilder). Without it, jumping from
 * Today's schedule to Jobs > JobDetail before the Jobs tab has ever been
 * focused mounts the stack with JobDetail as its ONLY route — no JobList
 * beneath, no back button, and no way back until an app restart.
 */
import React from "react";
import { render, fireEvent } from "@testing-library/react-native";
import TodayScreen from "../screens/TodayScreen";
import { getTodayDateString } from "../utils/dateHelpers";
import type { Job } from "../types/models";

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

const mockScheduledJob: Job = {
  id: "j1",
  title: "Fix water heater",
  customerName: "Dana Smith",
  status: "scheduled",
  scheduledDate: getTodayDateString(),
} as Job;

jest.mock("../utils/storage", () => ({
  loadJobs: jest.fn(() => Promise.resolve([mockScheduledJob])),
  loadInvoices: jest.fn(() => Promise.resolve([])),
  getExpectedEarningsForDate: jest.fn(() => Promise.resolve(0)),
  filterOverdueInvoices: jest.fn(() => []),
  loadLeadJobs: jest.fn(() => Promise.resolve([])),
  loadCustomers: jest.fn(() => Promise.resolve([])),
  loadSettings: jest.fn(() => Promise.resolve({})),
  resolveCustomer: jest.fn(() => null),
  loadBookingRequests: jest.fn(() => Promise.resolve([])),
}));

jest.mock("../utils/setupChecklist", () => ({
  loadSetupChecklistState: jest.fn(() => Promise.resolve(null)),
  markSampleTourDone: jest.fn(),
}));

jest.mock("../utils/appointmentSend", () => ({
  sendAppointmentMessage: jest.fn(() => Promise.resolve(false)),
}));

jest.mock("../utils/analytics", () => ({
  track: jest.fn(),
  reportError: jest.fn(),
}));

describe("cross-tab navigation preserves the target stack's initial route", () => {
  it("tapping a job in Today's schedule targets Jobs > JobDetail with initial: false", async () => {
    const parentNavigate = jest.fn();
    const navigation = {
      navigate: jest.fn(),
      getParent: jest.fn(() => ({ navigate: parentNavigate })),
    } as any;

    const { findByText } = await render(
      <TodayScreen navigation={navigation} route={{} as any} />
    );

    const row = await findByText("Fix water heater");
    await fireEvent.press(row);

    expect(parentNavigate).toHaveBeenCalledWith("Jobs", {
      screen: "JobDetail",
      initial: false,
      params: { jobId: "j1" },
    });
  });
});
