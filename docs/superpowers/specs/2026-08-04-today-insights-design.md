# Proactive Today-Screen Insights — Design

**Date:** 2026-08-04
**Status:** Approved (owner design conversation 2026-08-04); not yet implemented
**Scope:** new utils/todayInsights.ts + components/InsightsCard.tsx, largest-gap helper in scheduleSmarts.ts, isSetupComplete in setupChecklist.ts, TodayScreen wiring, ChatHome initialPrompt param + ChatScreen consumption, optional-clock param on daysPastDue

## Problem

The Today screen reacts (overdue list, awaiting-estimates row, leads) but never
volunteers forward-looking, money-on-the-table observations: a job burning past
its labor estimate, a finished job nobody invoiced, an invoice about to go
overdue, an empty slot tomorrow while approved work sits unscheduled. The AI
coach can discuss all of this — but only if the user thinks to open a blank
chat and ask. Deterministic rules can surface these insights proactively, in
the same card style as the setup checklist, and hand the AI a running start
where drafting/explaining helps.

## Decisions (owner-approved)

1. **Net-new insights only.** The card surfaces only rules Today does not
   already show. The existing Overdue section, awaiting-estimates row, leads
   section, and stat row are untouched. (Chosen over consolidating them into
   one "needs attention" card.)
2. **Deep-links + "Ask coach".** Each insight taps through to the most relevant
   existing screen; the labor-overrun row additionally gets an "Ask coach"
   action that opens the AI tab with a prefilled, data-rich prompt (never
   auto-sent). (Chosen over deep-links-only and over inline AI text, which
   would put a network call on the Today render path — violates local-first.)
3. **Five rules in v1:** labor overrun, completed-but-uninvoiced, invoice due
   soon, open slot tomorrow, approved-but-unscheduled.
4. **Gated behind setup completion.** The card appears only once the "Finish
   setting up" checklist is gone (dismissed OR all tasks done) and the
   first-action hero is gone. It occupies the checklist's visual slot.
5. **Top-3 by fixed priority, no dismiss button.** Rows disappear on their own
   as the underlying condition resolves. (Per-insight snooze is a v2 idea.)
6. **Work day = 08:00–17:00 constant** for the open-slot rule. Not a setting —
   no persisted data-shape change in v1.

## Data-shape changes

**NONE.** No new fields on any persisted model, no new AsyncStorage keys, no
dependency changes, no backend/sync changes. Everything derives from data
TodayScreen already loads. (The only type change is an additive navigation
param — `ChatHome: { initialPrompt?: string }` — which is not persisted.)

## Design

### A. New utility: `utils/todayInsights.ts`

Pure functions, no I/O, no Expo/RN imports, injected clock — mirrors
`utils/estimateFollowUps.ts`. Single orchestrator:

```ts
selectTodayInsights(jobs: Job[], invoices: Invoice[], now: Date): TodayInsight[]

type TodayInsight = {
  kind: "labor_overrun" | "uninvoiced_complete" | "due_soon"
      | "open_slot" | "unscheduled_approved";
  title: string;
  detail?: string;
  target: InsightTarget;      // discriminated union, below
  coachPrompt?: string;       // labor_overrun only
};

type InsightTarget =
  | { type: "job"; jobId: string }            // JobDetail
  | { type: "createInvoice"; jobId: string }  // CreateInvoiceFromJob
  | { type: "invoice"; invoiceId: string }    // InvoiceList + openInvoiceId
  | { type: "invoices" }                      // Invoices tab
  | { type: "jobs" }                          // Jobs tab
  | { type: "schedule"; jobId: string }       // AddJob { jobId, focusSchedule }
  | { type: "selectDate"; date: string };     // Today week-strip selection
```

Returns the full prioritized list; the card renders the first 3. Icons are
mapped from `kind` inside the card (keeps the util free of Ionicons imports).

The five rules, in priority order:

1. **`labor_overrun`** (one row per job). Qualifies iff status ∈
   {approved, scheduled, in_progress} (a clock-in on `approved` does not
   auto-advance, so `approved` can carry sessions), not archived
   (`isArchived`, utils/archive.ts), `laborHours > 0`, `timeSessions`
   non-empty, and `computeTimeTracking(sessions, laborHours,
   now.getTime()).overUnder >= 0.25` (quarter-hour floor — trades think in
   quarter-hours; sub-15-minute overruns are noise). Title:
   `'{title}' is {formatElapsed(overMs)} over its {formatLaborHint(laborHours)}
   labor estimate`. Target: job detail. Carries `coachPrompt` (§F).
   Completed/invoiced jobs are excluded — "running over" is present tense;
   after completion the money conversation belongs to invoicing.
2. **`uninvoiced_complete`.** Status `complete`, `invoiceId` null, not
   archived. Job has no completion timestamp (verified against models.ts), so
   the copy carries no day count. One job: `'{title}' is complete but not
   invoiced`, detail `{formatQuote(estimateTotal)} to bill` when
   `estimateTotal > 0`, target createInvoice. Several: `{N} completed jobs
   haven't been invoiced`, target jobs. Fires regardless of the
   `autoInvoiceOnComplete` toggle (with it ON these jobs exist only when the
   user skipped the auto flow — still actionable).
3. **`due_soon`.** `!isFullyPaid(invoice)` and `daysPastDue(invoice.due, now)`
   in **[−2, 0]** — due-today is NOT overdue (existing semantics), so this
   hands off to the Overdue section exactly at day +1 with no overlap.
   One invoice: `Invoice {number} ({formatMoney(balanceDue)}) is due
   {today | tomorrow | in 2 days}`, target invoice detail (existing
   `openInvoiceId` param). Several: `{formatMoney(sum of balanceDue)} across
   {N} invoices is due within 2 days`, target invoices.
4. **`open_slot`.** Tomorrow = `shiftDate(formatLocalDate(now), 1)` (all
   local-frame, FA-039). Uses the new `largestFreeGap` helper (§B): fires iff
   tomorrow has ≥1 scheduled non-terminal job AND the largest free gap inside
   08:00–17:00 is ≥ 120 minutes. If an approved, unscheduled, non-archived
   job with `0 < laborHours*60 <= gapMinutes` exists (pick the largest
   fitting `laborHours` — best fill): `Tomorrow has a
   {formatLaborHint(gap/60)} open slot — '{title}'
   ({formatLaborHint(laborHours)}) would fit`, target
   schedule→`AddJob { jobId, focusSchedule: true }`. Otherwise: `Tomorrow has
   a {…} open slot`, target selectDate(tomorrow) — the week strip flips to
   tomorrow so the user sees the day. An empty tomorrow is deliberately
   silent: the empty-schedule state owns that message.
5. **`unscheduled_approved`.** Approved, no `scheduledDate`, not archived,
   **excluding** the job already named by rule 4's fit (dedupe). One:
   `'{title}' is approved but not scheduled`, target schedule. Several:
   `{N} approved jobs aren't on the schedule yet`, target jobs.

### B. `largestFreeGap` in utils/scheduleSmarts.ts

New pure export next to the existing window math (which it reuses —
`window()`, `toMinutes`, `TERMINAL_STATUSES` gains an export):

```ts
largestFreeGap(jobs: Job[], date: string,
               dayStart = "08:00", dayEnd = "17:00")
  : { start: string; minutes: number } | null
```

Filters to `scheduledDate === date`, `scheduledStartTime` set, non-terminal
status; returns `null` when no such job exists (the "empty day is silent"
rule lives here so no caller can leak it). Busy windows are clamped to
[dayStart, dayEnd], merged, and the largest complement gap returned. All
minutes-since-midnight local math — no Date parsing of date strings.

### C. `isSetupComplete` in utils/setupChecklist.ts

```ts
isSetupComplete(settings, state, notifGranted): boolean
// state.dismissed === true || deriveSetupTasks(...).every(t => t.done)
```

The single shared definition of "the checklist box is off the screen" so
SetupChecklistCard's hide condition and InsightsCard's show condition can
never drift. SetupChecklistCard is NOT refactored in v1 (its logic already
matches; refactoring it to call the helper is a free follow-up).

### D. `components/InsightsCard.tsx`

Mirrors SetupChecklistCard's structure exactly: self-contained focus-effect
load of checklist state + notification permission, `createStyles(colors,
shadow)` factory, renders `null` until loaded. Visible iff `isSetupComplete()`
AND ≥1 insight. Props:

```ts
{ jobs, invoices, settings, onNavigate: (target: InsightTarget) => void,
  onAskCoach: (prompt: string) => void }
```

Header row: title **"Insights"** (checklist-card typography, no progress
counter, no Hide button). Rows: kind-mapped Ionicons icon + title +
optional detail sub-line + chevron, 44pt min height, hairline separators —
the checklist row pattern. The labor-overrun row adds a small secondary
"Ask coach" pill (accent-tinted, like the JobCard "On my way" button).
Insights are computed in a `useMemo` over `[jobs, invoices]` with
`new Date()` at render — static per focus load, no ticking timer.

### E. TodayScreen wiring

Rendered in the checklist card's slot, directly after `<SetupChecklistCard>`:
`{!loading && !hero && <InsightsCard … />}`. TodayScreen already loads jobs,
invoices (overdue subset only — it must additionally pass ALL invoices, so
`loadInvoices()` joins the existing `Promise.all`), settings. `onNavigate`
maps the target union onto the existing navigation helpers (`getParent()`
cross-tab pattern, `openInvoiceId` for invoice detail, `setSelectedDate` for
selectDate). `onAskCoach` navigates
`getParent()?.navigate('AI', { screen: 'ChatHome', params: { initialPrompt } })`.

Sample data is treated exactly like the existing sections treat it (no
filtering) — consistency over cleverness. Note: both SetupChecklistCard and
InsightsCard load checklist state on focus; after the user taps "Hide" on the
checklist, the insights card appears on the NEXT focus, not the same frame —
accepted (one focus-cycle delay, zero coupling).

### F. ChatHome initialPrompt (types/navigation.ts + screens/ChatScreen.tsx)

`ChatHome: { initialPrompt?: string } | undefined`. ChatScreen consumes it in
a `useEffect` on the param: `setInput(initialPrompt)` then
`navigation.setParams({ initialPrompt: undefined })` so it can never re-fire.
**Not auto-sent** — the user reviews/edits before sending. The labor-overrun
`coachPrompt` is built deterministically in todayInsights.ts, e.g.:

> I'm working on '{title}' and I've logged {tracked} against a {est} labor
> estimate at {rate}/hr (estimate total {formatQuote(estimateTotal)}). How
> should I handle the overrun — talk to the customer now, absorb it, or
> adjust the bill?

Privacy: job title + financials — the same data categories the chat coach's
BUSINESS DATA block already sends and the privacy policy already discloses.
No policy change required.

### G. `daysPastDue` optional clock (utils/invoiceHelpers.ts)

Gains an optional trailing `now: Date = new Date()` param so the due_soon
rule is deterministic under test. Purely additive — zero call-site changes,
existing tests unaffected.

### H. Analytics

Three new PostHog events: `insight_shown` `{ kinds: string[] }` (the ≤3
visible kinds, once per focus load while visible), `insight_tapped`
`{ kind }`, `insight_coach_opened` `{ kind: "labor_overrun" }`.

## Edge cases

- **Timezone/DST:** every date is local-frame — `formatLocalDate` +
  `shiftDate` for tomorrow, `daysPastDue` (round-not-floor) for due buckets,
  minutes-since-midnight for gaps. No `toISOString`, no UTC parsing (FA-039).
- **Clocked-in jobs:** `overUnder` uses live elapsed time at render; the card
  does not tick — the number refreshes on next focus. Accepted.
- **due_soon → overdue handoff:** daysPastDue 0 → due_soon; ≥1 → Overdue
  section. (Owner decision, 2026-08-04: the pre-existing UTC-parse quirk in
  `loadOverdueInvoices`'s own comparison — `new Date(inv.due) < today` parsed
  the bare date as UTC midnight, misclassifying due-today invoices as overdue
  in negative-offset timezones — was fixed on this branch. The Overdue loader
  now filters on local-frame `daysPastDue(inv.due) >= 1`, so the handoff is
  clean in every timezone.)
- **Terminal/declined/archived** records are excluded from every rule
  (shared `TERMINAL_STATUSES` + `isArchived`).
- **Performance:** pure O(n) passes over already-loaded arrays; zero network,
  zero storage reads beyond the one added `loadInvoices()` — the render path
  stays local-first.
- **Empty tomorrow** never fires open_slot (rule lives inside
  `largestFreeGap`). A day fully booked has no ≥2h gap — silent.
- **Rule-4/5 dedupe:** the fitting job named by open_slot is excluded from
  unscheduled_approved's count so one job never generates two rows.

## Out of scope (v1)

Per-insight dismiss/snooze, configurable work hours or thresholds, inline
AI-generated insight text, notification versions of these insights, widget
surfacing, refactoring SetupChecklistCard onto `isSetupComplete`, additional
rules (expense anomalies, seasonal trends). All compatible extensions.

## Testing

- `__tests__/todayInsights.test.ts` — fixed-clock units per rule: fires /
  doesn't-fire boundaries (overUnder 0.24 vs 0.25; due in 2 vs 3 days;
  due-today vs overdue handoff; gap 119 vs 120 min; empty tomorrow silent;
  fit selection picks largest fitting job), aggregation copy (1 vs N),
  priority order, rule-4/5 dedupe, terminal/archived exclusion,
  coachPrompt content, formatMoney-vs-formatQuote mapping (actual amounts →
  formatMoney; estimate headlines → formatQuote).
- scheduleSmarts suite — `largestFreeGap`: overlapping windows merge, windows
  clamp to the work day, missing end-time blocks max(labor, 1h) (existing
  `window` semantics), no-jobs → null, exact-120 boundary.
- `daysPastDue` — new injected-clock case; existing zero-arg cases untouched.
- InsightsCard RNTL screen-level test only if parity with existing component
  suites warrants it (per the estimate-nudges precedent) — selector units are
  the load-bearing coverage.
- Gate: tsc 0 / all tests / lint 0 before any commit (change-control rule 2).

## Ship path

JS-only, no dependencies, no native changes → **OTA-eligible** via
`eas update` on the production channel (1.1.0 runtime) once the owner's
device smoke passes. No store-listing claims from this feature.
