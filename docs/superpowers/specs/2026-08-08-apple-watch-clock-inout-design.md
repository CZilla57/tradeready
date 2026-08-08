# Apple Watch Clock In/Out — Design

**Date:** 2026-08-08 · **Branch:** TBD (not yet started) · **Roadmap:** post-1.2.0, own phase (targeted 1.3.0)
**Status:** DESIGNED, not built. Deliberately sequenced *after* 1.2.0 (widgets + Siri Tier 1–2 +
background refresh, docs/release-runbook-1.2.0.md) ships — 1.2.0 is one owner smoke test away
from submission and this adds a new native target type, which is its own compile/provisioning
risk best kept off that critical path.

## Goal

Let a tradesperson clock in and clock out of a job from their Apple Watch without pulling out
the phone. Minimum viable scope: a standalone watchOS app showing the current/next job and two
buttons (Clock In / Clock Out), reusing 100% of the existing clock-in/out business logic and
sync queue — the watch is a new *input surface*, not a new code path.

## Owner decisions (2026-08-08)

| Decision | Choice | Rationale |
|---|---|---|
| Watch experience | **Standalone watch app, two buttons** (not a complication, not Siri-only) | Most direct answer to "clock in/out from the wrist"; complication and watch-Siri are cheaper but don't meet the ask on their own. |
| Data/action transport | **Relay through the phone via WatchConnectivity** — not a standalone-network watch app | App Groups don't span devices, so phone↔watch always needs real IPC regardless. Routing through the phone means the watch reuses the *existing* `pendingActions` replay layer and `applyClockIn`/`applyClockOut` verbatim — zero new business logic, one new transport. A standalone-network watch app would duplicate auth, session handling, and clock-in logic in Swift, a second place for it to drift from the JS implementation. |
| Release sequencing | **Own phase, targeted 1.3.0** — not folded into 1.2.0 | 1.2.0 is fully scoped and mid-smoke (TestFlight build 11, `docs/release-runbook-1.2.0.md`). A new target type (`watch`) is a new provisioning-profile/compile risk (the widget target's first EAS build already hit an interactive-credential snag); isolating it avoids reopening a release that's nearly done. |
| Complication, Siri-on-watch, standalone network | **Explicitly out of scope for this phase** | YAGNI. Siri-on-watch may already work for free via the existing `AppShortcutsProvider` (worth a cheap TestFlight check before this phase even starts, not a design dependency). |

## Architecture

- **New target:** `watch` via `@bacons/apple-targets` (already a dependency at `5.0.0` — no
  Rule 3 new-dependency approval needed, just a new `targets/` entry and app.json plugin config,
  the same pattern already proven by the `widget` target). WatchKit App type, `deploymentTarget`
  watchOS 10 (mirrors the iOS 17.0 floor decision for 1.2.0 — no legacy-OS support debt).
- **New bridge module:** `modules/watch-bridge/` (Swift), sibling to the existing
  `modules/widget-bridge/`. Where `WidgetBridgeModule.swift` writes to `UserDefaults(suiteName:)`
  for same-device widget reads, `watch-bridge` wraps `WCSession` to push/pull data across the
  device boundary.
- **JS side:** `utils/watchBridge.ts`, mirroring `utils/widgetBridge.ts`'s shape —
  `requireOptionalNativeModule("WatchBridge")` guarded, strict no-op when the module is absent
  (Android, Expo Go, pre-watch-target builds) or no watch is paired. Never throws.

## Data flow

1. **Phone → Watch (snapshot mirror).** Every site that already calls `refreshWidgetSnapshot`
   (job/invoice save, sign-in, foreground re-pull) also calls
   `WCSession.updateApplicationContext` with the **same** `WidgetSnapshot` struct already defined
   for the widgets (next job, active timer). No new snapshot shape, no new selection logic —
   `selectNextJob`/`selectActiveTimer` are reused as-is.
2. **Watch UI.** SwiftUI view: job title + status text, Clock In / Clock Out buttons. Exactly one
   button is enabled at a time, driven by whether the mirrored snapshot shows an active timer —
   the same rule the Job Timer widget already follows. If clocked in, an elapsed-time label uses
   the same `Text(date, style: .timer)` live-updating pattern as the widget.
3. **Watch → Phone (button tap).** The watch writes the action to `WCSession.transferUserInfo`
   (OS-queued, guaranteed delivery once reachable — survives the phone being locked, backgrounded,
   or briefly out of Bluetooth/WiFi range; does **not** require `sendMessage`'s live-reachability).
   The watch immediately renders optimistic pending state, mirroring the widget's existing
   optimistic-render pattern.
4. **Phone receives the transfer** (delivered even while the app is backgrounded) → appends into
   the **existing** `widgetActions` pendingActions queue with `type: timer_start` /
   `timer_stop` → the **existing** replay layer runs unchanged: `applyClockIn`/`applyClockOut`
   (pure functions in `timeTracking`), the done-status guard that already lives only in the replay
   layer. Replay ends in a snapshot refresh, which re-triggers step 1 and pushes the updated state
   back to the watch — closing the loop with no new business logic anywhere.

## Edge cases

- **Signed out on phone** → mirrored snapshot is the existing "blank" shape, both buttons
  disabled on the watch — matches sign-out already blanking the widgets.
- **Phone unreachable when the button is tapped** → the action sits in `transferUserInfo`'s
  OS-managed queue (survives watch app termination) and delivers automatically on reconnect; the
  watch UI stays in "pending" until the context round-trips back with the new state. No timeout,
  no error toast — same fail-safe posture as the Siri replay queue.
- **No next job / no active session** → both buttons render a neutral empty/disabled state, no
  crash — mirrors `selectNextJob`'s existing null-safe design.
- **Watch app opened while phone data is stale** (e.g. watch reconnects after being out of range
  for hours) → `updateApplicationContext` only keeps the *latest* context (by design, it
  coalesces), so the watch always converges to current truth on next delivery rather than
  replaying a backlog of stale snapshots.

## Testing / smoke plan

- **Unit tests** for `utils/watchBridge.ts`: null-module no-op, snapshot pass-through shape
  parity with `widgetBridge.test.ts` (same fixtures, same null/undefined edge cases).
- **Device smoke** (paired Watch + iPhone, mirrors the Tier-1/Tier-2 widget smoke checklists in
  `docs/release-runbook-1.2.0.md`):
  - Tap Clock In on the watch → phone-side job session becomes real (verify in-app).
  - Tap Clock Out on the watch → the job's time entry closes with a sane duration.
  - Lock the phone / step out of Bluetooth range, tap Clock In, reconnect → action delivers and
    both watch and phone converge to the same state.
  - Sign out on the phone → watch app blanks (buttons disabled, no stale job title).
  - Cold-start the watch app with no prior context delivered yet → neutral empty state, no crash.

## Out of scope (this phase)

- Watch-face complication (`watch-widget` target) — a natural follow-up once the app target is
  proven, not required to meet "clock in/out from the wrist."
- Siri-on-watch — may already work via the existing `AppShortcutsProvider` with zero new native
  code; worth a five-minute TestFlight check before this phase kicks off, since it could shrink
  scope further, but isn't a blocking dependency for this design.
- Standalone network access (watch working with the phone fully absent, e.g. left at home) —
  would require duplicating auth/session/clock-in logic natively; deliberately rejected above.
- Any watch action beyond Clock In/Out (e.g. logging an expense, viewing the day's schedule).

## Related

- `docs/widget-plan.md` — the widget/Siri precedent this design reuses (WidgetSnapshot,
  pendingActions replay layer, `requireOptionalNativeModule` guard pattern).
- `docs/release-runbook-1.2.0.md` — why this phase is sequenced after, not inside, 1.2.0.
