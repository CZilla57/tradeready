// __tests__/dateTimePickerSheet.test.ts
// Pins roundToMinuteInterval: incoming picker values snap to the interval so
// pre-existing odd times (9:37) don't confuse the iOS spinner, with hour
// carry and a never-roll-to-next-day clamp.

import { roundToMinuteInterval } from '../components/DateTimePickerSheet';

function at(h: number, m: number): Date {
  const d = new Date(2026, 7, 1);
  d.setHours(h, m, 0, 0);
  return d;
}

describe('roundToMinuteInterval', () => {
  test('rounds to the nearest interval multiple', () => {
    const r = roundToMinuteInterval(at(9, 37), 5);
    expect(r.getHours()).toBe(9);
    expect(r.getMinutes()).toBe(35);
  });

  test('rounds up with hour carry', () => {
    const r = roundToMinuteInterval(at(9, 58), 5);
    expect(r.getHours()).toBe(10);
    expect(r.getMinutes()).toBe(0);
  });

  test('exact multiples are unchanged', () => {
    const r = roundToMinuteInterval(at(14, 30), 5);
    expect(r.getHours()).toBe(14);
    expect(r.getMinutes()).toBe(30);
  });

  test('never rolls into the next day', () => {
    const r = roundToMinuteInterval(at(23, 59), 5);
    expect(r.getHours()).toBe(23);
    expect(r.getMinutes()).toBe(55);
    expect(r.getDate()).toBe(1);
  });

  test('no interval returns the value untouched', () => {
    const v = at(9, 37);
    expect(roundToMinuteInterval(v, undefined)).toBe(v);
  });
});
