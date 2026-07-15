# Overdue Invoice Auto-Outreach — Design

**Date:** 2026-07-14
**Status:** Approved (design), pending implementation plan
**Repo:** `tradeready/` (new branch off `master` — do **not** build on `feat/social-signin`)

## Goal

Give the tradesperson "one less thing to remember" on overdue invoices: when an
overdue invoice reaches a configured age, the app should **proactively surface a
ready-to-send payment reminder** instead of only telling them the invoice is
late. Ship this in two phases:

- **Phase 1 (this spec — build now):** on-device **auto-draft + one-tap send**.
  At the configured age an overdue notification becomes *actionable* — tapping it
  opens a pre-generated outreach message for that invoice, which the user sends
  with one tap (email or text). Human stays in the loop.
- **Phase 2 (sketched here, its own spec later):** opt-in **fully hands-off
  server email auto-send** via the Vercel backend + Resend.

## The hard constraint that shapes the whole feature

An Expo app **cannot silently send an email or SMS from the device**.
`expo-mail-composer` / `expo-sms` (see `utils/messaging.ts`) only *open* the
native composer — a human taps send. Truly hands-off sending is only possible
**server-side**. That is why Phase 1 is "draft + one tap" (achievable today,
email *and* text) and true auto-send is deferred to Phase 2 (server, email-only,
larger compliance surface).

## What already exists (Phase 1 mostly *connects* these)

- **Overdue notifications** — `utils/notifications.ts › syncNotifications()`
  reschedules local notifications for every unpaid invoice × every
  `settings.rules` entry (`ReminderRule = { days }`, "notify N days past due"),
  fired at 09:00, capped at 60, permission-gated. Configured in
  `screens/SettingsScreen.tsx` under "Notification rules".
- **The outreach composer** — `screens/OutreachScreen.tsx` already loads an
  invoice by id, AI-generates (or template-falls-back via
  `utils/invoiceHelpers.ts › generateOutreachMessage`) a past-due message, lets
  the user pick email/text, optionally attaches a payment link / payment plan,
  and opens Mail/Messages. It already renders a "paid — no further outreach
  needed" state when the invoice is paid.
- **A working "auto-remind + one-tap send" precedent** — Review Requests
  (`utils/reviewRequest.ts`, `settings.reviewRequestEnabled`,
  `screens/ReviewRequestScreen.tsx`): a toggle schedules a local notification
  after job completion; tapping it opens a pre-filled screen to send with one
  tap. Phase 1 mirrors this pattern exactly.
- **Notification-tap routing** — `App.tsx` already registers
  `addNotificationResponseReceivedListener` and routes `type: "review_request"`
  taps to `Main → Jobs → ReviewRequest`, guarded by a signed-in check
  (`sessionRef.current`). Today, overdue-invoice notifications carry
  `data: { invoiceId }` with **no `type`**, so tapping one does nothing — the gap
  Phase 1 closes.
- **`Outreach` is already a registered route** in the Invoices, Jobs, and
  Customer stacks (`types/navigation.ts`), taking `{ invoiceId }`. Phase 1 routes
  taps to the **Invoices** tab's copy.

---

# Phase 1 — Auto-draft + one-tap send

## Configuration model: reuse the existing day-rules

No new age field. The `settings.rules` the user already configures under
"Notification rules" **are** the triggers. A single new master toggle decides
whether those overdue notifications are *actionable* (tap → drafted outreach) or
stay as today's quiet reminders. Multiple rules (e.g. `1 / 7 / 30` days)
naturally give repeat nudges for free, and ages stay configured in exactly one
place.

### New setting (one field)

Add to the `Settings` interface (`types/models.ts`) and `defaultSettings()`
(`utils/storage/defaults.ts`):

```ts
// Notifications
autoOutreachEnabled: boolean; // default false — opt-in
```

Default `false`: no behavior change until the user opts in. Plain AsyncStorage
(not sensitive, not SecureStore). Place it next to `rules` in the interface and
next to the `rules` line in `defaultSettings()`.

## Notification enrichment — `utils/notifications.ts › syncNotifications()`

The scheduling loop is **unchanged** — same iteration over unpaid invoices ×
`rules`, same 09:00 fire time, same 60-cap, same permission guard. Only the
per-notification *content* branches on the toggle:

- **`autoOutreachEnabled === true`:**
  - `data: { type: "overdue_outreach", invoiceId: inv.id }`
  - Action-oriented body, e.g.
    `Tap to send ${inv.customer} a reminder for ${inv.number} — ${rule.days} days past due.`
  - Title may stay `Overdue invoice — ${inv.customer}` (or become
    `Follow up with ${inv.customer}` — copy decided in the plan).
- **`autoOutreachEnabled === false`:** byte-for-byte today's behavior — title
  `Overdue invoice — ${inv.customer}`, body
  `Invoice ${inv.number} is now ${rule.days} days past due.`,
  `data: { invoiceId: inv.id }`, **no `type`**. Tapping does nothing, as today.

Because the toggle changes the *content/data* of already-scheduled
notifications, `syncNotifications()` must re-run when it changes.
`SettingsScreen`'s save path already calls `syncNotifications()`
(`screens/SettingsScreen.tsx:270`), so this is covered with no extra wiring.

## Tap routing — `App.tsx` notification listener

Add one branch alongside the existing `review_request` branch, inside the same
`sessionRef.current` signed-in guard:

```ts
if (data?.type === "overdue_outreach" && data?.invoiceId && navigationRef.isReady()) {
  navigationRef.navigate("Main", {
    screen: "Invoices",
    params: { screen: "Outreach", params: { invoiceId: String(data.invoiceId) } },
  });
}
```

Routing to the **Invoices** tab keeps the mental model clean (this is about an
invoice) and uses the already-registered `InvoiceStackParamList.Outreach` route.

## OutreachScreen — no change required

It already loads by `invoiceId`, generates the message on mount, and shows the
paid-state card when `invoice.paid`. A tapped notification for an
already-paid-or-deleted invoice therefore degrades gracefully. **Optional
polish (may be deferred):** default the channel to `invoice.email ? "email" :
"text"` so the one-tap flow lands on the right composer; left out of the core
scope to avoid touching the generate-on-mount effect.

## Settings UI — `screens/SettingsScreen.tsx`

Directly under the existing "Notification rules" block (after the `+ Add rule`
button, before the `Divider`), add a toggle card matching the review-request
toggle's markup:

- **Label:** "Draft a reminder I can send with one tap"
- **Subtitle:** "When an overdue reminder fires, tapping it opens a
  ready-to-send message for that invoice."
- Bound to `s.autoOutreachEnabled` via the existing `update(...)` helper.

No new save logic — the existing `handleSave` → `syncNotifications()` path
already reschedules notifications with the new content.

## Guardrails (mostly free)

- Only **unpaid** invoices are scheduled — already filtered
  (`invoices.filter(inv => !inv.paid && inv.due)`).
- **Paid between schedule and tap:** handled twice over — OutreachScreen's paid
  state, *and* `syncNotifications()` re-running on invoice changes
  (`AddInvoiceScreen`, `InvoicesScreen`) cancels stale notifications.
- 60-notification cap and the notifications-permission guard are preserved
  unchanged.
- Toggle defaults **off**; enabling it is a deliberate opt-in.

## Telemetry

One event when a tap routes into outreach from a notification, consistent with
the existing analytics wrapper (`utils/analytics.ts`, mirroring
`review_request_sent`): `overdue_outreach_opened`, property `{ daysOverdue }`.
Fire it either in the `App.tsx` listener branch or via a route param consumed by
OutreachScreen — exact placement decided in the plan.

## Testing & gate

- Extend `__tests__/notifications.test.js`:
  - With `autoOutreachEnabled: true`, scheduled notifications carry
    `data.type === "overdue_outreach"` and a defined `invoiceId`.
  - With `autoOutreachEnabled: false`, scheduled notifications carry **no**
    `type` (today's shape) — a regression guard on the opt-in boundary.
  - Ages/cap/permission behavior unchanged.
- Extend the settings-defaults assertions (e.g. `__tests__/storage.test.js`) to
  include `autoOutreachEnabled: false`.
- Notification-tap routing is not unit-tested here (needs an RN-nav harness);
  covered by manual device smoke instead.
- All new/changed files stay `.ts` / `.tsx`. The verify gate (typecheck / tests
  / lint) must be **green** before any commit.

## No new dependencies

Everything used (`expo-notifications`, `expo-mail-composer`, `expo-sms`, the
existing AI/template generator) is already installed. No Expo SDK or dependency
changes — no owner approval gate on that axis.

---

# Phase 2 — Opt-in server email auto-send *(sketch only — deferred to its own spec)*

Fully hands-off: a Vercel Cron job scans overdue invoices server-side and sends
the reminder via **Resend** (already wired for password-reset email on
`gettradereadyapp.com`) with no human tap. **Email only** — SMS would require a
new provider (e.g. Twilio) and carries TCPA weight.

Deferred because it is a materially larger surface than Phase 1:

- **Server-side data access — open question to resolve first:** the cron job
  needs each overdue invoice + the customer's email server-side. Confirm what
  actually syncs to Supabase (invoices and their `email` field) before designing
  the scan; if the data isn't there, Phase 2 needs a sync change first.
- **Compliance & trust guardrails:** per-customer opt-out, a required
  unsubscribe footer, per-invoice/per-day send caps, and an in-app **audit log**
  ("Reminder sent automatically on …") the user can review — because the app is
  now sending on the user's behalf without a per-message tap.
- **Scheduling & idempotency:** Vercel Cron cadence, "send once per
  invoice per rule" de-dup, retry/failure handling.
- **Settings:** a separate opt-in (`autoSendEmailEnabled`) layered *on top of*
  the Phase 1 draft flow — Phase 1 remains the default for cautious users.

## Out of scope (YAGNI)

- Silent on-device sending (impossible — see the hard-constraint section).
- SMS auto-send (Phase 2 is email-only; SMS would need a new provider).
- A second/independent age setting or a separate repeat-cadence engine — the
  existing `rules` list supplies both trigger ages and repeat nudges.
- Changing the existing "quiet reminder" behavior when the toggle is off.
- Any Phase 2 server work in the Phase 1 build.
