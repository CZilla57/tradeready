# Portal Completion Phase C (portal-request write path) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The portal's first write path — customers can request follow-up work, or a reschedule/cancel of an owner-scheduled appointment — as idempotent, server-timestamped `bookingRequests` inserts, with the `portal_access_log` table providing security logging and a durable per-token daily cap.

**Architecture:** One new action `POST /api/estimate/portal-request` (Workers-only). Follow-up requests reuse the entire shipped booking pipeline (insert → owner push → device lead conversion), now id-linked to the existing customer via `sourceCustomerId`. Appointment-change requests get a NEW status value `portal_change_requested` — per the models.ts additive-union contract, OTA-old clients skip statuses they don't match, so these rows are inert on old clients (no bogus lead conversion, no OTA-ordering hazard) and surface on new clients via `selectBookingAttention`. `portalStore.js` keeps its READ-ONLY contract — all writes live in a new `portalRequestStore.js`.

## Global Constraints

- Spec §5 + §8, decisions D3/D4 (approved). Phase A/B constraints carry over. Baseline 2599 tests / 193 suites.
- Idempotency: row id = `bkpr_` + sha256(`${token}|${requestKey}`).slice(0, 20); insert with `Prefer: resolution=ignore-duplicates` (NOT merge-duplicates — a retry must not clobber `createdAt`, `handledAt`, or conversion stamps).
- Server-timestamped: `createdAt` = server clock; nothing time-shaped trusted from the page.
- Abuse posture: honeypot `website` field (silent fake success), 10/min/IP in-memory limit, durable cap 5 requests/day/token via `portal_access_log`, note capped 300 (booking-manage precedent). Cap-check DB errors fail OPEN (in-memory limit still guards; a broken log table must not take the feature down) — logged.
- No raw token in any log row or console line — `token_prefix` = first 8 chars only.
- Phase C logs `request` + `denied` events only; `view`/`ics`/`photo` logging lands with the Phase D token-table rework (one lookup-path change instead of two).
- Migration applied out-of-band via Supabase SQL editor (owner op at deploy, like every sibling); until applied, the endpoint works with the cap failing open.

---

### Task 1: migration + model additions

**Files:** Create `supabase/migrations/20260807_portal_access_log.sql`; modify `types/models.ts`.

```sql
-- Phase 12C (2026-08-07 portal-completion spec §8): security log for the
-- customer portal + durable per-token daily cap for the portal-request write
-- path. Sibling of 20260806_auto_invoice_email_log.sql. Applied out-of-band
-- via the Supabase SQL editor. Service-role writes (bypass RLS); owner may
-- read their own rows (reserved for a future "portal was viewed" surface).
-- NEVER stores a raw portal token — token_prefix is the first 8 chars only.
create table if not exists public.portal_access_log (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  token_prefix text not null,
  event        text not null, -- 'request' | 'denied' (view/ics/photo reserved for Phase D)
  ip           text,
  created_at   timestamptz not null default now()
);

create index if not exists portal_access_log_cap_idx
  on public.portal_access_log (user_id, token_prefix, event, created_at);

alter table public.portal_access_log enable row level security;

create policy "read own portal access log"
  on public.portal_access_log for select
  using (auth.uid() = user_id);
```

models.ts (all additive; D3): `BookingRequestStatus` gains `"portal_change_requested"` (docblock updated — SERVER-written by portal-request; old clients skip it by the explicit-match rule); `BookingRequest` gains:

```ts
  /** "portal" when the row was created by the customer-portal request path (Phase 12C). */
  source?: "portal";
  /** The portal customer's record id — conversion links THIS customer instead of name-matching. */
  sourceCustomerId?: string;
  /** portal_change_requested only: the appointment's job id the change refers to. */
  jobRef?: string;
  /** portal_change_requested only: what the customer asked for. */
  portalKind?: "reschedule" | "cancel";
  /** Device-written when the owner dismisses a portal change request on Today. */
  handledAt?: string;
```

Commit: `feat(portal): portal_access_log migration + portal-request model fields`

### Task 2: `portalRequestStore.js` (the write-side store)

**Files:** Create `backend-workers/lib/estimate/portalRequestStore.js`; test `__tests__/portalRequestWorkers.test.js` (store half).

Functions (service role, same `headers`/fetch conventions as portalStore):
- `insertPortalRequest(env, userId, request)` — POST bookingRequests with `Prefer: resolution=ignore-duplicates`; row shape `{id, user_id, data, updated_at, deleted:false}` (sync-compatible, booking-store convention).
- `logPortalEvent(env, { userId, tokenPrefix, event, ip })` — POST portal_access_log, best-effort: **never throws** (markLog convention).
- `countTodayRequests(env, { userId, tokenPrefix })` — GET `portal_access_log?user_id=eq.&token_prefix=eq.&event=eq.request&created_at=gte.<UTC midnight ISO>&select=id&limit=6`, returns row count; caller compares to the cap.
- `fetchSettingsData(env, userId)` — settings row `data` blob (notifyOwner needs the push token inside it).

Tests: URL/Prefer-header pinning for all four; logPortalEvent swallows a rejected fetch.

Commit: `feat(portal): portal-request write store with ignore-duplicates + access log`

### Task 3+4: `portalRequest` core + route + registration

**Files:** Create `backend-workers/lib/estimate/portalRequest.js`, `backend-workers/src/routes/estimate/portalRequest.js`; modify `backend-workers/src/index.js`; test = second half of `__tests__/portalRequestWorkers.test.js`.

Core `portalRequestCore(env, { body, ip, nowMs })` returning `{ status, json }`:

1. Honeypot: `body.website` non-blank → `{200, {ok:true}}` (silent drop, console.warn without token).
2. Validate: `kind` ∈ followup|reschedule|cancel; `requestKey` matches `/^[A-Za-z0-9_-]{8,64}$/`; `note` = String slice 300 (required non-blank for followup); missing `p` → 400.
3. Token lookup via portalStore (read) → oracle-free 404.
4. Durable cap: `countTodayRequests >= 5` → log `denied`, return 429 `{ error: 'Too many requests today.' }`. Cap-check throw → fail open.
5. reschedule/cancel: `jobRef` must resolve via `fetchCustomerJobs` to a job with a valid `scheduledDate` → else 404 (same message).
6. Build row (name/phone/email/address copied from the CUSTOMER RECORD, capped 120/40/254/200 — attacker-independent):
   - followup → `{ id, status:'new', …contact, details: note, preferredTiming:'', createdAt: ISO(nowMs), source:'portal', sourceCustomerId: customer.id }`
   - reschedule/cancel → same but `status:'portal_change_requested'`, `details` = `` `${kind === 'reschedule' ? 'Reschedule' : 'Cancellation'} requested for "<job title>" (<scheduledDate>)` + (note ? ` — ${note}` : '') ``, plus `jobRef`, `portalKind: kind`.
7. `insertPortalRequest` (idempotent — duplicate id is a silent no-op → still `{ok:true}`).
8. `logPortalEvent('request')` best-effort; `notifyOwner(env, {userId, settingsData, request})` fire-and-forget (shipped push/email builder — copy reads fine for both kinds since name/details are populated).
9. `{200, {ok:true}}`.

Route: estimate-family CORS (`applyCors` POST/OPTIONS), 405, 10/min/IP limit, jsonBody, delegate to core, 500 on throw. Register `app.all('/api/estimate/portal-request', …)` before the `:action` catch-all.

Tests (fetch-mocked, bookingManage harness style): honeypot; bad kind/requestKey/missing note; unknown token 404; cap 429 + denied log row; cap-error fail-open; followup row shape exact (including source/sourceCustomerId, server createdAt); reschedule row shape exact (status portal_change_requested, jobRef, templated details); jobRef not this customer's / unscheduled → 404; deterministic id (same token+requestKey twice → same id both calls); no raw token in any log/console write.

Commit: `feat(portal): portal-request endpoint - followup and appointment-change writes`

### Task 5: conversion — id-linking + portal notes

**Files:** Modify `utils/storage/bookingConversion.ts`; extend `__tests__/bookingConversion.test.ts` (or the existing conversion suite's actual filename).

- Before the name-keyed upsert: if `r.sourceCustomerId` matches an existing customer record, use that customer directly (no upsert, no contact backfill — the portal copied FROM that record moments ago). Fall back to the upsert when absent/dangling.
- Notes provenance line becomes portal-aware: `source === 'portal'` → `Came in via customer portal <date>`.
- `portal_change_requested` needs NO changes here — the explicit status match already skips it (add the pinning test).

Tests: sourceCustomerId hit links without creating/altering customers; dangling sourceCustomerId falls back to upsert; portal_change_requested rows are untouched by conversion; portal note line.

Commit: `feat(portal): conversion links portal requests to the existing customer by id`

### Task 6: Today surfacing — attention row + dismiss

**Files:** Modify `utils/bookingAttention.ts`, `utils/storage/bookingRequests.ts` (add `markBookingRequestHandled`), `screens/TodayScreen.tsx`; extend `__tests__/bookingAttention.test.ts`.

- `BookingAttention` union gains `{ kind: "portal_change"; request; jobId?: string; note?: string }` — emitted for `status === "portal_change_requested" && !handledAt` (jobId = `jobRef`, note = `details`); sorted after reschedule_requested, before cancelled.
- `markBookingRequestHandled(requestId, nowIso)` — load → stamp `handledAt` → save (normal synced path).
- TodayScreen: label branch (`"<name> asked to reschedule/cancel — <job title>"` via the jobs lookup, falls back to details) + Alert actions "View job" (existing cross-tab navigate — `initial: false` invariant) / "Done" (stamps handledAt, drops the row in-memory).

Tests (selector level, the Phase 11 convention): surfaced when unhandled; hidden once handledAt set; sort position; note passthrough.

Commit: `feat(portal): surface portal change requests on Today with dismiss`

## Self-review notes

- Spec §5 fully covered; §8 partially by design (request/denied events now, read-event logging deferred to Phase D — stated in Global Constraints and the phase report).
- The status-value mechanism supersedes the spec's "conversion skips kind marker" sketch — strictly safer for OTA-old clients (they skip unknown statuses entirely); spec updated by this plan, flagged in the report.
- Insert must be ignore-duplicates; merge-duplicates would let a retry clobber handledAt/conversion stamps (stated in Task 2 and pinned by test).
