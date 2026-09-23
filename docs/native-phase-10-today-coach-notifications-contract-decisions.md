# Phase 10 — Today, coach, and notifications contract decisions

**Task:** 10.00 (freeze contracts and characterize gaps) · **Date:** 2026-09-21

**Status:** Code complete. Characterization only — no implementation file was
changed. Selected contracts are marked chosen; open items are marked blocked.

**How this was produced:** the React Native sources, RN tests, backend route, and
the existing Swift files named per task were read in full and their behavior
recorded below. No oracle test was modified, added, or skipped. Where the native
code already intentionally differs from RN (notification priority, the extra
booking-attention kinds) the difference is recorded rather than reconciled,
because Phase 10 must reproduce the *product* behavior while keeping the native
safety properties that already shipped.

Requirement IDs: **D1–D6, S1–S5, C1–C5, N1–N6, B1, B2** (all, for
characterization).

---

## 1. Today selection semantics (D1)

### 1.1 Week strip and the selected day

`screens/TodayScreen.tsx` + `utils/dateHelpers.ts`:

- `todayString = getTodayDateString()` (local `YYYY-MM-DD`, never `toISOString`).
- `selectedDate` starts at `todayString` and is *state*, so the strip can browse
  other days/weeks without changing "today".
- `getWeekDates(anchor)` → the **Mon–Sun** local dates for the week containing
  `anchor`: `monday = anchor - ((getDay() + 6) % 7)` days, then 7 consecutive
  `toDateString` values. `weekMonthLabel(weekDates)` is `"Jul 2026"` when the week
  sits in one month, `"Jun – Jul 2026"` when it straddles two (first month
  abbreviated, last month + year).
- Prev/next week = `shiftDate(selectedDate, ∓7)`; `shiftDate` builds the anchor
  through the local `Date` constructor and **clamps/settles month boundaries**
  (`setDate` overflow), so a "next week" off a month end is correct.
- Per-day schedule rows: `allJobs.filter(j => j.scheduledDate === selectedDate)`
  then `sort((a, b) => !a.scheduledStartTime ? 1 : !b.scheduledStartTime ? -1 :
  a.scheduledStartTime.localeCompare(b.scheduledStartTime))` — **unscheduled rows
  last**, otherwise code-unit comparison of `"HH:MM"` strings (which is
  chronological for zero-padded 24-hour times).
- The day has no schedule gate: a non-workday or a day with no jobs renders the
  empty-day copy, not a hidden section.

### 1.2 Earnings value

`getExpectedEarningsForDate(date)` sums `jobBillableTotal(job)` over that day's
rows — billable total (estimate + **approved** change orders), *not* collected
revenue. It is not filtered by status: a `lead` with a scheduled date still counts
toward "expected". Failure path returns `0` (never throws).

### 1.3 Stats row

Three tappable stat cards, each with its own accessibility label:

| Card | Label | Value | Sub | Tap |
|---|---|---|---|---|
| Today | `TODAY` | `formatMoney(earnings)` (accent) | `Expected` | scrolls to the schedule section |
| Overdue | `OVERDUE`, or `⚠ OVERDUE` (danger) when count > 0 | `formatMoney(overdueTotal)` else `—` | `N invoice(s)` else `All clear` | Invoices tab |
| Leads | `LEADS` (warning when > 0) | `leadCount` else `—` | `follow up` / `None pending` | Jobs tab |

While loading, each card shows a spinner instead of its value.

### 1.4 Briefing sections, caps, and "due today is not overdue"

- **Overdue Invoices** section: rows from `filterOverdueInvoices(invoices)` —
  `!isFullyPaid(inv) && daysPastDue(inv.due) >= 1`, sorted by `new Date(due)`
  ascending (oldest first). **`daysPastDue === 0` (due today) is NOT overdue**;
  due-today belongs to the `due_soon` insight. `daysPastDue` compares local
  midnights, so a bare `YYYY-MM-DD` never shifts a day (FA-039).
- **Follow Up** (leads) section: `loadLeadJobs()` — `status === "lead"`, sorted by
  `createdAt` ascending (oldest lead first).
- Caps: `INVOICE_LIMIT = 3`, `LEAD_LIMIT = 3`. The section renders
  `slice(0, LIMIT)` and, when `total - LIMIT > 0`, a **See N more →** row that
  routes to the owning tab. `extraInvoices = total - 3` (positive only), and the
  last rendered row's divider is suppressed when it is the final row.
- **Estimates awaiting response** pointer: rendered when the follow-up toggle is
  on and `selectAwaitingFollowUp(jobs, now)` is non-empty —
  `status === "estimate_sent"` with an `estimateSentDate` at least
  `FOLLOW_UP_DAYS` in the past; copy `awaitingResponseLabel(count)` =
  `"N estimate(s) awaiting response"`. It is a single row (no list), routes to
  Jobs, and stays until the customer answers or the job moves on (unlike the
  one-shot `est_` notification).
- Header: greeting (`Good morning` < 12:00, `Good afternoon` < 17:00, else
  `Good evening`) + `formatDisplayDate(todayString)` (`"Saturday, July 4"`), with
  Calendar, Search, and Settings buttons.

### 1.5 First-action hero (D5)

Derived, never persisted except the sample flag:

```
if loading || checklistState == nil || realJobs.length > 0      -> no hero
else if sampleJobs.length > 0 && realCustomers.length == 0
        && !checklistState.sampleTourDone                       -> "Explore a Sample Job"
else if sampleJobs.length == 0 && realCustomers.length == 0     -> "Add Your First Customer"
else                                                            -> "Create Your First Job"
```

`realJobs`/`realCustomers` exclude `isSampleId(…)` rows, so any real work retires
the hero. The sample hero opens the first sample job **that has a scheduled date**
(falling back to the first sample job), tracks `sample_job_opened`, and writes
`sampleTourDone` before navigating — so it is shown at most once.

---

## 2. Booking attention (D3)

### 2.1 RN selector (`utils/bookingAttention.ts`)

`selectBookingAttention(requests, jobs)` emits, in rank order
`reschedule_requested (0) → portal_change (1) → cancelled (2)`, ties broken by
`slot.date` ascending:

- `reschedule_requested`: `kind === "booked"` + a slot + `status ===
  "reschedule_requested"`; carries `convertedJobId` and the **last** customer
  `request_reschedule` history note.
- `portal_change`: `status === "portal_change_requested"` **and `!handledAt`**;
  carries `jobRef` and `details` as the note. Explicit dismissal
  (`markBookingRequestHandled` → `handledAt`) is the only clear condition.
- `cancelled`: `booked` + slot + (`status === "cancelled" || "declined"`) **while
  the converted job still holds the slot** — i.e. the job exists, is not archived,
  is not terminal, and its `scheduledDate`/`scheduledStartTime` still equal the
  request's slot. Clearing, moving, archiving, or terminal-ing the job
  self-dismisses the row.

### 2.2 Native delta (already shipped, Phase 8 `NativeBookingAttention`)

The native selector keeps the same three kinds **and adds two**:
`missingJob` (a converted-job id that no longer resolves) and
`unconvertedActive` (a booked request that never converted while its slot is
still ahead). Both exist so a booking can never silently disappear from the
owner's view; the Phase 8 tests assert them. Phase 10 renders these rows through
the same header/actions as RN's kinds and must **not** drop them to match RN.

### 2.3 Row labels and actions

- `reschedule_requested` → title `"<name> asked to reschedule"`, body
  `"<displayDate>, <timeRange>"` plus `“note”` when present; actions
  `View job` / `I've rescheduled it` (`resolve_reschedule`) / `Decline booking`
  (destructive) / `Cancel`.
- `portal_change` → title `"<name> asked to <cancel|reschedule>"` (verb from
  `portalKind`), body = the server-templated details line (or the customer's own
  words); actions `View job` / `Done` (stamps `handledAt`) / `Cancel`.
- `cancelled` → title `"<name> cancelled their booking"`, body `"<when> is free
  again. Clear or reuse the time on the job."`; actions `View job` / `OK`.
- `View job` with no `jobId` falls back to the Jobs tab (never a dead action).

Every cross-tab jump to a non-initial screen passes `initial: false` so the target
stack keeps its list beneath (`__tests__/crossTabNavigation.test.tsx`).

---

## 3. Proactive insights (S3)

`utils/todayInsights.ts` — pure, injected clock, no I/O. `selectTodayInsights(jobs,
invoices, now, schedule = SCHEDULE_DEFAULTS, extras)` concatenates eight selectors
**in this order**, and that order *is* the priority (the card renders the first
three after mute filtering):

| # | Kind | Fires when | id shape | target |
|---|---|---|---|---|
| 1 | `labor_overrun` | status ∈ {approved, scheduled, in_progress}, not archived, `laborHours > 0`, has `timeSessions`, and `overUnder ≥ 0.25 h` | `labor_overrun:<jobId>` | job |
| 2 | `low_margin_estimate` | status ∈ {lead, estimate_sent}, not archived, `estimateTotal > 0 && laborHours > 0 && laborRate > 0`, and implied margin ≤ target − 3 pts | `low_margin_estimate:<jobId>:<estimateTotal>` | job |
| 3 | `uninvoiced_complete` | `status === "complete" && !invoiceId`, not archived | `uninvoiced_complete:<jobId>` (one) / `:all` (many) | createInvoice / jobs |
| 4 | `due_soon` | `!isFullyPaid` and `daysPastDue ∈ [-2, 0]` | `due_soon:<invoiceId>` (one) / `:all` (many) | invoice / invoices |
| 5 | `open_slot` | tomorrow is a work day, not blacked out, and the largest free gap ≥ 120 min | `open_slot:<tomorrow>` | schedule (when a fitting job exists) / selectDate |
| 6 | `unscheduled_approved` | approved jobs with no date, minus the job already offered by `open_slot` | `unscheduled_approved:<jobId>` (one) / `:all` (many) | schedule / jobs |
| 7 | `maintenance_due` | a customer's last delivered job is ≥ 6 months back, with nothing in motion | `maintenance_due:<customerId>` (one) / `:all` (many) | customer / customers |
| 8 | `expense_anomaly` | MTD > 1.5 × the prior-3-full-month average, all three months non-zero, MTD ≥ $200 | `expense_anomaly:<YYYY-MM>` | money |

Constants (all frozen): `OVERRUN_MIN_HOURS = 0.25`, `MARGIN_TOLERANCE_PTS = 3`,
`DUE_SOON_DAYS = 2`, `MIN_GAP_MINUTES = 120`, `MAINTENANCE_DUE_MONTHS = 6`,
`EXPENSE_ANOMALY_MULT = 1.5`, `EXPENSE_ANOMALY_MIN_MTD = 200`. Default target
margin is `20` when `extras.targetMarginPercent` is absent.

Per-kind exclusions and text (verbatim sources for the Swift port):

- **labor_overrun** excludes completed/invoiced jobs (after completion the money
  conversation belongs to invoicing) and archived jobs. Title
  `'<title>' is <formatElapsed> over its <formatLaborHint> labor estimate`;
  `reason` names the logged time and the estimate and states it clears when the
  job is completed or the estimate updated. `coachPrompt` includes the live time,
  the estimate hours, the rate, and the quote total.
- **low_margin_estimate** computes `computeEstimateBreakdown(job)` (labor + marked
  up materials), `overheadAt = costBase × job.overhead/100`, `profit =
  estimateTotal − costBase − overheadAt`, and `impliedPct = profit / (costBase +
  overheadAt) × 100`. Only the **worst** hit is returned, with `N more under
  target` in the detail; `severe = profit < 0` switches the title to
  `'<title>' is priced below your costs and overhead`. The id embeds
  `estimateTotal`, so a reprice re-fires after a dismissal (a repriced job is a
  new question). One row, always.
- **uninvoiced_complete** detail is `formatQuote(jobBillableTotal)` + `"to bill"`
  only when the billable total is positive. One row when a single job, otherwise
  one aggregate row targeting the Jobs tab.
- **due_soon** uses `dueLabel(days)`: `today` (0), `tomorrow` (−1), else
  `in N days`. Single: `Invoice <number> (<formatMoney(balanceDue)>) is due
  <label>`; aggregate: `<formatMoney(total)> across N invoices is due within 2
  days`. The `reason` states that once past due it moves to the Overdue section.
- **open_slot** is silent when tomorrow is a non-workday or blacked out. Gap copy
  is `formatLaborHint(gap.minutes/60)` and the reason names tomorrow's date and
  the working window (`workDayStart–workDayEnd`, "at least 2 hours"). When the
  largest approved unscheduled job's `laborHours × 60 ≤ gap.minutes` fits, the
  title offers that job and the target is that job's schedule; otherwise the title
  is just the open slot and the target is `selectDate(tomorrow)`.
- **unscheduled_approved** excludes the job already offered by `open_slot` (so the
  same job cannot appear twice) and ignores archived jobs (via
  `selectUnscheduledApproved`).
- **maintenance_due** requires an active, non-archived, non-empty customer id with
  a non-empty phone **or** email; skips customers with any non-archived job in the
  active pipeline or an active recurring rule; history is the latest
  `scheduledDate` over complete/invoiced/paid jobs **joined on a real
  `customerId`** (invoice-only customers have no job history — a stated v1
  limitation); archived history still counts. `monthsBetween` is pure component
  math, never `Date`-parsing. Sorted by months descending; single row for one
  customer (first name only in `coachPrompt` — no financials, no contact details,
  no full name), otherwise `N customers haven't been serviced in 6+ months`.
  The reason ends `Snoozing hides this for 30 days.`
- **expense_anomaly** compares month-to-date (current `YYYY-MM` **up to and
  including today**, string comparison) against the average of the prior three
  full calendar months, requires all three to be non-zero, and fires strictly
  greater than `1.5 ×` the average. Title `Spending is running N% above your
  recent monthly average`, detail `<formatMoney(mtd)> so far vs <formatMoney(avg)>
  average`, reason names all three prior `YYYY-MM` values and the biggest driver
  category (`mtd − priorAvg/3` maximized, falling back to the literal `Other`
  label), and ends `Dismissing hides this for the rest of the month.` `shiftMonth`
  is pure string math (never `Date`-parsing).

Absent inputs suppress rules instead of guessing: `extras.customers ?? []`,
`extras.recurringJobs ?? []`, `extras.expenses ?? []`, and
`jobs || []` / `invoices || []` at the entry point.

### 3.1 Card presentation (S5)

`components/InsightsCard.tsx`:

- Hidden entirely unless `isSetupComplete(settings, state, notifGranted) &&
  insights.length > 0` — the checklist takes the slot first.
- Also hidden while the first-action hero (§1.5) is shown: `TodayScreen.tsx`
  renders `InsightsCard` only when `!loading && !hero` (added 2026-09-22).
- `filterMutedInsights(allInsights, mutes, now).slice(0, 3)`: **the mute filter
  runs before the top-three slice**, so muting a row promotes the next one.
- Only `MUTEABLE_KINDS = {low_margin_estimate, maintenance_due, expense_anomaly}`
  get an overflow menu; `SNOOZE_DAYS = {maintenance_due: 30}` (the other two are
  dismiss-only). The five self-resolving kinds deliberately have no dismiss
  affordance.
- Long-press opens `Why am I seeing this?` (the insight's `reason`) plus
  `Snooze 30 days` (maintenance only) and `Dismiss` (destructive), then `Cancel`.
  Rows with a `coachPrompt` also expose an `Ask coach` accessibility action and an
  inline coach button.
- Icons per kind: labor_overrun `timer`, low_margin `trending-down`,
  uninvoiced `receipt`, due_soon `alarm`, open_slot `today`,
  unscheduled_approved `calendar`, maintenance_due `build`, expense_anomaly
  `trending-up`.
- Analytics: `insight_shown` once per distinct visible id set,
  `insight_tapped`, `insight_coach_opened`, `insight_reason_viewed`,
  `insight_snoozed`, `insight_dismissed`.

---

## 4. Mute lifecycle (S4)

`utils/insightMutes.ts` — device-local, unsynced AsyncStorage key
`insightMutes`, wiped by `clearAllUserData()` (mute ids embed this account's
record ids, so a stale mute would silently hide the next account's insights).

- `makeMute(id, now, days?)`: `mutedAt = now.toISOString()`; `until =
  shiftDate(formatLocalDate(now), days)` **only when `days > 0`** — otherwise the
  mute is a permanent dismiss (no `until` key at all).
- `isMuteActive(mute, today)`: `!mute.until || mute.until > today` — a snooze is
  active **until its day arrives**, i.e. it expires at the start of `until`.
- `filterMutedInsights(insights, mutes, now)`: order-preserving; a no-op when
  there are no mutes.
- `pruneMutes(mutes, today, liveIds?)`: keeps only active mutes and, when
  `liveIds` is provided, only ids the engine can still emit.
- `muteInsight(id, now, {days?, liveIds?})`: prune, drop any existing mute for the
  same id, append the new mute — **one write** — and return the stored record.
- `loadInsightMutes()` degrades to `[]` on any read/parse failure and filters out
  entries whose `id` is not a string.

Local-frame date semantics throughout (FA-039): `until` is a local `YYYY-MM-DD`.

---

## 5. Setup checklist (D4, D5)

`utils/setupChecklist.ts` + `components/SetupChecklistCard.tsx`:

- Stored state (device-local, unsynced, key `setupChecklistState`):
  `{ dismissed?: Bool, done?: {contact|logo|rate|stripe|notifications: Bool},
  sampleTourDone?: Bool }`. Everything else is **derived**.
- `deriveSetupTasks(settings, state, notifGranted)` returns exactly five tasks in
  this order, each `{id, title, subtitle, done}`:

| id | title | subtitle | done when |
|---|---|---|---|
| contact | Add your contact details | Phone and address appear on invoices and estimates. | `phone.trim() && address.trim()` |
| logo | Add your logo | Shown on estimates, invoices and PDFs. | `settings.logoPhoto` |
| rate | Review your pricing defaults | Labor rate, markup and margin power every estimate. | `done.rate === true` (no honest derivation) |
| stripe | Connect a payment processor | Send payment links so customers can pay you online. | `done.stripe === true` **or** (`provider !== "stripe"` and that provider's key is non-blank) |
| notifications | Turn on invoice reminders | Get notified before invoices go overdue. | OS permission granted |

  Note the `contact` derivation uses **only** `phone` and `address` — `email` is
  not part of it. The card shows `N of 5` (done count) and hides itself when
  `state.dismissed` or every task is done.
- `isSetupComplete(settings, state, notifGranted)` = `dismissed || all tasks done`
  — the single shared definition the insights card also reads, so the two cards
  can never disagree.
- Writes are idempotent: `markSetupTaskDone` skips an already-recorded task,
  `markSampleTourDone` skips when already set, `dismissSetupChecklist` always
  writes `dismissed: true`. A failed write is swallowed (checklist state is a
  convenience).
- Task taps: `notifications` is handled in-card (request permission; on grant
  `setNotifGranted(true)` + `syncNotifications()`; on refusal an alert offering
  `Open device settings`); every other id navigates to its settings subpage via
  `SETTINGS_ROUTE_FOR_TASK` = contact → Business, logo → Business, rate → Pricing,
  stripe → Payments (the map is total so the compiler keeps it in sync).

---

## 6. Business snapshot (S1, S2)

`utils/businessSnapshot.ts`:

- `aggregateSnapshot(invoices, jobs, rawCustomers, now)`:
  - `thisMonthRange = [Date(y, m, 1), Date(y, m+1, 0)]`, and the previous-month
    range rolls the **year** when `m === 0` (`lastYear = y-1`, `lastMonth = 11`).
  - `revenueThisMonth` / `revenueLastMonth` come from a single
    `collectedByPeriod(invoices, [thisMonthRange, lastMonthRange])` walk (payments
    bucket by their own dates, so a legacy paid invoice lands on `paidAt ?? due`).
  - `outstandingTotal` sums `balanceDue` over **every** invoice;
    `overdueTotal`/`overdueCount` add only invoices with `balance > 0 &&
    isOverdue(inv)`. A partly-paid invoice therefore contributes to revenue *and*
    outstanding at once.
  - `activeJobsByStatus` counts only `{lead, estimate_sent, approved, scheduled,
    in_progress}` keys, **omitting** statuses with zero jobs (a partial record, not
    a zero-filled one).
  - `avgCompletedJobValue` = mean `jobBillableTotal` over `{complete, invoiced,
    paid}` jobs with a positive billable total; `0` when there are none.
  - `totalCustomers` and `topCustomers` (first 5, `{name, lifetimeSpend,
    amountOwed}`) come from `buildCustomerList(invoices, rawCustomers)` — the
    Phase 5 `NativeCustomerIdentity` rollup, not a forked sum.
- `buildTaxSnapshotBlock({invoices, expenses, trips, settings, now})` is a thin
  projection over `summarizeTaxWindow`: `periodReserve`, `ytdReserve`,
  `periodLabel` (`formatPeriodRange` → `"Jun 1 – Aug 31"`), `dueLabel`
  (`formatDeadline` → `"Sep 15"`, or `"Jan 15, 2027"` when the deadline year
  differs), `incomeRateSet`, `needsVehicleChoice`, `ratesKnown`.
- `getBusinessSnapshot()` sets `asOf = now.toISOString().split("T")[0]` (a **UTC**
  date on a UTC ISO string — the one place the snapshot deliberately uses UTC) and
  always attaches `tax`; the type keeps `tax` optional so an input failure can
  omit the block instead of zeroing it.

---

## 7. Coach (C1–C5)

`screens/ChatScreen.tsx` + `utils/aiService.ts` + `backend-workers/src/routes/aiChat.js`:

- Constants: `MAX_HISTORY = 20`, `max_tokens = 600`, Anthropic model
  `claude-sonnet-4-6` with `anthropic-version: 2023-06-01`, Groq model
  `llama-3.1-8b-instant`, temperature 0.7 (Groq only). Native defines each model
  id as one named constant, so a model change is a one-line edit reviewed on its
  own rather than a parity break.
- Provider precedence: `settings.anthropicKey` → `settings.groqKey` → backend
  proxy. The direct paths send the key only in `x-api-key` / `Authorization`;
  **no key ever appears in the system prompt or the message bodies**. Missing key
  messages: `"No AI key set. Add your Groq API key in Settings → AI Assistant."`
  and the Anthropic equivalent; the backend path requires a session and says
  `"Sign in to use the AI assistant."`.
- History window: `messages.slice(-MAX_HISTORY)` **after** appending the new user
  message, so a 21-message history sends the last 20.
- `buildSystemPrompt(settings, snapshot)` (exact wording, in order): `Assistant
  for <businessName>, <trade label>, <contactName>.` + optional ` Region:
  <region>.` + `Rates: $<laborRate||85>/hr labor, <materialMarkup||20>% materials
  markup, <overheadPercent||15>% overhead, <marginPercent||20>% margin,
  $<minimumJobFee||75> min fee. Be brief. Itemize estimates. USD only.` Then, when
  a snapshot exists, a `BUSINESS DATA (<asOf>):` block with revenue this/last
  month, outstanding (+ ` ($X overdue, N invoices)` when overdue), active jobs by
  status (`<n> <status with underscore replaced by space>`, comma-joined, `none`
  when empty), `Customers: N total` (+ `. Top: name ($X lifetime, owes $Y); …`),
  and `Avg completed job: $X.` only when positive. The tax block appends
  `Tax set-aside estimate: $<periodReserve> for <periodLabel> (set aside by
  <dueLabel>); $<ytdReserve> year to date.` plus the caveat fragments
  ` Income-tax rate not set — figure is SE tax only.` and/or ` Vehicle deduction
  method not chosen.`, then the hard constraint sentence: `You may cite these as
  set-aside guidance only — for filing, deduction elections, eligibility, or
  business-entity questions, decline and refer the user to a tax professional.`
- Quick prompts (`getQuickPrompts(snapshot)`, four cards): "How's my month?",
  "Who owes me?" (falls back to a pricing-estimate prompt), then a branch on
  `overdueCount > 0` → "Follow up on overdue" with the live count/amount, else
  "Write an estimate", then a branch on `avgCompletedJobValue > 0` → "Increase job
  value" with the live average, else "Price a job".
- Errors render as a distinct assistant bubble with `isError` and the text
  `Something went wrong: <provider message>` (the RN string is literally
  "Something"), and are reported through `reportError(err, {context: 'aiChat'})`.
- Input: `maxLength = 2000`, send disabled while empty or in flight, an in-flight
  typing bubble, `New chat` in the header when the transcript is non-empty, and
  `send` ignores a second submit while sending.
- Insight handoff (C5): a Today `Ask coach` tap passes `initialPrompt`; the screen
  fills the input **once**, clears the param, and marks the next send as
  `source: 'insight_prefill'`. Nothing is auto-sent.

---

## 8. Markdown-lite (C4)

`utils/chatMarkdown.ts` `formatChatText(raw)`, in this exact order:

1. Fenced code blocks: strip `^```[^\n]*\n?` lines (multiline), keeping content.
2. Per line, indent-preserving: `^(\s*)#{1,6}\s+` → indent; `^(\s*)[-*]\s+` →
   `indent + "• "`; `^(\s*)>\s+` → indent.
3. Paired emphasis with the `(?!\w)` closing guard, in order:
   `***x***` → `x`, `**x**` → `x`, `*x*` (content must start non-space, non-`*`)
   → `x`, `__x__` → `x`. Single underscores are deliberately **not** stripped.
4. Inline code spans `` `x` `` → `x`.

The preserved cases the oracle pins: `2*4 and 2*6` stays intact (the closing `*`
is glued to a digit), spaced math (`2 * 4 * 6`) stays intact, and `snake_case`
stays intact.

---

## 9. Notifications (N1–N6)

`utils/notifications.ts` + `utils/reviewRequest.ts` + `utils/estimateFollowUps.ts`
+ `utils/appointmentMessages.ts`, mirrored by the native coordinator in
`N/NativeEstimateFollowUpNotifications.swift`.

### 9.1 Namespaces and identifier formats

| Namespace | Identifier | `data.type` | Producer |
|---|---|---|---|
| `inv_` | `inv_<invoiceId>_<days>d` | `overdue_invoice` / `overdue_outreach` | invoice dunning sweep |
| `appt_` | `appt_<jobId>` | `appointment_confirm` | appointment selector |
| `rinv_` | `rinv_<ruleId>` | `recurring_invoice` | active recurring-invoice rules |
| `est_` | `est_<jobId>` | `estimate_follow_up` | estimate follow-up selector |
| `review_` | `review_<…>` (built by `buildReviewRequestNotification`) | `review_request` | pending review-request records |

The native `NativeNotificationNamespace` already owns all five prefixes and the
same `payloadType` strings; `overdue_outreach` is the tap-to-send variant.

### 9.2 Fire dates (local frame, 9:00 a.m.)

- `inv_`: `parseLocalDate(due)` (defensive: strict ISO → local midnight; anything
  else falls back to the platform parser), `+ rule.days`, then `setHours(9,0,0,0)`.
  Skip when the result is not finite or is not in the future.
- `rinv_`: `new Date(rule.nextDueDate + "T00:00:00")` then `setHours(9,0,0,0)` —
  deliberately the same local construction as the `inv_` branch; the two must not
  drift (both were fixed together on 2026-08-01 after a UTC-midnight bug fired a
  day early).
- `appt_` / `est_`: fire dates come from the pure selectors; the `est_` nudge is
  `FOLLOW_UP_DAYS` after the estimate was sent, 9:00 a.m. local.
- `review_`: the delay is re-derived from the stored record's `scheduledAt` plus
  `reviewRequestDelaySeconds(settings.reviewRequestDelayHours)`, so a rebuild
  never moves the fire instant.

### 9.3 Dunning exclusions (N2)

An invoice is scheduled only when it is **not fully paid**, has a non-empty `due`,
its linked job is dunning-eligible (`isJobDunningEligible`, which excludes
pre-completion deposit invoices), and it does **not** carry `importBatchId` (kept
in parity with `backend-workers/lib/selectInvoicesToRemind.js`: an imported
invoice never triggers a reminder, local or emailed). The auto-outreach body
switch replaces title/body and adds `daysPastDue` to the payload.

### 9.4 Review one-shot rebuild rule (N4, B2)

The review namespace is *not* derived by the sweep. `scheduleReviewRequest` arms a
one-shot at job completion; the sweep's cancel-all would eat it, and the pending
record's guard would then refuse to re-arm. `syncNotifications` therefore
rebuilds `review_` from the pending records (sentAt null) using
`getPendingReviewRequests()` joined to the job map — a record whose job is gone is
dropped, and a fire instant already in the past is never re-nagged late. Toggle
off = not rebuilt = pending nudges stop.

### 9.5 Shared 60-request cap and priority (N5)

RN walks `inv_` → `appt_` → `rinv_` → `est_` → `review_` and stops at 60.
The **native** coordinator (already shipped) deliberately orders
`est_ (0) → appt_ (1) → review_ (2) → inv_ (3) → rinv_ (4)`, accounts for
**foreign** pending requests first (they consume budget before any owned namespace
schedules), and never removes a foreign identifier. Phase 10 keeps the native
order: it is a documented, intentional difference that preserves the Phase 6
`est_`-first guarantee. Each family has per-namespace cleanup, and a family being
toggled off removes only its own pending requests.

### 9.6 Tap routing (N6)

`NativeNotificationRoute` decodes payload → typed destination
(`estimateFollowUp(jobID:)`, `appointmentConfirm(jobID:)`, `reviewRequest(jobID:)`,
`invoiceReminder(invoiceID:daysPastDue:opensOutreach:)`,
`recurringInvoiceReminder(ruleID:)`) and the app routes only to records that still
exist — a missing or archived record fails closed (no invented destination).

### 9.7 Permission prompt (N1)

`promptForInvoiceReminders()` is one-shot and owner-bound: the flag
(`invoiceReminderPromptShown`) is **stamped before** showing, so a dismissed
prompt never repeats; the alert is skipped entirely when the OS status is already
settled (`granted`/`denied`); on `Turn on` a grant calls `syncNotifications()`.
The flag is on the sign-out wipe list. `setupNotifications()` creates the Android
channels (`invoice-reminders`, `review-requests`, `appointment-reminders`);
nothing registers `UNNotificationCategory` today (native gap — see §13).

---

## 10. Duplicate prevention across launches (B2)

- **Coordinator-owned families**: `cancelOwnedThenReschedule` removes exactly the
  coordinator's namespaces and re-plans in one pass, so a relaunch cannot stack a
  second copy of the same `identifier` (identifiers are deterministic), and a
  scheduling failure leaves the previously-scheduled set untouched.
- **Review one-shot**: the pending record's `scheduledAt` is the single source of
  truth; the arm path refuses to re-arm while a pending record exists, and the
  rebuild path recomputes the same instant from that record.
- **Cross-launch duplicates** are prevented by determinism rather than by a
  remembered set: the same canonical input must produce the same identifier set
  on every pass (the 10.14 idempotence proof reconciles twice and compares the
  pending set).

---

## 11. Parity oracle index

| Requirement | Oracle test(s) | Oracle source(s) |
|---|---|---|
| D1 day/week + stats | `__tests__/TodayScreenSettingsGear.test.tsx`, `__tests__/bookingAttention.test.ts` | `screens/TodayScreen.tsx`, `utils/dateHelpers.ts`, `utils/storage/dailyOps.ts` |
| D2 caps + follow-ups | `__tests__/TodayScreenSettingsGear.test.tsx` | `screens/TodayScreen.tsx`, `utils/estimateFollowUps.ts` |
| D3 attention | `__tests__/bookingAttention.test.ts`, `__tests__/bookingNotify.test.js` | `utils/bookingAttention.ts`, `N/Domain/NativeBookingAttention.swift` |
| D4/D5 checklist + hero | `__tests__/setupChecklist.test.js` | `utils/setupChecklist.ts`, `components/SetupChecklistCard.tsx` |
| D6 routing | `__tests__/crossTabNavigation.test.tsx`, `__tests__/bookingAttention.test.ts` | `screens/TodayScreen.tsx`, `N/NativeGlobalSearch.swift` |
| S1/S2 snapshot | `__tests__/businessSnapshot.test.js`, `__tests__/estimateSnapshot.test.js` | `utils/businessSnapshot.ts`, `utils/customerList.ts`, `utils/taxEstimate.ts` |
| S3 insights | `__tests__/todayInsights.test.ts` | `utils/todayInsights.ts` |
| S4 mutes | `__tests__/insightMutes.test.ts` | `utils/insightMutes.ts` |
| S5 card | `__tests__/todayInsights.test.ts` (kinds/order) | `components/InsightsCard.tsx` |
| C1–C4 coach | `__tests__/chatMarkdown.test.ts`, `__tests__/estimateSnapshot.test.js` | `screens/ChatScreen.tsx`, `utils/aiService.ts`, `backend-workers/src/routes/aiChat.js` |
| N1 permission/categories | `__tests__/settingsNotificationsScreen.test.tsx`, `__tests__/notifications.test.js` | `utils/notifications.ts`, `screens/SettingsNotificationsScreen.tsx` |
| N2 dunning | `__tests__/notifications.test.js`, `__tests__/reminderLogic.test.js`, `__tests__/reminderEmailHardening.test.js` | `utils/notifications.ts`, `utils/jobStatus.ts`, `backend-workers/lib/selectInvoicesToRemind.js` |
| N3/N4 appointment + review | `__tests__/notifications.test.js` | `utils/appointmentMessages.ts`, `utils/reviewRequest.ts` |
| N5/N6 cap + routing | `__tests__/notifications.test.js` | `utils/notifications.ts`, `N/NativeEstimateFollowUpNotifications.swift` |
| B1/B2 background | `__tests__/reminderLogic.test.js` (scheduling idempotence) | `N/NativeBackgroundRefresh.swift`, RN `backgroundRefresh.ts` |

---

## 12. Contract decision table

| # | Contract | Decision | Basis |
|---|---|---|---|
| 1 | Local-frame `YYYY-MM-DD` everywhere except `asOf` | Chosen | `dateHelpers.ts`, `insightMutes.ts`, FA-039 |
| 2 | Insight priority = rule order; top-3 **after** mute filter | Chosen | `selectTodayInsights`, `InsightsCard` |
| 3 | Insight ids are stable and kind-scoped (`kind:recordId` / `:all` / `:date` / `:period`), low-margin embeds `estimateTotal` | Chosen | `todayInsights.ts` |
| 4 | Insight mutes/snoozes are device-local, owner-bound, wiped at the account boundary | Chosen | `insightMutes.ts`, `lifecycle.ts` |
| 5 | Setup completion is derived; only `rate`/`stripe`/dismissal/sample-tour are stored | Chosen | `setupChecklist.ts` |
| 6 | `isSetupComplete` is the one shared gate for both Today cards | Chosen | `setupChecklist.ts` doc |
| 7 | Snapshot omits zero-valued statuses rather than zero-filling | Chosen | `aggregateSnapshot` |
| 8 | Tax block is absent on input failure, never zeroed | Chosen | `BusinessSnapshot.tax?:` |
| 9 | Coach provider precedence anthropic → groq → backend; keys never enter prompts | Chosen | `ChatScreen.send`, `aiService.ts` |
| 10 | `MAX_HISTORY = 20`, `max_tokens = 600`, input `maxLength = 2000` | Chosen | `aiService.ts`, `ChatScreen.tsx` |
| 11 | Markdown-lite reproduces RN byte-for-byte incl. the `2*4` / spaced-math / `snake_case` survivors | Chosen | `chatMarkdown.ts` |
| 12 | Five notification namespaces with deterministic identifiers and per-family cleanup | Chosen | `notifications.ts`, native coordinator |
| 13 | Native scheduling priority stays `est_ → appt_ → review_ → inv_ → rinv_` with foreign families first | Chosen (recorded native difference) | `NativeEstimateFollowUpNotifications.swift` |
| 14 | Native keeps `missingJob`/`unconvertedActive` attention rows | Chosen (recorded native addition) | Phase 8 `NativeBookingAttention` |
| 15 | `UNNotificationCategory` registration | Blocked on 10.05 (none exists today) | grep: no `setNotificationCategories` |
| 16 | Live AI providers, device permission prompts, background refresh on device | Blocked (Phase 12 evidence) | plan §1 verification deferral |
| 17 | Native mute/checklist stores fail closed on unreadable data (RN degrades to `[]`); the insights card then shows only the five non-muteable kinds and the checklist stays hidden | Chosen (recorded native difference, added 2026-09-22) | 10.03 execution log; plan 10.12 step 5 |
| 18 | Insights card is hidden while the first-action hero is shown | Chosen (added 2026-09-22) | `TodayScreen.tsx` `!loading && !hero` |

---

## 13. Native interface / type handoff for independent tasks

Pure/service lane (no shared-file edits):

- 10.01 `N/Domain/NativeBusinessSnapshot.swift` — `aggregateSnapshot`,
  `buildTaxSnapshotBlock`, `NativeBusinessSnapshot` (+ optional tax block).
  Consumes `NativeCashBasis.collectedByPeriod`, `PaymentLedger`,
  `NativeCustomerIdentity` rollups, `TaxEstimateEngine`.
- 10.02 `N/Domain/NativeTodayInsights.swift` — `NativeTodayInsight`
  (`kind`/`id`/`title`/`detail`/`target`/`reason`/`coachPrompt`) and the eight
  selectors, reusing `NativeTimeTracking`, `PricingEngine`,
  `NativeCalendar`/`NativeSchedule`/`NativeAvailability`, `NativeChangeOrders`.
- 10.03 `N/Domain/NativeInsightMutes.swift`, `N/NativeInsightMuteStore.swift`,
  `N/Domain/NativeSetupChecklist.swift`, `N/NativeSetupChecklistStore.swift` — policy +
  exact-owner stores mirroring `NativeReviewRequestStore`, plus seed adoption for
  `insightMutes` / `setupChecklistState` / `invoiceReminderPromptShown`.
- 10.04 `N/Domain/NativeTodayBriefing.swift` — week strip, day schedule, stats,
  capped sections, awaiting-estimate row, greeting header, typed
  `NativeTodayDestination`, hero derivation, and the attention row model
  (unchanged from `NativeBookingAttention`).
- 10.10 `N/NativeCoachTransport.swift` (provider routing, typed errors),
  `N/Domain/NativeCoachPrompt.swift` (`buildSystemPrompt`),
  `N/Domain/NativeChatMarkdown.swift` (`formatChatText`), and
  `N/Domain/NativeCoachQuickPrompts.swift` (quick-prompt branches). The insight
  prefill contract is implemented in 10.13's UI.

Integration lane (serialized shared files): 10.11 `N/TodayView.swift`, 10.12
checklist/hero/insights cards, 10.13 `N/CoachView.swift` + prefill;
notification lane 10.05–10.09 (settings surface, categories, background refresh).

Existing code reused, not duplicated: the notification coordinator and
namespaces, `NativeAppointmentNotifications`, `NativeInvoiceNotifications`,
`NativeReviewRequests`/`NativeReviewRequestStore`, `NativeBookingAttention`,
`NativeBackgroundRefresh`, `NativeGlobalSearch` one-shot routing,
`NativeInteractionState`, `PaymentLedger`/`TaxEstimateEngine`/`PricingEngine`.

---

## 14. Source-discovered gaps (confirming the plan's list)

1. `N/TodayView.swift` is a prototype: no week strip or day selection, no stats
   row, no hero, no checklist, no insights card, no overdue/lead briefing, no
   route-planning action, and one summary button instead of attention rows.
   Confirmed.
2. `N/CoachView.swift` is a prototype: backend-only transport, a one-line system
   prompt, three static prompts, no snapshot, no provider routing, no
   markdown-lite, no typed error bubble, no history/token limits, no prefill.
   Confirmed.
3. No Swift equivalents of `todayInsights.ts`, `businessSnapshot.ts`,
   `insightMutes.ts`, `setupChecklist.ts`, or `chatMarkdown.ts`. Confirmed.
4. No insight-mute or setup-checklist live store; `NativeTypedAccountState`
   parses `setupChecklistState`, `insightMutes`, and
   `invoiceReminderPromptShown` but nothing adopts them. Confirmed.
5. No `setNotificationCategories` call and no one-shot contextual reminder
   prompt. Confirmed.
6. The background task does not reconcile notifications or refresh derived state
   after a pass. Confirmed. *(Revised 2026-09-22: the schedule key should cover
   only notification-selector inputs; insight/setup state does not change any
   scheduled item and must not be folded in. See plan 10.08/10.09.)*

---

## 15. Oracle verification evidence (actual results)

Run from the repository root with `TZ=America/Phoenix` (a west-of-UTC zone, so the
UTC-parse regressions FA-039 guards would surface):

```sh
npx jest --runInBand --runTestsByPath __tests__/todayInsights.test.ts \
  __tests__/businessSnapshot.test.js __tests__/insightMutes.test.ts \
  __tests__/setupChecklist.test.js __tests__/bookingAttention.test.ts \
  __tests__/bookingNotify.test.js __tests__/TodayScreenSettingsGear.test.tsx
# -> 7 suites, 110 tests, all passing

npx jest --runInBand --runTestsByPath __tests__/chatMarkdown.test.ts \
  __tests__/estimateSnapshot.test.js __tests__/settingsNotificationsScreen.test.tsx \
  __tests__/notifications.test.js __tests__/reminderLogic.test.js \
  __tests__/reminderEmailHardening.test.js
# -> 6 suites, 123 tests, all passing
```

13 suites / 233 tests, all passing. No oracle file was modified, added, or
skipped.

Native foundations still green at the time of writing (Phase 6–8 suites):
`run-notification-coordinator-tests`, `run-estimate-follow-up-notification-tests`,
`run-appointment-notification-tests`, `run-invoice-notification-tests`,
`run-review-request-tests`, `run-background-refresh-tests`,
`run-booking-attention-tests`, `run-global-search-tests`,
`run-interaction-state-tests`, `run-store-integration-tests`.

**Blockers (named, non-blocking for the pure lane):** live AI providers and
device permission/background evidence are Phase 12 rows; `UNNotificationCategory`
registration is 10.05's implementation work; the native notification priority and
the two extra attention kinds are recorded intentional differences, not defects.

### 10.00 execution ledger

| Field | Value |
|---|---|
| Status | **Code complete / no implementation file changed** |
| Files | `docs/native-phase-10-today-coach-notifications-contract-decisions.md` (new) |
| Commands | the two `npx jest` groups above |
| Results | 13 suites / 233 tests passing; four RN oracle groups read in full |
| Blockers | Phase 12 device/live-provider evidence only |
| Handoff | §12 decision table + §13 interface handoff; 10.01/10.02/10.03/10.04/10.10 are next-ready |

---

## 16. Task 10.14 — cross-client and hosted-contract qualification (evidence)

**Status:** Code complete. New file: `native/Phase10QualificationTests/main.swift`
+ `native/run-phase10-qualification-tests.sh` (not registered in
`run-all-domain-tests.sh` — ruling R6, deferred to 10.15). No implementation
file was changed except the three recorded-deviation doc updates below.

One shared canonical fixture (Tue Aug 4 2026, 10:00 local — the same clock as
10.02's `TodayInsightsTests` oracle fixture) is threaded through the business
snapshot, insights, setup checklist, coach prompt/quick-prompts/markdown, and
the full five-namespace notification set, proving: (a) each engine is
deterministic on the same input, (b) the seams agree (the snapshot the coach
cites is the snapshot Today derives; the same `isSetupComplete` gate the hero
and the insights card both read), and (c) reconciling notifications twice
from the same fixture yields an identical pending set (B2's idempotent-
scheduling proof) while a foreign (non-owned) pending request survives both
passes untouched (N5).

Insight kinds not re-exercised in the new fixture (`labor_overrun`,
`open_slot`, `unscheduled_approved`, `maintenance_due`) are already pinned
against the RN oracle exhaustively in `TodayInsightsTests` (task 10.02);
10.14 references that coverage rather than duplicating it, per the brief.

### 16.1 Recorded deviations (evidence)

1. **`weekMonthLabel` / FA-039 (task 10.04).** RN's `utils/dateHelpers.ts`
   `weekMonthLabel` parses `weekDates[0]`/`weekDates[6]` with `new Date(...)`
   — a UTC parse of a date-only string. Probed live under
   `TZ=America/Phoenix` (`npx jest` scratch probe against the real function,
   transcript below) for the week `2026-06-01 … 2026-06-07` (entirely inside
   June): **RN returns `"May – Jun 2026"`** — wrong, since the week never
   leaves June. Native's `NativeTodayBriefing.monthLabel(for:)` walks local
   date components (never `Date`-parses) and correctly returns `"Jun 2026"`.
   `Phase10QualificationTests` asserts both the correct native value and that
   it differs from the RN oracle's value for this exact fixture (§5 of that
   file). Probe transcript (`TZ=America/Phoenix npx jest --runInBand
   --runTestsByPath __tests__/zzTmp1014Probe.test.ts`, scratch file, removed
   after use):
   ```
   WEEK_DATES ["2026-06-01","2026-06-02","2026-06-03","2026-06-04","2026-06-05","2026-06-06","2026-06-07"]
   WEEK_LABEL May – Jun 2026
   TZ America/Phoenix 420
   ```
2. **`Math.round` vs. Swift `.rounded()` (task 10.02).** Same probe, `Math.round`
   on `[0.5, 1.5, 2.5, -0.5, -1.5, -2.5]`:
   ```
   MATH_ROUND 0.5 1
   MATH_ROUND 1.5 2
   MATH_ROUND 2.5 3
   MATH_ROUND -0.5 -0
   MATH_ROUND -1.5 -1
   MATH_ROUND -2.5 -2
   ```
   RN's `Math.round` is round-half-towards-positive-infinity; Swift's default
   `.rounded()` is round-half-away-from-zero. They **agree for every positive
   half** (both give `1, 2, 3`) and **diverge for every negative half**
   (`-0/-1/-2` vs. `-1/-2/-3`). `NativeTodayInsights.swift`'s two `.rounded()`
   call sites (`pointsUnder` in `selectLowMarginEstimates`, `pct` in
   `selectExpenseAnomaly`) are both guarded to only ever see non-negative
   inputs by construction (the low-margin rule only fires below target; the
   anomaly rule only fires when `mtd > avg`), so this divergence is a proven
   **latent** property of the `Int(_:).rounded())` pattern, not an observed
   output difference anywhere in the current Phase 10 surface —
   `Phase10QualificationTests` §6 asserts the divergence table directly so a
   future call site that ever applies this pattern to a signed delta is
   flagged by this recorded evidence rather than rediscovered.
3. **Setup checklist `rate` task completion trigger (task 10.12).** RN's
   `screens/SettingsPricingScreen.tsx` marks the `rate` setup task done on
   **save**. Native's `PricingDefaultsSettings` in
   `native/TradeReadyNative/SettingsView.swift` binds every field
   continuously (no discrete "save" action exists in the SwiftUI form), so it
   instead marks the task done in `.onDisappear` — leaving the Pricing
   Defaults page stands in for "reviewed the pricing defaults" rather than
   "saved a change." Intentional, not byte-for-byte parity. Recorded in
   `docs/native-parity-matrix.md`'s "Setup checklist" row (this task) and
   asserted (idempotence of `markingDone`) in `Phase10QualificationTests` §3.
4. **Coach input length: grapheme clusters vs. UTF-16 code units (task
   10.13).** RN's `TextInput maxLength={2000}` counts UTF-16 code units;
   `NativeCoachInputLimit.clamp` counts Swift grapheme clusters
   (`String.count`). No RN oracle test pins this exact limit (not in the
   brief's verification-commands list), so the divergence is accepted per
   the 10.13 report. `Phase10QualificationTests` §4 demonstrates it directly:
   a string of `maxLength` family-emoji grapheme clusters is a no-op under
   native's `clamp` (exactly at the grapheme limit) while already exceeding
   `maxLength` UTF-16 code units — RN's `TextInput` would have clamped it
   shorter already.

### 16.2 Determinism and idempotency proofs

- **Deterministic daily surface:** the same fixture run twice through
  `NativeBusinessSnapshotEngine.aggregate` and `NativeTodayInsights.select`
  produces `Equatable`-equal results both times (`Phase10QualificationTests`
  §1, §2).
- **Idempotent scheduling (B2):** a coordinator wired with all five owned
  namespaces (`est_`, `appt_`, `review_`, `inv_`, `rinv_`) reconciled twice
  from the identical fixture produces the identical pending-identifier set
  (no duplicate identifiers, no churn on a foreign `expo_legacy_x` pending
  request left untouched by both passes) — `Phase10QualificationTests` §7.
  Tap-routing (N6) round-trips every owned route through
  `NativeNotificationRoute.decode(userInfo:)` and fails closed on an unknown
  or missing `type`.

### 16.3 Commands and results

```sh
TZ=America/Phoenix npm test -- --runInBand --runTestsByPath __tests__/todayInsights.test.ts __tests__/businessSnapshot.test.js __tests__/insightMutes.test.ts __tests__/setupChecklist.test.js __tests__/bookingAttention.test.ts __tests__/bookingNotify.test.js __tests__/TodayScreenSettingsGear.test.tsx __tests__/crossTabNavigation.test.tsx
# -> 8 suites, 112 tests, all passing

TZ=America/Phoenix npm test -- --runInBand --runTestsByPath __tests__/chatMarkdown.test.ts __tests__/estimateSnapshot.test.js __tests__/settingsNotificationsScreen.test.tsx
# -> 3 suites, 22 tests, all passing

TZ=America/Phoenix npm test -- --runInBand --runTestsByPath __tests__/notifications.test.js __tests__/reminderLogic.test.js __tests__/reminderEmailHardening.test.js __tests__/reviewRequest.test.js __tests__/ReviewRequestScreen.test.tsx
# -> 5 suites, 121 tests, all passing

TZ=America/Phoenix sh native/run-phase10-qualification-tests.sh
# -> "Phase 10 qualification tests passed" (run twice, both clean)

TZ=America/Phoenix sh native/run-all-domain-tests.sh
# -> see task-10.14-report.md for the full result (every existing Swift
#    host-test runner plus the backend-workers node --test suite)
```

**Blockers (named, unchanged):** device, permission, live-AI-provider, and
background-delivery evidence remain deferred to Phase 12 per the roadmap's
2026-09-16 verification-deferral decision — nothing in this task claims it.

### 10.14 execution ledger

| Field | Value |
|---|---|
| Status | **Code complete** |
| Files | `native/Phase10QualificationTests/main.swift` (new), `native/run-phase10-qualification-tests.sh` (new, not registered — 10.15 owns that), this doc (§16), `docs/native-parity-matrix.md` (Setup checklist / Proactive insights rows), `docs/native-phase-10-implementation-plan.md` (§6 row flip + this §7 entry) |
| Commands | §16.3 above |
| Results | 16 RN-oracle suites / 255 tests passing (unchanged, pre-existing); new `run-phase10-qualification-tests.sh` passing (run twice); full `run-all-domain-tests.sh` aggregate — see report |
| Deviations recorded | §16.1 (weekMonthLabel/FA-039, Math.round vs. .rounded(), rate onDisappear, grapheme vs. UTF-16 input limit) |
| Blockers | Phase 12 device/permission/live-AI/background-delivery evidence only |
| Handoff | 10.15 (aggregate verification + closeout) is next-ready |
