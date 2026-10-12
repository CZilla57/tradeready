# Google/iCloud Calendar Sync (Roadmap Phase 26) — Design Spec

**Date:** 2026-10-03
**Status:** BUILT 2026-10-03 (Stages A and B); verified, reviewed and committed 2026-10-12 on local `feat/calendar-sync`, stacked on `feat/campaigns`. Gate green on its own branch tip against the master baseline (accessibility-audit and layout-metrics fail on master too); Worker `npm test`, doc reference check and the Release compile pass. Independent review: no P1; one P2 (mirror calendar adopted and deleted by title) and four P3s fixed on `fix/calendar-mirror` (`9d9fbba`). EventKit adapter paths are compile-only and need device evidence. Nothing pushed, deployed or applied. Build record: §11.
**Origin:** `docs/post-launch-feature-roadmap.md` Phase 26, build order #10 ("None on the on-device path; Google OAuth would be new")
**Builds on:** calendar/availability booking (`2026-08-07-calendar-availability-booking-design.md`), the Phase 8 booking lifecycle RPCs and server-authority tables, portal and booking ICS (Phase 11 D / 12A), the native calendar (Phase 8 task 8.01), native background refresh (`NativeBackgroundRefresh`)
**Build target:** the native SwiftUI app and the Worker. **No React Native changes. One migration file, which the owner applies. No deploys.** The only `tradeready-legal` change is the privacy-policy paragraph in §5, which needs owner approval.

## 0. Preconditions verified against the repo

`N/` means `native/TradeReadyNative/`.

**Availability engines and parity**
- The native engine (`N/Domain/NativeAvailability.swift`) already takes extra busy windows: `BusyWindow {date, start, end}` (:26-35), padded by the buffer and merged with jobs in `busyWindowsFor` (:82-114), sliced into slots by `computeCandidateSlots` (:116-159). The UTC boundary is `zonedTimeToUtc` (:202-221) and `nowInZone` (:250-258).
- No screen calls the engine. Its only in-app use is `isValidIANAZone` in `N/NativeScheduleSettingsView.swift:205,343,381`.
- The Worker twin is `backend-workers/lib/booking/availability.js`: `busyWindowsFor` (:162-189), `computeCandidateSlots` (:193-230), exports (:327-334). Reservations already ride `extraBusy` (`lib/booking/slots.js:54-58`, `lib/booking/reserve.js:91`). **So calendar busy times need no engine change; they become more `extraBusy` windows.**
- **Parity coverage is uneven.**
  - `__tests__/availabilityParity.test.ts` pins the RN client (`utils/availability.ts`) to the Worker (:9-14, :162-191).
  - Swift is pinned only through `native/ScheduleTests/Fixtures/scheduleVectors.json` (`defaults`, 7 `zoneVectors`, 2 `nowVectors`). Only Swift reads that file (`native/run-availability-tests.sh:16`, `native/AvailabilityTests/main.swift:217-247`). Jest copies the same values by hand (`__tests__/bookingAvailability.test.js:7,34-40`).
  - No shared vector pins Swift candidate slots to the Worker.
- **Latent `"24:00"` parity gap.**
  - Worker and RN `toMinutes` don't validate (`availability.js:116-119`, `utils/scheduleSmarts.ts:37-40`), so an `extraBusy` end of `"24:00"` counts as 1440.
  - Swift `NativeSchedule.toMinutes` rejects it (`N/Domain/NativeSchedule.swift:125-131`), and `busyWindowsFor` then silently drops the whole window (`NativeAvailability.swift:96-100`). Swift fails open; the others don't.
  - Swift `minutesToTime` clamps to 23:59 (`NativeSchedule.swift:133-136`); JS doesn't (`availability.js:121-125`).
  - Nothing produces `"24:00"` today, because slots end at or before `workDayEnd`, which is at most 23:59.

**Slots and reserve**
- `slotsCore` (`lib/booking/slots.js:23-76`):
  - Resolves the token to the settings row and answers 404 unless slots are on and a zone is set (:37-40).
  - Fetches jobs and reservations in parallel (:44-47).
  - Computes with `days: schedule.slotWindowDays` (:59-66).
  - Answers 200 `{businessName, timeZone, slots}` (:68-75).
- `reserveCore` re-checks membership server-side (`reserve.js:84-97`). It then calls the `claim_booking_slot` RPC (:143-166), or takes the legacy split path when the RPC isn't deployed (:167-198).
- **The claim RPC is a third busy check, in SQL.**
  - It re-checks jobs and reservations in-transaction under a per-owner advisory lock (`supabase/migrations/20260920_booking_lifecycle_rpcs.sql:163-381`; busy loops :317-361).
  - Write-fence triggers make every `jobs`/`settings` write take the same lock (:100-160).
  - The Phase 8 migrations are **not applied to the live project yet** (`docs/native-phase-12-cutover-charter.md`, decision rows 20-21 and defect P12-024). The live Worker therefore runs the legacy split path.
- `book.html` treats a failed slots fetch, or an empty slot list, as request-only mode (`tradeready-legal/book.html:94-99,101-115`). **Failing closed is graceful:** the customer gets the classic request form, not an error.
- A 404 from PostgREST on a relation or RPC already means "not deployed" (`backend-workers/lib/booking/store.js:91-99,283`). A missing new table can reuse that.

**Settings and server storage**
- `Settings.schedule` is a typed, preservation-carrying object inside the whole settings blob (`N/Domain/CanonicalModels.swift:1568-1594`; `Settings` from :1596). Settings sync is whole-blob last-writer-wins (2026-08-07 spec §3a). Time off is `schedule.blackouts`, whole days only.
- Every public booking lookup reads the whole settings blob (`store.js:77-85,116-124`), and every settings write takes the booking owner lock (the fence trigger above).
- **Server-authority tables** have RLS on, no client policy and no client grants (`supabase/migrations/20260921_booking_admin_state.sql:68-80`, P12-023). Capability tables store sha256 hashes only (`supabase/migrations/20260807_portal_tokens.sql`).
- Account deletion relies on `ON DELETE CASCADE` to `auth.users` (`backend-workers/lib/accountDeletion.js:126-127`). `supabase/verify/account_deletion_cascade.sql` audits it against an expected-table list.
- The booking horizon `slotWindowDays` has no upper bound in the editor (`N/NativeScheduleSettingsView.swift:342`).

**Outbound precedents**
- `backend-workers/lib/booking/ics.js` has `buildIcs` (UTC instants, :21-38) and `buildJobIcs` (floating local time, :66-92).
  - They are served by `GET /api/booking/manage?format=ics` (`src/routes/booking/manage.js:27-38`) and `GET /api/estimate/portal-ics` (`src/routes/estimate/portalIcs.js`; core `lib/estimate/portalIcs.js:17-41`).
  - Both are single-event downloads. Neither folds lines (RFC 5545 §3.1). That is fine for short lines but not for a feed carrying addresses.
- `tradeready://job/<id>` is an existing deep link, gated on sign-in and ownership (`N/NativeDeepLinkParser.swift:6-60`).
- A one-way owner tag (SHA-256 of a prefix plus the account binding) already exists (`N/NativeRejectedChangeStore.swift:111-117`).

**Native platform**
- The app's plist is **`native/Info.plist`** (`INFOPLIST_FILE = Info.plist`), not `N/Info.plist`.
  - Its only permission string is `NSCameraUsageDescription` (:30).
  - `UIBackgroundModes` is `fetch` (:34), and the BG task id is `com.gettradereadyapp.tradeready.sync-refresh` (:13).
  - The deployment target is **iOS 17.0** (`native/TradeReadyNative.xcodeproj/project.pbxproj:358,369,387,424`). So the iOS 17 EventKit access levels apply, and the legacy `NSCalendarsUsageDescription` key is not needed.
- Nothing in `native/` uses EventKit.
- `N/PrivacyInfo.xcprivacy` sets tracking to false. Its collected types already include `NSPrivacyCollectedDataTypeOtherUserContent` (App Functionality, linked) (:207-217).
- `docs/native-phase-12-release-readiness.md` §4.4 records the camera string as the only permission string. §5 holds the approved privacy-label proposal; the labels are not yet entered in App Store Connect.
- Background refresh:
  - `NativeBackgroundRefreshPolicy` (`N/NativeBackgroundRefresh.swift:13-28`) asks for a 30-minute earliest begin.
  - The work runs in `AppStore.performBackgroundRefresh` → `runBackgroundRefresh` (`N/AppStore.swift:9034,9045`).
  - Foreground refresh is `performForegroundRefresh` (`N/AppStore.swift:8658`).
- Precedents to copy:
  - The JWT Worker client is `N/NativeBookingAdministration.swift` (bearer token plus one refresh retry, :189-231).
  - The Worker JWT wrapper is `backend-workers/src/routes/booking/admin.js:28-40`.
- The native calendar is `NativeCalendar.buildCalendarDay` (`N/Domain/NativeCalendar.swift:65-99`) plus `N/NativeCalendarView.swift` (day/week, gap suggestion row :209). The Settings hub's `.schedule` destination is at `N/SettingsView.swift:136`.
- There is no per-install identifier.
- Google Sign-In is configured (`native/Info.plist:28-29`, `N/NativeGoogleSignIn.swift`). That matters only to the OAuth comparison in §1.2.

**Concurrent edits.** Phase 32 work has these files modified in the working tree, so line numbers in them may move:
- `N/AppStore.swift` and `N/SettingsView.swift`
- `native/TradeReadyNative.xcodeproj/project.pbxproj`
- `backend-workers/src/index.js`
- `native/run-all-domain-tests.sh` and `native/run-appstore-sources-common.sh`

The build keeps AppStore edits to a few hooks (§4.4) for this reason.

## 1. Options and recommendation

### 1.1 Outbound: jobs in the owner's calendar

| | A. Subscribable ICS feed (Worker) | B. EventKit "TradeReady" calendar (device) |
|---|---|---|
| Latency | The subscriber's poll: iOS lets the owner choose, from every 15 minutes upward. Google refreshes subscribed feeds every ~8–24 h and can't be forced | Immediate, and works offline |
| Reach | Any app that can subscribe: Google web, Outlook, Android | iOS Calendar, plus the owner's Mac and iCloud web through iCloud sync. Not Google web, unless the owner's Google calendar is the target (§9 R3) |
| New server surface | A public, bearer-token endpoint serving every scheduled job; a token table with rotation; line folding | None |
| PII exposure | Titles and addresses sit behind a URL that Google (or whoever subscribes) stores. A leaked URL exposes the whole schedule until it is rotated | Stays in the owner's own calendar account |
| Permission | None | Calendar **full access**. Write-only can't read back or update its own events, so it can't keep a mirror in sync (§5). Inbound needs the same full access anyway |
| Migration | Yes (token table) | No |
| Multi-device | One feed URL | Each device writes into the same iCloud calendar. Idempotency comes from event markers (§2.5) |

**Recommendation: B now (Stage B). Defer A (Stage C, sketched in §6) to an owner call (Q8).**
- Inbound already needs full calendar access, so B costs no extra permission.
- B adds no public endpoint that carries PII, and needs no migration or rotation UI.
- A subscribed feed that Google refreshes up to a day late is a poor way to carry a schedule.
- A is worth building only if the owner wants jobs in Google Calendar on the web, or in Outlook.

### 1.2 Inbound: personal busy times block booking slots

| | I1. On-device EventKit read → free/busy push | I2. Server-side Google Calendar OAuth (`freeBusy`) |
|---|---|---|
| Covers | Every calendar account on the device: iCloud, Google, Exchange, subscribed calendars | Google only. iCloud has no public API (CalDAV with app-specific passwords is rejected outright) |
| Freshness | Bounded by when the device last checked: foreground, BG refresh, change notifications. Needs a TTL (§1.4) | Live at offer time; no stale-device problem |
| New services | None. One Worker endpoint and one table | A Google Cloud OAuth client with Calendar scopes. These are **sensitive scopes, so Google verification is required** (justification and demo video; no CASA assessment for sensitive-only). Also: encrypted refresh-token storage (a new secret and table), refresh/revocation handling, and per-request Google latency and quota on public slot pages |
| Privacy | Only start/end times leave the device. Titles, locations, notes and attendees never do | Google grants the server read access; the policy needs a Google API Limited Use disclosure |
| Existing Google client | Unaffected | Adding Calendar scopes to the Sign-In project's consent screen puts sign-in under the same verification review |

**Recommendation: I1.**
- It is the build order's "no new services" path, and it covers iCloud, which I2 can't.
- **Caveat:** EventKit sees a Google calendar only if the owner has added the Google account in iOS Settings › Apps › Calendar › Calendar Accounts. The settings screen says so (§4.5).
- **Revisit I2 only if** device evidence shows owners whose calendars live only in the Google Calendar app, or the stale-snapshot fallback (§1.4) fires often in practice. The Worker logs a stale-snapshot count per owner for this purpose.

### 1.3 Where the busy times live

| | Settings blob (`schedule.calendarBusy`) | **New server-authority table (chosen)** | New synced collection |
|---|---|---|---|
| Migration | No | Yes | Yes |
| Write conflicts | Pushed every refresh into a whole-blob last-writer-wins record. That collides with real settings edits from other devices, and an older device can resurrect a stale snapshot | Isolated. A snapshot is replaced atomically | Isolated, but pulled back to every device for no reason |
| Cost on public lookups | Bloats the blob that every booking lookup reads and every write locks | One extra parallel read in slots/reserve only | Same as table |
| Validation | Device-trusted | The Worker validates on write **and** re-validates on read | Device-trusted |
| Removal | The owner's next settings push | `DELETE` on turn-off; cascades on account deletion | Tombstones |

**Recommendation:** a table `calendar_busy`, one row per owner, written only through an authenticated Worker endpoint. It follows the P12-023 server-authority pattern (§2.3). The migration is Q6.

### 1.4 Freshness: what a stale device means

- **Fail open** (ignore old busy times) re-creates the problem the feature exists to solve.
- **Fail closed** means no offered slots, and `book.html` drops to request mode. The customer can still reach the owner; only instant booking pauses.

**Recommendation: fail closed, using a TTL plus explicit coverage.**
- A snapshot is fresh for **48 hours** after `effectiveAt = min(computedAt, receivedAt)`. Taking the minimum means neither a fast device clock nor a delayed upload makes old data look new.
- The snapshot covers only `[windowStart, windowEnd)`. Time outside that coverage counts as busy.
- 48 hours rides out a weekend with one background refresh. The owner sees the state in Settings and on Today (§4.5), and opening the app refreshes it.

### 1.5 Staging

| Stage | Contents |
|---|---|
| **A — inbound** (most value) | Pure busy rules and the gate (both twins); the Worker endpoint, table, and slots/reserve gate; shared parity vectors; EventKit read; the settings page; the in-app calendar overlay and conflict warning; the Today stale row |
| **B — outbound** | The EventKit "TradeReady" calendar mirror, with a toggle on the same settings page |
| **C — ICS feed** | Deferred (Q8). Sketched in §6 |

## 2. Data model

### 2.1 Device-local state (not synced)

Stored in standard `UserDefaults` (already declared under `CA92.1`) and keyed by the account binding. All of it is wiped by the account-scrub paths (§4.7).

| Key | Meaning |
|---|---|
| `calendarSync.sourceId` | A random UUIDv4 generated with `SecRandomCopyBytes` on first enable. It identifies this install to the server and is never derived from device or user data |
| `calendarSync.checksEnabled` | "Check my calendars for busy times" |
| `calendarSync.excludedCalendarIDs` | An **exclusion** list, so calendars added later are checked by default (conservative) |
| `calendarSync.lastPush` | `{digest, at}` from the last successful push |
| `calendarSync.mirrorEnabled`, `calendarSync.mirrorCalendarID` | The Stage B toggle and the identifier of the TradeReady calendar |
| `calendarSync.notice` | A one-time notice, such as "TradeReady calendar was deleted" or "Calendar checks moved to another device" |

### 2.2 Wire snapshot (device → Worker)

```json
{
  "v": 1,
  "computedAt": "2026-10-03T14:05:00Z",
  "windowStart": "2026-10-03T05:00:00Z",
  "windowEnd":   "2026-10-17T05:00:00Z",
  "timed":  [["2026-10-06T15:00:00Z", "2026-10-06T16:30:00Z"]],
  "allDay": [["2026-10-10", "2026-10-11"]]
}
```

- **Instants** are UTC at minute precision and must match `^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:00Z$`. Starts are floored to the minute and ends ceiled.
- **`windowStart`** is the start of today in the owner's `schedule.timeZone`.
- **`windowEnd`** is `windowStart` plus `min(slotWindowDays, 62)` days, computed zone-aware so it is DST-safe.
- **`timed`** pairs are sorted, merged, and strictly non-overlapping (touching blocks merge). Each pair is clipped to the window.
- **`allDay`** pairs are owner-naive inclusive date ranges, sorted and non-overlapping.
- **Caps:**
  - at most 500 `timed` pairs and 100 `allDay` ranges
  - window length ≤ 63 days, and each all-day range ≤ 63 days
  - request body ≤ 64 KB
- **Truncation:** if merging leaves more than 500 timed pairs, the device keeps the first 500 and pulls `windowEnd` back to the floored start of the 501st. The dropped tail is then uncovered, and so busy.
- **`snapshot: null`** means "calendar checks are on, but nothing is shared". It is used while bookable slots are off (§4.4), and the gate treats it as stale, so it fails closed.

### 2.3 Table (`supabase/migrations/20261003_calendar_busy.sql`, owner-applied)

```sql
create table if not exists public.calendar_busy (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  source_id    text not null,                 -- device install id (2.1)
  snapshot     jsonb,                         -- {v,timed,allDay}; null = registered, nothing shared
  computed_at  timestamptz,
  window_start timestamptz,
  window_end   timestamptz,
  received_at  timestamptz not null default now(),  -- server clock, stamped on every put
  check (snapshot is null or (computed_at is not null and window_start is not null and window_end is not null))
);
alter table public.calendar_busy enable row level security;
-- Server-authority table (P12-023): no client policy, no client grants.
revoke all on public.calendar_busy from anon, authenticated;
```

- Only the service role touches the table. No fence trigger is needed, because the claim RPC doesn't read it (§3.4).
- The migration is idempotent, follows the `20260921` header style, and states the rollback (`drop table`).

### 2.4 Busy-window derivation: the shared pure gate (Worker and Swift twins)

`calendarBusyGate(row, {timeZone, nowMs, ttlHours = 48})` → `off | stale | fresh {windows, lastCoveredDate}`:

1. **No row** → `off`. Availability is exactly today's behavior.
2. **Row with a null snapshot, or one that fails re-validation (§3.1)** → `stale`.
3. **`nowMs − min(computedAt, receivedAt) > ttlHours`**, or **`windowEnd ≤ nowMs`** → `stale`.
4. **Timed pair `[s, e)`** → let `offS = offset(s)` and `offE = offset(e)` in `timeZone`. The local span is `[s + min(offS, offE), e + max(offS, offE))`.
   - This is exact when no transition falls inside the block, and a superset across one. A fall-back fold widens the window rather than losing the repeated hour.
   - The span is split per naive date into `{date, start, end}`. A day's end of 24:00 is encoded as **`"23:59"`**. That is equivalent for slots, since `workDayEnd ≤ 23:59` means no slot can end later. It also never trips the Swift gap in §0.
   - Windows that are empty after clipping are dropped.
5. **All-day range `[d1, d2]`** → `{d, "00:00", "23:59"}` for each date in the range.
6. **Coverage edges:**
   - The head: the time before `windowStart`'s latest local reading on its date is busy.
   - The tail: `windowEnd`'s earliest local reading `(D, M)` begins busy time. If `M = 0`, then `lastCoveredDate = D − 1` with no tail window. Otherwise `lastCoveredDate = D`, plus a window `{D, M, "23:59"}`.
7. **Output** windows are sorted by `(date, start, end)` and not merged; the engine merges them.

`offerableSlots({schedule, jobs, reservations, calendarRow, nowMs})` is the shared pipeline that `slotsCore` and `reserveCore` now both call. It:
- resolves `now`;
- runs the gate;
- on `stale`, returns `[]`;
- on `fresh`, sets `extraBusy = reservations ∪ windows` and `days = min(slotWindowDays, epochDays(lastCoveredDate) − epochDays(now.date) + 1)`, clamped at 0;
- on `off`, behaves exactly as today;
- then calls the unchanged `computeCandidateSlots` and `resolveSlotsUtc`.

The **buffer applies** to calendar windows, as it already does to reservations. It is travel and setup time either way.

### 2.5 Mirror event mapping (Stage B, device only)

| Event field | Value |
|---|---|
| Calendar | "TradeReady", created in the iCloud CalDAV source when one exists; otherwise the default calendar's source if it accepts new calendars; otherwise Local |
| Title | `"<job title> — <customer name>"` (just the title when there's no customer; "Job" when there's no title) |
| Location | The job address, when non-empty |
| Start/end | Timed: `scheduledStartTime` to `scheduledEndTime`. When the end is missing or not after the start, use start + `max(laborHours, 1h)`, capped at midnight (the `blockWindow` rule). Untimed: an all-day event on `scheduledDate` |
| Time zone | `schedule.timeZone` when it is a valid IANA zone. Otherwise the event is **floating** (`timeZone = nil`), matching `buildJobIcs` |
| URL | `tradeready://job/<percent-encoded id>`, the existing gated deep link |
| Notes | `"Status: <label>"`, then `"Managed by TradeReady. Changes made here are replaced; edit the job in TradeReady."`, then the marker line `tradeready-job:<ownerTag16>:<jobId>` |
| Availability / alarms | Busy / none (the app's own appointment reminders already exist) |

- **Jobs mirrored:** not archived, a valid `scheduledDate` within `[today − 30, today + 180]`, and status not `declined`. Completed, invoiced and paid jobs stay as history.
- **`ownerTag16`** is the first 16 hex characters of a one-way tag of the account binding (the `NativeRejectedChangeStore.ownerTag` pattern, with its own prefix).
- **Reconcile touches only events whose marker carries this account's tag.** A different account signed in on the same device never edits or deletes the first account's events.

## 3. Worker

### 3.1 `POST /api/calendar/busy` (owner JWT)

- The wrapper is `backend-workers/src/routes/calendar/busy.js`, a copy of `routes/booking/admin.js:19-51`: static CORS, JWT → `userId`, and a per-user limit of 20 per window.
- The core is `backend-workers/lib/calendar/busyCore.js` with signature `busyCore(env, {userId, body, nowMs})` → `{status, body}`.

| `action` | Body | Result |
|---|---|---|
| `put` | `{sourceId, snapshot \| null, takeOver?}` | Validates, then upserts and stamps `received_at = now`. If a row exists with another `source_id` and `takeOver !== true`, answers **409** `{error: "source_mismatch", receivedAt}`. Otherwise 200 `{ok, receivedAt}` |
| `status` | `{sourceId}` | 200 `{ok, enabled, thisDevice, shared, computedAt, receivedAt, fresh, ttlHours}`. `shared` means the snapshot is non-null; `fresh` comes from the §2.4 gate |
| `disable` | `{}` | Deletes the owner's row, from any device, because it is the owner's intent. 200 `{ok}` |

**`validateSnapshot`** lives in `lib/calendar/busyGate.js`, shared with the read path. Any violation answers 400 `{error: "invalid_snapshot"}` and changes nothing. It checks:
- `v === 1`, and `sourceId` is a lowercase UUID;
- every timestamp matches the regex in §2.2 and parses;
- `windowStart ≤ computedAt`, `windowStart < windowEnd`, and the window is at most 63 days;
- `computedAt ≤ nowMs + 10 min` and `windowStart ≤ nowMs + 10 min` (bounded clock skew);
- the §2.2 caps, ordering and non-overlap;
- each timed pair lies inside the window;
- all-day dates are real calendar dates (round-trip through `Date.UTC`);
- the body is at most 64 KB.

- **Missing table:** a PostgREST 404 on `calendar_busy` makes the endpoint answer **503** `{error: "unavailable"}`. The device then shows "Calendar checks aren't available yet".
- **Logging:** `put` logs only counts (`timed`, `allDay`, window days), never instants.

### 3.2 Store

`backend-workers/lib/calendar/busyStore.js` (service role, raw PostgREST, the `store.js` pattern):
- `fetchCalendarBusy(env, userId)` → row or `null`. A 404 on the relation also gives `null` ("feature not deployed" = `off`).
- `upsertCalendarBusy(env, row)` uses `Prefer: resolution=merge-duplicates` on `user_id`. `busyCore` checks the source by reading the row first and then upserting. A race between two devices both taking over is harmless; last write wins.
- `deleteCalendarBusy(env, userId)`.

### 3.3 Slots and reserve

- `slotsCore` and `reserveCore` fetch `calendar_busy` alongside jobs and reservations (one more entry in each `Promise.all`), then call `offerableSlots` (§2.4) from the new `backend-workers/lib/booking/offerable.js`.
- **Slots, stale:** 200 `{businessName, timeZone, slots: []}`. This is indistinguishable from "fully booked", so the response is no oracle on the owner's device or calendar state, and `book.html` shows the request form.
- **Reserve, stale or overlapping:** 409 `slot_taken`, the existing remedy (refresh the list, which now drops to request mode).
- **A calendar fetch error other than 404** answers 500, like a jobs-fetch failure today.
- The response shapes and the `availability.js` engine are unchanged, so `__tests__/availabilityParity.test.ts` (RN ↔ Worker) stays green untouched.
- Each stale answer logs `[booking/slots] calendar_stale` with the user id prefix only. That count is the §1.2 revisit signal.

### 3.4 Claim RPC: unchanged in v1

- The JS re-check in `reserveCore` reads the same snapshot microseconds before the RPC runs, and live traffic runs the legacy path anyway (§0).
- Extending `claim_booking_slot` would mean redefining a 220-line, not-yet-applied function, and adding a third (plpgsql) twin of the gate.
- The residual is §9 R5. The follow-up, if wanted, is a UTC-instant overlap check in SQL (`p_slot_start_utc − buffer < block_end AND block_start < p_slot_end_utc + buffer`). It is exact, weaker than or equal to the JS superset, and needs no naive conversion.

### 3.5 Registration

In `backend-workers/src/index.js`, add `app.all('/api/calendar/busy', calendarBusyHandler)` and then `app.all('/api/calendar/:action', 404)`, following the booking/estimate families.

## 4. Native

### 4.1 Pure domain (Foundation-only)

**`N/Domain/NativeCalendarBusy.swift`**

Busy rules over a value-type `Sample {start, end, isAllDay, availability, status, ownerDeclined, calendarID}`:

| Event | Counts as busy? |
|---|---|
| Calendar excluded, or the TradeReady mirror calendar | Never (always skipped) |
| A `tradeready-job:` marker in its notes, in any calendar | Never (defensive skip) |
| Status `canceled`, or the owner declined (`isCurrentUser` attendee with participant status declined) | No |
| Availability `free` | No |
| **Timed**, availability busy, unavailable, **tentative** or notSupported | **Yes** |
| **All-day**, availability busy or unavailable | **Yes** |
| All-day, availability free, tentative or notSupported | No. Birthdays, holidays and "Mom's birthday" don't wipe out a day; vacations belong in Time off, and the settings copy says so |
| Zero or negative duration | No |

- `makeSnapshot(samples:windowStart:windowEnd:computedAt:calendar:)` clips, rounds, merges and truncates timed blocks (§2.2). It derives all-day dates from `startDate` and `endDate − 1 s` in the injected `Calendar`, which is the device zone, because all-day events float.
- `encode` produces the exact wire JSON. `digest` is the SHA-256 of `{windowEnd, timed, allDay}`.
- The **gate twin** is `gate(_ stored:, timeZoneID:, nowMillis:, ttlHours:)`, mirroring §2.4 exactly. `offerableSlots(...)` is its pipeline twin.
- The in-app overlay uses the same gate on a locally built snapshot, so **what the owner sees is what the booking page enforces.**

**`N/Domain/NativeCalendarMirror.swift`**
- `desiredEvents(jobs:schedule:today:ownerTag:)` produces naive dates and times plus a zone id. The adapter turns those into `Date`s.
- `plan(desired:existing:)` produces `[create | update(eventID) | delete(eventID)]` over `Existing {eventID, externalID?, creationDate?, marker?, fields}`:
  - Unmarked events, and events marked for another owner, are **never touched**.
  - Marked events are grouped by job id. The survivor is the earliest `creationDate`, then the smallest `externalID`, then the smallest `eventID`. Every device picks the same survivor, so concurrent creates converge. The others are deleted.
  - The survivor is updated when any mirrored field differs. Calendar-app edits are therefore restored, because the mirror is one-way. It is deleted when its job is no longer desired.
  - A desired event with no survivor is created.
  - Only events starting inside the mirror window are considered. A pass makes at most 200 operations; the rest wait for the next pass.

### 4.2 EventKit adapter: `N/NativeEventKitBridge.swift` (`#if canImport(EventKit)`)

- **Protocol `NativeCalendarAccess`**, so host tests inject a fake:
  - `authorization`
  - `requestFullAccess()` (`requestFullAccessToEvents()`)
  - `calendars()`
  - `samples(start:end:)`, via `predicateForEvents(withStart:end:calendars:)`. EventKit expands recurring events into occurrences within the window (≤ 63 days, far under its 4-year predicate limit), so detached exceptions arrive as their own events.
  - `ensureMirrorCalendar()`
  - `mirrorEvents(start:end:)`
  - `apply(_ ops:)` (`save(_:span:.thisEvent, commit:false)`, then one `commit()`)
- **Authorization handling:**
  - `.fullAccess` is the only usable state.
  - `.writeOnly` is treated as denied; it can't occur without the write-only key (§5).
  - `.denied` and `.restricted` show "Open Settings" (`UIApplication.openSettingsURLString`).
- **Change observation:** observes `.EKEventStoreChanged` while the app is in the foreground, debounced 5 s. Notifications within 2 s of our own commit are ignored (an optimization only; a reconcile with no diff writes nothing).

### 4.3 Transport: `N/NativeCalendarSyncTransport.swift`

A copy of the booking-admin transport (`BuildEnvironment.endpoint("api/calendar/busy", sendsUserData: true)`, bearer token, one refresh retry). The typed results are `ok`, `sourceMismatch`, `unavailable`, `invalid`, `offline` and `unauthorized`.

### 4.4 Coordinator and triggers: `N/NativeCalendarSyncCoordinator.swift`

The coordinator is owned by `AppStore`. AppStore gets only hooks, to stay clear of the concurrent edits.

**When it runs**
- On every foreground (`performForegroundRefresh`).
- On every BG refresh, after sync (`runBackgroundRefresh`).
- On `EKEventStoreChanged`.
- After a schedule settings save.
- After canonical job writes and sync pulls. These are debounced 2 s and affect the mirror only.

**Inbound (this device is the source)**
- `sharing` is true when checks are enabled, `schedule.bookableSlotsEnabled` is on, and the zone is valid.
- When `sharing`, the device builds the snapshot and pushes when the digest changed **or** the last push is older than **30 minutes**. The 30-minute heartbeat keeps a quiet calendar fresh.
- When not `sharing`, the device sends one `put` with `snapshot: null` on the transition. Busy times never sit on the server while slots are off, and if another device later turns slots on, booking fails closed until this device shares.
- **Order on enable:** when a schedule save turns slots on, the coordinator awaits a push before the settings change is queued. An offline device queues both, and the brief fail-open window is §9 R6.
- On `sourceMismatch`, the device stops pushing and offers "Calendar checks run on another device. Use this one instead?". Accepting retries with `takeOver: true`.
- Turning checks off asks for confirmation ("Your booking page will stop checking your personal calendar"), then calls `disable`.

**Status**
- When slots are on, any signed-in device fetches `status` at most once per 30 min on foreground. That status feeds the settings page and the Today row (§4.5).

**Outbound (Stage B)**
- After each trigger: ensure the calendar exists, fetch the mirror window, plan, and apply.
- The mirror calendar is found by its stored identifier only, never by title (§11.7). When calendars are readable and the stored identifier is genuinely absent, the mirror is turned **off** with a notice. It is never silently recreated. When no calendar can be read (for example, protected data is unavailable), nothing changes and the next pass tries again.
- An existing calendar is adopted (after sign-out or reinstall) only when it is provably this account's mirror; otherwise a new one is created (§11.7).

### 4.5 UI

**Settings › Calendar sync** (new hub row after Schedule; `N/NativeCalendarSyncSettingsView.swift`):

**Calendar checks**
- **Toggle:** "Check my calendars for busy times".
  - The first enable shows an explainer sheet, then the system prompt. The sheet says what is read, what leaves the device, and that Google calendars must be added in iOS Settings to appear.
- **Calendar list:** grouped by account, with checkmarks. Birthday and subscribed (holiday/sports) calendars default to off, and the TradeReady calendar is hidden.
- **Status row:**
  - "Booking page updated 5 min ago · busy times for the next 14 days"
  - "Not shared: bookable time slots are off"
  - "Runs on another device · last update 3 h ago [Use this device]"
  - "Out of date: your booking page takes requests only until TradeReady checks again"
- **Footer:** "Only start and end times are sent to TradeReady, never event names, places, notes or guests. All-day events block booking only when they're marked Busy; add vacations under Schedule › Time off."

**Add jobs to my calendar**
- **Toggle:** "Add my jobs to a TradeReady calendar". It shows the account used ("iCloud") and a one-device recommendation.
- **Turning it off** offers "Remove calendar" or "Keep calendar". Remove is the default; its copy says it removes the calendar from every device on that account.

**Elsewhere**
- **Hub subtitle:** "Off", "Busy times shared", "Calendar access is off" (warning), and so on.
- **Today:** while slots are on and `status` says enabled but not fresh, Today shows one attention row: "Online booking is request-only: calendar checks haven't run since <date>". It opens the settings page, follows the existing Today attention pattern, and can't be muted.
- **Calendar view** (`N/NativeCalendarView.swift`, `N/Domain/NativeCalendar.swift`), when checks are on:
  - `buildCalendarDay` gains an optional `personalBusy` parameter (default empty, so existing vectors are unchanged).
  - Grey "Busy (personal)" blocks render with no titles.
  - A job overlapping personal busy time gets a separate, warning-only label: "Overlaps a personal event".
  - The gap suggestion (:209) treats personal busy time as occupied, through an optional parameter on `NativeSchedule.largestFreeGap` (default empty).
  - The schedule editor's conflict warning shows the same label.

### 4.6 Swift `"24:00"` fix

`NativeAvailability.busyWindowsFor` will accept an `extraBusy` end of exactly `"24:00"` as 1440, which is what the Worker and RN already do. It gets a shared vector. The gate never emits `"24:00"`; this closes the latent fail-open gap from §0.

### 4.7 Account boundary

- **Sign-out:** stops both directions and wipes the §2.1 keys. The server row stays and goes stale, so booking fails closed until the owner turns checks on with another device. The Today row on other devices says so. The TradeReady calendar stays; it is the owner's data in their own account.
- **Account deletion:** cascades the row. On this device, when the mirror was on, the TradeReady calendar is also removed, best effort, as a step in the existing scrub, but only when every event in it carries this account's tag; otherwise only this account's events are deleted and the calendar stays (§11.7).

## 5. Privacy and platform

**What leaves the device**

| Where | What |
|---|---|
| Worker / `calendar_busy` | UTC start/end instants of busy periods within the booking window (up to 62 days), plus all-day busy dates and a random install id. No titles, locations, notes, attendees, calendar names, or event ids. Each put replaces the last; turning checks off deletes the row |
| Customers (`book.html`) | Only the offered slots, as today. Gaps in the offers imply busy times, just as jobs already do; that is inherent to any booking page. A stale snapshot looks like "fully booked" |
| Worker logs | Counts and a user-id prefix; no instants |
| Mirror calendar | Job titles, customer names and addresses, written into the owner's own calendar account. TradeReady's servers aren't involved |

**Permission strings** (`native/Info.plist`; **NEEDS OWNER APPROVAL**, Q1–Q2)
- **Add** `NSCalendarsFullAccessUsageDescription`:
  > TradeReady checks the calendars you choose for busy times so your booking link won't offer them, and can add your jobs to a TradeReady calendar. Only busy start and end times are sent to TradeReady, never event names, notes or guests.
- **Do not add** `NSCalendarsWriteOnlyAccessUsageDescription`.
  - Write-only access can't read events back, not even the app's own, so it can neither do inbound nor keep a mirror in sync.
  - Leaving the key out also keeps iOS Settings to None / Full Access for TradeReady, with no "Add Events Only" state.
- **Do not add** the legacy `NSCalendarsUsageDescription`, because the deployment target is 17.0.
- `docs/native-phase-12-release-readiness.md` §4.4 gets the new string recorded.

**Privacy manifest** (`N/PrivacyInfo.xcprivacy`; **NEEDS OWNER APPROVAL**, Q3)
- EventKit is not a required-reason API.
- Busy times fit the already-declared `NSPrivacyCollectedDataTypeOtherUserContent` (linked, not tracking, App Functionality). The proposal is a **comment-only edit** recording that, plus the manifest test's comment.

**App Store privacy label** (**NEEDS OWNER APPROVAL**, Q4)
- No new data type.
- Release-readiness §5's "Other User Content" row "Why" gains: "and, if calendar checks are on, busy start/end times from calendars the user selects".
- The alternative is a separate "Other Data Types" row; it is not recommended, because the data is user content used only for app functionality.

**Privacy policy** (`tradeready-legal/privacy.html` §1, after "App data"; **NEEDS OWNER APPROVAL**, Q5)
> **Calendar busy times (optional):** if you turn on calendar checks, the app reads the calendars you choose on your device and sends us only the start and end times of busy periods in your booking window (up to about two months ahead), so your booking page doesn't offer those times. Event titles, locations, notes and attendees never leave your device. Each update replaces the last one, and turning calendar checks off deletes them from our servers. If you turn on "Add my jobs to a TradeReady calendar", the app writes your scheduled jobs into a calendar on your device (your calendar account, such as iCloud, may sync it); our servers aren't involved.

**App Review notes:** one line naming Settings › Calendar sync, what it reads, and that it is optional.

## 6. Stage C (deferred): subscribable ICS feed

The design is recorded so it isn't lost. Build it only on a Q8 "yes".

- **Token:** a server-authority table `calendar_feed_tokens (user_id pk, token_hash, created_at, rotated_at)` that stores hashes only. A JWT `POST /api/calendar/feed-admin` handles `mint | rotate | disable`; rotate kills existing subscriptions, the portal-token pattern.
- **Feed:** `GET /api/calendar/feed?f=<token>` (IP-limited, `Cache-Control: private, max-age=900`) serves `text/calendar` built from the owner's `jobs` rows (service role; the same selection as §2.5). It uses `UID:<jobId>@tradeready-feed` and floating times, like `buildJobIcs`, and **adds RFC 5545 line folding**.
- **Detail level:** owner-chosen and **default "title only"**, with no customer name and no address, since a leaked URL exposes the schedule. "Include customer and address" is opt-in.
- **Cost:** one migration, two routes, a native "Subscribe in Google Calendar" share sheet, and privacy-policy text. Google refreshes a subscription every ~8–24 h.

## 7. Testing

**New Swift suite: `native/CalendarSyncTests/main.swift`** (runner `native/run-calendar-sync-tests.sh`, modelled on `run-availability-tests.sh` and run with `TZ="${TZ:-America/Phoenix}"`; registered in `native/run-all-domain-tests.sh`)
- **Busy rules:** every row of the §4.1 table (canceled, declined, free, tentative, notSupported, timed vs all-day), the excluded calendar, the mirror calendar, a marker in another calendar, zero duration.
- **Snapshot:**
  - clipping, minute floor/ceil, merging touching and overlapping blocks
  - truncation at 500 pulls `windowEnd` back
  - all-day dates under an injected Phoenix and Auckland `Calendar`
  - the exact wire JSON, and digest stability
- **Mirror planner:**
  - create, update on any field difference (restoring a Calendar-app edit), delete when the job is declined, archived, unscheduled or deleted
  - duplicates converge on the same survivor across two simulated devices
  - unmarked and foreign-owner events are untouched
  - the window bounds, floating vs zoned events, untimed → all-day, a missing or invalid end → `blockWindow`, a midnight cap, and the 200-op cap

**Shared vectors** (extend `native/ScheduleTests/Fixtures/scheduleVectors.json`; this is the parity extension)
- **`calendarBusyVectors`:** `{name, zone, nowUtc, row, expected: {state, windows, lastCoveredDate}}`. Required cases:
  - no row → `off`; null snapshot → `stale`
  - TTL edge: 47:59 fresh, 48:01 stale
  - a future `computedAt` uses `receivedAt`; `windowEnd` in the past → `stale`; an invalid snapshot → `stale`
  - a block across midnight
  - America/Chicago spring-forward (2026-03-08) and fall-back fold (2026-11-01; expected window 00:30–02:15)
  - Pacific/Auckland and Asia/Kolkata
  - an all-day range
  - head and tail coverage (midnight vs mid-day `windowEnd`)
  - a day ending at 24:00 encoded as `"23:59"`
- **`offerableScenarios`:** `{scheduleBlob, jobs, reservations, row, nowUtc, expected: {slots}}`, covering: busy removes slots, the buffer pads calendar windows, coverage caps the days, a stale snapshot gives `[]`, `off` matches today's output, and a reservation and a calendar block coexist.
- **`"24:00"` vector:** an `extraBusy` end of `"24:00"` blocks to midnight in both engines (§4.6).
- **Swift:** `native/AvailabilityTests/main.swift` asserts every new section.
- **Jest:** a new `__tests__/calendarBusyParity.test.js` **reads the same JSON** and asserts the Worker against the same `expected` values. It also asserts the existing `zoneVectors` and `nowVectors`, so the file becomes truly shared rather than hand-copied.

**Updated Swift suites**
- `CalendarTests`: the `personalBusy` overlay, the "Overlaps a personal event" label, and the gap suggestion with personal busy time. Existing vectors are unchanged with the default.
- `StoreIntegrationTests`, with a fake `NativeCalendarAccess` and a fake transport:
  - foreground push, heartbeat, and the digest skip
  - a null snapshot while slots are off; push-before-enable ordering
  - `sourceMismatch` → takeover
  - disable on toggle-off; `unavailable` (503) state
  - scrub wipes the keys; the mirror calendar is removed on deletion
  - mirror turned off when its calendar is gone
- `TodayBriefingTests`: the stale row shows only when slots are on and status is enabled but not fresh.
- `ScheduleBookingSettingsTests`: the save path awaits the push when enabling slots.
- Runner registration: add `NativeCalendarBusy.swift` and `NativeCalendarMirror.swift` to `run-availability-tests.sh`, `run-calendar-tests.sh`, `run-today-briefing-tests.sh` and `APPSTORE_TEST_SOURCES` in `native/run-appstore-sources-common.sh`. Then run `node scripts/parity-manifest.mjs --write`, and add `calendar-sync` / `calendarBusyParity` to the Calendar row in `scripts/parity-map.json`.

**Worker** (root Jest, `TZ=America/Phoenix npm test -- --runInBand --runTestsByPath …`)
- New `__tests__/calendarBusyWorkers.test.js` against `busyCore`:
  - the validation matrix: every cap, regex, ordering, overlap, skew, window length, bad date and oversized body
  - put/replace; `source_mismatch` and `takeOver`; `disable`; `status` (fresh, stale, null, absent)
  - a missing table → 503
  - logs carry no instants
- `__tests__/bookingSlotsReserve.test.js` additions:
  - fresh busy time removes slots and reserve answers 409 on an overlap
  - stale → slots 200 `[]` and reserve 409
  - an absent row, or a missing table (404), → byte-identical to today
  - a calendar fetch 500 → 500
  - coverage caps the days
- `__tests__/availabilityParity.test.ts` stays untouched and green.
- `cd backend-workers && npm test` stays green.

**SQL**
- The migration file, plus a `supabase/verify/calendar_busy.sql` read-only check: RLS on, zero policies, zero client grants.
- Add `calendar_busy` to the expected list in `supabase/verify/account_deletion_cascade.sql`.
- Add the apply/re-apply step to `supabase/verify/local/run.sh`.

**Gates**
- `sh native/run-all-domain-tests.sh`
- the Release compile
- the targeted Jest files under Phoenix
- `cd backend-workers && npm test`
- `sh supabase/verify/local/run.sh`
- `sh native/run-doc-reference-check.sh`

**Device evidence** (deferred to Phase 12 under the 2026-09-16 deferral decision)
- the permission prompt, then denial, then revocation in iOS Settings
- a Google account added in iOS shows its calendars, and busy times block slots end to end
- all-day defaults for iCloud and Google events
- BG refresh cadence over a weekend
- the iCloud "TradeReady" calendar appears on a Mac
- what happens when the default source is a Google account
- two devices converge on the mirror

## 8. Rollout

1. Owner answers Q1–Q8.
2. Build Stage A, then Stage B, on `feat/calendar-sync` (local, stacked, no push).
3. **Owner applies `20261003_calendar_busy.sql`**, then runs `supabase/verify/calendar_busy.sql` (the grant query must return zero rows). The order relative to the Worker deploy doesn't matter: before the table exists, the Worker treats busy times as `off` and the endpoint answers 503.
4. Deploy the Worker.
5. Publish the privacy-policy change before the native build ships.
6. Ship the native build. Then update the App Store Connect label text (Q4) and add the App Review note.

**Rollback:** turning checks off deletes the row. A Worker revert ignores the table. `drop table public.calendar_busy` removes everything. No settings, job or booking data changes, so nothing needs unwinding.

## 9. Accepted residuals

- **R1. Stale snapshot → request-only.** If no device checks for 48 h (the phone is off, Low Power Mode, a force-quit app, or the user signed out), the booking page takes requests only until the app opens. That is deliberate (§1.4), and Today shows it.
- **R2. Calendars missing from the device.** Google calendars that aren't added to iOS Calendar are invisible. The settings copy explains this.
- **R3. Mirror reach.** The mirror lives in iCloud (or Local), not Google Calendar; creating calendars in a Google CalDAV source from iOS is unverified (Phase 12 row). Google-web visibility is Stage C.
- **R4. Collisions within the freshness window.** An event added after the last check can be booked over until the next check. The owner gets the booking alert, and Phase 11 D reschedule is the remedy.
- **R5. Claim RPC doesn't read busy times** (§3.4). A block landing between the JS re-check and the RPC, a window of milliseconds, isn't seen.
- **R6. Enable-order gap.** When an offline device enables slots, the settings change may sync before the first busy push. Booking runs on jobs only until that push lands.
- **R7. Floating timed events** are read in the device's current zone. That differs from the schedule zone only while travelling.
- **R8. Multi-device mirror.** Concurrent creates converge (§4.1) but can briefly show a duplicate. The settings copy recommends one device.
- **R9. Calendar-app edits** to mirrored events are overwritten. The event notes say so.
- **R10. Horizon cap.** With checks on, booking horizons beyond 62 days are cut to 62. The settings page notes it.
- **R11. Old snapshots linger.** A stale row keeps its last (past-dated) times until it is replaced or turned off. Once the window has passed they hold no future information. A cron purge would turn fail-closed into fail-open, so none is added.
- **R12. The dormant Vercel twin and RN** are unchanged. RN owners never get calendar sync.

## 10. Decisions

### Decided (within the owner's 2026-10-03 go-ahead)

| # | Decision | Choice |
|---|---|---|
| D1 | Inbound mechanism | On-device EventKit; free/busy only (§1.2) |
| D2 | Storage | A new server-authority table, one row per owner, written only through the Worker (§1.3, §2.3) |
| D3 | Multi-device inbound | One source device per owner; switching is an explicit takeover (§4.4) |
| D4 | Freshness | 48 h TTL from `min(computedAt, receivedAt)`, plus explicit coverage; stale → no slots (request mode), reserve → 409 (§1.4, §2.4) |
| D5 | Time conversion | UTC instants on the wire; owner-naive windows with the conservative fold rule; all-day as dates; `"23:59"`, never `"24:00"` (§2.4) |
| D6 | Event rules | §4.1 table: tentative counts as busy; all-day only when Busy or Unavailable |
| D7 | Calendar selection | An exclusion list, so new calendars are included; birthday and subscribed calendars are off by default |
| D8 | Buffer | Pads calendar windows, as it does reservations |
| D9 | Caps | 500 timed, 100 all-day, a 62-day window (63 accepted), 64 KB; truncation pulls coverage in |
| D10 | Data minimization | Busy times are shared only while bookable slots are on; otherwise a null snapshot keeps booking failing closed |
| D11 | Refresh | Foreground, BG refresh, `EKEventStoreChanged` (5 s debounce), schedule save; 30-min heartbeat |
| D12 | Claim RPC | Unchanged in v1 (§3.4, R5) |
| D13 | Outbound | EventKit "TradeReady" calendar (Stage B): one-way, marker-based idempotency, owner-tagged markers, deterministic de-dupe, deep link |
| D14 | Mirror scope | Non-archived, non-declined jobs scheduled within [−30, +180] days; untimed → all-day; floating unless a schedule zone is set |
| D15 | Mirror calendar deleted / mirror off | Deleted outside the app → mirror off with a notice, never recreated silently. Turning it off defaults to removing the calendar, after confirmation |
| D16 | In-app awareness | Personal busy overlay, a "personal event" conflict label and gap suggestion, using the same gate twin |
| D17 | Swift `"24:00"` | Fixed to match the Worker and RN (§4.6) |
| D18 | Parity | `scheduleVectors.json` becomes read by Swift **and** Jest; new busy and offerable sections (§7) |
| D19 | Analytics | None, unless the event catalog allowlists `calendar_checks_enabled` / `calendar_mirror_enabled`, with no counts or times |

### NEEDS OWNER APPROVAL

| # | Question | Recommendation |
|---|---|---|
| Q1 | May we add `NSCalendarsFullAccessUsageDescription` to `native/Info.plist` with the exact text in §5? | **Yes.** It is the only way to read busy times or keep a mirror in sync on iOS 17+ |
| Q2 | May we leave out `NSCalendarsWriteOnlyAccessUsageDescription` (and the legacy `NSCalendarsUsageDescription`)? | **Yes, leave both out.** Write-only can't support either direction, and the legacy key is unnecessary at a 17.0 deployment target |
| Q3 | Privacy manifest: may we record busy times under the existing `OtherUserContent` declaration (a comment-only edit, no new collected-data type)? | **Yes.** No required-reason API is involved |
| Q4 | App Store privacy label: may we fold busy times into the existing "Other User Content" (App Functionality, linked, not tracking) row, updating release-readiness §5's "Why" text, rather than adding a type? | **Yes.** The alternative "Other Data Types" row is accurate but adds a label for the same purpose |
| Q5 | May we add the §5 paragraph to `tradeready-legal/privacy.html` §1 (you publish it before the native ship)? | **Yes.** The policy must describe the upload before it ships |
| Q6 | May we write `supabase/migrations/20261003_calendar_busy.sql` (one additive server-authority table, plus its verify script) for you to apply? | **Yes.** It is additive only; the Worker treats a missing table as "feature off" and the endpoint answers 503 |
| Q7 | Should we build server-side Google Calendar OAuth? | **No, not now.** It is a new service, a sensitive-scope verification that would also cover the Sign-In consent screen, refresh-token storage, and Google-only coverage. Revisit if device evidence shows Google-app-only owners or frequent stale fallbacks (§1.2) |
| Q8 | Build Stage C (the subscribable ICS feed) in this phase? | **Defer.** EventKit covers the owner's iPhone, Mac and iCloud. Build the feed only if you want jobs in Google Calendar on the web or in Outlook; it would default to titles only (§6) |

## 11. Build record (2026-10-03)

Built on `feat/calendar-sync` (worktree `.claude/worktrees/calendar`), Stage A (inbound) and Stage B (outbound mirror). Owner decisions Q1–Q4 and Q6 applied as recommended; Q7 (Google OAuth) and Q8 (ICS feed) not built; Q5 (`privacy.html`) left to the engineer who owns `tradeready-legal` (paragraph below). Nothing committed, deployed or applied.

**§0 re-verified** against this tree (HEAD `cdc2b29`, Phase 20 on top of Phase 27 and 25). Every reference held except line drift in `N/AppStore.swift` (`performForegroundRefresh` and `runBackgroundRefresh` moved) and one design fact: the account binding is an HMAC of the user id under a **device-local** key (`N/NativeAuthenticatedIdentity.swift`), so a tag of it differs per device. See decision 1.

### 11.1 What was built

**Worker**
- `backend-workers/lib/calendar/busyGate.js`: `validateSnapshot` (every §3.1 rule), `gateFreshness`, `calendarBusyGate` (§2.4), instant/date helpers. Zone math rides the engine's `nowInZone`; `availability.js` is unchanged.
- `backend-workers/lib/booking/offerable.js`: `offerableCandidates` / `offerableSlots`, the shared pipeline. `off` is today's computation byte for byte.
- `backend-workers/lib/calendar/busyStore.js`: fetch (404 = not deployed), upsert (`merge-duplicates` on `user_id`), delete.
- `backend-workers/lib/calendar/busyCore.js`: `put` / `status` / `disable`, 409 `source_mismatch`, `takeOver`, 503 `unavailable`, counts-only logs.
- `backend-workers/src/routes/calendar/busy.js`: owner JWT, static CORS, 20/window per user, raw-body 64 KB cap before parsing. Registered in `backend-workers/src/index.js` with the `/api/calendar/:action` 404.
- `backend-workers/lib/booking/slots.js`, `backend-workers/lib/booking/reserve.js`: one more read in each `Promise.all`, then the pipeline; stale logs `calendar_stale` with an 8-character user id prefix.

**SQL** (written, not applied)
- `supabase/migrations/20261003_calendar_busy.sql`: the §2.3 table, RLS on, no policy, client grants revoked, service-role grants; idempotent; rollback is `drop table`.
- `supabase/verify/calendar_busy.sql`: columns, RLS, zero policies, zero client privileges, service-role privileges, the cascade FK, the check constraint.
- `calendar_busy` added to `supabase/verify/account_deletion_cascade.sql` and to the apply/re-apply, grant and verify loops of `supabase/verify/local/run.sh`.

**Native domain (pure)**
- `N/Domain/NativeCalendarBusy.swift`: §4.1 busy rules, the zone-aware window, `makeSnapshot` (clip, floor/ceil, merge, 500 truncation, all-day dates from the injected device calendar), exact wire `encode`, `digest`, the validation and gate twins, `offerableSlots`, the overlay, status copy.
- `N/Domain/NativeCalendarMirror.swift`: `desiredEvents`, markers, `plan` (survivor rule, foreign and unmarked events untouched, window, 200-op cap), `ownerTag16`.
- `N/Domain/NativeAvailability.swift`: the §4.6 fix (an `extraBusy` end of exactly `"24:00"` is 1440).
- `N/Domain/NativeCalendar.swift`: `PersonalBusyBlock`, `personalBusy` on `buildCalendarDay`/`buildCalendarWeek` (default empty), `overlapsPersonalBusy` on blocks, `overlapsPersonalBusy(date:start:end:laborHours:personalBusy:)` for the editor.
- `N/Domain/NativeSchedule.swift`: `largestFreeGap(..., extraBusy:)` (default empty).
- `N/Domain/NativeTodayBriefing.swift`: `calendarChecksStaleMessage` (the Today row text).

**Native platform**
- `N/NativeEventKitBridge.swift`: the `NativeCalendarAccess` protocol and value types, plus the `#if canImport(EventKit)` adapter (iOS 17 access levels, `.writeOnly` treated as denied, expanded occurrences, iCloud → default source → Local calendar creation, one `commit()` per plan, `EKEventStoreChanged` observation, lazy `EKEventStore`).
- `N/NativeCalendarSyncTransport.swift`: the booking-admin transport pattern for `api/calendar/busy`; outcomes `ok`, `sourceMismatch`, `unavailable`, `invalid`, `offline`, `unauthorized`.
- `N/NativeCalendarSyncCoordinator.swift`: device-local state and its owner-tagged store, triggers (foreground, BG refresh, `EKEventStoreChanged` with a 5 s debounce and a 2 s own-commit quiet period, schedule save, debounced snapshot writes for the mirror), digest/heartbeat pushes, the null put on the sharing transition, push-before-enable, takeover, disable, status reads, the mirror pass, the account boundary.
- `N/NativeCalendarSyncStore.swift`: the `AppStore` API (install, `commitScheduleSettingsAwaitingCalendar`, overlay, Today text, hub subtitle).
- `N/AppStore.swift` hooks only: the lazy coordinator, the production install, `snapshot.didSet`, `sceneDidEnterBackground`, `performForegroundRefresh`, `runBackgroundRefresh`, `removeAccountScrubStores`, the account switch, `applyCompletedSignOutState`, account deletion, and the two primitives `calendarSyncOwner` / `calendarSyncCredentials`.

**UI**
- `N/NativeCalendarSyncSettingsView.swift`: Settings › Calendar sync (checks toggle with the first-enable explainer sheet, calendar list by account, status row, Use this device, remote turn-off, access help with Open Settings, the mirror toggle with Remove/Keep), plus the Today row component.
- `N/SettingsView.swift`: the hub row after Schedule and its destination. `N/TodayView.swift`: the stale row.
- `N/NativeCalendarView.swift`: hatched, labelled "Busy (personal)" blocks, untitled list rows, "Overlaps a personal event", the gap suggestion and week summary. `N/NativeScheduleEditorView.swift`: the same warning. `N/NativeScheduleSettingsView.swift`: Save awaits the push path.

**Platform and docs**: `NSCalendarsFullAccessUsageDescription` in `native/Info.plist` (exact §5 text; no write-only or legacy key); comment-only edits in `N/PrivacyInfo.xcprivacy` and the manifest test; `docs/native-phase-12-release-readiness.md` §4.4, §5 and §7 (App Review note); `scripts/parity-map.json` Calendar row; regenerated manifest and matrix columns.

**Tests**
- New: `native/CalendarSyncTests/main.swift` (`native/run-calendar-sync-tests.sh`, registered), `__tests__/calendarBusyParity.test.js`, `__tests__/calendarBusyWorkers.test.js`, `__tests__/bookingCalendarBusyWorkers.test.js`, `backend-workers/tests/calendarBusy.test.cjs`.
- Shared vectors in `native/ScheduleTests/Fixtures/scheduleVectors.json`: `calendarBusyVectors` (20), `offerableScenarios` (7), `midnightEndVectors` (1), read by Swift (`native/AvailabilityTests`) and Jest; Jest now also asserts the existing `zoneVectors` and `nowVectors`. Hand-checked, including the fold's 00:30–02:15; a tampered copy makes the Swift suite fail.
- Updated: `AvailabilityTests`, `CalendarTests`, `TodayBriefingTests`, `ScheduleBookingSettingsTests` (now async; section F), `StoreIntegrationTests` (Phase 26 section with fake access and transport), the accessibility and layout inventories, `run-availability-tests.sh`, `run-appstore-sources-common.sh`.

### 11.2 Decisions where the spec was silent

1. **Mirror owner tag from the server user id.** `ownerTag16` is the first 16 hex of SHA-256 over a prefix plus the authenticated user id, not the account binding: the binding is device-local, so tags of it would differ per device and §4.1's cross-device convergence could not hold. Still one-way; it only separates accounts.
2. **Local state is one document.** The §2.1 keys are fields of one JSON document under `calendarSync.state` in standard `UserDefaults`, tagged with a one-way hash of the binding (never the binding). Another owner reads defaults; every scrub path and the account switch remove it at once.
3. **Coverage edges.** The head's "latest local reading" uses `max(offset(W − 1 h), offset(W))` and the tail's "earliest" uses `min(offset(E), offset(E + 1 h))`, so a fold beside an edge is covered. Dates from the owner's today up to the head date (a device clock up to 10 minutes fast) are whole busy days. A tail window that would be empty (23:59) is dropped, like every empty window.
4. **`put` also answers `created`.** It is true when no row existed. A source device that had pushed before and gets `created: true` knows checks were turned off on another device: it deletes the row it just recreated, turns checks off and shows a one-time notice. The same happens when a status read says not enabled. `status` accepts a missing `sourceId`, so a device that never enabled checks can read it.
5. **Remote turn-off and takeover from any device.** A device that is not the source shows "Runs on another device", **Use this device** (asks for access, then `takeOver`) and **Turn off calendar checks** (`disable`).
6. **Access revoked while checks are on** sends one `snapshot: null`, so booking fails closed at once instead of after the 48 h TTL. Settings explains it with Open Settings, for restricted access too.
7. **Default exclusions apply to calendars seen for the first time** (tracked in `seenCalendarIDs`): birthday and subscribed calendars, including ones added later.
8. **All-day ranges** are clipped to the window's owner dates, and adjacent dates merge, so the 100-range cap cannot be reached in 62 days. It is still guarded, by pulling `windowEnd` back.
9. **One EventKit read per run.** It covers 62 days in the schedule zone (the device zone without a valid one) and feeds both the overlay and the shared snapshot. The overlay's `23:59` day ends display as midnight.
10. **Status cadence.** Foreground at most every 30 minutes, the settings page at most once a minute, and a push refreshes the cached status. A cached status ages against the clock, so the Today row appears 48 h after the last run even offline.
11. **Turning checks off offline** keeps them on and shows an alert, so busy times never stay on the server without the owner knowing.
12. **The schedule Save is async.** It awaits `commitScheduleSettingsAwaitingCalendar`, and Save stays disabled while it runs. Only a save that turns slots on while checks are on here waits for the push.
13. **Slots/reserve Worker cases live in `__tests__/bookingCalendarBusyWorkers.test.js`.** `__tests__/bookingSlotsReserve.test.js` is untouched (Phase 34 edits it) and still passes.
14. **Runner registration is minimal.** The new domain files are in `run-availability-tests.sh`, the shared AppStore list and the new runner. `NativeCalendar` and `NativeTodayBriefing` take plain values, so `run-calendar-tests.sh` and `run-today-briefing-tests.sh` needed no new sources.
15. **No analytics** (D19): the settings page sends no screen event and no `NativeAnalyticsScreen` case was added.
16. **Mirror details.** "Today" is the device calendar's date. Existing all-day events are normalized with `endDate − 1 s`. Several writable "TradeReady" calendars resolve to the smallest identifier. "Keep calendar" keeps the stored id, so turning the mirror on again reuses that calendar.
17. **The local SQL runner was run on its throwaway cluster only** (a temp-dir PostgreSQL that it creates and deletes; `PGPORT_SCRATCH=54347` so it could not collide with other engineers). No hosted or shared database was touched, and the migration is still unapplied everywhere that matters. Results are in §11.5.

### 11.3 `tradeready-legal/privacy.html` paragraph (for the legal-repo engineer; §1, after "App data")

> **Calendar busy times (optional):** if you turn on calendar checks, the app reads the calendars you choose on your device and sends us only the start and end times of busy periods in your booking window (up to about two months ahead), together with a random identifier for that app installation, so your booking page doesn't offer those times. Event titles, locations, notes and attendees never leave your device. Each update replaces the last one, and turning calendar checks off deletes them from our servers. If you turn on "Add my jobs to a TradeReady calendar", the app writes your scheduled jobs into a calendar on your device (your calendar account, such as iCloud, may sync it); our servers aren't involved.

The only change from the §5 draft is the clause about the random installation identifier, which the row stores (§2.1, §5 table).

### 11.4 Owner ship steps

1. In the Supabase SQL editor, apply `supabase/migrations/20261003_calendar_busy.sql`. Then run `supabase/verify/calendar_busy.sql` (the policy and client-grant queries must return zero rows) and `supabase/verify/account_deletion_cascade.sql`. Optionally run `sh supabase/verify/local/run.sh` on a machine with PostgreSQL first.
2. Deploy the Worker. The order relative to step 1 doesn't matter: without the table, slots and reserve treat busy times as `off` and the endpoint answers 503 (the app shows "Calendar checks aren't available yet").
3. Publish the privacy-policy paragraph (§11.3) before the native build ships.
4. Ship the native build. Then update the App Store Connect "Other User Content" label text (release-readiness §5) and add the App Review note (release-readiness §7).

Device evidence stays deferred to Phase 12 (§7).

### 11.5 Test results

The first builder's sequential run was cut off, so every result below is from a full rerun on 2026-10-03. Swift runners ran **one at a time** with `TMPDIR` set to a scratch folder. JS ran under `TZ=America/Phoenix`.

**Worker and Jest**
- `cd backend-workers && npm test`: 125/125 pass, 16 suites. `tests/calendarBusy.test.cjs` alone: 15/15.
- Root Jest, all booking oracles plus Phase 26 (`__tests__/booking*`, `__tests__/phase8Booking*`, `__tests__/calendarBusy*`, `__tests__/availabilityParity.test.ts`): 26 suites, 343/343 pass. That includes:
  - `calendarBusyParity` 42
  - `calendarBusyWorkers` 60
  - `bookingCalendarBusyWorkers` 15
  - `bookingSlotsReserve` 15 (untouched)
  - `availabilityParity` (untouched)
- The Worker entry (`src/index.js`) bundles cleanly with the local esbuild. No `wrangler` was run.

**Swift: Phase 26 runners and everything named in the brief.** All PASS, except where noted:
- `calendar-sync`, `availability`, `calendar`, `schedule`, `today-briefing`, `today-insights`, `phase10-qualification`
- `account-deletion`, `booking-administration`
- `store-integration`, including the Phase 26 section
- `schedule-booking-settings`, including section F
- `calendar-editor`
- `accessibility-audit`: 2061/2062. The one failure is the known pre-existing `raw .borderedProminent at N/RootView.swift:234`.
- `layout-metrics`: 930/933. The three failures are the known pre-existing ones:
  - `RootView keeps six tabs`
  - `cancellationAction 'Done' at N/CoachView.swift:68`
  - the `.keyboardShortcut` total off by one (59 vs 58). The new explainer's "Not now" `.cancelAction` is counted on both sides, so it doesn't change this.

**Swift: every other runner that compiles `AppStore.swift` (shared list) or reads a changed file at runtime.** All PASS:
- `performance-metrics` 178/178, `legacy-migration-retention`, `tax-settings`
- `ai-provider-key` 480/480, `analytics-transport` 226
- `app-intent-queue`, `deep-link-routing`, `export-import-ui`
- `legacy-reimport` 933, `quote-options-store` 122, `poor-network` 422/422
- `pricebook-ui`, `schedule-booking-recovery` 1477
- `phase11-qualification` 514/514, `phase9-qualification`
- `widget-owner-gating`, `rejected-changes` 183, `rollback-readiness` 310
- `support-diagnostics` 239/239, `widget-snapshot`

No compiler warning points at a Phase 26 file. None of these runners touched real EventKit (the fakes are injected), and none stalled on a privacy prompt.

**Not run here:** `run-analytics-event-tests.sh`, `run-error-redaction-tests.sh` and `run-save-rollback-tests.sh`. They hang on a macOS privacy prompt under a custom `TMPDIR`, so they are left for the owner's final gate. The ErrorRedaction edit is a comment only.

**Checks**
- `sh native/check-runner-registration.sh`: ok.
- `node scripts/parity-manifest.mjs --write`: 136 runners, 225 RN oracles. It refreshed the `store-integration` source hash; the matrix was already current.
- `sh native/run-fixture-manifest-check.sh`: current.
- `sh native/run-doc-reference-check.sh`: 2366 references, 0 missing.
- `sh supabase/verify/local/run.sh`, on a throwaway cluster (decision 17): 57/57. That covers:
  - `20261003_calendar_busy` applies and re-applies
  - `calendar_busy`: RLS on, no policy, no client privileges, the service-role privileges
  - `calendar_busy.sql` runs clean

**Release compile**
- `xcodebuild … -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`: **BUILD SUCCEEDED**.
- 4 warnings, all pre-existing, in `N/NativeChangeOrdersView.swift`.
- The built `Info.plist` has `NSCalendarsFullAccessUsageDescription` with the §5 text, and no write-only key.

**Still owed:** the `sh native/run-all-domain-tests.sh` aggregate, which includes the three prompt-bound runners, and device evidence (§7, deferred to Phase 12).

### 11.6 Review fixes

- **A loose `tradeready-job:` no longer hides busy time (parser differential).** The busy rules dropped any event, in any calendar, whose notes merely contained `tradeready-job:`, so an invite or pasted note could make a busy period bookable. Outside the mirror calendar, an event is now left out only when `NativeCalendarMirror.parseMarker` accepts its notes and the tag equals this account's `ownerTag16` (reconcile's own test). `Sample` keeps only the parsed tag, and `countsAsBusy`/`busySamples` take `mirrorOwnerTag`, which the coordinator derives from the owner's server user id. Tests are in `native/CalendarSyncTests` (free text, malformed and foreign markers stay busy; this account's marker in another calendar is skipped; the other exclusions hold) and in the `native/StoreIntegrationTests` Phase 26 section (what is pushed).

### 11.7 Review fixes: calendar ownership (2026-10-04)

Branch `fix/calendar-mirror`. Rules, in `NativeCalendarMirror` (pure, host-tested); the EventKit adapter only executes them.

- **Never adopt by title.** `findMirrorCalendar` looks up the stored identifier only. After sign-out or reinstall (no stored id) the coordinator reads every event of each calendar titled "TradeReady", "TradeReady Jobs" or "TradeReady Jobs N" and `adoptableCalendarID` accepts one only when it is writable, holds at least one event, and every event's parsed marker carries this account's `ownerTag16`. A same-title calendar of another account, of the owner, a mixed one and an empty one are all refused, and a new calendar is created. `newCalendarTitle` picks "TradeReady", or "TradeReady Jobs" (then "TradeReady Jobs 2", ...) when the title is taken.
- **Removal.** "Remove calendar" and account deletion go through `removalDecision`: the whole calendar is deleted only when every event in it carries this account's tag. Otherwise only this account's tagged events are deleted, the calendar stays, and the owner is told. Calendars that can't be read remove nothing. "Remove calendar" in settings says so.
- **Edit and delete guard.** The planner only emits operations for events with this account's tag; the adapter also refuses an update or delete of an event outside the mirror calendar or without a mirror marker.
- **Scan window.** Ownership is judged over today ± 5 years, read in 3-year slices (EventKit truncates a predicate at 4 years). A foreign event farther out than that is not seen; this is the residual.
- **Zone duplicates.** Existing events are fetched over the mirror window widened by 2 days each side (device zone vs schedule zone can differ by 26 hours), and `plan` matches them to jobs by the job id in the marker, not by window membership. An event of a job that is no longer wanted is deleted only when it starts inside [today − 30, today + 180].
- **Transient empty read.** `syncMirror` turns the mirror off with the "deleted" notice only when calendars are readable and the stored id is absent; no readable calendars, or a present but read-only calendar, leaves it on (as the inbound path does).
- **Picker.** Settings hides only this account's mirror calendar (by stored id), so a same-title calendar that is not the mirror can be unchecked.
- **BG refresh order.** The calendar step now runs after the widget/Siri action replay in `runBackgroundRefresh`.
- Tests: `native/CalendarSyncTests` (adoption, removal, planner by job id) and the `native/StoreIntegrationTests` Phase 26 section (foreign, own-events and mixed calendars; removal and account deletion with foreign events; unreadable calendars; edge-date jobs under Phoenix, New York and Auckland over repeated passes; transient empty read; picker; BG order).
