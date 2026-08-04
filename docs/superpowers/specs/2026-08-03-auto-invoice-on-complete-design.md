# Auto-invoice on job completion — design

Date: 2026-08-03 · Status: approved by owner (behavior + revision round) · JS-only, OTA-safe

## What it does

When the tradesperson marks a job **complete** (JobDetailScreen's advance
action — the only site in the app where a job reaches `complete`), and the new
opt-in Settings toggle is on, the app:

1. Clocks out a still-running job timer at that moment (marking complete is the
   natural end of the clock), so the final session counts toward billed hours.
2. Auto-creates the invoice exactly as the manual "Create invoice" path would —
   same customer resolution, next invoice number, line items, due date
   (today + 30).
3. Advances the job `complete → invoiced` via the existing
   `jobChangesAfterInvoiceSave("create", …)`.
4. Navigates straight to the **Outreach** screen — payment link, PDF, and
   message prefilled. One tap sends. Backing out lands on JobDetail showing the
   invoiced job, identical to the manual flow's end state.

If any gate fails, behavior is unchanged from today (the "Create invoice →"
action remains). Failures degrade silently to the manual flow (reportError, no
alert).

## Gates (`shouldAutoInvoice(job, settings)`)

- `settings.autoInvoiceOnComplete` is truthy (opt-in, default OFF, absent means
  OFF — same convention as `appointmentRemindersEnabled`).
- Job has **no** `invoiceId` — a pre-work deposit invoice means "finalize"
  mode, which edits an existing invoice's amount and keeps the manual review
  screen. Deliberately out of scope for automation.
- `estimateTotal > 0` and a non-blank customer name (both required to save an
  invoice). A computed billable total ≤ 0 also bails.

## Tracked-time billing (owner revision, 2026-08-03)

When the job timer was used, the invoice bills **tracked hours**, not estimated
hours:

- Applies only when the estimate priced labor hourly (`laborHours > 0` AND
  `laborRate > 0`) — a flat-priced job must never gain a tracked-labor charge
  on top of its quoted total — AND the job is done (`complete`/`invoiced`/
  `paid`), so deposit requests mid-job still bill off the estimate.
- Billed hours = completed sessions' time, rounded to 2 decimals.
- **Total = estimateTotal + (billedHours − laborHours) × laborRate**, rounded
  to cents. Works in both directions (fewer tracked hours lowers the bill).
- Line items keep the §2.5 residual invariant (lines sum to total): labor line
  = billedHours × rate; materials line unchanged; "Overhead & operating costs"
  line unchanged (the original residual, which carries quoted overhead +
  profit + travel/tax). Extra/fewer hours are billed at the straight labor
  rate — like a T&M change order at the agreed rate. Re-running the full
  pricing engine is deliberately NOT done: jobs don't persist all engine
  inputs (`overhead`/`margin` name drift, no taxPercent) and hand-adjusted
  totals must be trusted.
- Applies to BOTH the auto flow and the manual CreateInvoiceFromJob screen
  ("create" mode prefill + line items), so both paths produce the same invoice
  for the same job. The manual screen's ⏱ banner copy switches to say the
  amount was billed from tracked time; all fields stay editable and manual
  edits win. The manual screen does NOT auto-clock-out (bills completed
  sessions only); only the auto flow closes a running timer.
- "finalize" mode: the amount still prefills from the existing (possibly
  hand-adjusted) deposit invoice — deliberately preserved; its line items
  recompute fresh (existing behavior) and therefore show tracked labor.

## New module: `utils/autoInvoice.ts`

Shared invoice-from-job derivation (extracted from CreateInvoiceFromJobScreen
so the auto path doesn't duplicate it — the dedup rule in the architecture
contract §9):

- `defaultDueDate()` — today + 30 (moved verbatim from the screen).
- `billableLaborHours(job)` — the tracked-vs-estimated decision above.
- `computeBillableBreakdown(job)` — base `computeEstimateBreakdown` with the
  labor line swapped when tracked applies; exposes `total`.
- `buildInvoiceLineItems(job)` — labor/materials/overhead lines (screen's save
  derivation, now tracked-aware).
- `prefillInvoiceDraftFromJob(job, invoices, settings, customerRecord)` —
  customer name, number (`nextInvoiceNumber`), amount, due, email/phone, desc.
- `shouldAutoInvoice(job, settings)` — pure gate predicate.
- `createAutoInvoiceForJob(jobId)` — orchestration: load → clock-out →
  resolveCustomer/getOrCreateCustomer → build → `saveInvoices` →
  `jobChangesAfterInvoiceSave` → `saveJobs` → returns invoice id or null.
  Tracks `invoice_created` with `source: 'auto_on_complete'`.

## Settings

- `types/models.ts`: `autoInvoiceOnComplete: boolean` (doc comment states the
  absent-means-OFF convention).
- `utils/storage/defaults.ts`: `autoInvoiceOnComplete: false`.
- SettingsScreen: toggle card after "Estimate follow-up reminders" —
  "Auto-invoice completed jobs". No data migration needed (truthy reads; blob
  sync).

## Tests (`__tests__/autoInvoice.test.ts`)

- `billableLaborHours`: each gate (no sessions / flat-priced / pre-complete
  status / rate 0), rounding, both directions.
- `computeBillableBreakdown`: worked example (4h @ $85, $300 materials +20%,
  total $966; tracked 5.5h → $1,093.50; tracked 2h → $796), lines sum to
  total.
- `shouldAutoInvoice`: each gate.
- `createAutoInvoiceForJob`: end-to-end against mocked AsyncStorage — invoice
  created with expected fields, job → invoiced with closed timer session,
  toggle-off returns null with no writes.

## Out of scope (deliberate)

Auto-finalizing deposit invoices; server-side/background sending (composer
requires the user's tap; backend is at the Vercel 12-function cap);
auto-popping the mail composer from Outreach (races link fetch + AI message);
auto-clock-out outside the auto-invoice flow.
