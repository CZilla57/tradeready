// backend-workers/lib/booking/offerable.js
// The shared offer pipeline (Roadmap Phase 26, spec §2.4 `offerableSlots`)
// that slotsCore and reserveCore both call, so offers and the reserve-time
// membership check can never disagree about calendar busy times.
//
// - `off` (no calendar_busy row, or the table is not deployed): exactly
//   today's computation — reservations as extraBusy, the full slotWindowDays.
// - `stale`: no offers. book.html then shows the request form (§1.4).
// - `fresh`: the gate's busy windows join the reservations, and the horizon
//   is cut to the snapshot's last covered date.
// The engine (availability.js) is unchanged; its buffer pads calendar windows
// exactly as it pads reservations (D8).
//
// ⚠️ PARITY: Swift twin `NativeCalendarBusy.offerableSlots`; shared vectors
// in native/ScheduleTests/Fixtures/scheduleVectors.json (`offerableScenarios`).

const { computeCandidateSlots, resolveSlotsUtc, nowInZone } = require('./availability.js');
const { calendarBusyGate } = require('../calendar/busyGate.js');

function epochDays(date) {
  const [y, m, d] = date.split('-').map(Number);
  return Date.UTC(y, m - 1, d) / 86400000;
}

/** Owner-naive candidates (before UTC resolution) plus the gate state. */
function offerableCandidates({ schedule, jobs, reservations, calendarRow, nowMs }) {
  const now = nowInZone(schedule.timeZone, nowMs);
  const extraBusy = reservations.map((r) => ({ date: r.slot_date, start: r.slot_start, end: r.slot_end }));
  let days = schedule.slotWindowDays;

  const gate = calendarBusyGate(calendarRow, { timeZone: schedule.timeZone, nowMs });
  if (gate.state === 'stale') return { state: 'stale', candidates: [] };
  if (gate.state === 'fresh') {
    for (const w of gate.windows) extraBusy.push(w);
    days = Math.max(0, Math.min(days, epochDays(gate.lastCoveredDate) - epochDays(now.date) + 1));
  }

  const candidates = computeCandidateSlots({ schedule, jobs, extraBusy, fromDate: now.date, days, now });
  return { state: gate.state, candidates };
}

/** §2.4 `offerableSlots(...)` → `{state, slots}` with UTC-resolved offers. */
function offerableSlots(input) {
  const { state, candidates } = offerableCandidates(input);
  return { state, slots: resolveSlotsUtc(candidates, input.schedule.timeZone) };
}

module.exports = { offerableCandidates, offerableSlots };
