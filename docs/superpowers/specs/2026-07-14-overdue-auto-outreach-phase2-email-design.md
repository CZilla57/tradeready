# Overdue Auto-Outreach Phase 2 — Server-Side Email Auto-Send — Design

**Date:** 2026-07-14
**Status:** Approved (design), pending implementation plan
**Repo:** `tradeready/` (new branch off `master`, e.g. `feat/overdue-auto-outreach-phase2`). Phase 1 already merged (`59c07b8`).

## Goal

When a tradesperson opts in, the backend **automatically emails a payment reminder** for an overdue invoice — no tap, no manual step — **exactly once per invoice**, using a deliberately conservative, transactional posture. This is the fully-hands-off half of the auto-outreach feature; Phase 1 (on-device auto-draft + one-tap send) already shipped. See [Phase 1 spec](2026-07-14-overdue-auto-outreach-design.md).

## Why this is feasible without a sync change (verified)

- **The data is already on the server.** `utils/sync.ts` syncs `COLLECTION_TABLES = ['jobs', 'invoices', 'customers', 'expenses', 'pricebook']` plus `settings` to Supabase. Each collection row is `{ id, data (JSONB), deleted, user_id, updated_at }`; the full `Invoice` record — including `email`, `due`, `paid`, `amount`, `number`, `customer`, cached `paymentLinkUrl` — lives inside `data`. Settings sync to a `settings` table as `{ user_id, data }` (JSONB), so `autoSendEmailEnabled` + `rules` are server-readable.
- **The server already has admin access.** `backend/api/delete-account.js` establishes the pattern: raw `fetch` against Supabase REST (`/rest/v1/…`) and Auth (`/auth/v1/…`) using `SUPABASE_SERVICE_ROLE_KEY` (bypasses RLS), with `SUPABASE_URL` / `SUPABASE_ANON_KEY` also present. No `@supabase/supabase-js` dependency in the backend (only `stripe`).
- **Email is the one genuinely new capability.** Resend is currently only Supabase's *auth* SMTP provider (the app's only "resend" code is `utils/resendCooldown.ts`, a client-side button cooldown — unrelated). Server-initiated email means calling **Resend's REST API** directly via `fetch` (no new npm dependency), with a new `RESEND_API_KEY`. The sending domain `gettradereadyapp.com` is already DNS-verified.
- **No cron exists yet.** `backend/vercel.json` has only a `functions` block (`maxDuration: 10`). Vercel Cron is added via a `crons` entry.

## Trigger model — one-and-done

- An unpaid invoice becomes eligible when it first crosses the **earliest** configured reminder age: `min(settings.rules.days)`. This reuses the same `settings.rules` the user already configures for Phase 1 notifications. **No rules ⇒ no auto-send.**
- Each invoice gets **at most one** automatic email, ever. Never repeated, never escalated.

### Idempotency + audit: new `auto_reminder_log` table

The send-once guard and the audit trail are the same table. The server **never writes the synced invoice blob** (that would risk sync conflicts with the client's last-write-wins record merge).

```sql
create table public.auto_reminder_log (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  invoice_id text not null,          -- Invoice.id is a string (e.g. "1-<seed>")
  to_email   text,
  sent_at    timestamptz not null default now(),
  status     text not null default 'sent',   -- 'sent' | 'failed'
  error      text,
  unique (user_id, invoice_id)       -- DB-level one-and-done guarantee
);

alter table public.auto_reminder_log enable row level security;

-- The app reads its own audit rows; the cron writes via the service role (bypasses RLS).
create policy "read own reminder log"
  on public.auto_reminder_log for select
  using (auth.uid() = user_id);
```

The `unique (user_id, invoice_id)` constraint makes double-send impossible even under a mid-run crash or a race.

## The cron endpoint — `backend/api/cron/send-reminders.js`

- **Schedule:** Vercel Cron, once daily. `backend/vercel.json` gains:
  ```json
  { "crons": [{ "path": "/api/cron/send-reminders", "schedule": "0 15 * * *" }] }
  ```
  (~15:00 UTC ≈ morning in US timezones; a single daily UTC run is acceptable — timezone-perfect windows are out of scope.)
- **Auth:** reject unless `Authorization: Bearer ${CRON_SECRET}` matches. Vercel Cron automatically sends this header when `CRON_SECRET` is set in the project env.
- **Runtime shape** (mirrors `delete-account.js` conventions — CommonJS `module.exports = async function handler(req, res)`, env-var presence check, `fetch` to Supabase REST with the service-role key):
  1. Verify the cron secret.
  2. `GET /rest/v1/invoices?deleted=is.false&data->>paid=eq.false&select=id,user_id,data` (service role). JSONB filter narrows to unpaid; the rest is filtered in JS. *(v1 fetches all matching rows; pagination is a documented future concern, not built.)*
  3. `GET /rest/v1/settings?select=user_id,data` → map by `user_id`.
  4. `GET /rest/v1/auto_reminder_log?select=user_id,invoice_id` → set of already-handled `${user_id}:${invoice_id}` keys.
  5. Group invoices by `user_id`; for each user, run the pure selector (below) against their settings + already-sent set.
  6. For each selected invoice: **claim → send → record** (see failure handling).
- Returns a small JSON summary (`{ scanned, sent, failed }`) for observability; logs failures to `console.error` (Sentry is not wired into the backend today — out of scope to add).

### Pure, unit-tested selection function

```js
// backend/lib/selectInvoicesToRemind.js
// Pure — no I/O. Given one user's invoices + settings + the set of invoice ids
// already auto-reminded, returns the invoices to email now.
function selectInvoicesToRemind({ invoices, settings, alreadySentInvoiceIds, today }) { ... }
```

Rules, in order:
- If `!settings.autoSendEmailEnabled` → `[]`.
- `earliest = Math.min(...(settings.rules || []).map(r => r.days))`; if there are no rules → `[]`.
- Include an invoice iff: `!invoice.paid` **and** a non-empty `invoice.email` **and** `daysPastDue(invoice.due, today) >= earliest` **and** `invoice.id` not in `alreadySentInvoiceIds`.
- `daysPastDue(due, today) = floor((midnight(today) - date(due)) / 86400000)` — same formula as the app's `invoiceHelpers.daysPastDue`.

## Email content — template-only

No server-side AI for unattended mail: deterministic, no API variance/cost/latency, and the user never previews it. A minimal email template is **ported to the backend** (the backend is a separate package and cannot import the RN `utils/invoiceHelpers.ts`; this small, intentional duplication is the cost of the process boundary — noted, not avoidable).

- **From:** `"{businessName} via TradeReady <reminders@gettradereadyapp.com>"`
- **Reply-To:** `settings.email` if set (so the customer's reply reaches the tradesperson, not the app); omitted if empty.
- **Subject:** `Payment reminder – {invoice.number}`
- **Body** (plain text):
  ```
  Hi {invoice.customer},

  This is a friendly reminder that invoice {invoice.number} for {amount} is now {N} days past due.

  {If invoice.paymentLinkUrl present: "You can pay securely here: {paymentLinkUrl}"}

  If you've already sent payment, thank you — please disregard this note. Questions, or want to stop these reminders? Just reply to this email or contact {businessName}.

  {settings.paymentNotes if present}

  Best regards,
  {settings.contactName}
  {settings.businessName}
  {settings.phone}
  ```
  `{amount}` uses two-decimal money formatting; `{N}` is `daysPastDue`.
- **Recipient guard:** invoices with no `email` are excluded by the selector, so no send is attempted without a recipient.
- **Payment link:** include the invoice's **cached `paymentLinkUrl` only if already present** in the invoice data. The cron does **not** call Stripe to mint links.
- **Send:** `POST https://api.resend.com/emails` with `Authorization: Bearer ${RESEND_API_KEY}` and a JSON body (`from`, `to`, `reply_to`, `subject`, `text`).

## App-side changes

- **New setting:** `Settings.autoSendEmailEnabled: boolean`, default `false`. Add to `types/models.ts` (Notifications group, next to `autoOutreachEnabled`) and `defaultSettings()` (`utils/storage/defaults.ts`). Independent of `autoOutreachEnabled` — a user may want either, both, or neither. Because settings sync to Supabase, the cron reads this flag from `settings.data`; existing-user safety is the same as Phase 1 (absent ⇒ falsy ⇒ off; the cron uses a truthy check).
- **Settings UI** (`screens/SettingsScreen.tsx`): a second toggle directly under the Phase 1 toggle, with copy that is explicit that this *actually sends email automatically*, e.g. label **"Automatically email overdue reminders"**, subtitle *"When on, TradeReady emails the customer a payment reminder once an invoice passes your earliest reminder age — no tap needed. Sent under your business name; replies come to your email."* Reuses the existing toggle-card markup (`card` / `toggleRow` / `toggleLabel`), coerced `value={!!s.autoSendEmailEnabled}`, `update("autoSendEmailEnabled", v)`.
- **Audit visibility** (lightweight): `OutreachScreen` shows a note — "An automatic reminder was emailed on {date}" — when a matching `auto_reminder_log` row exists for the invoice. The app reads its own rows via the existing Supabase client (`utils/supabase.ts`), RLS-scoped to `auth.uid()`, filtered by `invoice_id`. Best-effort and non-blocking (failure to read just hides the note).

## New infrastructure (owner-provisioned — cannot be done in-session)

- **Vercel env vars:** `RESEND_API_KEY` (Resend account, `gettradereadyapp.com` sending domain) and `CRON_SECRET` (random string). `SUPABASE_URL` / `SUPABASE_ANON_KEY` / `SUPABASE_SERVICE_ROLE_KEY` already exist.
- **`backend/vercel.json`:** add the `crons` entry above. Confirm the Vercel plan permits the schedule (Hobby allows daily crons; a finer cadence needs Pro — daily is the intended cadence regardless).
- **Supabase migration:** apply the `auto_reminder_log` table + RLS SQL (via the project's migration flow — see the run-and-operate process).

## Failure handling & guardrails

- Send requires **all** of: `autoSendEmailEnabled` true, a recipient `email`, an existing reminder rule, invoice unpaid + past the earliest age, and no prior `auto_reminder_log` row.
- **Claim → send → record**, to make one-and-done crash-safe:
  1. **Claim:** insert an `auto_reminder_log` row first (`status: 'sent'` provisionally) relying on the `unique (user_id, invoice_id)` constraint; if the insert conflicts (row already exists), skip this invoice — it was already handled.
  2. **Send** via Resend.
  3. **Record:** if the send failed, `PATCH` the row to `status: 'failed'` with the error text.
- **No retries**, even on transient Resend errors (a claimed row blocks re-send). Accepted tradeoff: a rare transient failure means that one invoice simply doesn't get an auto-reminder; the tradesperson can still chase it manually via Phase 1. Failures are recorded (`status: 'failed'`) and logged to `console.error`.

## Testing

- **Backend (new harness):** add a minimal Jest setup to `backend/` (a `jest` devDependency + `test` script) and `backend/__tests__/selectInvoicesToRemind.test.js` covering: opt-out off ⇒ none; no rules ⇒ none; paid excluded; missing email excluded; not-yet-at-earliest-age excluded; already-sent excluded; eligible included; and multi-user isolation (one user's rules/flag don't affect another's). **This adds a dependency to the backend package — requires owner approval per change-control before install.**
- **App:** the `autoSendEmailEnabled` default + Settings toggle follow the Phase 1 pattern; covered by typecheck + the existing gate. No new app Jest test is required beyond keeping the gate green (screen JSX / Supabase reads aren't unit-tested here).
- Full app gate (typecheck / tests / lint) stays green before any commit; backend Jest green before backend commits.

## Decisions made in design (noted, reversible)

- **Template-only email content** (not server-side AI) — predictability over personalization for unattended mail.
- **Cached payment link or omit** — no Stripe calls inside the cron.
- **Strict one-and-done even on failure** — a claimed log row blocks retries; a transient failure forfeits that invoice's auto-reminder.
- **`autoSendEmailEnabled` is independent** of the Phase 1 `autoOutreachEnabled` toggle.

## Out of scope (YAGNI)

- SMS auto-send (email only; SMS carries TCPA weight and needs a new provider).
- Unsubscribe links / suppression lists / per-customer opt-in (transactional posture + one-and-done cap covers v1; the email invites a reply-to-stop).
- Escalating or repeat reminders (one-and-done).
- On-the-fly payment-link generation in the cron.
- Timezone-personalized send windows (single daily UTC run).
- Pagination of the cross-user invoice scan (fine at launch scale; documented as a future optimization).
- Wiring Sentry into the backend (uses `console.error`; the app keeps its own Sentry).
