# Smart Schedule Pickers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make AddJobScreen's schedule pickers labor-aware: auto-fill end time from `Job.laborHours`, smart default start times, 5-minute snapping, and a non-blocking double-booking warning.

**Architecture:** All intelligence lives in a new pure-function module `utils/scheduleSmarts.ts` (no I/O, fully unit-tested). The shared `DateTimePickerSheet` gains exactly one generic optional prop (`minuteInterval`) and stays job-agnostic. `AddJobScreen` wires the pieces together. Spec: `docs/superpowers/specs/2026-08-01-smart-schedule-pickers-design.md`.

**Tech Stack:** Expo 54 / React Native 0.81 / React 19 / TypeScript strict / Jest (jest-expo). No new dependencies.

## Global Constraints

- Work on branch `feat/smart-schedule-pickers` (already exists; spec committed as `a442007`).
- **No `package.json` changes of any kind** (change-control rule 3). `minuteInterval` is a prop already supported by the installed `@react-native-community/datetimepicker@8.4.4`.
- **No persisted data-shape changes** — every field used (`scheduledDate`, `scheduledStartTime`, `scheduledEndTime`, `laborHours`) already exists on `Job`.
- Gate before EVERY commit, run from `tradeready/`: `npm run typecheck` (0 errors), `npm test` (all pass; baseline 1511 tests / 95 suites), `npm run lint` (0 warnings). Never commit red (change-control rule 2).
- No `eslint-disable` / `@ts-ignore` / `@ts-expect-error`.
- Themed components use the createStyles factory pattern with `useMemo(() => createStyles(colors, shadow), [colors, shadow])` — already in place in both touched components; new styles go inside the existing `createStyles`.
- Time strings are `"HH:MM"` 24-hour; date strings are `"YYYY-MM-DD"` (existing app-wide convention).
- All times/dates are computed in the device's LOCAL frame — never `toISOString()` for date math (FA-039 precedent).

---

### Task 1: `utils/scheduleSmarts.ts` — pure schedule-intelligence functions

**Files:**
- Create: `utils/scheduleSmarts.ts`
- Test: `__tests__/scheduleSmarts.test.ts`

**Interfaces:**
- Consumes: `Job` type from `types/models.ts` (fields: `id`, `status`, `scheduledDate`, `scheduledStartTime`, `scheduledEndTime`, `laborHours`).
- Produces (Task 3 relies on these exact signatures):
  - `addLaborToStart(start: string, laborHours: number): string`
  - `defaultStartTime(scheduledDate: string, now: Date): string`
  - `defaultEndTime(start: string, laborHours: number): string`
  - `formatLaborHint(laborHours: number): string`
  - `findScheduleConflicts(jobs: Job[], query: ConflictQuery): Job[]` where
    `type ConflictQuery = { excludeJobId?: string; date: string; start: string; end?: string | null; laborHours: number }`

- [ ] **Step 1: Write the failing test**

Create `__tests__/scheduleSmarts.test.ts`:

```ts
// __tests__/scheduleSmarts.test.ts
// Pins the labor-aware scheduling rules from the 2026-08-01 smart-schedule-
// pickers spec: end = start + labor rounded UP to 15 min, 08:00 default for
// non-today dates, next half-hour for today, and non-blocking overlap
// detection that ignores terminal-status jobs.

import {
  addLaborToStart,
  defaultStartTime,
  defaultEndTime,
  formatLaborHint,
  findScheduleConflicts,
} from '../utils/scheduleSmarts';
import type { Job } from '../types/models';

function job(overrides: Partial<Job>): Job {
  return {
    id: 'j_other',
    customerId: 'c1',
    customerName: 'A',
    title: 'Faucet repair',
    description: '',
    status: 'scheduled',
    scheduledDate: '2026-08-03',
    scheduledStartTime: '09:00',
    scheduledEndTime: '11:00',
    address: '',
    estimateTotal: 0,
    laborHours: 2,
    laborRate: 85,
    materials: [],
    materialMarkup: 20,
    overhead: 15,
    margin: 20,
    notes: '',
    invoiceId: null,
    createdAt: '2026-08-01',
    ...overrides,
  };
}

describe('addLaborToStart', () => {
  test('whole hours landing on a boundary stay put', () => {
    expect(addLaborToStart('09:00', 2)).toBe('11:00');
  });

  test('fractional hours round UP to the next 15-minute boundary', () => {
    expect(addLaborToStart('09:00', 1.7)).toBe('10:45'); // 10:42 → 10:45
    expect(addLaborToStart('09:10', 2.5)).toBe('11:45'); // 11:40 → 11:45
    expect(addLaborToStart('09:05', 0.25)).toBe('09:30'); // 09:20 → 09:30
  });

  test('never crosses midnight — clamps to 23:59', () => {
    expect(addLaborToStart('22:00', 3)).toBe('23:59');
  });
});

describe('defaultStartTime', () => {
  const today2pm12 = new Date(2026, 7, 1, 14, 12); // Aug 1 2026, 2:12 PM local

  test('non-today date (future or past) → 08:00', () => {
    expect(defaultStartTime('2026-08-05', today2pm12)).toBe('08:00');
    expect(defaultStartTime('2026-07-20', today2pm12)).toBe('08:00');
  });

  test('today → next half-hour boundary', () => {
    expect(defaultStartTime('2026-08-01', today2pm12)).toBe('14:30');
    expect(defaultStartTime('2026-08-01', new Date(2026, 7, 1, 14, 30))).toBe('14:30');
    expect(defaultStartTime('2026-08-01', new Date(2026, 7, 1, 14, 47))).toBe('15:00');
  });

  test('empty date behaves like today', () => {
    expect(defaultStartTime('', today2pm12)).toBe('14:30');
  });

  test('late night clamps to 23:30', () => {
    expect(defaultStartTime('', new Date(2026, 7, 1, 23, 45))).toBe('23:30');
  });
});

describe('defaultEndTime', () => {
  test('uses labor hours when priced', () => {
    expect(defaultEndTime('09:00', 2.5)).toBe('11:30');
  });

  test('falls back to 1 hour when unpriced', () => {
    expect(defaultEndTime('09:00', 0)).toBe('10:00');
  });
});

describe('formatLaborHint', () => {
  test('whole hours', () => {
    expect(formatLaborHint(2)).toBe('2h');
  });
  test('mixed hours and minutes', () => {
    expect(formatLaborHint(2.5)).toBe('2h 30m');
  });
  test('sub-hour', () => {
    expect(formatLaborHint(0.25)).toBe('15m');
  });
});

describe('findScheduleConflicts', () => {
  const base = { date: '2026-08-03', start: '10:00', end: '12:00', laborHours: 2 };

  test('detects an overlapping window on the same date', () => {
    expect(findScheduleConflicts([job({})], base)).toHaveLength(1);
  });

  test('windows that merely touch do NOT conflict', () => {
    // other job 09:00–10:00, candidate starts 10:00
    expect(
      findScheduleConflicts([job({ scheduledEndTime: '10:00' })], base)
    ).toHaveLength(0);
  });

  test('different dates never conflict', () => {
    expect(
      findScheduleConflicts([job({ scheduledDate: '2026-08-04' })], base)
    ).toHaveLength(0);
  });

  test('a job with no start time never conflicts', () => {
    expect(
      findScheduleConflicts(
        [job({ scheduledStartTime: null, scheduledEndTime: null })],
        base
      )
    ).toHaveLength(0);
  });

  test('terminal statuses are history — excluded', () => {
    expect(findScheduleConflicts([job({ status: 'complete' })], base)).toHaveLength(0);
    expect(findScheduleConflicts([job({ status: 'invoiced' })], base)).toHaveLength(0);
    expect(findScheduleConflicts([job({ status: 'paid' })], base)).toHaveLength(0);
  });

  test('the job being edited is excluded via excludeJobId', () => {
    expect(
      findScheduleConflicts([job({ id: 'j_me' })], { ...base, excludeJobId: 'j_me' })
    ).toHaveLength(0);
  });

  test('other job missing end time blocks max(laborHours, 1h)', () => {
    // 09:00 + 2h labor → blocks 09:00–11:00, overlaps candidate 10:00 start
    expect(
      findScheduleConflicts([job({ scheduledEndTime: null, laborHours: 2 })], base)
    ).toHaveLength(1);
    // 09:00 + max(0,1)=1h → blocks 09:00–10:00, touches only
    expect(
      findScheduleConflicts([job({ scheduledEndTime: null, laborHours: 0 })], base)
    ).toHaveLength(0);
  });

  test('empty candidate end falls back to max(laborHours, 1h)', () => {
    // candidate 10:00 + 2h → 10:00–12:00, other job 11:00–13:00 overlaps
    expect(
      findScheduleConflicts(
        [job({ scheduledStartTime: '11:00', scheduledEndTime: '13:00' })],
        { date: '2026-08-03', start: '10:00', end: null, laborHours: 2 }
      )
    ).toHaveLength(1);
  });

  test('missing date or start returns no conflicts', () => {
    expect(findScheduleConflicts([job({})], { ...base, date: '' })).toHaveLength(0);
    expect(findScheduleConflicts([job({})], { ...base, start: '' })).toHaveLength(0);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run (from `tradeready/`): `npx jest __tests__/scheduleSmarts.test.ts`
Expected: FAIL — `Cannot find module '../utils/scheduleSmarts'`

- [ ] **Step 3: Write the implementation**

Create `utils/scheduleSmarts.ts`:

```ts
// utils/scheduleSmarts.ts
// Pure schedule-intelligence helpers behind AddJobScreen's smart pickers
// (2026-08-01 spec: docs/superpowers/specs/2026-08-01-smart-schedule-pickers-design.md).
// Times are "HH:MM" 24-hour strings; dates are "YYYY-MM-DD". All math is
// minutes-since-midnight in the device's local frame — no Date parsing of
// date strings, no UTC (FA-039).

import type { Job } from "../types/models";

/**
 * Job statuses whose schedules are history — never flagged as conflicts. A
 * job declined via the estimate-approval loop keeps its schedule fields, but
 * its slot is dead — warning against it would mislead.
 */
const TERMINAL_STATUSES: ReadonlySet<Job["status"]> = new Set([
  "complete",
  "invoiced",
  "paid",
  "declined",
]);

export type ConflictQuery = {
  excludeJobId?: string;
  date: string;
  start: string;
  end?: string | null;
  laborHours: number;
};

function toMinutes(time: string): number {
  const [h, m] = time.split(":").map(Number);
  return h * 60 + m;
}

function toTimeString(totalMinutes: number): string {
  const clamped = Math.min(totalMinutes, 23 * 60 + 59);
  const h = Math.floor(clamped / 60);
  const m = clamped % 60;
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
}

/**
 * start + laborHours, rounded UP to the next 15-minute boundary (trades think
 * in quarter-hours; rounding down would understate the block), clamped to
 * 23:59 — the schedule has no multi-day window. Callers guard laborHours > 0.
 */
export function addLaborToStart(start: string, laborHours: number): string {
  const raw = toMinutes(start) + laborHours * 60;
  return toTimeString(Math.ceil(raw / 15) * 15);
}

/**
 * Picker-open default when Start is empty: 08:00 for any non-today date,
 * otherwise the next half-hour boundary from `now`, clamped to 23:30.
 */
export function defaultStartTime(scheduledDate: string, now: Date): string {
  const today = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`;
  if (scheduledDate && scheduledDate !== today) return "08:00";
  const next = Math.ceil((now.getHours() * 60 + now.getMinutes()) / 30) * 30;
  return toTimeString(Math.min(next, 23 * 60 + 30));
}

/** Picker-open default when End is empty but Start is set. */
export function defaultEndTime(start: string, laborHours: number): string {
  return addLaborToStart(start, laborHours > 0 ? laborHours : 1);
}

/** 2 → "2h", 2.5 → "2h 30m", 0.25 → "15m" (for the schedule hint row). */
export function formatLaborHint(laborHours: number): string {
  const totalMinutes = Math.round(laborHours * 60);
  const h = Math.floor(totalMinutes / 60);
  const m = totalMinutes % 60;
  if (h > 0 && m > 0) return `${h}h ${m}m`;
  if (h > 0) return `${h}h`;
  return `${m}m`;
}

/** [startMinutes, endMinutes) window; a missing end blocks max(labor, 1h). */
function window(
  start: string,
  end: string | null | undefined,
  laborHours: number
): [number, number] {
  const s = toMinutes(start);
  if (end) return [s, toMinutes(end)];
  return [s, Math.min(s + Math.max(laborHours, 1) * 60, 24 * 60)];
}

/**
 * Other jobs whose window overlaps the candidate window on the same date.
 * Strict overlap — windows that merely touch (9–11 vs 11–1) don't conflict.
 * Warning-only by design: callers must never block saving on this.
 */
export function findScheduleConflicts(jobs: Job[], query: ConflictQuery): Job[] {
  if (!query.date || !query.start) return [];
  const [qStart, qEnd] = window(query.start, query.end, query.laborHours);
  return jobs.filter((j) => {
    if (j.id === query.excludeJobId) return false;
    if (j.scheduledDate !== query.date) return false;
    if (!j.scheduledStartTime) return false;
    if (TERMINAL_STATUSES.has(j.status)) return false;
    const [s, e] = window(j.scheduledStartTime, j.scheduledEndTime, j.laborHours ?? 0);
    return qStart < e && s < qEnd;
  });
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx jest __tests__/scheduleSmarts.test.ts`
Expected: PASS — 21 tests.

- [ ] **Step 5: Run the full gate**

Run: `npm run typecheck` then `npm run lint` then `npm test`
Expected: 0 errors / 0 warnings / all suites pass (baseline + 1 new suite).

- [ ] **Step 6: Commit**

```bash
git add utils/scheduleSmarts.ts __tests__/scheduleSmarts.test.ts
git commit -m "feat: add scheduleSmarts utils for labor-aware scheduling"
```

---

### Task 2: `DateTimePickerSheet` — optional `minuteInterval` prop

**Files:**
- Modify: `components/DateTimePickerSheet.tsx`
- Test: `__tests__/dateTimePickerSheet.test.ts` (new)

**Interfaces:**
- Consumes: nothing new.
- Produces (Task 3 relies on these):
  - New optional prop `minuteInterval?: MinuteInterval` on `DateTimePickerSheet`, where `type MinuteInterval = 1 | 2 | 3 | 4 | 5 | 6 | 10 | 12 | 15 | 20 | 30` (mirrors the non-exported union in `@react-native-community/datetimepicker`'s `index.d.ts` line 8 — declare it locally, do NOT try to import it).
  - Named export `roundToMinuteInterval(value: Date, minuteInterval?: number): Date`.

- [ ] **Step 1: Write the failing test**

Create `__tests__/dateTimePickerSheet.test.ts`:

```ts
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx jest __tests__/dateTimePickerSheet.test.ts`
Expected: FAIL — `roundToMinuteInterval` is not exported.

- [ ] **Step 3: Implement**

In `components/DateTimePickerSheet.tsx`:

3a. Extend the header comment (after the existing paragraph ending "…gets a Date back in `onChange`." at line 18) with:

```
// `minuteInterval` (optional, time mode) snaps selection to that many minutes
// on both platforms; the incoming value is pre-rounded via
// roundToMinuteInterval so stored odd times (9:37) don't confuse the spinner.
```

3b. Replace the props type (lines 36–43) with:

```tsx
/** Mirrors the non-exported MinuteInterval union in
 * @react-native-community/datetimepicker's index.d.ts. */
type MinuteInterval = 1 | 2 | 3 | 4 | 5 | 6 | 10 | 12 | 15 | 20 | 30;

type DateTimePickerSheetProps = {
  visible: boolean;
  mode: "date" | "time";
  value: Date;
  title: string;
  onChange: (date: Date) => void;
  onClose: () => void;
  /** Snap time selection to this many minutes (time mode only). */
  minuteInterval?: MinuteInterval;
};
```

3c. Add the exported helper directly above the component:

```tsx
/**
 * Round a Date's time-of-day to the nearest interval multiple (hour carry,
 * clamped so 23:59 never rolls into the next day). Exported for tests and
 * used to pre-round incoming picker values.
 */
export function roundToMinuteInterval(value: Date, minuteInterval?: number): Date {
  if (!minuteInterval || minuteInterval <= 1) return value;
  let total =
    Math.round((value.getHours() * 60 + value.getMinutes()) / minuteInterval) *
    minuteInterval;
  if (total >= 24 * 60) total = 24 * 60 - minuteInterval;
  const rounded = new Date(value);
  rounded.setHours(Math.floor(total / 60), total % 60, 0, 0);
  return rounded;
}
```

3d. In the component: accept the prop and pre-round the value. Change the destructuring and add one line after `const isDate = mode === "date";`:

```tsx
export function DateTimePickerSheet({
  visible,
  mode,
  value,
  title,
  onChange,
  onClose,
  minuteInterval,
}: DateTimePickerSheetProps) {
  const { colors, shadow, isDark } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  if (!visible) return null;

  const isDate = mode === "date";
  const pickerValue = isDate ? value : roundToMinuteInterval(value, minuteInterval);
```

3e. In the iOS branch: the Done button's `onPress` commits `pickerValue` instead of `value` (`onChange(pickerValue)`); the `DateTimePicker` gets `value={pickerValue}` and `minuteInterval={minuteInterval}`.

3f. In the Android return: `value={pickerValue}` and `minuteInterval={minuteInterval}` on the `DateTimePicker`.

No other changes — the existing five call sites (AddJob ×4 via Task 3, AddExpenseModal, RecordPaymentSheet, AddRecurringInvoiceScreen, ExportDataScreen) omit the prop and behave exactly as before.

- [ ] **Step 4: Run test to verify it passes**

Run: `npx jest __tests__/dateTimePickerSheet.test.ts`
Expected: PASS — 5 tests.

- [ ] **Step 5: Run the full gate**

Run: `npm run typecheck` then `npm run lint` then `npm test`
Expected: 0 / 0 / all pass.

- [ ] **Step 6: Commit**

```bash
git add components/DateTimePickerSheet.tsx __tests__/dateTimePickerSheet.test.ts
git commit -m "feat: add minuteInterval snapping to DateTimePickerSheet"
```

---

### Task 3: Wire smart pickers into `AddJobScreen`

**Files:**
- Modify: `screens/AddJobScreen.tsx`

**Interfaces:**
- Consumes:
  - From Task 1: `addLaborToStart`, `defaultStartTime`, `defaultEndTime`, `formatLaborHint`, `findScheduleConflicts` from `../utils/scheduleSmarts`.
  - From Task 2: `minuteInterval` prop on `DateTimePickerSheet`.
- Produces: user-facing behavior only; nothing downstream consumes this task.

Line numbers below refer to the file BEFORE this task's edits (881-line version at commit `a442007`).

- [ ] **Step 1: Imports**

Add to the import block (near line 27, after the `DateTimePickerSheet` import):

```tsx
import {
  addLaborToStart,
  defaultStartTime,
  defaultEndTime,
  formatLaborHint,
  findScheduleConflicts,
} from "../utils/scheduleSmarts";
```

Extend the type-only import at line 31 to include `Job`:

```tsx
import type { Customer, Job, RecurrenceCadence, RecurrenceEndCondition, RecurringJob } from "../types/models";
```

- [ ] **Step 2: State**

After the `scheduledEndTime` state (line 51), add:

```tsx
  // Estimated labor from the pricing calculator (edit path only — new jobs
  // are unpriced) and the full jobs list for overlap warnings.
  const [laborHours, setLaborHours] = useState<number>(0);
  const [allJobs, setAllJobs] = useState<Job[]>([]);
```

- [ ] **Step 3: Populate in `load()`**

After `setCustomers(custs);` (line 86) add:

```tsx
      setAllJobs(jobs);
```

Inside the edit branch, after `setScheduledEndTime(j.scheduledEndTime || "");` (line 97) add:

```tsx
          setLaborHours(j.laborHours || 0);
```

- [ ] **Step 4: Auto-fill effect + conflicts memo + window label helper**

Immediately after the `displayTime` function (line 159), add:

```tsx
  // End-time auto-fill (spec: fill only when End is blank). Runs when the
  // start picker CLOSES, not per onChange tick — the iOS sheet emits live
  // changes while the user scrolls, and filling on the first tick would
  // freeze a stale end time while Start keeps moving.
  const startPickerWasVisible = useRef(false);
  useEffect(() => {
    const justClosed = startPickerWasVisible.current && !showStartTimePicker;
    startPickerWasVisible.current = showStartTimePicker;
    if (justClosed && scheduledStartTime && !scheduledEndTime && laborHours > 0) {
      setScheduledEndTime(addLaborToStart(scheduledStartTime, laborHours));
    }
  }, [showStartTimePicker, scheduledStartTime, scheduledEndTime, laborHours]);

  const conflicts = useMemo(
    () =>
      findScheduleConflicts(allJobs, {
        excludeJobId: jobId,
        date: scheduledDate,
        start: scheduledStartTime,
        end: scheduledEndTime,
        laborHours,
      }),
    [allJobs, jobId, scheduledDate, scheduledStartTime, scheduledEndTime, laborHours]
  );

  function conflictWindowLabel(j: Job): string {
    if (!j.scheduledStartTime) return "";
    const start = displayTime(j.scheduledStartTime);
    const end = j.scheduledEndTime ? displayTime(j.scheduledEndTime) : null;
    return end ? `, ${start}–${end}` : `, ${start}`;
  }
```

- [ ] **Step 5: Hint row + conflict warning row in the JSX**

Immediately after the closing `</View>` of `styles.timeRow` (line 558), add:

```tsx
          {laborHours > 0 ? (
            <Text style={styles.laborHint}>Est. labor: {formatLaborHint(laborHours)}</Text>
          ) : null}
          {conflicts.length > 0 ? (
            <View style={styles.conflictRow} accessibilityRole="alert">
              <Ionicons name="warning-outline" size={14} color={colors.warning} style={styles.conflictIcon} />
              <Text style={styles.conflictText}>
                Overlaps: {conflicts[0].title}
                {conflictWindowLabel(conflicts[0])}
                {conflicts.length > 1 ? `  +${conflicts.length - 1} more` : ""}
              </Text>
            </View>
          ) : null}
```

- [ ] **Step 6: Smarter picker props**

Replace the start-time sheet (lines 698–705) with:

```tsx
      <DateTimePickerSheet
        visible={showStartTimePicker}
        mode="time"
        title="Start Time"
        minuteInterval={5}
        value={timeObjFromStr(
          scheduledStartTime || defaultStartTime(scheduledDate, new Date())
        )}
        onChange={(date: Date) => setScheduledStartTime(toTimeStr(date))}
        onClose={() => setShowStartTimePicker(false)}
      />
```

Replace the end-time sheet (lines 706–713) with:

```tsx
      <DateTimePickerSheet
        visible={showEndTimePicker}
        mode="time"
        title="End Time"
        minuteInterval={5}
        value={timeObjFromStr(
          scheduledEndTime ||
            (scheduledStartTime ? defaultEndTime(scheduledStartTime, laborHours) : "")
        )}
        onChange={(date: Date) => setScheduledEndTime(toTimeStr(date))}
        onClose={() => setShowEndTimePicker(false)}
      />
```

(The date pickers at lines 690–697 and 714–721 are unchanged.)

- [ ] **Step 7: Styles**

In `createStyles`, after `pickerIcon` (line 816), add:

```tsx
  laborHint: {
    fontFamily: fonts.bodyRegular,
    fontSize: fontSize.sm,
    color: colors.textMuted,
    marginTop: 2,
    marginBottom: spacing.sm,
  },
  conflictRow: {
    flexDirection: "row",
    alignItems: "center",
    backgroundColor: colors.warningBg,
    borderRadius: radius.sm,
    paddingHorizontal: spacing.sm,
    paddingVertical: 6,
    marginBottom: spacing.sm,
  },
  conflictIcon: { marginRight: 6 },
  conflictText: {
    fontFamily: fonts.bodyMedium,
    fontSize: fontSize.sm,
    color: colors.warning,
    flex: 1,
  },
```

(`colors.warning` / `colors.warningBg` exist in both palettes — `utils/theme.ts` lines 18/21 and 58/61.)

- [ ] **Step 8: Run the full gate**

Run: `npm run typecheck` then `npm run lint` then `npm test`
Expected: 0 errors / 0 warnings / all suites pass. Watch specifically for
`react-hooks/exhaustive-deps` on the new effect — its dep array
`[showStartTimePicker, scheduledStartTime, scheduledEndTime, laborHours]` is
complete; do not silence the rule if it complains, fix the deps.

- [ ] **Step 9: Commit**

```bash
git add screens/AddJobScreen.tsx
git commit -m "feat: wire smart schedule pickers into AddJobScreen"
```

---

## Post-implementation

1. Full gate one final time; report counts (expect baseline + 26 new tests).
2. Owner phase report (Confidence / Missing Context / Recommended Next Step) — merge decision and device smoke (Expo Go) are the owner's.
3. Merge to `master` only on owner go-ahead (superpowers:finishing-a-development-branch).
4. Note for the report: this is JS-only — OTA-eligible once 1.1.0 is live (per current release state).

## Self-review notes (already applied)

- Spec §A–§C map to Tasks 1–3; spec's test list is covered by Task 1/2 test
  files (spec named the test file `.test.js`; repo convention moved to `.ts`
  for pure-util suites — `.ts` used, consistent with `invoiceNumber.test.ts`).
- `Ionicons` warning icon replaces the spec's literal `⚠` glyph example,
  matching the Blueprint emoji→Ionicons convention.
- Type names cross-checked: `ConflictQuery.laborHours` present everywhere;
  `MinuteInterval` union matches installed `index.d.ts` line 8 exactly.
