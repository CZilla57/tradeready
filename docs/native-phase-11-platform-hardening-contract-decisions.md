# Phase 11 — Platform hardening contract decisions

**Task:** 11.00 (freeze contracts and baselines) · **Date:** 2026-09-23

**Status:** Contract frozen. This is characterization only: no Swift file, test,
project file or RN file was changed. Selected contracts are marked **chosen**.
An open item is marked **blocked**, with its owner and the reason.
Revised in fix round 1 (2026-09-23): a single owner predicate (§2.5) and precision fixes.
Amended by 11.01 (2026-09-23): file placement for the extension target (§5.4, §8). No
schema, owner or write-semantics decision changed.
Amended by 11.07 (2026-09-24): the PostHog pin re-check (§7), the analytics inputs for the
app manifest (§8.3) and the implementation notes (§9.7). No gating, catalog or redaction
decision changed.
Amended by 11.09 (2026-09-24): the Sentry pin re-check (§7), a File Timestamp correction
(§8.1), the §8.3 manifest decisions, the native dSYM project slug and script (§10.2), and
the implementation notes and `reportError` call-site map (§10.4). No gating, option or
deny-table decision changed; the redactor is stricter than §10.2 in the ways §10.4 lists.

**How this was produced:**
- Sources read in full:
  - the RN widget, bridge, action, deep-link and analytics sources;
  - the RN `App.tsx` Sentry/PostHog init;
  - the RN tests that pin them;
  - the native App Group, replay, deep-link, analytics-seam, derived-state and secure-store code.
- The RN widget files `targets/widget/JobTimer.swift` and
  `targets/widget/_shared/SiriIntents.swift` carry uncommitted edits by another agent
  (they add the advisory lock to `appendPendingAction`). They were read as-is from the
  working tree and are cited that way. Line numbers refer to that working tree.
- SDK versions and their privacy manifests were read at the pinned tags from GitHub
  (`git ls-remote`, the releases API, and raw files). Nothing was downloaded into the repo.
- The snapshot fixtures in §2.4 were decode-checked in a scratchpad against a copy of
  RN's `BridgeSnapshot`; see §16. The committed decode test belongs to 11.01 (ruling P4).
- Secrets: the PostHog key, the Sentry DSN and the RevenueCat keys are cited by their
  `app.json` line, never copied.

This document is binding once committed. It overrides any prose paraphrase in the plan
(global constraints). Where native code already differs from RN on purpose, the
difference is recorded here, not reconciled.

Requirement IDs: **W1–W4, A1–A3, L1, L2, P1–P4, R1–R3, H1–H4, M1** (all, for
characterization).

---

## 1. Contract decision table

| ID | Topic | Decision | Status | Owner |
|---|---|---|---|---|
| C1 | Snapshot schema | RN `BridgeSnapshot` v1 fields and optionality, decoded both ways (§2) | chosen | 11.01 |
| C2 | Native snapshot writer shape | Explicit `null`s, `address` always a string, `outstandingTotal` in dollars rounded to 2 dp from the 10.01 value, `.sortedKeys`, fractional ISO `updatedAt`, plus the `ownerTag` field (§2.3) | chosen | 11.01 |
| C3 | Stale-snapshot window | **86,400 s (24 h)**. The snapshot is stale iff `now − updatedAt > 86400`, or its age is negative or unparseable (§3.3) | chosen | 11.02, 11.05 |
| C4 | Mirror write triggers | Every committed canonical write that changes jobs, time sessions, invoices or payments; foreground/launch after replay; the 10.09 seam (§3.1) | chosen | 11.01 |
| C5 | Seam observer input | Add a `(canonical, output, expectedOwnerBinding)` register overload. The current observer receives only `NativeBusinessSnapshot` (§3.2) | chosen; Own-list addition for 11.01 | 11.01 |
| C6 | Action queue | Four types, fixed JSON shapes, `flock` protocol, 512 cap, duplicate-id handling, never overwrite a malformed queue (§4) | chosen | 11.04 |
| C7 | Owner stamping | `ownerTag` (hash of the §2.5 binding) goes on the snapshot, on each queued action, on `activeTrip` and on the `pendingOpenUrl` stash. Extensions refuse to write when no snapshot is present. Replay drops actions whose owner is missing or mismatched (§4.5) | chosen | 11.01, 11.04, 11.05 |
| C8 | Malformed or duplicate queue wedge | Native replay retries forever on `malformedQueue`/`duplicateActionID` (§4.6) | **resolved** by 11.05: existing native behavior, recorded (§4.6). **Amended by Phase 12 12.00b.2-C (2026-09-25; charter L130, L131):** only the bad entries of a list are set aside and the rest apply; a queue over 512 entries is claimed 512 at a time; only bytes that are not a list are set aside whole; an unusable claim file is set aside so replay continues (§4.3, §4.6) | 11.05, 12.00b.2-C |
| C9 | Intents | Ten intents, a single 17.0 floor, target membership per ruling P3 (§5) | chosen | 11.04 (types), 11.01 (membership) |
| C10 | Deep links | Gate order: parse → authenticate → exact owner → record exists and is not archived. `onmyway` also refuses a done status (§6) | chosen; implemented by 11.06 with the native differences in §6.3 | 11.06 |
| C11 | Notification `est_` archived dead tap (P8) | An archived `estimate_sent` job's delivered `est_` notification **opens** its editable follow-up review; only a missing job, an answered estimate or a non-exact/signed-out workspace fail closed (§6.3) | **resolved** by 11.06 (2026-09-24) | 11.06 |
| C12 | SDKs | Sentry Cocoa **9.29.0** and PostHog iOS **3.81.0**, via SPM `exactVersion`, behind Foundation-only adapters (§7) | chosen; PostHog pin re-checked and kept by 11.07, Sentry pin re-checked and kept by 11.09 (§7) | 11.07, 11.09 |
| C13 | Privacy manifests | App and extension manifests: required-reason APIs and collected-data types (§8) | chosen; extension manifest by 11.01, app manifest by 11.09 (§8.1 corrected, §8.3 decided) | 11.01, 11.09 |
| C14 | Analytics gating | Release build **and** a configured, non-`PLACEHOLDER` key. RN gated PostHog on the key only (§9.2) | chosen (recorded deviation) | 11.07 |
| C15 | Event catalog | 52 events from 70 RN `track(` call sites; the fixture in §9.5 is exact. 11.08 asserts the event set, never a site count | chosen | 11.08 |
| C16 | Seam property types | Widen `[String: String]` to JSON scalars and string arrays (§9.6) | chosen; implemented by 11.07 (§9.7) | 11.07 (in place, ruling P6) |
| C17 | `$screen` names | Use RN route names; 11.08 produces the exact route-to-screen map (§9.3) | chosen policy; map delivered by 11.08 | 11.08 |
| C18 | Redaction | Allow/deny table (§10.1); Sentry user is `{id}` only; extras are allow-listed; `rawError` is reduced | chosen; crash side implemented by 11.09 (§10.4) | 11.07, 11.09, 11.15 |
| C19 | AI key entry | Keychain-only through `NativeKeychainSecureSettingsStore`, same keys as RN (§11) | chosen; implemented by 11.15 with the native differences in §11.1 | 11.15 |
| C20 | Accessibility baseline | Per-file inventory and release-blocking findings (§12) | chosen baseline; 11.10a closed all four release-blocking candidates (§12.1). 11.10b re-audited after 11.11 and 11.12 (§12.3): A13, A15–A18 and A24–A29 fixed, A22 accepted. A29 (success, warning and status colors as text) was fixed with native text tokens after the controller ruling (2026-09-24). Fix round 1 fixed the in-row destructive buttons (I1, in A28) and recorded A30 (PDF stamps; fixed in 11.13 as a native difference, §12.1) and A31 (system-drawn dialogs, accepted). Zero release-blocking findings remain, so **H1 is closed** | 11.10a/11.10b |
| C21 | Device matrix | Phase 11 owns host, build and simulator rows. Phase 12 owns every physical row (§13) | chosen | 11.13, 11.14 / Phase 12 |
| C22 | Owner predicate | ONE predicate for the snapshot writer, `ownerTag`, the replay gate and the deep-link/pending-URL gate: `AppStore.derivedStatePublishBinding` (§2.5). The existing migrated-only replay/consume gates are gaps | chosen; replay gap closed by 11.05 (plan §7), deep-link and pending-URL-consumer gaps **closed by 11.06** (§2.5, §6.2, §6.3) | 11.01, 11.05, 11.06 |

---

## 2. Snapshot schema (W1)

### 2.1 Keys and container

| Item | Value | Source |
|---|---|---|
| App Group id | `group.com.gettradereadyapp.tradeready` | `targets/widget/Widgets.swift:10`, `N/NativeAppGroupInbox.swift:16` |
| Snapshot key | `widgetSnapshot` (a JSON **string** stored in UserDefaults) | `targets/widget/Widgets.swift:11`, `utils/widgetBridge.ts` `WIDGET_SNAPSHOT_KEY` |
| Action queue key | `widgetActions` (a JSON array string) | `utils/widgetBridge.ts` `WIDGET_ACTIONS_KEY`, `targets/widget/_shared/SiriIntents.swift:51` |
| Trip session key | `activeTrip` (a JSON object string, private to Siri) | `targets/widget/_shared/SiriIntents.swift:52` |
| Cold-launch handoff key | `pendingOpenUrl` (RN `{url, at}`; native adds `ownerTag`, §6.2) | `targets/widget/_shared/SiriIntents.swift:53`, `utils/widgetBridge.ts` `PENDING_OPEN_URL_KEY` |
| Advisory lock | File `.tradeready-widget-actions.lock` in the App Group container, `flock(LOCK_EX)` | `targets/widget/JobTimer.swift:25-41` (working tree), `N/NativeWidgetActionReplay.swift` claim transport |

The native scrubber `NativeAppGroupAccountScrubber` (`N/NativeAppGroupInbox.swift:42-79`)
already covers all four keys under the lock. It calls `removePersistentDomain` and
verifies the result.

### 2.2 `BridgeSnapshot` v1 (RN reference: `targets/widget/Widgets.swift:13-35`)

| Field | Type | Optional | Notes |
|---|---|---|---|
| `version` | Int | no | Always `1` |
| `updatedAt` | String (ISO 8601) | no | RN writes `new Date(now).toISOString()` (fractional, `Z`). The RN widget ignores it. Native uses it for staleness (§3.3) |
| `nextJob` | object | yes (`null`) | See below |
| `nextJob.id` | String | no | Exact job id. The deep link uses it verbatim |
| `nextJob.customerName` | String | no | |
| `nextJob.title` | String | no | |
| `nextJob.scheduledDate` | String `yyyy-MM-dd` | no | Local-frame date string. Never parse it as UTC (FA-039) |
| `nextJob.scheduledStartTime` | String `HH:mm` | yes (`null`) | |
| `nextJob.address` | String | **no** | Must be a string (`""` when empty). `null` fails RN's decoder (fixture F6) |
| `timer` | object | yes (`null`) | |
| `timer.jobId` / `jobTitle` / `customerName` / `startedAt` | String | no | `startedAt` is the ISO clock-in instant |
| `outstandingTotal` | Number (dollars) | yes | RN always writes it, rounded to cents. Decoders must tolerate it being absent (F5) |

**Decode rules (both directions, chosen):**
- Plain `JSONDecoder` with no custom key strategy.
- Unknown keys are ignored. RN already ignores them (`targets/widget/Widgets.swift:37-44`).
- Native decoding must accept every RN-written fixture unchanged (F1–F3, F5).
- RN's decoder must accept every native-written snapshot (F4). This is what
  "byte-compatible" means here: decode equivalence, not identical bytes or key order.
- Local-frame parsing of `scheduledDate` + `scheduledStartTime`:
  - locale `en_US_POSIX`, `TimeZone.current`;
  - format `yyyy-MM-dd HH:mm`, else `yyyy-MM-dd` (`targets/widget/Widgets.swift:58-70`).

**Minimal-projection rule (chosen):**
- The snapshot contains exactly the fields above, plus `ownerTag` (§2.3).
- Never include a collection, a customer list, contact details other than the displayed
  name and address, notes, amounts other than `outstandingTotal`, or any secure value.

**Projection semantics (RN `utils/widgetBridge.ts:99-160`, chosen as the native spec):**
- `nextJob` is the earliest candidate job:
  - candidates are not archived, have a `scheduledDate`, have `scheduledDate >=` local
    today (string compare), and are not in `DONE_STATUSES` = {complete, invoiced, paid, declined};
  - sort by date, then by `scheduledStartTime` with no-time jobs last;
  - today's job stays "next" after its start time passes.
- `timer` is the open session with the latest `start` across all jobs. RN does not
  filter archived jobs here; native keeps that parity so a running clock is never hidden.
- `outstandingTotal` = `FinancialDecimal.cents(NativeBusinessSnapshot.outstandingTotal)`.
  Despite its name, `cents` returns **dollars rounded to 2 decimal places** (`.plain`
  rounding; `N/Domain/FinancialDomain.swift:12-17`), which matches RN's `roundToCents`.
  Source value: `N/Domain/NativeBusinessSnapshot.swift:110-117`. Encode it as a JSON
  number of dollars (e.g. `160`, `1234.56`). Never re-derive the sum.

### 2.3 Native writer additions (chosen)

- **`ownerTag`**: lowercase hex SHA-256 of `"tradeready.widget.owner.v1:" + O`, where `O`
  is the 64-hex owner binding defined in §2.5 (`AppStore.derivedStatePublishBinding`).
  For the seam writer, `O` is the publish's `expectedOwnerBinding` (§3.2).
  - It is hashed again so the raw binding never enters the App Group.
  - RN decoders ignore it.
  - The native widget decoder treats it as optional. A missing tag means "no owner":
    intents refuse to write (§4.5).
- Encoding:
  - `JSONEncoder` with `.sortedKeys`;
  - `nextJob`, `timer` and `scheduledStartTime` written as explicit `null`, never omitted;
  - `updatedAt` via `ISO8601DateFormatter` with `.withInternetDateTime` and `.withFractionalSeconds`;
  - `version: 1`.

### 2.4 Fixtures (verbatim; ruling P4)

**F1 — empty.** From `__tests__/widgetBridge.test.js:196-203`, with
`NOW = new Date(2026,7,3,12,0,0)` in `TZ=America/Phoenix`:

```json
{"version":1,"updatedAt":"2026-08-03T19:00:00.000Z","nextJob":null,"timer":null,"outstandingTotal":0}
```

**F2 — full.** From `__tests__/widgetBridge.test.js` next-job j9 (lines 126-133),
timer j2 (lines 161-166) and total 160 (lines 180-193):

```json
{"version":1,"updatedAt":"2026-08-03T19:00:00.000Z","nextJob":{"id":"j9","customerName":"Alice Johnson","title":"Fence repair","scheduledDate":"2026-08-04","scheduledStartTime":"10:30","address":"12 Oak St"},"timer":{"jobId":"j2","jobTitle":"Deck build","customerName":"Bob Smith","startedAt":"2026-08-03T10:00:00.000Z"},"outstandingTotal":160}
```

**F3 — no start time, empty address, fractional total, no timer.**

```json
{"version":1,"updatedAt":"2026-08-03T19:00:00.000Z","nextJob":{"id":"j5","customerName":"Dana Lee","title":"Gutter clean","scheduledDate":"2026-08-05","scheduledStartTime":null,"address":""},"timer":null,"outstandingTotal":1234.56}
```

**F4 — native writer shape.** Sorted keys, with `ownerTag` and the RN widget sample
values from `targets/widget/Widgets.swift:49-56`. The tag here is illustrative:

```json
{"nextJob":{"address":"1420 Maple Ave","customerName":"Alex Morgan","id":"sample","scheduledDate":"2026-01-01","scheduledStartTime":"09:00","title":"Water heater replacement"},"outstandingTotal":0,"ownerTag":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","timer":null,"updatedAt":"2026-01-01T08:00:00.000Z","version":1}
```

**F5 — older writer or future field.** `outstandingTotal` is absent and there is an
unknown key:

```json
{"version":1,"updatedAt":"2026-08-03T19:00:00.000Z","nextJob":null,"timer":null,"futureField":{"x":1}}
```

**F6 — must be rejected** (`address: null`). The native writer must never produce it:

```json
{"version":1,"updatedAt":"2026-08-03T19:00:00.000Z","nextJob":{"id":"j5","customerName":"Dana Lee","title":"Gutter clean","scheduledDate":"2026-08-05","scheduledStartTime":null,"address":null},"timer":null,"outstandingTotal":0}
```

Expected results against RN `BridgeSnapshot`: F1–F5 decode and F6 is rejected
(scratchpad result in §16). 11.01's test must also prove the native type decodes F1–F5,
rejects or explicitly degrades F6, and encodes a projection RN decodes.

### 2.5 Owner predicate (chosen; one predicate for all four paths)

**Predicate:** `O = AppStore.derivedStatePublishBinding` (`N/AppStore.swift:5600-5611`).
It returns `verifiedAccountBinding` only when both of these hold:
- the gate is one of `.signedIn`, `.subscriptionLoading`, `.paywall`, `.startingPoint`
  or `.onboarding`;
- the workspace is exact: `isMigratedLocalOwnerVerified ||
  hasCompletedPersistedWorkspace(binding:)`.

It is the same predicate the 10.09 publisher already uses for its owner re-check
(`ownerBinding:` at `N/AppStore.swift:5581`). It is equivalent to
`hasExactSignedInWorkspace` (`N/AppStore.swift:4920`) plus `verifiedAccountBinding`,
except that it also rejects the `.accountMismatch`/`.unavailable` gates.

| Path | Rule | Owner |
|---|---|---|
| Snapshot writer | Write only when `O != nil`. The seam observer uses the publish's `expectedOwnerBinding`, which the publisher re-checks against `O` | 11.01 |
| `ownerTag` | `sha256hex("tradeready.widget.owner.v1:" + O)` (§2.3) | 11.01 (snapshot), 11.04 (actions, `activeTrip`, stash) |
| Replay gate | Replay only when `O != nil` **and** the gate is `.signedIn`. The coordinator receives `O` as its verified binding, and an action's `ownerTag` must equal `hash(O)` (§4.5) | 11.05 |
| Deep-link and pending-URL gate | Route only when `O != nil` **and** the gate is `.signedIn`. A stash's `ownerTag` must equal `hash(O)` (§6.2) | 11.06 |

Replay and routing also require `.signedIn` because they mutate data or navigate. The
writer may run in the post-sign-in gates because the publisher does.

**Not used:** `migratedAccountBinding` and `isMigratedLocalOwnerVerified` on their own.
Both are set only when an RN legacy auxiliary artifact was staged
(`N/NativeAuthenticatedIdentity.swift:544-553`, `:587-588`). With no current users,
every future account is native-only, so a gate on them never opens.

**Gaps in existing code (named, with owners):**
- **11.05:** `replayVerifiedWidgetActionsIfPossible` (`N/AppStore.swift:5155-5160`)
  requires `isMigratedLocalOwnerVerified` and `migratedAccountBinding`, so widget and
  Siri actions would never replay for a native-only account. Switch it to `O`. The
  claim files are keyed by binding (`claim-<binding>-<digest>.json`); 11.05 decides what
  happens to an in-flight claim keyed by the old binding (no current users, so it may
  discard).
- **11.06:** `consumeVerifiedPendingOpenURLIfNeeded` (`N/AppStore.swift:5190-5194`)
  requires `isMigratedLocalOwnerVerified`, so the cold stash would never be consumed.
  It also runs only once per session (`didConsumeVerifiedPendingOpenURL`), so a later
  warm stash is ignored. Switch it to `O` and to the §6.2 lock/tag rules, and consume on
  every activation.
  **Closed by 11.06 (2026-09-24):** the function and its once-per-session flag are gone.
  `AppStore.consumePendingOpenURLStash` runs at launch, on every activation and on each
  `.signedIn` arrival; routing requires `O` and `.signedIn`; the stash is read and
  removed under `WidgetAppGroupLock` and its tag must equal `hash(O)` (§6.3).

---

## 3. Snapshot write semantics (W1, W4)

### 3.1 When the mirror is written (chosen)

RN mirror triggers, for reference:
- `utils/storage/collections.ts:33` (`saveInvoices`) and `:54` (`saveJobs`);
- `context/AuthContext.tsx:108` (session start, after `replayWidgetActions`) and `:129`
  (foreground, after the sync chain);
- `utils/backgroundRefresh.ts:106`;
- `utils/storage/lifecycle.ts:141` clears the snapshot.

RN writes best-effort and reloads timelines in the bridge module:
- `modules/widget-bridge/ios/WidgetBridgeModule.swift`: `setSharedItem` reloads;
  `clearShared` removes the persistent domain and reloads.

Native writes the mirror:
1. After every committed canonical write that changes jobs, time sessions, invoices or
   payments. Invoices are included because `outstandingTotal` depends on them; RN
   mirrors on `saveInvoices` too.
2. On launch and foreground, **after** widget-action replay. This way a just-applied
   `timer_start` is reflected, and a stale snapshot is refreshed.
3. From an observer registered on the 10.09 post-sync-commit seam
   (`N/NativeDerivedStatePublisher.swift`). This covers remote pulls and background refresh.

Write protocol:
- Acquire the advisory lock.
- Re-check the owner gate, write `widgetSnapshot`, release the lock.
- Then call `WidgetCenter.shared.reloadAllTimelines()`.
- **Amended by Phase 12 12.00b.2-B (2026-09-25).** The mirror runs on the main actor,
  so its lock wait is bounded (§4.2 amendment). A busy write leaves the stored snapshot
  as it was and does not reload. `AppStore` marks the mirror dirty, logs one
  payload-free diagnostic (`widget-lock/busy`, context `widgetLock`/`mirror`, and a
  capped count), and schedules a retry after 0.5 s, then 2 s, then 8 s while it stays
  busy. Every later trigger retries too. A retry projects the live snapshot through the
  owner gate, so it never writes for an owner who is no longer current.

Gate: write only when the §2.5 owner predicate `O` is non-nil, re-checked inside the
lock. For seam writes, `O` must also equal the publish's `expectedOwnerBinding`.
A gated-off write is a no-op, not a clear. Wiping is the scrubber's job.

Wipe authority: `NativeAppGroupAccountScrubber` stays the only wipe path.
- `signOut(revokeRemote:)` (`N/AppStore.swift:4122-4154`) and `deleteAccount`
  (`N/AppStore.swift:4156-4230`) already scrub and then call `reloadAllTimelines()`
  (lines 4152 and 4213).
- The writer must not re-populate the suite after a scrub. The lock plus the owner
  re-check inside the lock guarantee this.

### 3.2 Seam observer gap (chosen fix; Own-list addition for 11.01)

`AppStore.registerDerivedStateObserver` (`N/AppStore.swift:5653`) delivers only
`NativeBusinessSnapshot`. The widget projection also needs jobs and time sessions from
the canonical snapshot. `NativeDerivedStatePublisher` explicitly forbids reading
"stale in-memory collections" from an observer, so reading `AppStore.snapshot` inside
the callback is not allowed.

**Chosen:** 11.01 adds an additive overload to both `N/NativeDerivedStatePublisher.swift`
and `AppStore` that registers
`(canonical: Input, output: Output, expectedOwnerBinding: String) throws -> Void`. The
publisher already holds all three values in `publish(canonical:expectedOwnerBinding:)`
(line 134), and it re-checks that binding against `O` around every await. The writer
computes `ownerTag` from the delivered `expectedOwnerBinding`, so the tag provably
matches the publish's owner. No separate binding accessor is needed; the binding stays
private. Existing observers are unchanged.

Non-seam writes (triggers 1–2 in §3.1) run inside `AppStore`, which reads `O`
directly.

**Amended by 11.01 fix round 1 (2026-09-23, controller ruling):** the seam observer
projects the **newest** canonical for the delivered owner.
- The problem: every AppStore publish site captures `canonical` (the live snapshot) before
  the publisher awaits `notifySynchronize`. A local write during that suspension (for
  example a clock-in) is mirrored at once by trigger 1. The owner and generation guards
  catch newer publishes, not newer local writes, so writing the delivered canonical
  afterwards would roll the mirror back, and no later trigger would correct it.
- `AppStore` keeps a canonical-write revision, bumped in `snapshot.didSet`. Every AppStore
  publish goes through `AppStore.publishDerivedState(expectedOwnerBinding:)`, which records
  the revision it captured.
- On delivery:
  - if the revision has moved on, the observer projects the **live** snapshot, tagged
    for `expectedOwnerBinding`. The in-lock owner re-check still requires that binding
    to equal `O`;
  - otherwise it projects the delivered canonical and its business snapshot.
- An older canonical is never written over a newer one. This is the one sanctioned read
  of the live snapshot from inside the callback: it only ever picks newer data for the
  same verified owner.
- Seam writes (and the §3.1 trigger-2 foreground and background writes) are
  **non-forced**. The writer skips a write when the stored content is unchanged and less
  than one hour old, so a sync pass writes and reloads at most once. Any mirror an hour
  old or older is still rewritten, so trigger 2 still refreshes a stale snapshot (§3.3).
  Only the launch-time install write is forced.

### 3.3 Stale-snapshot window (chosen: 86,400 seconds)

`docs/widget-plan.md` defines no stale window, and the RN widget never reads `updatedAt`.
RN's only day-scale cutoff is `siriStaleActiveTripInterval = 24 * 60 * 60`
(`targets/widget/_shared/SiriIntents.swift:291`, compared with `>` at line 297). Native
reuses that value so there is a single day boundary across the extension.

- `stale(now, updatedAt) = age > 86_400 || age < 0 || updatedAt is unparseable`,
  where `age = now − parse(updatedAt)`.
- Exactly 86,400 s is **fresh**.
- Parse with fractional seconds first, then plain (the same two-step as
  `siriParseISODate`).
- Separately from staleness, a `nextJob` whose `scheduledDate` < local today is never
  presented as "next". The widget shows the no-upcoming state for that entry.

Behavior when stale (chosen):

| Surface | Stale behavior |
|---|---|
| Next Job widget (11.02) | Explicit stale state ("Open TradeReady to refresh"). No customer name or address, and no job deep link: the whole card opens the app root |
| Job Timer widget (11.03) | A running timer stays visible and Stop stays enabled; replay clamps and ignores a stop with no open session. The idle Start button is suppressed and the status reads "Open app to sync" |
| NextJob, ClockIn, OnMyWay, Outstanding intents (11.04) | Refuse with the dialog "Open TradeReady to refresh your schedule." No action is written and no data is spoken |
| ClockOut, StartTrip, StopTrip, LogExpense | Not refused when stale. StartTrip, StopTrip and LogExpense read only `ownerTag` from the snapshot. ClockOut also reads `snapshot.timer`, for the on-the-clock check and the optional `jobId` (`targets/widget/_shared/SiriIntents.swift:643-655`), inside the append's lock hold (§4.5). With a stale timer, the worst case is a `timer_stop` that replay ignores because that session is already closed |
| Timeline | Add an entry at `updatedAt + 86_400` (or the next local midnight, whichever is first) so the stale state appears without an app reload |

11.02 (UI) and 11.05 (fixtures) both test the same boundary: 86,399 s is fresh,
86,400 s is fresh, 86,401 s is stale, a negative age is stale, and garbage is stale.

---

## 4. Action-queue contract (A3)

### 4.1 Types and JSON shapes

`PendingActionType = timer_start | timer_stop | trip_log | expense_log`
(`utils/widgetActions.ts:37-52`).

| Type | Required | Optional | Writer |
|---|---|---|---|
| `timer_start` | `id`, `type`, `at`, `jobId` | `ownerTag` (native, §4.5) | Start Timer, Clock In |
| `timer_stop` | `id`, `type`, `at` | `jobId` (only when non-empty), `ownerTag` | Stop Timer, Clock Out |
| `trip_log` | `id`, `type`, `at` (= stopAt), `date` (local `yyyy-MM-dd` of `startedAt`), `odometerStart`, `odometerEnd` | `ownerTag` | Stop Trip |
| `expense_log` | `id`, `type`, `at`, `date`, `amount` (finite, > 0, ≤ 1,000,000), `category` | `description`, `ownerTag` | Log Expense |

Field rules:
- `id` is a UUID string: at most 128 UTF-8 bytes, no control characters
  (`N/NativeWidgetActionReplay.swift` `maximumIdentifierLength`).
- `at` is ISO 8601 with or without fractional seconds.
- `date` is strict `yyyy-MM-dd`.
- Odometers are finite and ≥ 0.
- `category` is one of the eight expense ids (§5.3). The replayer maps unknown values to
  `other`, matching RN's `expenseFromAction`.
- An empty `description` becomes "Logged via Siri".

### 4.2 Lock protocol (chosen, matches the working-tree RN edits)

1. `open(<container>/.tradeready-widget-actions.lock, O_CREAT|O_RDWR, 0600)`, then
   `flock(LOCK_EX)`.
2. Read, validate, append and write while holding the lock. Verify the write when the
   caller needs certainty (Siri).
3. Unlock and close. Reload timelines outside the lock.

If the container is unavailable or the lock fails, the intent reports failure. It never
writes without the lock. The native claim transport already takes the same lock before
it claims a prefix.

- **Amended by Phase 12 12.00b.2-B (2026-09-25): the acquire is bounded (charter L74,
  L96).** Step 1 no longer blocks in `flock(LOCK_EX)`. `WidgetAppGroupLock` tries
  `LOCK_EX | LOCK_NB`, backs off 1 ms doubling to a 16 ms cap, makes a last attempt at
  the deadline, then throws `busy` without running the critical section. The budget is
  100 ms on the main thread (iOS counts 250 ms as a hang) and 2 s on any other thread.
  There is no blocking variant. The lock file, the scrub's lock order and the scrub's
  semantics are unchanged.
  - Main-thread fast-fail window (review fix, 2026-09-25). After a main-thread acquire
    ends `busy`, main-thread acquires for the next 1 s make one `LOCK_NB` attempt, so
    one synchronous turn (for example activation: stash consume, boundary-step scrub
    retry, replay pass) waits for a stuck holder at most once. A fast-fail `busy` does
    not extend the window and a success does not close it. Off-main acquires never use
    it.
  - Each main-thread busy site logs one fixed, payload-free line:
    `TradeReadyWidgetLock stage=busy site=mirror|intent|stash|scrub|replay`. The mirror
    also reports `widget-lock/busy` (§3.1). The claim transport's line (`site=replay`,
    from its `withLock` for claim, acknowledge and both quarantines) was added by
    12.00b.2-C (2026-09-25).
  - A busy intent (`WidgetIntentFailure.busy`) writes nothing and reports failure with
    its existing failure dialog: "TradeReady couldn't save that" for the shared writer
    refusal, the trip intents' own failure lines, and "I couldn't open that. Open
    TradeReady and try again." for On My Way. The widget buttons do not reload.
  - A busy mirror write (`NativeWidgetMirrorOutcome.busy`) writes nothing; §3.1 keeps it
    dirty and retries.
  - A busy claim, acknowledge or quarantine is the transport's `lockFailed`: the queue
    stays, and the next activation retries. A busy stash consumer takes nothing and
    leaves the stash for its 300 s window. A busy account scrub is the scrubber's
    `lockFailed`: the widget step stays pending, the mirror and replay stay gated, and
    sign-out throws `localScrubFailed` until a retry succeeds.

### 4.3 Writer rules (chosen; stricter than RN because the native planner rejects whole batches)

The native planner (`N/NativeWidgetActionReplay.swift`) throws for the whole batch on
`tooManyActions` (> 512), `duplicateActionID`, `malformedQueue`, `malformedAction` and
`invalidAction`. A single bad append would wedge every later action (§4.6). So writers
must, inside the lock:

- **Cap:** refuse to append when the queue already holds 512 entries. Return failure;
  the Siri dialog is "TradeReady has too many pending actions — open the app to sync."
  RN had no cap (`targets/widget/JobTimer.swift:56-77`).
- **Duplicate ids:** if an entry with the same `id` exists and is exactly equal (compare
  with sortedKeys), treat the append as success and do nothing. If it differs, fail.
  This matches `siriAppendPendingActionLocked`
  (`targets/widget/_shared/SiriIntents.swift:178-204`).
- **Malformed existing value:** if `widgetActions` exists but is not a JSON array of
  objects, **refuse** and never overwrite it. RN `JobTimer.swift` treated it as empty,
  which silently discards data.
- **Validate before append:** the new action must pass the same field rules the planner
  enforces (§4.1).
- Never write canonical data from an extension.

**Amended by Phase 12 12.00b.2-C (2026-09-25; charter L130).** The planner no longer
rejects whole batches. `prepare` throws only for bytes that are not a JSON list
(`malformedQueue`), an invalid binding, or more than 512 entries (`tooManyActions`,
which the transport never passes: it claims a 512-entry prefix, §4.6). A bad owned
entry (`malformedAction`, `invalidAction`, or a different entry reusing an accepted id,
`duplicateActionID`) is listed in the batch's `rejected` entries and set aside alone;
every other entry applies. An entry that exactly repeats an accepted one (same
sorted-key digest) is skipped: it is the idempotent re-append this section allows.
The writer rules above are unchanged and still required: they keep bad entries out of
the queue, so nothing needs to be set aside, and the cap still bounds the queue.

### 4.4 `activeTrip` private session

Payload is `{id?, startedAt, odometerStart, stopAt?, odometerEnd?, ownerTag}`.

- **Start Trip:**
  - an existing non-stale trip → "already running";
  - a stale trip (age > 86,400 s, or an unparseable start) → replaced, with the dialog
    "Your previous trip was never finished — starting a new one." It is never logged;
  - `odometerStart` must be finite and ≥ 0.
- **Stop Trip** (`targets/widget/_shared/SiriIntents.swift:340-376`):
  - under the lock, persist a stable `id`, `stopAt` and `odometerEnd` into `activeTrip`
    first;
  - append `trip_log`, then remove `activeTrip` and verify the removal;
  - a retry after a crash reuses the same id, so the duplicate-id rule makes it idempotent;
  - miles spoken = `max(0, end − start)`.
- Native addition: discard (never log) an `activeTrip` whose `ownerTag` differs from the
  current snapshot's `ownerTag` (§4.5).

### 4.5 Owner stamping (chosen, new)

**Threat:** a sign-out scrub can run between an intent's snapshot read and its queue
append. The action then survives into the next account, where an `expense_log` or
`trip_log` would be applied to the wrong owner.

**Contract:**
- **Extension writers (11.04):** every snapshot read used to build an action happens
  **in the same lock hold as the append**. That covers:
  - `ownerTag`;
  - `nextJob.id` (ClockIn, OnMyWay);
  - `timer` and `timer.jobId` (ClockOut's on-the-clock check and its `jobId`);
  - the queue's last pending timer type (the "on the clock" rule).
  Reading before the lock and appending after it is forbidden. It would reopen the
  ClockIn/ClockOut race and the scrub race.
- **No snapshot or no tag → refuse.** Write nothing and speak no data. The Siri dialog
  is **"Open TradeReady and sign in first."** This also applies to the read-only
  NextJob and Outstanding intents. The widget timer buttons write nothing and the
  widget shows its empty state.
- Stamp the tag on the action, on `activeTrip` and on the `pendingOpenUrl` stash (§6.2).
- **Snapshot writer (11.01):** writes `ownerTag` under the lock.
- **Replayer (11.05):** an action whose `ownerTag` is missing or differs from
  `hash(O)` (§2.5) is **acknowledged and dropped**, never applied. It is counted in
  a bounded diagnostic with no payload.
  - This retires replay of untagged RN-written actions. That is acceptable because there
    are no current users (see memory "No current app users"; plan "Upgrade identity").
  - The owner check runs **before** type dispatch. An untagged or mismatched action of
    an unknown type is dropped like any other. Only tagged, owner-matched unknown types
    are retained (§4.6).
  - 11.05 updates `N/NativeWidgetActionReplay.swift` and its fixtures accordingly.

### 4.6 Replay (existing native behavior, recorded)

Order: claim → prepare → apply → save → acknowledge. Sources:
`NativeWidgetActionReplayCoordinator`, and `N/AppStore.swift:5155-5188`.

- The claim is a write-ahead file in Application Support `WidgetActionClaims`:
  `claim-<binding>-<digest>.json`, protected with
  `completeFileProtectionUntilFirstUserAuthentication`.
- Only the claimed prefix is removed.
- At most 8 batches of at most 512 actions per activation.
- Unknown types are retained ("Kept N newer widget action(s)…"). Under §4.5 this
  applies only to tagged, owner-matched actions; an untagged or mismatched unknown-type
  action is dropped.
- Start/stop markers `__nativeWidgetStartActionID` / `__nativeWidgetStopActionID` make
  replay idempotent. Done statuses are skipped. `scheduled` becomes `in_progress` on
  start. A stop is clamped to its start. Trips and expenses use deterministic ids.
- **Native difference (11.05, recorded):** a `timer_start` whose job is **archived**
  (non-empty `archivedAt`) is ignored and acknowledged, like a missing or done job.
  RN's `utils/widgetActions.ts` has no archived check. The replayer re-resolves the
  exact job id in the current owner's data and fails closed, matching the projection's
  own rule that archived work is never offered (§3.3). A `timer_stop` is not affected:
  it only closes an open session on the exact id.
- **Now matches RN (11.13 fix round 1, I2):** an empty or whitespace-only queue value
  is an empty batch, as RN `parsePendingActions` returns `[]` for `""`. The planner
  used to throw `malformedQueue` for it, and the coordinator quarantined the key. Now
  the coordinator commits a no-op (nothing saved, nothing quarantined) and clears the
  empty key. RN leaves an empty key in place, but the difference has no effect: an
  absent key and an empty key both mean nothing is pending. Malformed JSON and
  non-array values still quarantine (C8); RN reads them as `[]`, and that stays a
  recorded difference. The App Intent writer still refuses to append to an existing
  `""` (§4.3). The next replay clears that key, so the writer is unblocked. Evidence:
  Q2 in `native/Phase11QualificationTests/main.swift`.
- RN's equivalent is `utils/widgetActions.ts`:
  - RN clears the queue before applying;
  - `t_siri_<id>` trips, purpose "Business trip (Siri)";
  - `e_siri_<id>` expenses;
  - replay ends with a refresh.
- Triggers:
  - after the starting point (`N/AppStore.swift:4115-4116`);
  - identity activation (`:4641-4642`), including foreground via
    `activateMigratedAuthenticatedIdentity`;
  - subscription gate advance (`:4848-4849`);
  - background refresh (`:6063`).

**Blocked (C8, owner 11.05):** on any thrown error the coordinator only reloads and sets
"Widget actions are still safely queued and will be retried." (`N/AppStore.swift:5186`).
A malformed queue or a duplicate id therefore fails forever and blocks every later
action. 11.05 must choose and test a quarantine policy. Suggested shape: move the
offending raw queue into an owner-scoped quarantine file under the lock, surface a
bounded message, and continue. The writer rules in §4.3 make this state unreachable
from native writers, but it stays reachable from legacy or foreign data.

**Resolved (11.05, 2026-09-24):** an unpreparable queue is re-read and re-prepared under
the lock, then its bytes (digest and size only above 1 MiB) are written to an
owner-scoped `quarantine-<binding>-<digest>.json` next to the claims (at most 4 per
owner) before the shared queue is cleared. The app shows "Some widget or Siri actions
couldn't be read and were set aside." and later actions replay. Details: plan §7, 11.05.

**Amended by Phase 12 12.00b.2-C (2026-09-25; charter L130, L131).** Only what cannot
be applied is set aside; everything else replays. Sources: `NativeWidgetActionBatchPlanner`,
`NativeWidgetActionClaimTransport` and `NativeWidgetActionReplayCoordinator` in
`N/NativeWidgetActionReplay.swift`; the replay loop in `N/AppStore.swift`
(`replayVerifiedWidgetActionsIfPossible`).

- **What RN does (the spec).** RN `parsePendingActions` (`utils/widgetActions.ts:62-76`)
  reads `null`, `""`, malformed JSON and a non-array as `[]`, and filters out entries
  that are not objects or lack a string `id`, `type` or `at`. The timer guards
  (`:101-120`), `tripFromAction` (`:136-151`) and `expenseFromAction` (`:186-202`) drop
  a bad action and dedupe on `t_siri_<id>` / `e_siri_<id>`. `replayWidgetActions`
  removes the key before parsing (`:247-253`), so a bad entry, or a whole unparseable
  queue, is lost. There is no cap. RN tests: `__tests__/widgetActions.test.js:70-100`
  ("drops entries missing id, type, or at; keeps valid ones") and `:484-495`. Native
  matches RN on the valid entries (they apply) and differs only in keeping the bad
  bytes instead of losing them.
- **A list with bad entries.** The owner check still runs first (§4.5): an untagged,
  foreign or non-object entry is owner-dropped and never set aside for this owner.
  Each owned entry is then checked alone. A bad one is left out of the batch and every
  valid one applies, in order. When the claim is acknowledged, the bad entries are
  written, in the same lock hold and verified BEFORE the claim file is removed, to one
  `quarantine-<binding>-<digest>.json` record: `sourceBytes` is a JSON list of those
  entries with their exact bytes from the claim, `reason` is the first entry's reason
  and `entryReasons` lists one per entry (`malformedAction`, `invalidAction`,
  `duplicateActionID`). The digest names the set-aside bytes.
- **Duplicate ids.** The first valid entry of an id applies. A later entry that is
  exactly the same action (same sorted-key digest) is skipped, not set aside: it is the
  writer's idempotent re-append (§4.3), and the idempotency markers would ignore it
  anyway. A later entry that differs is set aside: it can never apply under that id,
  so setting it aside (bytes kept) loses no action. An entry that is itself set aside
  does not take its id.
- **More than 512 entries.** A claim takes the first 512 entries, each with its exact
  bytes (`NativeWidgetActionBatchPlanner.claimablePrefix`). Removing the claimed prefix
  leaves the rest in the shared queue, in order and with their exact bytes (canonical
  sorted-key JSON only if the bytes cannot be split and verified). The next claim, in
  the same pass or the next activation, takes the next prefix. Nothing is set aside
  for size, so `tooManyActions` is no longer written; it stays decodable for 11.x
  records.
- **Bytes that are not a JSON list.** Unchanged: the whole queue is set aside
  (`malformedQueue`) with its exact bytes, as resolved by 11.05.
- **Claim files (L131).** A claim file that fails validation (it does not decode, its
  schema, owner, digest or file name do not match, or its bytes are not a list) is set
  aside as `invalidClaim`, keeping the file's exact bytes. Two or more valid claims for
  one owner are all set aside as `conflictingClaims`. The protocol never makes two
  (one writer under the §4.2 lock, and a claim is returned before another is taken),
  so a pair comes from outside it: a restore, a copy or a version skew. Nothing orders
  them and either may already be applied, so applying one or both could reorder timers
  or repeat an action. Setting both aside applies nothing twice, and each claim's
  exact bytes stay in a record that retention never evicts (see Bounds). An invalid
  claim beside one valid claim: only the invalid one is set aside, and the valid one
  then replays. Each record is verified before its claim file is removed. Another
  owner's claim is still discarded unread (§4.5). The pass continues with the next
  claim.
- **Unreadable claim paths (fix round 1, 2026-09-25).** A claim path that is not a
  regular file (a directory, a symbolic link: `isRegularFileKey`) has no bytes to keep:
  it is removed (a link, never its target) behind a count-only `invalidClaim` record
  (`sourceBytes` nil, `sourceByteCount` 0, digest of the file name), and the pass
  continues. **Remaining behavior:** a regular claim file that cannot be read still
  fails the pass closed and is left in place, because its bytes could not be kept and
  the read may succeed later (data protection). Each such pass is counted
  (`unreadableClaimCount`) and logs one fixed, payload-free line
  (`TradeReadyWidgetReplay stage=unreadable-claim`), with "Widget actions are still
  safely queued and will be retried." Replay for that owner waits until the file is
  readable; the writers keep queueing up to their 512-entry limit (§4.3).
- **At most once.** A valid action is applied only from a claim, and the claim file is
  removed only after the canonical save, the outbound enqueue and the set-aside record
  (all verified). A crash before removal leaves the claim; the retry applies the same
  bytes again, and the idempotency markers and deterministic ids make every valid
  action a no-op, while the record is rewritten under the same name. A record that
  already exists under that name with other bytes is replaced (the name is the digest
  of the set-aside bytes, so those bytes are the same). A set-aside claim is never
  applied. A long queue is claimed in disjoint prefixes, and the prefix is removed from
  the queue by value, so no entry is claimed twice.
- **Bounds (fix round 1, I1).** Retention never deletes a record that may hold the
  only copy of valid actions. Only set-aside-entry records (`entryReasons` present)
  are evicted: at most 4 per owner, the oldest first. They hold entries that can
  never apply. Whole-queue records (`malformedQueue`, 11.x `tooManyActions`) and
  claim-file records (`invalidClaim`, `conflictingClaims`) are never evicted, not by
  entry records and not by each other, including when one pass writes several. That
  pool is bounded without eviction: only the app writes claim files (app-private
  storage, one claim at a time under the §4.2 lock), and every native writer writes
  a JSON list and refuses to overwrite a queue that is not one (§4.3), so each such
  record needs a file or queue made outside the protocol, and setting it aside
  removes that source. The account scrub removes all records. The 1 MiB byte limit
  still applies to every record (above it, digest and size only, as since 11.05).
- **Message and diagnostics.** A message appears only when something was set aside.
  Entries set aside while their batch applied: "1 widget or Siri action couldn't be
  applied and was set aside." or "N widget or Siri actions couldn't be applied and were
  set aside.", counting the whole pass. A whole queue or an invalid claim keeps "Some
  widget or Siri actions couldn't be read and were set aside."; conflicting claims show
  "Some widget or Siri actions couldn't be applied and were set aside." These take
  precedence within a pass, also over a later "Kept N newer widget action(s)…" result
  or "still safely queued" failure in the same pass (fix round 1), so the one-time
  message is not overwritten. Counts only, reset at an account boundary:
  `setAsideActionCount` (counted from a result returned only after the claim is
  acknowledged, so a retried claim counts once), `quarantinedQueueCount`,
  `quarantinedClaimCount`, `unreadableClaimCount`.
- **Not changed.** Owner gating (§4.5, the replay binding), the idempotency markers,
  the 8-claim bound per activation, and the retention of unsupported future types (a
  claim holding one is kept whole, its set-aside entries included, until a compatible
  update).
- Evidence: `native/WidgetActionReplayTests/main.swift` (`testPartialQuarantine`,
  `testClaimQuarantine`), `native/WidgetOwnerGatingTests/main.swift` (`testQuarantine`,
  `testQuarantineInAppStore`, `testOneLock`), Q2 in
  `native/Phase11QualificationTests/main.swift`.

**Amended by Phase 12 12.00b.2-D (2026-09-25; charter L286.1).** Replay keeps its
bookkeeping local, and no `__native*` key reaches the server. This replaces the
start/stop marker rule above and the "idempotency markers" named in the 12.00b.2-C
amendment (At most once, Duplicate ids, Not changed); the rest of that amendment
stands. Sources: `NativeWidgetActionReplayer`, `NativeWidgetActionClaim.appliedTimers`,
`NativeWidgetActionClaimTransport.recordAppliedTimers` and
`NativeWidgetActionReplayCoordinator` in `N/NativeWidgetActionReplay.swift`;
`Canonical.nativePrivateKeyPrefix` and `ObjectReader.finish` in
`N/Domain/CanonicalModels.swift`; `upsertRequest` in `N/NativeSupabasePush.swift`.

- **Why the markers went.** They sat in the session's unknown fields, were pushed
  inside the job, and RN keeps them: `mergeRemoteRecord` returns the remote job
  (`utils/syncMerge.ts:44-59`) and `applyClockOut` spreads the session
  (`utils/timeTracking.ts:124-133`). They were also the only record of which timer
  actions a claim had applied. After a push, a pull replaces a job that is not pending
  with the server copy (`AppStore.rebasePulledDelta`). With the markers stripped from
  the push and nothing else changed, an unacknowledged claim retried after that pull
  clocked in again: the poor-network test showed two sessions, locally and on the
  server. So stripping alone was not safe.
- **The ledger.** A claim now carries `appliedTimers`: one entry per timer action an
  attempt of that claim applied (the action id, start or stop, the job id, and the
  start of the session it opened or closed). The coordinator writes it into the claim
  file (an atomic rewrite, verified by read-back) BEFORE the canonical save. The claim
  file is app-private, never synced, and goes when the claim is acknowledged or set
  aside. The field is left out until a timer action is recorded, so a claim file written without it reads
  unchanged, and the claim schema version stays 1.
- **Retry rule.** For an action in the ledger: a start counts as applied if its job
  still holds a session with that start; if not, the earlier save never happened and
  the start applies again. A stop acts only on its own session: closed means applied;
  still open means the earlier save never happened, so it is closed again; gone means
  it changed elsewhere, and no other session is closed in its place. An action not in
  the ledger applies as before. A session is named by its job and its start because
  neither client ever changes a start once written, and the server copy keeps it: RN
  `applyClockIn` appends and `applyClockOut` only sets the last session's `end`
  (`utils/timeTracking.ts:106-133`), and native `AppStore.clockIn`/`clockOut` do the
  same. Trips and expenses keep their deterministic `t_siri_`/`e_siri_` ids, which the
  server copy keeps too.
- **Outbound: one choke point.** `NativeSupabaseMutationPushService.upsertRequest`
  drops every key that starts with `__native` from the payload, at any depth, for
  every table (collections, settings, customer notes), before it builds the body.
  Every queued upsert passes there, whichever producer queued it and whenever (a queue
  file written by an earlier build included). A delete sends the constant
  `{"deleted": true}`. The push is the only writer to `rest/v1`; the initial and delta
  sync only read. The other requests (estimate and change-order approval links,
  portal and booking administration, booking response, invoice delivery, AI, coach,
  photo transfer) send endpoint-specific bodies, not job rows, and are built from
  records that no longer hold such keys (Inbound). The queue and the rejected-change
  store keep payloads as queued: both are local, a Retry pushes through the same
  builder, and the queue's push reconciliation compares items by value.
- **Inbound.** Decoding drops every `__native*` key from a record's unknown fields,
  including one nested in another unknown field (`ObjectReader.finish`). A record read
  from disk, a pull, or a Discard fetch never holds one. A stale marker written by an
  earlier native build and kept by RN decodes, is inert (the replayer no longer reads
  markers, so it cannot suppress a new action), and the next push of that job cleans
  the server row. Only the two replay markers ever used the prefix.
- **Recorded limits.** A claim that a build before this change applied but did not
  acknowledge has no ledger, and its markers are dropped on read, so after the update
  its timer actions apply again. There are no current users, so this is accepted. A
  session removed before an interrupted claim is retried (a Discard of the job, or an
  older server copy) is started again, as it was with the markers.
- Evidence: `native/WidgetActionReplayTests/main.swift` (`testReplayMarkersStayLocal`),
  `native/PoorNetworkTests/main.swift` (`widgetReplayMarkersStayLocal`,
  `staleServerMarkersAreDroppedOnPull`), `native/MutationPushTests/main.swift`,
  `native/WidgetOwnerGatingTests/main.swift`. Device row: P12-B2D-1 (evidence index
  §23).

---

## 5. Intent contract (A1, A2)

### 5.1 Inventory

RN sources:
- `targets/widget/_shared/SiriIntents.swift`: intents at lines 476–814, phrases at
  lines 824–899.
- `targets/widget/JobTimer.swift`: timer intents at lines 117–185.

Native type names and phrases may differ from RN (no current users). The native versions
below are **chosen**.

| # | RN intent (title) | Parameters | App Group behavior | `openAppWhenRun` | Native target | Stale rule |
|---|---|---|---|---|---|---|
| 1 | NextJobIntent ("Next Job") | — | Read-only `widgetSnapshot.nextJob`. Dialog "You have no upcoming jobs scheduled." when none | no | app (Siri) | refuse |
| 2 | StartTripIntent ("Start Mileage Trip") | `odometerStart: Double` | Writes `activeTrip` only (§4.4) | no | app | n/a |
| 3 | StopTripIntent ("Stop Mileage Trip") | `odometerEnd: Double` | `activeTrip` → one `trip_log`, clear | no | app | n/a |
| 4 | OnMyWayIntent ("On My Way") | — | Stash `pendingOpenUrl {url, at, ownerTag}` with `tradeready://onmyway/<nextJob.id>`, written in one lock hold with the `nextJob`/`ownerTag` read (§4.5, §6.2) | **yes** (`@MainActor`) | app | refuse |
| 5 | ClockInIntent ("Clock In") | — | `timer_start` for `nextJob.id`. "already clocked in" if a pending start or snapshot timer exists; "No upcoming job to clock into." | no | app | refuse |
| 6 | ClockOutIntent ("Clock Out") | — | `timer_stop` with the snapshot timer's `jobId` when known. "You're not clocked in." | no | app | n/a |
| 7 | LogExpenseIntent ("Log Expense") | `amount: Double`, `category: ExpenseCategory`, `expenseDescription: String?` (native choice: RN declares a non-optional `String` at `targets/widget/_shared/SiriIntents.swift:760`. Optional lets Siri skip the prompt; empty or absent becomes "Logged via Siri") | `expense_log`. Amount finite, > 0, ≤ 1,000,000, else "That amount doesn't look right." | no | app | n/a |
| 8 | OutstandingIntent ("Outstanding Invoices") | — | Read-only `outstandingTotal`. "Nothing outstanding — you're fully collected." / "You're owed $X in outstanding invoices." | no | app | refuse |
| 9 | StartTimerIntent ("Start Job Timer") | `jobId: String` | `timer_start`. An empty id writes nothing. `isDiscoverable = false` | no | **both** (widget button) | Start button hidden when stale |
| 10 | StopTimerIntent ("Stop Job Timer") | `jobId: String` | `timer_stop` (jobId only if non-empty). `isDiscoverable = false` | no | **both** | allowed |

"On the clock" rule: a pending queued timer action beats the snapshot (last action wins).
Sources: `siriIsOnTheClock` at `targets/widget/_shared/SiriIntents.swift:238`,
`lastPendingTimerType` in `JobTimer.swift`.

**OnMyWay under native (chosen):**
- `openAppWhenRun` runs `perform()` in the app process. There is no
  `RCTOpenURLNotification`; RN posted it at `targets/widget/_shared/SiriIntents.swift:593`.
- The intent stashes `pendingOpenUrl`, for a cold launch where `AppStore` is not ready,
  and hands the URL to an app-side router that feeds `AppStore.handle(url:)` once the
  store exists.
- Gap for 11.04/11.06: `consumeVerifiedPendingOpenURLIfNeeded` consumes only once per
  session (`didConsumeVerifiedPendingOpenURL`, `N/AppStore.swift:5190-5204`). The warm
  path must therefore route directly rather than rely on the stash.
  **Closed by 11.06 (2026-09-24):** the once-per-session consume is gone (see §2.5), and
  a warm `onmyway` route removes its matching stash under the lock (`takeMatching`), so
  the cold consumer never presents the same review twice (§6.3).
- The route ends in `routeToOnMyWay` → `requestOnMyWayReview`
  (`N/AppStore.swift:5210-5213`): an editable review that is **never auto-sent**.

### 5.2 Phrases (native; the RN phrases are kept, `.applicationName` is required)

| Intent | Phrases | Short title / SF Symbol |
|---|---|---|
| Next Job | "What's my next job in X", "What's next in X" | Next Job / `calendar` |
| Start Trip | "Start a trip in X", "Start tracking miles in X" | Start Trip / `car` |
| Stop Trip | "Stop my trip in X", "Finish my trip in X" | Stop Trip / `car.fill` |
| On My Way | "I'm on my way in X", "Tell my customer I'm on my way in X" | On My Way / `message` |
| Clock In | "Clock in in X", "Start the clock in X" | Clock In / `play.circle` |
| Clock Out | "Clock out in X", "Stop the clock in X" | Clock Out / `stop.circle` |
| Log Expense | "Log an expense in X", "Add an expense in X" | Log Expense / `dollarsign.circle` |
| Outstanding | "How much am I owed in X", "What's outstanding in X" | Outstanding / `banknote` |

X is `\(.applicationName)`. Start/Stop Timer have no phrases (`isDiscoverable = false`).

### 5.3 Expense category AppEnum

Raw values: `materials, tools, fuel, labor, insurance, software, marketing, other`.
These equal RN `ExpenseCategoryId`.

Display labels: Materials, Tools & Equipment, Fuel & Transport, Subcontractors,
Insurance, Software & Apps, Marketing, Other.

### 5.4 Target membership (ruling P3)

- The new file N/Widgets/Shared/WidgetIntents.swift (proposed by the plan) holds
  Start/Stop Timer plus the shared lock/queue helpers. It is a member of **both** the
  app and extension targets, via 11.01's `PBXFileSystemSynchronizedBuildFileExceptionSet`
  entries.
- Extension-only files (the `@main WidgetBundle`, widget views) are excluded from the
  app target. `N/` is a synchronized root group, so without an exception every file
  joins the app target and two `@main` types fail to compile.
- **Amended by 11.01 (2026-09-23) — sibling-root layout (the fallback P3 allowed):**
  Xcode 26.6 exception sets honor per-file paths only (folder paths and globs were
  tried in a scratch project and ignored), so a per-file exclusion list for every
  future widget file would be fragile. Instead:
  - extension-only sources live in their own synchronized root
    `native/TradeReadyWidgets/`, owned by the extension target only. The app's
    `N/` root never sees them, so no app-side exception is needed;
  - `N/Widgets/Shared/` stays inside the app's `N/` root **and** is a second
    synchronized root owned by the extension. Every file placed there compiles into
    **both** targets with no project-file edit, including 11.04's
    `N/Widgets/Shared/WidgetIntents.swift`;
  - the only exception set lists the extension's `Info.plist` and
    `TradeReadyWidgets.entitlements` (not compiled sources);
  - rule for 11.02–11.05: never put an extension-only file under `N/Widgets/`
    outside `Shared/` (it would join the app target). Shared files must compile in
    both targets (Foundation/AppIntents/WidgetKit only; no app-only types).
- Siri-only intents live in the new N/Intents/ directory (app target only).
- `AppShortcutsProvider` lives in the new N/NativeAppIntents.swift (app target only, per
  Apple DTS; see `targets/widget/_shared/SiriIntents.swift:12-28`).
- A single availability floor of iOS 17.0 applies to every intent, with no mixed
  `@available`. This matches the app and the extension deployment target.

---

## 6. Deep-link contract (L1, L2)

### 6.1 Grammar (existing: `N/NativeDeepLinkParser.swift:26-49`, RN `utils/deepLinks.ts`)

- `tradeready://job/<id>` and `tradeready://onmyway/<id>`, parsed per
  `utils/deepLinks.ts` `JOB_LINK`/`ONMYWAY_LINK`.
- The scheme is case-insensitive.
- Exactly two components; no query or fragment.
- The id is percent-decoded and must be non-empty.
- Anything else → `nil`, with no side effect.
- `pendingOpenUrl`: `{url, at}`, freshness `0 ≤ age ≤ 300 s`
  (`pendingOpenURLMaximumAge = 5*60`; RN `PENDING_OPEN_URL_MAX_AGE_MS`). A negative or
  greater age is rejected. RN reads, then removes, then parses (`App.tsx:537-550`).

### 6.2 Gate order (chosen)

1. **Intercept before parsing:** the Google Sign-In callback (`N/TradeReadyNativeApp.swift:99-101`)
   and then the password-recovery link inside `handle(url:)` keep their current priority.
2. **Parse** (above).
3. **Read the stash under the lock.** The `pendingOpenUrl` stash is `{url, at, ownerTag}`.
   11.04 writes it inside the same lock hold that reads `ownerTag` and `nextJob.id`
   (§4.5). The consumer (11.06) reads **and removes** it in one lock hold, whether or not
   it is valid, then checks freshness (`0 ≤ age ≤ 300 s`) and parses it. A stash with no
   tag is discarded.
4. **Authenticate and park:** if the gate is not `.signedIn`, park at most one pending
   route in memory, holding its source, its `ownerTag` (stash) or arrival-time `O` (warm
   URL, possibly nil), and `at`. RN parked until session and navigation were ready
   (`App.tsx:491-523`, flush points at 552-553, 558-560 and 593-597).
   - Cold-launch parking rule: apply the parked stash route only when the gate reaches
     `.signedIn` with `hash(O) == ownerTag`.
   - Discard it when the tag differs, when the gate reaches `.signedOut`,
     `.accountMismatch` or `.unavailable`, or when the app backgrounds first.
   - **Amended by the 11.06 fix round 1 controller ruling (the brief wins over the
     wording above):** "reaches a closed gate" means leaving a session in which an owner
     was active (`O` held at some gate since the last boundary): sign-out, account
     switch, scrub, deletion, or a mismatch/outage reached after sign-in. The initial
     launch resolution `.loading` → `.signedOut` (or `.accountMismatch`/`.unavailable`)
     is **not** a boundary and keeps the parked route for the sign-in that follows. The
     tag check (a stash for another owner is discarded at apply time) and the freshness
     window still protect the owner.
   - A parked warm URL applies when `.signedIn`, and only if its arrival binding was nil
     or equals `O`. The record lookup in step 6 is always in the current owner's data.
5. **Exact owner:** the §2.5 predicate `O` is non-nil and the gate is `.signedIn`.
6. **Record:** the job exists and `archivedAt == nil`.
   - `job` routes on any non-archived status. A complete or paid job's detail is still
     the right record.
   - `onmyway` also refuses `DONE_STATUSES`. A native deviation from RN, chosen so no
     on-my-way review is offered for finished work.
   - A failure shows the existing not-found state, never a different record.
7. On success, track `widget_deep_link_opened {type}` (§9.5). The stash was already
   removed in step 3 (RN reads, then removes, then parses).

**Gaps 11.06 must close (found in source):**
- `AppStore.handle(url:)` (`N/AppStore.swift:3593-3603`) checks only `jobs.contains`.
  It has no auth, owner or archived gate, and no parking.
- `NativePendingOpenURLConsumer` (`N/NativeAppGroupInbox.swift:92-133`) has no archived
  check, does not take the lock, and never clears its source.
- `consumeVerifiedPendingOpenURLIfNeeded` is gated on the migrated owner and runs once
  per session (§2.5).
- **All three closed by 11.06 (2026-09-24):** `handle(url:)` runs the whole gate through
  `NativeDeepLinkRoutingPolicy` (auth → park, exact owner, live non-archived record);
  `NativePendingOpenURLConsumer` reads and removes under the lock, checks freshness and
  the tag, and the record check runs at apply time; the migrated-only, once-per-session
  consume is replaced (§2.5). Details in §6.3.
- **P8 (C11):** the parked Phase 10 "`est_` archived dead tap" decision belongs
  to 11.06. **Resolved 2026-09-24, see §6.3.**

### 6.3 11.06 decisions and recorded native differences (2026-09-24)

- **C11 / P8 resolved: an archived estimate's `est_` tap opens.**
  `NativeEstimateFollowUp.canOpenNotification` no longer refuses an archived job.
  - Why: `upcomingReminders` still schedules `est_` for an archived `estimate_sent` job
    (like RN `selectEstimateFollowUps`; RN `utils/archive.ts` keeps notifications seeing
    archived records), and RN's `estimate_follow_up` tap routes with no archive check.
    Refusing it made a notification the app itself delivered a dead tap, which Phase 10
    §9.6 rules out for every other family.
  - The principle shared with the widget links: a surface the app is still producing
    must route; a stale link to a record that is no longer produced fails closed.
  - The owner gate is unchanged: exact signed-in workspace, job present, still
    `estimate_sent`.
- **Archived job with a running timer (native difference to step 6):** a `job` link to an
  archived job whose last time session is open routes to that job. The Job Timer widget
  keeps showing that running clock (§2.2 parity; `activeTimer` does not filter archived)
  and its tap is `tradeready://job/<id>`, so refusing it would be a dead tap on the app's
  own widget. `onmyway` never gets this exception (Next Job never selects an archived job).
- **Oversize bound (native difference to §6.1):** a link longer than 1,024 UTF-8 bytes,
  or a `pendingOpenUrl` value longer than 4,096 bytes, is dropped before parsing, and the
  id must also pass `WidgetActionFieldRules.isValidIdentifier` (non-empty, at most 128
  UTF-8 bytes, no control characters). RN has no bound; no producer comes near it.
- **Not-found surface (step 6):** a record failure (missing, archived, or `onmyway` on a
  done status) shows a sheet reusing the Jobs "Job not found" title and symbol. Owner and
  freshness failures are silent, because showing anything would describe a link that is
  not this owner's to open.
- **Parking details (step 4):**
  - "Discard when the gate reaches `.signedOut`/`.accountMismatch`/`.unavailable`" means
    on **entering** it **out of a session in which an owner was active** (fix round 1, I1:
    `AppStore.deepLinkOwnerWasActive`, set when `O` holds at a gate change and consumed
    by the boundary). The launch resolution `.loading` → `.signedOut` keeps the route, so
    a widget tap or stash that cold-launches a signed-out app opens after the same owner
    signs in. A link that arrives while the gate is already closed also parks and is
    decided at sign-in, like RN.
  - A warm link that arrived with no owner signed in (arrival binding nil, no stash tag)
    and whose record the signing-in owner does not have is dropped **silently**
    (`missingRecordUnownedArrival`, fix round 1 M1): that owner is never told "Job not
    found" for a tap another owner may have made. A missing record for a link that
    arrived under `O`, or for `O`'s own tagged stash, still shows not-found.
  - The 300 s freshness window bounds every candidate, parked or not.
  - Every other gate (loading, initial sync, subscription, paywall, starting point,
    onboarding, password recovery) keeps the parked route.
- **Double On My Way (11.04 handoff):** a warm `onmyway` link removes the matching stash
  (same parsed route) in one lock hold and carries its tag as extra owner proof. The
  intent writes the stash and hands the URL to the router on the main actor with no
  suspension in between, so the cold consumer never sees a stash the warm route will
  also present.
- **Account boundaries:** sign-out, deletion, scrub retry and `useAnotherAccount` clear
  every held route and one-shot target (`deepLinked*`, `pending*JobID`, the parked route
  and the notice). `useAnotherAccount` clears before its first await and again after
  its awaits.

---

## 7. SDK decision (P1, R1; ruling P7)

Both SDKs are consumed through SPM with `kind = exactVersion`, following the existing
precedent in `native/TradeReadyNative.xcodeproj/project.pbxproj` (GoogleSignIn-iOS 9.2.0,
purchases-ios-spm 5.83.2). They are linked to the **app target only**; the widget
extension links neither. Each sits behind a Foundation-only protocol adapter that host
tests replace with a fake.

| SDK | Repository | Pinned version | Released | SPM product | PrivacyInfo |
|---|---|---|---|---|---|
| Sentry Cocoa | `https://github.com/getsentry/sentry-cocoa` | **9.29.0** (latest stable) | 2026-09-17 | `Sentry` (binary xcframework) | Ships `Sources/Resources/PrivacyInfo.xcprivacy`: collects Crash Data, Performance Data, Other Diagnostic Data (linked: no, tracking: no, purpose App Functionality). APIs: UserDefaults `CA92.1`, System Boot Time `35F9.1`, File Timestamp `C617.1` |
| PostHog iOS | `https://github.com/PostHog/posthog-ios` | **3.81.0** (latest stable) | 2026-09-22 | `PostHog` | Ships `PostHog/Resources/PrivacyInfo.xcprivacy` (Package.swift lines 37-38, `.copy`): collects Product Interaction, Other Usage Data (Analytics; linked: no, tracking: no). APIs: UserDefaults `CA92.1`, System Boot Time `35F9.1`, File Timestamp `C617.1`. Also bundles PHPLCrashReporter |

For reference, the RN versions are `@sentry/react-native` 7.2.0 and
`posthog-react-native` 4.54.5.

**Concern:** PostHog 3.81.0 was one day old when pinned. 11.07 re-checks for a
3.81.x patch release before adding the package and records the final pin. Moving to a
newer patch is allowed; moving to a new minor needs a note in the execution log.

If package resolution fails for lack of network, 11.07/11.09 ship the adapter and fake
and report BLOCKED on the SDK link only (ruling P7).

**Re-check (11.07, 2026-09-24):** `git ls-remote --tags https://github.com/PostHog/posthog-ios`
lists no 3.81.x patch after 3.81.0. The next tag is **3.82.0**, a new minor, which was not
adopted. The final pin is **3.81.0** (`exactVersion`, revision
`2771b92c2e7b5471c196d24d5bc4997e26cafbcd` in `Package.resolved`). The package resolved
over the network and links to the app target only.

**Re-check (11.09, 2026-09-24):** `git ls-remote --tags https://github.com/getsentry/sentry-cocoa`
lists **9.29.1**, published 2026-09-24 about 90 minutes before the package was added. Its
notes cover an opt-in experimental URLSession loader, MetricKit payload retention, replay
trace ids, a watchOS duplicate-span fix and the App Hang timeout guard. None touches an
option §10.2 sets, so the ruling's pin was kept. The final pin is **9.29.0** (`exactVersion`,
revision `d9df1c4e8d8466c7f8b3c56150378927dadf1b8e` in `Package.resolved`), SPM product
`Sentry` (the static xcframework, checksum-verified by SwiftPM), linked to the app target
only.
- Resolution note: `xcodebuild -resolvePackageDependencies` hung on this machine inside
  SwiftPM's keychain credential lookup for `github.com` before downloading the binary
  artifact. It resolved with `-packageAuthorizationProvider netrc`, which skips the
  keychain. There is no `~/.netrc`, so the download is anonymous. Nothing about the
  project changed.
- Moving to 9.29.1 or later is a one-line pin change plus a `Package.resolved` update;
  record it in the execution log.

---

## 8. Privacy manifest contract (M1)

Both manifests are new files. The app's is N/PrivacyInfo.xcprivacy, created by 11.09.
The extension's is N/Widgets/PrivacyInfo.xcprivacy, created by 11.01. Neither exists
today (grep: no `PrivacyInfo.xcprivacy` in `native/`).
**Amended by 11.01 (2026-09-23):** the extension manifest is
`native/TradeReadyWidgets/PrivacyInfo.xcprivacy` (sibling-root layout, §5.4). It declares
UserDefaults `1C8F.1` only, no tracking and no collected data; the re-grep found no
file-timestamp, boot-time or disk-space use in the extension's sources.

### 8.1 Required-reason APIs

| API category | App target | Widget extension | Evidence |
|---|---|---|---|
| UserDefaults | `CA92.1` (standard defaults) **and** `1C8F.1` (App Group shared with the extension) | `1C8F.1` | App Group suite: `N/NativeAppGroupInbox.swift`, `N/NativeWidgetActionReplay.swift:393`, `N/LegacyDataImporter.swift:235`. Standard: `N/NativeInitialSync.swift:135,677-684`, `N/NativeSupabasePush.swift:71,314-321` |
| File timestamp | **`C617.1`** (corrected by 11.09: the 11.00 grep missed `contentModificationDateKey`) | none | `N/NativeWidgetActionReplay.swift` reads `.contentModificationDateKey` of the widget-action claim files in the App Group container to order and evict them. `N/NativeJobPhotoTransfer.swift:166` reads `.isRegularFileKey`/`.isSymbolicLinkKey`, which is not a required-reason key |
| System boot time | none of our own (SDKs declare `35F9.1`) | none | grep: no `systemUptime`/`mach_absolute_time` in `N/` |
| Disk space | none | none | grep: no `volumeAvailableCapacity` in `N/` |

Each implementer re-greps before writing its manifest, and adds a row if new code
introduces a category.

**11.09 re-grep (2026-09-24)** over `N/` and `native/TradeReadyWidgets/` for
`ModificationDate`, `creationDate`, `attributesOfItem`, `stat(`, `fstat`, `systemUptime`,
`mach_absolute_time`, `volumeAvailableCapacity`, `identifierForVendor`,
`activeInputModes` and the other date resource keys: the only hits are the two
`contentModificationDateKey` reads above. No widget-extension source reads a timestamp, so
the extension manifest is unchanged. The crash-reporting code adds no category.

### 8.2 Collected-data types (app manifest)

| Type | Linked | Tracking | Purposes | Source |
|---|---|---|---|---|
| User ID | **yes** | no | Analytics, App Functionality | `identify` and Sentry user use the Supabase user id (§9.4) |
| Product Interaction | yes (identified after sign-in) | no | Analytics | PostHog events |
| Other Usage Data | yes | no | Analytics | PostHog lifecycle and screen events |
| Crash Data | yes | no | App Functionality | Sentry |
| Performance Data | yes | no | App Functionality | Sentry traces (0.2) |
| Other Diagnostic Data | yes | no | App Functionality | Sentry `reportError` |

`NSPrivacyTracking` is false and `NSPrivacyTrackingDomains` is empty. The SDKs' own
manifests say "linked: no". The app manifest declares "linked: yes" because the app ties
events to a user id. The app-level declaration wins for App Store labels.

The extension manifest declares **no** collected data: it neither transmits nor
identifies.

### 8.3 Analytics inputs for the app manifest (recorded by 11.07, 2026-09-24)

11.09 writes the app manifest. These are the analytics facts it needs, taken from the
linked SDK and the implemented transport.

**Collected-data types that analytics contributes** (§8.2 rows confirmed; each is
Analytics purpose, tracking no):

| Type | Linked | What produces it |
|---|---|---|
| User ID | yes | `identify(<Supabase user id>)`. The transport rejects any id that is not a plain identifier (no email, phone, token or free text). 11.08 wires the calls |
| Product Interaction | yes | §9.5 catalog events, after the allow-list and redaction, and `$screen` (11.08) |
| Other Usage Data | yes | The SDK's `Application Installed/Updated/Opened/Backgrounded` events (`version`, `build`, `previous_version`, `previous_build`, `from_background`) and its default context properties (OS, app version, device type, locale, session id) |

**Decisions left to 11.09:**
- **Financial Info / Purchase History:** the catalog sends money amounts (`amount`,
  `balanceRemaining`; §10.1 allows them). `subscription_purchased` records that a purchase
  happened, with no amount. Decide whether these count as "Other Financial Info" and
  "Purchase History". §8.2 does not list either.
- **Device ID:** PostHog stores an anonymous distinct id, a random UUID per install kept
  in UserDefaults. `reset()` rotates it. It is not the IDFA and not `identifierForVendor`.
  PostHog's own manifest does not declare Device ID. Decide whether to declare it.

**Decisions (11.09, 2026-09-24; written to `N/PrivacyInfo.xcprivacy`):**
- **Other Financial Info: declared** (linked yes, tracking no, Analytics). The catalog
  sends `amount` and `balanceRemaining`, tied to the identified user. They are
  business-ledger values, not the user's own payment data, but Apple's category covers
  "other financial information", and declaring it is the conservative reading.
- **Purchase History: declared** (linked yes, tracking no, Analytics).
  `subscription_purchased` records that the user bought the subscription.
- **Device ID: not declared.** PostHog's anonymous distinct id is a random per-install
  UUID that `reset()` rotates. It is not the IDFA or `identifierForVendor`, and PostHog's
  own manifest does not declare it. The SDK sends it as the pre-identify distinct id and,
  on feature-flag requests only, as `$device_id`; flags are off (`preloadFeatureFlags =
  false`, §9.2). `$device_name` is the model string (`device.model`), not the user-set
  name. Revisit if flags are enabled or a device identifier API is ever read.
- **`PostHog_PHPLCrashReporter.bundle` manifest: left as shipped.** It cannot be removed
  from an SPM resource bundle without forking. It is inert (auto-capture is off, §9.2),
  and its two types (Crash Data, Other Diagnostic Data) are already declared by the app
  manifest for Sentry, so it adds nothing to the label.
- The Sentry and PostHog SDK manifests ship in the app bundle; the 11.09 Release build
  confirmed both (execution log).
- **Concern for Phase 12 App Store Connect labels, not declared here:** the app also
  sends the sign-in email to Supabase auth, syncs business records (customers, jobs,
  invoices) and uploads job photos to the TradeReady backend. §8.2 does not list these
  App Functionality types (Email Address, Name, Phone Number, Physical Address, Photos,
  Customer Support/Other User Content). 11.09 followed the contract; 12.01 must decide
  them with the labels.

**Never collected by analytics:** email, name, phone, address, contacts, location, customer
PII, message bodies, document bytes, credentials. §10.1 denies them and the transport
enforces it (§9.7).

**Required-reason APIs from the SDK** (read from the built
`TradeReadyNative.app/PostHog_PostHog.bundle/PrivacyInfo.xcprivacy`; it matches §7):
UserDefaults `CA92.1`, System Boot Time `35F9.1`, File Timestamp `C617.1`.
- The package also bundles `PostHog_PHPLCrashReporter.bundle/PrivacyInfo.xcprivacy`, which
  §7 did not list. It declares no API types and collects Crash Data and Other Diagnostic
  Data (linked no, App Functionality).
- That crash reporter is never installed: `errorTrackingConfig.autoCapture = false`
  (§9.2), so Sentry stays the only crash reporter. Its manifest still ships in the app
  bundle.

**Required-reason APIs from our own analytics code:** none. `NativeAnalytics.swift`,
`NativeAnalyticsConfiguration.swift` and `NativeAnalyticsPostHog.swift` use no
UserDefaults, file timestamp, boot time or disk-space API. The §8.1 app rows are unchanged.

---

## 9. Analytics contract (P1–P3)

### 9.1 RN configuration (reference)

- Key: `app.json:99` (`expo.extra.posthogApiKey`, a `phc_…` project key; not copied).
- Host: `https://us.i.posthog.com` (`App.tsx:822-831`).
- `POSTHOG_ENABLED = Boolean(key) && !key.startsWith("PLACEHOLDER")` (`App.tsx:105`).
  **There is no `__DEV__` gate for PostHog in RN.** Only Sentry uses `enabled: !__DEV__`
  (`App.tsx:103-114`).
- `PostHogProvider autocapture={{captureScreens: false}}`. `captureAppLifecycleEvents`
  therefore takes the SDK default (true) in `posthog-react-native` 4.54.5.
- `ScreenTracker` calls `useNavigationTracker` inside `NavigationContainer`, which emits
  `$screen` events with route names.
- `posthogRef.current` is set at `App.tsx:745`.
- `track` (`utils/analytics.ts:11-21`) calls `posthogRef.current?.capture` and swallows
  errors.

### 9.2 Native gating (chosen)

Analytics is enabled iff all three hold:
1. a non-Debug build (`#if !DEBUG`);
2. the Info.plist key `TradeReadyPostHogAPIKey` (from the build setting
   `TRADEREADY_POSTHOG_API_KEY`, following the `N/BuildEnvironment.swift` pattern) is
   non-empty;
3. that key does not start with `PLACEHOLDER`.

The host key `TradeReadyPostHogHost` defaults to `https://us.i.posthog.com`.

- Missing configuration → no-op transport, no crash, one bounded debug log.
- **Recorded deviation:** RN sent events from dev builds. Native Debug is silent by
  default (plan 11.07 "Debug build emits nothing").
- Staging stays `https://staging.invalid`. Analytics has no staging project. A staging
  Release build uses the same gate and will send only if a key is configured, so the
  staging config must leave the key empty.

SDK options (chosen):
- `captureApplicationLifecycleEvents = true` (RN parity).
- `captureScreenViews = false`, since SwiftUI auto-capture is unreliable; screens are
  sent explicitly (§9.3).
- Element-interaction autocapture off.
- Session replay off; surveys off.
- PostHog exception/crash capture off, because Sentry is the only crash reporter.
- Flush on background (SDK default).

### 9.3 Screen events (chosen policy; map by 11.08)

- Send `$screen` via the adapter's `screen(name)` for native destinations that have an
  RN route, using the RN route name (e.g. `Today`, `JobDetail`, `Invoices`).
- 11.08 delivers the exact destination-to-route-name table and its test.
- Destinations with no RN route send no screen event.

### 9.4 Identity lifecycle (RN call sites, and the native rule)

RN:
- `identifyUser(userId)` = `posthog.identify(userId)` + `Sentry.setUser({id})`
  (`utils/analytics.ts:23-30`). Called from:
  - `context/AuthContext.tsx:52` (initial `getSession`);
  - `context/AuthContext.tsx:89` (`onAuthStateChange`, any event except `SIGNED_OUT`).
- `resetUser()` = `posthog.reset()` + `Sentry.setUser(null)` (`utils/analytics.ts:32-38`).
  Called from:
  - `screens/SettingsAccountScreen.tsx:57` (account deletion);
  - `screens/SettingsAccountScreen.tsx:88` (sign-out);
  - `screens/PaywallScreen.tsx:131` (hard-gate sign-out).
- RN does **not** reset on the `SIGNED_OUT` auth event itself.

Native (chosen, 11.08):
- `identify(supabaseUserID)`, on both SDK adapters, when the authenticated identity is
  verified and the gate enters `.signedIn`, including cold launch.
- `reset()` on:
  - explicit sign-out (`signOut(revokeRemote:)`);
  - completed account deletion (`deleteAccount`);
  - the paywall/subscription-gate sign-out;
  - **account switch**, where the verified user id differs from the last identified one:
    `reset` runs before the new `identify`;
  - `applyCompletedSignOutState` (`N/AppStore.swift:4252`).
- Never send email, name or any other trait. `identify` carries the id only.

### 9.5 Event catalog (52 events, 70 RN call sites)

Every event fires at the same business moment as RN: after the durable save, not on tap.
Types below: `bool`, `number`, `string`, `string[]`, a literal (`true`), or an enum
(`a|b`). `?` marks an optional key.

| Event | Properties | RN call sites | Native today |
|---|---|---|---|
| `customer_created` | `first: bool` (no prior non-sample customers) | `screens/AddCustomerScreen.tsx:222` (new customers only) | — |
| `estimate_sent` | — | `screens/SendEstimateScreen.tsx:154`, `:168`; `screens/PricingCalculatorScreen.tsx:352` | — |
| `payment_link_sent` | `provider: string`, `deposit: bool` | `screens/OutreachScreen.tsx:211` (explicit generation only) | — |
| `onboarding_step_viewed` | `step: welcome\|business\|starting_point` | `screens/OnboardingScreen.tsx:90`; `screens/StartingPointScreen.tsx:54` | — |
| `onboarding_completed` | `trade: TradeId` | `screens/OnboardingScreen.tsx:116` | — |
| `onboarding_start_choice` | `choice: sample\|fresh` | `screens/StartingPointScreen.tsx:62` | — |
| `sign_in` | `method: password\|apple\|google` | `screens/AuthScreen.tsx:122`, `:172`, `:181` | — |
| `sign_up` | — | `screens/AuthScreen.tsx:130` | — |
| `sign_up_confirmation_resent` | — | `screens/AuthScreen.tsx:155` | — |
| `job_created` | `duplicated?: true`, `customerId?: string` (internal id), `first: bool` | `screens/AddJobScreen.tsx:400` | — |
| `pricebook_entry_saved` | — | `screens/PricebookEntryScreen.tsx:171` | — |
| `invoice_paid` | `amount: number` | `screens/InvoicesScreen.tsx:239` (per bulk-settled invoice), `:340`, `:365` (fully settled only) | — |
| `bulk_invoices_marked_paid` | `count: number` | `screens/InvoicesScreen.tsx:241` | — |
| `bulk_invoice_reminders` | `channel: email\|text`, `count: number` | `screens/InvoicesScreen.tsx:303` | — |
| `payment_recorded` | `amount: number`, `method: PaymentMethod`, `balanceRemaining: number` | `screens/InvoicesScreen.tsx:335` (`method: other`, `balanceRemaining: 0`), `:359` | — |
| `payment_voided` | `amount: number`, `method: PaymentMethod` | `screens/InvoicesScreen.tsx:407` | — |
| `invoice_finalized` | `source: from_job` | `screens/CreateInvoiceFromJobScreen.tsx:226` | — |
| `invoice_created` | variants: `{source: from_job, mode: create\|requestDeposit\|finalize}` · `{source: manual}` · `{source: auto_on_complete, usedTrackedTime: bool, autoEmailQueued: bool}` | `screens/CreateInvoiceFromJobScreen.tsx:245`; `screens/AddInvoiceScreen.tsx:109`; `utils/autoInvoice.ts:337` | — |
| `ai_chat_sent` | `source: insight_prefill\|organic`, `provider: anthropic\|groq\|backend` | `screens/ChatScreen.tsx:166` (before send) | `N/AppStore.swift:8447` |
| `review_request_sent` | `channel: sms\|email`, `source: notification\|job_detail` | `screens/ReviewRequestScreen.tsx:125`, `:139` | — |
| `on_my_way_sent` | `{}` | `screens/TodayScreen.tsx:653`; `screens/JobDetailScreen.tsx:806` (only if the composer opened) | **missing (m6)** |
| `appointment_confirm_sent` | `{}` | `screens/JobDetailScreen.tsx:806` | — |
| `sample_job_opened` | — | `screens/TodayScreen.tsx:754` | `N/AppStore.swift:8316` |
| `first_action_tapped` | `action: add_customer\|create_job` | `screens/TodayScreen.tsx:761`, `:766` | **missing (m6)** |
| `estimate_follow_up_sent` | `channel: sms\|email`, `source: notification\|job_detail` | `screens/EstimateFollowUpScreen.tsx:90`, `:104` | — |
| `trip_logged` | — | `screens/AddTripScreen.tsx:115` | — |
| `estimate_follow_up_opened` | `source: job_detail\|notification` | `screens/JobDetailScreen.tsx:644`; `App.tsx:420` | — |
| `job_status_changed` | `from: JobStatus`, `to: JobStatus` | `screens/JobDetailScreen.tsx:842` | — |
| `time_tracking_started` | `jobId: string` (internal id) | `screens/JobDetailScreen.tsx:1036` | — |
| `change_order_created` | `amount: number` | `screens/AddChangeOrderScreen.tsx:118` (new only) | — |
| `customers_merged` | `jobs: number`, `invoices: number` | `screens/CustomerDetailScreen.tsx:419` | — |
| `expense_logged` | `category: ExpenseCategoryId`, `linkedToJob: bool` | `components/JobProfitabilitySection.tsx:110`; `hooks/useMoneyData.ts:84` | — |
| `subscription_paywall_shown` | `context: settings\|onboarding_gate` | `screens/PaywallScreen.tsx:59` | — |
| `subscription_purchased` | — | `screens/PaywallScreen.tsx:90` | — |
| `change_order_sent` | `amount: number`, `channel: text\|email` | `components/ChangeOrdersSection.tsx:125` | — |
| `change_order_decided` | `decision: approved\|declined`, `channel: manual` | `components/ChangeOrdersSection.tsx:176` | — |
| `setup_checklist_task_opened` | `task: notifications\|contact\|logo\|rate\|stripe` | `components/SetupChecklistCard.tsx:56`, `:78` | `N/AppStore.swift:8527` |
| `setup_checklist_dismissed` | `doneCount: number` | `components/SetupChecklistCard.tsx:83` | `N/AppStore.swift:8294` (stringified) |
| `insight_shown` | `kinds: InsightKind[]`, `ids: string[]` | `components/InsightsCard.tsx:139` | `N/AppStore.swift:8505` (comma-joined) |
| `insight_tapped` | `kind: InsightKind` | `components/InsightsCard.tsx:146` | `N/AppStore.swift:8512` |
| `insight_coach_opened` | `kind: InsightKind` | `components/InsightsCard.tsx:152` | `N/AppStore.swift:8516` |
| `insight_reason_viewed` | `kind: InsightKind` | `components/InsightsCard.tsx:170` | `N/AppStore.swift:8520` |
| `insight_snoozed` | `kind`, `insightId: string`, `days: number` | `components/InsightsCard.tsx:178` | `N/AppStore.swift:8353` (`days` stringified) |
| `insight_dismissed` | `kind`, `insightId: string` | `components/InsightsCard.tsx:188` | `N/AppStore.swift:8353` |
| `receipt_scanned` | variants: `{outcome: failed}` · `{outcome: filled\|empty, route: user_key\|backend}` | `components/money/AddExpenseModal.tsx:150`, `:158`, `:184` | — |
| `tax_settings_saved` | `hasIncomeRate: bool`, `vehicleMethod: mileage\|actual\|unset` | `components/money/TaxSetAsideCard.tsx:61` | — |
| `pull_to_refresh` | `screen: MoneyScreen\|JobsScreen` | `hooks/useRefresh.ts:17` | — |
| `overdue_outreach_opened` | `daysPastDue?: number` (RN passes `data.daysPastDue`, which a payload may omit) | `App.tsx:427` | — |
| `appointment_confirm_opened` | `{}` | `App.tsx:434` | — |
| `booking_request_opened` | `{}` | `App.tsx:466` | — |
| `booking_update_opened` | `{}` | `App.tsx:476` | — |
| `widget_deep_link_opened` | `type: job\|onmyway` | `App.tsx:503` | — |

Enum definitions:
- `TradeId` = plumbing, electrical, hvac, carpenter, bricklayer, plasterer, landscaping,
  cleaning, painting, handyman, other.
- `PaymentMethod` = stripe, cash, check, card, other (`types/models.ts:436`).
- `JobStatus` = lead, estimate_sent, approved, scheduled, in_progress, complete,
  invoiced, paid, declined (`types/models.ts:18-27`).
- `ExpenseCategoryId` = materials, tools, fuel, labor, insurance, software, marketing,
  other (`types/models.ts:44-45`).
- `InsightKind` = labor_overrun, low_margin_estimate, uninvoiced_complete, due_soon,
  open_slot, unscheduled_approved, maintenance_due, expense_anomaly
  (`utils/todayInsights.ts:28`).

Autocapture adds `$screen` (§9.3) and the SDK's `Application …` lifecycle events
(installed, updated, opened, backgrounded; exact names are set by the pinned SDK).
These are SDK-generated and outside the fixture.

**Event-catalog fixture.** 11.08's catalog test and 11.07's allow-list read this exact
JSON. Each event maps to a list of allowed property-shape variants.

```json
{
  "catalogVersion": 1,
  "enums": {
    "TradeId": ["plumbing","electrical","hvac","carpenter","bricklayer","plasterer","landscaping","cleaning","painting","handyman","other"],
    "PaymentMethod": ["stripe","cash","check","card","other"],
    "JobStatus": ["lead","estimate_sent","approved","scheduled","in_progress","complete","invoiced","paid","declined"],
    "ExpenseCategoryId": ["materials","tools","fuel","labor","insurance","software","marketing","other"],
    "InsightKind": ["labor_overrun","low_margin_estimate","uninvoiced_complete","due_soon","open_slot","unscheduled_approved","maintenance_due","expense_anomaly"]
  },
  "events": {
    "ai_chat_sent": [{"source": "insight_prefill|organic", "provider": "anthropic|groq|backend"}],
    "appointment_confirm_opened": [{}],
    "appointment_confirm_sent": [{}],
    "booking_request_opened": [{}],
    "booking_update_opened": [{}],
    "bulk_invoice_reminders": [{"channel": "email|text", "count": "number"}],
    "bulk_invoices_marked_paid": [{"count": "number"}],
    "change_order_created": [{"amount": "number"}],
    "change_order_decided": [{"decision": "approved|declined", "channel": "manual"}],
    "change_order_sent": [{"amount": "number", "channel": "text|email"}],
    "customer_created": [{"first": "bool"}],
    "customers_merged": [{"jobs": "number", "invoices": "number"}],
    "estimate_follow_up_opened": [{"source": "job_detail|notification"}],
    "estimate_follow_up_sent": [{"channel": "sms|email", "source": "notification|job_detail"}],
    "estimate_sent": [{}],
    "expense_logged": [{"category": "enum:ExpenseCategoryId", "linkedToJob": "bool"}],
    "first_action_tapped": [{"action": "add_customer|create_job"}],
    "insight_coach_opened": [{"kind": "enum:InsightKind"}],
    "insight_dismissed": [{"kind": "enum:InsightKind", "insightId": "string"}],
    "insight_reason_viewed": [{"kind": "enum:InsightKind"}],
    "insight_shown": [{"kinds": "enum[]:InsightKind", "ids": "string[]"}],
    "insight_snoozed": [{"kind": "enum:InsightKind", "insightId": "string", "days": "number"}],
    "insight_tapped": [{"kind": "enum:InsightKind"}],
    "invoice_created": [
      {"source": "from_job", "mode": "create|requestDeposit|finalize"},
      {"source": "manual"},
      {"source": "auto_on_complete", "usedTrackedTime": "bool", "autoEmailQueued": "bool"}
    ],
    "invoice_finalized": [{"source": "from_job"}],
    "invoice_paid": [{"amount": "number"}],
    "job_created": [{"duplicated?": "true", "customerId?": "string", "first": "bool"}],
    "job_status_changed": [{"from": "enum:JobStatus", "to": "enum:JobStatus"}],
    "on_my_way_sent": [{}],
    "onboarding_completed": [{"trade": "enum:TradeId"}],
    "onboarding_start_choice": [{"choice": "sample|fresh"}],
    "onboarding_step_viewed": [{"step": "welcome|business|starting_point"}],
    "overdue_outreach_opened": [{"daysPastDue?": "number"}],
    "payment_link_sent": [{"provider": "string", "deposit": "bool"}],
    "payment_recorded": [{"amount": "number", "method": "enum:PaymentMethod", "balanceRemaining": "number"}],
    "payment_voided": [{"amount": "number", "method": "enum:PaymentMethod"}],
    "pricebook_entry_saved": [{}],
    "pull_to_refresh": [{"screen": "MoneyScreen|JobsScreen"}],
    "receipt_scanned": [{"outcome": "failed"}, {"outcome": "filled|empty", "route": "user_key|backend"}],
    "review_request_sent": [{"channel": "sms|email", "source": "notification|job_detail"}],
    "sample_job_opened": [{}],
    "setup_checklist_dismissed": [{"doneCount": "number"}],
    "setup_checklist_task_opened": [{"task": "notifications|contact|logo|rate|stripe"}],
    "sign_in": [{"method": "password|apple|google"}],
    "sign_up": [{}],
    "sign_up_confirmation_resent": [{}],
    "subscription_paywall_shown": [{"context": "settings|onboarding_gate"}],
    "subscription_purchased": [{}],
    "tax_settings_saved": [{"hasIncomeRate": "bool", "vehicleMethod": "mileage|actual|unset"}],
    "time_tracking_started": [{"jobId": "string"}],
    "trip_logged": [{}],
    "widget_deep_link_opened": [{"type": "job|onmyway"}]
  }
}
```

Fixture grammar:
- A property value is `bool`, `number`, `string`, `string[]`, the literal `true`, an
  inline enum `a|b|c` (a single token is a fixed literal), `enum:<Name>` or
  `enum[]:<Name>`.
- A key ending in `?` is optional.
- `[{}]` means no properties: RN sends `undefined` or `{}`, and the two are equivalent.
- An event name missing from `events` is **dropped** by the transport. Debug builds
  assert.
- A property key missing from every variant of its event is **stripped**.
- A value of the wrong type or outside its enum is **stripped** with a bounded
  diagnostic; the event still sends. Rationale: a partial event beats a lost event, and
  no unexpected data leaves the device.

### 9.6 Native seam inventory and deviations (`N/NativeAnalytics.swift`)

Today's seam is `protocol NativeAnalytics { func track(_ event: String, _ properties: [String: String]) }`
with the no-op `NativeNoOpAnalytics`. It is injected into `AppStore` at
`N/AppStore.swift:385` and stored at line 260.

| Call site | Event | Properties sent | Deviation to fix in 11.07/11.08 |
|---|---|---|---|
| `N/AppStore.swift:8294` | `setup_checklist_dismissed` | `doneCount: String` | Must be a number |
| `N/AppStore.swift:8316` | `sample_job_opened` | none | — |
| `N/AppStore.swift:8353` | `insight_dismissed` / `insight_snoozed` | `kind`, `insightId`, `days: String` | `days` must be a number |
| `N/AppStore.swift:8447` | `ai_chat_sent` | `source`, `provider` (`coachProviderSummary.analyticsName`) | Check that the provider values are exactly `anthropic\|groq\|backend` |
| `N/AppStore.swift:8505` | `insight_shown` | `kinds`, `ids` comma-joined | Must be string arrays |
| `N/AppStore.swift:8512` / `:8516` / `:8520` | `insight_tapped` / `insight_coach_opened` / `insight_reason_viewed` | `kind` | — |
| `N/AppStore.swift:8527` | `setup_checklist_task_opened` | `task` | — |
| (missing) | `first_action_tapped`, `on_my_way_sent` | — | Parity matrix m6; 11.08 adds them |

**Chosen (C16, ruling P6):** 11.07 widens the seam **in place** to
`[String: NativeAnalyticsValue]`, where
`enum NativeAnalyticsValue { case bool(Bool), number(Double), string(String), strings([String]) }`
and the enum conforms to the literal protocols. Existing call sites keep compiling
through a `[String: String]` convenience overload. 11.08 migrates them to typed values.
The protocol also gains `identify(_ userID: String)`, `reset()` and `screen(_ name: String)`.

### 9.7 11.07 implementation notes (2026-09-24)

**Seam** (`N/NativeAnalytics.swift`):
- `NativeAnalyticsValue` has four cases: `bool`, `number`, `string` and `strings`. It
  conforms to the literal protocols.
- Both `track` forms are protocol requirements, and each default forwards to the other,
  so a conformer implements at least one of them. *(Superseded by 11.08 m1, below: the
  typed form is now the only requirement and the `[String: String]` form is gone.)*
  - The `[String: String]` form wraps each value as `.string`.
  - The typed form stringifies for legacy string-only conformers: arrays are
    comma-joined, and integral numbers have no `.0`. The existing recording fakes in
    `native/StoreIntegrationTests` and `native/DeepLinkRoutingTests` compile unchanged.
- `identify`, `reset` and `screen` default to no-ops.
- `AppStore()` gained `analytics:`, which defaults to the no-op. `TradeReadyNativeApp`
  passes `NativeAnalyticsTransport.live()`. No call site changed.

**Choke point** (`NativeAnalyticsTransport.track`, via `NativeAnalyticsPrivacyPolicy`):
- The allow-list is parsed from the §9.5 fixture embedded verbatim. A test proves it is
  byte-identical to the block in this document.
- Among an event's variants, the transport keeps the one that keeps the most properties;
  on a tie, the one with the fewest missing required keys. *(Refined by 11.08 m2, below:
  a matching literal discriminator ranks first.)*
- An event outside the catalog is dropped. Debug asserts through an injectable hook.
- **Value rules:**
  - A key in no variant is stripped.
  - A wrong type, a value outside its enum, `duplicated: false` or a non-finite number is
    stripped. The event still sends.
- **Free `string`/`string[]` values** (the ids and `provider`) must be plain identifiers:
  `[A-Za-z0-9_.:-]`, at most 128 bytes, at most 64 array items. The transport strips:
  - credential prefixes (Anthropic/OpenAI `sk-`; Stripe `sk_`/`rk_`/`pk_`/`whsec_`; Groq
    `gsk_`; RevenueCat `appl_`/`goog_`/`amzn_`/`strp_`/`rcb_`; PostHog `phc_`/`phx_`;
    Supabase `sb_secret_`/`sb_publishable_`; Google `AIza`; JWT `eyJ`; GitHub tokens), plus
    `Bearer `, `authorization:`, `access_token` and `refresh_token`;
  - URLs and `data:` URIs (documents and tokenized links);
  - `@` (emails);
  - phone-like values: 7–15 digits with phone punctuation, or a bare run of 7–12 digits.
    RN ids start with a 13-digit `Date.now()`, so they pass;
  - any other character (free text such as names, addresses and notes).
- A sanitized payload over 4,096 bytes of JSON is rejected whole.
- **Diagnostics:**
  - carry the operation, a sanitized event name, and at most 8 (key, reason) pairs plus
    an omitted count;
  - are capped at 512 characters;
  - classify stripped keys as secure, personal-data, document or unknown;
  - never include a value, a user id or an error description;
  - go to `os.Logger` at debug level (category `analytics`).
- `identify` accepts only a plain identifier of at most 128 bytes. `screen` accepts only a
  route-name identifier of at most 64 bytes.
- Every adapter throw is swallowed.

**Gate** (`N/NativeAnalyticsConfiguration.swift`): exactly §9.2.
- Info.plist maps `TradeReadyPostHogAPIKey` → `$(TRADEREADY_POSTHOG_API_KEY)` and
  `TradeReadyPostHogHost` → `$(TRADEREADY_POSTHOG_HOST)`.
- Neither build configuration sets either value, so the Debug (development) and Release
  (staging) builds both resolve to disabled. A reporting release supplies the key at build
  time. The RN production key is never copied into native config.
- A non-empty host that is not a bare `https` origin disables analytics.
- A disabled gate never builds the SDK adapter and logs one setup diagnostic.

**SDK options** (`N/NativeAnalyticsPostHog.swift`), beyond §9.2:
- rage-click autocapture is off (`rageClickConfig.enabled`, default on in 3.81.0); it is
  element-interaction autocapture;
- push-token upload and push-open capture are off;
- feature-flag preload and `$feature_flag_called` are off;
- a `beforeSend` hook drops every SDK event except catalog events, `$screen`,
  `$identify` and the four `Application …` lifecycle events.

**11.08 event parity and identity (2026-09-24).**

*Seam fixes (11.07 review findings):*
- **m1.** `NativeAnalytics` now requires only `track(_:_: [String: NativeAnalyticsValue])`.
  The `[String: String]` overload is removed from the protocol, its extension,
  `NativeNoOpAnalytics` and the transport. Before, the two defaults called each other, so
  a conformer implementing neither compiled and recursed forever. `track(_ event:)` and
  `track(_ event: NativeAnalyticsEvent)` are extension conveniences that funnel into the
  one requirement. `legacyStringValue` remains for host-test fakes only.
- **m2.** Variants are ranked by `(discriminator score, kept count, fewer missing)`. The
  score is +1 for each required single-token literal key (`source: manual`,
  `outcome: failed`) whose supplied value matches, and −1 for each mismatch. A variant
  that keeps more incidental keys can no longer win while stripping the discriminator.
- **m3.** `NativeAnalyticsDiagnostic.sanitizedName`, which is logged `privacy: .public`,
  also redacts a name that `containsSecret` flags (`phc_…`, `sk_live_…`, `AIza…`, `eyJ…`)
  or that carries a run of 7 or more digits.

*Typed events.* Every call site builds its payload with a constructor in
`N/NativeAnalyticsEvents.swift` and sends it through the one `emitAnalytics` in `AppStore`,
after the durable commit. The 11.07 handoff is closed: `doneCount` and `days` are
numbers, and `kinds`/`ids` are string arrays.

*Identity (refines §9.4).*
- `identify` runs when the verified subject is applied
  (`applyAuthenticatedIdentityOutcome`, and the background activation). That is before
  the onboarding, paywall and starting-point gates. It is re-asserted, as a no-op, when
  the gate enters `.signedIn`. This matches RN, which identifies at `getSession` or
  `onAuthStateChange` time, so onboarding and purchase events carry the user id in
  both apps.
- A verified id different from the last identified one resets before identifying.
- `reset` runs at every boundary:
  - `applyCompletedSignOutState`: sign-out, the paywall sign-out, and a retried scrub;
  - `useAnotherAccount`, before its first await;
  - `deleteAccount`, as soon as the server confirms and before the local scrub. This
    also covers the scrub-failure path.
- Back-to-back boundaries reset once, so deletion does not reset again in its teardown.
- As in RN, a session rejection or a password-recovery sign-out does not reset. The
  switch rule covers the next owner.
- Pull-to-refresh drops its event if the owner changed during the sync await.

*Screens (clarifies §9.3).* `$screen` sends the RN **leaf** route name that
`useNavigationTracker` reports (`getCurrentRoute().name`): `TodayHome`, `JobList`,
`InvoiceList`, `CustomerList`, `MoneyHome` and `ChatHome`. It does not send the tab
names `Today` or `Invoices` that §9.3 gave as examples.
- The table is `NativeAnalyticsScreen.routeName`. The test checks every name against
  `App.tsx`.
- Views report through `.nativeAnalyticsScreen(_:)`, an `onAppear`/`onDisappear` hook,
  and the store maps the name.
  - Like RN, every appearance sends. A pop back to a list and a second visit to the
    same page both send again (fix round 1).
  - The tab roots and Settings attach the hook to their stack's root content, so a
    pop re-fires it.
  - The store does not dedupe. The only dedupe is per appearance
    (`NativeAnalyticsScreenAppearance`): SwiftUI's duplicate `onAppear` calls with no
    `onDisappear` between them count once.
- The gate roots (`Auth`, `Onboarding`, `Paywall`, `StartingPoint`) come from the gate
  transition.
- Destinations with no RN route send nothing: expense and payment editors, invoice
  detail, the on-my-way, appointment and change-order reviews, booking requests, the
  portal, photos, sync settings and password recovery.
- The differences that remain:
  - Dismissing a sheet does not re-send the parent screen, while RN re-sends it when
    a stack modal pops.
  - RN also re-sends the focused route on any navigation-state change that keeps it
    focused, such as a params update. Native sends only on an appearance.

*Recorded native differences:*
- `estimate_follow_up_sent` and `review_request_sent` fire only on a composer `.sent`.
  RN also counts `unknown`, which the Android composers report.
- `estimate_sent` fires on:
  - an explicit "Mark estimate as sent";
  - a composer-confirmed delivery stamp (`recordEstimateDelivery` `.recorded`, native's
    only other commit of the sent state);
  - approval-link creation (RN `createLink`).

  As in RN, creating a link and then marking the estimate sent counts twice.
- `on_my_way_sent`, `appointment_confirm_sent` and `change_order_sent` fire when the
  composer is presented, which is RN's "composer opened" moment.
- `estimate_follow_up_opened`, `appointment_confirm_opened` and
  `overdue_outreach_opened` fire only when the guarded native route actually opens. RN
  tracks before navigating, even for a stale payload.
  - `appointment_confirm_opened` is notification-only, as in RN.
  - The job-detail entry passes `fromNotification: false`.
- `bulk_invoice_reminders.count` counts the outreach sheets presented in the chain.
  RN counts the composers it opened.
  - As in RN, the event fires once per run that had an eligible invoice, with a
    count of 0 allowed.
  - The rule is `NativeAnalyticsEvent.bulkInvoiceReminderRun`. The view only reports
    the finished chain (fix round 1).
- `overdue_outreach_opened` sends without `daysPastDue` when the payload has none. RN
  sends `{ daysPastDue: undefined }`, which drops the key.
  - Fix round 1 changed the §9.5 fixture key to `daysPastDue?`, an optional-key
    change only. `catalogVersion` stays 1.
- `subscription_paywall_shown` is always `onboarding_gate`. Native has no Settings
  upsell paywall. A purchase or retry load does not re-fire it within one presentation.
- `booking_request_opened` and `booking_update_opened` have constructors but no emission
  site. Native has no remote-push surface; RN tracks them on push taps in `App.tsx`.
  They are wired when native push lands.
- `tax_settings_saved` is emitted by `commitTaxSettings`, including for an unset draft
  (RN parity).
  - No production code calls `commitTaxSettings`: native has no tax-settings editor
    (RN `TaxSetAsideCard`). The event cannot be reached until that editor exists.
  - So 49 of the 52 events are wired: every event except the two booking push opens
    and this one.

---

## 10. Redaction contract (P4, R1–R3)

### 10.1 Allow/deny table

This applies to analytics properties, Sentry events, breadcrumbs, extras, tags and
contexts, logs, and the widget snapshot.

| Data | Analytics | Sentry (event/breadcrumb/extra) | Widget snapshot | Source |
|---|---|---|---|---|
| `providerKey` (Stripe Connect backend API token) | **deny** | **deny** | **deny** | `types/models.ts:961`; `utils/storage/keys.ts:29` |
| `providerKeys` (public payment handles) | **deny** | **deny** | **deny** | `types/models.ts:971` |
| `anthropicKey`, `groqKey`, legacy `geminiKey` | **deny** | **deny** | **deny** | `types/models.ts:1036-1037`; `utils/storage/keys.ts:29` |
| RevenueCat keys (`rcAppleApiKey`, `rcGoogleApiKey`, `TradeReadyRevenueCatAPIKey`) | **deny** | **deny** | **deny** | `app.json` extra; `native/Info.plist:23` |
| Stripe secret or publishable keys, payment-link URLs with tokens | **deny** | **deny** | **deny** | |
| Supabase access, refresh or session tokens; `Authorization` headers; `BACKEND_API_TOKEN`; portal and booking tokens | **deny** | **deny** | **deny** | |
| Customer PII: names, emails, phones, addresses, notes, message bodies, review text | **deny** | **deny** | allow **only** `nextJob.customerName`, `nextJob.address`, `timer.customerName` | `utils/widgetBridge.ts` projection |
| Document bytes: invoice/estimate PDFs, receipt images, job photos, data URIs, CSV/ZIP exports; request/response bodies | **deny** | **deny** | **deny** | |
| Money amounts (`amount`, `balanceRemaining`) | allow (catalog only) | deny in extras | `outstandingTotal` only | §9.5 |
| Counts, enums, booleans in the catalog | allow | allow as tags | — | §9.5 |
| Internal record ids | allow **only** where the catalog names them (`customerId`, `jobId`, `insightId`, `ids`) | allow in extras when allow-listed (`jobId`, `invoiceId`) | `nextJob.id`, `timer.jobId` | |
| Supabase user id | `identify` only | `user.id` only | **deny** (the `ownerTag` hash only) | §9.4 |
| Email address of the signed-in user | **deny** | **deny** (no `user.email`, no `sendDefaultPii`) | **deny** | |

### 10.2 Sentry configuration (chosen; RN `App.tsx:103-114`)

- Enabled iff `!DEBUG`, the DSN (`TradeReadySentryDSN` from `TRADEREADY_SENTRY_DSN`;
  RN value at `app.json:100`, not copied) is non-empty, and the DSN does not start with
  `PLACEHOLDER`.
- `tracesSampleRate = 0.2` and `enableAutoSessionTracking = true`. These are separate
  settings; the second feeds the Phase 12 crash-free-sessions metric.
- `environment = BuildEnvironment.environment.rawValue`.
- `releaseName = <bundle id>@<CFBundleShortVersionString>+<CFBundleVersion>`.
- dSYM upload configured for org `tradeready-3r` (RN plugin at `app.json:56`). The
  project slug is chosen in 11.09; the RN slug `react-native` is not reused for native.
  **Chosen (11.09): `tradeready-ios`.** The upload is the checked-in script
  `native/scripts/upload-sentry-dsyms.sh <App.xcarchive>`, run by hand on a Release
  archive (a Phase 12 runsheet row). It no-ops with a message when `SENTRY_AUTH_TOKEN`
  is absent or `SENTRY_ORG` / `SENTRY_PROJECT` is set empty. Source bundles
  (`--include-sources`) are opt-in with `SENTRY_INCLUDE_SOURCES=1` and off by default,
  because they send app source code to Sentry (11.09 fix round 1). There is no run-script
  build phase and no token in the repo. The Sentry project `tradeready-ios` must exist in the org before the first
  upload.
- `sendDefaultPii = false`, `attachScreenshot = false`, `attachViewHierarchy = false`.
- Session replay sample rates are 0.
- `enableCaptureFailedRequests = false`, because failed-request events carry URLs that
  can contain portal/booking tokens.
- `beforeSend` and `beforeBreadcrumb` run the Foundation-only redactor
  (`NativeErrorRedaction`, 11.09):
  - drop request bodies;
  - strip URL query strings and token-bearing path segments;
  - drop any key in the deny table, matched case-insensitively and in nested dictionaries;
  - scrub email, phone and bearer-token patterns in strings;
  - cap each string at 1 KB.
- User = `{id: supabaseUserID}` only (`setUser(null)` on reset).

### 10.3 `reportError` parity (R3; RN `utils/analytics.ts:41-78`)

- If the value is an `Error`, capture it as is. Otherwise wrap it as
  `Error(describeNonError(value))`:
  - if `message` is a non-empty string: `"[<code>] <message>"` when `code` is a string or
    number, else `<message>`;
  - otherwise `JSON.stringify(value)`, else `String(value)`.
- Context entries become extras. **Native narrowing (chosen):** only the allow-listed
  extra keys pass: `context`, `operation`, `collection`, `status`, `code`, `count`,
  `jobId`, `invoiceId`, `componentStack`. Other keys are dropped.
- `rawError` extra: RN attaches the whole original object, whose `details`/`hint` may
  contain row data. Native attaches only `{code, message, hint}`, each redacted and capped.
- The ErrorBoundary analog attaches the SwiftUI context the same way (RN
  `App.tsx:652` `componentStack`).
- `Sentry.wrap(AppRoot)` has no native equivalent. SDK start happens in
  `TradeReadyNativeApp.init`.
- A reporting failure never blocks or fails a save.

### 10.4 11.09 implementation notes (2026-09-24)

**Files:** `N/NativeErrorRedaction.swift` (the redactor, `NativeSensitiveData` and the
`reportError` builder), `N/NativeCrashReporting.swift` (options, gate, adapter protocol,
reporter), `N/NativeCrashReportingSentry.swift` (the only `import Sentry`, app target
only; an addition to the plan's Own list, mirroring 11.07's `NativeAnalyticsPostHog.swift`).

**Shared screens:** the credential-prefix list, the secure-key fragments, the phone rule
and the identifier rule live in `NativeSensitiveData`; `NativeAnalyticsPrivacyPolicy`
forwards to them. The analytics key lists are unchanged.

**Gate:** as §10.2, plus a malformed DSN (not `https`, no public key, no project path, a
query or fragment) disables reporting instead of failing inside the SDK, and an
unexpanded `$(TRADEREADY_SENTRY_DSN)` counts as missing. No build configuration sets
`TRADEREADY_SENTRY_DSN`, so both committed builds report nothing until a release supplies
the DSN at build time. `debug = false`.

**Redactor, beyond §10.2 (all stricter):**
- `beforeSendSpan` also runs the redactor on span descriptions and data. Traces sample at
  0.2, and the SDK's HTTP spans carry the URL plus `http.query`/`http.fragment`.
- Request headers, cookies, query string and fragment are always removed, and
  `serverName` (the device name, often a person's name) is dropped. The user is
  rebuilt as `{id}` and only a plain identifier survives.
- URLs keep scheme, host, port and path. User info is dropped. Payment hosts (Stripe
  links, PayPal.me, Venmo, Cash App, Square) lose their whole path. A path segment after a
  capability marker (`portal`, `booking`, `book`, `pay`, `reset-password`, `t`, `p`, `e`,
  `s`, `l`, …) or a token-shaped segment (a credential prefix, or 20+ URL-safe characters
  mixing letters and digits that is not a UUID) becomes `[Filtered]`. For a non-network
  scheme (`tradeready://portal/<token>`) the host is the route, so it is checked as the
  segment before the path; `http(s)` and `ws(s)` hosts never count as markers.
- Redaction is idempotent (11.09 fix round 1): breadcrumbs pass `beforeBreadcrumb` and
  then `beforeSend`, so a `[Filtered]`, `[email]` or `[phone]` path segment from the
  first pass is kept as is, and a second pass returns identical output.
- Strings are also scrubbed of JWTs, credential prefixes, `key=value` secrets, API-key
  headers, data URIs and base64 runs of 120+ characters (`[document]`). A plain
  alphanumeric run that long is also scrubbed, which is acceptable for diagnostics.
- Deny keys add money (`amount`, `balance`, `total`, `price`, `payment`; §10.1 "deny in
  extras") and request parts (`query`, `fragment`, `header`). `data`, `name`, `text`,
  `request` and `response` are denied as whole keys; a bare `name` is kept only in the
  SDK's `os`, `runtime` and `browser` contexts. `Data` values and objects that are not
  JSON are dropped. Depth is capped at 8 and arrays at 100 items.

**`reportError` (§10.3), native narrowing:**
- The wrapped error is `NativeReportedError` (domain `TradeReady.ReportedError`), whose
  `NSDebugDescriptionErrorKey` is the title. Sentry uses that as the exception value, so
  the issue title is the real message.
- The JSON fallback is built from the value **after** redaction, so a denied key never
  reaches the title. A value that is not JSON is titled `Non-error value of type <T>`,
  because Swift's `String(describing:)` would print every stored field. The title is then
  redacted and capped.
- `rawError` is attached only for a non-nil value and is reduced to `{code, message,
  hint}`; a reduction with nothing left is dropped. RN attaches it even for `null`.
- The fingerprint is `["{{ default }}", <context>]`. Capture runs off the caller's
  thread, which makes every captured stack look alike; the context keeps call sites
  apart.
- Capture and `setUser` run on a private serial queue, so a slow SDK never blocks a save
  and a throw never reaches the caller. Order between them is kept.
- `setUser` rides the 11.08 lifecycle: `applyAnalyticsIdentityActions` pairs
  `.identify(id)` with `setUser(id)` and `.reset` with `setUser(nil)`. There is no second
  identity path.

**Call-site map:** RN calls `reportError` at about 74 sites in 28 files. Native wires the
API (`AppStore.reportError(_:context:)`) and these sites:

| RN site | Native site |
|---|---|
| `utils/sync.ts:211` `{context: 'pushQueue', failedCount, tables}` | `AppStore.applySyncStatus`: once per sync pass that ends `.failed`/`.partial`, `{code: <diagnosticCode>, message}` with `{context: 'pushQueue', count: <remaining>}` (`tables` is not an allowed extra) |
| `utils/sync.ts:312` `{context: 'pullRemote'}` | `AppStore.applySyncStatus`: once per completed push whose pull ends failed or partial |
| `screens/SettingsAccountScreen.tsx:61` `{context: 'deleteAccount'}` | `SettingsView.performDeleteAccount` catch |

The other RN sites (screen-level load/save catches, photo sync and storage, imports,
booking and payment settings, auto-invoice, subscription, PDF and logo files, and the
remaining `utils/sync.ts` contexts `trySyncNow`, `backfillLocalOnlyCollections`,
`initialSync`, `pushAllLocalToCloud`) are not mapped. Native either surfaces those
failures in the UI or folds them into the coordinator's bounded diagnostic codes. A
later task adds a site by calling `store.reportError(error, context: ["context": "<name>"])`
after the commit it describes. The SwiftUI ErrorBoundary analog (`componentStack`) has no
native trigger yet; `componentStack` stays allow-listed for it.

---

## 11. Task 11.15 — AI Assistant advanced key entry

RN behavior (`screens/SettingsAIScreen.tsx`, 65 lines):
- Hint: "AI features work automatically via our cloud service. Toggle Advanced to use
  your own API keys instead."
- An "Advanced" switch (a11y "Advanced AI settings") reveals two `secureTextEntry` fields:
  - Groq: placeholder `gsk_...`, a11y "Groq API key";
  - Anthropic: placeholder `sk-ant-...`, a11y "Anthropic API key";
  - under each: "Stored only on your device. Never share this key."
- Saved through `useSettingsDraft`.
- RN storage: `SECURE_FIELDS = ["providerKey","anthropicKey","groqKey"]` in
  expo-secure-store (`utils/storage/keys.ts:29`). The legacy `geminiKey` is migrated to
  `groqKey` (`utils/storage/settings.ts:33-41`).

Native contract (chosen):
- Store the keys with `NativeKeychainSecureSettingsStore`
  (`N/LegacyMigrationCoordinator.swift:273`). Its backend is `NativeKeychainBackend`
  (service `com.gettradereadyapp.tradeready.native`,
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), with accounts `anthropicKey` and
  `groqKey`.
  - Save = `backend.upsert(Data(utf8), key:)`.
  - Clear = `backend.remove(key:)`. An empty trimmed field counts as a clear.
- The coach already reads these accounts: `advisoryAnthropicKey`/`advisoryGroqKey`
  (`N/AppStore.swift:7789-7806`), with precedence anthropic → groq → backend in
  `N/NativeCoachTransport.swift:145`. After save or clear, 11.15 refreshes
  `coachProviderSummary` (`N/AppStore.swift:8457`).
- Owner wipe already exists: `clearAccountValues()`
  (`N/LegacyMigrationCoordinator.swift:367`) removes providerKey, anthropicKey, groqKey,
  geminiKey and the session on sign-out and deletion.
- `CanonicalSnapshot.secureSettingsKeys` (`N/Domain/CanonicalSnapshot.swift:181`)
  keeps the keys out of the canonical file.
- Redaction rule:
  - key text never enters `UserDefaults`, the App Group, the canonical snapshot, logs,
    analytics or Sentry;
  - the view shows a masked saved state (e.g. `sk-ant-…` plus the last 4 characters, or
    only "Saved");
  - `ai_chat_sent.provider` carries only the provider name;
  - 11.15's redaction test feeds a sample key through the analytics and Sentry redactors
    and asserts it is absent.

### 11.1 Implemented by 11.15 (2026-09-24): recorded native differences

- **Key shape is validated.** RN stores any string. Native stores a trimmed key only when
  it starts with the provider prefix (`gsk_`, `sk-ant-`), holds only `[A-Za-z0-9_-]` and
  is 20–512 characters. Those are the characters `NativeErrorRedaction.secretPrefixPattern`
  consumes after a credential prefix, so every storable key is redacted whole by the
  shared `NativeSensitiveData` screens; a key with a `.` or a space would leave a tail.
  Policy: `N/NativeAIProviderKeyPolicy.swift`. **Adding a provider** (fix round 1, M3)
  means updating both `NativeAIProviderKeyKind.requiredPrefix` and
  `NativeSensitiveData.secretValuePrefixes` (`N/NativeErrorRedaction.swift`); a prefix in
  the first but not the second would store a key the redaction screens do not recognize.
- **Save and Remove are explicit.** The native field never shows the saved key, so an
  empty field is not a deletion: Save is disabled for a blank field and Remove clears the
  account. The policy still maps an empty trimmed entry to a clear (above).
- **Masked display is "Saved".** RN has no masked format (its secure field redisplays the
  saved value as dots). Native shows the provider name with "Saved" or "Not set", and no
  character of the key. A Keychain read error (for example before first unlock) shows
  "Unavailable" and still offers Remove (fix round 1, M5); the coach treats an unreadable
  key as absent and routes to the backend.
- **Owner-bound writes.** A save or remove is refused unless an owner is signed in and no
  account boundary (sign-out, deletion, account switch, password recovery, a pending or
  blocked scrub) is running. `useAnotherAccount` holds `accountSwitchInFlight` for the
  whole switch, because the gate stays `.signedIn` across its awaits.
- **Store injection.** `AppStore` takes one `NativeKeychainSecureSettingsStore`
  (production: the system Keychain) for the key reads and writes, every account-scrub
  wipe, every session read and the identity activator, so the store the keys are written
  to is the store that is wiped (fix round 1, M1: no AppStore path builds its own store).
- **`$screen` hardening.** `NativeAnalyticsPrivacyPolicy.screenNameRejection` now also
  applies `containsSecret`: a 56-byte Groq key passed the route-name character check.
- **Account switch and password recovery wipe keys** (fix round 1, controller ruling
  2026-09-24; reverses the first round's "keys kept"). Provider keys are bound to their
  owner. `anthropicKey` and `groqKey`, entered or migrated, are removed through the
  injected store:
  - by `useAnotherAccount`, before its first await and again after its last;
  - by both password-recovery exits (`updateRecoveredPassword`, `cancelPasswordRecovery`),
    in `applyRecoverySignedOutState`;
  - by `dismissInvalidPasswordRecovery` when it drops an active recovery session.

  Sign-out and deletion keep wiping them through the full scrub. There are no current
  users, so no one loses a key they expect to keep.
- **Amended by Phase 12 12.00b.2-A (2026-09-25).** While that boundary wipe is pending
  (§17.2 item 5), the key rows read "Not set" without reading the Keychain and offer no
  Remove (L286.5a): the key there may be the previous owner's, and "Not set" is what a
  kind the previous owner never saved reads. The rows cache that state and refresh it on
  appear, after a save or remove, and when `isAccountBoundaryCleanupPending` (whether any
  boundary step is pending) changes, never in `body` (L205.g). That flag does not change
  when one step clears while another stays pending; the rows are still right, because a
  wiped kind reads "Not set" either way. The boundary wipe also removes the migrated
  legacy `providerKey` and `geminiKey` fields (L205.e).
- **Amended by Phase 12 12.00b.2-A review I1 (2026-09-25): owner-tagged key items.**
  - Each `anthropicKey` / `groqKey` item holds a small JSON object
    (`N/NativeAIProviderKeyOwnerTag.swift`): the key, a schema version, and an owner
    tag. The tag is the lowercase hex SHA-256 of a versioned prefix plus the verified
    account binding, the widget owner stamp's derivation with its own prefix. The item
    stores no user id, email or binding. One verified upsert writes it, so a key is
    never stored without its tag.
  - Every read (the coach's advisory keys, `aiProviderKeyIsSaved`,
    `aiProviderKeyState`) returns the key only when the tag matches the current verified
    owner. An untagged, malformed or other owner's item reads as absent ("Not set"; the
    coach routes to the backend).
  - A save needs a verified account binding; `canChangeAIProviderKeys` is false without
    one.
  - RN-era keys copied by the launch migration (`anthropicKey`, `groqKey`, `geminiKey`)
    are written before any owner is verified, so they stay untagged and read as absent
    until the owner saves a key again. No migration tags them.
  - The boundary wipe and its markers stay as defense in depth.

---

## 12. Accessibility baseline (H1)

Method: grep counts per view file under `N/` for the SwiftUI modifiers listed. A count of
0 in every column omits the file. These counts are a baseline for 11.10a; they are not a
conformance claim.

Columns: labels = `accessibilityLabel`; hints = `accessibilityHint`; traits =
`accessibilityAddTraits`; hidden = `accessibilityHidden`; fixed H/W = `.frame(height:)`
/ `.frame(width:)` with literals; `lineLimit(1)`; anim = `withAnimation`/`.animation`;
scale = `minimumScaleFactor`.

| File | labels | hints | traits | hidden | fixed H | fixed W | lineLimit(1) | anim | scale |
|---|---|---|---|---|---|---|---|---|---|
| `N/CoachView.swift` | 2 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 0 |
| `N/Components.swift` | 2 | 0 | 0 | 2 | 1 | 1 | 1 | 0 | 1 |
| `N/CustomersView.swift` | 5 | 1 | 0 | 1 | 1 | 1 | 0 | 0 | 0 |
| `N/InvoicesView.swift` | 0 | 1 | 0 | 1 | 0 | 0 | 0 | 0 | 0 |
| `N/JobsView.swift` | 1 | 0 | 1 | 0 | 0 | 0 | 3 | 0 | 2 |
| `N/MoneyView.swift` | 1 | 0 | 1 | 1 | 1 | 1 | 3 | 0 | 0 |
| `N/NativeAuthView.swift` | 1 | 0 | 0 | 0 | 5 | 0 | 0 | 0 | 0 |
| `N/NativeBookingRequestsView.swift` | 1 | 0 | 0 | 0 | 0 | 2 | 0 | 0 | 0 |
| `N/NativeBookingSettingsView.swift` | 6 | 7 | 0 | 2 | 1 | 1 | 1 | 0 | 0 |
| `N/NativeCalendarView.swift` | 17 | 6 | 0 | 1 | 1 | 1 | 0 | 0 | 0 |
| `N/NativeChangeOrdersView.swift` | 3 | 1 | 0 | 0 | 0 | 0 | 1 | 0 | 0 |
| `N/NativeCoachComponents.swift` | 2 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `N/NativeCustomerPortalView.swift` | 6 | 7 | 0 | 2 | 1 | 1 | 1 | 0 | 0 |
| `N/NativeEstimateFollowUpView.swift` | 2 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `N/NativeEstimateReview.swift` | 2 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `N/NativeExpenseEditor.swift` | 3 | 0 | 1 | 1 | 1 | 0 | 1 | 0 | 0 |
| `N/NativeExportDataView.swift` | 2 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 |
| `N/NativeGlobalSearch.swift` | 3 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `N/NativeImportView.swift` | 2 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 |
| `N/NativeInsightsCard.swift` | 3 | 0 | 1 | 2 | 0 | 1 | 0 | 0 | 0 |
| `N/NativeInteractionState.swift` | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `N/NativeInvoiceOutreachView.swift` | 0 | 0 | 0 | 0 | 0 | 1 | 0 | 0 | 0 |
| `N/NativeJobPhotosView.swift` | 3 | 0 | 0 | 0 | 1 | 1 | 0 | 0 | 0 |
| `N/NativeJobProfitabilityView.swift` | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `N/NativeMessageComposer.swift` | 2 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `N/NativeMileageLogView.swift` | 2 | 0 | 1 | 2 | 0 | 0 | 2 | 0 | 0 |
| `N/NativeMoneyCards.swift` | 2 | 0 | 0 | 1 | 18 | 18 | 4 | 1 | 2 |
| `N/NativeOnboardingView.swift` | 0 | 0 | 1 | 0 | 0 | 1 | 0 | 0 | 0 |
| `N/NativePasswordRecoveryView.swift` | 2 | 0 | 0 | 0 | 1 | 0 | 0 | 0 | 0 |
| `N/NativePaywallView.swift` | 1 | 0 | 1 | 0 | 1 | 1 | 0 | 0 | 0 |
| `N/NativePricebookEntryView.swift` | 2 | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 0 |
| `N/NativePricebookView.swift` | 2 | 0 | 0 | 1 | 0 | 0 | 2 | 0 | 0 |
| `N/NativeReviewRequestView.swift` | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `N/NativeRouteView.swift` | 2 | 0 | 0 | 0 | 3 | 2 | 1 | 0 | 0 |
| `N/NativeScheduleEditorView.swift` | 9 | 5 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `N/NativeScheduleSettingsView.swift` | 13 | 7 | 0 | 0 | 1 | 0 | 0 | 0 | 0 |
| `N/NativeSetupChecklistCard.swift` | 2 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 |
| `N/NativeTemplatePickerView.swift` | 2 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `N/NativeTimeTrackingView.swift` | 2 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `N/NativeTodayComponents.swift` | 12 | 0 | 1 | 0 | 4 | 6 | 4 | 0 | 0 |
| `N/NativeTripEditor.swift` | 2 | 0 | 1 | 0 | 0 | 0 | 1 | 0 | 0 |
| `N/SettingsView.swift` | 2 | 0 | 0 | 0 | 4 | 7 | 0 | 0 | 0 |
| `N/TodayView.swift` | 4 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `N/Domain/NativeMileageLog.swift` | 2 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

**Dynamic Type:**
- There is no `@ScaledMetric` or `dynamicTypeSize` anywhere in `N/`.
- Fixed `.font(.system(size:))` uses: `N/Components.swift` 1,
  `N/NativeBookingRequestsView.swift` 1, `N/NativePaywallView.swift` 2,
  `N/NativeRouteView.swift` 1, `N/NativeMoneyCards.swift` 2,
  `N/NativeOnboardingView.swift` 1, `N/NativePasswordRecoveryView.swift` 1,
  `N/SettingsView.swift` 1. None of these scale.
- Heaviest fixed-frame file: `N/NativeMoneyCards.swift` (18 heights, 18 widths).
- AX5 truncation risk: the `lineLimit(1)` sites in `N/NativeMoneyCards.swift`,
  `N/NativeTodayComponents.swift`, `N/JobsView.swift` and `N/MoneyView.swift`.

**Reduce Motion:** `accessibilityReduceMotion` is never read. Two animations are
unconditional:
- `N/CoachView.swift:131` (`withAnimation` scroll-to);
- `N/NativeMoneyCards.swift:133` (`.snappy` expand).

**Unlabeled icon-only buttons:** VoiceOver reads the SF Symbol name for these.
- `N/InvoicesView.swift:134` (plus)
- `N/JobsView.swift:91` (plus)
- `N/NativeRecurringInvoicesView.swift:61` (plus)
- `N/CustomersView.swift:141-144` (plus)
- `N/NativeBookingRequestsView.swift:350-357` (contact icon)
- `N/NativeRouteView.swift:52-57` (sort `Menu`, `arrow.up.arrow.down`)

The `N/TodayView.swift` calendar, search and settings buttons are labelled.

**Contrast** (WCAG relative luminance; colors from `N/Models.swift:461-467`):

| Pair | Ratio | Result |
|---|---|---|
| `tradeReady` (0.114, 0.361, 0.620) on white | 6.82 | pass AA |
| `tradeReady` on `tradeCanvas` light | 6.24 | pass AA |
| `tradeReady` on `tradeCanvas` **dark** (0.063, 0.094, 0.149) | **2.61** | **fail** (text and 3:1 UI). `tradeReady` has no dark variant and is the app-wide `.tint` (`N/TradeReadyNativeApp.swift`) |
| `tradeInk` on `tradeCanvas` light | 14.64 | pass. Only used as a gradient or a 6% overlay |
| White on `tradeReady` (filled buttons) | 6.82 | pass AA |
| RN widget: white at 0.55 opacity on navy `#0c335e` (10 pt caption) | 4.94 | pass AA, barely. The native widget must not go lower |
| RN widget: white at 0.9 / 0.75 / 0.7 / 0.6 on navy | 10.58 / 7.82 / 7.02 / 5.58 | pass |
| Navy on white (widget button) | 12.72 | pass |

**Release-blocking candidates for 11.10a:**
1. `tradeReady` tint on the dark canvas (2.61).
2. The six unlabeled icon buttons.
3. Reduce Motion ignored in two places.
4. Fixed font sizes and fixed frames that do not scale (`N/NativeMoneyCards.swift` first).

Keyboard and switch-control navigation are unaudited; they are 11.11's hardware-keyboard
rows and Phase 12 device rows.

### 12.1 11.10a audit results (2026-09-24)

11.10a re-ran the §12 inventory against HEAD `0cc4174` and fixed every release-blocking
candidate. The proof is `sh native/run-accessibility-audit-tests.sh`
(`native/AccessibilityAuditTests/main.swift`). It runs a pure contrast computation and
scans the source of every `.swift` file under `N/`. Each scan reads a construct from
its keyword to the end of its modifier chain, not a fixed window. Known sites are looked
up by marker, and a missing marker fails the run. The policy is in
`N/Domain/NativeAccessibilityAudit.swift` (palette, contrast table, Reduce Motion
policy, RN label catalog). The view helpers are in `N/NativeAccessibilityViews.swift`.

**Release-blocking findings open: 0.** H1 stays open until 11.10b re-audits after
11.11 and 11.12. **11.10b update:** see §12.3. The re-audit fixed A13 and A15–A18,
found and fixed A25–A28, and recorded A29 (success, warning and status colors used as
text). The controller ruled on A29 on 2026-09-24 and it is fixed. **H1 is closed.**

**Palette decision (native difference).** `tradeReady` is now dynamic:

- **Light:** unchanged `#1d5c9e`, RN `lightColors.accent`.
- **Dark:** `#5b9bdb`, RN `darkColors.accent`.

White text on `#5b9bdb` measures 2.93:1, so RN's dark filled buttons fail. A new
`tradeReadyFill` therefore carries every surface with white text or icons:

- **Light:** `#1d5c9e`.
- **Dark:** `#2f78c4`, native only. White text on it measures 4.56:1. Against the dark
  grounds the fill measures 3.06:1 or more, so the selected state stays visible.

The `AccentColor` asset now carries the same light and dark tint. It used to be
`(0.05, 0.53, 0.85)`, which measures 3.83:1 on white and is used by UIKit alerts.

| Pair (WCAG 2.x, computed by the host suite) | Ratio | Minimum |
|---|---|---|
| Tint text on the dark canvas `#101826` | 6.06 | 4.5 |
| Tint text on dark `systemBackground` / list row `#1c1c1e` / sheet list row `#2c2c2e` | 7.16 / 5.80 / 4.75 | 4.5 |
| Tint text on the RN dark surface `#182238` | 5.40 | 4.5 |
| Tint text on a 12% tint wash (dark canvas / dark row), `.bordered` wash | 5.09 / 4.86 / 4.84 | 4.5 |
| Tint text on the light canvas / white / light grouped / 12% wash | 6.24 / 6.82 / 6.11 / 5.69 | 4.5 |
| White text on the fill (light / dark) | 6.82 / 4.56 | 4.5 |
| Fill as UI on the dark canvas / black / `#1c1c1e` / `#2c2c2e` | 3.91 / 4.61 / 3.74 / 3.06 | 3.0 |
| Today hero subtitle: solid white caption on the fill (light / dark); it was 85% white, which measured 3.76 on the dark fill | 6.82 / 4.56 | 4.5 |
| Today hero icon: white on an 18% white disc over the fill (light / dark) | 4.53 / 3.34 | 3.0 |

The scanner's label check (tightened in fix round 1, m2) counts only a non-empty
`.accessibilityLabel` on the control's own modifier chain or inside its label closure. A
labelled `Button` nested in an icon-only `Menu`'s content no longer labels the `Menu`. An
animation must pass the environment's `reduceMotion` to the policy, not a literal.

Tint text on the elevated tertiary ground `#3a3a3c` measures 3.87:1. No `N/` view puts
tint text on that ground, so this is recorded only.

| # | Finding (§12 or found by the 11.10a scan) | Disposition | Evidence |
|---|---|---|---|
| A1 | **Blocking 1.** `tradeReady` measured 2.61:1 on the dark canvas | **Fixed:** dark variant plus `tradeReadyFill` (above). 24 `.borderedProminent` buttons now use `tradeReadyProminentButtonStyle()`. The clock-in button re-tints to the fill. 13 opaque fills under white text were moved to the fill: 8 chips, the selected week day, the Today hero, the "Schedule a Job" button, the working-day toggles and the Settings avatar gradient. `AccentColor` was aligned | Contrast table, palette literals parsed from `N/Models.swift` and the asset JSON, no raw `.borderedProminent`, opaque tint fills only on the allow-listed chart bars and dots |
| A2 | **Blocking 2.** Six unlabeled icon buttons | **Fixed.** RN labels: "Add new invoice", "Add new job", "Add maintenance plan", "Add new customer". Booking contact: "Call/Text/Email {name}", following RN `CustomerDetailScreen` (Text is native only). Route order `Menu`: "Route order options" (native only; RN has a text button) | Icon-only scan (0 unlabeled). The six sites are found by marker. The catalog is checked against the RN `accessibilityLabel` text in the working tree |
| A3 | Found by the scan: the route "move stop" chevrons were unlabeled, with glyph-sized targets | **Fixed.** RN labels "Move stop up" and "Move stop down", with a 44×44 target | Scan plus touch-target check |
| A4 | **Blocking 3.** Reduce Motion was ignored: the `CoachView` scroll-to and the `NativeMoneyCards` section expand | **Fixed.** `NativeAccessibilityAudit.allowsCustomMotion(reduceMotion:)`. With the setting on, the change happens without animation | Every `withAnimation`/`.animation(` in `N/` must pass through the policy. Both sites are found by marker |
| A5 | **Blocking 4.** Fixed fonts and frames did not scale | **Fixed:** all ten non-widget `.font(.system(size:))` literals now use `@ScaledMetric` or `.largeTitle`. Money cards: the 110pt expense-trend chart no longer clips its labels; the rank, count and icon columns scale; seven multi-column rows stack at AX sizes (`NativeAccessibilityAdaptiveRow`) instead of shrinking or truncating amounts. The Today stats, Jobs stats and Invoices metrics rows also stack. The auth and recovery submit buttons use `minHeight: 48`. Customer initials, the week-strip day circles and the `SettingsRow`/`MetricCard` badges scale | No fixed-point font outside `N/Widgets/`, `@ScaledMetric` present per file, site checks |
| A6 | Found: the working-day toggles were 36pt tall, and the week-strip arrows were glyph-sized | **Fixed:** 44pt minimum | Touch-target checks |
| A7 | Found (step 4): the auth email field showed "Next", which did nothing. The recovery "New password" field had no return action | **Fixed:** `@FocusState`. Email Next moves to the password (Go still sends a reset). Show/Hide keeps focus. New password Next moves to confirmation, then Go submits. RN uses "done" (dismiss) on email, so this is a native difference | Focus checks |
| A8 | Week strip at AX2–AX5: seven day columns and two arrows cannot grow further on a phone | **Retained by design:** capped at `.accessibility1`. VoiceOver reads each day in full. A long press shows the Large Content Viewer for the days and arrows. **Fix round 1 (I1):** the day circle's `@ScaledMetric` sat on the strip, outside the cap, so it reached about 98pt at AX5 and pushed the arrows off-screen. The metric now lives in a day view inside the capped subtree, and the circle is clamped to 34pt (`NativeAccessibilityAudit.WeekStrip`). Seven 34pt columns fit beside both 44pt arrows on a 375pt phone: each column gets 35.3pt | Cap, placement and clamp checks; Phase 12 AX5 row |
| A9 | Widget views (`N/Widgets/Shared/*`) use fixed-point fonts | **Retained:** fixed widget canvas, matching RN `targets/widget`. Owned by 11.02/11.03 | Scan exempts only `N/Widgets/`; Phase 12 widget AX row |
| A10 | Remaining `lineLimit(1)` sites: names, notes, addresses, links, job titles | **Retained:** truncating a name or address does not lose meaning in a list row, the detail screen shows the full text, and VoiceOver reads it in full. The amount sites that could lose meaning now stack | Reviewed |
| A11 | Hardware-keyboard shortcuts and iPad keyboard commands | **Done by 11.11** (§12.2): Esc on every toolbar Cancel/Done/Close, ⌘S on every toolbar save, ⌘⏎ on the change-order Confirm, ⌘N on the five existing toolbar "new" actions (gated: never while the owner presents anything or has a screen pushed over it; fix round 1), no shortcut on the destructive delete, no custom command menus (RN has none). Tab traversal is the system focus order; return-key chains beyond auth and recovery stay A24 (11.10b) | `native/run-layout-metrics-tests.sh` keyboard checks; Phase 12 rows IPAD-KB-1 and IPAD-KB-2 |
| A12 | Reading order: static review found no layered text out of order. The one layered text view, the calendar timeline, is already hidden from VoiceOver. No `accessibilitySortPriority` was added | **Deferred to device** (Phase 12 VoiceOver rows) | — |
| A13 | Today job card: an "On my way" button nested inside the card button. Its VoiceOver reachability can only be confirmed on a device | **Fixed in 11.10b** without waiting for the device. The card also offers "On my way to {name}" (the RN `TodayScreen` label) as a VoiceOver custom action, so it is reachable whether or not the nested button is its own element. Device proof stays in A11-VO-2 | `testReAuditSites` (card action, RN label parity) |
| A14 | **Corrected in fix round 1 (I3).** Money cards with `onOpen` used the label "{title}, open", which hid their figures from VoiceOver. The first pass said RN does the same, but only RN `TaxSetAsideCard` sets a label ("Tax set-aside — open settings"). RN `MileageCard` and `PricebookCard` set none, so RN VoiceOver reads their figures, and native was a regression | **Fixed:** an openable card with no RN label combines its text into one button element (`.accessibilityElement(children: .combine)` plus the button trait), so the title and figures are read. The tax card uses RN's exact label, with the reserve as the accessibility value. The native tax card has no open action today, because native has no tax-settings screen yet. It stays a static card that VoiceOver reads in full, and the RN label and value take effect when a destination is wired | Catalog parity (`taxSetAsideOpen` against RN), RN no-label checks for Mileage and Pricebook, branch checks in `NativeMoneyCard` |
| A15 | The Money charts (monthly, seasonal, expense trends) have no accessibility summary; VoiceOver reads each month letter separately | **Fixed in 11.10b.** Each bar area is one element labelled "{title} chart". Its value reads every month with its figures, for example "April: Income $1,200.00, Expenses $300.00. …". Expense trends add "down 12% from the previous month". The legends are hidden because the value names each series. Native only: RN charts have no accessibility label | `testChartSummaries` (pure summary text plus the three card sites) |
| A16 | Cosmetic fixed icon frames: `MoneyView` category badge, `SettingsView` sync-status badge and avatar, Today hero circle, job-photo thumbnail, route index column, booking-request kind column (56pt; text wraps at AX5) | **Fixed in 11.10b.** The badges, the avatar (capped at 96pt), the hero disc and the photo thumbnail use `@ScaledMetric`. The thumbnail is clamped to 112–168pt by `NativeAccessibilityAudit.PhotoThumbnail`. The route number and reorder columns use minimum widths. At AX sizes, the booking kind column and the Today schedule time column (52pt, found by the re-audit) move above their row. Every remaining literal width of 20pt or more is on a reviewed allowlist with its reason | `testFixedFrames` (no fixed square of 20pt or more, per-file width allowlist, site checks) |
| A17 | The job-photo error badge is not announced | **Fixed in 11.10b:** the thumbnail's accessibility value is the error text | `testReAuditSites` |
| A18 | The clock-out `.borderedProminent` uses system red: white on dark `#ff453a` measures about 3.4:1 | **Fixed in 11.10b** with `tradeDangerFill`. Light is `#b8432b` (RN `lightColors.danger`; white text 5.42:1). Dark is `#cc4a30` (native only; 4.58:1) | Contrast table rows, palette literals parsed from `N/Models.swift`, the time-tracking tint check |
| A19 | Switch Control, full VoiceOver, AX5 layout, Increase Contrast | **Deferred to device** (Phase 12; runsheet rows in the plan's 11.10a entry) | — |
| A20 | Found in fix round 1 (I2): the Today hero subtitle was `.white.opacity(0.85)` on the fill, which measured 3.76:1 in dark mode | **Fixed:** solid white. No translucent white foreground remains outside `N/Widgets/` | Contrast rows above; the translucent-white scan |
| A21 | Found in fix round 1 (m3): glyph-sized icon buttons, namely the undo banner's dismiss `xmark` and the time-off `trash` in Schedule settings | **Fixed:** 44×44 target | Touch-target checks |
| A22 | Fix round 1 (m4): the 44pt route move chevrons are stacked, so a middle stop's row grows from about 50pt to about 116pt at the default size | **Accepted in 11.10b, with rationale.** RN `RouteScreen` stacks its move buttons the same way (`reorderCol`: 32pt buttons with a 6pt gap), so the stacked column is parity, and 11.11 did not change it. The native column now has a 44pt minimum width instead of a fixed one, so the stop number can grow. Row density is the cost of reliable targets. A drag-to-reorder list would be a new interaction that RN does not have | Phase 12 A11-TT-1 |
| A23 | Fix round 1 (m5): Show/Hide on the password swaps the field and could lose focus in the same update | **Mitigated:** the refocus now runs on the next main-actor turn. Device proof is in the A11-KB-1 and A11-SC-1 rows | Focus check |
| A24 | Fix round 1 (m6): step 4 audited the return-key and focus chains of the auth and recovery forms only | **Resolved in 11.10b.** *Return keys:* RN `Field` gives every single-line input "done", which dismisses the keyboard, and has no Next chains in the editors. A single-line SwiftUI field ends editing on Return the same way, so no chain is added. The scan fails any Next or Continue key without an `.onSubmit`. *Keyboard dismissal:* pad and multi-line keyboards have no key that dismisses them. RN mounts `KeyboardDoneBar` for them ("Done", labelled "Dismiss keyboard"). Native now has `.nativeKeyboardDoneBar()` on all 25 screens with such a field, and the scan fails a new one without it | `testReturnKeysAndDismissal`, `testRunnersCompileDoneBar` |
| A25 | Found by 11.10b: the Today card's "On my way" link was glyph-sized (RN pads it with `hitSlop` 8) | **Fixed:** a 44pt minimum target. **Fix round 1 (m7):** the first fix grew the card's status row to 44pt. Now the hit shape is padded 16pt above and below and the padding is taken back out of layout, like RN's `hitSlop`, so the row keeps its height. The width stays at least 44pt, and the smallest caption line (13pt) plus the outsets is 45pt (`NativeAccessibilityAudit.InlineLink`) | `testReAuditSites` (outset pattern, no `minHeight`, the 44pt sum) |
| A26 | Found by 11.10b: the route map's stop number was white text directly on the map tiles | **Fixed:** it sits on a `tradeReadyFill` capsule (4.56:1 or better) | `testReAuditSites`, contrast row |
| A27 | Found by 11.10b: the route preview's loading and empty bands were a fixed 200pt, which clips AX5 text | **Fixed:** 200pt minimum height | `testFixedFrames` |
| A28 | Found by 11.10b: error, validation and destructive text used system red. It measures 3.55:1 on a white list row in light mode and 4.09:1 on a dark sheet row. The danger money tone, the booking "Cancelled" kind, overdue amounts and the coach error wash used it too | **Fixed** with `tradeDangerText`, still RN's rust hue. Light is `#a63c27`: RN `lightColors.danger` `#b8432b` darkened by A29, because `#b8432b` measured 4.05:1 on a 13% status wash over the grouped background. It is now 6.36:1 on white and 5.70:1 on grouped gray. Dark is `#ee917a` (native only): 5.94:1 on `#2c2c2e`, where RN's `#e06a4f` measures 4.21:1. Every pair holds at least 4.71:1, washes included. **Corrected in fix round 1 (I1).** The first pass removed every `.red` token but missed the `role: .destructive` buttons the app draws itself, which still rendered system red text (3.55:1). There are 12: Delete customer, the AI key Remove, Sign out and Delete account in Settings, the Delete account sheet's toolbar Delete, the paywall Sign out, Delete expense, Remove receipt photo, Delete trip, Delete service, the job-photo trash, and the bordered booking Decline. The Decline was the worst, red on a red wash at 2.90:1. Each keeps its role for VoiceOver, and its label takes `.nativeDestructiveText()`: `tradeDangerText`, or the secondary color while disabled. It is applied inside the label, so the button style's red does not win. The Decline also tints its `.bordered` wash with `tradeDangerText`. Danger text holds at least 4.54:1 on that 15% wash, and on a 15% system-red wash, over the white, grouped and dark list rows. Destructive buttons in alerts, confirmation dialogs, swipe actions and context menus are system-drawn (A31) | `testDangerText` (no `.red`/`Color.red` token); `testSemanticColors` §7 (every `role: .destructive` is in a system-drawn container, a dialog-only helper whose calls are checked, or a `.nativeDestructiveText()` label; 12 in-row buttons pinned), contrast rows, palette literals |
| A29 | Found by 11.10b: success, warning and status colors used as text measure below 4.5:1 on white in light mode. System green is 2.22, orange 2.20, mint 2.12, cyan 2.54, blue 4.02 and purple 4.13, across about 110 uses (Money tones, job status pills, overdue and lead counts, booking kinds). Dark mode passes. RN has the same class of failure: `lightColors.success` 4.20, `warning` 3.21 and most `status*` colors 2.15–3.68 | **Fixed (native difference; controller ruling 2026-09-24).** Parity does not extend to inaccessible colors, the same precedent as the 11.10a dark fill. Seven dynamic text tokens replace the system hues: `tradeSuccessText` `#1d6d31`/`#30d158`, `tradeWarningText` `#8c5200`/`#ff9f0a`, `tradeInfoText` `#005cc1`/`#5daeff`, `tradeMintText` `#006b67`/`#63e6e2`, `tradeIndigoText` `#5250c7`/`#a3a2f1`, `tradePurpleText` `#863faa`/`#d38ef6` and `tradeCyanText` `#1e6688`/`#64d2ff` (light/dark). Each light value keeps the system hue, darkened. Each dark value is the system dark color where that passes; blue, indigo and purple are lightened. Every text token, `tradeDangerText` included, holds at least 4.70:1 on white, grouped gray, the canvas and its own 13% wash over each in light mode. In dark mode it holds at least 4.71:1 on black, `#1c1c1e`, `#2c2c2e`, the dark canvas, RN's surface and the washes. Non-text uses (status dots, the retention bar, the calendar conflict block, check glyphs) take the same tokens, because system green, orange, mint and cyan fail even 3:1 on white. Swipe actions drew white on system green, orange and red (2.22, 2.20 and 3.55:1). They now use `tradeSuccessFill` `#22833b`/`#23873c`, `tradeWarningFill` `#a76200`/`#ac6400`, `tradeReadyFill` and `tradeDangerFill`. Every one is at least 4.55:1 under white, and each dark fill is at least 3:1 on the dark rows | `testSemanticColors`: palette literals parsed from `N/Models.swift`, generated contrast rows, no system hue in a non-widget view (the `.mint` portal action is matched per use by its call shape), foreground styles carry only text tokens, fills appear only inside tint, background, fill or overlay calls (a helper returning one fails), no text token as a tint, every swipe button tinted with a fill, and washes at or below 13%. **Fix round 1:** the hue scan also catches UIKit spellings (`Color(.systemGreen)`, `UIColor.systemRed`, `Color(uiColor: .systemOrange)`) (m3). The `.mint` action is matched per use by call shape, not counted per file (m4). A fill may tint only a swipe action or a `.borderedProminent` chain, and a text token only a `.bordered` chain (m2). Every literal opacity above 13% in any context, helper or trailing closure, must be a reviewed non-text or proven use (m1; the coach user bubble's 18% wash under primary text now has rows). The mutations are in the plan §7 log |
| A30 | Found by the 11.10b review (m5): the invoice PDF's status stamps and accent measure below 4.5:1. PAID green on its tint is 2.90:1, OUTSTANDING orange 3.09:1, PARTLY PAID blue 4.28:1, and the `#007aff` accent on white 4.02:1 (`N/NativeInvoicePDF.swift`, the stamp colors and `accent`; `N/NativeEstimatePDF.swift` shares the accent) | **Fixed in 11.13 (native difference).** Both renderers now take every color from `NativeAccessibilityAudit.DocumentPalette` (`N/Domain/NativeAccessibilityAudit.swift`), and no `UIColor(red:` literal remains in either file. The accent is the light information text color: 6.37:1 on white and 5.91:1 on the total wash. The stamps use the semantic text colors on their unchanged fills: PAID 5.86:1, OUTSTANDING 5.74:1 and PARTLY PAID 5.67:1. All 13 `documentContrastRequirements` pairings meet their role minimum. RN `utils/pdfTemplates.ts` keeps the failing hues: `#007aff` measures 4.02:1, `.badge-paid` 2.88:1, `.badge-unpaid` 3.12:1 and `.badge-partial` 4.33:1. The darker native text is therefore a recorded native difference. These are printed documents outside H1's app-view scope, so A30 never blocked H1 | `testDocumentPDFContrast` in `native/AccessibilityAuditTests/main.swift`: the old literals and RN's hexes fail, and every palette pairing passes. Same WCAG math as the rest of the suite |
| A31 | Destructive buttons inside alerts, confirmation dialogs, swipe actions and context menus render system red on the system's own material | **Accepted: system-owned.** iOS draws these containers, and the app cannot restyle an alert or dialog button. The swipe actions already take `tradeDangerFill` under white (A29). Helpers that only feed dialogs (`bookingAlertActions`, the insight `optionsActions` and `muteButtons`, and the change-order `actions(for:)`) are listed, and each call site is checked | `testSemanticColors` §7 |


### 12.2 11.11 iPad layouts, multitasking, rotation and hardware keyboard (2026-09-24)

11.11 adds the native analog of RN `layout.contentColumn` (`utils/theme.ts`:
`{ width: "100%", maxWidth: 700, alignSelf: "center" }`) and applies it to every list,
form and scroll screen. The proof is `sh native/run-layout-metrics-tests.sh`
(`native/LayoutMetricsTests/main.swift`). The policy is in `N/NativeLayoutMetrics.swift`:
the width math is Foundation-only, and the two SwiftUI modifiers in the same file compile
wherever SwiftUI exists (the app, and the macOS host runners that compile view files; the
suite checks that each such runner also compiles the policy file). The host suite shares
the 11.10a source model, which moved unchanged to
`native/HostTestSupport/SwiftSourceScan.swift`.

**Constants (chosen):**

| Name | Value | Source |
|---|---|---|
| `NativeLayoutMetrics.contentMaxWidth` | 700pt | RN `layout.contentMaxWidth`; the suite reads `utils/theme.ts` and fails if either value changes |
| `NativeLayoutMetrics.listMinimumSideInset` | 20pt | The system's regular-width row inset. A list column only engages once its margin clears the safe area plus 20pt, so the row edge never jumps inward |

**Column rule (chosen).** The rule is width-only and never reads the size class, like RN.
A container at or below 700pt keeps the system layout (full width). A wider one centers a
700pt column, and its scroll area, scroll indicators and background stay full width.
SwiftUI measures the two container kinds differently. These were measured with a
throwaway probe app on the iOS 26 Simulator (iPad Pro 11-inch and iPhone 17 Pro Max):

| Kind | Modifier | SwiftUI behavior (measured) | Margin |
|---|---|---|---|
| `.list` (`List`, `Form`) | `.nativeContentColumn(.list)` → `contentMargins(.horizontal, m, for: .scrollContent)` | Replaces the row inset (a margin of 0 goes edge to edge; `nil` keeps the default) and is measured from the outer edge; the row edge lands at `max(safe-area inset, m)` | `(width + safe areas − 700) / 2`, used only when ≥ max safe inset + 20; else `nil` |
| `.scroll` (`ScrollView`) | `.nativeContentColumn(.scroll)` | Added inside the safe area; content keeps its own padding inside the column | `(width − 700) / 2` when width > 700; else `nil` |
| Fixed chrome | `.nativeContentColumnFrame()` | `frame(maxWidth: 700)` then `frame(maxWidth: .infinity)`; a background applied after it stays full width | — |

Measured results with the modifier: iPad 11-inch portrait (834pt): list rows 67…767 (700pt)
and scroll content 83…751 (668pt, a 700pt column less 16pt padding). iPhone 17 Pro Max
landscape (956pt, 62pt safe areas): list rows 128…828 (700pt) and scroll content 144…812
(668pt). iPhone portrait (440pt): unchanged from before. `safeAreaPadding` was rejected
because a `List` ignores it horizontally.

**Screen disposition.** The suite holds an exact inventory. A missing target screen, an
unknown new scroll root, a wrong kind or a column placed only on a nested view fails the run.

| Group | Screens | Disposition |
|---|---|---|
| Tab roots (8 roots) | Today (`ScrollView`), Jobs, Invoices, Customers (`List`), Money (overview `ScrollView`, expenses `List`), Coach (empty and transcript `ScrollView`s) | Column applied |
| Detail and list screens (11 roots) | Job, invoice and customer detail; mileage log; pricebook; export; import; booking requests; recurring invoices; Settings hub (`ScrollView`) and all 12 `SettingsPage` screens through the shared `SettingsPage` `Form` | Column applied |
| Sheets, editors and other secondary screens (34 roots) | Job, invoice, payment, customer, merge picker, expense, trip, pricebook entry, pricing calculator, change order (editor, decision, review), estimate review and follow-up, invoice from job, outreach, on-my-way and appointment review, review request, recurring job and invoice editors, recurring jobs, schedule editor and settings, booking settings, customer portal, template and job pickers, global search, calendar (day and week), route, job profitability "What changed", delete-account confirmation | Column applied. An iPad sheet is usually narrower than 740pt, so the column is a no-op there, but it caps a large Stage Manager sheet |
| Auth gate (5 roots) | Sign-in, password recovery, paywall, onboarding, starting point (`ScrollView`) | Column applied; the existing 520pt (auth, recovery) and 560pt (paywall, onboarding) form cards are retained inside it |
| Fixed chrome (12 sites) | Coach composer; Money date chips and Overview/Expenses picker; calendar mode picker and day/week bar; sync banner; undo banner; Invoices bulk-select bar; onboarding footer; route map preview, its loading band and its no-address state | `.nativeContentColumnFrame()` |
| Horizontal chip rows (10) | Jobs, Money, expense editor (2), export, import, job photos, mileage log, outreach, trip editor | Exempt: they scroll sideways inside a capped parent, and the suite fails if one takes a column margin |
| Not scroll screens | Root gate states (`ContentUnavailableView`, `NativeContentStateView`), the job-photo viewer | Centered or full-bleed by design |

**Navigation (chosen; no NavigationSplitView).** RN is a phone-style bottom-tab app that
centers a 700pt column on iPad. It has no sidebar, split view or iPad-specific navigation.
Native keeps the one `TabView` from `RootView` with six tabs and one `NavigationStack` per
tab, in every size class and orientation. A split view would add a navigation structure RN
does not have and would duplicate the tab bar's destinations. The suite enforces the rule:
exactly one `TabView`; no `NavigationSplitView`, `NavigationView`, `.tabViewStyle` or
`sidebarAdaptable`; and every view whose body is a `NavigationStack` is a tab root, an
auth-gate root or a presented sheet, never pushed. A pushed stack is what shows two
navigation bars after a rotation or size-class change. Stacks built inside a type's own
`.sheet` closure are recognized as presented.

**Multitasking manifest (checked, unchanged).** `native/Info.plist` declares all four
iPad orientations, a `UILaunchScreen`, and iPhone portrait plus both landscapes. It has no
`UIRequiresFullScreen`, and every target builds for device family `1,2`. Split View and
Slide Over are therefore available. `UIApplicationSupportsMultipleScenes` stays `false`:
multitasking needs no second scene, and RN is a single window. No capability was added.

**Fixed widths and keyboard avoidance (checked).** `N/` has no `UIScreen` sizing (wrong
under Split View) and no `.ignoresSafeArea(.keyboard)`, so SwiftUI keeps its default
keyboard avoidance. No fixed `width:`, `minWidth:` or `idealWidth:` literal reaches 320pt
(the Slide Over width). The only `maxWidth:` literals of 300pt or more are the four
allowlisted form cards above. The Settings hub's hand-rolled `.frame(maxWidth: 700)` was
replaced with the shared column. The Coach composer sits below its transcript in a
`VStack`, so it rises with the keyboard.

**Hardware keyboard (A11, chosen).** The shortcut policy applies only to toolbar actions
that already exist. It adds no custom command menus, because RN has none.

| Toolbar action | Shortcut | Sites |
|---|---|---|
| Any `.cancellationAction` button (Cancel, Done) | Esc (`.cancelAction`) | 27 |
| A `.confirmationAction` button that only dismisses (Done, Close) | Esc (`.cancelAction`) | 4 |
| A `.confirmationAction` save (Save, Save Changes/Add Trip, the change-order save label, the shared `DismissableFormToolbar` Save) | ⌘S | 9 |
| The change-order decision Confirm | ⌘⏎ | 1 |
| Existing toolbar "new" actions: add job, add invoice, add customer, add maintenance plan, Coach "New chat" | ⌘N, gated (below) | 5 |
| The destructive delete-account confirmation | none (a destructive action is never one keystroke) | 1 |

Total: 46 shortcuts. Rules the suite enforces: every `.keyboardShortcut` in `N/` is one the policy checked, and
`N/` has no `CommandMenu`, `CommandGroup`, `.commands` or `UIKeyCommand`. Every
`.confirmationAction` title is classified in the suite's policy table; an unlisted title
fails rather than defaulting to ⌘S. Sending
(estimates, invoices, messages, Coach) gets no shortcut; those are form buttons, not toolbar
actions. **Tab/Return audit:** 25 files hold text inputs. Tab and Shift-Tab move through
them in the system focus order, and `N/` never disables focus (the suite fails on
`.focusable`, `.focusDisabled` or `.focusEffectDisabled`). Return in a single-line
field ends editing, and in the Coach composer (vertical axis) it inserts a newline. Only the
auth and recovery forms have return-key chains (11.10a A7). The other editors' chains stay
A24 for 11.10b.

**⌘N gating (fix round 1, chosen).** A SwiftUI toolbar shortcut stays live while its view
presents a sheet or dialog, and a root's toolbar shortcut stays live under a screen pushed
without a path. Both were measured on the iPadOS 26.5 Simulator with hardware-key input
(a throwaway probe mirroring these structures; ⌘J canary to prove delivery):

| Situation (ungated) | Measured | Gated result |
|---|---|---|
| ⌘N with the maintenance-plan edit sheet open | The list's "+" fired and the open editor's plan became `nil`, so Save would create a second plan | ⌘N does nothing; the canary lands in the editor |
| ⌘N on Maintenance plans pushed on the Invoices stack | The hidden Invoices "+" fired (a new invoice), not the visible plans "+" | The plans "+" fires |
| ⌘N with a `TabView`-level sheet up (RootView's notices) | Nothing on the tab fired; the canary landed in the sheet | Same |
| Esc with a SwiftUI or UIKit child sheet over an editor | Only the child dismissed; the editor's Cancel did not run | Same |
| Esc in a sheet with `interactiveDismissDisabled` | The sheet's `.cancelAction` Cancel ran | Same (the delete-account Cancel is disabled while deleting) |
| Tab away and back | Root visibility restored; ⌘N fires | Same |

Rule: each ⌘N owner declares `isPresentingAnything` (every state that drives one of its
sheets, dialogs, alerts or confirmations, plus the Invoices bulk-reminder queue between
sheets) and `newShortcut`, which is `nil` while anything is presented, while its
`NavigationStack` path is non-empty, or while its root is not visible (`isRootVisible`, kept by
`onAppear`/`onDisappear` on the root, which covers pushes that the path does not record). The
action also starts with `guard !isPresentingAnything`. The suite reads every presentation in
each owner and fails if its driving state is not gated, if a presentation's driver cannot be
read, or if the path or root-visibility gate is missing. The maintenance-plan editor also
moved to one `sheet(item:)` carrying the plan: with `sheet(isPresented:)` plus a separate
`editingRule`, the probe opened "Edit" with a `nil` plan (the create form) whenever the body
did not otherwise read that state.

**Recorded native differences (11.11):**

1. **List rows.** RN's 700pt column includes its 16pt horizontal padding, so cards are
   668pt. A native `List`/`Form` row is 700pt with the system 20pt text inset, so text is
   660pt. `ScrollView` screens match RN exactly: 668pt content in a 700pt column.
2. **Form-card caps retained.** Sign-in and recovery stay at 520pt, and the paywall and
   onboarding at 560pt, inside the 700pt column. RN uses 700pt for these screens. The
   narrower cards predate 11.11, are not stretched, and are allowlisted by the suite.
3. **Settings hub.** Before 11.11 the content was 700pt with 16pt padding outside it; now
   the 700pt column includes the padding (RN semantics).
4. **Chrome backgrounds.** RN caps the chat input row and the onboarding footer including
   their background. Native caps the content and keeps the bar background full width. The
   sync banner, undo banner and Invoices bulk-select bar are capped the same way (RN has
   no direct equivalents).
5. **Calendar.** RN `CalendarScreen` does not use `contentColumn`. Native caps the calendar
   sheet anyway, which is a no-op unless the sheet is wider than 740pt.
6. **Tab bar placement.** On iPadOS 18 and later, a regular-width `TabView` draws its tab
   bar at the top. This is the system presentation for the same six tabs. RN draws bottom
   tabs. The navigation structure is unchanged.
7. **Keyboard shortcuts** are native only (RN has none).
8. **Column engagement at 740pt for lists.** A list column engages at 740pt (700 plus two
   20pt insets), and a scroll column at 700pt. Between 700pt and 740pt a list keeps the
   system inset, so its rows are 660–700pt wide.

**Not changed by 11.11 (controller ruling):** A16 (cosmetic fixed icon frames), A22 (the
stacked route chevrons) and A24 (other editors' return chains) stay with 11.10b.

**Device proof (Phase 12; not claimed):** runsheet rows IPAD-L-1 to IPAD-L-4, IPAD-MT-1 to
IPAD-MT-3, IPAD-ROT-1, IPAD-KB-1, IPAD-KB-2 and IPAD-AX-1 are listed in the plan's 11.11
execution-log entry. They include confirming the measured `contentMargins` behavior on the
iOS 17 floor, since the probe ran on the iOS 26 runtime.

---

### 12.3 11.10b accessibility re-audit (2026-09-24)

11.10b re-audited HEAD `7da61a2`, after 11.11 (`e8db202..dc305bd`) and 11.12
(`c4e040a..7da61a2`). It resolved the §12.1 items handed forward and extended the 11.10a
scanner. The proof is still `sh native/run-accessibility-audit-tests.sh`.

**Release-blocking findings open: 0. H1 is closed.** A29 was fixed after the controller ruling of 2026-09-24. Fix round 1 then fixed the in-row destructive buttons that the A28 pass had missed (I1). A30, the PDF stamps, was outside H1's app-view scope; 11.13 fixed it (§12.1). A31 is accepted as system-owned.
Every other §12.1 row is fixed, accepted with a rationale, or a Phase 12 device row
(A12 and A19).

**Scanner coverage.**
- The suite pins an inventory of the 59 files that declare SwiftUI UI: `View`,
  `ViewModifier`, a representable, `App`, `Widget` or `ToolbarContent`.
- The inventory covers every such file under `N/` and the widget extension's own files
  in `native/TradeReadyWidgets/`, which the 11.10a scans did not load.
- A new view file fails the run until it is reviewed and added to the inventory, and so
  does a file that disappears. The icon-only, shortcut, translucent-white and fixed-frame
  scans now include the widget target.

**Regressions checked in 11.11 and 11.12.**

| Check | Result |
|---|---|
| Do keyboard shortcuts change VoiceOver labels? | No. `.keyboardShortcut` does not touch the accessibility label, and every labelled control keeps its label. |
| Do the ⌘N "+" buttons have a title for the iPad shortcut HUD (hold ⌘)? | They did not, which was a regression. The four buttons now use `Label(<RN label>, systemImage: "plus")` with `.labelStyle(.iconOnly)`. The scan requires a text title on all 46 shortcut controls. |
| Does the content column (`nativeContentColumn`, `contentMargins`, `frame(maxWidth:)`) clip at AX5? | No. It limits width only and never height, and the AX stacking rows are unchanged. |
| Did 11.11 or 11.12 add controls without labels? | No. The icon-only scan finds no unlabelled control. |
| Did they add animations? | No new animation. The Reduce Motion scan still passes. |
| Did they add focus changes? | No new `.focusable`, `.focusDisabled` or `@FocusState`. |
| Where do the 11.11 Money picker label and the 11.12 signposts sit? | The Money picker label sits after the column frame. The 11.12 signposts wrap computed properties only, with no view-tree change. |
| New contrast pairs? | None from 11.11 or 11.12. The re-audit found A26, A28 and A29 in older code. |

**Native differences recorded.**
- **Done bar scope.** The keyboard Done bar belongs to the screen in SwiftUI, so it also
  shows above that screen's text keyboards. RN shows it for pad and multi-line inputs
  only. It only adds a way to dismiss the keyboard.
- **Return key.** Single-line fields show "return", not "Done". They behave like RN's
  "done": editing ends.
- **Chart summaries.** These are native only.
- **Dark danger colors.** `tradeDangerFill` `#cc4a30` and `tradeDangerText` `#ee917a` are
  native only. RN's dark `#e06a4f` fails under white text and on the sheet list row.
- **Error text color.** Error text moved from system red to RN's rust, darkened in light
  mode to `#a63c27` so it holds on the status washes (A29).
- **Semantic text colors (A29).** Success, warning and status text uses native tokens:
  the system hue darkened in light mode, and lightened in dark mode for blue, indigo and
  purple. They are not RN's `lightColors.success`, `warning` or `status*` values, which
  fail text AA too (2.15–4.20:1). WCAG AA text contrast is a release requirement, and
  parity does not extend to inaccessible colors.
- **Swipe-action fills (A29).** The swipe actions use the fill tokens, not system green,
  orange, blue and red.
- **Destructive button labels (fix round 1, I1).** Destructive buttons the app draws use
  the rust `tradeDangerText`, not system red. RN draws its danger buttons in
  `colors.danger`, so this is closer to RN. Alert and dialog buttons stay system red
  (A31).
- **"On my way" target (fix round 1, m7).** The target is padded like RN's `hitSlop`
  without growing the card.

## 13. Device matrix (H2–H4; roadmap verification deferral 2026-09-16)

| Row | Owner | Notes |
|---|---|---|
| Host suites (`sh native/run-all-domain-tests.sh`, `TZ=America/Phoenix`) | **11.13 / 11.14** | Includes every new Phase 11 runner (ruling P9) |
| Unsigned generic Release build (`xcodebuild … CODE_SIGNING_ALLOWED=NO`) with the widget extension embedded | **11.13 / 11.14** | Proves the target, membership and SDK link compile |
| Signed local Release build | **11.14** | The user approved signed local builds (memory "Signed local builds OK"). Archive and upload still need approval |
| Simulator smoke (optional): widget gallery, Siri shortcut listing, `xcrun simctl openurl` deep links | 11.13 (optional) | Not a device claim |
| iPhone SE-class, iOS 17.x (floor) | **Phase 12** | Small screen, AX5 Dynamic Type, iOS 17 interactive widget |
| Standard iPhone, iOS 18.x | **Phase 12** | Widgets, Siri, Control Center |
| iPhone 16 Pro Max, iOS 27.0 (existing row in `docs/native-phase-3-device-matrix.md`) | **Phase 12** | Launch time and soak baselines from 11.12: PERF-1 to PERF-10 and SOAK-1 to SOAK-6 in `docs/native-phase-11-performance.md` |
| iPad 11-inch and iPad mini, iPadOS 27 | **Phase 12** | Split View, Slide Over, Stage Manager, rotation, hardware keyboard (11.11 rows) |
| VoiceOver, Switch Control, AX5 Dynamic Type, Reduce Motion, Increase Contrast, dark mode | **Phase 12** | 11.10a/11.10b produce the runsheet rows |
| Home-screen widgets (Next Job small/medium, Job Timer), Siri phrases, on-my-way cold/warm | **Phase 12** | 11.02–11.06 produce the rows |
| Sentry/PostHog live delivery (Release, staging key absent → silent) | **Phase 12** | 11.07/11.09 rows |
| Poor network, memory and battery soak | **Phase 12** | 11.12 host tests (`native/run-poor-network-tests.sh`, done 2026-09-24) plus the soak protocol (SOAK-1 to SOAK-6 in `docs/native-phase-11-performance.md`) |

11.14 collected these rows in [native-phase-11-device-runsheet.md](native-phase-11-device-runsheet.md)
(created 2026-09-24). Phase 12 12.03 consolidates it. No row is claimed as passed in Phase 11.
The 11.14 results for the three Phase 11 rows above (aggregate, unsigned build, signed
local build) are in the plan §7 11.14 entry; the signed local build did not complete
(widget provisioning), and that is recorded there, not claimed.

---

## 14. Parity-matrix source map (per row)

| Parity row (`docs/native-parity-matrix.md`) | RN sources | Native sources today | Owning task(s) |
|---|---|---|---|
| WidgetKit | `targets/widget/Widgets.swift`, `targets/widget/JobTimer.swift`, `modules/widget-bridge/ios/WidgetBridgeModule.swift`, `utils/widgetBridge.ts`, `__tests__/widgetBridge.test.js` | `N/NativeAppGroupInbox.swift` (scrubber only) | 11.01 (target, snapshot, writer), 11.02 (Next Job), 11.03 (Job Timer), 11.05 (owner/stale) |
| App Intents/Siri | `targets/widget/_shared/SiriIntents.swift`, `targets/widget/JobTimer.swift` (timer intents), `utils/widgetActions.ts`, `__tests__/widgetActions.test.js` | `N/NativeWidgetActionReplay.swift` | 11.04 (all intent types), 11.05 (owner gate, quarantine), 11.01 (membership) |
| Deep links | `utils/deepLinks.ts`, `App.tsx:491-597`, `__tests__/deepLinks.test.js` | `N/NativeDeepLinkParser.swift`, `N/NativeAppGroupInbox.swift`, `N/AppStore.swift:3593` | 11.06 (plus P8) |
| Analytics | `utils/analytics.ts`, `App.tsx` PostHog provider, every `track(` site (§9.5), `context/AuthContext.tsx`, `__tests__/analytics.test.ts` | `N/NativeAnalytics.swift`, `N/AppStore.swift` sites (§9.6) | 11.07 (transport, privacy), 11.08 (events, identity) |
| Crash reporting | `utils/analytics.ts#reportError`, `App.tsx:103-114`, `App.tsx:652`, `app.json:56` | none | 11.09 |
| Accessibility | `components/`, `screens/` labels | §12 inventory | 11.10a, 11.11, 11.10b |
| Release migration | — (Phase 12) | — | Phase 12 (11.14 hands over runsheets) |
| Background refresh (widget mirror + replay) | `utils/backgroundRefresh.ts:106` | `N/AppStore.swift:6036-6064` | 11.01 (mirror on the seam), 11.12 (poor-network) |
| AsyncStorage upgrade (widget/Siri handoff) | `utils/widgetActions.ts` | `N/NativeWidgetActionReplay.swift` | 11.05. Untagged legacy actions are dropped per §4.5; update the row's wording at closeout |
| Settings › AI Assistant | `screens/SettingsAIScreen.tsx`, `utils/storage/keys.ts` | `N/LegacyMigrationCoordinator.swift`, `N/AppStore.swift:7789` | 11.15 |
| Today and planning / Coach (event sources) | `screens/TodayScreen.tsx`, `components/InsightsCard.tsx`, `components/SetupChecklistCard.tsx`, `screens/ChatScreen.tsx` | `N/AppStore.swift:8294-8527` | 11.08 (m6 gaps, type widening) |
| Privacy manifests (roadmap Stage C) | — | none | 11.01 (extension), 11.09 (app) |

---

## 15. Interface handoff per task

- **11.01:**
  - owns §2 and §3.1–3.2: the schema, F1–F6 decode tests, the writer, `ownerTag`, and
    the seam `(canonical, output, expectedOwnerBinding)` overload (**Own-list addition**:
    `N/NativeDerivedStatePublisher.swift` and the matching `AppStore.registerDerivedStateObserver`
    overload in `N/AppStore.swift`; no separate binding accessor);
  - the writer gated on the §2.5 predicate;
  - the extension manifest (§8);
  - the P3 exception sets.
- **11.02:** §3.3 stale state and boundary tests, the empty state, the `widgetURL`
  grammar (§6.1), and the timeline entry at `updatedAt + 86400`.
- **11.03:** §3.3 Timer rules. Uses 11.04's timer intents and defines no intents of its own.
- **11.04:** §4.1–4.5 writer rules (lock, 512 cap, duplicate handling, never overwrite a
  malformed queue, owner stamp, every snapshot read in the append's lock hold, the "Open
  TradeReady and sign in first." refusal), §5 all ten intents and phrases, the tagged
  `pendingOpenUrl` stash (§6.2), and the OnMyWay in-app routing.
- **11.05:** switch the replay gate from the migrated owner to the §2.5 predicate (gap),
  the replay owner-tag gate (§4.5, including dropping untagged unknown types),
  the quarantine policy (C8), stale fixtures (§3.3), and cross-sign-in fixtures.
- **11.06:** switch the deep-link and pending-URL gate to the §2.5 predicate, and remove
  the once-per-session consume (gap). §6 gate order, stash read-and-remove under the
  lock, tag-based cold-launch parking, the archived and done-status rules, and P8.
- **11.07:** §9.2 gating and options, §9.5 allow-list enforcement, and §9.6 seam
  widening in place. SDK pin re-check (§7).
- **11.08:** §9.3 screen map, §9.4 identity lifecycle, §9.5 parity including the m6 gaps.
- **11.09:** §10.2–10.3 Sentry config, redactor and `reportError`; the app manifest (§8).
  Done 2026-09-24 (§10.4; §8.1 and §8.3 amended).
- **11.15:** §11. Done 2026-09-24 (§11.1).
- **11.10a/11.11/11.12/11.10b:** §12 baseline, §13 rows. 11.12 done 2026-09-24: the
  signpost facade `N/NativePerformanceMetrics.swift` (pinned call-site inventory), the
  poor-network suite, and the measurement and soak protocol with Phase 12 owners in
  `docs/native-phase-11-performance.md`.
- **11.13/11.14:** §13 Phase 11 rows, the runsheet file, and the parity-row updates from §14.

---

## 16. Verification recorded for this task

| Command | Result |
|---|---|
| `TZ=America/Phoenix npm test -- --runInBand --runTestsByPath __tests__/widgetBridge.test.js __tests__/widgetActions.test.js __tests__/deepLinks.test.js __tests__/analytics.test.ts` | 4 suites and 123 tests passed. The fixture sources are green |
| Scratchpad-only `swiftc` decode of F1–F6 against a verbatim copy of `BridgeSnapshot` from `targets/widget/Widgets.swift:13-35` (nothing written to the repo) | F1–F5 decode (F5 with `outstandingTotal = nil`); F6 is rejected, as expected |
| `git ls-remote --tags` plus the GitHub releases API for `getsentry/sentry-cocoa` and `PostHog/posthog-ios` | Latest stable: 9.29.0 (2026-09-17) and 3.81.0 (2026-09-22). PrivacyInfo files read at those tags |
| `grep -rn "track(" --include='*.ts' --include='*.tsx' App.tsx screens components hooks utils context` | 72 lines: 70 call sites, plus 2 in `utils/analytics.ts` (the definition and a comment). 52 distinct events, all in §9.5. 11.08 must not assert a site count |
| `sh native/run-doc-reference-check.sh` | See the plan execution log (§7 of the plan) |

---

## 17. Cross-client qualification (11.13, 2026-09-24)

11.13 qualifies Phase 11 against RN; it does not rewrite it. Where a focused 11.01–11.12
suite already proves an area, this section cites it. The cross-client fixtures that
were missing now live in one new suite:

- `native/Phase11QualificationTests/main.swift`;
- run by `sh native/run-phase11-qualification-tests.sh`, which is registered in
  `native/run-all-domain-tests.sh`.

That runner extracts RN's `BridgeSnapshot` (`targets/widget/Widgets.swift`) and
`SiriSnapshot` (`targets/widget/_shared/SiriIntents.swift`) from the working tree at
test time. It never copies or edits `targets/`. It fails loudly if either struct
disappears.

### 17.1 Per-area evidence

| Area | Added by 11.13 (cross-client) | Suites cited (all run with `TZ=America/Phoenix`) | Result | Gaps and owners |
|---|---|---|---|---|
| Q1 Widget snapshot parity (§2) | RN `BridgeSnapshot` and `SiriSnapshot` decode F1–F5. F6 is rejected by RN's widget and by native, and Siri degrades it to "no address". Three native projections (empty; next job + timer; no start time + empty address), stored by the real `NativeWidgetMirror`, decode with both RN decoders field for field. The native stored fields equal RN's 15 plus `ownerTag: String?` only. The verbatim copy in `WidgetSnapshotTests` is checked against the working tree | `run-widget-snapshot`, `run-next-job-widget`, `run-job-timer-widget`, `run-widget-owner-gating` | All pass | None |
| Q2 Action batch replay (§4) | The pure-function vectors of `__tests__/widgetActions.test.js` run through the real planner and replayer: `parsePendingActions`, timer start/stop/pair, done statuses, the stop fallback, trip and expense records, dedupe, the category list parsed from `utils/moneyUtils.ts`, and the description fallback. A retry of the same claim is included. The `replayWidgetActions` vectors run through the real claim transport and coordinator: an empty queue, a timer, trip, expense or mixed batch, and a malformed queue. **Fix round 1:** the `null` and `""` vectors were missing and are now added; `""` changed to match RN (§4.6). A completeness guard parses every RN `test(`/`test.each(` title and table size and pins each to the checks that transcribe it, so a new RN vector fails the suite | `run-widget-action-replay`, `run-app-intent-queue` (native writer → replay → AppStore), `run-widget-owner-gating` | All pass | None. Recorded differences, asserted per vector: RN drops only an invalid action, while native rejects the whole batch (§4.3; superseded by 12.00b.2-C, 2026-09-25: native now sets aside only that entry, bytes kept, §4.6); malformed or non-array JSON is quarantined (C8). `NaN`/`Infinity` cannot be written as JSON, so they surface as `malformedQueue`. The two "never throws" RN vectors are cited (`run-widget-action-replay`, `run-widget-snapshot`) |
| Q3 Deep-link matrices (§6) | Every `__tests__/deepLinks.test.js` vector with a Swift form, job and on-my-way, runs through `NativeDeepLinkParser.parse` and `parsePendingOpenURL` (the freshness window and 10 malformed stashes). The RN `null`/`undefined` rows have no Swift form, because both functions take a `String`; the completeness guard records them. The same guard pins every RN vector | `run-deep-link-routing` (auth, owner and record gates), `run-app-group-pending-open-url` | All pass | None. For `otherapp://evil`, RN returns the raw URL and its parser then rejects it; native rejects it at one boundary. The end result is the same (§6.3) |
| Q4 Event catalog vs call sites (§9.5, §9.7) | RN `track(` sites (70 sites across `App.tsx`, `screens`, `components`, `hooks`, `utils` and `context`, a literal or a two-literal ternary, anything else fails) must equal the 52-event catalog. Every catalog event has a typed constructor. A call graph over `N/` counts an `AppStore` emission as live only if its enclosing function is reachable from a root: a reference in another `N/` file, or one outside every `func` body. Gate-policy events count through `output.events.forEach(emitAnalytics)`. 49/52 are live, and the unwired set must equal the exclusion list exactly | `run-analytics-event`, `run-analytics-transport` | All pass | Three named exclusions; see §17.2, G1 and G2 |
| Q5 Redaction denylist (§10.1) | RN `SECURE_FIELDS`, parsed from `utils/storage/keys.ts`, is `secureKey` to analytics and denied by the crash redactor. The §10.1 deny keys are parsed from the table (33 keys). Each is dropped by `redactDictionary`, reduced to allow-listed extras by `redactExtras`, and stripped from a catalog event by the analytics policy. Five credential prefixes are scrubbed from text. **Fix round 1:** `NativeSensitiveData` now recognises Square access tokens (`EAAA`, `sq0atp-`, `sq0atb-`) and application secrets (`sq0csp-`, `sq0csb-`). Q5 proves that `containsSecret`, `redactString` and the analytics policy stop them, and that every link `isSquarePaymentLink` accepts stays a non-secret and still configures Square. No widget-snapshot key is secure-shaped, and a secret planted in job notes never reaches the snapshot | `run-error-redaction` (Square cases added), `run-analytics-transport`, `run-ai-provider-key`, `run-store-integration` (fix round 2) | All pass | None. **Fix round 2** fixed G4 and G5 (§17.2): Settings refuses a Square value that is not a payment link, and RN `scrubLegacySquareToken` is ported to sign-in and every synced-settings commit |
| Q6 Accessibility and layout metrics (§12) | §12.1 lists A1–A31, and every status starts with a closed status on an allow-list (Fixed, Retained, Done by, Accepted, Mitigated, Resolved, Deferred to device). A30 is fixed here (below) | `run-accessibility-audit` (1859 checks, including `testDocumentPDFContrast`), `run-layout-metrics`, `run-invoice-pdf`, `run-estimate-pdf` | All pass | None open. VoiceOver, Switch Control and AX5 are deferred to Phase 12 (A12, A19) |

**A30 (controller-assigned, §12.1).** `N/NativeInvoicePDF.swift` and
`N/NativeEstimatePDF.swift` now draw every color from
`NativeAccessibilityAudit.DocumentPalette`. The new values measure:

- accent (the light information text color): 6.37:1 on white and 5.91:1 on the total wash;
- PAID on its fill: 5.86:1 (success text);
- OUTSTANDING on its fill: 5.74:1 (warning text);
- PARTLY PAID on its fill: 5.67:1 (information text).

The fills, ink, secondary and rule colors are unchanged. `documentContrastRequirements`
has 13 rows, and all meet their role minimum. RN `utils/pdfTemplates.ts` keeps its
colors: `#007aff` at 4.02:1, badges at 2.88, 3.12 and 4.33:1, and labels in `#8e8e93`
at 3.26:1. The native colors are therefore a recorded native difference: parity does
not extend to inaccessible colors (as with A29).

### 17.2 Gaps, blockers and owners

| ID | Gap | Coverage or blocker | Owner |
|---|---|---|---|
| G1 | `booking_request_opened`, `booking_update_opened` have no native emission (RN tracks push taps, `App.tsx`) | Named blocker: native has no remote-push surface. Q4 fails if either becomes live without the list changing, or if another event goes unwired | owner: Phase 12.00 — cutover-blocking parity gap (build or dated waiver). The build is native remote push |
| G2 | `tax_settings_saved` is emitted only via `emitTaxSettingsSaved` ← `commitTaxSettings`, and nothing calls `commitTaxSettings` | Named blocker: native has no tax-settings editor (RN `TaxSetAsideCard`). Q4 pins the dead chain | owner: Phase 12.00 — cutover-blocking parity gap (build or dated waiver). The build is a native tax-settings editor. The parity row "Tax set-aside" was corrected by 11.14 (`d18b29c`): it is "In progress" and says the tax-settings editor is not ported |
| G4 | RN `scrubLegacySquareToken` (`App.tsx` sign-in chain; `utils/storage/settings.ts`) deletes any stored `providerKeys.square` value that `isSquarePaymentLink` refuses, such as a pasted Square access token left by pre-2026-08 builds, then saves, which re-enqueues the cleaned blob so the cloud copy heals. Fix round 1 recorded it as not applicable; the controller ruling on G5 reversed that, because a token can also arrive in a pulled blob from another device or an old RN queue | **Fixed (fix round 2, the 11.13 commit after `f7a2e13`)**. `NativeSquareProviderKeyPolicy.scrubbed` (`N/Domain/NativeInvoicePaymentLinks.swift`) has RN's exact rule: a non-empty value `isSquarePaymentLink` refuses is deleted, and nothing is written otherwise. `AppStore.scrubLegacySquareToken()` applies it to the canonical settings, saves (rotating the repository backup too), re-projects Settings and queues one settings upsert. The settings push sends the whole `data` blob, so the heal is local and the server copy is replaced. It runs on the returning-user sign-in, after the initial-sync commit and after every delta-pull commit, gated on the exact signed-in workspace. Tests: Q5 (policy and call sites) and `run-store-integration` (a pulled token is scrubbed and queued; a second pass writes nothing; the gate) | None; fixed |
| G5 | Fix round 1 found that "native never writes a non-link square value" did not hold: `N/SettingsView.swift` bound the Square field straight to `BusinessSettings.setProviderKey`, so a pasted token reached the canonical snapshot and the synced settings blob. RN has the same input path and relies on its sign-in scrub (G4) | **Fixed (fix round 2, the 11.13 commit after `f7a2e13`)**. The Square field is now a draft saved with **Save link**, through `AppStore.setPaymentProviderKey`, which uses `NativeSquareProviderKeyPolicy.validate`: a value `isSquarePaymentLink` refuses is rejected with RN's Square hint as the copy and is never saved; an empty entry clears the field; other providers keep RN's unvalidated save. `mergeSettingsAndSave` also strips a non-link Square value before any settings write, so no Settings path can persist or queue one. **Heal window:** a token that arrives through a pull, the initial sync or an RN import is written to `store.json` by that commit. The heal removes it at the next gated run: right after a delta-pull or initial-sync commit, or at the next sign-in for an RN import. A token that was already on disk can survive one generation in `store.json.backup` until the heal's second save rotates the backup. Tests: Q5 (policy, copy, Settings writes only through the validated save) and `run-store-integration` (a token never reaches the projection, snapshot, disk or queue; a link saves and queues; empty clears) | None; fixed |
| G6 | `LegacyBackups/` keeps the exact pre-conversion source: the RN AsyncStorage copy, the RN App Group values and a legacy native snapshot. An RN-era plaintext Square token can sit there, and the files were written with plain `.atomic` under Application Support, with no backup exclusion | **Fixed in code (fix round 3):** `Canonical.SnapshotRepository` writes the preserved bytes with `[.atomic, .completeFileProtection]`, raises copied directory files to `.complete`, and excludes the `LegacyBackups/` tree from backup. Failures only log a bounded stage code. `run-repository` asserts the options and the exclude flag; file protection is not observable on a macOS host (runsheet row Q11-P12-6). **Residual:** on an upgraded device, the RN app's own AsyncStorage source files may still hold the token. **Amended by Phase 12 12.00b.2-F (2026-09-25; charter §5.4 G6-Q1, defect P12-001):** a permanent account deletion now erases the RN source files (the AsyncStorage candidates, the Documents photo directories and the legacy Expo SecureStore services) as the last step of the `.all` scrub, under the scrub marker (`NativeLegacySourceEraser`), so the deleted account is never re-imported and any token in those files goes with it. A sign-out keeps them: the retention policy covers live accounts only. Tests: `run-legacy-reimport`. **Amended by Phase 12 12.00b.2-G (2026-09-25; defect P12-003):** a sign-out on a migrated device removes the snapshot and keeps the completed journal, and the launch migration gate read that as a lost migrated snapshot (`missingMigratedSnapshot`: writes blocked, and the next sign-in stopped at `preflight/local-recovery/missing-migrated-snapshot`). The `.live` scrub now first writes a content-free record that it cleared the workspace (`store.json.account-scrub-cleared`, schema version only), and the next snapshot save removes it. With a completed journal, no snapshot and that record, the launch and "Try again" treat the device as signed out: no migration attempt, no block, and the steady-state re-protect of `LegacyBackups/` still runs. A snapshot lost with no scrub still blocks. Tests: `run-legacy-reimport`, `run-repository` | owner: Phase 12.00 migration/recovery retention policy |
| G3 | Siri, widget, extension and store behavior on a device | Deferred to Phase 12 (§13): home-screen rendering, interactive widgets, Siri phrases and Shortcuts, on-my-way cold and warm, Control Center, Sentry and PostHog live delivery, StoreKit, VoiceOver, AX5, and the iPad rows | Phase 12 (11.14 collects the runsheet) |

**Known issues carried to the final review, not qualified by 11.13.** None of these
was claimed as passing by 11.13. The Phase 11 final review
(`.superpowers/sdd/native-phase-11-implementation-plan/final-fix-brief.md`) gave each
one a disposition; its fix wave is logged in the plan §7 "Final review fix wave" entry:

1. the `NativeRecurringInvoicesView` "Cancel plan"/"Delete plan" `actionRule` bug
   (final review I1): **fixed** in `8146cd6`. `NativeRecurringPlanActionState`
   (`N/Domain/NativeRecurringInvoices.swift`) keeps the target through the dialog's
   dismissal and the alerts act on `presenting:`. Test: `run-recurring-invoice`.
   Device row: runsheet Q11-P12-7;
2. the `NativeSupabasePush` non-auth 4xx queue wedge (final review I2): **recorded,
   not fixed** at Phase 11 exit; **fixed in Phase 12 12.00b.1** (below). Owner: Phase
   12.00, cutover-blocking. Non-auth 4xx (400/404/409/413/422, and a 403 that repeats
   after refresh) is treated as transient and retained forever,
   and `NativeSyncCoordinator`'s `guard queue.load().isEmpty` skips every pull, so one
   poison mutation wedges inbound sync and an RLS 403 loops. Fix sketch: classify those
   responses as `.rejected`; move rejected mutations to an app-private, owner-scoped
   rejected store scrubbed at every account boundary; a bounded diagnostic; "N changes
   couldn't sync" on Cloud Sync; then decide whether to relax the pull guard toward RN
   parity (RN always pulls after push, `utils/sync.ts` `syncIfOnline`:316-326, which
   calls `pushQueue`:149-214 then `pullRemote`), mindful of the 11.12 per-table rebase.
   Test: a poor-network poison-item scenario in `native/PoorNetworkTests/main.swift`
   (good items push, inbound pulls continue, and the poison item reaches the rejected
   store exactly once). Implemented by Phase 12 12.00b.1
   (`docs/native-phase-12-implementation-plan.md`).
   **Fixed in Phase 12 12.00b.1 (2026-09-25, native/phase-12, host evidence only):**
   - Classification: `NativeMutationPushClassification.classify`
     (`N/NativeMutationPushClassification.swift`) is the one status table. 2xx is
     accepted. 401, and a change's first 403 in a pass, take the auth path. A 403
     for a change that also got one before the pass's one refresh (per change, not
     per pass: review fix round 1, M1), and every other 4xx except 408/425/429, is
     `.rejected`. 408/425/429, 5xx, other statuses, transport errors and non-HTTP
     responses stay transient. Tests: `run-mutation-push` (the table),
     `run-sync-coordinator`.
   - Store: a rejected change leaves the queue for `NativeRejectedChangeStore`
     (`N/NativeRejectedChangeStore.swift`). It is app-private next to the queue,
     tagged with a one-way hash of the owner's binding, capped at 100 entries (newest
     kept, drops counted), and never logged. It is written with after-first-unlock
     protection, like the queue and snapshot that hold the same payloads: `.complete`
     would add no confidentiality and would stop background sync while locked. A
     settle that cannot read or write keeps every started item queued. With a signed-in
     subject but no verified binding (a rejected session keeps the subject) and a file
     on disk, whose entries they are is unknown: the pull fails with
     `pull/rejected-store` and a settle throws, so the attempt stays queued (review fix
     round 1, M2). Every account boundary
     scrubs it under a durable `rejected-changes-scrub-pending` step
     (`Canonical.SnapshotRepository.BoundaryStep`, file marker plus the 12.00b.2-A
     Keychain record), and the full account scrub removes it. Test:
     `run-rejected-changes`.
   - Diagnostic: `rejected/<table>/<status>` with a count, through `reportError` and
     the redaction path, plus `rejected-store/overflow`. The count, and never the
     entries, is `rejectedChangeCount` in `createPersistenceSupportReport` (schema v2).
     Tests: `run-error-redaction`, `run-repository`.
   - Surface (owner decision D3): Settings › Cloud Sync shows "N change(s) couldn't be
     saved" and opens `NativeRejectedChangesView`; while any are listed its status
     never reads "Up to date" (review fix round 1, M7). Each entry shows its record type,
     name and when it was refused. **Retry** re-queues the change through the normal
     queue, where it coalesces; refused again, it goes back to the store once, with no
     loop in the pass. **Discard** asks for confirmation, then fetches that one record
     from the server and shows the server's version. A change the server never had (a
     refused insert) is removed from this device, and the confirmation says so. No
     delete is queued. Tests: `run-rejected-changes`, poor-network R and S.
   - Pull guard (plan step 5), decided: the coordinator pulls after every push pass
     that returns per-item results, as RN `syncIfOnline` does (`utils/sync.ts`
     316-326: `pushQueue` at 320, then `pullRemote` at 321). A push that throws still
     skips the pull. The 11.12 per-table rebase keeps queued and refused records over
     the server's rows. They no longer hold the table's cursor (`unheldKeys`), so a
     kept record cannot pin the watermark. Only a record pushed while the pull was in
     flight holds it (the I1 rule). Tests: poor-network P (the poison scenario) and Q
     (the watermark reaches the newest server stamp over three passes).
   - Residuals, rated S3: past the cap the oldest refused change is dropped and
     counted, and a later pull can then overwrite its record; the password-recovery
     exits scrub the store but keep the records, with the same effect; so does "Use
     another account", which scrubs the store and keeps the workspace; and a newer
     change to a refused record that the push drops as unsendable (`record-contract`)
     counts as cleared, so its entry leaves the list. The server would never accept
     those edits anyway.
   - Still owed: device rows P12-B1-1 (a poison change on a real device against STG,
     blocked while D4 is open, never waived) and P12-B1-2 (the Cloud Sync surface with
     VoiceOver and Dynamic Type), in `docs/native-phase-12-evidence-index.md` §23;
3. the parity-matrix Tax set-aside row, which said "ported" although native has no
   tax-settings screen (see G2): **fixed** by 11.14 (`d18b29c`); the editor itself stays
   with G2's owner;
4. the `useAnotherAccount` scrub fail-open (final review 1a): **fixed** in `5f2f397`.
   The App Group wipe runs under a durable `widget-scrub-pending` marker
   (`Canonical.SnapshotRepository.BoundaryStep`, the account-scrub marker pattern); while
   it is pending the mirror has no owner and replay is closed; it is retried at launch,
   from `retryAccountScrub` and before an interactive sign-in, and a successful retry
   reloads timelines. Test: `run-widget-owner-gating`.
   **Amended by Phase 12 12.00b.2-A (2026-09-25):** when a step's file marker cannot be
   written, the step is also recorded in the native Keychain
   (`N/NativeAccountBoundaryStepRecord.swift`), so a step that fails as well stays
   pending across a relaunch (L286.5b); a record that cannot be read at launch keeps the
   step's gates closed without running it until a retry can read it. A pending step
   shows a non-blocking "Account cleanup paused" banner whose "Try cleanup again" runs
   it through `retryAccountScrub`, on both of its branches, and sign-up's immediate
   session retries it before binding, like sign-in (L286.4). Tests: `run-ai-provider-key`
   and `run-widget-owner-gating` (every marker × step failure combination, then a
   relaunch).
   **Note (2026-09-25, 12.00b.2-A review):**
   - When the file marker, the Keychain record and the step all fail, the step is
     pending in memory only. The in-process gates hold, and the record-write failure
     is counted. A relaunch forgets it.
   - AI keys are owner-tagged (§11.1), so after that relaunch A's key still reads as
     absent for B, and B can save its own.
   - The widget step's share of that residual is rated S3. Replay stamped for A is
     dropped, and B's first mirror write overwrites A's snapshot. The widget extension
     showing leftover App Group data until then is pre-existing.
   - The next owner is not refused: B binds after the pre-bind retry, and stays gated
     while a step is pending.
   - A record unreadable at launch is re-read on every scene activation, and a
     successful sign-out or deletion scrub retries any step still pending (review M1).
   - Deletion's `clearAllValues` removes the step records on any backend (review M7).
   - Tests: `run-ai-provider-key` (the triple failure, then a relaunch; owner-only
     reads; activation; the post-scrub retry; deletion).
   **Amended by Phase 12 12.00b.2-G (2026-09-25; defect P12-004 and the Task 9b review
   M2, M3):**
   - The launch recovery, "Try cleanup again" (`retryAccountScrub`) and the first
     attempt of a sign-out or deletion clear one shared list of stores. Retry used to
     skip the pending schedule/booking work. That was not a leak: each item carries its
     owner's exact binding, so the next account could neither send nor apply it (S3).
   - A scrub marker that exists but cannot be read (before first unlock, say) or
     decoded keeps the scrub pending and blocked, and none of it runs. It used to read as
     a sign-out, which skipped a deletion's legacy-source erase and cleared its marker.
   - Scene activation also retries a pending account scrub, with the same gates, unless
     a sign-out or deletion is running. The blocked screen says "Account deletion cleanup
     paused" for a deletion and "Sign-out cleanup paused" otherwise.
   - Test: `native/run-legacy-reimport-tests.sh`.
   **Amended by Phase 12 12.00b.2-G fix round 1 (2026-09-25; defect P12-005):**
   - A sign-out used to keep the RN-era auxiliary artifact (account state and the
     `__dataOwner` owner marker) and its staged copy for an exact-owner rollback. With
     RN owner keys, every other account's sign-in then met the Phase 3 exact-owner gate
     (`.accountMismatch`), so no second account could use the device.
   - The `.live` scrub now removes both, before the snapshot, as RN's sign-out clears
     `__dataOwner` and every account key. The next account gets a clean workspace and
     none of the previous account's state. The same account's sign-in takes the
     ordinary path; its device-local RN-era state is gone, as on RN.
   - Unchanged: the Phase 3 rule still holds another account while a workspace no
     scrub cleared is on the device; the completed journal, `LegacyBackups/` and the
     RN source files stay (G6).
   - Test: `native/run-legacy-reimport-tests.sh`.
   **Amended by Phase 12 12.00b.2-G fix round 1 (2026-09-25; Task 9c review Minor 1):**
   - An identity check (launch, scene activation, background refresh, the sync's
     session refresh) awaits `/auth/v1/user`. A boundary that finished during that
     await could be overwritten when the check resumed: the check re-cached the old
     session's verified identity in the Keychain and applied the old owner's outcome
     over the signed-out state. The boundaries are the activation's retry of a pending
     sign-out, the Retry button, a sign-out, a deletion and an account switch.
   - The store now keeps an account-boundary generation. It advances when an account
     scrub has written its marker, when a sign-out or deletion completes, and when an
     account switch starts. Each check reads the generation before the await. If it
     moved, the check drops its result, or its error, and leaves the state as the
     boundary set it. The check also clears the Keychain identity cache unless the
     cache describes the session stored now.
   - Test: `native/run-legacy-reimport-tests.sh` (section 6; the background and
     sync-refresh checks need a configured Supabase build, so they are source pins).
   **Amended by Phase 12 12.00b.2-G fix round 1 (2026-09-25; defect P12-006):**
   - A deletion whose local scrub could not write its marker ran no step and left
     nothing on disk saying it was pending. The Retry button and the activation retry
     then unblocked without scrubbing, and the next launch loaded the deleted account's
     data, which the next account could adopt.
   - Such a deletion is now also recorded in the Keychain
     (`account-deletion-scrub-pending.v1`, schema version only) and held in memory, and
     it advances the boundary generation. Retry, scene activation and the launch write
     the marker from it first and run the whole `.all` scrub, eraser included. Until
     then the deletion stays blocked with nothing loaded. The `.all` scrub's
     `clearAllValues` removes the record on every backend.
   - A record that cannot be read at launch does not block the launch (the snapshot it
     guards is unreadable in the same before-first-unlock window); scene activation
     re-reads it. If the Keychain write fails as well, only the in-memory copy remains:
     Retry and activation still finish it, a relaunch first does not. Both failures are
     counted and logged by stage code.
   - Test: `native/run-legacy-reimport-tests.sh` (section 7).
5. the silent AI-key wipe failure (final review 1b): **fixed** in `5f2f397`. The wipe
   tries every kind under a durable `ai-key-wipe-pending` marker and counts and logs a
   failure without key material; while pending the coach reads no client key and no key
   can be saved; same retries. Test: `run-ai-provider-key`;
6. `deepLinkOwnerWasActive` keyed on O (final review 2): **fixed** in `2e70415`. The
   arrival stamp and the owner-was-active flag fall back to the verified account behind
   pending gates, and the recovery sign-out clears held routes. Test:
   `run-deep-link-routing`. **Amended by Phase 12 12.00b.2-A (2026-09-25, L286.7):** a
   stored session rejected at activation also clears the verified binding and every held
   route; the parked route follows §6.3 (the launch resolution keeps it).

The final review also fixed two findings outside this list: widget/Siri replay now
enqueues its writes (C1, `2f4ed28`; `run-widget-action-replay`, `run-poor-network`),
and an account switch is exclusive (1c, `5f2f397`; `run-widget-owner-gating`).

### 17.3 Commands and results (2026-09-24, `TZ=America/Phoenix`)

| Command | Result |
|---|---|
| `TZ=America/Phoenix npm test -- --runInBand --runTestsByPath __tests__/widgetBridge.test.js __tests__/widgetActions.test.js __tests__/deepLinks.test.js __tests__/analytics.test.ts` | 4 suites and 123 tests passed, exit 0. Jest printed a haste-map warning about a duplicate `__mocks__` in a `.claude/worktrees` copy; it did not affect the result |
| `sh native/run-phase11-qualification-tests.sh` | RED before the A30 row changed: `1 of 318 checks FAILED` (A30 open). GREEN: `318/318 checks passed` |
| Mutations on a scratch copy of the root, run by the compiled binary with nothing in the repo changed | Six mutations, each caught: `emitAnalytics(.tripLogged)` dropped (2 failures); A5 reopened (1); a field added to RN `BridgeSnapshot` (3); a new RN `track("brand_new_event")` (1); a new RN secure field (1); a caller wired for `commitTaxSettings` (4). The restored copy returned `318/318` |
| `sh native/run-accessibility-audit-tests.sh` | RED (A30 test first): compile failure, `DocumentPalette` and `documentContrastRequirements` missing. GREEN: `1859/1859 checks passed` |
| The focused runners in §17.1, plus `run-background-refresh`, `run-snapshot` and `run-store-integration` | Each exits 0; the plan §7 11.13 entry lists every runner and its output line |
| `sh native/run-all-domain-tests.sh` | See the plan §7 11.13 entry |
| Release compile (`xcodebuild … -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`) | `** BUILD SUCCEEDED **` |
| `sh native/run-doc-reference-check.sh` | See the plan §7 11.13 entry |
| Fix round 1: `sh native/run-phase11-qualification-tests.sh` | RED: `21 of 473 checks FAILED` (the empty-queue vectors, the Square token screens, and the §17.2 owners). GREEN: `474/474 checks passed`. Six mutations of the new guards (a new RN test, an extra `test.each` row, an edited F2, an unmapped §10.1 row, a `**Pending` A-row, a changed G5 owner) were each caught |
| Fix round 1: `sh native/run-error-redaction-tests.sh` | RED: 12 failures (the Square poison strings). GREEN: `711/711 checks passed` |
| Fix round 2: `sh native/run-phase11-qualification-tests.sh` | RED: `6 of 510 checks FAILED` (the heal call sites, the Settings write path, and G4/G5 still open in §17.2). GREEN: `510/510 checks passed` |
| Fix round 2: `sh native/run-store-integration-tests.sh` | RED: compile failure (no `setPaymentProviderKey`/`scrubLegacySquareToken`), then with the API stubbed `FAILED: 11` (the persist guard, the pull heal and the gate). A 12th check, the token surviving in the repository `.backup` after the heal, failed after the first GREEN attempt and was fixed by rotating the backup. GREEN: `PASS`. Removing the persist guard and the pull hook fails 8 checks |
| Fix round 3: `sh native/run-repository-tests.sh`, `sh native/run-error-redaction-tests.sh` | Repository RED: `FAILED: 3` (no exclude flag on `LegacyBackups/` from any of the three writers), after a compile RED for the missing option seam. GREEN: `PASS`. Redaction RED: `715/720` (short `EAAA` words were redacted). GREEN: `720/720` |
