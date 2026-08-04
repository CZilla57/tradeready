# Release runbook — 1.2.0 (widgets, Siri, background refresh)

**Created 2026-08-03.** The ordered path from "1.1.0 sitting in App Review" to
"1.2.0 with widgets live on the store." The ORDER is load-bearing: the version
bump changes `runtimeVersion` (policy `appVersion`), so bumping before the
1.1.0 OTA ships would strand build-7 users on stale JS forever.

## Sequence

1. **GATE (owner): Apple approves 1.1.0 / build 7** (in review since
   2026-08-01). Only the owner sees the resolution email / App Store Connect.

2. **OTA the accumulated JS to 1.1.0 users** — the FIRST and LAST over-the-air
   update for build-7 users, carrying everything since `c4ec829` (QoL batch,
   estimate nudges, smart pickers, iPad Tier-1 JS, security fixes, widget JS —
   all designed as guarded no-ops where build 7 lacks native support):
   - Confirm master gate + CI green, tree clean.
   - Confirm master includes the `utils/backgroundRefresh.ts` guarded-require
     fix (fix commit, not the original Task 1 feat commit) — the pre-fix
     version statically imports `expo-task-manager`/`expo-background-task`,
     and both packages throw at module scope when their native module is
     absent, which is true of every build-7/9/10 binary; OTA-ing the pre-fix
     version crashes the app at launch for every build-7/9/10 user.
   - `npx eas-cli update --channel production --message "<summary>"`
     (reaches ONLY runtime 1.1.0: build 7 + TestFlight builds 9/10).
   - Owner smoke on the production app after the update lands.

3. **Bump `expo.version` → `1.2.0`** in app.json (one line; commit). From this
   commit on, builds and OTA updates target the 1.2.0 runtime.

4. **EAS build** (`npx eas-cli build --platform ios --profile production
   --non-interactive`). First 1.2.0-runtime binary; carries widgets + Siri
   Tiers 1–2, background refresh, iPad tablet capability, the iOS 17.0 floor,
   and the flat brand icon/splash.

5. **TestFlight smoke** (checklist below), then
   `npx eas-cli submit --platform ios --id <build-id> --non-interactive`.

6. **App Store submission (owner, in ASC):** attach the new build to a 1.2.0
   version, what's-new text, screenshots including the widgets. Claims
   discipline: widgets/Siri may be claimed once the Tier-2 smoke passes.
   The listing's minimum-OS shows iOS 17 automatically.

7. **Post-approval:** production-channel OTAs now serve the 1.2.0 runtime.
   Build-7 users receive nothing further over the air (their last update was
   step 2); they get 1.2.0 via the store.

## Tier-2 smoke checklist (next TestFlight build)

- Shortcuts app lists **eight** TradeReady actions (four Tier-1 + Clock In,
  Clock Out, Log Expense, How Much Am I Owed).
- "Clock in in TradeReady" → confirms with the next job's title; open app →
  session is real; "Clock out in TradeReady" closes it.
- "Log an expense in TradeReady" → Siri collects amount, category, and
  what-for by voice; expense appears in Money under the SAME category label
  Siri spoke.
- "How much am I owed in TradeReady" → number matches the Invoices tab's
  Outstanding stat.
- Trip staleness escape: with a stale (>24h) unfinished Siri trip, "start a
  trip" says "previous trip was never finished" and starts fresh.
- Background refresh is opportunistic (iOS decides; minimum interval 30 min,
  typically hours): passively verify over a day that widgets update without
  the app being opened — no deterministic test exists off-device.
- Tier-1 regression: all four original Siri flows, both widgets, timer
  round-trip from the widget, sign-out blanks everything.
