// __tests__/TaxSetAsideCard.test.js
// The Money-tab tax card. Math is pinned by taxEstimate.test.js — these pin
// the presentation contract: which figures render, which prompts appear for
// unset settings, and that the disclaimer + local-mileage disclosure are
// always present.
//
// The card self-loads trips/settings via useFocusEffect (MileageCard
// pattern), so the navigation hook is mocked to a plain effect here.

import React from "react";
import { render } from "@testing-library/react-native";
import { TaxSetAsideCard } from "../components/money/TaxSetAsideCard";

// jest.mock calls are hoisted above the imports by babel-jest, and the
// factories below only DEREFERENCE the mock* fns when the component calls
// them at render time — after these consts have initialized — so importing
// the component above is safe.
jest.mock("@react-navigation/native", () => ({
  useFocusEffect: (cb) => {
    const { useEffect } = require("react");
    // eslint-disable-next-line react-hooks/exhaustive-deps
    useEffect(() => { cb(); }, []);
  },
}));

const mockLoadTrips = jest.fn();
const mockLoadSettings = jest.fn();
jest.mock("../utils/storage", () => ({
  loadTrips: (...a) => mockLoadTrips(...a),
  loadSettings: (...a) => mockLoadSettings(...a),
  saveSettings: jest.fn(),
}));

const invoice = (over) => ({
  id: "i1", customer: "Acme", number: "INV-1", desc: "", email: "", phone: "",
  amount: 5000, due: "2026-07-01", paid: false, ...over,
});

describe("TaxSetAsideCard", () => {
  beforeEach(() => {
    jest.useFakeTimers();
    // Mid-July → current period is Q3 (Jun 1 – Aug 31, due Sep 15).
    jest.setSystemTime(new Date(2026, 6, 18));
    mockLoadTrips.mockResolvedValue([]);
    mockLoadSettings.mockResolvedValue({ mileageRate: 0.7 });
  });

  afterEach(() => {
    jest.useRealTimers();
    jest.clearAllMocks();
  });

  test("shows the period reserve, window, deadline, and YTD line", async () => {
    const invoices = [invoice({
      payments: [{ id: "p1", amount: 10000, date: "2026-06-15", method: "cash" }],
      amount: 10000,
    })];
    const { findByText } = await render(
      <TaxSetAsideCard invoices={invoices} expenses={[]} />
    );
    // $10,000 net → SE tax only (no rate set): 10000 × .9235 × .153 = 1412.96.
    expect(await findByText("$1,412.96")).toBeTruthy();
    expect(await findByText(/Jun 1 – Aug 31 · set aside by Sep 15/)).toBeTruthy();
    expect(await findByText(/\$1,412\.96 for the year so far/)).toBeTruthy();
  });

  test("prompts to set the income-tax rate while unset", async () => {
    const { findByText } = await render(<TaxSetAsideCard invoices={[]} expenses={[]} />);
    expect(await findByText(/Set your income-tax rate/)).toBeTruthy();
  });

  test("prompts for the vehicle election when vehicle data exists without a method", async () => {
    mockLoadTrips.mockResolvedValue([{
      id: "t1", date: "2026-06-20", odometerStart: 0, odometerEnd: 100, miles: 100,
      fromJobId: null, fromLabel: "Home / Shop", toJobId: null, toLabel: "Home / Shop",
      purpose: "", createdAt: "2026-06-20",
    }]);
    const { findByText } = await render(<TaxSetAsideCard invoices={[]} expenses={[]} />);
    expect(await findByText(/Choose standard mileage or actual fuel costs/)).toBeTruthy();
    expect(await findByText(/1 trip this year/)).toBeTruthy();
  });

  test("no vehicle prompt once a method is chosen", async () => {
    mockLoadSettings.mockResolvedValue({ mileageRate: 0.7, vehicleDeductionMethod: "mileage", taxIncomeRate: 12 });
    const { queryByText, findByText } = await render(
      <TaxSetAsideCard invoices={[]} expenses={[]} />
    );
    // Wait for the async settings load to land before asserting the negatives.
    expect(await findByText(/Estimate only — not tax advice/)).toBeTruthy();
    expect(queryByText(/Choose standard mileage/)).toBeNull();
    expect(queryByText(/Set your income-tax rate/)).toBeNull();
  });

  test("the disclaimer and local-mileage disclosure are always present", async () => {
    const { findByText } = await render(<TaxSetAsideCard invoices={[]} expenses={[]} />);
    expect(await findByText(/Estimate only — not tax advice\. Assumes net profit under \$200k\./)).toBeTruthy();
    expect(await findByText(/trip log \(0 trips this year\) — not synced/)).toBeTruthy();
  });
});
