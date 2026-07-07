// __tests__/dateHelpers.test.js
// Roadmap #7 (7.1): pure date/time + week-math helpers extracted from
// TodayScreen. These pin the fiddly bits — 12-hour clock formatting, week
// boundaries, day-diff phrasing — that were previously untested inside the
// screen. The now-dependent helpers take an injected clock so assertions are
// deterministic regardless of the machine timezone.

import {
  toDateString,
  getTodayDateString,
  formatDisplayDate,
  getGreeting,
  formatTimeRange,
  daysAgo,
  getWeekDates,
  weekMonthLabel,
  shiftDate,
} from "../utils/dateHelpers";

const DAY = 86400000;

describe("toDateString / getTodayDateString", () => {
  test("formats a Date as zero-padded local YYYY-MM-DD", () => {
    expect(toDateString(new Date(2026, 0, 5))).toBe("2026-01-05");   // Jan
    expect(toDateString(new Date(2026, 10, 3))).toBe("2026-11-03");  // Nov
    expect(toDateString(new Date(2026, 6, 4))).toBe("2026-07-04");
  });

  test("getTodayDateString uses the injected clock", () => {
    expect(getTodayDateString(new Date(2026, 6, 4))).toBe("2026-07-04");
  });

  test("getTodayDateString defaults to a well-formed string", () => {
    expect(getTodayDateString()).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });
});

describe("formatDisplayDate", () => {
  test("renders long weekday + month from a date string", () => {
    // 2026-07-04 is a Saturday.
    expect(formatDisplayDate("2026-07-04")).toBe("Saturday, July 4");
    // 2026-01-01 is a Thursday.
    expect(formatDisplayDate("2026-01-01")).toBe("Thursday, January 1");
  });
});

describe("getGreeting", () => {
  test("morning before noon", () => {
    expect(getGreeting(new Date(2026, 0, 1, 0))).toBe("Good morning");
    expect(getGreeting(new Date(2026, 0, 1, 8))).toBe("Good morning");
    expect(getGreeting(new Date(2026, 0, 1, 11, 59))).toBe("Good morning");
  });
  test("afternoon from noon to 16:59", () => {
    expect(getGreeting(new Date(2026, 0, 1, 12))).toBe("Good afternoon");
    expect(getGreeting(new Date(2026, 0, 1, 16, 59))).toBe("Good afternoon");
  });
  test("evening from 17:00", () => {
    expect(getGreeting(new Date(2026, 0, 1, 17))).toBe("Good evening");
    expect(getGreeting(new Date(2026, 0, 1, 23))).toBe("Good evening");
  });
});

describe("formatTimeRange", () => {
  test("no start time is Unscheduled", () => {
    expect(formatTimeRange(null, null)).toBe("Unscheduled");
    expect(formatTimeRange(undefined, "11:00")).toBe("Unscheduled");
    expect(formatTimeRange("", null)).toBe("Unscheduled");
  });
  test("start + end renders an en-dash range", () => {
    expect(formatTimeRange("09:00", "11:00")).toBe("9:00 AM – 11:00 AM");
    expect(formatTimeRange("23:05", "23:45")).toBe("11:05 PM – 11:45 PM");
  });
  test("start only renders a single time", () => {
    expect(formatTimeRange("13:30", null)).toBe("1:30 PM");
  });
  test("noon and midnight map to 12", () => {
    expect(formatTimeRange("00:15", null)).toBe("12:15 AM");
    expect(formatTimeRange("12:00", null)).toBe("12:00 PM");
  });
});

describe("daysAgo", () => {
  // Anchor now to the same UTC instant the date string parses to, so the bucket
  // math is timezone-independent.
  const base = new Date("2026-07-01").getTime();
  test("absent date is 'recently'", () => {
    expect(daysAgo(null)).toBe("recently");
    expect(daysAgo("")).toBe("recently");
  });
  test("same day is 'today'", () => {
    expect(daysAgo("2026-07-01", base + 0.5 * DAY)).toBe("today");
  });
  test("one day is singular", () => {
    expect(daysAgo("2026-07-01", base + 1.5 * DAY)).toBe("1 day ago");
  });
  test("multiple days is plural", () => {
    expect(daysAgo("2026-07-01", base + 3.2 * DAY)).toBe("3 days ago");
  });
});

describe("getWeekDates", () => {
  test("returns Mon–Sun for the week containing a Saturday anchor", () => {
    // 2026-07-04 is a Saturday → week runs Mon 06-29 … Sun 07-05.
    expect(getWeekDates("2026-07-04")).toEqual([
      "2026-06-29", "2026-06-30", "2026-07-01", "2026-07-02",
      "2026-07-03", "2026-07-04", "2026-07-05",
    ]);
  });
  test("a Sunday anchor stays in the same Mon–Sun week", () => {
    // 2026-07-05 is a Sunday → same week as the Saturday above.
    expect(getWeekDates("2026-07-05")[0]).toBe("2026-06-29");
    expect(getWeekDates("2026-07-05")[6]).toBe("2026-07-05");
  });
  test("a Monday anchor starts its own week", () => {
    expect(getWeekDates("2026-06-29")[0]).toBe("2026-06-29");
  });
});

describe("weekMonthLabel", () => {
  test("single-month week shows one month", () => {
    expect(weekMonthLabel(getWeekDates("2026-07-15"))).toBe("Jul 2026");
  });
  test("cross-month week shows both months", () => {
    expect(weekMonthLabel(getWeekDates("2026-07-04"))).toBe("Jun – Jul 2026");
  });
});

describe("shiftDate", () => {
  test("shifts forward and back within a month", () => {
    expect(shiftDate("2026-07-04", 1)).toBe("2026-07-05");
    expect(shiftDate("2026-07-04", -1)).toBe("2026-07-03");
    expect(shiftDate("2026-07-04", 7)).toBe("2026-07-11");
  });
  test("rolls across month and year boundaries", () => {
    expect(shiftDate("2026-07-31", 1)).toBe("2026-08-01");
    expect(shiftDate("2026-01-01", -1)).toBe("2025-12-31");
  });
});
