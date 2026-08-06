# Fully Automatic Invoice Emailing (opt-in) — Design

**Date:** 2026-08-06 · **Status:** owner-approved; built per docs/superpowers/plans/2026-08-06-auto-email-invoice.md (pending owner smoke + Worker deploy + migration + OTA)
**Depends on:** auto-invoice-on-complete (2026-08-03 spec, merged `1a88540`),
change orders (2026-08-05 spec, merged `c38a3f9`), overdue auto-outreach Phase 2
(2026-07-14 spec — the Resend + log-table pattern this design mirrors),
Cloudflare Workers backend (production cron since the 2026-08-05 cutover).

## Summary

A second opt-in tier above `Settings.autoInvoiceOnComplete`: when a job is
marked complete and its invoice is auto-created, the invoice is **emailed to
the customer automatically** — no send screen, no Mail composer — within about
15 minutes, via the backend's existing unattended-email machinery (Resend,
verified `gettradereadyapp.com` domain). Approved change orders are already
included in the auto-created invoice (`utils/autoInvoice.ts`
`buildInvoiceLineItems` appends each approved CO as an `other`-category line),
so they appear in the emailed invoice with no new work.

Owner decisions taken in the 2026-08-06 brainstorm:

| Question | Decision |
|---|---|
| Email content | Deterministic template (no AI): line-item summary + pay link when available. No PDF attachment in V1. |
| Send timing | Backend sweep every 15 min; the 0–15 min lag doubles as a delete-to-cancel grace window. |
| Customer has no email | Invoice still auto-created; app falls back to today's behavior (opens the send screen). |
| Architecture | Client stamps the invoice + mints the pay link at creation; backend sweeps and sends. No backend Stripe surface, no backend write-back into synced invoice data. |

## Client design (app — JS-only, OTA-eligible)

### New persisted fields (`types/models.ts` first — it is authoritative)

- `Settings.autoEmailInvoiceOnComplete: boolean` — the opt-in. Absent-means-OFF
  (truthy read), same convention as `autoInvoiceOnComplete`. Add to
  `defaultSettings` in `utils/storage/defaults.ts` as `false`.
- `Invoice.autoEmailRequestedAt?: string` — ISO datetime stamped at creation,
  meaning "the backend should email this invoice." Optional; legacy records
  lack it, which correctly reads as not-requested. No migration needed.

Both ride the JSON-blob sync (no Supabase schema change). Owner approval for
the persisted-shape change: given at this design's approval (change-control
rule).

### Flow change — `utils/autoInvoice.ts`

`createAutoInvoiceForJob` (currently `autoInvoice.ts:231`), after the existing
gates pass and the invoice object is built:

1. If `settings.autoEmailInvoiceOnComplete` is truthy AND the resolved customer
   record has a non-empty email → save the invoice with
   `autoEmailRequestedAt: new Date().toISOString()`.
2. Return type changes from `string | null` to
   `{ invoiceId: string; autoEmailQueued: boolean; email: string } | null` so
   the caller knows which path it is on. (Single call site:
   `screens/JobDetailScreen.tsx:804`, plus `__tests__/autoInvoice.test.ts`.)
3. **Fire-and-forget pay-link mint** after the save: reuse OutreachScreen's
   existing machinery (`resolvePaymentLink` with `settings.provider` — the
   same default OutreachScreen seeds `selectedProvider` from at `:110` — and
   its `getProviderKey` key, full balance, no deposit ask; extract the small
   mint-and-persist step shared with `OutreachScreen.tsx:199`
   `handleGenerateLink` rather than duplicating it), persisting
   `paymentLinkUrl`/`paymentLinkAmount` via the
   normal `loadInvoices`/`saveInvoices` path. Runs async: marking a job
   complete never waits on the network (local-first invariant). Failure or
   offline → `reportError` and the email goes out link-less.

### JobDetailScreen

When the result has `autoEmailQueued: true` → do NOT navigate to Outreach.
Show a confirmation alert: "Invoice INV-1042 created — it'll be emailed to
<email> within about 15 minutes." with **View invoice** (navigates to
Outreach, as today) and **OK**. When `autoEmailQueued: false` → exactly
today's behavior (navigate to Outreach).

### OutreachScreen — double-send guard

On a successful manual send (compose outcome `sent`/`unknown`) of an invoice
that still carries `autoEmailRequestedAt` → clear the stamp via `saveInvoices`.
This stops the backend emailing a second copy when the user beats the sweep.
(After the sweep has sent, the one-and-done log row prevents re-sends
regardless of the stamp.)

### Settings UX — `screens/SettingsNotificationsScreen.tsx`

In the existing "Auto-invoice completed jobs" card (`:169`): a sub-toggle
**"Email it automatically"**, rendered only while the parent toggle is on
(hidden ≠ cleared; the stored value persists). Note text:

> Skip the send screen — the invoice is emailed to the customer within about
> 15 minutes, with a payment link when one can be made. If the customer has no
> email on file, the send screen opens instead.

Amend the parent card's note so "…and open the send screen" no longer reads as
unconditional.

### Analytics

Extend the existing `invoice_created` event (`source: "auto_on_complete"`)
with `autoEmailQueued: boolean`. No new event in V1.

## Backend design (Cloudflare Workers ONLY — `backend-workers/`; Vercel untouched)

### Cron

- `wrangler.toml`: `crons = ["0 15 * * *", "*/15 * * * *"]`.
- `src/index.js` `scheduled()`: route by `event.cron` — daily pattern →
  `runReminders` (unchanged); 15-min pattern → new `runInvoiceEmails`. At
  15:00 UTC both fire; the batches are disjoint (different log tables), which
  is harmless.
- New manual-run fallback route `/api/cron/send-invoice-emails` behind
  `CRON_SECRET`, mirroring `src/routes/cron.js`.
- No new secrets: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`,
  `RESEND_API_KEY`, `CRON_SECRET` already set.

### New table — `supabase/migrations/20260806_auto_invoice_email_log.sql`

Byte-for-byte sibling of `20260715_auto_reminder_log.sql`:
`id uuid pk, user_id uuid → auth.users, invoice_id text, to_email text,
sent_at timestamptz default now(), status text default 'pending'
('pending'|'sent'|'failed'), error text`, `unique (user_id, invoice_id)`,
RLS enabled, owner-read SELECT policy (`auth.uid() = user_id`). The cron
writes with the service role. Applied by the owner in the Supabase SQL editor
(no CLI runner in this repo). The unique constraint is the one-and-done
claim guard (insert `pending` first; conflict → skip).

### Selector — `backend-workers/lib/selectInvoicesToAutoEmail.js` (pure)

An invoice is emailed when ALL hold:

1. `invoice.autoEmailRequestedAt` present (only client-stamped auto-invoices —
   never manual ones, never pre-existing backlog);
2. owner's `settings.autoEmailInvoiceOnComplete` truthy **at send time**
   (turning the toggle off halts pending sends);
3. `invoice.email` non-empty;
4. balance due > 0 (`paymentMath.balanceDue`) — paid/fully-credited invoices
   are skipped (customer paid on the spot before the sweep);
5. not already claimed in `auto_invoice_email_log`;
6. freshness: `autoEmailRequestedAt` within the last 7 days — a long-offline
   device syncing up weeks-old stamped invoices must not blast stale email;
   stale ones simply never send (no log row; the age check excludes them on
   every run — cheap at this scale, and keeps the status enum identical to
   the reminder table).

Batch runner `backend-workers/lib/sendInvoiceEmails.js` mirrors
`sendReminders.js`: fetch invoices (`deleted=is.false`) + settings + log rows,
per-user selector, claim-insert, send, best-effort `markLog`, per-invoice
error isolation, per-user daily cap of 25 counted from today's log rows.
(No jobs fetch needed — deposit-finalize jobs never enter this path because
`shouldAutoInvoice` refuses jobs with an existing `invoiceId`.)

### Email builder — `backend-workers/lib/invoiceEmail.js` (pure, plain text, no AI)

Mirrors `reminderEmail.js` discipline exactly:

- **From:** `<Business> via TradeReady <invoices@gettradereadyapp.com>` using
  the existing `sanitizeFromPhrase` (header-injection-safe; empty sanitization
  degrades to the bare sender). New localpart on the already-verified domain.
- **Reply-to:** `settings.email` when present. **Subject:**
  `Invoice INV-1042 from <business>` with CR/LF stripped.
- **Body:** greeting by `invoice.customer`; job description (`invoice.desc`);
  the invoice line items — labor, materials, overhead, and each approved
  change order on its own line (from `invoice.lineItems`, amounts via the
  backend `formatMoney` in `lib/overdue.js`); total and due date; then the
  payment-link line, `settings.paymentNotes`, and the business signature.
- **Payment-link rule (reused, not relaxed):** include the cached
  `paymentLinkUrl` ONLY when `paymentLinkAmount` matches the balance due
  within `PAID_EPSILON` AND `isAllowedPaymentLink` passes (https + allowlisted
  host). A failing link drops the LINE, never the email.
- Invoices lacking `lineItems` (possible if a future path stamps without
  items) fall back to a single amount line — the email never fabricates a
  breakdown.

### What the backend never does (deliberate)

No Stripe minting server-side; no write-back into synced invoice `data` blobs
(avoids the whole-blob clobber hazard the Stripe webhook must tiptoe around
with add-only ledger discipline). The invoice record stays client-owned.

## Edge cases

| Case | Outcome | Mechanism |
|---|---|---|
| Invoice deleted before sweep | No email | `deleted=is.false` filter; the 0–15 min lag is the grace window |
| Paid before sweep | No email | balance-due > 0 condition |
| Edited before sweep | Email reflects current synced amounts | Sweep reads live data; a broken link-amount match drops the link line |
| Customer email removed before sweep | Never claims; stays manual | selector condition 3 |
| Multi-device | Exactly one email | stamp syncs; `unique (user_id, invoice_id)` claim |
| Pre-OTA clients | Backend idles safely | old clients never stamp |
| 15:00 UTC double-fire | Harmless | disjoint batches/tables |
| Long-offline device syncs old stamps | No stale blast | 7-day freshness condition |
| Manual send before sweep | One email | Outreach clears the stamp on send success |

## Error handling and accepted limitations

- **Mint failure / offline completion:** email goes out without a pay link
  (honest degradation); error reported to Sentry; completion UX never blocks.
- **Resend send failure:** log row `status='failed'` with the error; NOT
  retried (one-and-done, mirroring the reminder cron). Accepted V1
  limitation; automatic retry is a listed follow-up.
- **In-app delivery status:** V1 shows only the completion alert. The
  owner-read RLS policy ships in the migration so a follow-up can show
  "Emailed on <date>" in the app by reading the user's own log rows
  (background fetch — never on the render path).

## Testing

- **Client** (`__tests__/autoInvoice.test.ts` + siblings): stamping gates
  (toggle off / no email / queued), new return shape, mint is fire-and-forget
  and non-blocking (mocked), JobDetail navigation branch, Outreach
  stamp-clear on send success. Settings sub-toggle render gating (RNTL).
- **Backend** (new suites mirroring `reminderLogic.test.js` /
  `reminderEmailHardening.test.js`): selector — each of the 6 conditions,
  freshness boundary, daily-cap counting; builder — sanitized From, link
  include/drop rules (amount mismatch, disallowed host, http), change-order
  lines present, no-lineItems fallback, CR/LF-stripped subject.
  Note: the Workers libs are ESM; expectation is babel-jest transpiles them
  when imported from `__tests__/` (they are not under `node_modules`). If
  Jest balks, fall back to extracting the pure logic CJS-style — decided at
  implementation, not silently.
- Full gate (typecheck / tests / lint) green before any commit.

## Rollout (three independent steps, each safe alone, in order)

1. **Owner** applies `20260806_auto_invoice_email_log.sql` in the Supabase SQL
   editor.
2. Deploy `backend-workers` (new cron trigger + route). The sweep finds
   nothing until clients stamp.
3. Client changes ride the next OTA train (post-1.1.0-approval; subject to
   the standing trip-sync/privacy-label ordering gates). No new privacy-label
   surface expected: customer email addresses already flow to Resend via the
   shipped reminder feature.

Feature activates per-user only when both toggles are on.

## Follow-ups (out of scope for V1)

- Automatic retry for `failed` sends.
- In-app "Emailed on <date>" status from the log table.
- Server-side PDF attachment.
- Backend mint-at-send for the offline-completion case.
