# Proactive Today-Screen Insights Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A deterministic "Insights" card on the Today screen (labor overrun, uninvoiced complete jobs, invoices due soon, open slot tomorrow, approved-but-unscheduled) that appears once the setup checklist is gone, deep-links per row, and hands the AI coach a prefilled prompt for labor overruns.

**Architecture:** Pure selector module `utils/todayInsights.ts` (injected clock, no I/O — mirrors `estimateFollowUps.ts`) + self-gating `components/InsightsCard.tsx` (mirrors `SetupChecklistCard.tsx`). Small pure additions to `scheduleSmarts.ts` (largest-gap), `setupChecklist.ts` (shared gate), `invoiceHelpers.ts` (optional clock). One additive nav param (`ChatHome.initialPrompt`).

**Tech Stack:** Expo 54 / RN 0.81 / React 19 / TypeScript strict / Jest (jest-expo). No new dependencies.

**Spec:** `docs/superpowers/specs/2026-08-04-today-insights-design.md` (owner-approved).

## Global Constraints

- Repo root: `C:\Users\Chadr\OneDrive\Documents\TraderPro App\tradeready\` — run all commands from there.
- Gate MUST be green before every commit: `npm run typecheck` (0 errors), `npm test` (all pass), `npm run lint` (0 warnings). Never commit on red (change-control rule 2).
- NO dependency changes, NO persisted data-shape changes, NO new AsyncStorage keys, NO `eslint-disable`/`@ts-ignore`.
- All date math LOCAL-frame (FA-039): `formatLocalDate`/`shiftDate`/`daysPastDue`; never `toISOString()` date math, never `new Date("YYYY-MM-DD")`.
- Money formatting mapping rule: actual amounts → `formatMoney` (cents); estimate headlines → `formatQuote` (whole dollars).
- Themed components use the `createStyles(colors, shadow)` factory + `useMemo` keyed `[colors, shadow]`; never import the static `colors` alias.
- Work window constants: `08:00`–`17:00`; minimum gap `120` minutes; overrun floor `0.25` h; due-soon window `2` days; card shows at most `3` rows.
- Commit style: imperative subject, `feat:`/`test:`/`docs:` prefix, end body with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Stage files EXPLICITLY by path (concurrent-session trap); never `git add -A`. Leave the untracked `.claude/skills/` directory alone.

---

### Task 1: `largestFreeGap` in utils/scheduleSmarts.ts

**Files:**
- Modify: `utils/scheduleSmarts.ts` (export `TERMINAL_STATUSES`, add `FreeGap` + `largestFreeGap` at end of file)
- Test: `__tests__/scheduleSmarts.test.ts` (append a `describe` block; the file already defines a `job(overrides)` factory at its top — reuse it)

**Interfaces:**
- Consumes: existing private `window()`, `toMinutes()`, `toTimeString()` in the same file; `TERMINAL_STATUSES` (currently a private `const` — make it `export const`, no other change).
- Produces: `export type FreeGap = { start: string; minutes: number }` and `export function largestFreeGap(jobs: Job[], date: string, dayStart?: string, dayEnd?: string): FreeGap | null` (defaults `"08:00"`/`"17:00"`). Returns `null` when the date has NO non-terminal job with a `scheduledStartTime` (the "empty day is silent" rule lives here). Task 5 consumes this.

- [ ] **Step 1: Write the failing tests** — append to `__tests__/scheduleSmarts.test.ts`:

```ts
import { largestFreeGap } from '../utils/scheduleSmarts'; // add to the existing import list

describe('largestFreeGap', () => {
  test('no scheduled jobs that day → null (empty day is silent by design)', () => {
    expect(largestFreeGap([job({ scheduledDate: '2026-08-04' })], '2026-08-05')).toBeNull();
    expect(largestFreeGap([], '2026-08-05')).toBeNull();
  });

  test('single morning job leaves the afternoon as the largest gap', () => {
    const jobs = [job({ scheduledDate: '2026-08-05', scheduledStartTime: '09:00', scheduledEndTime: '11:00' })];
    expect(largestFreeGap(jobs, '2026-08-05')).toEqual({ start: '11:00', minutes: 360 });
  });

  test('overlapping windows merge before gap computation', () => {
    const jobs = [
      job({ id: 'a', scheduledDate: '2026-08-05', scheduledStartTime: '08:00', scheduledEndTime: '10:00' }),
      job({ id: 'b', scheduledDate: '2026-08-05', scheduledStartTime: '09:00', scheduledEndTime: '12:00' }),
    ];
    expect(largestFreeGap(jobs, '2026-08-05')).toEqual({ start: '12:00', minutes: 300 });
  });

  test('windows clamp to the work day; a fully-booked day has no gap', () => {
    const jobs = [job({ scheduledDate: '2026-08-05', scheduledStartTime: '07:00', scheduledEndTime: '18:00' })];
    expect(largestFreeGap(jobs, '2026-08-05')).toBeNull();
  });

  test('terminal-status jobs do not count as scheduled work', () => {
    const jobs = [job({ scheduledDate: '2026-08-05', scheduledStartTime: '09:00', scheduledEndTime: '11:00', status: 'paid' })];
    expect(largestFreeGap(jobs, '2026-08-05')).toBeNull(); // no live job → null
  });

  test('missing end time blocks max(labor, 1h), matching findScheduleConflicts', () => {
    const jobs = [job({ scheduledDate: '2026-08-05', scheduledStartTime: '09:00', scheduledEndTime: null, laborHours: 3 })];
    // busy 09:00–12:00 → largest gap 12:00–17:00 = 300
    expect(largestFreeGap(jobs, '2026-08-05')).toEqual({ start: '12:00', minutes: 300 });
  });

  test('exact-tie gaps: the earlier gap wins (strict >)', () => {
    const jobs = [job({ scheduledDate: '2026-08-05', scheduledStartTime: '11:15', scheduledEndTime: '13:45' })];
    // gaps 08:00–11:15 (195) and 13:45–17:00 (195) → earlier one reported
    expect(largestFreeGap(jobs, '2026-08-05')).toEqual({ start: '08:00', minutes: 195 });
  });
});
```

- [ ] **Step 2: Run to verify failure** — `npx jest scheduleSmarts` → FAIL: `largestFreeGap` is not exported.

- [ ] **Step 3: Implement** — in `utils/scheduleSmarts.ts`: change `const TERMINAL_STATUSES` to `export const TERMINAL_STATUSES` (line ~15), then append at end of file:

```ts
export type FreeGap = { start: string; minutes: number };

/**
 * Largest free gap inside [dayStart, dayEnd) on `date`, from the same busy
 * windows findScheduleConflicts uses (missing end → max(labor, 1h)). Returns
 * null when the date has no live scheduled job — an empty day is not an
 * "open slot" (the Today empty-schedule state owns that message) — or when
 * every minute is booked. Ties go to the earlier gap (strict >).
 */
export function largestFreeGap(
  jobs: Job[],
  date: string,
  dayStart = "08:00",
  dayEnd = "17:00"
): FreeGap | null {
  const dayJobs = jobs.filter(
    (j) =>
      j.scheduledDate === date &&
      !!j.scheduledStartTime &&
      !TERMINAL_STATUSES.has(j.status)
  );
  if (dayJobs.length === 0) return null;

  const startMin = toMinutes(dayStart);
  const endMin = toMinutes(dayEnd);

  const busy = dayJobs
    .map((j) => window(j.scheduledStartTime as string, j.scheduledEndTime, j.laborHours ?? 0))
    .map(([s, e]): [number, number] => [Math.max(s, startMin), Math.min(e, endMin)])
    .filter(([s, e]) => s < e)
    .sort((a, b) => a[0] - b[0]);

  const merged: [number, number][] = [];
  for (const [s, e] of busy) {
    const last = merged[merged.length - 1];
    if (last && s <= last[1]) last[1] = Math.max(last[1], e);
    else merged.push([s, e]);
  }

  let best: FreeGap | null = null;
  let cursor = startMin;
  for (const [s, e] of merged) {
    if (s - cursor > (best?.minutes ?? 0)) best = { start: toTimeString(cursor), minutes: s - cursor };
    cursor = Math.max(cursor, e);
  }
  if (endMin - cursor > (best?.minutes ?? 0)) best = { start: toTimeString(cursor), minutes: endMin - cursor };
  return best;
}
```

- [ ] **Step 4: Run to verify pass** — `npx jest scheduleSmarts` → all pass (existing suites too).

- [ ] **Step 5: Gate + commit**

```bash
npm run typecheck
npm test
npm run lint
git add utils/scheduleSmarts.ts __tests__/scheduleSmarts.test.ts
git commit -m "feat: add largestFreeGap schedule helper for Today insights

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: optional clock on `daysPastDue`

**Files:**
- Modify: `utils/invoiceHelpers.ts:26-38` (`daysPastDue`)
- Test: `__tests__/invoiceHelpers.test.js` (append; this file is plain JS — no type annotations)

**Interfaces:**
- Produces: `daysPastDue(dueDate: string, now: Date = new Date()): number` — purely additive; every existing zero-arg call site is untouched. MUST clone `now` before `setHours` (never mutate the caller's Date). Task 4 consumes this.

- [ ] **Step 1: Write the failing test** — append to `__tests__/invoiceHelpers.test.js`:

```js
describe("daysPastDue with an injected clock", () => {
  test("computes against the given now, not the wall clock", () => {
    const now = new Date(2026, 7, 4, 10, 0); // Aug 4 2026, 10:00 local
    expect(daysPastDue("2026-08-04", now)).toBe(0);
    expect(daysPastDue("2026-08-05", now)).toBe(-1);
    expect(daysPastDue("2026-08-01", now)).toBe(3);
  });

  test("does not mutate the caller's Date", () => {
    const now = new Date(2026, 7, 4, 10, 30);
    daysPastDue("2026-08-04", now);
    expect(now.getHours()).toBe(10);
    expect(now.getMinutes()).toBe(30);
  });
});
```

- [ ] **Step 2: Run to verify failure** — `npx jest invoiceHelpers` → FAIL (second argument ignored → wrong day counts against the real clock).

- [ ] **Step 3: Implement** — in `utils/invoiceHelpers.ts`, change the signature and the `today` line only (keep the existing comment block):

```ts
export function daysPastDue(dueDate: string, now: Date = new Date()): number {
  // ...existing comment unchanged...
  const due = parseLocalDate(dueDate);
  due.setHours(0, 0, 0, 0);
  const today = new Date(now.getTime());
  today.setHours(0, 0, 0, 0);
  return Math.round((today.getTime() - due.getTime()) / (1000 * 60 * 60 * 24));
}
```

- [ ] **Step 4: Run to verify pass** — `npx jest invoiceHelpers` → all pass.

- [ ] **Step 5: Gate + commit**

```bash
npm run typecheck
npm test
npm run lint
git add utils/invoiceHelpers.ts __tests__/invoiceHelpers.test.js
git commit -m "feat: accept an injected clock in daysPastDue

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: `isSetupComplete` in utils/setupChecklist.ts

**Files:**
- Modify: `utils/setupChecklist.ts` (add one export after `deriveSetupTasks`)
- Test: `__tests__/setupChecklist.test.js` (append; plain JS)

**Interfaces:**
- Consumes: existing `deriveSetupTasks(settings, state, notifGranted)`.
- Produces: `isSetupComplete(settings: Settings, state: SetupChecklistState, notifGranted: boolean): boolean` — the single shared definition of "the checklist box is off the screen": dismissed OR every derived task done. Task 7 consumes this. (SetupChecklistCard itself is NOT refactored — out of scope per spec.)

- [ ] **Step 1: Write the failing test** — append to `__tests__/setupChecklist.test.js` (reuse the file's existing settings fixture if one exists; otherwise this minimal one):

```js
const doneSettings = {
  phone: "555-0100",
  address: "1 Main St",
  logoPhoto: "file:///logo.png",
  provider: "stripe",
};

describe("isSetupComplete", () => {
  test("dismissed → complete regardless of task state", () => {
    expect(isSetupComplete(doneSettings, { dismissed: true }, false)).toBe(true);
  });

  test("all five tasks done → complete", () => {
    const state = { done: { rate: true, stripe: true } };
    expect(isSetupComplete(doneSettings, state, true)).toBe(true);
  });

  test("any open task → not complete", () => {
    const state = { done: { rate: true, stripe: true } };
    expect(isSetupComplete(doneSettings, state, false)).toBe(false); // notifications open
    expect(isSetupComplete({ ...doneSettings, logoPhoto: undefined }, state, true)).toBe(false);
  });
});
```

- [ ] **Step 2: Run to verify failure** — `npx jest setupChecklist` → FAIL: `isSetupComplete` is not a function.

- [ ] **Step 3: Implement** — in `utils/setupChecklist.ts`, after `deriveSetupTasks`:

```ts
/**
 * The single shared definition of "the Finish-setting-up card is off the
 * screen": the user dismissed it, or every derived task is done. The Today
 * InsightsCard gates on this so it can never disagree with
 * SetupChecklistCard's own hide condition.
 */
export function isSetupComplete(
  settings: Settings,
  state: SetupChecklistState,
  notifGranted: boolean
): boolean {
  if (state.dismissed) return true;
  return deriveSetupTasks(settings, state, notifGranted).every((t) => t.done);
}
```

- [ ] **Step 4: Run to verify pass** — `npx jest setupChecklist` → all pass.

- [ ] **Step 5: Gate + commit**

```bash
npm run typecheck
npm test
npm run lint
git add utils/setupChecklist.ts __tests__/setupChecklist.test.js
git commit -m "feat: add isSetupComplete shared checklist gate

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: utils/todayInsights.ts — types + rules 1–3

**Files:**
- Create: `utils/todayInsights.ts`
- Test: `__tests__/todayInsights.test.ts` (new, TypeScript)

**Interfaces:**
- Consumes: `computeTimeTracking`, `formatElapsed` (utils/timeTracking.ts); `formatLaborHint` (utils/scheduleSmarts.ts); `isArchived` (utils/archive.ts); `isFullyPaid`, `balanceDue` (utils/invoicePayments.ts); `daysPastDue(due, now)` (Task 2); `formatMoney`, `formatQuote` (utils/format.ts).
- Produces (Tasks 5–7 rely on these exact names):
  - `export type InsightKind = "labor_overrun" | "uninvoiced_complete" | "due_soon" | "open_slot" | "unscheduled_approved"`
  - `export type InsightTarget = { type: "job"; jobId: string } | { type: "createInvoice"; jobId: string } | { type: "invoice"; invoiceId: string } | { type: "invoices" } | { type: "jobs" } | { type: "schedule"; jobId: string } | { type: "selectDate"; date: string }`
  - `export type TodayInsight = { kind: InsightKind; title: string; detail?: string; target: InsightTarget; coachPrompt?: string }`
  - `export function selectTodayInsights(jobs: Job[], invoices: Invoice[], now: Date): TodayInsight[]`
  - `export const WORK_DAY_START = "08:00"`, `export const WORK_DAY_END = "17:00"`

- [ ] **Step 1: Write the failing tests** — create `__tests__/todayInsights.test.ts`:

```ts
// __tests__/todayInsights.test.ts
// Pins the deterministic Today-insight rules from the 2026-08-04 spec
// (docs/superpowers/specs/2026-08-04-today-insights-design.md). Fixed clock
// throughout: Tue Aug 4 2026, 10:00 local → "tomorrow" is 2026-08-05.

import { selectTodayInsights } from '../utils/todayInsights';
import type { Job, Invoice } from '../types/models';

const NOW = new Date(2026, 7, 4, 10, 0);

function job(overrides: Partial<Job>): Job {
  return {
    id: 'j1',
    customerId: 'c1',
    customerName: 'Dana',
    title: 'Faucet repair',
    description: '',
    status: 'in_progress',
    scheduledDate: null,
    scheduledStartTime: null,
    scheduledEndTime: null,
    address: '',
    estimateTotal: 1200,
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

function invoice(overrides: Partial<Invoice>): Invoice {
  return {
    id: 'i1',
    customer: 'Dana',
    number: 'INV-0042',
    amount: 850,
    due: '2026-08-05',
    email: '',
    phone: '',
    desc: '',
    paid: false,
    ...overrides,
  };
}

/** An ended clock session of exactly `hours` on Aug 4. */
function session(hours: number) {
  const startMs = new Date(2026, 7, 4, 6, 0).getTime();
  return { start: new Date(startMs).toISOString(), end: new Date(startMs + hours * 3600000).toISOString() };
}

describe('labor_overrun', () => {
  test('fires at 15 minutes over, with elapsed and estimate in the title', () => {
    const jobs = [job({ timeSessions: [session(2.25)] })];
    const [insight] = selectTodayInsights(jobs, [], NOW);
    expect(insight.kind).toBe('labor_overrun');
    expect(insight.title).toBe("'Faucet repair' is 15m over its 2h labor estimate");
    expect(insight.target).toEqual({ type: 'job', jobId: 'j1' });
  });

  test('quarter-hour floor: 14 minutes over is silent', () => {
    const jobs = [job({ timeSessions: [session(2 + 14 / 60)] })];
    expect(selectTodayInsights(jobs, [], NOW)).toHaveLength(0);
  });

  test('coachPrompt carries tracked time, estimate, rate and total', () => {
    const [insight] = selectTodayInsights([job({ timeSessions: [session(3.5)] })], [], NOW);
    expect(insight.coachPrompt).toContain('3h 30m');
    expect(insight.coachPrompt).toContain('2h labor estimate');
    expect(insight.coachPrompt).toContain('$85.00/hr');
    expect(insight.coachPrompt).toContain('$1,200');
  });

  test('completed, archived, and zero-estimate jobs are excluded', () => {
    const sessions = [session(5)];
    expect(selectTodayInsights([job({ status: 'complete', invoiceId: 'i9', timeSessions: sessions })], [], NOW)).toHaveLength(0);
    expect(selectTodayInsights([job({ archivedAt: '2026-08-03', timeSessions: sessions })], [], NOW)).toHaveLength(0);
    expect(selectTodayInsights([job({ laborHours: 0, timeSessions: sessions })], [], NOW)).toHaveLength(0);
  });
});

describe('uninvoiced_complete', () => {
  test('single job: create-invoice target and a formatQuote detail', () => {
    const jobs = [job({ status: 'complete', timeSessions: undefined })];
    const [insight] = selectTodayInsights(jobs, [], NOW);
    expect(insight.kind).toBe('uninvoiced_complete');
    expect(insight.title).toBe("'Faucet repair' is complete but not invoiced");
    expect(insight.detail).toBe('$1,200 to bill');
    expect(insight.target).toEqual({ type: 'createInvoice', jobId: 'j1' });
  });

  test('several jobs aggregate to one row targeting the Jobs tab', () => {
    const jobs = [
      job({ id: 'a', status: 'complete' }),
      job({ id: 'b', status: 'complete', title: 'Deck repair' }),
    ];
    const [insight] = selectTodayInsights(jobs, [], NOW);
    expect(insight.title).toBe("2 completed jobs haven't been invoiced");
    expect(insight.target).toEqual({ type: 'jobs' });
  });

  test('invoiced or archived complete jobs are excluded', () => {
    expect(selectTodayInsights([job({ status: 'complete', invoiceId: 'i1' })], [], NOW)).toHaveLength(0);
    expect(selectTodayInsights([job({ status: 'complete', archivedAt: '2026-08-01' })], [], NOW)).toHaveLength(0);
  });
});

describe('due_soon', () => {
  test.each([
    ['2026-08-04', 'today'],
    ['2026-08-05', 'tomorrow'],
    ['2026-08-06', 'in 2 days'],
  ])('due %s reads "due %s"', (due, label) => {
    const [insight] = selectTodayInsights([], [invoice({ due })], NOW);
    expect(insight.kind).toBe('due_soon');
    expect(insight.title).toBe(`Invoice INV-0042 ($850.00) is due ${label}`);
    expect(insight.target).toEqual({ type: 'invoice', invoiceId: 'i1' });
  });

  test('outside the window: 3 days out and already-overdue are both silent', () => {
    expect(selectTodayInsights([], [invoice({ due: '2026-08-07' })], NOW)).toHaveLength(0);
    expect(selectTodayInsights([], [invoice({ due: '2026-08-03' })], NOW)).toHaveLength(0); // Overdue section owns it
  });

  test('fully paid invoices are silent; aggregates sum balanceDue', () => {
    expect(selectTodayInsights([], [invoice({ paid: true })], NOW)).toHaveLength(0);
    const invs = [
      invoice({ id: 'a', amount: 850 }),
      invoice({ id: 'b', number: 'INV-0043', amount: 600, due: '2026-08-06',
                payments: [{ id: 'p1', amount: 100, date: '2026-08-01', method: 'cash' }] }),
    ];
    const [insight] = selectTodayInsights([], invs, NOW);
    expect(insight.title).toBe('$1,350.00 across 2 invoices is due within 2 days');
    expect(insight.target).toEqual({ type: 'invoices' });
  });
});
```

- [ ] **Step 2: Run to verify failure** — `npx jest todayInsights` → FAIL: cannot find module `../utils/todayInsights`.

- [ ] **Step 3: Implement** — create `utils/todayInsights.ts`:

```ts
// utils/todayInsights.ts
// Deterministic "proactive insights" rules for the Today screen (2026-08-04
// spec: docs/superpowers/specs/2026-08-04-today-insights-design.md). Pure —
// no I/O, no Expo/RN imports, injected clock — mirroring estimateFollowUps.ts.
// The card (components/InsightsCard.tsx) renders the first 3 of whatever this
// returns, so PRIORITY IS THE ORDER THE RULES RUN in selectTodayInsights.

import type { Job, Invoice } from "../types/models";
import { computeTimeTracking, formatElapsed } from "./timeTracking";
import { formatLaborHint } from "./scheduleSmarts";
import { isArchived } from "./archive";
import { isFullyPaid, balanceDue } from "./invoicePayments";
import { daysPastDue } from "./invoiceHelpers";
import { formatMoney, formatQuote } from "./format";

export type InsightKind =
  | "labor_overrun"
  | "uninvoiced_complete"
  | "due_soon"
  | "open_slot"
  | "unscheduled_approved";

export type InsightTarget =
  | { type: "job"; jobId: string }
  | { type: "createInvoice"; jobId: string }
  | { type: "invoice"; invoiceId: string }
  | { type: "invoices" }
  | { type: "jobs" }
  | { type: "schedule"; jobId: string }
  | { type: "selectDate"; date: string };

export type TodayInsight = {
  kind: InsightKind;
  title: string;
  detail?: string;
  target: InsightTarget;
  /** labor_overrun only: prefills the AI coach input (never auto-sent). */
  coachPrompt?: string;
};

/** Quarter-hour floor — sub-15-minute overruns are noise to a trade. */
const OVERRUN_MIN_HOURS = 0.25;
/** Fixed work window for the open-slot rule (no setting in v1, per spec). */
export const WORK_DAY_START = "08:00";
export const WORK_DAY_END = "17:00";
/** How many days ahead (inclusive) "due soon" looks; day +1 belongs to the
 * Overdue section (due-today is NOT overdue — existing semantics). */
const DUE_SOON_DAYS = 2;

/**
 * Statuses where "running over the labor estimate" is a live, present-tense
 * problem. A clock-in on `approved` does not auto-advance (applyClockIn only
 * advances from `scheduled`), so `approved` can carry sessions too.
 * Completed/invoiced jobs are excluded — after completion the money
 * conversation belongs to invoicing, not the timer.
 */
const OVERRUN_STATUSES: ReadonlySet<Job["status"]> = new Set([
  "approved",
  "scheduled",
  "in_progress",
]);

function selectLaborOverruns(jobs: Job[], now: Date): TodayInsight[] {
  const out: TodayInsight[] = [];
  for (const job of jobs) {
    if (!OVERRUN_STATUSES.has(job.status) || isArchived(job)) continue;
    if (!(job.laborHours > 0) || !job.timeSessions?.length) continue;
    const t = computeTimeTracking(job.timeSessions, job.laborHours, now.getTime());
    if (t.overUnder === null || t.overUnder < OVERRUN_MIN_HOURS) continue;
    out.push({
      kind: "labor_overrun",
      title: `'${job.title}' is ${formatElapsed(t.overUnder * 3600000)} over its ${formatLaborHint(job.laborHours)} labor estimate`,
      target: { type: "job", jobId: job.id },
      coachPrompt:
        `I'm working on '${job.title}' and I've logged ${formatElapsed(t.liveMs)} ` +
        `against a ${formatLaborHint(job.laborHours)} labor estimate at ` +
        `${formatMoney(job.laborRate)}/hr (estimate total ${formatQuote(job.estimateTotal)}). ` +
        `How should I handle the overrun — talk to the customer now, absorb it, or adjust the bill?`,
    });
  }
  return out;
}

function selectUninvoicedComplete(jobs: Job[]): TodayInsight[] {
  const done = jobs.filter((j) => j.status === "complete" && !j.invoiceId && !isArchived(j));
  if (done.length === 0) return [];
  if (done.length === 1) {
    const job = done[0];
    return [{
      kind: "uninvoiced_complete",
      title: `'${job.title}' is complete but not invoiced`,
      detail: job.estimateTotal > 0 ? `${formatQuote(job.estimateTotal)} to bill` : undefined,
      target: { type: "createInvoice", jobId: job.id },
    }];
  }
  return [{
    kind: "uninvoiced_complete",
    title: `${done.length} completed jobs haven't been invoiced`,
    target: { type: "jobs" },
  }];
}

function dueLabel(days: number): string {
  if (days === 0) return "today";
  if (days === -1) return "tomorrow";
  return `in ${-days} days`;
}

function selectDueSoon(invoices: Invoice[], now: Date): TodayInsight[] {
  const soon = invoices
    .map((inv) => ({ inv, days: daysPastDue(inv.due, now) }))
    .filter(({ inv, days }) => !isFullyPaid(inv) && days <= 0 && days >= -DUE_SOON_DAYS);
  if (soon.length === 0) return [];
  if (soon.length === 1) {
    const { inv, days } = soon[0];
    return [{
      kind: "due_soon",
      title: `Invoice ${inv.number} (${formatMoney(balanceDue(inv))}) is due ${dueLabel(days)}`,
      target: { type: "invoice", invoiceId: inv.id },
    }];
  }
  const total = soon.reduce((s, { inv }) => s + balanceDue(inv), 0);
  return [{
    kind: "due_soon",
    title: `${formatMoney(total)} across ${soon.length} invoices is due within ${DUE_SOON_DAYS} days`,
    target: { type: "invoices" },
  }];
}

export function selectTodayInsights(jobs: Job[], invoices: Invoice[], now: Date): TodayInsight[] {
  const safeJobs = jobs || [];
  const safeInvoices = invoices || [];
  return [
    ...selectLaborOverruns(safeJobs, now),
    ...selectUninvoicedComplete(safeJobs),
    ...selectDueSoon(safeInvoices, now),
  ];
}
```

- [ ] **Step 4: Run to verify pass** — `npx jest todayInsights` → all pass.

- [ ] **Step 5: Gate + commit**

```bash
npm run typecheck
npm test
npm run lint
git add utils/todayInsights.ts __tests__/todayInsights.test.ts
git commit -m "feat: add Today insight rules — labor overrun, uninvoiced complete, due soon

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: todayInsights.ts — schedule rules + priority + dedupe

**Files:**
- Modify: `utils/todayInsights.ts` (add `selectScheduleInsights`, extend orchestrator)
- Test: `__tests__/todayInsights.test.ts` (append)

**Interfaces:**
- Consumes: `largestFreeGap`, `FreeGap` (Task 1); `formatLocalDate` (utils/recurrence.ts); `shiftDate` (utils/dateHelpers.ts); everything from Task 4.
- Produces: `selectTodayInsights` now returns all five kinds in priority order `labor_overrun → uninvoiced_complete → due_soon → open_slot → unscheduled_approved`. `MIN_GAP_MINUTES = 120` (module-private). Rule-4/5 dedupe: the job named by open_slot's fit never counts toward unscheduled_approved.

- [ ] **Step 1: Write the failing tests** — append to `__tests__/todayInsights.test.ts`:

```ts
describe('open_slot', () => {
  const tomorrowJob = job({
    id: 'sched', status: 'scheduled', scheduledDate: '2026-08-05',
    scheduledStartTime: '09:00', scheduledEndTime: '11:00',
  });

  test('fires with the largest gap when tomorrow has a scheduled job', () => {
    const [insight] = selectTodayInsights([tomorrowJob], [], NOW);
    expect(insight.kind).toBe('open_slot');
    expect(insight.title).toBe('Tomorrow has a 6h open slot'); // 11:00–17:00
    expect(insight.target).toEqual({ type: 'selectDate', date: '2026-08-05' });
  });

  test('names the largest fitting approved unscheduled job and targets its schedule editor', () => {
    const jobs = [
      tomorrowJob,
      job({ id: 'fitS', status: 'approved', title: 'Small fix', laborHours: 1 }),
      job({ id: 'fitL', status: 'approved', title: 'Fence gate', laborHours: 4 }),
      job({ id: 'huge', status: 'approved', title: 'Full remodel', laborHours: 9 }),
    ];
    const insights = selectTodayInsights(jobs, [], NOW);
    expect(insights[0].title).toBe("Tomorrow has a 6h open slot — 'Fence gate' (4h) would fit");
    expect(insights[0].target).toEqual({ type: 'schedule', jobId: 'fitL' });
  });

  test('empty tomorrow and sub-2h gaps are silent', () => {
    expect(selectTodayInsights([job({ status: 'approved' })], [], NOW)
      .filter(i => i.kind === 'open_slot')).toHaveLength(0);
    const packed = [
      job({ id: 'a', status: 'scheduled', scheduledDate: '2026-08-05', scheduledStartTime: '08:00', scheduledEndTime: '12:01' }),
      job({ id: 'b', status: 'scheduled', scheduledDate: '2026-08-05', scheduledStartTime: '14:00', scheduledEndTime: '17:00' }),
    ];
    expect(selectTodayInsights(packed, [], NOW).filter(i => i.kind === 'open_slot')).toHaveLength(0); // 119 min
  });

  test('exactly 120 minutes fires', () => {
    const jobs = [
      job({ id: 'a', status: 'scheduled', scheduledDate: '2026-08-05', scheduledStartTime: '08:00', scheduledEndTime: '12:00' }),
      job({ id: 'b', status: 'scheduled', scheduledDate: '2026-08-05', scheduledStartTime: '14:00', scheduledEndTime: '17:00' }),
    ];
    const [insight] = selectTodayInsights(jobs, [], NOW);
    expect(insight.title).toBe('Tomorrow has a 2h open slot');
  });
});

describe('unscheduled_approved', () => {
  test('single job targets its schedule editor; several aggregate to Jobs', () => {
    const [single] = selectTodayInsights([job({ id: 'u1', status: 'approved', title: 'Fence gate' })], [], NOW);
    expect(single.kind).toBe('unscheduled_approved');
    expect(single.title).toBe("'Fence gate' is approved but not scheduled");
    expect(single.target).toEqual({ type: 'schedule', jobId: 'u1' });

    const [multi] = selectTodayInsights([
      job({ id: 'u1', status: 'approved' }),
      job({ id: 'u2', status: 'approved' }),
    ], [], NOW);
    expect(multi.title).toBe("2 approved jobs aren't on the schedule yet");
    expect(multi.target).toEqual({ type: 'jobs' });
  });

  test('the job consumed by open_slot never double-counts', () => {
    const jobs = [
      job({ id: 'sched', status: 'scheduled', scheduledDate: '2026-08-05', scheduledStartTime: '09:00', scheduledEndTime: '11:00' }),
      job({ id: 'fit', status: 'approved', title: 'Fence gate', laborHours: 4 }),
      job({ id: 'left', status: 'approved', title: 'Gutter clean', laborHours: 9 }),
    ];
    const insights = selectTodayInsights(jobs, [], NOW);
    const kinds = insights.map(i => i.kind);
    expect(kinds).toEqual(['open_slot', 'unscheduled_approved']);
    expect(insights[1].title).toBe("'Gutter clean' is approved but not scheduled");
  });
});

describe('priority order', () => {
  test('all five kinds arrive in spec order', () => {
    const jobs = [
      job({ id: 'over', timeSessions: [session(5)] }),
      job({ id: 'done', status: 'complete' }),
      job({ id: 'sched', status: 'scheduled', scheduledDate: '2026-08-05', scheduledStartTime: '09:00', scheduledEndTime: '11:00' }),
      job({ id: 'fit', status: 'approved', laborHours: 2 }),
      job({ id: 'left', status: 'approved', laborHours: 9 }),
    ];
    const kinds = selectTodayInsights(jobs, [invoice({})], NOW).map(i => i.kind);
    expect(kinds).toEqual(['labor_overrun', 'uninvoiced_complete', 'due_soon', 'open_slot', 'unscheduled_approved']);
  });
});
```

- [ ] **Step 2: Run to verify failure** — `npx jest todayInsights` → new describes FAIL (no open_slot/unscheduled_approved produced).

- [ ] **Step 3: Implement** — in `utils/todayInsights.ts`, add imports, the constant, the selector, and extend the orchestrator:

```ts
// add to the import block:
import { formatLaborHint, largestFreeGap } from "./scheduleSmarts"; // largestFreeGap joins the existing import
import { formatLocalDate } from "./recurrence";
import { shiftDate } from "./dateHelpers";

/** Minimum free gap worth surfacing, in minutes. */
const MIN_GAP_MINUTES = 120;

function selectScheduleInsights(jobs: Job[], now: Date): TodayInsight[] {
  const out: TodayInsight[] = [];
  const tomorrow = shiftDate(formatLocalDate(now), 1); // local-frame (FA-039)

  const unscheduled = jobs.filter(
    (j) => j.status === "approved" && !j.scheduledDate && !isArchived(j)
  );

  let fittedJobId: string | null = null;
  const gap = largestFreeGap(jobs, tomorrow, WORK_DAY_START, WORK_DAY_END);
  if (gap && gap.minutes >= MIN_GAP_MINUTES) {
    const gapLabel = formatLaborHint(gap.minutes / 60);
    // Best fill: the largest approved unscheduled job that still fits.
    const fit = unscheduled
      .filter((j) => j.laborHours > 0 && j.laborHours * 60 <= gap.minutes)
      .sort((a, b) => b.laborHours - a.laborHours)[0];
    if (fit) {
      fittedJobId = fit.id;
      out.push({
        kind: "open_slot",
        title: `Tomorrow has a ${gapLabel} open slot — '${fit.title}' (${formatLaborHint(fit.laborHours)}) would fit`,
        target: { type: "schedule", jobId: fit.id },
      });
    } else {
      out.push({
        kind: "open_slot",
        title: `Tomorrow has a ${gapLabel} open slot`,
        target: { type: "selectDate", date: tomorrow },
      });
    }
  }

  const remaining = unscheduled.filter((j) => j.id !== fittedJobId);
  if (remaining.length === 1) {
    out.push({
      kind: "unscheduled_approved",
      title: `'${remaining[0].title}' is approved but not scheduled`,
      target: { type: "schedule", jobId: remaining[0].id },
    });
  } else if (remaining.length > 1) {
    out.push({
      kind: "unscheduled_approved",
      title: `${remaining.length} approved jobs aren't on the schedule yet`,
      target: { type: "jobs" },
    });
  }
  return out;
}
```

and the orchestrator's return becomes:

```ts
  return [
    ...selectLaborOverruns(safeJobs, now),
    ...selectUninvoicedComplete(safeJobs),
    ...selectDueSoon(safeInvoices, now),
    ...selectScheduleInsights(safeJobs, now),
  ];
```

- [ ] **Step 4: Run to verify pass** — `npx jest todayInsights` → all pass.

- [ ] **Step 5: Gate + commit**

```bash
npm run typecheck
npm test
npm run lint
git add utils/todayInsights.ts __tests__/todayInsights.test.ts
git commit -m "feat: add open-slot and unscheduled-approved insight rules with priority order

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: ChatHome `initialPrompt` param

**Files:**
- Modify: `types/navigation.ts:83-85` (`ChatStackParamList`)
- Modify: `screens/ChatScreen.tsx:121` (component signature) and after the `useFocusEffect` block (~line 148)

**Interfaces:**
- Produces: `ChatHome: { initialPrompt?: string } | undefined` — Task 7's `handleAskCoach` navigates with it. ChatScreen fills the input ONCE and clears the param; never auto-sends.
- No unit test: this is screen wiring with no pure logic; the gate (tsc + lint) is the check. Jest has no Chat screen suite to extend (verified 2026-08-04).

- [ ] **Step 1: Update the param list** — in `types/navigation.ts`:

```ts
export type ChatStackParamList = {
  ChatHome: { initialPrompt?: string } | undefined;
};
```

- [ ] **Step 2: Consume it in ChatScreen** — in `screens/ChatScreen.tsx`:
  - Add `useEffect` to the React import if not already there.
  - Change the signature: `export default function ChatScreen({ navigation, route }: ChatStackScreenProps<'ChatHome'>)`.
  - After the existing `useFocusEffect` block, add:

```tsx
  // A Today-insight "Ask coach" tap arrives as initialPrompt: fill the input
  // once and clear the param so it can never re-fire. NEVER auto-send — the
  // user reviews and edits before anything leaves the device.
  const initialPrompt = route.params?.initialPrompt;
  useEffect(() => {
    if (initialPrompt) {
      setInput(initialPrompt);
      navigation.setParams({ initialPrompt: undefined });
    }
  }, [initialPrompt, navigation]);
```

- [ ] **Step 3: Gate + commit**

```bash
npm run typecheck
npm test
npm run lint
git add types/navigation.ts screens/ChatScreen.tsx
git commit -m "feat: let ChatHome accept a prefilled prompt via nav param

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: InsightsCard component

**Files:**
- Create: `components/InsightsCard.tsx`

**Interfaces:**
- Consumes: `selectTodayInsights`, `InsightKind`, `InsightTarget`, `TodayInsight` (Tasks 4–5); `isSetupComplete`, `loadSetupChecklistState`, `SetupChecklistState` (Task 3); `useTheme`; `track` (utils/analytics.ts).
- Produces: `export function InsightsCard(props: { jobs: Job[]; invoices: Invoice[]; settings: Settings | null; onNavigate: (target: InsightTarget) => void; onAskCoach: (prompt: string) => void })` — Task 8 renders it. Renders `null` until checklist state loads, when setup is incomplete, or when no insight fires.
- No RNTL test in v1 (spec: selector units are the load-bearing coverage); gate is the check.

- [ ] **Step 1: Create the component** — `components/InsightsCard.tsx`:

```tsx
// components/InsightsCard.tsx
// Proactive deterministic insights on Today (2026-08-04 spec) — takes the
// setup checklist's visual slot once setup is complete. The rules live in
// utils/todayInsights.ts (pure, tested); this card is presentation + gating:
// nothing renders until the "Finish setting up" card is gone (dismissed or
// every task done — the shared isSetupComplete definition) and at least one
// insight fired. No dismiss button by design: rows disappear on their own as
// the underlying condition resolves.

import React, { useState, useCallback, useMemo, useRef, useEffect } from "react";
import { View, Text, TouchableOpacity, StyleSheet } from "react-native";
import { useFocusEffect } from "@react-navigation/native";
import { Ionicons } from "@expo/vector-icons";
import * as Notifications from "expo-notifications";
import { spacing, radius, fontSize, fonts, type ColorScheme, type ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import {
  isSetupComplete,
  loadSetupChecklistState,
  type SetupChecklistState,
} from "../utils/setupChecklist";
import {
  selectTodayInsights,
  type InsightKind,
  type InsightTarget,
  type TodayInsight,
} from "../utils/todayInsights";
import type { Job, Invoice, Settings } from "../types/models";
import { track } from "../utils/analytics";

const VISIBLE_LIMIT = 3;

const KIND_ICONS: Record<InsightKind, keyof typeof Ionicons.glyphMap> = {
  labor_overrun: "timer-outline",
  uninvoiced_complete: "receipt-outline",
  due_soon: "alarm-outline",
  open_slot: "today-outline",
  unscheduled_approved: "calendar-outline",
};

interface InsightsCardProps {
  jobs: Job[];
  invoices: Invoice[];
  settings: Settings | null;
  onNavigate: (target: InsightTarget) => void;
  onAskCoach: (prompt: string) => void;
}

export function InsightsCard({ jobs, invoices, settings, onNavigate, onAskCoach }: InsightsCardProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const [state, setState] = useState<SetupChecklistState | null>(null);
  const [notifGranted, setNotifGranted] = useState(false);

  useFocusEffect(
    useCallback(() => {
      let active = true;
      loadSetupChecklistState().then(s => { if (active) setState(s); });
      Notifications.getPermissionsAsync()
        .then(({ status }) => { if (active) setNotifGranted(status === "granted"); })
        .catch(() => {});
      return () => { active = false; };
    }, [])
  );

  // Static per data change — no ticking timer; the number refreshes on focus.
  const insights = useMemo(
    () => selectTodayInsights(jobs, invoices, new Date()).slice(0, VISIBLE_LIMIT),
    [jobs, invoices]
  );

  const visible =
    !!settings && state !== null && isSetupComplete(settings, state, notifGranted) && insights.length > 0;

  // insight_shown once per distinct visible-kinds set, not per render.
  const shownKey = visible ? insights.map(i => i.kind).join(",") : "";
  const lastShownKey = useRef("");
  useEffect(() => {
    if (shownKey && shownKey !== lastShownKey.current) {
      lastShownKey.current = shownKey;
      track("insight_shown", { kinds: insights.map(i => i.kind) });
    }
  }, [shownKey, insights]);

  if (!visible) return null;

  function handleTap(insight: TodayInsight) {
    track("insight_tapped", { kind: insight.kind });
    onNavigate(insight.target);
  }

  function handleCoach(insight: TodayInsight) {
    if (!insight.coachPrompt) return;
    track("insight_coach_opened", { kind: insight.kind });
    onAskCoach(insight.coachPrompt);
  }

  return (
    <View style={styles.card}>
      <View style={styles.headerRow}>
        <Text style={styles.title}>Insights</Text>
      </View>
      {insights.map((insight, i) => (
        <TouchableOpacity
          key={`${insight.kind}_${i}`}
          style={[styles.row, i > 0 && styles.rowBorder]}
          onPress={() => handleTap(insight)}
          activeOpacity={0.7}
          accessibilityRole="button"
          accessibilityLabel={insight.title}
        >
          <Ionicons name={KIND_ICONS[insight.kind]} size={22} color={colors.accent} />
          <View style={styles.rowText}>
            <Text style={styles.rowTitle}>{insight.title}</Text>
            {insight.detail ? <Text style={styles.rowDetail}>{insight.detail}</Text> : null}
            {insight.coachPrompt ? (
              <TouchableOpacity
                style={styles.coachButton}
                onPress={() => handleCoach(insight)}
                hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
                accessibilityRole="button"
                accessibilityLabel="Ask coach about this overrun"
              >
                <Ionicons name="chatbubble-ellipses-outline" size={13} color={colors.accent} />
                <Text style={styles.coachButtonText} maxFontSizeMultiplier={1.4}>Ask coach</Text>
              </TouchableOpacity>
            ) : null}
          </View>
          <Text style={styles.chevron}>›</Text>
        </TouchableOpacity>
      ))}
    </View>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    card: {
      backgroundColor: colors.surface,
      borderRadius: radius.lg,
      padding: spacing.md,
      marginHorizontal: spacing.lg,
      marginBottom: spacing.md,
      ...shadow.card,
    },
    headerRow: { flexDirection: "row", alignItems: "center", gap: spacing.sm, marginBottom: spacing.xs },
    title: { fontFamily: fonts.bodySemiBold, flex: 1, fontSize: fontSize.md, color: colors.textPrimary },
    row: { flexDirection: "row", alignItems: "flex-start", gap: spacing.sm, paddingVertical: spacing.sm, minHeight: 44 },
    rowBorder: { borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: colors.border },
    rowText: { flex: 1 },
    rowTitle: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.textPrimary },
    rowDetail: { fontFamily: fonts.bodyRegular, fontSize: fontSize.xs, color: colors.textSecondary, marginTop: 1 },
    coachButton: {
      flexDirection: "row",
      alignItems: "center",
      gap: 4,
      alignSelf: "flex-start",
      marginTop: spacing.xs,
      paddingHorizontal: spacing.sm,
      paddingVertical: 4,
      borderRadius: radius.sm,
      backgroundColor: colors.accent + "1a",
    },
    coachButtonText: { fontFamily: fonts.bodyBold, fontSize: fontSize.xs, color: colors.accent },
    chevron: { fontFamily: fonts.bodyRegular, fontSize: fontSize.lg, color: colors.textMuted },
  });
}
```

- [ ] **Step 2: Gate + commit**

```bash
npm run typecheck
npm test
npm run lint
git add components/InsightsCard.tsx
git commit -m "feat: add InsightsCard component in the setup-checklist style

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: TodayScreen wiring

**Files:**
- Modify: `screens/TodayScreen.tsx` (imports ~lines 19-54, state ~line 408, both load blocks ~lines 427-481, handlers after `handlePlanRoute` ~line 521, render after `<SetupChecklistCard>` ~line 680)

**Interfaces:**
- Consumes: `InsightsCard` (Task 7); `InsightTarget` type (Task 4); `loadInvoices` (utils/storage — already exported, verified); `ChatHome` param (Task 6); existing `setSelectedDate`, `navigation.getParent()` cross-tab pattern.
- Produces: the user-visible feature. No new exports.

- [ ] **Step 1: Imports** — add `loadInvoices` to the existing `utils/storage` import list; add:

```tsx
import { InsightsCard } from '../components/InsightsCard';
import type { InsightTarget } from '../utils/todayInsights';
```

- [ ] **Step 2: State** — next to the other `useState` calls:

```tsx
  const [invoices, setInvoices] = useState<Invoice[]>([]);
```

- [ ] **Step 3: Load invoices in BOTH load paths** — in `fetchTodayData`'s `Promise.all` AND `useRefresh`'s `Promise.all`, append `loadInvoices()` as the last element, add `allInvoices` to the destructuring, and `setInvoices(allInvoices)` beside the other setters. The two blocks must stay mirror images (existing convention):

```tsx
          const [allJobsList, expectedEarnings, overdue, leads, loadedSettings, customerList, checklist, allInvoices] = await Promise.all([
            loadJobs(),
            getExpectedEarningsForDate(todayString),
            loadOverdueInvoices(),
            loadLeadJobs(),
            loadSettings(),
            loadCustomers(),
            loadSetupChecklistState(),
            loadInvoices(),
          ]);
```

with `setInvoices(allInvoices);` added in the `if (active)` block (and the same two lines in `useRefresh`).

- [ ] **Step 4: Handlers** — after `handlePlanRoute`:

```tsx
  function handleInsightNavigate(target: InsightTarget) {
    switch (target.type) {
      case 'job':
        navigation.getParent()?.navigate('Jobs', { screen: 'JobDetail', params: { jobId: target.jobId } });
        break;
      case 'createInvoice':
        navigation.getParent()?.navigate('Jobs', { screen: 'CreateInvoiceFromJob', params: { jobId: target.jobId } });
        break;
      case 'invoice':
        navigation.getParent()?.navigate('Invoices', { screen: 'InvoiceList', params: { openInvoiceId: target.invoiceId } });
        break;
      case 'invoices':
        navigation.getParent()?.navigate('Invoices');
        break;
      case 'jobs':
        navigation.getParent()?.navigate('Jobs');
        break;
      case 'schedule':
        navigation.getParent()?.navigate('Jobs', { screen: 'AddJob', params: { jobId: target.jobId, focusSchedule: true } });
        break;
      case 'selectDate':
        setSelectedDate(target.date);
        break;
    }
  }

  function handleAskCoach(prompt: string) {
    navigation.getParent()?.navigate('AI', { screen: 'ChatHome', params: { initialPrompt: prompt } });
  }
```

- [ ] **Step 5: Render** — directly after the `<SetupChecklistCard … />` line:

```tsx
      {/* Proactive insights — takes the checklist's slot once setup is done
          (gating lives inside the card); hidden for brand-new accounts while
          the first-action hero is up. */}
      {!loading && !hero && (
        <InsightsCard
          jobs={allJobs}
          invoices={invoices}
          settings={settings}
          onNavigate={handleInsightNavigate}
          onAskCoach={handleAskCoach}
        />
      )}
```

- [ ] **Step 6: Full gate + commit**

```bash
npm run typecheck
npm test
npm run lint
git add screens/TodayScreen.tsx
git commit -m "feat: surface proactive insights card on Today

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 7: Verify CI after push (when the owner asks to push)** — `gh run list --workflow "Verify gate" --limit 1` must be green (standing lesson: local green ≠ CI green).

---

## Post-plan notes for the executor

- **Do NOT run `git add -A`** — an untracked `.claude/skills/` directory exists in the repo and must stay untracked.
- The spec's out-of-scope list is binding: no per-insight dismiss, no work-hours setting, no SetupChecklistCard refactor, no RNTL card test in v1.
- After Task 8, report the phase (Confidence / Missing Context / Recommended Next Step) and STOP for the owner. Device smoke (owner-only, via Expo Go/TestFlight) is required before any OTA claim — the web preview cannot verify TradeReady UI.
