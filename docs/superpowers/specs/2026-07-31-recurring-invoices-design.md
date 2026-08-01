# Recurring Invoices (Maintenance Plans) — Design

**Date:** 2026-07-31 · **Branch:** `feat/recurring-invoices` · **Roadmap:** post-launch item #6
**Status:** owner-approved design (2026-07-31), including both persisted-shape
approvals (§ Data shapes). Ships THIRD of the three-branch effort
(CSV → PDF-logo-size → recurring-invoices).

## Goal

Steady billing for maintenance plans: generate an invoice for a customer on a
schedule (with pause/resume and end conditions), surfaced through a local
notification for review-and-send — never auto-sent. Mirrors the recurring-jobs
pattern rather than inventing a new one.

## Owner decisions (2026-07-31)

| Decision | Choice |
|---|---|
| Delivery | Generate + local notification ("review & send"); NEVER auto-send (matches appointment-reminders philosophy) |
| Rule model | Standalone per customer (amount + description + cadence), independent of the jobs pipeline |
| Engine | Extract shared recurrence helpers; keep two thin engines (rejected: one generic engine — risky refactor; full copy — reintroduces the duplication bug class) |
| Invoice shape | **Approved:** optional `recurringInvoiceId?: string` and `occurrenceNumber?: number` on `Invoice` (mirrors `Job.recurringJobId`/`occurrenceNumber`; additive-optional; JSON-blob sync = no backend migration; follow the `tradeready-storage-and-sync` safe-shape recipe) |
| Storage | **Approved:** new local-only AsyncStorage key `recurringInvoices` (mirrors `recurringJobs`: not synced, wiped by `clearAllUserData`'s getAllKeys sweep, covered by `sampleMigration`) |

## Design

### 1. Shared recurrence helpers — `utils/recurrence.ts` (new)

Move `calculateNextDate(from, cadence)` and the end-condition check out of
`utils/recurringJobs.ts` into `utils/recurrence.ts`; `recurringJobs.ts`
re-imports them (behavior-preserving refactor — existing
`recurringJobs.test.ts` must pass unchanged). The end-condition helper is
generalized to the fields both rule types share
(`{ endCondition, endCount?, endDate?, occurrenceCount, nextDueDate }`).

### 2. Model — `RecurringInvoice` (types/models.ts)

```ts
interface RecurringInvoice {
  id: string;                       // ri<timestamp>
  customerId: string;
  customerName: string;             // denormalized display copy (Job.customerName pattern)
  description: string;              // becomes invoice.desc
  amount: number;
  dueDays: number;                  // net terms; default 30 (= AddInvoiceScreen defaultDueDate)
  cadence: RecurrenceCadence;       // reuse the existing 5-value union
  endCondition: RecurrenceEndCondition;
  endCount?: number;
  endDate?: DateString;
  occurrenceCount: number;
  lastGeneratedDate: DateString | null;
  nextDueDate: DateString;          // next occurrence (generation) date
  isActive: boolean;
  createdAt: DateString;
}
```

LOCAL-ONLY, like `RecurringJob` and `Trip` (documented in the model comment):
stored under `recurringInvoices`, not synced, lost on device change — the same
accepted limitation recurring jobs already carry. Generated **invoices** sync
normally.

### 3. Storage — `utils/storage/recurringInvoices.ts` (new)

Exact mirror of `utils/storage/recurringJobs.ts`: `loadRecurringInvoices` /
`saveRecurringInvoices` over `KEYS.recurringInvoices`; re-export from
`utils/storage/index.ts`. Add the collection to `sampleMigration.ts`'s
customer-id repointing (same exposure as recurring-job rules: a rule can be
created against a seed customer before migration).

### 4. Generator — `utils/recurringInvoices.ts` (new)

`checkAndGenerateRecurringInvoices()`, mirroring the jobs engine: module-level
re-entry guard, catch-up `while (rule.nextDueDate <= today)` loop, end
conditions deactivate, single batched save. Called from `AuthContext`
immediately beside `checkAndGenerateRecurringJobs()` (sign-in effect + the
AppState 'active' listener).

Each generated invoice:

- `id`: `inv${Date.now()}` — **must stay all-digits after the `inv` prefix**
  so `invoiceIssueDate` (utils/pdfTemplates.ts:167) recovers the issue date;
  rule linkage goes in `recurringInvoiceId`, NEVER in id suffixes. The
  catch-up loop guarantees uniqueness (monotonic counter added to the ms value
  if two generations land on the same tick).
- `number`: from the **extracted** `nextInvoiceNumber(invoices)` util (§5).
- `customer`/`customerId`: from the rule; `email`/`phone`: snapshot from the
  linked customer record at generation time (blank if the customer is gone —
  `backfillInvoiceContacts` heals later, as with any invoice).
- `due`: occurrence date + `dueDays` (NOT generation date — catch-up invoices
  for missed periods date from when the money was owed; they may appear
  already overdue, which is correct and mirrors how catch-up jobs appear in
  the past).
- `desc`: rule description; `amount`: rule amount; `paid: false`; no
  `payments`, no `jobId`, no `lineItems`.
- `recurringInvoiceId`: rule id; `occurrenceNumber`: occurrence index.
- **No network in the generator** (local-first invariant): payment links are
  minted on demand by the existing send/outreach flow, exactly like every
  other invoice.

Saving through `saveInvoices` enqueues sync and re-runs `syncNotifications()`
automatically (existing behavior), so overdue-dunning rules apply to the new
invoice with no extra wiring. Note `isJobDunningEligible` passes invoices with
no `jobId` through — correct here: a generated maintenance invoice is billable
immediately, not tied to unfinished work.

### 5. Extract `nextInvoiceNumber` — new shared util

Currently duplicated as `AddInvoiceScreen.autoInvoiceNumber` (:156) and
`CreateInvoiceFromJobScreen.nextInvoiceNumber` (:66) — identical digit-scan
max+1 `INV-%04d` logic. The generator would be a third copy; per the
architecture contract's reuse rule, extract to `utils/invoiceNumber.ts` and
point both screens + the generator at it. Behavior-preserving (both screens'
existing behavior pinned by tests).

### 6. Notification — new branch in `syncNotifications`

In the existing declarative sweep (`utils/notifications.ts`), after loading
data, also load recurring-invoice rules and for each **active** rule schedule
one notification at 9:00am on `nextDueDate`:

- identifier `rinv_${rule.id}` (own namespace beside `inv_`/`appt_`); shares
  the existing 60-notification cap; skipped when `secondsUntil <= 0` like the
  others.
- content: title `Maintenance invoice ready — ${rule.customerName}`, body
  "Open to review & send." (wording stays correct whether catch-up generated
  one invoice or several), `data: { type: 'recurring_invoice', ruleId }`.
- Android channel: reuse `invoice-reminders` (it is exactly an invoice
  reminder — no new channel).

Tap routing: new branch in App.tsx's existing
`addNotificationResponseReceivedListener` for `type === 'recurring_invoice'`
→ navigate to the Invoices tab `InvoiceList`; resolve the generated invoice by
scanning loaded invoices for the rule's latest `recurringInvoiceId` match and
pass `openInvoiceId` when found (param already exists,
types/navigation.ts:52), plain list otherwise. No new settings toggle:
creating a rule IS the opt-in; pausing stops generation and (via the sweep)
notifications.

### 7. UI — two new screens in the Invoices stack

- **`RecurringInvoicesScreen`** (`RecurringInvoices` route): mirror of
  `RecurringJobsScreen` — rule list (cadence label, amount via `formatMoney`,
  end-condition line, Active/Paused badge), tap → action sheet
  (Pause/Resume, Edit, Cancel-plan-with-confirm). **Deliberate divergence
  from the mirror:** `RecurringJobsScreen`'s sheet has no Edit (pause/cancel
  only) — invoice plans get Edit because maintenance-plan amounts change
  (price increases) and cancel-and-recreate would reset the occurrence
  history. Do not "fix" this back to parity. Cancel follows the jobs
  precedent exactly: soft-deactivate (`isActive = false`) behind a
  destructive-style confirm, wording "No more invoices will be generated.
  Invoices already created are not affected." — generated invoices are real
  receivables and are never touched. Entry: `repeat-outline` header-right
  icon on `InvoiceList` with `accessibilityLabel="Recurring invoices"` — the
  exact JobList pattern (App.tsx ~124–134).
- **`AddRecurringInvoiceScreen`** (modal; also serves Edit): customer name /
  email / phone via shared `Field`s with the `getOrCreateCustomer` upsert on
  save (the only sanctioned creation path); amount; description; cadence
  (same five options as jobs); start date (= first `nextDueDate`, default
  today) via `DateTimePickerSheet`; end condition (never / after N / by
  date); due-days field (default 30). Validation mirrors AddInvoiceScreen
  (name + positive amount required). Blueprint-styled, `createStyles`
  factory.

Both routes registered in `InvoiceStack` only (reached nowhere else);
navigation types extended in types/navigation.ts.

### 8. Edge cases

- **Catch-up after long absence** generates every missed occurrence
  (deliberate mirror of the jobs engine — the money is owed either way).
- **Past start date** on a new rule: generates immediately on next engine run
  (same as recurring jobs today).
- Rule against a renamed/deleted customer: denormalized `customerName` keeps
  working; contact snapshot blank → healed by `backfillInvoiceContacts` when
  possible.
- Notification fires but app not opened until later: generation happens on
  next open (AuthContext hook) — the notification is an invitation to open,
  not the generation trigger.
- Expo Go / notifications denied: generation still works (the sweep no-ops on
  denied permissions, engine is independent).

### 9. Testing

- `recurrence.ts` helpers: existing `recurringJobs.test.ts` passes unchanged
  (proves extraction); direct tests move/extend for cadence math + end
  conditions.
- `recurringInvoices` generator: mirror of the jobs engine suite (catch-up,
  end-by-count/date, pause, re-entry guard, batched save) PLUS generated-field
  assertions: id parses via `invoiceIssueDate`, unique ids in one catch-up
  batch, `due` derives from occurrence date + dueDays, ledger/`jobId` absent,
  linkage fields set.
- `nextInvoiceNumber` extraction: unit tests (gaps, non-numeric numbers, empty
  list) + both screens' existing suites stay green.
- `syncNotifications`: rule scheduling (active vs paused, past-due skip,
  identifier namespace, cap interaction).
- Device smoke (owner, Expo Go): create plan → backdate start → reopen app →
  invoices generated + notification; send flow → payment link mints on
  demand; pause stops generation; delete keeps generated invoices.

## Constraints honored

- JS-only → OTA-eligible (this branch carries NO native changes — the PDF
  fix's `expo-image-manipulator` lives on `feat/pdf-logo-size` precisely so
  this stays true).
- No dependency changes. Approved persisted-shape changes only (§ decisions).
- Gate green before every commit. Skill-drift flags for the phase report:
  `tradeready-config-and-flags` (new AsyncStorage key),
  `tradeready-architecture-contract` (new shared primitives:
  `utils/recurrence.ts`, `utils/invoiceNumber.ts`).

## Out of scope

- Auto-send (email/SMS) of generated invoices; any backend work.
- Syncing rules across devices.
- Attaching invoice schedules to recurring jobs ("Both" option rejected for
  now — revisit on demand).
- Line-item recurring invoices (flat amount + description only, v1).
