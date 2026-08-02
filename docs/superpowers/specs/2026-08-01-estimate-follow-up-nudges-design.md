# Estimate Follow-Up Nudges — Design

**Date:** 2026-08-01
**Status:** Approved by owner (chat, 2026-08-01); spec pending owner review
**Scope:** new utils/estimateFollowUps.ts, new EstimateFollowUpScreen, syncNotifications est_ branch, Job/Settings shape additions, SendEstimateScreen + estimateApprovalLink + JobDetail stamps, Today row, Settings toggle

## Problem

A job that reaches `estimate_sent` gets no further attention from the app. If
the customer never responds, nothing nudges the tradesperson to follow up — the
estimate silently rots in the Jobs list. The estimate-approval loop (2026-07-30)
closed the customer side (Approve/Decline on a hosted page); this feature closes
the tradesperson side. Following up on silent estimates is one of the
highest-conversion actions a solo operator can take, and the app already owns
every piece of infrastructure needed: the local-notification sweep, tap routing,
message composers with outcome tracking, and a fresh template for a
"prefilled follow-up" screen (ReviewRequestScreen, 2026-07-31).

## Decisions (owner-approved)

1. **Tap action = prefilled composer.** Tapping the nudge opens a new
   `EstimateFollowUpScreen` with an editable, prefilled follow-up message and
   Send SMS / Send Email buttons. Tap-to-send only — nothing is ever auto-sent.
   (Chosen over "open JobDetail" and "resend the estimate".)
2. **Timing = one-shot, 3 days, 9:00am local.** A single nudge per estimate,
   3 days after it was sent. (Chosen over escalating 3d+7d and over
   configurable Settings rules.)
3. **Default ON, with a Settings toggle.** Matches the overdue-invoice reminder
   precedent (private nudge to the tradesperson; nothing customer-facing is
   sent). (Chosen over opt-in.)
4. **Notification + Today row.** Besides the one-shot notification, the Today
   screen shows a persistent "N estimate(s) awaiting response" row while any
   estimate has been silent ≥ 3 days, because a dismissed notification would
   otherwise leave no trace. (Chosen over notification-only.)
5. **Implementation approach A:** dedicated mini-screen mirroring
   ReviewRequestScreen. (Chosen over extending the invoice-coupled
   OutreachScreen and over composing directly from the notification tap.)

## Data-shape changes (owner approval carried by this spec)

Both are additive optional fields on JSON-blob-synced records — no backend
migration; follow the safe-shape-change recipe in `tradeready-storage-and-sync`
during planning.

- **`Job.estimateSentAt?: DateString`** — local-frame `"YYYY-MM-DD"` stamp of
  the most recent estimate send. Written at all THREE send paths:
  1. `SendEstimateScreen.markAsSent()` (manual "Mark as sent" — today writes no
     timestamp at all);
  2. `utils/estimateApprovalLink.ts` (~line 71) where the approval-link send
     sets `status: "estimate_sent"`;
  3. `JobDetailScreen` (~line 755) where the re-send path resets a decided
     approval back to `estimate_sent`.
  Re-stamping on re-send is deliberate: it re-arms the one-shot nudge.
- **`Settings.estimateFollowUpsEnabled?: boolean`** — Settings toggle.
  `defaultSettings()` gets `estimateFollowUpsEnabled: true`. **Absent means ON**
  (`!== false` check) so existing users get the feature after OTA without a
  settings write. ⚠️ This is the REVERSE of `appointmentRemindersEnabled`
  (absent → false, opt-in); the models.ts doc comment must state this loudly so
  the two are never "unified".

## Design

### A. New utility: `utils/estimateFollowUps.ts`

Pure functions, no I/O, born-typed — mirrors `selectAppointmentReminders`.

- `estimateSentDate(job: Job): Date | null`
  Resolves when the estimate was sent: `job.estimateSentAt` if present, else
  `job.approval?.sentAt` (backend ISO timestamp — legacy link-sends), else
  `null`. Parse with `parseLocalDate` (utils/moneyUtils.ts), the same defensive
  local-frame parser the inv_ branch uses: strict `"YYYY-MM-DD"` parses as
  local midnight; a full timestamp falls back to `new Date(raw)`.
  `null` (legacy manual sends) → job never nudges, silently. No surprise
  notifications after the OTA.
- `selectEstimateFollowUps(jobs: Job[], now: Date): EstimateFollowUpReminder[]`
  where the reminder is `{ jobId, customerName, jobTitle, fireDate }`.
  A job qualifies iff: `status === "estimate_sent"`, `estimateSentDate` is
  non-null, and `fireDate` (sent date + 3 days, `setHours(9,0,0,0)` — same
  local-frame construction as the inv_/rinv_ branches, FA-039 rule) is in the
  future relative to `now`. Past fire dates are excluded here AND re-checked by
  the sweep's `secondsUntil <= 0` guard — this is what makes the nudge
  one-shot: once fired (or once 3+ days old at ship time), no re-sweep ever
  re-creates it.
- `selectAwaitingFollowUp(jobs: Job[], now: Date): Job[]`
  For the Today row: jobs in `estimate_sent` whose `estimateSentDate` is
  non-null and ≥ 3 days before `now`. (The two selectors are NOT a strict
  partition: on day 3 before 9:00am a job is in both — the Today row already
  shows it while the notification is still pending. Harmless and correct;
  don't "fix" it.)
- `FOLLOW_UP_DAYS = 3` exported constant — single home for the number.
- `buildFollowUpMessage(job: Job, customerFirstName: string): string`
  The default template, with `formatQuote(job.estimateTotal)` for the amount
  (estimate headline → quote formatter, per the utils/format.ts mapping rule):

  > Hi {firstName}, just checking in on the estimate I sent over for
  > {jobTitle} ({amount}). Happy to answer any questions — want me to get you
  > on the schedule?

### B. syncNotifications branch (utils/notifications.ts)

New branch after the rinv_ loop, same shape:

- Gate: `settings.estimateFollowUpsEnabled !== false`.
- Iterate `selectEstimateFollowUps(jobs, now)`; shared 60-notification cap
  (est_ runs last — invoice dunning and appointments keep priority).
- Identifier: `est_${jobId}` (fourth namespace beside inv_/appt_/rinv_).
- Content: title `Estimate follow-up — {customerName}`, body
  `Estimate for "{jobTitle}" sent {FOLLOW_UP_DAYS} days ago with no response.
  Tap to follow up.`, data `{ type: "estimate_follow_up", jobId }`.
- No new Android channel (matches rinv_; setupNotifications untouched).
- Auto-cancel is free: `saveJobs` already calls `syncNotifications()`, and the
  sweep is cancel-all-and-re-derive — a job advancing to `approved`/`declined`
  (reconciler or manual) simply stops matching the selector.

### C. EstimateFollowUpScreen (screens/EstimateFollowUpScreen.tsx)

Mirrors ReviewRequestScreen's structure and conventions:

- Route: `EstimateFollowUp`, params `{ jobId: string, source: "notification" |
  "job_detail" }`. Registered in the Jobs stack (reached from the notification
  tap and from JobDetail — register in exactly the stacks it's reached from).
- Loads job + `resolveCustomer` (LIVE customer record drives contact info — the
  review-request lesson) + settings.
- Shows: customer name, job title, `formatQuote` amount, "sent N days ago".
- Editable multiline message input prefilled via `buildFollowUpMessage`.
- Actions: **Send SMS** / **Send Email** via `composeSMSWithOutcome` /
  `composeEmailWithOutcome` (cancelling the OS composer does NOT count as
  sent), plus **Copy message** (expo-clipboard, same as ReviewRequest).
  Missing phone/email handled by the compose helpers' built-in alerts.
- Sending does NOT change job status — following up is not a pipeline event;
  the job stays `estimate_sent` until the customer decides.
- **No persisted "followed up" state in v1.** One-shot semantics come from the
  fire-date-in-past mechanism (§A), not from a record.

### D. Tap routing (App.tsx)

New case in the existing `addNotificationResponseReceivedListener` block:
`data.type === "estimate_follow_up" && data.jobId` → `navigate("Main", {
screen: "Jobs", params: { screen: "EstimateFollowUp", params: { jobId,
source: "notification" } } })`, guarded by `sessionRef`/`navigationRef.isReady()`
like the four existing cases. Track `estimate_follow_up_opened`.

### E. JobDetail action (reachability)

When `job.status === "estimate_sent"`, JobDetail shows a **Send follow-up**
action navigating to `EstimateFollowUp` with `source: "job_detail"`. This keeps
the screen reachable without the notification (the shipped-but-unreachable
lesson from the estimate-approval loop) and serves the Today-row path.

### F. Today row (screens/TodayScreen.tsx)

- `selectAwaitingFollowUp(jobs, now)`; render only when count > 0 AND
  `estimateFollowUpsEnabled !== false` (one toggle governs notification + row).
- Copy: `1 estimate awaiting response` / `N estimates awaiting response`.
- Tap → Jobs tab (JobList). Styling follows Today's existing row/card patterns
  (Blueprint system; Ionicons, no emoji).

### G. Settings toggle (screens/SettingsScreen.tsx)

Toggle "Estimate follow-up reminders" in the existing Notification rules
section, wired like `appointmentRemindersEnabled`'s toggle (save settings →
`syncNotifications()` already runs). Sub-label: "Remind me when an estimate
gets no response for 3 days."

### H. Analytics

Two new PostHog events (joins the existing 17): `estimate_follow_up_opened`
(source: notification | job_detail) and `estimate_follow_up_sent`
(channel: sms | email — only on outcome `sent`).

## Edge cases

- **Legacy estimates:** older than 3 days at ship time → fire date in the past
  → never scheduled (sweep guard). Between 0–3 days old with an
  `approval.sentAt` → nudges correctly. Manual-sent legacy (no timestamp) →
  never nudges. In all cases: zero surprise-notification spam after OTA.
- **Timezone:** all fire-date math local-frame (`parseLocalDate` +
  `setHours(9,…)`), same as the inv_/rinv_ branches fixed 2026-08-01 (FA-039).
  The two existing branches' comment says "do not let branches drift" — the
  est_ branch joins that contract.
- **Re-send:** any of the three stamp sites updating `estimateSentAt` re-arms
  the nudge (intentional, decision 2).
- **Permissions absent / notifications unavailable:** existing sweep guards
  no-op silently.
- **60-cap pressure:** est_ scheduled last by design.
- **Customer with no contact info:** screen still opens (message + Copy work);
  compose helpers alert on missing phone/email.

## Out of scope (v1)

Settings-editable template (in-screen editing covers it), AI-generated message,
escalating/second reminders, configurable day count, persisted followed-up
state, Jobs-tab badge, backend/email automation. All are compatible extensions.

## Testing

- `__tests__/estimateFollowUps.test.ts` — selector units: status filtering,
  `estimateSentAt` precedence over `approval.sentAt`, null → excluded,
  fire-date local-frame math (incl. a UTC-offset-sensitive case per FA-039),
  exactly-3-days boundary between the two selectors, template output incl.
  formatQuote rendering.
- Extend the notifications test suite: est_ scheduled with correct
  identifier/data, toggle-off schedules nothing, absent-field-means-ON,
  past-fire-date skipped, cap shared.
- Today-row: count/pluralization logic unit-tested; screen-level RNTL test for
  EstimateFollowUpScreen only if the ReviewRequestScreen precedent gains one
  first (parity, not a new convention).
- Gate: tsc 0 / all tests / lint 0 before any commit (change-control rule 2).

## Ship path

JS-only, no new dependencies, no native changes → **OTA-eligible** via
`eas update --channel production` once iOS 1.1.0 is live (reaches only the
1.1.0 runtime). Device smoke on the owner's phone before the update is pushed;
no store-listing claim until smoke passes.
