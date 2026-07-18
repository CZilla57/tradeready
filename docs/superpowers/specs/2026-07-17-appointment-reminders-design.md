# Appointment & "On My Way" Reminders — Design

**Date:** 2026-07-17
**Branch:** `feat/appointment-reminders`
**Roadmap item:** Post-launch feature roadmap, Phase 2.
**Status:** Design approved; ready for implementation plan.

## Goal

Give the solo tradesperson two customer-facing touch points around a scheduled
job, reusing existing plumbing:

1. **Day-before confirmation** — the evening before a scheduled job, remind the
   tradesperson to send the customer a confirmation ("You're on the calendar for
   tomorrow…"). Opt-in.
2. **"I'm on my way"** — a one-tap button the tradesperson presses when they
   actually leave, opening a pre-filled text/email to the customer. Always
   available on scheduled jobs.

This is the "biggest professionalism-per-effort win" for a solo operator who
can't answer the phone from a ladder.

## Non-goals (YAGNI)

- **No backend, cron, Resend, or Supabase table.** Everything is on-device.
  (The overdue feature's server auto-email is deliberately *not* mirrored here —
  see "Why fully on-device".)
- **No auto-SMS.** Expo cannot silently send SMS or email; the device only opens
  a composer. Both flows are tap-to-send.
- **No configurable lead time / time-of-day picker.** Fixed 5pm-day-before for
  the confirmation reminder. Can be added later if requested.
- **No AI-generated copy.** Editable templates only — instant, deterministic,
  no API key, works offline.
- **No new dependency, no Expo SDK change.**

## Design decisions (locked with owner)

| Question | Decision |
|---|---|
| "On my way" model | One-tap button on the job (real-time; no cron can know when you leave). |
| Confirmation delivery | On-device tap-to-send (local notification → composer). Not server email. |
| Channel | SMS, falling back to email when the customer has no phone. |
| Message content | Editable templates with placeholders (like the review-request template). |
| Confirmation timing | Fixed **5:00pm local, the day before** the job. Opt-in via one Settings toggle. |

## Why fully on-device

The overdue-reminder feature ended up with *two* delivery paths: an on-device
draft (Phase 1) and a hands-off server email (Phase 2, Vercel Cron + Resend).
For appointments the owner chose the on-device path only, because:

- It works offline and needs no customer **email** (SMS is the natural channel).
- The "on my way" action is inherently real-time and manual — a fixed cron time
  would be wrong ("on my way" at 8am when you actually leave at 11am is worse
  than no message).
- Zero new backend surface, dependency, or cost; lowest launch risk.

## Architecture

Local-first invariant preserved: no read path waits on network. All new logic is
either pure (unit-tested) or on-device notification scheduling. Sync is untouched
except that job saves now also re-derive notifications (below).

### 1. Data model — `types/models.ts`

Three new `Settings` fields, all opt-in / default-safe. `loadSettings` does **not**
merge defaults (established pattern), so every read site coerces:

```ts
// Notifications
appointmentRemindersEnabled: boolean;   // gates the day-before confirmation notif
// Appointment message templates (editable, with placeholders)
appointmentConfirmTemplate: string;     // "" / absent → DEFAULT_CONFIRM_TEMPLATE
onMyWayTemplate: string;                 // "" / absent → DEFAULT_ON_MY_WAY_TEMPLATE
```

- Booleans read with `!!settings.appointmentRemindersEnabled` → absent = OFF.
- Templates read with `settings.appointmentConfirmTemplate?.trim() || DEFAULT_…`
  → absent/blank = the default template.

No migration needed (sync stores JSON blobs; optional fields are free — follow
the safe-shape-change recipe in `tradeready-storage-and-sync`).

### 2. Pure logic — new `utils/appointmentMessages.ts`

The heart of the feature, kept I/O-free so it is fully unit-testable without
mocking Expo. Mirrors the backend's pure `selectInvoicesToRemind`.

```ts
export const DEFAULT_CONFIRM_TEMPLATE =
  "Hi {customer}, this is {business} confirming your appointment for {date} at {time}. " +
  "Reply here if you need to reschedule. See you then!";

export const DEFAULT_ON_MY_WAY_TEMPLATE =
  "Hi {customer}, this is {business} — I'm on my way to {address} now. See you shortly!";

export type ApptChannel = "sms" | "email" | "none";

// Placeholder substitution: {customer} {date} {time} {business} {address}.
// Unknown placeholders left as-is; missing vars render as "".
export function renderTemplate(
  template: string,
  vars: Record<string, string>
): string;

// SMS preferred, email fallback, else "none".
export function resolveChannel(customer: Pick<Customer, "phone" | "email">): ApptChannel;

// Human date/time from Job.scheduledDate (DateString) + scheduledStartTime (TimeString|null).
export function formatApptDateTime(
  date: DateString,
  startTime: TimeString | null
): { date: string; time: string };

// PURE selection: which scheduled jobs get a confirmation notification, and when.
// Returns one entry per qualifying job. No I/O.
export function selectAppointmentReminders(
  jobs: Job[],
  customersById: Map<string, Customer>,
  settings: Pick<Settings, "appointmentRemindersEnabled" | "appointmentConfirmTemplate" | "businessName">,
  now: Date
): Array<{ jobId: string; fireDate: Date; title: string; body: string }>;
```

**`selectAppointmentReminders` qualifying rules:**

- `settings.appointmentRemindersEnabled` is true (else return `[]`).
- Job has a `scheduledDate`.
- Job `status` ∈ `{ approved, scheduled, in_progress }` (not a terminal status).
- The customer (looked up by `job.customerId`) exists and has phone **or** email
  (`resolveChannel !== "none"`).
- `fireDate` = 5:00:00pm **local** on the day before `scheduledDate`, and
  `fireDate > now` (past reminders are dropped).

Result is deterministic and ordered by `fireDate` so the notification cap
(below) truncates the *soonest-firing* set.

### 3. Send handler — new `utils/appointmentSend.ts`

A thin helper kept **separate** from the pure `appointmentMessages.ts` (this one
does I/O — it opens a composer). It renders the template and dispatches on the
resolved channel:

```ts
// Renders `template` for `job`/`customer`, then opens the composer.
// Returns true if a composer opened. Alerts + returns false if no contact info.
export async function sendAppointmentMessage(args: {
  job: Job;
  customer: Customer;
  settings: Settings;
  template: string;   // confirm or on-my-way
  kind: "confirm" | "on_my_way";
}): Promise<boolean>;
```

- Channel from `resolveChannel(customer)`:
  - `sms` → `composeSMS({ recipients: [customer.phone], body })`.
  - `email` → `composeEmail({ recipients: [customer.email], subject, body })`
    (subject e.g. `"Appointment confirmation"` / `"On my way"`).
  - `none` → `Alert.alert("No contact info", …)`, return false.
- On success, caller fires the analytics event (below).

Reuses the existing `composeSMS`/`composeEmail` (return `Promise<boolean>`,
handle availability + Alert). No new messaging primitive.

### 4. Notification scheduler — extend `utils/notifications.ts`

`syncNotifications()` currently loads invoices + settings only. Extend it to also
load `jobs` and `customers` (from AsyncStorage, same as it reads invoices), build
`customersById`, call `selectAppointmentReminders`, and schedule each result:

```ts
identifier: `appt_${jobId}`,
content: {
  title,                                   // e.g. "Confirm tomorrow's job — {customer}"
  body,                                    // e.g. "Tap to text {customer} a confirmation for {date}."
  data: { type: "appointment_confirm", jobId },
},
trigger: { seconds: secondsUntil },
```

- Reuses the existing `cancelAllScheduledNotificationsAsync()` at the top of
  `syncNotifications` → full re-derive each run, so **no double-scheduling**.
- Shares the existing 60-notification cap with invoice reminders. Budget:
  schedule invoice reminders first (unchanged), then appointment reminders up to
  the shared cap. (Launch scale is tiny; the cap is a safety valve.)
- On Android, add an `appointment-reminders` notification channel in
  `setupNotifications` (alongside `invoice-reminders` / `review-requests`).

### 5. Wire job saves — `utils/storage/collections.ts`

`saveJobs` currently does **not** call `syncNotifications` (verified). Add it,
matching `saveInvoices`:

```ts
export async function saveJobs(jobs: Job[]): Promise<void> {
  // …existing AsyncStorage write + enqueue + trySync…
  syncNotifications();
}
```

So scheduling/rescheduling/cancelling a job immediately re-derives its
confirmation reminder.

### 6. Tap routing — `App.tsx`

Add a branch to the existing `addNotificationResponseReceivedListener`:

```ts
if (data?.type === "appointment_confirm" && data?.jobId && navigationRef.isReady()) {
  track("appointment_confirm_opened", {});
  navigationRef.navigate("Main", {
    screen: "Jobs",
    params: { screen: "JobDetail", params: { jobId: String(data.jobId) } },
  });
}
```

Guarded by the same `sessionRef.current` signed-out check as the other branches.
`JobDetail` is already registered in `JobStack`.

### 7. UI

**JobDetail (`screens/JobDetailScreen`)** — for a job with `scheduledDate` and a
contactable customer, an "Appointment" action row with two buttons:

- **Send confirmation** → `sendAppointmentMessage(kind: "confirm")` using
  `appointmentConfirmTemplate`; on success `track("appointment_confirm_sent")`.
- **I'm on my way** → `sendAppointmentMessage(kind: "on_my_way")` using
  `onMyWayTemplate`; on success `track("on_my_way_sent")`.

**Today tab JobCard (`screens/TodayScreen`)** — a compact **"On my way"** action
on today's scheduled jobs (the natural place you glance before leaving). Same
handler as JobDetail's on-my-way button.

Both buttons load the job's customer (by `customerId`) via `loadCustomers` and
use the shared `useTheme` `createStyles` factory pattern.

**Settings (`screens/SettingsScreen`)** — under Notifications:

- A **"Appointment reminders"** toggle bound to `appointmentRemindersEnabled`.
- Two editable multiline template fields (confirmation, on-my-way), following the
  existing `reviewRequestTemplate` editing pattern, each showing the available
  `{placeholders}` as helper text.

### 8. Analytics — `utils/analytics.ts`

Three new business events (per the telemetry convention):

- `appointment_confirm_sent` — confirmation composer opened from a button.
- `appointment_confirm_opened` — confirmation notification tapped.
- `on_my_way_sent` — on-my-way composer opened.

## Testing

Pure, no Expo mocking required — this is why the logic lives in
`appointmentMessages.ts`:

- `renderTemplate` — each placeholder substituted; unknown placeholders left
  intact; missing vars render empty; no template mutation.
- `resolveChannel` — phone→sms, email-only→email, neither→none, blank strings
  treated as absent.
- `formatApptDateTime` — date + present/absent start time.
- `selectAppointmentReminders` — toggle off ⇒ `[]`; terminal statuses excluded;
  contactless customers excluded; `fireDate` computed to 5pm day-before local;
  past reminders dropped; ordering by `fireDate`.

Full gate (typecheck / tests / lint) green before any commit, per
`tradeready-change-control`. No commit on a red gate.

## Files touched (summary)

| File | Change |
|---|---|
| `types/models.ts` | +3 Settings fields |
| `utils/appointmentMessages.ts` | **new** — pure: templates, `renderTemplate`, `resolveChannel`, `formatApptDateTime`, `selectAppointmentReminders` |
| `utils/appointmentSend.ts` | **new** — I/O: `sendAppointmentMessage` (composer dispatch) |
| `utils/notifications.ts` | extend `syncNotifications` + Android channel |
| `utils/storage/collections.ts` | `saveJobs` → `syncNotifications()` |
| `App.tsx` | notification-tap branch for `appointment_confirm` |
| `screens/JobDetailScreen.*` | Appointment action row (2 buttons) |
| `screens/TodayScreen.*` | JobCard "On my way" action |
| `screens/SettingsScreen.*` | toggle + 2 template editors |
| `utils/analytics.ts` | 3 event names |
| `__tests__/…` | pure-logic tests for `appointmentMessages.ts` |

## Open, accepted risks

- **Notification cap sharing:** invoice + appointment reminders share the 60 cap.
  Acceptable at launch scale; documented in code.
- **Customer rename split** (existing residual, `tradeready-architecture-contract`
  §6): a job whose `customerId` doesn't resolve is simply skipped for the
  confirmation notif and shows no on-my-way button — safe degradation.
- **Timezone:** `fireDate` uses device-local 5pm; a job scheduled while the user
  travels across zones uses the device's current zone at schedule time. Matches
  the existing invoice-reminder behavior (`setHours(9,…)` local).
