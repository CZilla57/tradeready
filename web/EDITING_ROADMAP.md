# Web Portal → Editing Roadmap

Status: **planning** — the portal is read-only today (see `web/README.md`,
"Scope"). This document is the plan for making it **editable** without
corrupting data the mobile app and Stripe also write.

It exists so future sessions don't re-derive the analysis. Read this first,
then `web/README.md` ("A note on the future editing surface"), then the shared
sync engine in `utils/sync.ts` + `utils/syncMerge.ts`.

## Progress

- **P0.1 — landed (write layer).** `web/src/lib/writeRepository.ts` is the
  portal's single, typed write module. It implements ledger-preserving invoice
  writes — `saveInvoice`, `recordInvoicePayment`, `markInvoicePaid`,
  `voidInvoicePayment` — each starting from the authoritative server row and
  reusing the shared ledger math (`@shared/utils/invoicePayments`), so a
  concurrently-appended payment (Stripe webhook, another device) is never
  clobbered by a whole-blob replace. Covered by `writeRepository.test.ts`.
- **P1.1 / P1.2 — landed.** Reads and writes are in distinct modules, and
  `readOnly.arch.test.ts` now allow-lists exactly `writeRepository.ts` (and
  asserts it is genuinely the sole mutation site).
- **P1.3 — partial.** Payment drafts are validated; other domains' validation
  arrives with their operations.
- **First editing surface — landed.** `InvoiceDetailScreen` wires the three
  money ops: record a payment (inline validated form), mark the balance paid,
  and void a payment (with confirm). Each disables its control while in flight
  (P2.2 double-submit + error surfacing — a failed write keeps the form open and
  shows the error, never looks saved) and re-pulls invoices from the server on
  success (P2.3 via `retry(['invoices'])`). Covered by
  `InvoiceDetailScreen.test.tsx`.
- **`saveInvoice` not yet surfaced.** Editing scalar invoice fields (amount,
  description, line items) needs its own edit form — a later step.
- **P0.4 — landed (primitive).** `writeRepository.ts` exposes typed soft-delete
  ops (`deleteInvoice`, `deleteJob`, `deleteCustomer`, `deleteExpense`,
  `deletePricebookEntry`, `deleteRecurringJob`, `deleteRecurringInvoice`). Each
  writes a `deleted:true` tombstone with a fresh `updated_at` (never a hard
  `DELETE`, which would resurrect the row on the next device pull), scoped by
  id + user_id like the mobile delete. Covered by `writeRepository.test.ts`.
  Not yet surfaced in any screen, and cross-entity cascade (e.g. an invoice
  referencing a deleted customer) is deliberately left to each delete's future
  UI, not the primitive.

- **P0.3 — APPLIED (2026-08-31).** The server-side `set_updated_at` trigger
  (`supabase/migrations/20260831_updated_at_server_authority.sql`) is live on all
  twelve sync tables — confirmed present on every one. Every write now gets an
  authoritative DB-clock `updated_at`, closing the clock-skew propagation trap
  for the web portal, all mobile versions, and the backend webhooks at once.
  Optional remaining cleanup (no correctness impact, no coordination needed):
  clients may stop sending `updated_at` — web via the single `writeTimestamp()`
  in `writeRepository.ts`, mobile via `pushQueue` in `utils/sync.ts`.
- **P0.5 — landed (primitive).** `saveSettings(patch)` merges a patch onto the
  full current settings blob (preserving unrendered fields, P0.2) and strips
  every credential field by iterating `SECURE_FIELDS` (never hand-named), so a
  legacy blob's inline `providerKey`/`anthropicKey`/`groqKey` — or one a caller
  mistakenly passes — can't reach the cloud. Upserts by user_id like the mobile
  push. Covered by `writeRepository.test.ts`; not yet surfaced in a settings
  edit UI.

- **P3 scope — DECIDED.** The editable-surface rollout order is settled under
  "Phase 3" below: (1) complete Invoices, (2) Customers, (3) Jobs & Estimates,
  (4) Pricebook/Expenses/Settings, (5) Recurring/Calendar/creation — with Today
  and Money staying read-only dashboards and Trips/Coach/photos/bookings out of
  scope. Each stage carries a five-point definition of done.

Still open below: P0.6 (derived-field invariants, handled per domain as each
editable surface lands), P2 (concurrency/resilience). P0.3's optional client
cleanup (dropping the now-redundant `updated_at` sends) is not required for
correctness.

## Context in one paragraph

The cloud model is a set of owner-scoped blob tables
`{ id, user_id, data jsonb, updated_at, deleted }` with RLS
`for all … using/with check (auth.uid() = user_id)` on every table
(`supabase/migrations/20260803_local_collections_sync.sql`). Writes from an
authenticated browser are therefore already **authorized** — the anon key +
RLS is the security boundary. The risk in editing is **not permission**; it is
that a naïve whole-blob write silently overwrites data written concurrently
elsewhere, or writes a blob that mobile devices never pull. The mobile app is
an offline-first client that pushes a durable queue and pulls with a
`gt('updated_at', since)` watermark (`utils/sync.ts`). Every constraint below
falls out of that design.

## Guiding principle

Reads (`web/src/lib/repository.ts`) and writes must stay in **separate
modules**, exposing **typed, domain-specific** operations
(`saveInvoice(...)`, `updateJobStatus(...)`) — never a generic
`write(table, id, data)`. Client code validates payloads; **Supabase RLS stays
the ownership boundary.** This mirrors `web/README.md`.

---

## Phase 0 — Prerequisites (do before any write ships)

These are correctness/data-integrity blockers. Each is grounded in existing
code; a write that ignores any one can silently lose data.

### P0.1 Ledger-preserving invoice writes (highest risk)
- **Why:** the pull side unions payment ledgers
  (`utils/syncMerge.ts` → `mergePaymentLedgers`), but **every push is a
  whole-blob replace**. The ledger grows server-side (Stripe webhook) and
  on-device at the same time. A web invoice write built from a blob loaded a
  minute ago will **overwrite payments recorded since**. `bookingRequests.history`
  is the same server-append shape.
- **Do:** invoice/booking writes must re-fetch the current row, merge the
  ledger/history (reuse the shared merge helpers), then write. Never write an
  invoice blob straight from stale local state.

### P0.2 Full-blob round-tripping
- **Why:** the portal reads only display slices, but writes are whole-blob.
  Dropping a field the web doesn't render (but mobile uses) is invisible until a
  device pulls it.
- **Do:** every edit preserves all untouched fields — merge onto the current
  full blob; never reconstruct a partial blob.

### P0.3 `updated_at` freshness / clock trust
- **Why:** device pulls filter on `gt('updated_at', since)`
  (`utils/sync.ts:166`). Mobile stamps `pushedAt = new Date()` at push time
  precisely so edits aren't invisible. A web write that omits or **backdates**
  `updated_at` never reaches phones; a browser with a skewed clock breaks
  propagation both directions.
- **Do:** choose the timestamp source deliberately. Prefer the DB
  `default now()` over the browser clock where possible (the browser is less
  trustworthy than a device). Document the choice.

- **Migration drafted — awaiting owner apply.**
  `supabase/migrations/20260831_updated_at_server_authority.sql` adds a
  `set_updated_at` BEFORE INSERT OR UPDATE trigger that stamps `now()` (the DB
  clock) on every write to the twelve sync tables, **overriding** whatever the
  client sent. Chosen over a COALESCE-only fill because the column is written
  today from many clock domains — every mobile version, the web portal, and the
  server-side Stripe / subscription / booking / estimate writers — and only an
  unconditional override collapses them to one authoritative clock.

  #### Cutover plan
  1. **Apply the migration** in the Supabase SQL editor (idempotent; safe to
     re-run). This is the whole correctness fix and requires **no app release**:
     the trigger is backward-compatible, so every shipped mobile build, the
     current web bundle, and the backends keep working — their `updated_at` is
     simply replaced server-side.
  2. **Verify** with the psql script (NOT the SQL editor — it needs one
     transaction):
     `psql -v ON_ERROR_STOP=1 "$DATABASE_URL" -f supabase/migrations/verify/20260831_updated_at_server_authority_verify.sql`
     — expect "ALL CHECKS PASSED" (trigger present on all 12 tables; INSERT /
     UPDATE / on-conflict-upsert all override a backdated value; coexists with
     the invoice payment-merge trigger).
  3. **Optional cleanup (later, no coordination needed).** Once the trigger is
     confirmed in production, clients may stop sending `updated_at` entirely —
     web via the single `writeTimestamp()` in `writeRepository.ts`, mobile via
     `pushQueue` in `utils/sync.ts`. Purely cosmetic/bandwidth; not required for
     correctness, and either surface can change independently.

  - **Caution:** the override is unconditional, so a future backfill that
    intentionally sets a historical `updated_at` must disable the trigger for
    that table first (documented in the migration header).
  - **Not applied to** tables outside the device blob-sync watermark
    (`subscriptions`, `stripe_accounts`, …) — widen only with intent.

### P0.4 Soft-delete only
- **Why:** deletes set `deleted:true` + `updated_at` (`utils/sync.ts:130`);
  mobile relies on tombstones to remove records. A hard `DELETE` resurrects the
  record on the next device that hasn't seen the change.
- **Do:** "delete" = update `deleted:true` + fresh `updated_at`. Never
  `.from(t).delete()`.

### P0.5 Settings writes strip `SECURE_FIELDS`, preserve unknown fields
- **Why:** `providerKey` / `anthropicKey` / `groqKey` must never enter a blob
  (`utils/storage/keys.ts:29`) — iterate the constant, never hand-name (that's
  how `groqKey` once leaked). Settings is a single blob; a partial write nukes
  fields the web doesn't render.
- **Do:** merge onto the full existing settings blob; strip `SECURE_FIELDS` by
  iterating the shared constant.

### P0.6 Derived-field invariants
- **Why:** `paid`/totals are derived (`reconcilePaidFields`); invoice and
  change-order math already exist in `web/src/ui/*`.
- **Do:** recompute derived fields via the shared helpers on every write so the
  blob stays internally consistent.

---

## Phase 1 — Write architecture & guardrails

### P1.1 Separate typed write module
- New `web/src/lib/writeRepository.ts` (name TBD) with domain operations only;
  reads stay in `repository.ts`.

### P1.2 Re-scope the read-only arch guard (don't delete it)
- `web/src/lib/readOnly.arch.test.ts` currently fails the build on **any**
  `.from().insert|update|upsert|delete`. Reframe to "only the write module may
  mutate" so read-only screens still can't import a write path.

### P1.3 Payload validation
- Validate shape + invariants before send, so the client never writes a
  malformed blob.

### P1.4 `id` generation matches mobile
- New records use the same id format mobile generates (`id text primary key`,
  client-generated). Confirm the format before creating records.

### P1.5 Mutation tests
- Cover each write op and its validation/failure paths (per `web/README.md`).

---

## Phase 2 — Concurrency & resilience

### P2.1 Concurrency is last-write-wins with no detection
- There is no optimistic-concurrency check anywhere today. Editing multiplies
  web-vs-mobile races. Minimum: refetch-before-write. Better: an `updated_at`
  optimistic guard so a stale save is rejected, not silently clobbered.

### P2.2 No offline queue on the web
- Mobile has a durable retry queue; the browser won't. Web writes are
  online-only → explicit save/success/failure UX, double-submit protection,
  clear error surfacing. A failed write must never look saved.

### P2.3 Post-write refresh
- Decide how the current tab and other tabs reflect an edit: optimistic local
  update + `reload()`/`retry()` (already in `web/src/lib/DataContext.tsx`), or
  Supabase realtime.

---

## Phase 3 — Product scope (DECISION)

Editable surfaces roll out in the order below — ordered by value (what is
keyboard/desk work a phone is awkward for) balanced against write-risk (how
tricky the domain's write semantics are) and reuse of what's already built.
One domain reaches "done" before the next starts; the primitive lands in the
write module first, then the screen.

**Definition of done, per editable domain** (every stage below must meet all
five):
1. A typed write op in `writeRepository.ts` (never a generic table writer).
2. Full-blob round-trip — load the current server row, merge the edit onto it,
   write (P0.2); reuse the shared merge for any domain with a server-appended
   field.
3. P0.6 derived-field reconciliation where the domain has derived fields.
4. The established UI pattern from `InvoiceDetailScreen`: in-flight disable
   (P2.2), a failed write that stays open and shows the error, and a server
   re-pull on success (P2.3).
5. Mutation tests (write op + validation/failure paths).

### Order

1. **Invoices — complete it. ✅ LANDED.** Payments already shipped; the
   `InvoiceEditor` on `InvoiceDetailScreen` now edits the invoice-local scalar
   fields (number, amount, due, description, contact email/phone) via
   `saveInvoice` — which preserves the server ledger and re-derives paid/paidAt
   from the new amount, matching the mobile edit's `reconcilePaidFields` — and
   deletes via `deleteInvoice` behind an inline confirm (then navigates to the
   list). Line-item editing is deliberately DEFERRED: line items are an immutable
   snapshot from the job estimate (mobile's Edit Invoice doesn't touch them
   either), so authoring them belongs with Estimates in stage 3. Editing the
   customer name / re-linking `customerId` is likewise deferred to stage 2
   (customer domain). Covered by `InvoiceDetailScreen.test.tsx`.
2. **Customers. ✅ LANDED.** `CustomerEditor` on `CustomerDetailScreen` edits
   name/email/phone/address/notes via `saveCustomer` (a whole-blob last-write-
   wins upsert — Customer has no server-appended field, so no merge needed),
   toggles archive via the shared `withArchived` helper (the model's safe
   soft-removal — invoices/jobs keep working), and hard-deletes via
   `deleteCustomer` behind a confirm carrying the mobile app's "invoices and jobs
   stay but unlinked" warning. NOTE (correction to an earlier draft): notes now
   live on the customer record's own `notes` field — the legacy `customer_notes`
   table is being retired (`utils/storage/customers.ts`) and the portal never
   writes it. Covered by `CustomerDetailScreen.test.tsx`.
3. **Jobs & Estimates.** Split into 3a (done) and 3b (open) once the code
   revealed the Job's consent-integrity coupling:
   - **3a — Job operational editing. ✅ LANDED.** `JobEditor` on
     `JobDetailScreen` edits title, description, address, schedule
     (date/start/end), and notes via `updateJobDetails`, plus archive
     (`setJobArchived`) and delete (`deleteJob`). CRITICAL: the Cloudflare Worker
     backend writes `approval` and `changeOrders[].approval` to the jobs table
     when a customer acts on the estimate portal (consent is frozen once
     approved), and mobile appends `timeSessions` / stamps `invoiceId`/`status`.
     So `updateJobDetails` applies the edit onto a FRESHLY re-fetched server row —
     every field the portal doesn't set (approval, changeOrders, timeSessions,
     status, invoiceId, pricing) is preserved from the authoritative server copy
     and can't be clobbered. Covered by `JobDetailScreen.test.tsx` +
     `writeRepository.test.ts` (server-authored fields survive an edit).
   - **3b — Job status transitions & estimate editing. PARTIAL.**
     - **Operational status advance. ✅ LANDED.** `StatusAdvance` on
       `JobDetailScreen` fires the two purely-operational forward transitions —
       `scheduled → in_progress` ("Start job") and `in_progress → complete`
       ("Mark complete") — via `advanceJobStatus`. The sanctioned set lives in
       `web/src/ui/status.ts` (`OPERATIONAL_STATUS_ADVANCE`), mirrored from the
       mobile pipeline `JOB_STATUSES[...].next` and asserted adjacent to
       `JOB_PIPELINE` so it can't drift; it is a small map rather than a
       pricingEngine import (`ui/pricingMath.ts` ports only that engine's
       estimate math, not its status table). The guard is authoritative on a
       FRESHLY re-fetched server row, so a job that raced ahead elsewhere (a
       phone marked it complete, an invoice moved it to `invoiced`) is rejected
       with `JobStatusTransitionError` rather than clobbered (P2.1 refetch-
       before-write); every other field (approval, changeOrders, timeSessions,
       invoiceId, pricing) rides through untouched. Unlike mobile's "mark
       complete", the portal does NOT run the opt-in auto-invoice or schedule a
       review — those are separate flows it doesn't surface; the bare status
       change is internally consistent on its own. Covered by
       `writeRepository.test.ts`, `status.test.ts`, `JobDetailScreen.test.tsx`.
     - **Still OPEN.** The consent-/invoice-coupled transitions
       (`estimate_sent → approved`, `complete → invoiced`, `invoiced → paid` —
       the portal reflects the last two from the invoice ledger, it doesn't
       drive them), plus estimate/materials authoring and approval/change-order
       handling. These need guarded, cross-entity transitions, so they stay
       deferred.
4. **Pricebook, Expenses, Settings. ✅ LANDED.** Catalog/config maintenance.
   Every editable surface below is in; the only things left read-only are
   deliberate (Pricebook pricing fields — deferred pending a web-safe estimate
   recompute; the payment processor and online-booking config — Stripe/booking
   flows that stay on mobile):
   - **Settings → Business profile, Pricing defaults, Invoicing. ✅ LANDED.**
     `ProfileEditor` edits businessName/contactName/phone/email/address/region;
     `PricingEditor` edits the seven direct-value pricing inputs (laborRate,
     materialMarkup, overheadPercent, marginPercent, minimumJobFee,
     travelFeePerMile, mileageRate — each validated non-negative, blank rejected
     rather than silently saved as 0); `InvoicingEditor` edits invoicePrefix,
     invoiceStartNumber (optional whole number; blank clears it so the util's
     "INV"/1 defaults apply), and the two auto-on-complete flags (auto-email is
     forced off whenever auto-create is off, so the pair can't drift). All three
     go through the existing `saveSettings` (merges onto the full blob, strips
     secrets) — none is a derived or cross-entity-coupled field, so no new write
     op is needed. The estimate math and auto-invoice workflow that CONSUME these
     values run on-device; the portal only stores the inputs.
     `AutomationEditor` (also LANDED) edits the five opt-in/out flags
     (autoOutreachEnabled, autoSendEmailEnabled, appointmentRemindersEnabled,
     estimateFollowUpsEnabled, reviewRequestEnabled) the same way. ⚠️ Note:
     `estimateFollowUpsEnabled` uses the REVERSE convention — ABSENT means ON
     (read as `!== false`, an explicit owner decision, types/models.ts) — so the
     editor reads it with `!== false` (the plain-`yesNo` read-only card was wrong
     for a pre-field blob) and always writes an explicit boolean.
     `ScheduleEditor` (also LANDED) edits the working pattern behind the calendar
     — work days, work hours, appointment length, buffer, and time-off blackouts,
     matching the mobile Settings → Schedule screen. Schedule is a NESTED sub-blob
     whose slot-booking fields (`bookableSlotsEnabled`, `slotLeadHours`,
     `slotWindowDays`, `timeZone`) are written by a DIFFERENT surface (the mobile
     Booking screen), so a flat `saveSettings({schedule})` would drop them; it
     therefore uses a dedicated typed op `saveSchedule(patch)` that deep-merges
     onto the freshly-loaded server `schedule` (P0.2 one level down). Values are
     normalised the way `resolveSchedule` expects (start < end, ≥1 work day,
     non-negative minutes) and validated before send; display reads through
     `resolveSchedule` so an absent/partial blob shows its effective defaults.
     `PaymentsEditor` (also LANDED) closes the section out: the processor
     (`provider`) is Stripe-onboarding-coupled and stays read-only, but
     `paymentNotes` — a plain direct-value string — is editable through
     `saveSettings`. Only online-booking (slot fields / `timeZone`) remains on the
     mobile Booking screen, by design.
   - **Pricebook → metadata + pricing. ✅ LANDED.** `PricebookEditor` on
     `PricebookDetailScreen` edits name/category/description AND the pricing
     inputs (labor hours/rate, material markup, overhead, margin) via
     `savePricebookEntry` (whole-blob; bumps the blob's `updatedAt`) and deletes
     via `deletePricebookEntry`. `estimateTotal` is a DERIVED field, recomputed on
     save by `web/src/ui/pricingMath.ts` — the web port of
     `pricingEngine.calculateEstimate` (the mobile engine isn't web-importable: it
     pulls `BadgeColor` from an RN component module, breaking typecheck
     resolution; the pure math is reimplemented web-side and pinned to the mobile
     engine's own test values, exactly like invoiceMath/changeOrderMath). The
     recompute matches the mobile PricebookEntryScreen save path
     (buildEstimateInput→calculateEstimate: travel/tax 0, non-emergency,
     `minimumJobFee` from settings), so a service priced in the portal equals one
     priced on the phone (P0.6). Material LINE ITEMS are now editable via the
     shared `MaterialsEditor` (see the line-item authoring note under stage 5c) —
     both here and on the New service form — and feed the recompute; `jobCosts`
     (direct-cost lines) still round-trip untouched, a separate authoring surface.
   - **Expenses. ✅ LANDED.** An `ExpensesSection` on `MoneyScreen` lists
     expenses and adds/edits/deletes them: `saveExpense` (whole-blob upsert; new
     records stamped with the shared `stampExpense` so ids match the mobile app)
     and `deleteExpense` (tombstone). Edits spread onto the existing record so
     hidden fields (receiptUri, jobId, importBatchId, createdAt) round-trip.
     Category select reuses the shared `EXPENSE_CATEGORIES`. Covered by
     `MoneyScreen.test.tsx`.
   Covered by `SettingsScreen.test.tsx`, `PricebookDetailScreen.test.tsx`,
   `writeRepository.test.ts`.
5. **Recurring, Calendar scheduling, and creation flows.** Recurring rules +
   maintenance plans, drag/assign-to-schedule (a `saveJob`), and net-new record
   creation (new client-generated ids, heavier validation). Last because
   creation and scheduling add the most new surface and validation. In progress:
   - **5a — Recurring pause/resume + delete. ✅ LANDED.** `RecurringScreen` rows
     now pause/resume via `setRecurringJobActive` / `setRecurringInvoiceActive`
     and hard-delete via the existing `deleteRecurring*` tombstone ops, behind an
     inline confirm, with per-row in-flight disable + error surfacing (P2.2) and a
     `retry([...])` re-pull on success. CRITICAL: both rule types carry ADVANCING
     generation state (`lastGeneratedDate`, `occurrenceCount`, `nextDueDate`)
     stamped by the mobile generation engines, so the toggle ops re-fetch the
     server row and change ONLY `isActive`. Resume asymmetry preserved (NOT
     unified): a maintenance-plan resume fast-forwards `nextDueDate` past today so
     elapsed occurrences aren't back-billed (a web-safe copy of
     `utils/recurringInvoices.ts` `fastForwardedNextDueDate` over the pure
     `utils/recurrence.ts` helpers), while a recurring-job resume keeps back-fill.
     Covered by `RecurringScreen.test.tsx` + `writeRepository.test.ts`.
   - **5b — Calendar scheduling. ✅ LANDED.** `CalendarScreen`'s "Needs
     scheduling" rows now assign a date (+ optional start/end time) inline via a
     new typed op `scheduleJob(jobId, {scheduledDate, scheduledStartTime,
     scheduledEndTime})` — the schedule flow's "saveJob". It applies onto a
     FRESHLY re-fetched server row (like `updateJobDetails`, so approval /
     changeOrders / timeSessions / invoiceId / pricing are preserved) and
     reconciles the ONE schedule-coupled derived field (P0.6): gaining a date
     advances an `approved` job to `scheduled`, matching the mobile scheduling
     action. That advance is a web-side reimplementation of `utils/jobStatus.ts`
     `advanceStatusForSchedule` (that module reaches `pricingEngine`'s
     `JOB_STATUSES`, not web-importable — same reason invoiceMath/status.ts are
     reimplemented) and keeps its no-regress/no-skip guarantee; clearing the date
     never regresses a later status. Times validated (end needs a start; end >
     start). Rescheduling an already-scheduled job still goes through
     `JobEditor`/`updateJobDetails` on the detail screen; grid drag-and-drop was
     deliberately not built (cramped, and the inline assign covers the desk task).
     Covered by `CalendarScreen.test.tsx` + `writeRepository.test.ts`.
   - **5b — Maintenance-plan rule editing. ✅ LANDED.** `RecurringScreen`'s plan
     rows now have an inline `PlanEditor` (description, amount, net terms,
     cadence, end condition + count/date, next date, auto-send) saved through a
     new typed op `updateRecurringInvoiceRule`. It applies the edited rule fields
     onto a FRESHLY re-fetched server row, preserving the plan's history (id,
     customerId/customerName, occurrenceCount, lastGeneratedDate, isActive,
     createdAt) exactly as the mobile edit's `{ ...r, ...shared }` does, and
     normalises endCount/endDate to the chosen endCondition. Validation mirrors
     mobile (amount > 0, net ≥ 0, positive end count, end date when required). A
     maintenance plan's `amount` is a flat entered value (no pricingEngine
     estimate), which is why THIS rule type is editable while RECURRING-JOB rule
     editing is deferred: a RecurringJob's `estimateTotal` is a
     `pricingEngine.calculateEstimate` derivation (not web-importable — same
     blocker as Pricebook pricing), so its rows still expose only pause/resume +
     delete, no Edit. Customer re-linking is out of scope here (customer domain).
     Covered by `RecurringScreen.test.tsx` + `writeRepository.test.ts`.
   - **5b — Recurring-JOB rule editing. ✅ LANDED.** Now that the pricingMath
     port exists, `RecurringScreen`'s job rows get an inline `JobRuleEditor`
     (title, description, the five pricing inputs, MATERIALS via the shared
     `MaterialsEditor`, cadence, end condition + count/date, next date) saved
     through a new typed op `updateRecurringJobRule`. Same shape as the plan
     editor — applies onto a freshly re-fetched server row, preserving the series'
     history (id, customerId/Name, jobCosts, occurrenceCount, lastGeneratedDate,
     isActive, createdAt) and normalising endCount/endDate — with the DERIVED
     `estimateTotal` recomputed on save via `estimateTotalFromPricing` (the port)
     over the edited materials + settings `minimumJobFee`, matching the mobile
     save. The edited materials replace the server list; `jobCosts` (direct-cost
     lines) stay preserved from the fresh row. Covered by `RecurringScreen.test.tsx`
     + `writeRepository.test.ts`.
   - **5c — Creation flows. IN PROGRESS.**
     - **New customer. ✅ LANDED.** `CustomersScreen` has a "New customer" form
       (`NewCustomerForm`) creating a record via a new typed op `createCustomer`,
       which mints a mobile-format id (`c<Date.now()>_<counter>`, matching
       `utils/storage/customers.ts` `newCustomerId`, P1.4), stamps `createdAt`,
       and upserts — the same fresh-record shape mobile writes; it navigates to
       the new record on success. Name is required, and a case-insensitive clash
       with an existing NON-archived customer is blocked in the UI (mobile's
       `upsertCustomerInList` dedupe key) rather than silently merged, so the
       portal never creates a hidden duplicate. Covered by `CustomersScreen.test
       .tsx` + `writeRepository.test.ts`.
     - **New expense. ✅ ALREADY LANDED (stage 4).** `MoneyScreen`'s
       `ExpensesSection` add flow stamps the mobile-format id via the shared
       `stampExpense` and saves through `saveExpense`.
     - **New pricebook entry. ✅ LANDED.** `PricebookScreen` has a "New service"
       form (`NewServiceForm`) creating a record via a new typed op
       `createPricebookEntry`, which mints a mobile-format id (`pb-<Date.now()>`,
       monotonic-guarded for burst uniqueness, matching PricebookEntryScreen,
       P1.4), stamps created/updatedAt, and upserts. The derived `estimateTotal`
       is computed with the pricingMath port over the entered pricing inputs and
       any materials authored via the shared `MaterialsEditor` + settings
       `minimumJobFee`, matching the mobile save; blank category/description
       collapse to `undefined`. Navigates to the new record on success. Covered by
       `PricebookScreen.test.tsx` + `writeRepository.test.ts`.
     - **New maintenance plan (recurring invoice). ✅ LANDED.** `RecurringScreen`
       has a "New plan" form (`NewPlanForm`) creating a standalone plan via a new
       typed op `createRecurringInvoice`, which mints a mobile-format id
       (`ri<Date.now()>`, monotonic-guarded, P1.4), initialises a FRESH series
       (occurrenceCount 0, lastGeneratedDate null, isActive true), and normalises
       endCount/endDate — matching the mobile AddRecurringInvoiceScreen create
       (no first invoice is generated; the engine emits on its next run). The
       customer is PICKED from existing records (a plan needs id + denormalized
       name; inline customer creation belongs to the customer screen — the form
       prompts to add a customer first when none exist). Validation mirrors mobile
       (customer, amount > 0, net ≥ 0, positive end count, end date when required).
       Covered by `RecurringScreen.test.tsx` + `writeRepository.test.ts`.
     - **New job (unpriced lead). ✅ LANDED.** `JobsScreen` has a "New job" form
       (`NewJobForm`) creating a record via a new typed op `createJob`, which
       mints a mobile-format id (`j<Date.now()>`, monotonic-guarded, matching
       AddJobScreen, P1.4) and writes the exact fresh-record shape mobile's
       unpriced-job path writes: `status: 'lead'`, estimateTotal 0, laborHours 0,
       empty materials, `invoiceId: null`, `createdAt` today. A brand-new id
       means a pure insert (no server row to preserve). The customer is PICKED
       from existing records (a job needs id + denormalized name; inline customer
       creation stays on the Customers screen) and a title is required; the four
       rate fields (laborRate/materialMarkup/overhead/margin) are SEEDED from the
       Settings business defaults (mobile's `settings.overheadPercent`/
       `marginPercent` → job `overhead`/`margin`), so the eventual estimate uses
       the owner's rates. Estimate/pricing/materials authoring is the deferred
       part of 3b, so creation stops at the operational shell. Navigates to the
       new record on success. Covered by `JobsScreen.test.tsx` +
       `writeRepository.test.ts`.
     - **New invoice (manual). ✅ LANDED.** `InvoicesScreen` has a "New invoice"
       form (`NewInvoiceForm`) creating a standalone MANUAL invoice via a new
       typed op `createInvoice` — the AddInvoiceScreen analog, NOT the
       create-from-job path (which snapshots the estimate's line items). It mints
       a mobile-format id (`String(Date.now())`, monotonic-guarded, P1.4) and
       writes the fresh-record shape mobile writes: `paid: false`, no ledger, no
       `lineItems`/`jobId` (a pure insert — no server row to merge). The number
       defaults to the shared `nextInvoiceNumber(invoices, settings)` (honouring
       the Settings prefix/start), overridable — keeping the numbering rule
       single-sourced. The customer is PICKED from existing records, setting both
       the denormalized `customer` name and the `customerId` link and adopting the
       customer's contact snapshot (editable), mirroring mobile's
       getOrCreateCustomer denormalization. Validation mirrors the InvoiceEditor
       (amount > 0, a due date, a number). Line-item authoring stays deferred (an
       estimate-snapshot concern). Covered by `InvoicesScreen.test.tsx` +
       `writeRepository.test.ts`.
     - **New recurring job. ✅ LANDED.** `RecurringScreen` has a "New job" form
       (`NewJobRuleForm`) creating a recurring-JOB rule via a new typed op
       `createRecurringJob`, which mints a mobile-format id (`rj_<Date.now()>`,
       monotonic-guarded, P1.4). DECISION — fresh series, NOT mobile's coupled
       spawn: mobile's create also writes a first Job occurrence (occurrenceNumber
       1), but the portal instead initialises a fresh series (occurrenceCount 0,
       lastGeneratedDate null, isActive true) and lets the generation engine emit
       the first occurrence on its next run — exactly the choice
       `createRecurringInvoice` already made for plans, keeping the op a
       single-entity insert (no two-blob write that could half-fail). The customer
       is PICKED from existing records; the derived `estimateTotal` is recomputed
       the mobile way via the `estimateTotalFromPricing` port over the five pricing
       inputs (seeded from the business defaults) AND any materials authored via
       the shared `MaterialsEditor`. `address`/`notes` start blank (not in the
       recurring-job editable surface). Covered by `RecurringScreen.test.tsx` +
       `writeRepository.test.ts`.
     - **Line-item / materials editor. ✅ LANDED (reusable component + Pricebook).**
       `web/src/ui/MaterialsEditor.tsx` is a reusable `Material[]` row editor
       (add / edit name-qty-unitCost / remove, with a live materials-cost preview)
       backed by pure string-draft helpers in `web/src/ui/materialsDraft.ts`
       (`parseMaterialDrafts` drops abandoned blank rows and validates the rest;
       new ids match the mobile `m<Date.now()>` format, P1.4). It is STRING-drafted
       like every other pricing field so mid-edit values ("1." / "") don't snap to
       a number, parsed to stored `Material[]` only on save. Wired into the
       Pricebook surfaces (the `PricebookEditor` edit form and the New service
       form) AND the recurring-job surfaces (the `JobRuleEditor` edit form and the
       New recurring-job form), so their materials — and thus their derived
       `estimateTotal` — are now fully authored in the portal. Covered by
       `materialsDraft.test.ts`, `PricebookDetailScreen.test.tsx`,
       `PricebookScreen.test.tsx`, `RecurringScreen.test.tsx`.
     - **Remaining: a Job's own estimate (OPEN).** A plain Job still has no
       pricing/materials editor: it needs a new `JobPricingEditor` on
       `JobDetailScreen` + an `updateJobPricing` write op (fresh-row merge
       preserving approval / status / invoiceId / changeOrders / timeSessions),
       which can drop in the same `MaterialsEditor`. Job estimate authoring also
       carries the deferred 3b approval/change-order surface. This is the last
       remaining editable surface.

### Stays read-only / out of scope

- **Today** and **Money** are derived dashboards — no direct edits; they reflect
  edits made on the source screens.
- **Trips** and the **AI Coach** are still not surfaced in the portal at all
  (Trips need a screen first; the Coach needs the Worker backend). Not editable
  because not present.
- **Job photos** and **booking requests** blobs exist but aren't surfaced;
  excluded until they have a read surface, and booking `history` is
  server-appended (treat like the invoice ledger if it ever becomes editable).

This order is the recommendation of record; it can be resequenced if a
particular surface becomes more urgent, but each stage keeps its five-point
definition of done.

---

## Quick reference — files that constrain the design

| File | Why it matters to editing |
| --- | --- |
| `utils/sync.ts` | Push (whole-blob replace, soft delete, `updated_at` at push time) + pull (`gt('updated_at', since)` watermark). |
| `utils/syncMerge.ts` | Invoice ledger + booking history unions — the merge the push side does **not** do. |
| `utils/storage/keys.ts` | `SECURE_FIELDS` that must never reach a blob. |
| `web/src/lib/repository.ts` | Read layer; writes go in a sibling module, not here. |
| `web/src/lib/readOnly.arch.test.ts` | The guard to re-scope, not delete. |
| `web/src/lib/DataContext.tsx` | `reload()` / `retry()` for post-write refresh. |
| `web/src/ui/invoiceMath.ts`, `changeOrderMath.ts`, `pricingMath.ts` | Shared derived-field math reimplemented web-side (the mobile modules pull RN); reuse on write. `pricingMath.ts` is the `pricingEngine.calculateEstimate` port that unblocks Pricebook pricing and (still open) recurring-JOB estimate editing. |
| `supabase/migrations/20260803_local_collections_sync.sql` | RLS `for all` — writes are already authorized. |
