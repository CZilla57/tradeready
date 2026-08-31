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
- **Not yet wired to the UI.** No screen imports the write module — the editing
  surface (forms, buttons) is the next step, and is what will exercise P2.2/P2.3.

Still open below: P0.3 (durable server-side `updated_at`), P0.4 (soft-delete
op), P0.5/P0.6 for other domains, P2 (concurrency/resilience), P3 (scope).

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

## Phase 3 — Product scope

- **Which screens become editable, in what order.** Suggest starting narrow
  (e.g. invoices/jobs/customers) rather than all 15 screens at once.
- **Out of scope today:** Trips, job photos, booking requests aren't surfaced in
  the portal at all — decide explicitly whether editing includes them.

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
