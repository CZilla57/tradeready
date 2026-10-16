# Stage A results: blank template

Fill this in and send it back (paste it, or tell me the file is saved). Not committed; delete when done.

Rules
- Result is one of: pass, fail, not run. Write "not run" for anything you didn't do. Never guess.
- Notes are short. No emails, Apple IDs, tester names, payment details or IDs: use aliases (A, B, ...).
- For any fail, say what you saw. I will open a P12- defect row.

## Run record

Run number: 1
Date: 10/1/2026
Native builds tested: 2.0.0 (1) / 2.0.0 (2)   (build 1 stalled on "Data migration paused", fixed in build 2)
Devices and iOS versions: 
Accounts (aliases only): 
Environment: production-configured build (R59), disposable team accounts, synthetic data
Expo build upgraded from: App Store 1.2.1  (confirm)
Time from upload to "Processed": 
SA2 upgrade duration (install over Expo to data ready): 

## 1. SA2 upgrade run

P2-P1: [pass] — Clean install
    note: 
P2-P2: [pass] — Sample account
    note: 
P2-P3: [pass] — Large account
    note: 
P2-P4: [pass] — Offline account
    note: 
P2-P5: [not run] — Partially synced account
    note: 
P2-P6: [pass] — Interrupted migration
    note: 
P2-P7: [pass] — Account mismatch
    note: 
P2-P8: [not run] — Corruption recovery
    note: 
P2-RB: [pass] — Rollback rehearsal (Phase 2)
    note: 
P12-3B-1 (subscription continuity):
    part 1, purchase made on Expo is honored after upgrade: [pass]
    part 2, Restore Purchases attaches the Expo purchase: [pass]
    part 3, fresh sandbox purchase works on native: [not run]
    entitlement state seen (active / trial / none): 
    note: 
P12-3B-2 (Sign in with Apple, same account after upgrade): [pass]
    note: 

## 2. Widgets, Siri, packaging, owner gating

JT-1: [pass] — Add Job Timer small and medium; drive it through all seven states
    note: 
JT-2: [pass] — Tap Start, then Stop, on the widget; then open the app
    note: 
JT-3: [pass] — Double-tap Start (two taps before the first reload lands)
    note: 
JT-4: [pass] — Leave the device 24 h with the app closed, once with a timer running and once without
    note: 
JT-5: [pass] — Where interactive widgets are unavailable (StandBy), tap the card
    note: 
SIRI-1: [pass] — Open the Shortcuts app; speak each §5.2 phrase
    note: 
SIRI-2: [pass] — "Start a trip in TradeReady" with an odometer, then "Stop my trip …"
    note: 
SIRI-3: [pass] — "Log an expense …" with an amount and category
    note: 
SIRI-4: [pass] — "I'm on my way in TradeReady", once from a cold app and once warm
    note: 
SIRI-5: [pass] — Sign out, then run every writing intent
    note: 
SIRI-6: [pass] — "What's my next job …" and "How much am I owed …" with data, with none, and with a snapshot older than 24 h
    note: 
NJ-1: [pass] — Add Next Job small and medium to the gallery preview and the Home Screen
    note: 
NJ-2: [pass] — Tap a .job card; then tap each other state (empty, signed out, stale)
    note: 
NJ-3: [pass] — Leave the device 24 h with the app closed, then open the app
    note: 
EXT-1: [pass] — Install REL. Long-press the Home Screen, open the widget gallery, search TradeReady
    note: 
EXT-2: [pass] — Sign in, create a job with a start time, background the app
    note: 
EXT-3: [pass] — With widgets on the Home Screen: sign out; separately, delete the account
    note: 
EXT-4: [pass] — Archive the stage build (12.01, owner-approved) and inspect TradeReadyWidgets.appex and the app bundle
    note: 
OWN-1: [pass] — Sign out with widgets on the Home Screen, then ask Siri "Clock in"
    note: 
OWN-2: [pass] — Queue a widget action as account A, sign out, sign in as account B
    note: 
OWN-3: [pass] — Run a widget or Siri action against a deleted, then an archived, job; separately leave a widget 24 h withou…
    note: 

## 3. Crash reporting (Sentry)

CR-1: [not run] — After OI-2: archive with TRADEREADY_SENTRY_DSN set, then SENTRY_AUTH_TOKEN=… sh native/scripts/upload-sentr…
    note: 
CR-2: [not run] — Trigger a test crash and a deleteAccount failure
    note: 
CR-3: [not run] — Queue a change offline, then make the push fail
    note: 
CR-4: [not run] — Use the app across several sessions
    note: 
CR-5: [not run] — A DBG build and a REL without the DSN
    note: 
CR-6: [not run] — On the CR-2 events, inspect the full stored event JSON
    note: 
CR-7: [not run] — Report a non-Error (plain-object) failure through reportError
    note: 
CR-8: [not run] — Inspect a sampled transaction and its spans
    note: 
CR-9: [not run] — Inspect the archive's dSYMs
    note: 

## 4. Rollback

P12-RB-2: [pass] — Rollback rehearsal, native → Expo (12.06 step 5, T0 and T1): the drain before any advisory and …
    note: 
P12-RB-3: [pass] — Rollback rehearsal, Expo → native (12.06 step 5, T2): a migrated, signed-in device never re-imp…
    note: 
P12-RB-4: [pass] — Check everything is saved (12.06, CH §6 rule 2) on a device: each state, accessibility and the …
    note: 
P12-RB-5: [pass] — SC4 after the rollback round trip: the legacy migration code path still runs in N2
    note: 
P12-RB-7: [pass] — P12-011 on a device (12.06 step 5, CH §6 rule 3): a native-only install signed out before the E…
    note: 

## 5. Baselines (from the runs above)

Cold launch (ms): 
Warm launch (ms): 
Crash-free sessions (%): 
Sync error rate (%): 
Migration timing (s): 

## 6. Defects and follow-ups

Defects found (describe; I will number them P12-...): 
Rows you want moved to Stage B: 
Anything unexpected on screen: 

## 7. Not covered here

About 280 other Stage A rows (phases 3 to 10 and the rest of Phase 11) are separate test passes. List any you did run, one line each, in the same format.
