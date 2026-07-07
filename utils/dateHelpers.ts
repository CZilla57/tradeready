// utils/dateHelpers.ts
// Pure date/time formatting + week-math helpers, extracted from TodayScreen
// (roadmap #7) so the fiddly bits — week boundaries, 12-hour clock formatting,
// day-diff phrasing — are unit-tested instead of buried in an 800-line screen.
//
// Conventions:
//   * "date string" everywhere means a local "YYYY-MM-DD" (NOT a UTC ISO
//     timestamp) — matches how jobs store scheduledDate. All the *DateString
//     helpers build/parse via the local-time Date constructor so a day never
//     shifts under a timezone offset.
//   * The now-dependent helpers accept an injectable clock (defaulting to the
//     real time) purely so tests are deterministic; callers pass nothing.

const MONTHS = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];

/** Local "YYYY-MM-DD" for a Date (zero-padded). */
export function toDateString(date: Date): string {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, "0");
  const d = String(date.getDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

/** Today's local date string. */
export function getTodayDateString(now: Date = new Date()): string {
  return toDateString(now);
}

/** "Saturday, July 4" — long weekday + month, from a "YYYY-MM-DD" string. */
export function formatDisplayDate(dateString: string): string {
  const [year, month, day] = dateString.split("-").map(Number);
  return new Date(year, month - 1, day).toLocaleDateString("en-US", {
    weekday: "long",
    month: "long",
    day: "numeric",
  });
}

/** Time-of-day greeting: morning < 12:00, afternoon < 17:00, else evening. */
export function getGreeting(now: Date = new Date()): string {
  const h = now.getHours();
  if (h < 12) return "Good morning";
  if (h < 17) return "Good afternoon";
  return "Good evening";
}

/**
 * "9:00 AM – 11:00 AM", or just the start when there's no end, or "Unscheduled"
 * when there's no start. Inputs are "HH:MM" 24-hour strings.
 */
export function formatTimeRange(
  startTime: string | null | undefined,
  endTime: string | null | undefined,
): string {
  if (!startTime) return "Unscheduled";
  const fmt = (t: string): string => {
    const [h, m] = t.split(":").map(Number);
    const period = h >= 12 ? "PM" : "AM";
    const hour = h % 12 === 0 ? 12 : h % 12;
    return `${hour}:${String(m).padStart(2, "0")} ${period}`;
  };
  return endTime ? `${fmt(startTime)} – ${fmt(endTime)}` : fmt(startTime);
}

/** "today" / "1 day ago" / "N days ago" — or "recently" when the date is absent. */
export function daysAgo(dateString: string | null | undefined, nowMs: number = Date.now()): string {
  if (!dateString) return "recently";
  const diff = Math.floor((nowMs - new Date(dateString).getTime()) / 86400000);
  if (diff === 0) return "today";
  if (diff === 1) return "1 day ago";
  return `${diff} days ago`;
}

/** The Mon–Sun local date strings for the week containing anchorDateStr. */
export function getWeekDates(anchorDateStr: string): string[] {
  const [y, m, d] = anchorDateStr.split("-").map(Number);
  const anchor = new Date(y, m - 1, d);
  const dayOfWeek = anchor.getDay(); // 0 = Sun
  const monday = new Date(anchor);
  monday.setDate(anchor.getDate() - ((dayOfWeek + 6) % 7));
  return Array.from({ length: 7 }, (_, i) => {
    const dd = new Date(monday);
    dd.setDate(monday.getDate() + i);
    return toDateString(dd);
  });
}

/** "Jul 2026" for a single-month week, "Jun – Jul 2026" when it straddles two. */
export function weekMonthLabel(weekDates: string[]): string {
  const first = new Date(weekDates[0]);
  const last = new Date(weekDates[6]);
  if (first.getMonth() === last.getMonth()) {
    return `${MONTHS[first.getMonth()]} ${first.getFullYear()}`;
  }
  return `${MONTHS[first.getMonth()]} – ${MONTHS[last.getMonth()]} ${last.getFullYear()}`;
}

/** Shift a "YYYY-MM-DD" string by ±days, returning a new date string. */
export function shiftDate(dateStr: string, days: number): string {
  const [y, m, d] = dateStr.split("-").map(Number);
  const date = new Date(y, m - 1, d);
  date.setDate(date.getDate() + days);
  return toDateString(date);
}
