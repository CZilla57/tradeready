// __tests__/jobsQuotesFilter.test.tsx
// Jobs tab "Quotes" chip (owner request, 2026-08-04, post-booking-smoke):
// a dedicated view of open quotes — lead + estimate_sent, the same pair the
// pending-estimates stat counts. Always visible (unlike Declined/Archived,
// which hide when empty) so there's a permanent, predictable place to look
// for incoming booking requests. Also pins the fact that prompted the
// request: a fresh lead DOES belong to the default Active filter — the
// booking smoke's "missing" lead was a scroll/timing artifact, not a filter
// exclusion, and this suite keeps it that way.

import React from "react";
import { render, fireEvent } from "@testing-library/react-native";
import JobsScreen from "../screens/JobsScreen";
import { loadJobs } from "../utils/storage";
import type { Job } from "../types/models";

jest.mock("../utils/storage", () => ({
  loadJobs: jest.fn(),
  loadInvoices: jest.fn(() => Promise.resolve([])),
  saveJobs: jest.fn(() => Promise.resolve()),
}));

// JobsScreen only uses useFocusEffect from this module; run it as a mount
// effect (pattern: TodayScreenSettingsGear.test.tsx).
jest.mock("@react-navigation/native", () => ({
  useFocusEffect: (cb: () => void | (() => void)) => {
    const { useEffect } = jest.requireActual("react");
    useEffect(() => cb(), [cb]);
  },
}));

const navigation = {
  navigate: jest.fn(),
  setOptions: jest.fn(),
  addListener: jest.fn(() => jest.fn()),
} as never;

function job(over: Partial<Job>): Job {
  return {
    id: "j1",
    customerId: "c1",
    customerName: "Someone",
    title: "Job",
    description: "",
    status: "lead",
    scheduledDate: null,
    scheduledStartTime: null,
    scheduledEndTime: null,
    address: "",
    estimateTotal: 0,
    laborHours: 0,
    laborRate: 85,
    materials: [],
    materialMarkup: 20,
    overhead: 15,
    margin: 20,
    notes: "",
    invoiceId: null,
    createdAt: "2026-08-04",
    ...over,
  };
}

const fixture: Job[] = [
  job({ id: "j_lead", title: "Quote request", customerName: "Dana Rivers", status: "lead" }),
  job({ id: "j_sent", title: "Fence repair", customerName: "Ben Ortiz", status: "estimate_sent" }),
  job({ id: "j_sched", title: "Deck build", customerName: "Ada Chu", status: "scheduled" }),
  job({ id: "j_paid", title: "Gutter clean", customerName: "Raj Patel", status: "paid" }),
];

describe("Jobs Quotes filter", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    (loadJobs as jest.Mock).mockResolvedValue(fixture);
  });

  it("shows the Quotes chip even when there are no open quotes", async () => {
    (loadJobs as jest.Mock).mockResolvedValue([job({ id: "j_paid", status: "paid" })]);
    const { findByText } = await render(<JobsScreen navigation={navigation} route={{} as never} />);
    expect(await findByText("Quotes")).toBeTruthy();
  });

  it("tapping Quotes shows only lead + estimate_sent jobs", async () => {
    const { findByText, queryByText } = await render(
      <JobsScreen navigation={navigation} route={{} as never} />
    );
    fireEvent.press(await findByText("Quotes (2)"));
    expect(await findByText("Quote request")).toBeTruthy();
    expect(await findByText("Fence repair")).toBeTruthy();
    expect(queryByText("Deck build")).toBeNull();
    expect(queryByText("Gutter clean")).toBeNull();
  });

  it("a fresh lead still appears under the default Active filter", async () => {
    const { findByText, queryByText } = await render(
      <JobsScreen navigation={navigation} route={{} as never} />
    );
    expect(await findByText("Quote request")).toBeTruthy(); // lead, in Active
    expect(queryByText("Gutter clean")).toBeNull(); // paid, not in Active
  });
});
