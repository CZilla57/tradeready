# Phase 8 — Contract Decisions (Task 8.00)

**Date:** 2026-09-20
**Status:** Contract frozen for independent native work; backend implementation pending (tasks 8.04–8.06).
**Spec:** [Calendar, booking, routes and portals](native-phase-8-calendar-booking-routes-portals-spec.md)
**Plan:** [native-phase-8-implementation-plan.md](native-phase-8-implementation-plan.md) (task 8.00 only)

Task 8.00 depends on nothing. This document is the entire backend-dependent
contract surface: every backend-dependent task (8.04–8.08, 8.10, 8.11, 8.13,
8.14) gets either an exact contract below or a named blocker in §12. No
implementation file was changed to produce it; current behavior was recorded
in fixtures/tests only (§13).

Rules honored while writing: no invented backend guarantees (unproven behavior
is labeled `BLOCKED`/`DEFERRED`, never specified as fact); a mocked 409 is
characterization, not database race evidence; no shared-file edits; no commit
or deploy.

## 0. Prerequisite report

**Satisfied (read before writing):** roadmap Phase 8 (Not started; guiding
constraint 7 — backend stays RN-compatible — governs every decision below);
the spec; `utils/scheduleConfig.ts`, `scheduleSmarts.ts`, `calendar.ts`,
`availability.ts`; `utils/storage/bookingConversion.ts`,
`bookingRequests.ts`, `bookingAttention.ts`, `utils/bookingLink.ts`,
`bookingRespond.ts`, `utils/portalLink.ts`, `utils/archive.ts`,
`screens/RouteScreen.tsx`, `utils/storage/dailyOps.ts`;
`backend-workers/lib/booking/{store,reserve,manage,respond,slots,availability,ics}.js`
plus route wrappers and `mint.js`; `backend-workers/lib/estimate/{portalTokenStore,portalManage,portalStore,portalRequest,portalIcs,portalAssemble}.js`;
`supabase/migrations/20260804_booking_requests.sql`,
`20260807_booking_reservations.sql`, `20260807_portal_tokens.sql`,
`20260807_portal_access_log.sql`; oracle suites listed in §13; existing
uncommitted work (Phase-7 estimate-revision/account-deletion files, untracked
`native/` host-test tree) — none touched, none conflicting (all new files).

**Missing, reported not blocking (independent work continues):**

- M1. No runnable local PostgreSQL concurrency harness exists in the repo
  (backend `test` script is jest; the `backend-workers` `test` script is `node --test`
  with two unrelated suites). Real competing-session proof is DEFERRED to
  Phase 12 / task 8.14. Mock-level 409s below are explicitly not race proof.
- M2. `tradeready-legal` (hosted `book.html`/`booking.html`/`portal.html`)
  is unavailable: browser-side rows are dependencies, not passes.
- M3. No `btree_gist` approval/process: the exclusion-constraint hardening
  in §4 stays optional until then; the chosen design avoids the extension.

## 1. Proposed `POST /api/booking/admin` — exact contract (G3)

Owner bearer JWT (same `auth/v1/user` resolution as `bookingMintHandler`),
per-user rate limit 10/window (mint precedent), base path under the Workers
router next to the existing booking routes. Additive: `mint` route and all
public shapes are untouched.

### 1.1 Request

```ts
type BookingAdminAction = "mint" | "set_enabled" | "rotate" | "status";

interface BookingAdminRequest {
  action: BookingAdminAction;
  /** Required for mint/set_enabled/rotate; ignored for status. */
  operationId?: string;      // UUID v4, client-generated, see §1.3
  /** Required for set_enabled. */
  enabled?: boolean;
  /** Required when the mutation must not clobber a newer revision (§1.4). */
  expectedRevision?: number;
  /** Status only: the caller's display copy, to validate currency (§7). */
  token?: string;            // 48 hex chars
}
```

Validation failures are 400 with the existing vocabulary (`Missing link
parameters.` / `Invalid action.` style — exact strings frozen at
implementation, reusing current messages where applicable).

### 1.2 Response

```ts
interface BookingAdminResponse {
  ok: true;
  enabled: boolean;
  /** mint/rotate only. Returned EXACTLY ONCE per operation (replay returns
      the stored copy, §1.3). Never logged, never stored server-side. */
  token?: string;            // 48 hex chars
  /** Monotonic per-owner booking-admin revision (§1.4). */
  revision: number;
  /** Echo of the request operationId for mutating actions. */
  operationId?: string;
  /** Status only. */
  tokenValid?: boolean;      // does `token` match current authority?
}
```

- `mint` with an enabled token already present → 409 `{error:"already_exists"}`
  (portal P1 parity). `rotate` works from zero rows (rotate-as-create, portal
  parity). `set_enabled` with no state row → 404 `{error:"Not found"}`.
- `status` with no state row → 200 `{ok:true, enabled:false, revision:0,
  tokenValid:false}` (never 404 — a fresh owner has nothing to reconcile).
- `status` never returns a token. A present-but-stale display token gets
  `tokenValid:false` and the UI shows the §7 recovery path, never a share URL.

### 1.3 Operation replay lifetime

New table `booking_operations`:

```sql
create table if not exists public.booking_operations (
  operation_id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  action text not null,
  request_hash text not null,   -- sha256 of canonicalized mutating fields
  response jsonb not null,      -- exact bytes to replay
  created_at timestamptz not null default now()
);
```

- Same `operationId` + same `request_hash` within lifetime → 200 with the
  stored response; no new side effects (this is the response-loss recovery:
  retry returns the same capability, never a second one).
- Same `operationId` + different `request_hash` → 409
  `{error:"operation_conflict"}` (client reused an ID for a new intent).
- Lifetime: **30 days**. Enforcement is lazy (replay lookup filters
  `created_at > now() - interval '30 days'`; a best-effort delete sweeps
  expired rows on read). No pg_cron/extension dependency. After expiry the ID
  is unknown → treated as a new operation.
- Scope: per-owner. A replay for another owner's ID is 404 (ownership
  follows the booking-respond convention: foreign = unknown, no oracle).

### 1.4 Version / conflict contract

New table `booking_link_state` (one row per owner):

```sql
create table if not exists public.booking_link_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  token_hash text,                       -- sha256; null when never minted/disabled-to-none
  enabled boolean not null default false,
  revision integer not null default 0,   -- bumped on every committed mutation
  adopted_at timestamptz,                -- NULL = pre-adoption, see §5
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
```

- Every committed mutating action bumps `revision` by exactly 1 inside the
  same transaction that writes the token row and the operations row.
- `expectedRevision` present and ≠ current → 409 `{error:"stale_revision",
  enabled, revision}` (current state echoed so the caller can reconcile
  without a second round trip). Absent → last-writer-wins (legacy/RN
  compatibility; native always sends it — 8.07/8.08).
- Raw-token recovery/storage: the server stores **hashes only** (portal
  precedent). There is **no raw-token recovery endpoint by design**; a lost
  display copy with `tokenValid:false` recovers via confirmed `rotate` (new
  `operationId`). `rawRecoverable` is therefore not a response field — the
  recovery path is rotation, stated here so no task invents a reveal API.

### 1.5 Error contract (reused vocabulary)

400 invalid shape/action; 401 auth failure; 404 unknown/disabled/foreign
(record/owner confusion gives nothing away); 409 `already_exists` /
`operation_conflict` / `stale_revision` / `slot_taken` / `invalid_state`;
429 rate limit (never retried in a tight loop); 5xx server failure. Timeouts
after a mutation are **unknown outcome**: the client replays `status` (same
`operationId` for mutations), never auto-mints/rotates again.

## 2. SQL transaction / RPC boundaries (G1/G2)

### 2.1 Per-owner reservation RPC — `claim_booking_slot` (G1)

One database transaction (PostgREST RPC, `security definer`, service role),
serialized per owner by `SELECT ... FOR UPDATE` on a per-owner sentinel row
(`booking_link_state` row for the owner; inserted on backfill/adoption so it
always exists when the RPC runs):

1. Lock sentinel row (`booking_link_state WHERE user_id = … FOR UPDATE`).
   All booking mutations for the owner take this lock first — this is the
   lock ordering root (§2.3).
2. Revalidate inside the txn: token hash + enabled (authority per §5) and
   slot configuration from the settings blob read **in the same snapshot**.
3. Recompute busy intervals in-txn: live jobs (non-terminal statuses) with
   the §2.4 duration/buffer predicate, plus `status='booked'` reservations.
4. On match: `INSERT` reservation row AND request row atomically; bump
   nothing else; return the offer. On mismatch: raise `slot_taken`.
5. Any error rolls back both inserts — **no compensation delete, no orphan
   hold** (the current reserve-then-compensate split is retired inside the
   RPC; the existing `insertReservation`/`deleteReservation` helpers remain
   for the pre-RPC code path until 8.04 lands, then are removed from the
   reserve path).

Result: same-start, different-start overlap, buffer-only, and disjoint cases
all serialize on the owner lock; exactly one winner per conflicting
interval. Cross-owner claims never conflict (all predicates owner-scoped).

### 2.2 Lifecycle RPC — `transition_booking` (G2)

One transaction per transition (customer manage actions and owner respond):

1. Same owner-lock ordering root first (§2.3).
2. `UPDATE ... WHERE id = … AND status = <expected>` style guarded write
   (expected-state predicate in the statement, not read-then-write in JS):
   zero rows → 409 `invalid_state` with current `{status}` echoed.
3. In the same txn: flip reservation status (release where applicable),
   patch request status, append exactly one server-authored history entry.
4. Retry semantics: a retry after a committed transition reads the new state
   and gets 409 `invalid_state`; the client then performs an authoritative
   status read — **if the status equals the intended target, the retry is a
   success** (documented success-equivalent, implemented in 8.07, not
   server magic).

### 2.3 Lock ordering

`booking_link_state` (owner sentinel) → `booking_reservations` →
`bookingRequests` → `settings`/`jobs` blob reads. Every RPC acquires in this
order and never in reverse. Owner manual schedule conflicts remain allowed
(warning-only, RN parity) and are ordered *after* claims: a claim that
committed first wins; a later manual overbook warns (existing conflict
infrastructure) but is never silently dropped.

### 2.4 Duration / buffer predicate (exact)

Candidate interval `[start, start+duration)` conflicts with a busy interval
`[bStart, bEnd)` iff `start < bEnd + buffer AND bStart < start + duration +
buffer`, with busy ends derived by `blockWindow` (missing end →
`max(laborHours, 1h)`, capped at midnight) and both sides clipped to
`[0, 1440)`. This matches `computeCandidateSlots`/`busyWindowsFor` exactly:
the RPC reuses the same arithmetic (server twin already exists in
`lib/booking/availability.js`; 8.04 moves its evaluation inside the txn
rather than changing it). Terminal statuses
(`complete/invoiced/paid/declined`) and missing-start jobs never block.
Touching endpoints are legal (strict inequality preserved).

### 2.5 Job / settings concurrent-write semantics

Jobs and settings stay blob tables (no schema rewrite). The RPC reads them
inside its snapshot under the owner lock, so a concurrent device job/settings
save serializes behind the claim; the loser retries against the new snapshot
and gets `slot_taken`/`slot_changed` rather than silently overbooking.
Buffer/duration edits between offer and claim are therefore always honored
at claim time (stale hosted pages can never book an invalid slot — the
current membership check, moved in-txn).

### 2.6 Request / hold rollback; legacy Data API field protection

- Rollback: atomic dual-insert (§2.1 step 4) replaces compensation. Until the
  RPC ships, the current best-effort `deleteReservation` stays, with its
  orphan-hold residual pinned by test (G1-05).
- Legacy Data API writes: the owner's device retains RLS write access to
  blob tables (sync depends on it). The server treats device-written
  lifecycle fields as untrusted for auth/claim decisions; authoritative state
  is what the RPCs committed. Device-side protection is by construction in
  native (field-scoped current-ID mutations, 8.08) and by convention in RN:
  never whole-blob replay a stale request as a decision — refresh-then-act,
  with 409 `invalid_state`/`stale_revision` as the backstop, not the plan.

## 3. Booking token legacy handoff (G3)

- **Pre-adoption** (`adopted_at IS NULL`): public resolution is today's
  behavior verbatim — settings JSON-path lookup, enabled-gated, unknown and
  disabled indistinguishable 404. Old mint + whole-settings sync keeps
  working; no RN change required to stay live.
- **Initial backfill** (deployment step 3, §10): one row per settings blob
  carrying `bookingLink.token`: `(user_id, sha256(token),
  enabled=(enabled!==false), revision=1, adopted_at=NULL)`. Validation query
  must show row-count == distinct blob-token count and zero hash mismatches
  before the Workers deploy proceeds.
- **Adoption:** the first owner admin *mutation* sets `adopted_at=now()` and
  bumps revision. `status` never adopts (read-only).
- **Post-adoption:** public resolution uses `booking_link_state` ONLY
  (hash match + enabled). Blob token/enabled writes are auth-inert: a stale
  RN/Swift whole-settings push **cannot resurrect** a disabled/rotated token
  (the server never reads settings for booking auth again). Display-copy
  divergence is possible (RN shows stale link state) — that is limitation L1
  (§6), not a revocation failure.
- **Stale-settings behavior matrix** is §6 (each legacy/adopted combination
  has a row; no silent inference between intentional rotation and delayed
  replay).

## 4. Portal single-current-token / disabled-token rules (G4)

Chosen invariant (8.06 implements; current code characterized in G4-02):

- At most **one non-revoked row** per `(user_id, customer_id)`, enforced by a
  partial unique index `... WHERE revoked_at IS NULL` (additive, §10).
- `mint` → 409 `already_exists` if ANY non-revoked row exists (change from
  today's enabled-only check, which permits a second row after disable —
  pinned gap G4-02). Re-enable via `set_enabled(true)`; destruction only via
  `rotate`.
- `set_enabled` patches the single non-revoked row (keeps today's
  `revoked_at IS NULL` filter; with the invariant there is at most one
  target, so unexpected mass-reactivation is impossible by construction).
- `rotate` = one transaction: revoke-all (stamp `revoked_at`) + insert fresh
  + write `portal_operations` replay row. Current read-then-mint /
  revoke-then-insert splits retire inside the txn (8.06).
- Rotation recovery: same `operationId` replay table as §1.3
  (`portal_operations`, 30-day lazy-TTL). Local-mirror failure after server
  success → `status` read shows `tokenValid:false` → explicit confirmed
  rotate with a NEW `operationId` (never silent re-mint: a timeout is unknown
  outcome, §1.5).
  *Note (2026-09-26, Phase 12 task 12.00b.2-I, defect `P12-013`):* when the
  device staged the server's result (booking or portal), launch and activation
  first read `status` with the staged token. `tokenValid:true` adopts it into the
  display copy (the §6 rule; no mutation, no new `operationId`).
  `tokenValid:false` or a 404 drops the staged item. The explicit rotate above
  stays the path when nothing was staged.
- Unknown-token fallback restricted to **unadopted** customers: post-adoption
  (≥1 `portal_tokens` row for the customer), an unknown hash fails closed
  (404) even if a stale enabled blob token exists — pinned residual G4-05
  becomes a passing 404 after 8.06. Read-path lazy backfill is retained ONLY
  for the zero-rows (unadopted) case and never authorizes on failure.
- Out of scope, restated (not re-promised): portal entry revocation does not
  revoke previously issued estimate/payment/manage links or signed-photo URLs
  (15-min TTL + private cache); capability-expiry limits stay as documented.

## 5. Post-adoption RN administration matrix (G3)

Mechanism: `adopted_at` (§3) IS the server-verifiable discriminator — no
payload sniffing, no inference. Rows:

| # | Actor / payload | Pre-adoption | Post-adoption |
|---|---|---|---|
| R1 | Public book/slots/submit/reserve with backfilled token | works (blob) | works (state table; hash backfilled) |
| R2 | Pre-adoption mint/rotate via old flow (server mint + blob write) | works, authoritative | n/a (adopted only via admin) |
| R3 | Post-adoption mint/rotate/enable via `POST /api/booking/admin` | n/a | works; revision+1; replay-safe |
| R4 | Delayed whole-settings write carrying an OLD token/enabled=true | authoritative (LWW, today's behavior) | **auth-inert** (cannot resurrect; L1 display divergence possible) |
| R5 | Old-RN rotate post-adoption (blob-only write, no admin call) | n/a | auth-inert; RN must surface "link management needs update" (L1) |
| R6 | Retried mutation with same `operationId` (response loss) | n/a (no dedupe today) | same stored response, no second capability |
| R7 | `status` reconciliation read | n/a | always available; never adopts; never leaks a token |

Limitation L1 (named, accepted): RN releases without the admin call cannot
rotate/disable post-adoption; their blob writes are safely inert rather than
destructive. The RN OTA adding admin calls (with `expectedRevision`) is
deployment step 5 (§10); until then R5 shows the update prompt.

## 6. Authoritative booking / portal reconciliation (8.07 reads)

- Booking: `POST /api/booking/admin {action:"status", token?}` → §1.2 status
  shape (`enabled`, `revision`, `tokenValid`; never a token).
- Portal: extend `portal-manage` with `action:"status"`:
  request `{action:"status", customerId, token?}` (display copy, optional) →
  `{ok:true, enabled:boolean, tokenValid:boolean, adopted:boolean}`.
  `already_exists` semantics unchanged; unknown/foreign customer stays 404.
- Native rule (8.07/8.08/8.13): share/adopt a display token ONLY when
  `tokenValid:true` on a fresh read; otherwise show recovery/unavailable. An
  eventually synced display copy is never proof of currency. Mutation replay
  alone never discovers another device's later rotation — `status` polling
  around link screens does.
- Backfill racing rotation: backfill inserts use `ignore-duplicates`; a
  conflicting/failed backfill never authorizes (resolver fails closed when
  adopted, §4). Covered by G4-05/G4-06 and 8.14 competing-session rows.

## 7. Replacement-schedule publication proof (B4 reschedule)

Native `resolve_reschedule` is a two-phase commit (8.08 implements; server
preconditions frozen here):

1. Durably save the revised job schedule locally and enqueue sync; await the
   Data API acknowledgment for the EXACT job mutation (record id +
   `updated_at` ≥ local write stamp).
2. Call respond with proof:
   `{requestId, action:"resolve_reschedule", scheduleProof:{jobId, updatedAt, date, start}}`.
   The `transition_booking` RPC verifies in-txn that the job blob still
   carries `(date, start)` with `updated_at ≥ proof.updatedAt`; mismatch →
   409 `{error:"schedule_changed"}` and the hold is NOT released.
3. Only on success does the server transition to `confirmed` and release the
   old reservation. A superseding schedule edit after proof generation
   therefore refuses rather than resolving against the wrong slot.
4. Legacy RN calls carrying no `scheduleProof`: accepted (constraint 7) but
   unverified — limitation L2. The server records the transition without
   publication evidence; 8.14 qualifies the divergence. Native never sends
   proof-less resolves.
5. *Note (2026-09-26, Phase 12 task 12.00b.2-I, defect `P12-013`):* a staged
   proof is kept only while step 2 can still succeed. It is kept while the
   request is still `reschedule_requested` and the job still carries the proven
   `(date, start)`. Launch and activation remove any other proof. Native never
   resends a resolve on its own; the owner retries.

Manage/ICS slot presentation (frozen): `GET manage` and `?format=ics`
return the ORIGINAL booked `request.slot` forever — `request.slot` is
immutable history. The replacement schedule lives on the job and surfaces
via portal appointments (convertedJobId-linked). No UI may present the ICS
slot as the current appointment once a reschedule has published.

## 8. Intake decisions (B3)

- D-B3-1 **Confirmed-before-conversion (intentional difference, chosen):**
  current RN converts only `new` and unconverted `booked`; `confirmed` and
  `reschedule_requested` rows wait for a later pass and are invisible to
  intake meanwhile. Native 8.02 converts ALL unconverted slot bookings
  (`booked`/`confirmed`/`reschedule_requested` with `kind=="booked"` and no
  `convertedJobId`), preserving status, and surfaces unconverted active
  bookings for inspection — so a confirmed booking can never disappear from
  owner intake. Fixtures B3-01…B3-04 pin both behaviors.
- D-B3-2 **Cross-device customer duplication (limitation L3, retained):**
  deterministic job IDs (`jbk_<requestId>`, never overwrite) are kept;
  customer creation stays time-based (RN parity). Two devices converting the
  same request concurrently may each create a Customer; the existing
  duplicate-detection/merge flow surfaces the pair. No server-side customer
  dedupe (would require customer authority — out of scope).
- D-B3-3 `portal_change_requested` never converts (stays inert, `handledAt`
  dismissal only). Portal follow-up `new` rows convert with
  `sourceCustomerId` linkage; dangling IDs fall back to upsert. Unknown
  statuses stay intact/inert. Conversion runs after verified pull, serialized,
  rechecking current records; no-op enqueues nothing.
- D-B3-4 Server lifecycle/history arriving late (either client) survives
  conversion/`handledAt` updates: conversion merges owned fields only
  (`convertedJobId`, `convertedCustomerId`, status `new→converted`) and
  preserves `history`/server status — 8.08 implements, 8.14 qualifies.

## 9. Rescheduled manage / ICS; archived semantics

- Manage view + ICS present the original booked slot (§7, pinned G2-08).
- Portal ICS (owner-scheduled jobs): floating local time, all-day when
  untimed — unchanged.
- **Archived gap (pinned, fix assigned to 8.06/8.14 lane, not assumed):**
  canonical archive marker is `archivedAt` (`utils/archive.ts`), but
  `portalAssemble` and `portalIcs` filter on `d.archived` — a field RN never
  sets. Today, an `archivedAt`-archived job is STILL served by portal view
  and ICS (pinned G4-08). Frozen fix: backend checks
  `(d.archived || d.archivedAt)` (additive, compat-safe); native route
  membership keeps the source behavior (no archive filter in
  `loadJobsForDate`/RouteScreen — pinned R1-01) until 8.14 freezes any
  cross-client correction with explicit fixtures. Calendar keeps
  per-selector behavior (`selectUnscheduledApproved` excludes archived;
  `buildCalendarDay` renders terminal history) — no blanket filter.

## 10. Additive deployment order / constraints / rollback / RN compat

Order (each step validates before the next):

1. Additive SQL only: `booking_link_state`, `booking_operations`,
   `portal_operations`, portal single-non-revoked partial unique index.
   Keep the existing booking identical-start unique index (still the
   backstop until RPCs ship). No column rewrites, no token/schema migration
   by assumption.
2. Backfill `booking_link_state` (`adopted_at=NULL`) + validation queries
   (row-count == distinct blob tokens; zero hash mismatches; portal: every
   blob-token customer has ≤1 non-revoked row after consolidation — conflicts
   resolved by keeping the blob token row and revoking others, logged).
3. Deploy Workers with adoption-gated dual reads (pre-adoption paths byte
   identical to today). Verify with RN compatibility tests (below).
4. Native 8.04→8.05→8.06 (backend lane, serial), then 8.07 transports.
5. RN OTA: admin/status calls + "management needs update" prompt (L1) +
   proof-carrying resolve (L2). Until adopted fleet-wide, R4/R5 rows apply.
6. Adoption happens per-owner on first admin mutation — no flag day.

Rollback: pre-adoption, new tables are inert (drop-safe). Post-adoption
per-owner rollback = set `adopted_at=NULL` (reverts to blob authority;
admin rows retained for audit). RPC deploy rollback = previous Worker
bundle (dual-read code paths are additive; old bundle ignores new tables).

RN compatibility tests (run on every backend change; 8.14 re-runs oracles):
old-client create/rotate/enable pre-adoption; stale whole-settings replay
post-adoption (must be auth-inert); legacy public access post-adoption;
proof-less resolve accepted (L2); unknown/foreign 404 indistinguishability;
429/5xx/timeout handling; `already_exists` stale-Create adoption (portal).

## 11. Decision table (chosen / blocked)

| # | Decision | State | Reason / owner |
|---|---|---|---|
| C1 | `/api/booking/admin` shapes, replay, errors (§1) | CHOSEN | 8.05 implements verbatim |
| C2 | Hash-only token storage; rotation-only recovery (§1.4) | CHOSEN | portal precedent; no reveal API |
| C3 | `claim_booking_slot` / `transition_booking` RPCs, lock order, buffer predicate (§2) | CHOSEN | 8.04 implements; DB proof deferred M1 |
| C4 | Owner-lock serialization instead of exclusion constraint | CHOSEN | no `btree_gist` dependency (M3); exclusion stays optional hardening |
| C5 | Adoption-gated legacy handoff + backfill (§3, R1–R7) | CHOSEN | 8.05; discriminator is `adopted_at`, not inference |
| C6 | Portal single-non-revoked invariant + 409 rule change (§4) | CHOSEN | 8.06; current gap pinned G4-02 |
| C7 | `status` reconciliation reads for both link families (§6) | CHOSEN | 8.05/8.06 add; 8.07 consumes |
| C8 | Publication-proof resolve + immutable request.slot (§7) | CHOSEN | 8.04 preconditions; 8.08 two-phase; legacy L2 accepted |
| C9 | Convert confirmed/reschedule_requested on first pass (D-B3-1) | CHOSEN (intentional RN difference) | 8.02; surfaced, never silent |
| C10 | Customer-dup limitation retained (L3) | CHOSEN (limitation) | 8.02 documents; merge flow surfaces |
| C11 | Manage/ICS show original slot; portal shows job schedule (§7/§9) | CHOSEN | 8.11 presents both, never rewrites |
| C12 | Portal archive check becomes `(archived \|\| archivedAt)` | CHOSEN (fix pending) | 8.06/8.14; current leak pinned G4-08 |
| C13 | Real DB concurrency evidence | BLOCKED (M1) | no local PG harness; Phase 12 / 8.14 |
| C14 | Exclusion-constraint hardening | BLOCKED (M3) | needs extension approval; optional |
| C15 | Hosted-page/browser evidence | BLOCKED (M2) | `tradeready-legal` unavailable |
| C16 | Old-RN post-adoption rotation without update | BLOCKED (L1) | indistinguishable payload; inert-safe + prompt |
| C17 | Proof-less legacy resolve verification | BLOCKED (L2) | accepted compat gap, qualified in 8.14 |

## 12. Handoff for independent native work (8.01/8.02/8.03, 8.07 mocks)

- 8.01/8.03 proceed on frozen oracle behavior (§13 fixtures; S1/S2/R1
  acceptance unchanged by anything above). No backend decision gates them.
- 8.02 implements D-B3-1…D-B3-4 exactly; L3 documented in-code.
- 8.07 builds transports against §1.1/§1.2 + §6 shapes now; acceptance
  against live behavior waits for 8.04–8.06 (mocks must assert the frozen
  shapes, including `operationId` echo, `stale_revision`, `tokenValid`,
  `schedule_changed`, unknown-outcome handling — never auto-retry
  destructive non-idempotent operations).
- TypeScript handoff types: `BookingAdminRequest`/`BookingAdminResponse`
  (§1), portal status `{ok, enabled, tokenValid, adopted}` (§6), resolve
  proof `{jobId, updatedAt, date, start}` (§7). Swift mirrors use identical
  field names and error strings; bearer/refresh follows the
  `NativeChangeOrderApprovalLink.swift` pattern (current bearer, bounded
  refresh, typed errors, no tokens in diagnostics).
- Next-ready: 8.01, 8.02, 8.03 (parallel, pure/service lane) and 8.04
  (backend lane, needs a PG harness decision for M1 first).

## 13. Fixture index + characterization tests (G1–G4)

All new tests record CURRENT behavior; none change implementation. Mock-level
409s are labeled as such inside each test.

| ID | What is pinned (current behavior) | File |
|---|---|---|
| G1-01 | Different-start overlaps both succeed at core level (no interlock; only identical-`slot_start_utc` index serializes) | `__tests__/phase8BookingIntegrityCharacterization.test.js` |
| G1-02 | Buffer-only concurrent claims both succeed with a stale snapshot | same |
| G1-03 | Identical-start 409 maps to `slot_taken` with no request row (mock-level only — NOT race evidence) | same |
| G1-04 | Cross-owner same instant both succeed (owner-scoped index) | same |
| G1-05 | Request-insert failure compensates; compensation-delete failure orphans the hold (residual) | same |
| G2-06 | Double transition on a stale read: both 200, forked (not chained) history — no version check | same |
| G2-07 | Respond retry lost-update: second patch drops the first's history entry | same |
| G2-08 | `resolve_reschedule` requires no schedule proof today (L2 basis) | same |
| G2-09 | Cancel frees the reservation BEFORE patching the request (order pinned) | same |
| G3-01 | No `/api/booking/admin` route registered (contract unimplemented) | `__tests__/phase8BookingAdminContract.test.js` |
| G3-02 | Blob token lookup: enabled resolves, disabled≡unknown (no oracle) | same |
| G3-03 | Stale-settings resurrection: re-enabling the blob re-authorizes (no revision) | same |
| G3-04 | Proposed admin shape examples satisfy the frozen rules (executable handoff) | same |
| G4-01 | Simultaneous mints both succeed at core level (no serialization) | `__tests__/phase8PortalConcurrencyCharacterization.test.js` |
| G4-02 | Mint-after-disable creates a second non-revoked row (invariant gap → §4 fix) | same |
| G4-03 | `set_enabled` targets all non-revoked rows (filter pinned) | same |
| G4-04 | Rotate insert failure after revoke strands the customer (recovery gap → replay table) | same |
| G4-05 | Unknown stale blob token authenticates after adoption (fail-closed fix → §4) | same |
| G4-06 | Unknown token + blob miss → null (preserved) | same |
| G4-07 | Manage view returns the stored slot verbatim (immutability basis) | same |
| G4-08 | `archivedAt`-only job still served by portal ICS (archive gap → §9 fix) | same |
| B3-01…04 | `confirmed`/`reschedule_requested` skipped pre-conversion; deterministic `jbk_` IDs; time-based customer IDs (L3 basis); `portal_change_requested` inert | existing `bookingConversion`/`bookingAttention` oracles (referenced, not duplicated) |
| S/R | Schedule/availability/calendar/route oracle behavior | existing `scheduleConfig`, `availability(+Parity)`, `calendar`, `scheduleSmarts`, `RouteScreen` behavior (referenced; 8.01/8.03 own parity) |

Evidence: focused jest runs recorded in the task return (commands + actual
results); aggregate `run-all-domain-tests.sh` / Release build untouched
(8.15 owns closeout). Unresolved blockers: M1, M2, M3, L1, L2 (§11).
