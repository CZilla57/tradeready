const {
  computeTripMiles,
  mileageSummary,
  formatMiles,
  DEFAULT_MILEAGE_RATE,
} = require('../utils/mileageUtils');

const trip = (over) => ({
  id: 'x', date: '2026-03-10', odometerStart: 0, odometerEnd: 0, miles: 0,
  fromJobId: null, fromLabel: 'Home / Shop', toJobId: null, toLabel: 'Home / Shop',
  purpose: '', createdAt: '2026-03-10', ...over,
});

describe('computeTripMiles', () => {
  test('end minus start', () => expect(computeTripMiles(45210, 45240)).toBe(30));
  test('end < start clamps to 0', () => expect(computeTripMiles(45240, 45210)).toBe(0));
  test('equal readings = 0', () => expect(computeTripMiles(100, 100)).toBe(0));
});

describe('mileageSummary', () => {
  const start = new Date(2026, 0, 1);
  const end = new Date(2026, 11, 31, 23, 59, 59);
  const trips = [
    trip({ date: '2026-03-10', miles: 20 }),
    trip({ date: '2026-06-01', miles: 30 }),
    trip({ date: '2025-12-31', miles: 99 }), // out of range
  ];
  test('sums in-range miles and applies rate', () => {
    const s = mileageSummary(trips, start, end, 0.70);
    expect(s.tripCount).toBe(2);
    expect(s.totalMiles).toBe(50);
    expect(s.deduction).toBeCloseTo(35, 2);
  });
  test('default rate constant is a number', () => {
    expect(typeof DEFAULT_MILEAGE_RATE).toBe('number');
  });
});

describe('formatMiles', () => {
  test('one decimal + suffix', () => expect(formatMiles(12)).toBe('12.0 mi'));
});
