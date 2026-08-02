# Estimate Follow-Up Nudges Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One-shot local notification 3 days after an estimate is sent with no response, opening a prefilled editable SMS/email composer, plus a persistent Today-screen "awaiting response" row and a Settings toggle (default ON).

**Architecture:** A pure selector module (`utils/estimateFollowUps.ts`, mirroring `utils/appointmentMessages.ts`) feeds a new `est_` branch in the `syncNotifications` cancel-all-and-re-derive sweep; auto-cancel and one-shot semantics fall out of the sweep for free. A new `EstimateFollowUpScreen` (mirroring `ReviewRequestScreen`) is reached by notification tap and a JobDetail action. Two additive optional fields (`Job.estimateSentAt`, `Settings.estimateFollowUpsEnabled`) ride the JSON-blob sync — no migration.

**Tech Stack:** Expo 54 / RN 0.81 / React 19 / TypeScript, expo-notifications, Jest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-08-01-estimate-follow-up-nudges-design.md` (owner-approved). Branch: `feat/estimate-follow-up-nudges`.

## Global Constraints

- Repo root for all paths: `C:\Users\Chadr\OneDrive\Documents\TraderPro App\tradeready\` — run all commands from there.
- **No new dependencies, no `package.json`/`app.json` changes, no Expo SDK changes** (change-control rule 3). JS-only → OTA-eligible.
- **Gate before EVERY commit:** `npm run typecheck` (0 errors), `npm test` (all pass; baseline 1537 tests / 97 suites), `npm run lint` (0 warnings). Never commit red.
- **Data shapes:** ONLY the two spec-approved additions (`Job.estimateSentAt?: DateString`, `Settings.estimateFollowUpsEnabled: boolean`). Nothing else on any persisted model. Do not touch `utils/sync.ts`.
- **Local-frame dates everywhere** (FA-039): fire dates built via `new Date(y, m, d, h…)` / `parseLocalDate` — never `toISOString()`/UTC parsing.
- **Absent `estimateFollowUpsEnabled` means ON** — every read site checks `!== false`, never truthiness. (Reverse of `appointmentRemindersEnabled`.)
- The one-shot nudge fires `FOLLOW_UP_DAYS = 3` days after send at **9:00am local**. Notification identifier namespace: `est_<jobId>`. Tap data: `{ type: "estimate_follow_up", jobId }`.
- Estimate amounts render with `formatQuote` (never `formatMoney`).
- Reuse shared primitives (`composeSMSWithOutcome`/`composeEmailWithOutcome`, `resolveCustomer`, `Button`/`Card`/`EmptyState`, `useTheme` + `createStyles(colors, shadow)` factory with `useMemo` keyed `[colors, shadow]`). No local copies.
- Commit style: imperative subject, `feat:`/`test:`/`docs:` prefix, specific content. Commit at the end of each task.

---

### Task 1: Data-shape additions (models + defaults)

**Files:**
- Modify: `types/models.ts` (~line 150 for Job; ~line 514 for Settings)
- Modify: `utils/storage/defaults.ts` (~line 233)

**Interfaces:**
- Consumes: nothing.
- Produces: `Job.estimateSentAt?: DateString` and `Settings.estimateFollowUpsEnabled: boolean` — every later task type-checks against these exact names.

- [ ] **Step 1: Add `estimateSentAt` to Job**

In `types/models.ts`, the Job interface currently ends:

```ts
  recurringJobId?: string;
  occurrenceNumber?: number;
  approval?: EstimateApproval;
}
```

Change to:

```ts
  recurringJobId?: string;
  occurrenceNumber?: number;
  /**
   * Local "YYYY-MM-DD" date the estimate was last sent (any send path:
   * mark-as-sent, approval link, revise-and-resend). Absent on jobs sent
   * before 2026-08 — those never get a follow-up nudge (estimateSentDate in
   * utils/estimateFollowUps.ts falls back to approval.sentAt, then gives up).
   * Re-stamped on every re-send, which deliberately re-arms the one-shot nudge.
   */
  estimateSentAt?: DateString;
  approval?: EstimateApproval;
}
```

- [ ] **Step 2: Add `estimateFollowUpsEnabled` to Settings**

In `types/models.ts`, after the `onMyWayTemplate: string;` line (~514), insert:

```ts
  /**
   * When false, suppresses estimate follow-up nudges — both the est_ local
   * notification and Today's "awaiting response" row. ⚠️ ABSENT MEANS ON,
   * the REVERSE of appointmentRemindersEnabled above: read sites must check
   * `settings.estimateFollowUpsEnabled !== false`, never truthiness, so users
   * whose persisted settings predate this field get the feature (default-on
   * was an explicit owner decision, 2026-08-01 spec). Do not "unify" the two
   * conventions.
   */
  estimateFollowUpsEnabled: boolean;
```

- [ ] **Step 3: Default it ON in `defaultSettings()`**

In `utils/storage/defaults.ts`, after the `onMyWayTemplate: DEFAULT_ON_MY_WAY_TEMPLATE,` line, insert:

```ts
    estimateFollowUpsEnabled: true, // default ON — and ABSENT also means on (see types/models.ts)
```

- [ ] **Step 4: Run the gate**

Run: `npm run typecheck` → 0 errors. `npm test` → 1537 passed. `npm run lint` → 0 warnings.
(Existing code compiles because both fields are optional-or-defaulted; no consumer exists yet.)

- [ ] **Step 5: Commit**

```bash
git add types/models.ts utils/storage/defaults.ts
git commit -m "feat: add estimateSentAt and estimateFollowUpsEnabled data shapes"
```

---

### Task 2: Pure selector module `utils/estimateFollowUps.ts` (TDD)

**Files:**
- Modify: `utils/recurrence.ts:14` (export keyword only)
- Create: `utils/estimateFollowUps.ts`
- Test: `__tests__/estimateFollowUps.test.ts`

**Interfaces:**
- Consumes: `Job.estimateSentAt` / `Settings` shapes from Task 1; `parseLocalDate` (`utils/moneyUtils.ts`), `formatQuote` (`utils/format.ts`), `formatLocalDate` (`utils/recurrence.ts`, newly exported).
- Produces (exact exports later tasks import):
  - `FOLLOW_UP_DAYS = 3`
  - `type EstimateFollowUpReminder = { jobId: string; customerName: string; jobTitle: string; fireDate: Date }`
  - `estimateSentDate(job: Job): Date | null`
  - `stampEstimateSent(job: Job, now: Date): Job`
  - `selectEstimateFollowUps(jobs: Job[], now: Date): EstimateFollowUpReminder[]`
  - `selectAwaitingFollowUp(jobs: Job[], now: Date): Job[]`
  - `awaitingResponseLabel(count: number): string`
  - `buildFollowUpMessage(job: Job, customerFirstName: string): string`

- [ ] **Step 1: Export `formatLocalDate` from recurrence.ts**

In `utils/recurrence.ts` line 14, change `function formatLocalDate(d: Date): string {` to:

```ts
// Exported for utils/estimateFollowUps.ts (stampEstimateSent) — same
// local-frame formatter, no behavior change.
export function formatLocalDate(d: Date): string {
```

- [ ] **Step 2: Write the failing test**

Create `__tests__/estimateFollowUps.test.ts`:

```ts
// __tests__/estimateFollowUps.test.ts
// Pure-selector tests for estimate follow-up nudges. All date math is
// LOCAL-frame (FA-039): fixed `now` Dates are constructed with the
// components constructor, never ISO strings.
import {
  FOLLOW_UP_DAYS,
  estimateSentDate,
  stampEstimateSent,
  selectEstimateFollowUps,
  selectAwaitingFollowUp,
  awaitingResponseLabel,
  buildFollowUpMessage,
} from "../utils/estimateFollowUps";
import type { Job } from "../types/models";

function makeJob(overrides: Partial<Job> = {}): Job {
  return {
    id: "j1",
    customerId: "c1",
    customerName: "Dave Smith",
    title: "Water heater swap",
    description: "",
    status: "estimate_sent",
    scheduledDate: null,
    scheduledStartTime: null,
    scheduledEndTime: null,
    address: "",
    estimateTotal: 850,
    laborHours: 3,
    laborRate: 85,
    materials: [],
    materialMarkup: 20,
    overhead: 15,
    margin: 20,
    notes: "",
    invoiceId: null,
    createdAt: "2026-07-01",
    ...overrides,
  };
}

describe("estimateSentDate", () => {
  test("prefers estimateSentAt over approval.sentAt", () => {
    const job = makeJob({
      estimateSentAt: "2026-08-01",
      approval: { token: "t", sentAt: "2026-07-20T14:00:00.000Z", snapshot: {} as never },
    });
    expect(estimateSentDate(job)).toEqual(new Date(2026, 7, 1));
  });

  test("falls back to approval.sentAt (ISO timestamp) when estimateSentAt is absent", () => {
    const job = makeJob({
      approval: { token: "t", sentAt: "2026-07-20T14:00:00.000Z", snapshot: {} as never },
    });
    const d = estimateSentDate(job);
    expect(d).not.toBeNull();
    expect(d!.getTime()).toBe(new Date("2026-07-20T14:00:00.000Z").getTime());
  });

  test("returns null when neither field exists (legacy manual send)", () => {
    expect(estimateSentDate(makeJob())).toBeNull();
  });

  test("returns null for an unparseable date instead of NaN math", () => {
    expect(estimateSentDate(makeJob({ estimateSentAt: "garbage" }))).toBeNull();
  });
});

describe("stampEstimateSent", () => {
  test("sets status and a local YYYY-MM-DD stamp from `now`", () => {
    const job = makeJob({ status: "lead" });
    const stamped = stampEstimateSent(job, new Date(2026, 7, 1, 16, 30));
    expect(stamped.status).toBe("estimate_sent");
    expect(stamped.estimateSentAt).toBe("2026-08-01");
  });

  test("preserves every other field", () => {
    const job = makeJob({ notes: "keep me" });
    const stamped = stampEstimateSent(job, new Date(2026, 7, 1));
    expect(stamped.notes).toBe("keep me");
    expect(stamped.id).toBe(job.id);
  });
});

describe("selectEstimateFollowUps", () => {
  // Sent Aug 1 → fire Aug 4, 9:00am LOCAL.
  const now = new Date(2026, 7, 2, 12, 0); // Aug 2 noon

  test("selects a silent estimate with a future fire date at sent+3d 9am local", () => {
    const out = selectEstimateFollowUps([makeJob({ estimateSentAt: "2026-08-01" })], now);
    expect(out).toHaveLength(1);
    expect(out[0]).toEqual({
      jobId: "j1",
      customerName: "Dave Smith",
      jobTitle: "Water heater swap",
      fireDate: new Date(2026, 7, 4, 9, 0, 0, 0),
    });
  });

  test("skips jobs not in estimate_sent", () => {
    const out = selectEstimateFollowUps(
      [makeJob({ status: "approved", estimateSentAt: "2026-08-01" })],
      now,
    );
    expect(out).toHaveLength(0);
  });

  test("skips jobs with no resolvable sent date (legacy)", () => {
    expect(selectEstimateFollowUps([makeJob()], now)).toHaveLength(0);
  });

  test("excludes past fire dates — this is the one-shot mechanism", () => {
    const out = selectEstimateFollowUps(
      [makeJob({ estimateSentAt: "2026-07-20" })],
      now,
    );
    expect(out).toHaveLength(0);
  });

  test("sorts soonest-first", () => {
    const out = selectEstimateFollowUps(
      [
        makeJob({ id: "late", estimateSentAt: "2026-08-02" }),
        makeJob({ id: "soon", estimateSentAt: "2026-08-01" }),
      ],
      now,
    );
    expect(out.map((r) => r.jobId)).toEqual(["soon", "late"]);
  });
});

describe("selectAwaitingFollowUp", () => {
  test("includes estimates silent >= FOLLOW_UP_DAYS, excludes younger ones", () => {
    const now = new Date(2026, 7, 10, 12, 0);
    const old = makeJob({ id: "old", estimateSentAt: "2026-08-01" }); // 9+ days
    const young = makeJob({ id: "young", estimateSentAt: "2026-08-09" }); // 1 day
    const out = selectAwaitingFollowUp([old, young], now);
    expect(out.map((j) => j.id)).toEqual(["old"]);
  });

  test("excludes non-estimate_sent and legacy no-date jobs", () => {
    const now = new Date(2026, 7, 10, 12, 0);
    const out = selectAwaitingFollowUp(
      [makeJob({ status: "approved", estimateSentAt: "2026-08-01" }), makeJob()],
      now,
    );
    expect(out).toHaveLength(0);
  });

  test("day-3 pre-9am: appears in BOTH selectors (intentional overlap, see spec)", () => {
    const now = new Date(2026, 7, 4, 8, 0); // day 3, 8:00am
    const job = makeJob({ estimateSentAt: "2026-08-01" });
    expect(selectAwaitingFollowUp([job], now)).toHaveLength(1);
    expect(selectEstimateFollowUps([job], now)).toHaveLength(1);
  });
});

describe("awaitingResponseLabel", () => {
  test("singular and plural", () => {
    expect(awaitingResponseLabel(1)).toBe("1 estimate awaiting response");
    expect(awaitingResponseLabel(3)).toBe("3 estimates awaiting response");
  });
});

describe("buildFollowUpMessage", () => {
  test("includes first name, job title, and formatQuote amount", () => {
    const msg = buildFollowUpMessage(makeJob(), "Dave");
    expect(msg).toContain("Hi Dave");
    expect(msg).toContain("Water heater swap");
    expect(msg).toContain("$850");
  });

  test("FOLLOW_UP_DAYS is 3 (spec constant — Settings copy and notification body cite it)", () => {
    expect(FOLLOW_UP_DAYS).toBe(3);
  });
});
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `npm test -- estimateFollowUps`
Expected: FAIL — `Cannot find module '../utils/estimateFollowUps'`.

- [ ] **Step 4: Write the implementation**

Create `utils/estimateFollowUps.ts`:

```ts
// utils/estimateFollowUps.ts
// Pure logic for estimate follow-up nudges — which silent estimates get a
// one-shot "no response" reminder and when, plus the prefilled follow-up
// message and the shared status+timestamp stamp for every send path. NO I/O
// and no Expo/RN imports — everything here is unit-testable directly
// (mirrors utils/appointmentMessages.ts). The scheduling I/O lives in
// utils/notifications.ts; the compose I/O in EstimateFollowUpScreen.
import type { Job, DateString } from "../types/models";
import { parseLocalDate } from "./moneyUtils";
import { formatLocalDate } from "./recurrence";
import { formatQuote } from "./format";

/** Days of silence after a send before the one-shot nudge fires. */
export const FOLLOW_UP_DAYS = 3;

export type EstimateFollowUpReminder = {
  jobId: string;
  customerName: string;
  jobTitle: string;
  fireDate: Date;
};

/**
 * When the estimate was last sent, or null when unknowable (legacy manual
 * sends predating estimateSentAt). estimateSentAt (local "YYYY-MM-DD") wins
 * over approval.sentAt (backend ISO timestamp). parseLocalDate handles both
 * shapes defensively — strict date → local midnight, anything else →
 * new Date(raw) — and the NaN guard keeps a malformed value from producing
 * NaN fire-date math (same defect class as the malformed-due fix, 2026-08-01).
 */
export function estimateSentDate(job: Job): Date | null {
  const raw: DateString | undefined = job.estimateSentAt ?? job.approval?.sentAt;
  if (!raw) return null;
  const d = parseLocalDate(raw);
  return Number.isFinite(d.getTime()) ? d : null;
}

/**
 * The status flip + local-frame stamp in ONE place so the three send sites
 * (SendEstimateScreen.markAsSent, estimateApprovalLink's two writes,
 * JobDetail's revise-and-resend) can never drift. Callers spread extras
 * (e.g. the approval object) on top of the returned job.
 */
export function stampEstimateSent(job: Job, now: Date): Job {
  return { ...job, status: "estimate_sent", estimateSentAt: formatLocalDate(now) };
}

/** sent + FOLLOW_UP_DAYS at 9:00am LOCAL — same local-frame construction as
 * the inv_/rinv_ branches in utils/notifications.ts (FA-039). */
function fireDateFor(sent: Date): Date {
  const fire = new Date(sent.getFullYear(), sent.getMonth(), sent.getDate(), 9, 0, 0, 0);
  fire.setDate(fire.getDate() + FOLLOW_UP_DAYS);
  return fire;
}

/**
 * Which silent estimates get a nudge, and when. Pure. One-shot semantics fall
 * out of the future-fire-date filter: once 9am on day FOLLOW_UP_DAYS passes,
 * no re-sweep ever re-creates the notification. Re-stamping estimateSentAt on
 * a re-send moves the fire date forward, deliberately re-arming it.
 */
export function selectEstimateFollowUps(jobs: Job[], now: Date): EstimateFollowUpReminder[] {
  const out: EstimateFollowUpReminder[] = [];
  for (const job of jobs || []) {
    if (!job || job.status !== "estimate_sent") continue;
    const sent = estimateSentDate(job);
    if (!sent) continue;
    const fireDate = fireDateFor(sent);
    if (fireDate.getTime() <= now.getTime()) continue;
    out.push({ jobId: job.id, customerName: job.customerName, jobTitle: job.title, fireDate });
  }
  out.sort((a, b) => a.fireDate.getTime() - b.fireDate.getTime());
  return out;
}

/**
 * Jobs for Today's "awaiting response" row: still estimate_sent and silent
 * >= FOLLOW_UP_DAYS. Overlaps selectEstimateFollowUps for a few hours on day
 * FOLLOW_UP_DAYS (the row shows while the 9am notification is still pending)
 * — intentional, see the 2026-08-01 spec. Don't "fix" it.
 */
export function selectAwaitingFollowUp(jobs: Job[], now: Date): Job[] {
  return (jobs || []).filter((job) => {
    if (!job || job.status !== "estimate_sent") return false;
    const sent = estimateSentDate(job);
    if (!sent) return false;
    return now.getTime() - sent.getTime() >= FOLLOW_UP_DAYS * 86400000;
  });
}

/** Today-row copy. */
export function awaitingResponseLabel(count: number): string {
  return `${count} estimate${count === 1 ? "" : "s"} awaiting response`;
}

/** Default follow-up message — editable on-screen before sending. Estimate
 * headline money uses formatQuote (utils/format.ts mapping rule). */
export function buildFollowUpMessage(job: Job, customerFirstName: string): string {
  return (
    `Hi ${customerFirstName}, just checking in on the estimate I sent over for ` +
    `${job.title} (${formatQuote(job.estimateTotal)}). Happy to answer any ` +
    `questions — want me to get you on the schedule?`
  );
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `npm test -- estimateFollowUps`
Expected: PASS, all tests. Also run `npm test -- recurrence` → still green (export-only change).

- [ ] **Step 6: Full gate, then commit**

Run: `npm run typecheck` → 0. `npm test` → all pass. `npm run lint` → 0.

```bash
git add utils/estimateFollowUps.ts utils/recurrence.ts __tests__/estimateFollowUps.test.ts
git commit -m "feat: add estimate follow-up pure selectors and send stamp"
```

---

### Task 3: Stamp `estimateSentAt` at the three send sites

**Files:**
- Modify: `screens/SendEstimateScreen.tsx:142-152` (markAsSent) + imports (~line 15)
- Modify: `utils/estimateApprovalLink.ts:55` and `:69-74` + imports
- Modify: `screens/JobDetailScreen.tsx:751-759` (handleReviseAndResend) + imports (~line 31)

**Interfaces:**
- Consumes: `stampEstimateSent(job, now)` from Task 2.
- Produces: every path that puts a job into `estimate_sent` now stamps `estimateSentAt` (behavior later tasks' notifications rely on).

- [ ] **Step 1: SendEstimateScreen — markAsSent**

Add to the imports block:

```ts
import { stampEstimateSent } from "../utils/estimateFollowUps";
```

In `markAsSent()` replace:

```ts
    const updated = jobs.map((j): Job =>
      j.id === jobId ? { ...j, status: "estimate_sent" } : j
    );
```

with:

```ts
    const updated = jobs.map((j): Job =>
      j.id === jobId ? stampEstimateSent(j, new Date()) : j
    );
```

- [ ] **Step 2: estimateApprovalLink — both writes**

Add to the imports at the top of `utils/estimateApprovalLink.ts`:

```ts
import { stampEstimateSent } from "./estimateFollowUps";
```

Replace the optimistic write (line ~55):

```ts
    await saveJobs(jobs.map((j): Job => (j.id === job.id ? { ...j, status: "estimate_sent" } : j)));
```

with:

```ts
    // Stamped here too: if the fetch below fails, the job is already visibly
    // estimate_sent — it must carry a sent date or it would never nudge.
    await saveJobs(jobs.map((j): Job => (j.id === job.id ? stampEstimateSent(j, new Date()) : j)));
```

Replace the mirror write (lines ~69-73):

```ts
    const linked = (await loadJobs()).map((j): Job =>
      j.id === job.id
        ? { ...j, status: "estimate_sent", approval: { token: out.token, sentAt: out.sentAt, snapshot } }
        : j
    );
```

with:

```ts
    const linked = (await loadJobs()).map((j): Job =>
      j.id === job.id
        ? { ...stampEstimateSent(j, new Date()), approval: { token: out.token, sentAt: out.sentAt, snapshot } }
        : j
    );
```

- [ ] **Step 3: JobDetailScreen — handleReviseAndResend**

Add to JobDetailScreen's imports (it already imports from utils — put beside them):

```ts
import { stampEstimateSent } from "../utils/estimateFollowUps";
```

In `handleReviseAndResend()` replace:

```ts
    const reset = jobs.map((j): Job =>
      j.id === job.id ? { ...j, status: "estimate_sent", approval: j.approval ? { ...j.approval, decision: undefined, consentAt: undefined, declineReason: undefined, signerName: undefined } : undefined } : j
    );
```

with:

```ts
    const reset = jobs.map((j): Job =>
      j.id === job.id ? { ...stampEstimateSent(j, new Date()), approval: j.approval ? { ...j.approval, decision: undefined, consentAt: undefined, declineReason: undefined, signerName: undefined } : undefined } : j
    );
```

- [ ] **Step 4: Full gate, then commit**

Run: `npm run typecheck` → 0. `npm test` → all pass (stampEstimateSent behavior is already unit-tested in Task 2; these are wiring changes covered by typecheck + the existing screen/link suites). `npm run lint` → 0.

```bash
git add screens/SendEstimateScreen.tsx utils/estimateApprovalLink.ts screens/JobDetailScreen.tsx
git commit -m "feat: stamp estimateSentAt at all three estimate send paths"
```

---

### Task 4: `est_` branch in the syncNotifications sweep (TDD)

**Files:**
- Modify: `utils/notifications.ts` (imports ~line 8; new branch after the `rinv_` loop, ~line 171)
- Test: `__tests__/notifications.test.js` (append a describe block)

**Interfaces:**
- Consumes: `selectEstimateFollowUps`, `FOLLOW_UP_DAYS` from Task 2; jobs/settings already loaded by the sweep.
- Produces: scheduled notifications `identifier: est_<jobId>`, `data: { type: "estimate_follow_up", jobId }` — Task 6's tap routing depends on this exact data shape.

- [ ] **Step 1: Write the failing tests**

Append to `__tests__/notifications.test.js` (uses the file's existing `seedStorage(invoices, settings, jobs, …)` helper and `dateInDays`):

```js
// ── Estimate follow-up nudges (est_) ──────────────────────────────────────────

describe("estimate follow-up nudges (est_)", () => {
  const estJob = (overrides = {}) => ({
    id: "j1",
    customerName: "Dave",
    title: "Water heater swap",
    status: "estimate_sent",
    estimateSentAt: dateInDays(-1),
    ...overrides,
  });

  test("schedules an est_ nudge for a silent estimate sent yesterday (absent flag means ON)", async () => {
    seedStorage([], { rules: [] }, [estJob()]);

    await syncNotifications();

    expect(Notifications.scheduleNotificationAsync).toHaveBeenCalledTimes(1);
    const [call] = Notifications.scheduleNotificationAsync.mock.calls;
    expect(call[0].identifier).toBe("est_j1");
    expect(call[0].content.title).toContain("Dave");
    expect(call[0].content.body).toContain("Water heater swap");
    expect(call[0].content.data).toEqual({ type: "estimate_follow_up", jobId: "j1" });
  });

  test("estimateFollowUpsEnabled: false schedules nothing", async () => {
    seedStorage([], { rules: [], estimateFollowUpsEnabled: false }, [estJob()]);

    await syncNotifications();

    expect(Notifications.scheduleNotificationAsync).not.toHaveBeenCalled();
  });

  test("a job that left estimate_sent gets no nudge (sweep auto-cancel)", async () => {
    seedStorage([], { rules: [] }, [estJob({ status: "approved" })]);

    await syncNotifications();

    expect(Notifications.scheduleNotificationAsync).not.toHaveBeenCalled();
  });

  test("an estimate sent long ago is one-shot done — nothing rescheduled", async () => {
    seedStorage([], { rules: [] }, [estJob({ estimateSentAt: dateInDays(-10) })]);

    await syncNotifications();

    expect(Notifications.scheduleNotificationAsync).not.toHaveBeenCalled();
  });

  test("legacy job with no sent date never nudges", async () => {
    seedStorage([], { rules: [] }, [estJob({ estimateSentAt: undefined })]);

    await syncNotifications();

    expect(Notifications.scheduleNotificationAsync).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `npm test -- notifications`
Expected: the first `est_` test FAILS (`scheduleNotificationAsync` called 0 times); the disable/skip tests may pass vacuously — that's fine, the positive case drives the implementation.

- [ ] **Step 3: Implement the branch**

In `utils/notifications.ts`, add to the imports:

```ts
import { selectEstimateFollowUps, FOLLOW_UP_DAYS } from './estimateFollowUps';
```

After the closing `}` of the `for (const rule of recurringInvoiceRules)` loop (before the `} catch {`), insert:

```ts
    // Estimate follow-up nudges — one-shot "no response" reminder per silent
    // estimate, FOLLOW_UP_DAYS after the send, 9:00am local. Fourth namespace
    // (est_) beside inv_/appt_/rinv_; shares the 60 cap and runs LAST so
    // invoice dunning and appointments keep priority. Fire-date math lives in
    // the pure selector (utils/estimateFollowUps.ts) using the same
    // local-frame construction as the branches above — do not let them drift.
    // ABSENT estimateFollowUpsEnabled means ON (default-on; the reverse of
    // appointmentRemindersEnabled — see types/models.ts).
    if (settings.estimateFollowUpsEnabled !== false) {
      for (const nudge of selectEstimateFollowUps(jobs, now)) {
        if (count >= 60) break;
        const secondsUntil = Math.floor((nudge.fireDate.getTime() - now.getTime()) / 1000);
        if (!Number.isFinite(secondsUntil) || secondsUntil <= 0) continue;
        await Notifications.scheduleNotificationAsync({
          identifier: `est_${nudge.jobId}`,
          content: {
            title: `Estimate follow-up — ${nudge.customerName}`,
            body: `Estimate for "${nudge.jobTitle}" sent ${FOLLOW_UP_DAYS} days ago with no response. Tap to follow up.`,
            data: { type: 'estimate_follow_up', jobId: nudge.jobId },
          },
          trigger: { seconds: secondsUntil } as Notifications.NotificationTriggerInput,
        });
        count++;
      }
    }
```

- [ ] **Step 4: Run the notifications suite**

Run: `npm test -- notifications`
Expected: PASS, including all pre-existing tests (the new branch schedules nothing when no `estimate_sent` jobs are seeded, so old tests' counts are unchanged).

- [ ] **Step 5: Full gate, then commit**

Run: `npm run typecheck` → 0. `npm test` → all pass. `npm run lint` → 0.

```bash
git add utils/notifications.ts __tests__/notifications.test.js
git commit -m "feat: schedule est_ follow-up nudges in the notification sweep"
```

---

### Task 5: EstimateFollowUpScreen + route registration

**Files:**
- Modify: `types/navigation.ts:46` (JobStackParamList)
- Create: `screens/EstimateFollowUpScreen.tsx`
- Modify: `App.tsx` (screen import + `<JobStack.Screen>` after ReviewRequest, ~line 157)

**Interfaces:**
- Consumes: `buildFollowUpMessage` (Task 2), `composeSMSWithOutcome`/`composeEmailWithOutcome` (`utils/messaging.ts`, return `{ opened: boolean; outcome: "sent" | "notSent" | "unknown" }`), `resolveCustomer`/`loadJobs`/`loadCustomers`/`loadSettings` (`utils/storage`), `daysAgo` (`utils/dateHelpers.ts`), `formatQuote`.
- Produces: route `EstimateFollowUp: { jobId: string; source?: "notification" | "job_detail" }` in JobStackParamList — Task 6 navigates to it by this exact name/params. Analytics event `estimate_follow_up_sent` `{ channel, source }`.

- [ ] **Step 1: Add the route type**

In `types/navigation.ts`, after the `ReviewRequest` line in `JobStackParamList`, add:

```ts
  EstimateFollowUp: { jobId: string; source?: "notification" | "job_detail" };
```

- [ ] **Step 2: Create the screen**

Create `screens/EstimateFollowUpScreen.tsx` (mirrors ReviewRequestScreen's structure; the message is EDITABLE here — that's the screen's point):

```tsx
import React, { useState, useEffect, useMemo } from "react";
import {
  View,
  Text,
  ScrollView,
  TextInput,
  TouchableOpacity,
  StyleSheet,
  Alert,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import * as Clipboard from "expo-clipboard";
import { composeEmailWithOutcome, composeSMSWithOutcome } from "../utils/messaging";
import { loadSettings, loadJobs, loadCustomers, resolveCustomer } from "../utils/storage";
import { buildFollowUpMessage } from "../utils/estimateFollowUps";
import { formatQuote } from "../utils/format";
import { daysAgo } from "../utils/dateHelpers";
import { Button, Card, Divider, EmptyState } from "../components/UI";
import { spacing, radius, fontSize, fonts, type ColorScheme, type ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import type { Settings } from "../types/models";
import { track } from "../utils/analytics";
import type { JobStackScreenProps } from "../types/navigation";

export default function EstimateFollowUpScreen({
  route,
  navigation,
}: JobStackScreenProps<'EstimateFollowUp'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const { jobId, source } = route.params;

  const [settings, setSettings] = useState<Settings | null>(null);
  const [customerName, setCustomerName] = useState("");
  const [customerPhone, setCustomerPhone] = useState("");
  const [customerEmail, setCustomerEmail] = useState("");
  const [jobTitle, setJobTitle] = useState("");
  const [estimateTotal, setEstimateTotal] = useState(0);
  const [sentLabel, setSentLabel] = useState("");
  const [message, setMessage] = useState("");
  const [copied, setCopied] = useState(false);
  const [notFound, setNotFound] = useState(false);
  const [answered, setAnswered] = useState(false);

  useEffect(() => {
    (async () => {
      const [s, jobs, customers] = await Promise.all([
        loadSettings(),
        loadJobs(),
        loadCustomers(),
      ]);
      setSettings(s);
      // The LIVE customer record drives contact info — a phone or email
      // corrected after the estimate went out must be what we send to.
      const job = jobs.find((j) => j.id === jobId);
      const cust = job ? resolveCustomer(customers, job) : null;
      if (!job || !cust) {
        setNotFound(true);
        return;
      }
      // A stale notification tap can land after the customer already decided
      // (the sweep cancels on status change, but a tap can race one sweep).
      if (job.status !== "estimate_sent") {
        setAnswered(true);
        return;
      }
      setCustomerName(cust.name);
      setCustomerPhone(cust.phone);
      setCustomerEmail(cust.email);
      setJobTitle(job.title);
      setEstimateTotal(job.estimateTotal);
      const sentRaw = job.estimateSentAt ?? job.approval?.sentAt;
      setSentLabel(sentRaw ? `Sent ${daysAgo(sentRaw)}` : "");
      const firstName = cust.name.trim().split(/\s+/)[0] || cust.name;
      setMessage(buildFollowUpMessage(job, firstName));
    })();
  }, [jobId]);

  // Cancelling out of the OS composer must not count as sent.
  async function handleSendSMS() {
    const { opened, outcome } = await composeSMSWithOutcome({
      recipients: customerPhone ? [customerPhone] : [],
      body: message,
    });
    if (opened && outcome !== "notSent") {
      track("estimate_follow_up_sent", { channel: "sms", source: source ?? "notification" });
      Alert.alert("Follow-up sent", `Sent to ${customerName} by text.`, [
        { text: "OK", onPress: () => navigation.goBack() },
      ]);
    }
  }

  async function handleSendEmail() {
    const { opened, outcome } = await composeEmailWithOutcome({
      recipients: customerEmail ? [customerEmail] : [],
      subject: `Checking in on your estimate — ${settings?.businessName ?? ""}`.trim(),
      body: message,
    });
    if (opened && outcome !== "notSent") {
      track("estimate_follow_up_sent", { channel: "email", source: source ?? "notification" });
      Alert.alert("Follow-up sent", `Sent to ${customerName} by email.`, [
        { text: "OK", onPress: () => navigation.goBack() },
      ]);
    }
  }

  async function handleCopy() {
    await Clipboard.setStringAsync(message);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  if (notFound) {
    return (
      <SafeAreaView style={styles.container} edges={["bottom"]}>
        <EmptyState message="This job or its customer no longer exists, so there's no one to follow up with." />
      </SafeAreaView>
    );
  }

  if (answered) {
    return (
      <SafeAreaView style={styles.container} edges={["bottom"]}>
        <EmptyState message="This estimate has already been answered — no follow-up needed." />
      </SafeAreaView>
    );
  }

  if (!settings || !message) return null;

  return (
    <SafeAreaView style={styles.container} edges={["bottom"]}>
      <ScrollView
        contentContainerStyle={styles.scroll}
        showsVerticalScrollIndicator={false}
        keyboardShouldPersistTaps="handled"
      >
        <Card style={styles.headerCard}>
          <Text style={styles.customerName}>{customerName}</Text>
          <Text style={styles.estimateLine}>
            {jobTitle} · {formatQuote(estimateTotal)}
          </Text>
          {sentLabel ? <Text style={styles.sentLine}>{sentLabel}</Text> : null}
        </Card>

        <Card style={styles.messageCard}>
          <Text style={styles.messageLabel}>Message — edit before sending</Text>
          <TextInput
            style={styles.messageInput}
            value={message}
            onChangeText={setMessage}
            multiline
            textAlignVertical="top"
            accessibilityLabel="Follow-up message"
          />
        </Card>

        <Divider />
        <Text style={styles.sendLabel}>Send via</Text>

        {customerPhone ? (
          <Button
            label="Send via SMS"
            onPress={handleSendSMS}
            style={{ marginBottom: spacing.sm }}
          />
        ) : null}

        {customerEmail ? (
          <Button
            label="Send via Email"
            onPress={handleSendEmail}
            variant={customerPhone ? "ghost" : "primary"}
            style={{ marginBottom: spacing.sm }}
          />
        ) : null}

        {!customerPhone && !customerEmail ? (
          <Text style={styles.noContactNote}>
            This customer has no phone or email on file — copy the message and
            send it another way, or add contact info on the customer.
          </Text>
        ) : null}

        <View style={styles.actionRow}>
          <TouchableOpacity
            style={styles.copyBtn}
            onPress={handleCopy}
            accessibilityRole="button"
            accessibilityLabel={copied ? "Copied" : "Copy message"}
          >
            <Text style={styles.copyBtnText}>{copied ? "Copied!" : "Copy message"}</Text>
          </TouchableOpacity>
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    scroll: { padding: spacing.md, paddingBottom: 40 },
    headerCard: { marginBottom: spacing.sm },
    customerName: {
      fontFamily: fonts.bodySemiBold,
      fontSize: fontSize.lg,
      color: colors.textPrimary,
    },
    estimateLine: {
      fontFamily: fonts.bodyRegular,
      fontSize: fontSize.sm,
      color: colors.textSecondary,
      marginTop: 2,
    },
    sentLine: {
      fontFamily: fonts.mono,
      fontSize: fontSize.xs,
      color: colors.textMuted,
      marginTop: 4,
    },
    messageCard: { marginBottom: spacing.sm },
    messageLabel: {
      fontFamily: fonts.mono,
      fontSize: fontSize.xs,
      color: colors.textMuted,
      textTransform: "uppercase",
      letterSpacing: 0.8,
      marginBottom: spacing.sm,
    },
    messageInput: {
      fontFamily: fonts.bodyRegular,
      fontSize: fontSize.md,
      color: colors.textPrimary,
      lineHeight: 22,
      minHeight: 120,
      padding: 0,
    },
    sendLabel: {
      fontFamily: fonts.mono,
      fontSize: fontSize.xs,
      color: colors.textSecondary,
      textTransform: "uppercase",
      letterSpacing: 0.8,
      marginBottom: spacing.sm,
    },
    noContactNote: {
      fontFamily: fonts.bodyRegular,
      fontSize: fontSize.sm,
      color: colors.textSecondary,
      lineHeight: 20,
      marginBottom: spacing.sm,
    },
    actionRow: {
      flexDirection: "row",
      justifyContent: "center",
      gap: spacing.md,
      marginTop: spacing.sm,
    },
    copyBtn: {
      paddingHorizontal: 16,
      paddingVertical: 10,
      borderRadius: radius.md,
      borderWidth: 1,
      borderColor: colors.border,
    },
    copyBtnText: {
      fontFamily: fonts.bodyMedium,
      fontSize: fontSize.sm,
      color: colors.textSecondary,
    },
  });
}
```

- [ ] **Step 3: Register the screen in the Jobs stack**

In `App.tsx`, add with the other screen imports:

```ts
import EstimateFollowUpScreen from "./screens/EstimateFollowUpScreen";
```

After the ReviewRequest `<JobStack.Screen>` block, add:

```tsx
      <JobStack.Screen
        name="EstimateFollowUp"
        component={EstimateFollowUpScreen}
        options={{ title: "Estimate Follow-Up" }}
      />
```

- [ ] **Step 4: Full gate, then commit**

Run: `npm run typecheck` → 0. `npm test` → all pass. `npm run lint` → 0.

```bash
git add types/navigation.ts screens/EstimateFollowUpScreen.tsx App.tsx
git commit -m "feat: add EstimateFollowUpScreen with prefilled editable composer"
```

---

### Task 6: Notification tap routing + JobDetail "Send follow-up" action

**Files:**
- Modify: `App.tsx:362-400` (notification response listener)
- Modify: `screens/JobDetailScreen.tsx:575-583` (PrimaryAction return)

**Interfaces:**
- Consumes: route `EstimateFollowUp` (Task 5); notification `data: { type: "estimate_follow_up", jobId }` (Task 4); `track` from `utils/analytics` (already imported in both files).
- Produces: analytics event `estimate_follow_up_opened` `{ source: "notification" | "job_detail" }`.

- [ ] **Step 1: Add the tap-routing case**

In `App.tsx`'s `addNotificationResponseReceivedListener` callback, after the `review_request` if-block, insert (same guard shape as its four siblings):

```ts
      if (data?.type === "estimate_follow_up" && data?.jobId && navigationRef.isReady()) {
        track("estimate_follow_up_opened", { source: "notification" });
        navigationRef.navigate("Main", {
          screen: "Jobs",
          params: { screen: "EstimateFollowUp", params: { jobId: String(data.jobId), source: "notification" } },
        });
      }
```

- [ ] **Step 2: Add the JobDetail secondary action (reachability)**

In `screens/JobDetailScreen.tsx`, PrimaryAction currently returns:

```tsx
  return (
    <Button
      label={action.label}
      onPress={action.onPress}
      variant={action.variant}
      style={{ marginBottom: spacing.sm }}
    />
  );
```

Replace with:

```tsx
  return (
    <>
      <Button
        label={action.label}
        onPress={action.onPress}
        variant={action.variant}
        style={{ marginBottom: spacing.sm }}
      />
      {job.status === "estimate_sent" && (
        <Button
          label="Send follow-up"
          variant="secondary"
          onPress={() => {
            track("estimate_follow_up_opened", { source: "job_detail" });
            navigation.navigate("EstimateFollowUp", { jobId: job.id, source: "job_detail" });
          }}
          style={{ marginBottom: spacing.sm }}
        />
      )}
    </>
  );
```

(`track` is already imported at the top of JobDetailScreen.)

- [ ] **Step 3: Full gate, then commit**

Run: `npm run typecheck` → 0. `npm test` → all pass. `npm run lint` → 0.

```bash
git add App.tsx screens/JobDetailScreen.tsx
git commit -m "feat: route est_ notification taps and add JobDetail follow-up action"
```

---

### Task 7: Today-screen "awaiting response" row

**Files:**
- Modify: `screens/TodayScreen.tsx` (imports ~line 27; state ~line 405; both loaders ~414-450; render between the Overdue and Follow Up sections ~line 588; styles in createStyles)

**Interfaces:**
- Consumes: `selectAwaitingFollowUp(jobs, now)`, `awaitingResponseLabel(count)` from Task 2; `loadSettings` (already imported); existing `goToJobs()` handler.
- Produces: user-visible row only — nothing downstream.

- [ ] **Step 1: Imports and state**

Add import:

```ts
import { selectAwaitingFollowUp, awaitingResponseLabel } from '../utils/estimateFollowUps';
```

Add state beside the other useState calls:

```ts
  const [awaitingEstimates, setAwaitingEstimates] = useState<Job[]>([]);
  const [followUpsEnabled, setFollowUpsEnabled] = useState(true);
```

- [ ] **Step 2: Load in both fetchers**

In `fetchTodayData` change the parallel load to include settings and derive the row data:

```ts
          const [allJobsList, expectedEarnings, overdue, leads, settings] = await Promise.all([
            loadJobs(),
            getExpectedEarningsForDate(todayString),
            loadOverdueInvoices(),
            loadLeadJobs(),
            loadSettings(),
          ]);
          if (active) {
            setAllJobs(allJobsList);
            setEarnings(expectedEarnings);
            setOverdueInvoices(overdue);
            setLeadJobs(leads);
            setAwaitingEstimates(selectAwaitingFollowUp(allJobsList, new Date()));
            // ABSENT means ON (see types/models.ts) — never truthiness.
            setFollowUpsEnabled(settings.estimateFollowUpsEnabled !== false);
          }
```

Make the same change in the `useRefresh` callback (same five loads, same four `set` calls plus the two new ones, without the `active` guard).

- [ ] **Step 3: Render the row**

Between the Overdue Invoices `BriefingSection`'s closing `)}` and the `{/* Leads Follow-Up … */}` comment, insert:

```tsx
      {/* Estimates awaiting response — persistent pointer; the one-shot est_
          notification is dismissable, this row stays until the customer
          answers or the job moves on. Same toggle as the notification. */}
      {!loading && followUpsEnabled && awaitingEstimates.length > 0 && (
        <TouchableOpacity
          style={styles.awaitingRow}
          onPress={goToJobs}
          activeOpacity={0.7}
          accessibilityRole="button"
          accessibilityLabel={awaitingResponseLabel(awaitingEstimates.length)}
        >
          <Ionicons name="hourglass-outline" size={16} color={colors.warning} />
          <Text style={styles.awaitingText} maxFontSizeMultiplier={1.4}>
            {awaitingResponseLabel(awaitingEstimates.length)}
          </Text>
          <Text style={styles.listRowChevron}>›</Text>
        </TouchableOpacity>
      )}
```

- [ ] **Step 4: Styles**

In TodayScreen's `createStyles`, add:

```ts
    awaitingRow: {
      flexDirection: 'row',
      alignItems: 'center',
      gap: spacing.sm,
      marginHorizontal: spacing.lg,
      marginBottom: spacing.sm,
      paddingHorizontal: spacing.md,
      paddingVertical: 12,
      borderRadius: radius.md,
      backgroundColor: colors.warningBg,
    },
    awaitingText: {
      flex: 1,
      fontFamily: fonts.bodyMedium,
      fontSize: fontSize.sm,
      color: colors.warning,
    },
```

- [ ] **Step 5: Full gate, then commit**

Run: `npm run typecheck` → 0. `npm test` → all pass (row logic — the selector and label — is unit-tested in Task 2). `npm run lint` → 0.

```bash
git add screens/TodayScreen.tsx
git commit -m "feat: show estimates-awaiting-response row on Today"
```

---

### Task 8: Settings toggle

**Files:**
- Modify: `screens/SettingsScreen.tsx` (after the Appointment reminders card, ~line 795)

**Interfaces:**
- Consumes: `Settings.estimateFollowUpsEnabled` (Task 1); the screen's existing `update(key, value)` helper, `Switch`, and `styles.card`/`toggleRow`/`toggleLabel`/`keyNote` styles (all already present — the Appointment reminders card at ~782-795 uses every one of them).
- Produces: user-visible toggle; saving Settings already triggers `syncNotifications()`.

- [ ] **Step 1: Add the toggle card**

Immediately after the Appointment reminders card's closing `</View>` (~line 795), insert:

```tsx
        <View style={styles.card}>
          <View style={styles.toggleRow}>
            <Text style={styles.toggleLabel}>Estimate follow-up reminders</Text>
            <Switch
              value={s.estimateFollowUpsEnabled !== false}
              onValueChange={(v) => update("estimateFollowUpsEnabled", v)}
              trackColor={{ true: colors.accent }}
              accessibilityLabel="Estimate follow-up reminders"
            />
          </View>
          <Text style={styles.keyNote}>
            Remind me when an estimate gets no response for 3 days.
          </Text>
        </View>
```

(`value` uses `!== false` — absent means ON, see types/models.ts.)

- [ ] **Step 2: Full gate, then commit**

Run: `npm run typecheck` → 0. `npm test` → all pass. `npm run lint` → 0.

```bash
git add screens/SettingsScreen.tsx
git commit -m "feat: add estimate follow-up reminders toggle to Settings"
```

---

### Task 9: Docs, final verification, phase report

**Files:**
- Modify: `docs/superpowers/specs/2026-08-01-estimate-follow-up-nudges-design.md` (Status line)
- Modify: `README.md` ONLY IF its feature list enumerates notification features (check first; follow `tradeready-docs-and-writing` house style — no capability claims beyond what's built)

**Interfaces:** none — verification and reporting.

- [ ] **Step 1: Update the spec status**

Change the spec's `**Status:**` line to: `Implemented on feat/estimate-follow-up-nudges (2026-08-01); device smoke pending`.

- [ ] **Step 2: README check**

Search `README.md` for the features/notifications section (`Select-String -Path README.md -Pattern "reminder"`). If it lists appointment/overdue reminders, add one line for estimate follow-up nudges in the same voice; if it has no such list, change nothing.

- [ ] **Step 3: Final full gate + suite count**

Run: `npm run typecheck` → 0. `npm test` → note the new totals (expect ~1558 tests / 98 suites: baseline 1537/97, +~16 from Task 2's new suite, +5 from Task 4). `npm run lint` → 0.

- [ ] **Step 4: Commit docs**

```bash
git add docs/superpowers/specs/2026-08-01-estimate-follow-up-nudges-design.md README.md
git commit -m "docs: mark estimate follow-up nudges spec implemented"
```

- [ ] **Step 5: Phase report to owner — STOP**

Report per change-control rule 1: Confidence Level, Missing Context, Recommended Next Step. Include:
- the verification line (tsc 0 / N tests / M suites / lint 0),
- skill-library drift to flag: `tradeready-config-and-flags` (new `estimateFollowUpsEnabled` Settings field + its reversed absent-means-ON semantics), `tradeready-architecture-contract` §9 if the owner wants `estimateFollowUps.ts` listed as a shared primitive, and the analytics event count (+2: `estimate_follow_up_opened`, `estimate_follow_up_sent`),
- remaining ship steps (owner device smoke via Expo Go → merge to master → OTA once iOS 1.1.0 is live),
- do NOT merge, push, or OTA without the owner's go-ahead.

---

## Manual smoke checklist (owner device, before OTA)

1. Send an estimate via "Mark as sent" → job's `estimateSentAt` stamps today (verify: JobDetail still shows normal state; Settings → toggle exists and is ON).
2. Mark an estimate sent and confirm NO immediate notification appears (the fire date is 3 days out).
3. To exercise the nudge + Today row without waiting 3 days: temporarily change `FOLLOW_UP_DAYS` to `0` in `utils/estimateFollowUps.ts` on the dev machine (Expo Go picks it up), verify the notification schedules and the row appears, then REVERT before committing anything.
4. JobDetail on an `estimate_sent` job shows "Send follow-up" → screen opens, message is editable, Copy works, SMS/Email open prefilled, cancelling the composer does NOT show the sent alert.
5. Toggle OFF in Settings → Today row disappears (after refresh) and no est_ notifications are scheduled.
6. Approve or decline the estimate → row and any pending nudge disappear.
