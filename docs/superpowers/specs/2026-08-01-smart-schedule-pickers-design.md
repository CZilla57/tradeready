# Smart Schedule Pickers — Design

**Date:** 2026-08-01
**Status:** Approved by owner (chat, 2026-08-01)
**Scope:** AddJobScreen schedule section, DateTimePickerSheet, new utils/scheduleSmarts.ts

## Problem

The three schedule pickers in AddJobScreen (date, start time, end time) are
completely independent. A job usually already knows its estimated labor time
(`Job.laborHours`, set in the pricing calculator before the job reaches the
scheduling stage), but the pickers ignore it: the user picks a start time, then
manually computes and picks the end time. Time pickers also open at the current
wall-clock minute (e.g. 2:47 PM), producing messy schedule times, and nothing
warns when two jobs are double-booked.

## Decisions (owner-approved)

1. **End-time auto-fill** — picking a start time auto-fills the end time as
   start + `laborHours`, but **only when End is blank**. An existing end time
   (manual or previously auto-filled) is never overwritten. The fill is a
   prefill, not a lock — End stays fully editable.
2. **Only-fill-when-empty** was chosen over "refill unless user-edited" and
   "always refill".
3. **Conflict warning** — inline, non-blocking warning when the chosen window
   overlaps another job's window on the same date.
4. **Smart default start time** — an empty Start picker opens at a sensible
   slot instead of the current minute.
5. **Minute rounding** — time pickers snap to 5-minute intervals.

## Design

### A. New utility: `utils/scheduleSmarts.ts`

Pure functions, no I/O, born-typed. All times are the app's existing `"HH:MM"`
(24h) string format; dates are `"YYYY-MM-DD"`.

- `addLaborToStart(start: string, laborHours: number): string`
  Returns start + laborHours, **rounded up to the next 15-minute boundary**
  (trades think in quarter-hours; rounding down would understate the block),
  clamped to `"23:59"` (the model has no multi-day window). `laborHours <= 0`
  is the caller's guard — callers only invoke this when `laborHours > 0`.
- `defaultStartTime(scheduledDate: string, now: Date): string`
  Any non-today date (future or past) → `"08:00"`. Today or empty date → the
  next half-hour boundary from `now` (2:12 → 2:30, 2:30 → 2:30, 2:47 → 3:00),
  clamped to `"23:30"`.
- `defaultEndTime(start: string, laborHours: number): string`
  Picker-open fallback when End is empty but Start is set:
  `addLaborToStart(start, laborHours > 0 ? laborHours : 1)`.
- `formatLaborHint(laborHours: number): string`
  `2 → "2h"`, `2.5 → "2h 30m"` (for the hint row).
- `findScheduleConflicts(jobs, opts): Job[]` where
  `opts = { excludeJobId?, date, start, end?, laborHours }`.
  Returns other jobs that overlap the candidate window. Rules:
  - Candidate window: `[start, end]`; when `end` is empty, fall back to
    `start + max(laborHours, 1h)`.
  - A job conflicts only if: same `scheduledDate`, has a `scheduledStartTime`,
    `id !== excludeJobId`, and its status is **not** terminal
    (`complete`, `invoiced`, `paid`, `declined` — those schedules are history).
  - Other job's window: its own start→end; if it has no end time, block out
    `start + max(its laborHours, 1h)`.
  - Jobs with a date but no start time never conflict (no window to test).
  - Overlap is strict: `aStart < bEnd && bStart < aEnd` — windows that merely
    touch (9–11 and 11–1) do NOT conflict.

### B. `components/DateTimePickerSheet.tsx` — one optional generic prop

- New prop `minuteInterval?: number`, passed through to the native
  `DateTimePicker` on both platforms (supported by the installed
  `@react-native-community/datetimepicker@8.4.4`; prop only — **no dependency
  change**).
- When `minuteInterval` is set, the incoming `value`'s minutes are rounded to
  the nearest interval multiple (with hour carry, e.g. 9:58 → 10:00) before
  display, so pre-existing odd times (9:37) don't confuse the iOS spinner.
- No job-specific knowledge enters this shared primitive — it stays usable by
  AddExpenseModal / RecordPaymentSheet / AddRecurringInvoiceScreen unchanged
  (date mode ignores the prop; they simply don't pass it).

### C. `screens/AddJobScreen.tsx` wiring

- Load `laborHours` from the job on the edit path (new jobs: 0 — no auto-fill,
  no hint; that's correct, they haven't been priced yet).
- Both time pickers get `minuteInterval={5}`.
- **Auto-fill trigger — on picker close, not per-tick.** The iOS sheet emits
  `onChange` live while the user scrolls; filling on the first tick would
  freeze End at a stale value while Start keeps moving (violating
  only-fill-when-empty for the rest of the scroll). So the fill runs once,
  when the start picker closes: an effect keyed on `showStartTimePicker`
  detects the visible→hidden transition (previous-value ref) and, if
  `scheduledStartTime && !scheduledEndTime && laborHours > 0`, sets
  `scheduledEndTime = addLaborToStart(start, laborHours)`. Clearing End later
  does NOT re-trigger a fill (no visibility transition). Accepted minor
  behavior: dismissing the start picker without changing anything, while Start
  is set and End is empty, still fills End — harmless and consistent.
- **Start picker default:** when Start is empty, the picker's `value` is
  `defaultStartTime(scheduledDate, new Date())` instead of `new Date()`.
  Because the iOS sheet's Done commits the displayed value, tapping Done
  immediately accepts the sensible default. When End is empty and Start is
  set, the end picker's `value` is `defaultEndTime(start, laborHours)`.
- **Hint row:** when `laborHours > 0`, a muted caption under the time row:
  `Est. labor: 2h 30m`.
- **Conflict row:** jobs list (already fetched in `load()`) is kept in state;
  a `useMemo` over `[jobs, scheduledDate, scheduledStartTime,
  scheduledEndTime]` computes `findScheduleConflicts`. Non-empty result
  renders a warning row under the schedule section using the theme's warning
  color: `⚠ Overlaps: Faucet repair, 9:00–11:00 AM` (first conflict named;
  `+N more` if several). **Warning only — saving is never blocked.**

### D. Explicitly out of scope

- No data-model changes (all fields already exist), no sync implications,
  no new dependencies, no changes to AddExpenseModal / RecordPaymentSheet /
  AddRecurringInvoiceScreen call sites.
- RecurringJob occurrence generation is untouched — generated occurrences
  copy schedule fields as today.
- No calendar-style availability view; the Route/Today screens are untouched.

## Testing

New `__tests__/scheduleSmarts.test.js` (pure-function suite):

- `addLaborToStart`: whole hours on boundary stay put (9:00+2h→11:00),
  fractional round-up (9:00+1.7h→10:45, 9:10+2.5h→11:45, 9:05+0.25h→9:30),
  midnight clamp (22:00+3h→23:59).
- `defaultStartTime`: future date→08:00; today at 2:12→2:30, 2:30→2:30,
  2:47→3:00; late-night clamp →23:30.
- `formatLaborHint`: 2→"2h", 2.5→"2h 30m", 0.25→"15m".
- `findScheduleConflicts`: overlap detected; touching windows don't conflict;
  different-date jobs don't conflict; no-start-time jobs don't conflict;
  terminal statuses (complete/invoiced/paid/declined) excluded; excludeJobId excluded;
  missing-end fallback windows (both sides); empty candidate end uses
  `max(laborHours, 1h)`.

Screen-level behavior is covered by the standard gate (tsc 0 / all tests /
lint 0) — consistent with how AddJob's existing picker wiring is tested.

## Files touched

| File | Change |
|---|---|
| `utils/scheduleSmarts.ts` | NEW — pure schedule-intelligence functions |
| `components/DateTimePickerSheet.tsx` | optional `minuteInterval` prop + value rounding |
| `screens/AddJobScreen.tsx` | laborHours state, auto-fill effect, picker defaults, hint row, conflict row |
| `__tests__/scheduleSmarts.test.js` | NEW — pure-function tests |
