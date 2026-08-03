# Widgets & Siri Plan — Home-Screen Widgets, App Group Bridge, App Intents

**Created:** 2026-08-02 · **Status: Phases 1–2 code COMPLETE 2026-08-03 (owner
approved the native bundle); awaiting EAS build 8 compile validation + device
smoke.** JS half: `utils/widgetBridge.ts` (snapshot selectors + guarded mirror/wipe,
wired into `saveJobs`/`saveInvoices`, AuthContext, `clearAllUserData`) — a no-op
until the native module is present, so it rides OTA safely. Native half:
`modules/widget-bridge/` (WidgetBridgeModule.swift — setSharedItem/clearShared +
WidgetCenter reload), `targets/widget/` (Next Job widget, small+medium, iOS 17+,
deep-links `tradeready://job/<id>`), `@bacons/apple-targets@5.0.0` plugin, App Group
entitlement, `scheme: "tradeready"`, `ios.appleTeamId: 96J48TJWX3` (recovered from
build 7's provisioning profile — the plugin errors without it). ⚠️ Swift cannot
compile on the Windows dev box (prebuild refuses non-macOS): the EAS build is the
first compiler run. Nothing may be claimed in the store listing until
device-smoke-tested.

## What this is

Two home-screen widgets (Next Job, Job Timer) plus Siri voice entry points, all sitting
on one shared native foundation — the **App Group bridge**. The bridge is the cheap,
one-time piece (~1 day); the widgets and intents are the consumers. Building the bridge
once during the widget effort makes Siri Tier 1 a modest add-on rather than its own
project, and any future Live Activity reads from the same place.

**Platform order:** iOS first. The original sketch included Kotlin/Glance counterparts,
but Play submission is deferred (owner decision 2026-07-14), so Android widget work is
out of scope until that changes.

---

## The widgets

1. **Next Job** — read-only glanceable card: customer, time, address. Small + medium
   sizes. Tap deep-links to that job's JobDetail.
2. **Job Timer** — start/stop clock-in/out with live elapsed time (WidgetKit
   `Text(.date, style: .timer)`). Interactive buttons need iOS 17+; iOS 16 gets a
   read-only fallback that opens the app.

**Why:** a solo tradesperson's highest-frequency actions are "when/where is my next
job?" and clocking in/out — neither should require opening the app.

---

## The App Group bridge (shared foundation)

**Why it exists:** AsyncStorage writes into the app's own sandbox. Widget and intent
extensions run in separate processes and cannot read it. The fix is not to move
AsyncStorage — it's to **mirror a minimal snapshot** into the shared App Group
container, which both the app and its extensions can read.

Parts, in build order:

1. **Entitlement (config only).** Add to `app.json` under `ios.entitlements`:
   `"com.apple.security.application-groups": ["group.com.gettradereadyapp.tradeready"]`
   (matches `bundleIdentifier` `com.gettradereadyapp.tradeready`). EAS syncs the
   capability to the provisioning profile automatically — same path that worked when
   Sign-In-With-Apple was added for social sign-in. No Xcode session needed.
2. **WidgetBridge native module (~30–50 lines of Swift).** A local Expo module
   (Expo Modules API, `npx create-expo-module --local`) exposing roughly
   `setSharedItem(key, json)` / `clearShared()`, writing to
   `UserDefaults(suiteName: "group.com.gettradereadyapp.tradeready")`. After each
   write it calls `WidgetCenter.shared.reloadAllTimelines()` so widgets never sit on
   stale data. A local module avoids adding an npm dependency, but it is still native
   code — dev builds only from that point on.
3. **The mirror write (plain JS).** A small function that serializes the snapshot
   (next job's time/customer/address, timer state, outstanding total) and calls the
   module. Wire it into the storage-layer write paths for jobs/timer and on app
   foreground. The mirror only refreshes while the app runs — acceptable for
   "next job", since schedules are created in-app.
4. **Sign-out wipe — in the same change, not a follow-up.** `clearAllUserData`
   (`utils/storage/lifecycle.ts`) must also clear the shared container. Otherwise
   user A's next job and customer name sit in a widget after user B signs in — the
   exact cross-user-leak class fixed twice in the `review_requests` wipe gaps
   (2026-08-02, commits `98cbe23` / `bb675fe`). Treat the wipe as part of the
   bridge's definition of done.
5. **Minimal projection only.** The group container is a plaintext plist — same
   protection level as current AsyncStorage (no regression), but it is another copy
   of customer PII. Mirror only what the widget/Siri surfaces actually display;
   never whole collections.

**Bidirectional flow (timer only):** the timer widget can't write app data directly.
It uses a **pending-action pattern** — the widget's App Intent writes a small intent
record ("stop pressed at T") into the shared container; the app replays it on next
foreground through the existing timer handlers. The app remains the single writer of
real data.

---

## Siri / App Intents

**Framework reality:** modern Siri means App Intents (Swift, iOS 16+). Expo has no
first-party support, so intents live in the same extension-target-and-config-plugin
infrastructure as the widgets — and interactive widgets are themselves built on App
Intents, so this is one foundation, not two. App Shortcuts registered this way also
surface in Spotlight and the Shortcuts app for free.

Ranked for a solo tradesperson (hands on a wheel, a ladder, or covered in dust):

**Tier 1 — fold into the widget milestone (hands-free truck moments):**

1. **Start/stop a mileage trip** — "Hey Siri, start a trip in TradeReady." The moment
   to log a trip is exactly the moment you can't touch the phone, and trips are
   local-only (`AddTripScreen` / Trip model), so no sync complexity. Forgetting
   trips is the #1 way the mileage deduction leaks.
2. **"What's my next job?"** — Siri reads time, customer, address from the bridge
   snapshot; follow-up offers Maps navigation. Same data the Next Job widget shows.
3. **"On my way" text** — opens the existing prefilled composer (the on-my-way path
   on JobDetail/Today). Opens, never auto-sends — consistent with the committed
   appointment-reminders design (tap-to-send, nothing sent silently).

**Tier 2 — later:**

4. **Log an expense by voice** — parameterized intent (amount + category + note);
   covers the receipt-less cash moments OCR can't.
5. **Job timer start/stop by voice** — once the Timer widget's intent exists this is
   nearly free (same intent, voice phrase added).
6. **"How much am I owed?"** — reads the outstanding total from the snapshot.
   Low frequency, read-only, demos well.

**Deliberately skipped:** voice-creating invoices/estimates (too many fields,
money-adjacent errors) and voice mark-paid (too destructive for a misheard command).

---

## Phases (owner-gated; stop for go-ahead between each)

| Phase | Contents | Status |
|---|---|---|
| 1 | **Shared infra:** App Group entitlement, WidgetBridge module, mirror writes, sign-out wipe, deep-link routes, extension-target config plugin | ✅ BUILT (fe422c2 + 74b9009), smoke-passed on build 9 |
| 2 | **Next Job widget** (small + medium, deep link to JobDetail) | ✅ BUILT (74b9009), smoke-passed on build 9 |
| 3 | **Job Timer widget** (iOS 17 interactive; pending-action replay via `widgetActions` container queue) | ✅ CODE COMPLETE 2026-08-03 (d4ce3c5 + replay layer 79bb704/4b4ac3d/9185c08) — awaiting EAS compile + device smoke. No iOS-16 fallback: the whole widget target floors at 17.0 (2026-08-03 decision) |
| 4 | **Siri Tier 1** (odometer-based trip start/stop, next-job query, on-my-way) | ✅ CODE COMPLETE 2026-08-03 (62de4a9 + cold-launch fix 5c8e919) — intents live in `targets/widget/_shared/` so they compile into BOTH the app and the widget target (Siri requires main-app registration); on-my-way opens the app via RCTOpenURLNotification (warm) + a `pendingOpenUrl` container stash drained at launch (cold); trips collect odometer readings as Siri parameters and land as one complete `trip_log` pending action |

**Accepted v1 tradeoffs (2026-08-03, final review):** launch-path replay runs
concurrently with initialSync's pull (same exposure class as the recurring-job
generators; sync queue re-pushes); a widget Start tap whose job is gone/done at
replay silently reverts; `activeTrip` has no expiry — a forgotten Siri trip
blocks "start a trip" until "stop my trip" or sign-out (v2: staleness overwrite
in StartTripIntent); a crashed replay loses that batch of pending actions.

**Deployment floor DECIDED 2026-08-03 (owner: drop iOS 15/16):**
`expo-build-properties@~1.0.10` + `ios.deploymentTarget: "17.0"` landed same
day. Native-only change — takes effect in the NEXT EAS build (build 10 shipped
at the 15.1 floor and smoke-passed anyway); harmless over OTA (plugins don't
apply). Phases 3–4 device smoke PASSED on build 10 (all four shortcuts, timer
widget round-trip, on-my-way warm + cold, sign-out blanking).

Original whole-effort estimate: **~3 weeks** (2026-07 sketch, iOS + Android; iOS-only
should come in under that — re-estimate at kickoff).

## Constraints & approvals

- **Rule 3 approvals needed before the native half of Phase 1:** the
  extension-target config plugin (`@bacons/apple-targets` or equivalent), the local
  Expo module scaffolding, the App Group entitlement, and a URL `scheme` key are
  dependency/`app.json` changes — explicit owner sign-off first. (Discovered at
  kickoff 2026-08-03: `app.json` has NO `scheme` today — the estimate-approval flow
  uses the web domain — so widget tap deep-links need one added, which is itself a
  native config change riding the same build.)
- **Build vehicle:** ships only in a fresh EAS build (whichever build number is next
  when this starts); the JS mirror-write code is inert without the native side, so
  it must not be OTA'd ahead as if it were a feature.
- **Dev workflow changes:** once the native module exists, Expo Go can no longer run
  the app — day-to-day dev moves to dev builds. Worth an explicit owner heads-up at
  kickoff.
- **Claims discipline:** widgets/Siri appear in the store listing only after device
  smoke tests, per the standing rule.
