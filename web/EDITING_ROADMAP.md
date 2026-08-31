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
3. **Jobs & Estimates.** `saveJob` on the shared Job model — status, schedule,
   materials, customer link; estimate-stage editing (line items, approval) is
   the same write. The core workflow object, but the trickiest for P0.6 (job
   status ↔ invoice coupling, profitability derivations) and for concurrency, so
   it comes after the pattern is proven on simpler domains.
4. **Pricebook, Expenses, Settings.** Catalog/config maintenance:
   `savePricebookEntry`, expense add/edit (Money), and wiring the existing
   `saveSettings` into the read-only SettingsScreen. Simpler blobs; the settings
   primitive already exists.
5. **Recurring, Calendar scheduling, and creation flows.** Recurring rules +
   maintenance plans, drag/assign-to-schedule (a `saveJob`), and net-new record
   creation (new client-generated ids, heavier validation). Last because
   creation and scheduling add the most new surface and validation.

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
| `web/src/ui/invoiceMath.ts`, `changeOrderMath.ts` | Shared derived-field math to reuse on write. |
| `supabase/migrations/20260803_local_collections_sync.sql` | RLS `for all` — writes are already authorized. |
