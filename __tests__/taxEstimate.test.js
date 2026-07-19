// __tests__/taxEstimate.test.js
// The tax set-aside math. Two things are load-bearing here: the IRS payment
// periods are UNEVEN (3/2/3/4 months — encoding even quarters is a silent
// wrong answer), and the vehicle deduction is an either/or election (mileage
// OR actual fuel costs; unset deducts NEITHER — over-reserving on purpose).

import {
  SS_WAGE_BASE,
  SE_NET_EARNINGS_FACTOR,
  SOCIAL_SECURITY_RATE,
  MEDICARE_RATE,
  taxPeriodsForYear,
  currentTaxPeriod,
  formatPeriodRange,
  formatDeadline,
  splitDeductibleExpenses,
  resolveVehicleDeduction,
  estimateTaxReserve,
  summarizeTaxWindow,
} from "../utils/taxEstimate";

describe("constants", () => {
  test("2026 wage base and SE rates match the verified IRS values", () => {
    expect(SS_WAGE_BASE[2026]).toBe(184500);
    expect(SS_WAGE_BASE[2025]).toBe(176100);
    expect(SE_NET_EARNINGS_FACTOR).toBe(0.9235);
    expect(SOCIAL_SECURITY_RATE + MEDICARE_RATE).toBeCloseTo(0.153, 10);
  });
});

describe("taxPeriodsForYear — the uneven 3/2/3/4 periods", () => {
  const periods = taxPeriodsForYear(2026);

  test("period boundaries are Jan–Mar, Apr–May, Jun–Aug, Sep–Dec", () => {
    expect(periods.map((p) => [p.start.getMonth(), p.end.getMonth()])).toEqual([
      [0, 2],
      [3, 4],
      [5, 7],
      [8, 11],
    ]);
    expect(periods.map((p) => p.end.getDate())).toEqual([31, 31, 31, 31]);
  });

  test("2026 deadlines land on weekdays and do not shift", () => {
    // Apr 15 Wed, Jun 15 Mon, Sep 15 Tue, Jan 15 2027 Fri — verified weekdays.
    expect(periods.map((p) => [p.due.getMonth(), p.due.getDate(), p.due.getFullYear()])).toEqual([
      [3, 15, 2026],
      [5, 15, 2026],
      [8, 15, 2026],
      [0, 15, 2027],
    ]);
    for (const p of periods) {
      expect([0, 6]).not.toContain(p.due.getDay());
    }
  });

  test("a Saturday deadline shifts to Monday (Q4 2027 → Jan 17, 2028)", () => {
    const q4 = taxPeriodsForYear(2027)[3];
    // Jan 15, 2028 is a Saturday.
    expect(q4.due.getFullYear()).toBe(2028);
    expect(q4.due.getMonth()).toBe(0);
    expect(q4.due.getDate()).toBe(17);
    expect(q4.due.getDay()).toBe(1);
  });

  test("a Sunday deadline shifts to Monday (Q1 2029 → Apr 16, 2029)", () => {
    const q1 = taxPeriodsForYear(2029)[0];
    // Apr 15, 2029 is a Sunday.
    expect(q1.due.getDate()).toBe(16);
    expect(q1.due.getDay()).toBe(1);
  });

  test("June income belongs to Q3 (due September), not Q2", () => {
    expect(currentTaxPeriod(new Date(2026, 5, 1)).quarter).toBe(3);
  });

  test("currentTaxPeriod picks the containing period at each boundary", () => {
    expect(currentTaxPeriod(new Date(2026, 0, 10)).quarter).toBe(1);
    expect(currentTaxPeriod(new Date(2026, 2, 31)).quarter).toBe(1);
    expect(currentTaxPeriod(new Date(2026, 3, 1)).quarter).toBe(2);
    expect(currentTaxPeriod(new Date(2026, 4, 31)).quarter).toBe(2);
    expect(currentTaxPeriod(new Date(2026, 7, 31)).quarter).toBe(3);
    expect(currentTaxPeriod(new Date(2026, 8, 1)).quarter).toBe(4);
    expect(currentTaxPeriod(new Date(2026, 11, 31)).quarter).toBe(4);
  });

  test("labels: period range and deadline (Q4 names the next year)", () => {
    const q3 = taxPeriodsForYear(2026)[2];
    const q4 = taxPeriodsForYear(2026)[3];
    expect(formatPeriodRange(q3)).toBe("Jun 1 – Aug 31");
    expect(formatDeadline(q3)).toBe("Sep 15");
    expect(formatDeadline(q4)).toBe("Jan 15, 2027");
  });
});

describe("splitDeductibleExpenses", () => {
  const exp = (over) => ({
    id: "e1", createdAt: "2026-01-01", description: "", amount: 100,
    category: "materials", date: "2026-07-01", notes: "", receiptUri: null,
    ...over,
  });
  const START = new Date(2026, 5, 1);
  const END = new Date(2026, 7, 31);

  test("fuel is held apart from every other category", () => {
    const split = splitDeductibleExpenses(
      [
        exp({ id: "e1", category: "materials", amount: 300 }),
        exp({ id: "e2", category: "fuel", amount: 200 }),
        exp({ id: "e3", category: "tools", amount: 50 }),
      ],
      START, END,
    );
    expect(split.nonVehicle).toBe(350);
    expect(split.fuel).toBe(200);
  });

  test("expenses outside the window are excluded", () => {
    const split = splitDeductibleExpenses(
      [exp({ date: "2026-01-15", amount: 999 })],
      START, END,
    );
    expect(split.nonVehicle).toBe(0);
  });

  test("malformed amounts contribute zero, never NaN", () => {
    const split = splitDeductibleExpenses(
      [exp({ amount: undefined }), exp({ id: "e2", amount: "250" })],
      START, END,
    );
    expect(split.nonVehicle).toBe(250);
    expect(Number.isFinite(split.nonVehicle)).toBe(true);
  });
});

describe("resolveVehicleDeduction — the either/or election", () => {
  test("mileage method deducts miles × rate", () => {
    const r = resolveVehicleDeduction({ method: "mileage", miles: 100, mileageRate: 0.7, fuelExpenses: 500 });
    expect(r.deduction).toBe(70);
    expect(r.needsChoice).toBe(false);
  });

  test("actual method deducts fuel expenses", () => {
    const r = resolveVehicleDeduction({ method: "actual", miles: 100, mileageRate: 0.7, fuelExpenses: 500 });
    expect(r.deduction).toBe(500);
    expect(r.needsChoice).toBe(false);
  });

  test("unset with vehicle data deducts NEITHER and flags the choice", () => {
    const r = resolveVehicleDeduction({ method: undefined, miles: 100, mileageRate: 0.7, fuelExpenses: 500 });
    expect(r.deduction).toBe(0);
    expect(r.needsChoice).toBe(true);
  });

  test("unset with no vehicle data needs no choice", () => {
    const r = resolveVehicleDeduction({ method: undefined, miles: 0, mileageRate: 0.7, fuelExpenses: 0 });
    expect(r.deduction).toBe(0);
    expect(r.needsChoice).toBe(false);
  });
});

describe("estimateTaxReserve", () => {
  test("worked example: $10k income, $2k expenses, $500 vehicle, 12% rate", () => {
    const e = estimateTaxReserve({
      collectedIncome: 10000,
      deductibleExpenses: 2000,
      vehicleDeduction: 500,
      incomeRatePercent: 12,
      year: 2026,
    });
    // net 7500; seBase 6926.25; seTax 6926.25 × 15.3% = 1059.72 (below cap);
    // incomeTax (7500 − 529.86) × 12% = 836.42; reserve 1896.13.
    expect(e.netProfit).toBe(7500);
    expect(e.seTax).toBeCloseTo(1059.72, 2);
    expect(e.incomeTax).toBeCloseTo(836.42, 2);
    expect(e.reserve).toBeCloseTo(1896.13, 2);
    expect(e.ratesKnown).toBe(true);
  });

  test("rate unset (0%) reserves the SE component only", () => {
    const e = estimateTaxReserve({
      collectedIncome: 10000, deductibleExpenses: 0, vehicleDeduction: 0,
      incomeRatePercent: 0, year: 2026,
    });
    expect(e.incomeTax).toBe(0);
    expect(e.reserve).toBe(e.seTax);
  });

  test("Social Security caps at the wage base; Medicare does not", () => {
    const e = estimateTaxReserve({
      collectedIncome: 250000, deductibleExpenses: 0, vehicleDeduction: 0,
      incomeRatePercent: 0, year: 2026,
    });
    // seBase 230,875 → SS on min(230875, 184500) = 22,878; Medicare 6,695.375;
    // sum 29,573.375 → cent-rounded 29,573.38 (the raw sum sits exactly half a
    // cent off, which toBeCloseTo(…, 2) rejects on its boundary — pin the
    // rounded value the function actually returns).
    expect(e.seTax).toBe(29573.38);
  });

  test("a loss produces a zero reserve, not a negative one", () => {
    const e = estimateTaxReserve({
      collectedIncome: 1000, deductibleExpenses: 5000, vehicleDeduction: 0,
      incomeRatePercent: 20, year: 2026,
    });
    expect(e.netProfit).toBe(-4000);
    expect(e.seTax).toBe(0);
    expect(e.incomeTax).toBe(0);
    expect(e.reserve).toBe(0);
  });

  test("an unknown year computes with the latest known base and flags it", () => {
    const known = estimateTaxReserve({
      collectedIncome: 10000, deductibleExpenses: 0, vehicleDeduction: 0,
      incomeRatePercent: 10, year: 2026,
    });
    const unknown = estimateTaxReserve({
      collectedIncome: 10000, deductibleExpenses: 0, vehicleDeduction: 0,
      incomeRatePercent: 10, year: 2030,
    });
    expect(unknown.ratesKnown).toBe(false);
    expect(unknown.reserve).toBeCloseTo(known.reserve, 2);
  });
});

describe("summarizeTaxWindow — the card/snapshot aggregator", () => {
  const NOW = new Date(2026, 6, 18); // Jul 18, 2026 → period Q3 (Jun 1 – Aug 31)

  const invoice = (over) => ({
    id: "i1", customer: "Acme", number: "INV-1", desc: "", email: "", phone: "",
    amount: 5000, due: "2026-07-01", paid: false,
    ...over,
  });
  const expense = (over) => ({
    id: "e1", createdAt: "2026-01-01", description: "", amount: 100,
    category: "materials", date: "2026-07-02", notes: "", receiptUri: null,
    ...over,
  });
  const trip = (over) => ({
    id: "t1", date: "2026-06-20", odometerStart: 0, odometerEnd: 100, miles: 100,
    fromJobId: null, fromLabel: "Home / Shop", toJobId: null, toLabel: "Home / Shop",
    purpose: "", createdAt: "2026-06-20",
  ...over,
  });

  const invoices = [
    invoice({
      id: "i1",
      payments: [
        { id: "p1", amount: 1000, date: "2026-06-15", method: "cash" },   // Q3 + YTD
        { id: "p2", amount: 500, date: "2026-02-10", method: "cash" },    // Q1 → YTD only
      ],
    }),
    invoice({ id: "i2", amount: 800, paid: true, paidAt: "2026-04-20" }), // legacy → Q2 → YTD only
  ];
  const expenses = [
    expense({ id: "e1", amount: 300, category: "materials", date: "2026-07-02" }), // Q3 + YTD
    expense({ id: "e2", amount: 200, category: "fuel", date: "2026-07-01" }),      // Q3 + YTD (fuel)
    expense({ id: "e3", amount: 100, category: "tools", date: "2026-03-01" }),     // YTD only
  ];
  const trips = [
    trip({ id: "t1", date: "2026-06-20", miles: 100 }), // Q3 + YTD
    trip({ id: "t2", date: "2026-01-15", miles: 50 }),  // YTD only
  ];

  test("mileage method: period and YTD use ledger income, split windows correctly", () => {
    const s = summarizeTaxWindow({
      invoices, expenses, trips,
      settings: { mileageRate: 0.7, taxIncomeRate: 10, vehicleDeductionMethod: "mileage" },
      now: NOW,
    });
    expect(s.period.quarter).toBe(3);
    // Q3: income 1000 − materials 300 − (100 mi × $0.70) = 630.
    expect(s.current.netProfit).toBeCloseTo(630, 2);
    // YTD: income 2300 − nonVehicle 400 − (150 mi × $0.70) = 1795.
    expect(s.ytd.netProfit).toBeCloseTo(1795, 2);
    expect(s.needsVehicleChoice).toBe(false);
    expect(s.incomeRateSet).toBe(true);
    expect(s.ytdTripCount).toBe(2);
  });

  test("actual method deducts fuel instead of mileage", () => {
    const s = summarizeTaxWindow({
      invoices, expenses, trips,
      settings: { mileageRate: 0.7, taxIncomeRate: 10, vehicleDeductionMethod: "actual" },
      now: NOW,
    });
    // Q3: 1000 − 300 − fuel 200 = 500.
    expect(s.current.netProfit).toBeCloseTo(500, 2);
  });

  test("unset method deducts neither and flags the choice", () => {
    const s = summarizeTaxWindow({
      invoices, expenses, trips,
      settings: { mileageRate: 0.7 },
      now: NOW,
    });
    // Q3: 1000 − 300 = 700 — no vehicle deduction at all.
    expect(s.current.netProfit).toBeCloseTo(700, 2);
    expect(s.needsVehicleChoice).toBe(true);
    expect(s.incomeRateSet).toBe(false);
    expect(s.current.incomeTax).toBe(0);
  });

  test("a voided payment contributes no income", () => {
    const s = summarizeTaxWindow({
      invoices: [invoice({
        id: "i3",
        payments: [{ id: "p9", amount: 1000, date: "2026-06-15", method: "cash", voidedAt: "2026-06-16" }],
      })],
      expenses: [], trips: [],
      settings: {},
      now: NOW,
    });
    expect(s.current.netProfit).toBe(0);
    expect(s.current.reserve).toBe(0);
  });

  test("empty books produce a calm zero state", () => {
    const s = summarizeTaxWindow({ invoices: [], expenses: [], trips: [], settings: {}, now: NOW });
    expect(s.current.reserve).toBe(0);
    expect(s.ytd.reserve).toBe(0);
    expect(s.needsVehicleChoice).toBe(false);
    expect(s.ytdTripCount).toBe(0);
  });
});
