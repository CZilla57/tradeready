# Phase 11 — Calendar, availability & real online booking (design)

**Date:** 2026-08-07 · **Status:** DESIGN — awaiting owner approval. No schema,
backend, or client code changes have been made. Per the kickoff prompt this doc
delivers: domain model, concurrency design, timezone rules, UI flow, API/RLS
plan, migration compatibility, and the phased test plan — then stops.

---

## 1. Verified preconditions (re-checked 2026-08-07 against master `3bc0542`)

| Precondition | Verdict |
|---|---|
| Booking link (Phase 9, `cec034f`) provides request model, hosted page, conversion flow | ✅ `BookingRequest` (types/models.ts:527–545), `bookingRequests` synced collection, `book.html` (tradeready-legal), `utils/storage/bookingConversion.ts`, Workers routes `mint/config/submit` |
| Overlap detection + smart pickers shipped | ✅ `utils/scheduleSmarts.ts` — `findScheduleConflicts` (:94), `largestFreeGap` (:116), `addLaborToStart`/`defaultStartTime`/`defaultEndTime`; tests `__tests__/scheduleSmarts.test.ts` |
| RouteScreen is a Maps deep-link stub | ✅ confirmed; no routing/optimization to build on — kickoff exclusion stands |
| Slot math is FA-039 territory | ✅ all existing schedule math is local-frame, minutes-since-midnight, no `Date` parse of date strings — this design keeps that discipline |
| No working-hours/availability/blackout config exists | ✅ repo-wide grep: only hardcoded `WORK_DAY_START/END = "08:00"/"17:00"` (utils/todayInsights.ts:46–48) and `largestFreeGap` defaults |
| Workers backend has NO durable coordination primitive | ✅ wrangler.toml bindings = two R2 buckets only; rate limiter is in-memory per-isolate (backend-workers/lib/guards.js) — atomicity must come from Postgres |

## 2. Scope recap

- **Phase A** — owner calendar: day + week views, unscheduled approved-work
  queue, conflict warnings, working hours, appointment duration, buffer time,
  fast reschedule. Today stays the daily action surface.
- **Phase B** — deterministic availability engine (pure, unit-tested, no UI).
- **Phase C** — public slot booking: server-authoritative atomic reservation,
  double-book prevention, request-only mode preserved, owner + customer
  notifications.
- **Phase D** — customer self-service: confirm, add-to-calendar, reschedule/
  cancel requests, auditable history, strict token isolation.
- **Excluded** (per kickoff): Google Calendar APIs, route optimization,
  external calendar sync (later opt-in phase), travel-time inference.

## 3. Domain model

### 3a. `Settings.schedule` — NEW additive-optional object (the only Settings change)

```ts
/** Owner scheduling config (Phase 11). OPTIONAL and additive — absent
 *  reproduces today's behavior exactly (08:00–17:00 window, no buffers,
 *  no blackouts, no public slots). */
schedule?: {
  /** IANA zone, e.g. "America/Chicago". Stamped from
   *  Intl.DateTimeFormat().resolvedOptions().timeZone when the owner enables
   *  slot booking; shown + editable in Settings. Required for Phase C only. */
  timeZone?: string;
  /** ISO weekdays 1–7 (Mon=1). Absent → engine default (owner decision D5). */
  workDays?: number[];
  workDayStart?: TimeString;          // absent → "08:00"
  workDayEnd?: TimeString;            // absent → "17:00"
  defaultDurationMinutes?: number;    // absent → 60
  bufferMinutes?: number;             // absent → 0 (explicit config, never inferred)
  slotLeadHours?: number;             // min notice for earliest slot; absent → 24
  slotWindowDays?: number;            // bookable horizon; absent → 14
  /** Whole-day time off. Kept inside settings (no new collection) — whole-blob
   *  LWW on settings is the existing accepted model; solo operator. */
  blackouts?: { id: string; start: DateString; end: DateString; reason?: string }[];
  /** Phase C master switch AND the kickoff-mandated feature flag. Absent → off. */
  bookableSlotsEnabled?: boolean;
}
```

Defaults resolve in one place: `resolveSchedule(settings): ResolvedSchedule`
(new pure util) — every consumer (calendar UI, conflict math, insights, engine)
reads through it. `WORK_DAY_START/END` in todayInsights.ts and
`largestFreeGap`'s defaults get wired to it (supersedes the "no setting in v1"
note in the 2026-08-04 today-insights spec — flagged, not silent drift).

### 3b. `Job` — NO changes

Appointment duration = `scheduledEndTime − scheduledStartTime` when both
present, else `max(laborHours, 1h)` — exactly `scheduleSmarts.window()`'s
existing semantics. Buffer is global config applied in the math, not a per-job
field. Engine and UI must tolerate both `null` and `""` schedule fields
(AddJobScreen writes `""` — screens/AddJobScreen.tsx:285–287).

### 3c. `BookingRequest` — additive extensions (Phase C/D)

```ts
/** Absent = legacy free-text request. */
kind?: "request" | "booked";
/** Owner-local naive slot (authoritative for what lands on the Job) plus the
 *  UTC instants derived server-side via schedule.timeZone. */
slot?: { date: DateString; start: TimeString; end: TimeString;
         timeZone: string; startUtc: string; endUtc: string };
/** Server-minted management token for the Phase D customer page.
 *  Public-by-design (in the emailed link), like portal/approval tokens. */
manageToken?: string;
/** Append-only audit trail, SERVER-written (mirrors EstimateApproval's
 *  server-side-write discipline). */
history?: { at: string; actor: "customer" | "owner" | "system";
            event: string; note?: string }[];
```

`status` union extends additively:
`"new" | "converted" | "booked" | "confirmed" | "reschedule_requested" | "cancelled" | "declined"`.
Safe because `convertBookingRequests` touches ONLY `status === "new"` rows
(bookingConversion.ts:38) — an OTA-old client ignores every new status; no
corruption, just no conversion until the client updates.

**Two-writer note:** device writes conversion stamps; server writes
customer-action history. Whole-blob LWW means a device push can drop a
concurrent server-appended history entry. Recommended: union-merge `history`
by `(at, event)` on pull, mirroring the `mergePaymentLedgers` precedent
(utils/syncMerge.ts) — owner decision D7; fallback is documented accepted-risk.

### 3d. `booking_reservations` — NEW Supabase table (Phase C; the atomicity anchor)

Real columns, NOT the blob shape, because a **partial unique index is the
double-book prevention mechanism** and indexes need real columns:

```sql
create table public.booking_reservations (
  id             text primary key,                -- rv<epoch-ms>_<6 hex>, server-minted
  user_id        uuid not null references auth.users (id) on delete cascade,
  request_id     text not null,                   -- pairs with bookingRequests.id
  slot_date      text not null,                   -- owner-local "YYYY-MM-DD"
  slot_start     text not null,                   -- owner-local "HH:MM"
  slot_start_utc timestamptz not null,
  slot_end_utc   timestamptz not null,
  status         text not null default 'booked',  -- booked | cancelled | declined | completed
  created_at     timestamptz not null default now()
);
create unique index booking_reservations_active_slot
  on public.booking_reservations (user_id, slot_start_utc)
  where status = 'booked';
alter table public.booking_reservations enable row level security;
create policy booking_reservations_owner on public.booking_reservations
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
```

Server-only coordination surface (service role bypasses RLS); the device never
reads it — the `bookingRequests` blob carries everything the app needs. The
owner-scoped policy ships anyway per the multi-tenant security floor (any new
table MUST carry it). Cancelling/declining flips `status`, which drops the row
out of the partial index and frees the slot atomically.

## 4. Timezone rules (explicit, per kickoff + FA-039)

1. **Owner-frame data stays naive.** `scheduledDate`/`scheduledStartTime`
   remain local "YYYY-MM-DD"/"HH:MM" strings. Date equality is string
   comparison; time math is minutes-since-midnight. No `Date` parsing of
   date-only strings anywhere in new code (FA-039 discipline; `parseLocalDate`
   / `formatLocalDate` where a `Date` is genuinely needed).
2. **The client availability engine is timezone-free.** It computes in the
   owner's naive frame. DST cannot occur in naive minute arithmetic.
3. **UTC exists only at the public boundary.** The server resolves each
   offered naive slot to a UTC instant using `schedule.timeZone` (IANA) at
   offer time and at reservation time. `slot_start_utc` drives uniqueness;
   the naive fields drive what lands on the Job.
4. **DST edges:** a naive slot that does not exist locally (spring-forward
   gap) is dropped from offers; an ambiguous slot (fall-back repeat) resolves
   to the FIRST occurrence. Both cases unit-tested on real transition dates.
5. **Customers see owner-local times, labeled with the zone** ("9:00 AM
   Central"). Trade work is physically at the job site — offering the
   viewer's zone would be wrong, not helpful.
6. **Zone changes:** `timeZone` is stamped at enable-time and edited only
   deliberately in Settings. Existing reservations keep their stored UTC
   instants (history is not rewritten).
7. The naive↔UTC converter is implemented with the standard `Intl.DateTimeFormat`
   offset-probe technique — **no new dependency** (Rule 3). Workers'
   `nodejs_compat` runtime has full ICU; verified in Phase C task 1 before
   anything builds on it.

## 5. Availability engine (Phase B)

New pure module `utils/availability.ts`:

```ts
computeCandidateSlots(input: {
  schedule: ResolvedSchedule;      // from resolveSchedule(settings)
  jobs: Job[];                     // busy = non-terminal, has scheduledDate+start
  extraBusy?: BusyWindow[];        // server passes active reservations here
  fromDate: DateString;            // first candidate day
  days: number;                    // horizon (slotWindowDays)
  now: { date: DateString; minutes: number };  // injected — determinism
}): CandidateSlot[]                // { date, start, end } owner-naive
```

Algorithm per day: skip non-workdays and blackout days → collect busy windows
(`window()` semantics: explicit end, else `max(laborHours,1)*60`; skip
`TERMINAL_STATUSES`; pad each side by `bufferMinutes`) → merge windows → free
gaps clipped to `[workDayStart, workDayEnd]` → slice gaps into
`defaultDurationMinutes` slots aligned to a fixed 30-minute grid → drop slots
earlier than `now + slotLeadHours`. Pure, deterministic, no I/O, no `Date`
construction from strings.

**Server twin:** `backend-workers/lib/booking/availability.js` (CommonJS),
same algorithm, plus the naive→UTC resolver. Kept in parity by a **shared
fixture suite** — the established pattern from the `selectInvoicesToRemind` /
`isPlausibleEmail` parity suites: one fixtures file, two runners, outputs
must be deep-equal.

## 6. Concurrency design (Phase C)

**Reservation is server-authoritative and atomic via Postgres, not via any
Worker-local state** (there is none — guards.js is per-isolate best-effort).

`POST /api/booking/reserve` handler sequence:

1. Validate payload (extend `lib/booking/validate.js` caps; same non-string
   rejection discipline).
2. Token → user via the existing settings JSON-path lookup (store.js:27–35);
   additionally require `schedule.bookableSlotsEnabled === true` — else 404,
   same no-oracle wording as config.
3. **Recompute availability server-side** from the user's settings blob +
   jobs blobs + active reservations (service-role reads). Requested slot must
   be a member. This makes the server authoritative even if the page's slot
   list is stale.
4. **Atomic claim:** INSERT into `booking_reservations`. Two customers racing
   for one slot both pass step 3; Postgres's partial unique index serializes
   them — the loser's insert fails with `23505`, mapped to
   `409 { error: "slot_taken" }`; the page refreshes the slot list. This is
   the entire double-book story: one constraint, no locks, no queues.
5. Insert the `bookingRequests` blob row (kind `"booked"`, slot, manageToken,
   history seed) — the shape `pullRemote` already absorbs. If THIS insert
   fails, compensate by deleting the just-created reservation (best-effort)
   and return 500 — a slot is never left held without a visible request.
6. `notifyOwner` fire-and-forget (existing pipeline), with accurate wording:
   "New booked appointment" vs "New quote request". Customer gets a
   confirmation response (+ email via Resend when an email was provided).

**Accepted limitations (stated, not hidden):**
- *Offline-owner race:* a job scheduled on-device but not yet synced is
  invisible to step 3 — a customer can book over it. Same eventual-consistency
  class as the Stripe-webhook latency the architecture already accepts. The
  conflict surfaces on next sync via the existing `findScheduleConflicts`
  warning; Phase D reschedule is the remedy. Mitigation is NOT attempted
  (would require making device saves network-blocking — violates the
  local-first invariant).
- *No cross-request idempotency* on reserve: a retried POST can create a
  second request row for an adjacent slot. Matches the existing submit
  endpoint's posture; the unique index still prevents same-slot doubles.

**Owner-side slot lifecycle:** owner decline/cancel (Phase D approval UI, or
deleting the job) flips the reservation `status` server-side via a new
JWT-authed endpoint — freeing the slot is a single UPDATE; atomic by the same
index.

## 7. UI flow

### Phase A — owner calendar (client-only, OTA-eligible, no server work)

- **New `CalendarScreen`** registered in TodayStack (route `Calendar`),
  entered from a calendar button in Today's week-strip header. Today itself
  is untouched as the action surface — the calendar is the planning surface.
- **Day view:** vertical time axis clipped to working hours (±overflow for
  out-of-hours jobs), jobs as blocks (start → end, else laborHours-derived),
  buffers rendered as soft padding, blackouts/non-work time shaded. Tap block
  → JobDetail.
- **Week view:** 7-column grid (Mon-first, matching `getWeekDates`), same
  block rendering, ‹/› week paging via `shiftDate(d, ±7)`. Day/week toggle in
  the header. (Month view deliberately NOT in Phase A — kickoff names day and
  week; month is a possible follow-up.)
- **Unscheduled queue:** a collapsible section listing approved-but-
  unscheduled jobs (the existing `unscheduled_approved` insight predicate,
  promoted to a shared selector). Tap → schedule sheet.
- **Fast reschedule = tap, not drag:** tapping a block (or queue row) opens a
  reschedule sheet reusing `DateTimePickerSheet` + `defaultStartTime`/
  `defaultEndTime`/`addLaborToStart`, live `findScheduleConflicts` warning
  (extended with `bufferMinutes`), and a "Suggested: <largest free gap>" chip.
  Drag-and-drop on a time grid would need a gesture dependency — rejected
  under Rule 3; tap-to-reschedule is two taps and testable.
- **Conflict warnings stay warning-only** (never block saving) — the
  documented `findScheduleConflicts` contract.
- **New Settings subpage "Schedule"** (12th hub row): working hours, work
  days, duration, buffer, blackouts list. Form page → uses `useSettingsDraft`
  per the contract. The Phase C toggle (slot booking + timezone display)
  lives on SettingsBookingScreen, which stays immediate-action/draft-free.
- All new UI: `createStyles(colors, shadow)` factory, Blueprint tokens,
  shared primitives (Field, Card, SectionHeader, EmptyState).

### Phase C/D — owner-side surfaces

- Booking-request rows (existing JobList landing) distinguish "booked
  appointment" (slot shown, already on calendar) from "quote request".
  Conversion of `kind:"booked"` rows creates the Job **with the slot's
  schedule fields populated** — initial status per owner decision D6.
- Reschedule/cancel requests from customers surface as a Today row + push
  (new notification `data.type` values routed in the App.tsx tap listener —
  precise routes, replacing today's coarse JobList landing for these).

### Phase C/D — public pages (tradeready-legal repo)

- `book.html` gains a slot picker: fetches `GET /api/booking/slots?b=…`;
  renders date strips + slot chips in owner-local time with zone label; falls
  back to today's free-text `preferredTiming` form when slots are disabled or
  the fetch fails (the current experience is the permanent request-only
  path — "request-only services" = leaving slot booking off, v1).
- New `booking.html` (manage page, `?m=<manageToken>`): status, slot,
  business name ONLY (config.js minimal-leak discipline); actions = confirm,
  add-to-calendar (client-generated `.ics` from slot data — no dependency),
  request reschedule, cancel. Same `esc()`/honeypot/rate-limit posture as
  book.html.

## 8. API & RLS plan

New Workers routes (`app.all` registration, in-handler method checks, public
CORS via `lib/estimate/cors.js`, rate limits via `lib/guards.js`, service-role
via raw PostgREST fetch — all existing patterns):

| Route | Auth | Purpose |
|---|---|---|
| `GET /api/booking/slots?b=<token>` | public, token-gated, IP-limited 30/min | timeZone + candidate slots (server-computed, reservations subtracted). Leaks nothing beyond businessName + slots. `bookableSlotsEnabled` false → 404, no oracle. |
| `POST /api/booking/reserve` | public, token-gated, IP-limited 10/min, honeypot | §6 sequence; 409 on `slot_taken` |
| `GET /api/booking/manage?m=<manageToken>` | public, manageToken-gated, IP-limited | THIS booking's status/slot/businessName only — token can never reach other customers or job notes |
| `POST /api/booking/manage` | public, manageToken-gated, IP-limited | confirm / request_reschedule / cancel → status + history append + owner notify |
| `POST /api/booking/respond` | JWT (owner) | approve/decline reschedule, cancel booking → reservation status flip + history + customer email |

- `/api/booking/config`, `mint`, `submit` are untouched (config's
  businessName-only leak posture preserved).
- **Workers-only.** No Vercel mirror — the Vercel backend is in decommission
  (CF migration Phase 6 pending); new booking tests target
  `backend-workers/lib` like the photo/PDF suites do. (Owner decision D4.)
- RLS: `bookingRequests` policy unchanged; `booking_reservations` ships with
  the standard owner-scoped ALL policy (§3d). No client-side Supabase access
  changes at all.
- Known perf note carried forward: token lookup is an unindexed JSON-path
  scan of `settings` (documented "tiny table" decision in the Phase 9 spec);
  slots adds one more read of it per page load. Unchanged posture; revisit
  only if scale demands.

## 9. Migration compatibility & rollout

| Change | Compatibility story |
|---|---|
| `Settings.schedule` | Additive-optional; absent → today's exact behavior via `resolveSchedule` defaults. No migration, no backfill. Whole-blob settings LWW unchanged. |
| `BookingRequest` extensions | Additive-optional; old rows = `kind` absent = request. Old CLIENTS skip non-`"new"` statuses entirely (verified bookingConversion.ts:38) — forward-safe. |
| `booking_reservations` | New server-only table; device schema untouched; standard migration file `supabase/migrations/20260807_booking_reservations.sql`, owner-applied. |
| Job shape | Untouched. |
| `book.html` | Progressive: slot UI renders only when the slots fetch succeeds AND returns slots; otherwise identical to today. Old links keep working. |
| OTA | All client work is JS-only → OTA-eligible; zero new dependencies anywhere (Rule 3 clean). |
| Feature flag | `schedule.bookableSlotsEnabled` (absent = off) is the kickoff-mandated flag: Phases A/B ship inert (calendar + engine touch nothing public); C/D stay dark until the owner flips the toggle AFTER migration applied + Workers deployed + pages live + device smoke passed. |

Rollback: toggle off → slots endpoint 404s, book.html falls back to request-
only, reservations table sits idle. No data to unwind.

## 10. Phased build & test plan (each phase: TDD, gate green, report, STOP)

**Phase A — owner calendar (client only)**
1. `resolveSchedule` + defaults (unit).
2. Buffer-aware conflict math: extend `ConflictQuery` with `bufferMinutes`
   (default 0 → existing tests unchanged; new cases: buffer-created overlap,
   touching windows with/without buffer).
3. Calendar selectors (pure): day-block layout (null vs `""` fields, missing
   end → laborHours, out-of-hours clipping), week composition, unscheduled-
   approved queue.
4. CalendarScreen day/week (RNTL screen suite, per bookingLinkSettings
   precedent) + reschedule sheet (conflict warning, gap suggestion,
   `advanceStatusForSchedule` on the edit path).
5. Settings "Schedule" subpage (draft contract, blackout CRUD) + rewire
   todayInsights/largestFreeGap constants through `resolveSchedule`
   (existing suites pin behavior with schedule absent).

**Phase B — availability engine (pure)**
1. `utils/availability.ts` + exhaustive units: empty day, packed day,
   buffers, blackouts, workdays, lead time, horizon, 30-min alignment,
   duration slicing, `""`/null fields, terminal statuses excluded.
2. Server twin + naive↔UTC resolver: DST spring-forward (slot dropped),
   fall-back (first occurrence), far-east/far-west zones; ICU presence check.
3. Client↔server parity fixture suite (shared fixtures, deep-equal outputs).

**Phase C — public booking (⛔ starts only after owner applies the migration)**
1. Migration file + `slots` endpoint tests (token gate, disabled→404,
   no-leak payload, rate limit, reservations subtracted).
2. `reserve` tests: happy path (reservation + request rows), membership
   rejection (stale slot), **409 on 23505**, compensation on second-write
   failure, honeypot, validation caps, notify wording.
3. Device: `kind:"booked"` conversion (schedule fields land, status per D6,
   idempotent, crash-rerun safe), calendar/Today render, precise
   notification-tap routing.
4. `book.html` slot picker + fallback. Owner smoke: real booking E2E on
   device (web preview can't verify — owner-run, per the standing trap).

**Phase D — customer changes**
1. `manage` GET/POST tests: token isolation (cannot see other bookings/jobs),
   minimal payload, history append, state machine (confirm/reschedule/cancel
   legal transitions only).
2. Owner `respond` endpoint + in-app approval UI; reservation freeing
   (slot immediately re-offerable — pinned by test).
3. `booking.html` + `.ics` generation (pure builder, unit-tested).
4. History LWW handling per D7. Full-gate + owner smoke + docs sweep
   (README, ARCHITECTURE.md, skills: storage-and-sync §COLLECTION notes,
   config-and-flags for `schedule`, payments untouched).

## 11. Owner decisions required before build starts

| # | Decision | Recommendation |
|---|---|---|
| D1 | New Supabase table `booking_reservations` (schema change) | Approve — it is the only honest atomicity mechanism available (no DO/KV/D1) |
| D2 | `Settings.schedule` shape (persisted-shape change) | Approve as §3a |
| D3 | `BookingRequest` extensions + status union growth | Approve as §3c |
| D4 | New endpoints Workers-only (no Vercel mirror) | Yes — Vercel is being decommissioned |
| D5 | Default `workDays` when unset | Mon–Sat (trades work Saturdays); Settings page makes it explicit |
| D6 | Initial Job status for a slot-booked conversion | `lead` WITH schedule fields set — shows on calendar, counts as busy in conflict math, zero pipeline disruption; "booked online" shown via the request link. Alternative (`scheduled`) skips estimate stages — flag if preferred |
| D7 | Customer-action `history` vs whole-blob LWW | Union-merge on pull (mergePaymentLedgers precedent); fallback = documented accepted-risk |
| D8 | Slot granularity fixed at 30 min for v1 | Yes — configurable later if asked |

## 12. Phase report (Rule 1)

**Confidence:** HIGH on the domain model, timezone rules, and concurrency
design — every claim above is grounded in file:line reads of the current
master, and the atomic-reservation pattern uses only primitives that already
exist in the stack (Postgres unique index + service-role PostgREST). MEDIUM
on Phase A effort: the week-grid rendering is the largest pure-UI lift in the
plan and has no in-repo precedent to copy.

**Missing context:** (1) whether Workers' ICU handles every IANA zone the
resolver needs — verified as Phase C task 1 before anything depends on it;
(2) Resend template wording for customer confirmations — owner voice;
(3) whether the owner wants the calendar reachable from the Jobs tab too
(multi-stack registration is cheap but is a nav decision).

**Recommended next step:** owner reviews §11 (D1–D8). On approval, begin
Phase A task 1 on a feature branch (`feat/calendar-availability`), phase-gated
as always. No code, schema, or backend changes until then.
