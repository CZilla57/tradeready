// __tests__/calendarScreen.test.tsx
// CalendarScreen (Phase 11 A4): day-view blocks, the untimed row, the
// unscheduled-approved queue, and the tap-to-reschedule sheet (smart
// defaults, conflict warning, approved→scheduled advance on save).
// Fixed far-future dates (2099-01-05) keep the sheet's smart defaults
// deterministic without faking timers: a non-today date always seeds
// start 08:00 (defaultStartTime), end = start + max(labor,1)h.

import React from "react";
import { render, fireEvent, waitFor } from "@testing-library/react-native";
import CalendarScreen from "../screens/CalendarScreen";
import { loadJobs, saveJobs, loadSettings } from "../utils/storage";
import { defaultSettings } from "../utils/storage/defaults";
import { getTodayDateString } from "../utils/dateHelpers";
import type { Job } from "../types/models";

jest.mock("../utils/storage", () => ({
  loadJobs: jest.fn(),
  saveJobs: jest.fn(() => Promise.resolve()),
  loadSettings: jest.fn(),
}));

const navigation = {
  setOptions: jest.fn(),
  addListener: jest.fn(() => jest.fn()),
  getParent: jest.fn(() => ({ navigate: jest.fn() })),
  navigate: jest.fn(),
  goBack: jest.fn(),
} as any;

function job(overrides: Partial<Job>): Job {
  return {
    id: "j1",
    customerId: "c1",
    customerName: "Dana",
    title: "Faucet repair",
    description: "",
    status: "scheduled",
    scheduledDate: getTodayDateString(),
    scheduledStartTime: "09:00",
    scheduledEndTime: "11:00",
    address: "",
    estimateTotal: 0,
    laborHours: 2,
    laborRate: 85,
    materials: [],
    materialMarkup: 20,
    overhead: 15,
    margin: 20,
    notes: "",
    invoiceId: null,
    createdAt: "2026-08-01",
    ...overrides,
  };
}

function mockData(jobs: Job[]) {
  (loadJobs as jest.Mock).mockResolvedValue(jobs);
  (loadSettings as jest.Mock).mockResolvedValue(defaultSettings());
}

async function renderScreen() {
  return render(<CalendarScreen navigation={navigation} route={{} as any} />);
}

beforeEach(() => {
  jest.clearAllMocks();
  (saveJobs as jest.Mock).mockResolvedValue(undefined);
});

describe("CalendarScreen day view", () => {
  it("renders the selected day's timed blocks", async () => {
    mockData([job({})]);
    const { findByText } = await renderScreen();
    expect(await findByText("Faucet repair")).toBeTruthy();
  });

  it("lists jobs with a date but no time under 'No time set'", async () => {
    mockData([job({ id: "u1", title: "Gutter quote", scheduledStartTime: null, scheduledEndTime: null })]);
    const { findByText } = await renderScreen();
    expect(await findByText("No time set")).toBeTruthy();
    expect(await findByText("Gutter quote")).toBeTruthy();
    expect(await findByText("Set time")).toBeTruthy();
  });

  it("shows approved undated jobs in the Needs scheduling queue — leads excluded", async () => {
    mockData([
      job({ id: "q1", title: "Panel upgrade", status: "approved", scheduledDate: null, scheduledStartTime: null, scheduledEndTime: null }),
      job({ id: "q2", title: "Maybe someday", status: "lead", scheduledDate: null, scheduledStartTime: null, scheduledEndTime: null }),
    ]);
    const { findByText, queryByText } = await renderScreen();
    expect(await findByText("Needs scheduling")).toBeTruthy();
    expect(await findByText("Panel upgrade")).toBeTruthy();
    expect(await findByText("Schedule")).toBeTruthy();
    expect(queryByText("Maybe someday")).toBeNull();
  });
});

describe("reschedule sheet", () => {
  // Sheet tests use today-dated untimed jobs (the day view only renders the
  // selected day, which opens on today). Assertions are clock-independent:
  // exact smart-default math is pinned in __tests__/scheduleSmarts.test.ts.
  it("opens from 'Set time' and warns about conflicts", async () => {
    mockData([
      job({
        id: "target",
        title: "Panel upgrade",
        status: "approved",
        scheduledStartTime: null,
        scheduledEndTime: null,
        laborHours: 2,
      }),
      // All-day blocker: any smart-default window overlaps it.
      job({
        id: "blocker",
        title: "Boiler service",
        scheduledStartTime: "00:05",
        scheduledEndTime: "23:55",
      }),
    ]);
    const { findByText } = await renderScreen();
    fireEvent.press(await findByText("Set time"));
    expect(await findByText("Reschedule")).toBeTruthy();
    expect(await findByText(/Overlaps: Boiler service/)).toBeTruthy();
  });

  it("save applies a valid window and advances approved → scheduled", async () => {
    mockData([
      job({
        id: "target",
        title: "Panel upgrade",
        status: "approved",
        scheduledStartTime: null,
        scheduledEndTime: null,
        laborHours: 2,
      }),
    ]);
    const { findByText } = await renderScreen();
    fireEvent.press(await findByText("Set time"));
    fireEvent.press(await findByText("Save"));

    await waitFor(() => expect(saveJobs).toHaveBeenCalled());
    const saved: Job[] = (saveJobs as jest.Mock).mock.calls[0][0];
    const target = saved.find((j) => j.id === "target")!;
    expect(target.scheduledDate).toBe(getTodayDateString());
    expect(target.scheduledStartTime).toMatch(/^\d{2}:\d{2}$/);
    expect(target.scheduledEndTime).toMatch(/^\d{2}:\d{2}$/);
    expect(target.status).toBe("scheduled");
  });
});

describe("week view", () => {
  it("toggling to Week renders 7 day columns", async () => {
    mockData([job({})]);
    const { findByText, findAllByTestId } = await renderScreen();
    fireEvent.press(await findByText("Week"));
    expect(await findAllByTestId("week-col")).toHaveLength(7);
  });
});
