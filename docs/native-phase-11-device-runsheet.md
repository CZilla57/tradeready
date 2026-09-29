# Phase 11 Device Runsheet (scheduled for Phase 12)

Per the 2026-09-16 deferral decision
([roadmap](native-ios-migration-roadmap.md#verification-deferral-decision-2026-09-16)),
the physical-device, home-screen, Siri, extension, live-SDK, store and soak rows below
are **scheduled work for Phase 12**, not per-phase gates. Host evidence (the focused
Swift runners, the RN oracle suites, the aggregate suite, the unsigned Release build and
the signed local Release build) gates **code complete**; the rows here gate `Verified`.
**No row below has been run. None is claimed as passed.**

Scope: Phase 11 (WidgetKit, App Intents/Siri, deep-link routing, analytics, crash
reporting, AI key entry, accessibility, iPad layout, performance and soak, cross-client
qualification). Sources:

- [native-phase-11-implementation-plan.md](native-phase-11-implementation-plan.md) §7,
  the per-task "Runsheet rows" and "Phase 12 deferrals" blocks (each row below names its
  source task);
- [native-phase-11-platform-hardening-contract-decisions.md](native-phase-11-platform-hardening-contract-decisions.md)
  §13 (device matrix) and §17.2 (gaps G1–G6);
- [native-phase-11-performance.md](native-phase-11-performance.md) (PERF-1 to PERF-10,
  SOAK-1 to SOAK-6; that document keeps the full measurement protocol);
- the Phase 11 progress ledger's Phase 12 carries (owned items below).

Phase 12 task 12.03 consolidates these rows into `docs/native-phase-12-evidence-index.md`
(created by 12.03) and assigns each a stage; see
[native-phase-12-implementation-plan.md](native-phase-12-implementation-plan.md). This
runsheet uses per-row ID tables (ID, requirement, steps, expected result,
environment/build, evidence) instead of the numbered checklists the Phase 7, 9 and 10
runsheets use, and 12.03 reuses this row shape for every row in the evidence index.

Conventions: `[ ]` open, `[x]` passed with an evidence link and date. Record the device
model, OS version, account, build number and date in the Evidence column. Use synthetic
data in a team or staging account; never production customer data. A failing row is
recorded as a defect with the build number, never silently waived.

## Environment and build codes

| Code | Meaning |
|---|---|
| **REL** | The signed Release build of the stage (the 12.04 internal TestFlight build; record the build number). Never a Debug build for a timing or delivery row. The widget extension `TradeReadyWidgets.appex` must be embedded (11.14 confirmed this for a signed local build; see plan §7, 11.14) |
| **REL+KEYS** | REL with a staging PostHog key (`TRADEREADY_POSTHOG_API_KEY`, `TRADEREADY_POSTHOG_HOST`) and a staging Sentry DSN (`TRADEREADY_SENTRY_DSN`) supplied at build time. Nothing is committed; a keyless REL sends nothing |
| **DBG** | A Debug build, used only to prove it sends nothing |
| **SE17** | iPhone SE-class on iOS 17.x (the floor: small screen, AX5, iOS 17 interactive widgets) |
| **STD18** | A standard iPhone on iOS 18.x (widgets, Siri, Control Center) |
| **PM27** | iPhone 16 Pro Max on iOS 27.0 (the existing row in `docs/native-phase-3-device-matrix.md`; launch and soak baselines) |
| **IPAD** | iPad 11-inch and iPad mini on iPadOS 27 (and an iPad 13-inch where a row says so) |
| **STG** | The trusted isolated staging backend only. Phase 12 12.03 records whether it exists. `https://staging.invalid` stays until it does; production is never substituted. A row that needs STG is blocked, not waived, while staging is missing |
| **RN-UP** | A device upgraded in place from the App Store Expo build (no delete), as in Phase 12 Stage A |

## Owned items and open gates (not device rows)

These are named decisions, gaps or policy questions carried out of Phase 11. They are
listed so no dependency is silently waived. Each has an owner; the Phase 12 owner
either builds it, decides it, or records a dated waiver.

| ID | Item | Owner | Blocking | Source |
|---|---|---|---|---|
| G1 | **No native remote push.** RN tracks push-notification taps (`booking_request_opened`, `booking_update_opened`); native has no remote-push surface, so both events are never emitted and booking push alerts do not exist natively. Build native remote push or take a dated waiver | **Phase 12.00** | **Cutover-blocking** | contract §17.2 G1; roadmap Phase 12 "Cutover-blocking parity gaps" |
| G2 | **No native tax-settings screen.** Native has `N/Domain/NativeTaxSettings.swift` and `AppStore.commitTaxSettings`, but no view calls it, so the income-tax rate and vehicle method the Money tax card prompts for cannot be set natively, and `tax_settings_saved` is unreachable. Build the editor (RN `components/money/TaxSettingsModal.tsx`) or take a dated waiver | **Phase 12.00** | **Cutover-blocking** | contract §17.2 G2; parity matrix "Tax set-aside" row |
| G6 | **RN AsyncStorage source files on an upgraded device** may still hold an RN-era plaintext Square token. Native's own `LegacyBackups/` copies are protected and backup-excluded (fix round 3; row Q11-P12-6); the RN app's original files are not touched. Decide the migration/recovery retention policy (delete after a successful import, or keep with protection) | **Phase 12.00** (migration/recovery retention policy) | Decide before Stage A upgrade runs | contract §17.2 G6 |
| OI-1 | **§8.2 collected-data list omits first-party backend data**: the sign-in email, synced business records and job photos. Decide their App Store privacy-label declaration (App Functionality, linked) before the labels are entered, and update the app `PrivacyInfo.xcprivacy` if needed | **Phase 12.01** | Blocks App Store privacy labels | contract §8.2, §8.3; 11.09 runsheet |
| OI-2 | **Sentry project `tradeready-ios` must exist in org `tradeready-3r`** before the first dSYM upload (`native/scripts/upload-sentry-dsyms.sh` no-ops without `SENTRY_AUTH_TOKEN`) | **Phase 12.01 / 12.02** (owner-held Sentry account) | Blocks CR-1 | 11.09 ruling (dSYM script, no build phase) |
| OI-3 | **429 push policy.** Under a 429 the sync push still sends every queued item once per pass; passes are bounded by the coordinator's exponential backoff, base 5 s doubling to a 300 s cap (`N/NativeSyncCoordinator.swift:140-141,388`; manual syncs bypass it), with no early stop inside a pass. The poor-network test harness uses a 30 s base for faster runs (`native/PoorNetworkTests/main.swift:225`) — that value is the harness's, not the app's. Decide whether the app's real backoff is acceptable against the real rate limit, and monitor it | **Phase 12.00** (policy); **12.02** (monitored signal, PERF-7) | Monitor/policy question, not a known defect | plan §7, 11.12 ("Under a 429 …"); `docs/native-phase-11-performance.md` scenario B |
| I2 | **Sync push wedges on a non-auth 4xx.** `NativeSupabasePush` treats 400/404/409/413/422 (and a 403 that repeats after refresh) as transient and retains the mutation forever, and `NativeSyncCoordinator`'s `guard queue.load().isEmpty` skips every pull while anything is queued, so one poison mutation stops inbound sync and an RLS 403 loops. Fix sketch: classify those as `.rejected`; move them to an app-private, owner-scoped rejected store scrubbed at every account boundary; a bounded diagnostic; "N changes couldn't sync" on Cloud Sync; then decide relaxing the pull guard toward RN parity (RN always pulls after push, `utils/sync.ts` `pushQueue`:149-214 / `syncIfOnline`:316-326), mindful of the 11.12 per-table rebase. Test: a poor-network poison-item scenario in `native/PoorNetworkTests/main.swift` (good items push, inbound pulls continue, and the poison item reaches the rejected store exactly once). Implemented by Phase 12 12.00b.1 (`docs/native-phase-12-implementation-plan.md`). Recorded by the Phase 11 final review, not fixed. **Fixed on native/phase-12 by Phase 12 12.00b.1 (2026-09-25), host evidence only:** a non-auth 4xx leaves the queue for the owner-scoped rejected-change store, Settings › Cloud Sync lists it with Retry and Discard, and the coordinator pulls after every push pass that returns per-item results (a push that throws skips it; contract §17.2 "Known issues" 2). Device rows are still needed: P12-B1-1 (a poison change on a real device against STG) and P12-B1-2 (the Cloud Sync surface with VoiceOver and Dynamic Type), `docs/native-phase-12-evidence-index.md` §23 | **Phase 12.00** | **Cutover-blocking** until P12-B1-1 and P12-B1-2 pass | contract §17.2 "Known issues" 2; roadmap Phase 12 |
| OI-4 | **Known code issues carried to the Phase 11 final whole-branch review.** Dispositions: (1) `NativeRecurringInvoicesView` "Cancel plan"/"Delete plan" no-op: fixed (`8146cd6`, `run-recurring-invoice`; device row Q11-P12-7); (2) `NativeSupabasePush` non-auth 4xx wedge: not fixed, re-owned as row I2 above; (3) `useAnotherAccount` App Group scrub fail-open: fixed (`5f2f397`, `run-widget-owner-gating`); (4) silent AI-key wipe failure: fixed (`5f2f397`, `run-ai-provider-key`); (5) `deepLinkOwnerWasActive` keyed on O: fixed (`2e70415`, `run-deep-link-routing`). The review also fixed widget/Siri replay not enqueuing its writes (C1, `2f4ed28`; device row Q11-P12-8) | **Phase 11 final review** (1, 3, 4, 5: fixed); **Phase 12.00** (2, as I2) | Closed for Phase 11; I2 is cutover-blocking | contract §17.2 "Known issues" 1, 2, 4, 5, 6; plan §7 "Final review fix wave" |

## Build and extension packaging (11.01, 11.14)

| ID | Req | Steps | Expected result | Env / build | Evidence |
|---|---|---|---|---|---|
| EXT-1 | W1 | Install REL. Long-press the Home Screen, open the widget gallery, search TradeReady | Next Job (small, medium) and Job Timer (small, medium) are listed | REL, STD18 and SE17 | [ ] |
| EXT-2 | W1 | Sign in, create a job with a start time, background the app | The app writes `widgetSnapshot` into the real App Group container, and the widgets' timelines reload with the new job | REL, STD18, STG | [ ] |
| EXT-3 | W1, W4 | With widgets on the Home Screen: sign out; separately, delete the account | The App Group container is emptied and both widgets blank to the signed-out state | REL, STD18, STG | [ ] |
| EXT-4 | M1 | Archive the stage build (12.01, owner-approved) and inspect `TradeReadyWidgets.appex` and the app bundle | `PrivacyInfo.xcprivacy` is present in both; the extension declares no collected data; the app matches contract §8 (and OI-1's decision) | Archive of REL | [ ] |

## Next Job widget (11.02)

| ID | Req | Steps | Expected result | Env / build | Evidence |
|---|---|---|---|---|---|
| NJ-1 | W2 | Add Next Job small and medium to the gallery preview and the Home Screen | Both families are correctly sized and legible | REL, SE17, STD18, IPAD | [ ] |
| NJ-2 | W2, L1 | Tap a `.job` card; then tap each other state (empty, signed out, stale) | The job card opens the app at the linked job; every other state opens the app root | REL, STD18 | [ ] |
| NJ-3 | W2, W4 | Leave the device 24 h with the app closed, then open the app | After 24 h the widget shows the stale state; it recovers on the next app-triggered reload | REL, STD18 | [ ] |

## Job Timer widget (11.03)

| ID | Req | Steps | Expected result | Env / build | Evidence |
|---|---|---|---|---|---|
| JT-1 | W3 | Add Job Timer small and medium; drive it through all seven states | Every state renders sized and legible in the gallery and on the Home Screen | REL, SE17, STD18 | [ ] |
| JT-2 | W3, A3 | Tap Start, then Stop, on the widget; then open the app | Each tap queues an action; the widget shows the pending state within one reload; the app replays it into canonical state on the next foreground or launch | REL, SE17 (iOS 17 interactive floor), STD18 | [ ] |
| JT-3 | W3, A3 | Double-tap Start (two taps before the first reload lands) | Never two applied timer transitions | REL, STD18 | [ ] |
| JT-4 | W3, W4 | Leave the device 24 h with the app closed, once with a timer running and once without | The stale-but-running and stale-with-no-timer states show; both recover on the next app-triggered reload | REL, STD18 | [ ] |
| JT-5 | W3 | Where interactive widgets are unavailable (StandBy), tap the card | The whole-card fallback opens the correct job or the app root | REL, STD18 | [ ] |

## App Intents and Siri (11.04)

| ID | Req | Steps | Expected result | Env / build | Evidence |
|---|---|---|---|---|---|
| SIRI-1 | A1, A2 | Open the Shortcuts app; speak each §5.2 phrase | All eight app shortcuts are listed (Start/Stop Timer are not discoverable), and each phrase triggers its intent | REL, STD18, SE17 | [ ] |
| SIRI-2 | A2, A3 | "Start a trip in TradeReady" with an odometer, then "Stop my trip …" | One trip is logged with the right miles, exactly once (`t_siri_` id) | REL, STD18, STG | [ ] |
| SIRI-3 | A2, A3 | "Log an expense …" with an amount and category | The §5.3 category labels are offered; the replay records the spoken amount (`e_siri_` id) | REL, STD18 | [ ] |
| SIRI-4 | A1, L1 | "I'm on my way in TradeReady", once from a cold app and once warm | The review sheet for the next job opens once; nothing is sent automatically | REL, STD18 | [ ] |
| SIRI-5 | A2, W4 | Sign out, then run every writing intent | Each answers "Open TradeReady and sign in first." and the container stays empty | REL, STD18 | [ ] |
| SIRI-6 | A2 | "What's my next job …" and "How much am I owed …" with data, with none, and with a snapshot older than 24 h | The §5.1 dialogs; the stale snapshot is refused | REL, STD18 | [ ] |

## Owner gating and stale data (11.05)

| ID | Req | Steps | Expected result | Env / build | Evidence |
|---|---|---|---|---|---|
| OWN-1 | W4 | Sign out with widgets on the Home Screen, then ask Siri "Clock in" | Both widgets clear within one reload; Siri answers with the sign-in prompt | REL, STD18, STG | [ ] |
| OWN-2 | W4, A3 | Queue a widget action as account A, sign out, sign in as account B | The widgets show only B's data; A's queued action is never applied | REL, STD18, STG (two team accounts) | [ ] |
| OWN-3 | W4, L2 | Run a widget or Siri action against a deleted, then an archived, job; separately leave a widget 24 h without the app | Each fails closed with no wrong-record route | REL, STD18 | [ ] |

## Deep links and routing gates (11.06)

| ID | Req | Steps | Expected result | Env / build | Evidence |
|---|---|---|---|---|---|
| DL-1 | L1, L2 | Cold launch from a Next Job or Job Timer tap while signed in; repeat signed out, then sign in as the same owner; repeat, then sign in as a different owner | Signed in: the exact job opens. Signed out: it opens after the same owner signs in. A different owner: nothing opens | REL, STD18, STG | [ ] |
| DL-2 | A1, L1 | Siri "On My Way", warm and from a cold launch | One editable review, never twice, never sent automatically | REL, STD18 | [ ] |
| DL-3 | L2 | Widget tap on an archived job, on a deleted job, and on an archived job with a running timer | Archived or deleted: "Job not found". Archived with a running timer: the job opens | REL, STD18 | [ ] |
| DL-4 | L1 | Park a widget link while signed out, then complete Google Sign-In | Sign-in completes; the parked link then routes per DL-1 | REL, STD18, STG | [ ] |
| DL-5 | L1 | Tap an `est_` notification for an archived estimate | Its follow-up review opens | REL, STD18 | [ ] |
| DL-6 | L2 | Trigger "Job not found" while another sheet is up (an On My Way review, an estimate follow-up, a job editor) | The sheet appears on top or after the other closes, is never silently lost, and Done dismisses only it | REL, STD18, IPAD | [ ] |

## Analytics (11.07, 11.08)

| ID | Req | Steps | Expected result | Env / build | Evidence |
|---|---|---|---|---|---|
| AN-1 | P1 | REL+KEYS: use the app for a session. Then a DBG build and a keyless REL | REL+KEYS sends catalog events, `Application Opened`/`Backgrounded` and `$identify` to the staging PostHog project. DBG and keyless REL send nothing (proxy or live view) | REL+KEYS, DBG, REL; STD18 | [ ] |
| AN-2 | P4 | A REL+KEYS session exercising every tab | No `$autocapture`, `$rageclick`, `$exception`, push or feature-flag event arrives; every event carries only allow-listed properties | REL+KEYS, STD18 | [ ] |
| AN-3 | P3 | Sign in with a password, with Apple and with Google; then sign out, "Use another account" and delete the account | Each sign-in shows `$identify` with the Supabase id and `sign_in{method}`. Each exit shows a reset (a new anonymous distinct id) before the next owner's first event | REL+KEYS, STD18, STG | [ ] |
| AN-4 | P2 | Navigate the tabs and detail screens | `$screen` arrives with the RN leaf route names | REL+KEYS, STD18 | [ ] |
| AN-5 | P2 | Tap an estimate follow-up, an overdue-invoice and an appointment notification | Each sends its `*_opened` event once | REL+KEYS, STD18 | [ ] |
| AN-6 | P2 | Run onboarding and the paywall on a fresh account | `welcome` → `business` → `starting_point`, and `subscription_paywall_shown{onboarding_gate}` once per presentation | REL+KEYS, STD18, STG | [ ] |

## Crash reporting and privacy manifest (11.09)

| ID | Req | Steps | Expected result | Env / build | Evidence |
|---|---|---|---|---|---|
| CR-1 | R1 | After OI-2: archive with `TRADEREADY_SENTRY_DSN` set, then `SENTRY_AUTH_TOKEN=… sh native/scripts/upload-sentry-dsyms.sh <App.xcarchive>` (add `SENTRY_INCLUDE_SOURCES=1` only if uploading source is intended) | Sentry lists the app and widget dSYMs; no source bundle is sent by default | Archive of REL+KEYS | [ ] |
| CR-2 | R1, R2 | Trigger a test crash and a `deleteAccount` failure | Each arrives symbolicated with `release = <bundle>@<version>+<build>`, `environment`, user `{id}` only (no email, IP or device name) and a `[Filtered]` URL token | REL+KEYS, STD18, STG | [ ] |
| CR-3 | R3 | Queue a change offline, then make the push fail | One `pushQueue` issue titled `[<code>] Sync push left changes queued` | REL+KEYS, STD18, STG | [ ] |
| CR-4 | R1 | Use the app across several sessions | Sessions appear under Release Health; traces sample at about 20 % | REL+KEYS, STD18 | [ ] |
| CR-5 | R1 | A DBG build and a REL without the DSN | Nothing is sent | DBG, REL; STD18 | [ ] |
| CR-6 | R2 | On the CR-2 events, inspect the full stored event JSON | Every field the SDK writes back after `beforeSend` (device context, breadcrumbs, request, threads) is covered by the redactor: no secret, token, email or customer text survives | REL+KEYS, STD18 | [ ] |
| CR-7 | R3 | Report a non-`Error` (plain-object) failure through `reportError` | The Sentry issue title is the `NSDebugDescriptionErrorKey` text, redacted, as contract §10.4 records | REL+KEYS, STD18 | [ ] |
| CR-8 | R2 | Inspect a sampled transaction and its spans | Transaction and span descriptions/data are redacted; the only redaction path for transactions is `beforeSendSpan` (confirm nothing unredacted reaches Sentry through another path) | REL+KEYS, STD18 | [ ] |
| CR-9 | R1 | Inspect the archive's dSYMs | Release produces dSYMs (`DEBUG_INFORMATION_FORMAT` resolves to `dwarf-with-dsym`; the project sets no override); each dSYM's UUID matches the binary (`dwarfdump --uuid`) and Sentry symbolicates CR-2 with it | Archive of REL | [ ] |
| PRIV-1 | M1 | Enter the App Store Connect privacy labels (12.01) | The labels match the app `PrivacyInfo.xcprivacy` and the OI-1 decision (email, synced records, photos) | App Store Connect (owner) | [ ] |

## Settings › AI Assistant keys (11.15)

| ID | Req | Steps | Expected result | Env / build | Evidence |
|---|---|---|---|---|---|
| AI-1 | P4 | Switch Advanced on; save a real Groq key, then a real Anthropic key; remove Anthropic; remove both | The Provider row reads Groq, then "Anthropic (Claude)", and the coach answers through that provider. Without Anthropic: Groq. Without both: TradeReady AI (backend) | REL, STD18 (owner-held provider keys) | [ ] |
| AI-2 | P4 | VoiceOver through the Advanced section | It reads "Advanced AI settings", "Groq API key" and "Anthropic API key"; the field shows dots; the status reads only "Saved"; the key is never spoken | REL, STD18 | [ ] |
| AI-3 | P4 | Sign out and back in; separately delete the account | Both keys are gone after each | REL, STD18, STG | [ ] |
| AI-4 | P4 | Save both keys. "Use another account" from "Cloud data unavailable" and sign in as B; repeat with the password-recovery link (cancel it; separately finish it) | B sees "Not set" for both keys and the Provider row reads TradeReady AI; no key survives either exit (see OI-4 items 3 and 4) | REL, STD18, STG | [ ] |
| AI-5 | P4, R2 | REL+KEYS: enter a key, send a coach message | No Sentry event, PostHog event or `$screen` payload contains the key | REL+KEYS, STD18 | [ ] |

## Accessibility (11.10a, 11.10b)

Row IDs are the ones the tasks assigned (plan §7).

| ID | Req | Steps | Expected result | Env / build | Evidence |
|---|---|---|---|---|---|
| A11-VO-1 | H1 | VoiceOver sweep of Today, Jobs, Invoices, Customers, Money and Settings, plus the booking, route and recurring plus buttons | Every control reads a meaningful label; none reads "Button" or "plus" | REL, STD18 | [ ] |
| A11-VO-2 | H1 | Today job card: reach "On my way" with VoiceOver (A13) | Reachable and actionable | REL, STD18 | [ ] |
| A11-VO-3 | H1 | Reading order on Today, Money and Job detail (A12) | Order follows the visual layout | REL, STD18 | [ ] |
| A11-AX5-1 | H1 | AX5 on the Money cards, Today stats, Jobs stats and Invoices metrics | Rows stack; no amount is truncated or split | REL, SE17 | [ ] |
| A11-AX5-2 | H1 | AX5 on the auth and recovery submit buttons, the paywall and onboarding | Labels are not clipped; buttons grow | REL, SE17 | [ ] |
| A11-AX5-3 | H1 | AX5 on the week strip | Capped at AX1 without overlap; VoiceOver reads each day | REL, SE17 | [ ] |
| A11-DARK-1 | H1 | Dark mode: tint text and outlines, prominent buttons, selected chips, week day, Today hero, working days | Legible; the selected state is visible; white labels sit on the fill | REL, STD18 | [ ] |
| A11-RM-1 | H1 | Reduce Motion on: Money section expand, coach scroll-to-bottom | No animation | REL, STD18 | [ ] |
| A11-SC-1 | H1 | Switch Control on auth (email → password → submit), schedule working days, route reorder | Items are reachable in order; 44 pt targets activate | REL, STD18 | [ ] |
| A11-KB-1 | H1 | Hardware keyboard on auth and recovery: Return chains | Email → password → submit; new password → confirmation → submit | REL, IPAD | [ ] |
| A11-TT-1 | H1 | Touch targets: week arrows, route chevrons, working days | Each hits on the first tap | REL, SE17 | [ ] |
| A11-IC-1 | H1 | Increase Contrast on and off, light and dark | No regression against the §12.1 table | REL, STD18 | [ ] |
| A11-W-1 | H1 | Widgets at AX sizes (A9) | The fixed canvas is legible, matching RN | REL, STD18 | [ ] |
| A11B-KB-1 | H1 | iPad hardware keyboard: hold ⌘ on Jobs, Invoices, Customers, Maintenance plans and Coach | The HUD lists "Add new job", "Add new invoice", "Add new customer", "Add maintenance plan" and "New chat", with no blank entry | REL, IPAD | [ ] |
| A11B-KB-2 | H1 | Done bar on a price/rate/phone field and a notes field in the job, invoice, expense, trip and pricebook editors and Settings › Pricing | "Done" shows above the keyboard, reads "Dismiss keyboard", dismisses it, and appears once | REL, STD18 | [ ] |
| A11B-VO-1 | H1 | VoiceOver on the Money charts (Last 6 Months, 12-Month Trend, Expense Trends) | One element per chart reads "{title} chart" and every month with its figures | REL, STD18 | [ ] |
| A11B-VO-2 | H1 | VoiceOver on the Today job card: swipe up or down for actions | "On my way to {name}" is offered and sends | REL, STD18 | [ ] |
| A11B-VO-3 | H1 | VoiceOver on a job photo whose delete or visibility change failed | The error is read after "Open job photo" | REL, STD18 | [ ] |
| A11B-DARK-1 | H1 | Dark mode: clock out, sheet error text, the Money danger tone, the booking "Cancelled" kind | Rust text and fills are legible; white text sits on the fill | REL, STD18 | [ ] |
| A11B-AX5-1 | H1 | AX5: Today schedule, booking requests, route list and preview, job photos, Settings avatar and sync badge | Time and kind sit above their rows; nothing clips; at least one photo fits the row | REL, SE17 | [ ] |
| A11B-TT-1 | H1 | Tap the Today card's "On my way" at its edge | It sends "On my way" instead of opening the job | REL, SE17 | [ ] |
| A11B-FR1-1 | H1 | Light and dark: Settings Sign out and Delete account, the delete sheet's toolbar Delete (enabled and disabled), the paywall Sign out, editor Delete rows, Remove receipt photo, the job-photo trash, a booking Decline — on iOS 17 and 18 as well as 27 | Each label is rust, not system red; a disabled one reads as disabled; VoiceOver still announces it as destructive | REL, SE17, STD18, PM27 | [ ] |
| A11B-FR1-2 | H1 | Tap 12 pt above and below the Today card's "On my way" text | It sends "On my way"; the status row is no taller than a card without the link | REL, SE17, STD18 | [ ] |

## iPad layout, multitasking and keyboard (11.11)

| ID | Req | Steps | Expected result | Env / build | Evidence |
|---|---|---|---|---|---|
| IPAD-L-1 | H2 | iPad 11-inch (portrait and landscape) and iPad mini (portrait): Today, Jobs, Invoices, Customers, Money, Coach, Settings and one editor sheet | A centered ~700 pt column; scroll area, indicators and backgrounds full width; nothing clipped | REL, IPAD | [ ] |
| IPAD-L-2 | H2 | iPad 13-inch landscape, and a large sheet under Stage Manager | Sheet content capped at 700 pt; the calendar and route sheets read correctly | REL, IPAD (13-inch) | [ ] |
| IPAD-L-3 | H2 | iPhone Pro Max landscape: Jobs and Today | 700 pt column inside the safe areas; portrait unchanged | REL, PM27 | [ ] |
| IPAD-L-4 | H2 | iOS 17 floor (SE-class; an iPad on iPadOS 17): a list wider than 740 pt | Rows at the computed margin as measured on iOS 26; otherwise open an item | REL, SE17 and an iPadOS 17 iPad | [ ] |
| IPAD-MT-1 | H2 | Split View at 1/3, 1/2 and 2/3 beside another app, both orientations | No clipping; narrow widths full width; one tab bar and one navigation bar | REL, IPAD | [ ] |
| IPAD-MT-2 | H2 | Slide Over (320 pt): every tab plus the job, invoice and expense editors | Usable without horizontal clipping | REL, IPAD | [ ] |
| IPAD-MT-3 | H2 | Stage Manager: drag a window slowly across 690–760 pt on a list and a scroll screen; open a wide screen and a large sheet fresh | The column engages without a jump or layout loop; record any one-frame shift on first appearance (review M6) | REL, IPAD | [ ] |
| IPAD-ROT-1 | H2 | Rotate through all four orientations with a pushed detail, an open sheet and the keyboard up | State kept; no second navigation bar; the focused field stays visible; the Coach composer rises with the keyboard | REL, IPAD | [ ] |
| IPAD-KB-1 | H1, H2 | Hardware keyboard: Esc, ⌘S, ⌘⏎ (change-order Confirm), ⌘N on the five owners, including under sheets, dialogs, pushed screens and a UIKit child sheet; cancel a swipe-back on a pushed plan, then ⌘N (see plan §7, 11.11 for the full list) | Each fires once, only for the visible screen; ⌘N does nothing while its owner presents or is covered; on Maintenance plans ⌘N opens a new plan; Esc dismisses only the top sheet; no key triggers delete-account Delete | REL, IPAD | [ ] |
| IPAD-KB-2 | H1, H2 | Tab/Shift-Tab through the job, invoice, customer and expense editors; Return in a single-line field and in Coach | Focus follows visual order; Return ends editing (a newline in Coach) | REL, IPAD | [ ] |
| IPAD-AX-1 | H1, H2 | AX5 on iPad in 1/2 Split View: Money cards, Today stats, editors | The column and the AX stacks do not clip | REL, IPAD | [ ] |

## Performance, poor network and soak (11.12)

The full steps, data tiers and record fields are in
[native-phase-11-performance.md](native-phase-11-performance.md) §2–§4; the Phase 12 owner
of each row is named there. That document sets **no numeric threshold**; Phase 12.00
owns thresholds (absolute targets). "Expected result" below is the pass evidence the
row must record.

| ID | Req | Steps | Expected result | Env / build | Evidence |
|---|---|---|---|---|---|
| PERF-1 | H4 | Cold launch, one launch per App Launch trace, per data tier, five runs | Time to first frame plus `Launch`, `SnapshotLoad` (and first-run `LegacyMigration`) intervals recorded against the 12.00 targets | REL, SE17, PM27, STG | [ ] |
| PERF-2 | H4 | Warm launch (background, force-quit, relaunch within 10 s) | As PERF-1 | REL, SE17, PM27 | [ ] |
| PERF-3 | H4 | Decide whether to add a UI-test target for `XCTApplicationLaunchMetric` (none exists) | A recorded decision; results if added | 12.02 decision | [ ] |
| PERF-4 | H3, H4 | Xcode Organizer and TestFlight MetricKit aggregates (launch, hangs, memory, disk writes, battery, terminations) | Per-build percentiles, or "insufficient data" recorded | REL (TestFlight cohort) | [ ] |
| PERF-5 | H4 | Profile the first native launch of the 12.04 upgrade | `LegacyMigration`/`SnapshotLoad` durations and the migration outcome | REL, RN-UP, PM27 | [ ] |
| PERF-6 | H4 | Sign in on a fresh install for each data tier | `InitialSync` duration, outcome and count | REL, SE17, PM27, STG | [ ] |
| PERF-7 | H3 | Foreground and manual sync on typical and large tiers | `DeltaPull` durations and outcome mix; Cloud Sync diagnostic codes (the OI-3 signal) | REL, STD18, STG | [ ] |
| PERF-8 | H4 | Large tier: scroll Jobs and Invoices, search, switch every filter under Time Profiler and Hangs | `JobListProjection`/`InvoiceListProjection` durations; hitches or hangs recorded | REL, SE17, PM27 | [ ] |
| PERF-9 | R1, H4 | Read crash-free sessions from Sentry per build | Crash-free session rate recorded | REL+KEYS (cohort) | [ ] |
| PERF-10 | H4 | Optional: PERF-1 and PERF-2 on the installed App Store Expo build, same device | A reference launch time only, never a threshold | App Store Expo build, PM27 | [ ] |
| SOAK-1 | H3 | Typical tier, 5 queued edits, "Very Bad Network"; trigger the background task, then 2 h natural scheduling; repeat with "100% Loss" | Each task completes exactly once; server rows = local records; pending reaches 0 after recovery | REL, STD18, STG | [ ] |
| SOAK-2 | H3 | Large tier, 30 min of mixed use under Allocations and Leaks | No unbounded memory growth; no leaks in `N/` types; no jetsam | REL, SE17, STG | [ ] |
| SOAK-3 | H3 | Airplane mode, 10 edits incl. a re-edit and delete; force-quit; relaunch offline; reconnect; repeat with a 1 s mid-sync drop | Each change on the server once, in order; nothing lost or duplicated; Cloud Sync recovers | REL, STD18, STG | [ ] |
| SOAK-4 | H3 | Low Power Mode, typical tier, 60 min use plus 2 h idle | Foreground sync works; background deferral recorded; no busy loop while idle; battery % recorded | REL, STD18, STG | [ ] |
| SOAK-5 | H2, H3 | Stage Manager width drag across 690–760 pt for 60 s under Time Profiler | CPU returns to idle after the drag; no layout loop; one-frame shift recorded | REL, IPAD | [ ] |
| SOAK-6 | H3 | Typical tier, 60 min with 20 background/foreground cycles, a sign-out/sign-in and widget refreshes | Memory stays level; no crash; Organizer terminations recorded | REL, STD18, STG | [ ] |
| SYNC-1 | H3 | Fresh install. Sign in to an account that has a due recurring job rule and a recurring plan whose occurrence another device already generated. Background and foreground the app while the initial sync is loading | Exactly one occurrence per rule, locally and on the server; no duplicate after the sync completes (the host counterpart is the 11.12 fix round 3 case in `native/PoorNetworkTests/main.swift`, driven through the `AppStore.testRunRecurringGenerationAfterInitialSync` hook) | REL, STD18 plus a second device, STG | [ ] |

## Cross-client qualification (11.13)

| ID | Req | Steps | Expected result | Env / build | Evidence |
|---|---|---|---|---|---|
| Q11-P12-1 | W1, W4 | On an iPhone and an iPad: install REL, sign in, create a job and an invoice, clock in, then sign out; sign in as another owner | The Next Job and Job Timer widgets show the owner's data, then clear on sign-out; nothing from the previous owner appears after the new sign-in | REL, STD18, IPAD, STG | [ ] |
| Q11-P12-2 | W2, W3 | Add Next Job (small, medium) and Job Timer; use the interactive timer button; leave the device a day | The widgets render; the button starts and stops the timer through the queue; a snapshot older than 24 h shows the stale state | REL, STD18 | [ ] |
| Q11-P12-3 | A1, A2 | Speak each of the ten App Intent phrases (contract §5), including On My Way, from a cold and a warm app | Each intent's action replays once (trip `t_siri_`, expense `e_siri_`, timer); On My Way routes to the job composer | REL, STD18 | [ ] |
| Q11-P12-4 | P1, R1 | StoreKit sandbox or TestFlight purchase and restore, with staging PostHog and Sentry keys supplied | `subscription_purchased` and catalog events arrive with allow-listed properties only; Sentry receives a redacted event | REL+KEYS, STD18, STG | [ ] |
| Q11-P12-5 | H1 | Share an invoice PDF in each status and an estimate PDF; view on the device and in Mail; print one | Stamps and accent use the A30 colors and stay legible when printed | REL, STD18 | [ ] |
| Q11-P12-6 | R2 | On an RN-UP device, read the `LegacyBackups/` files' protection class and the backup-exclusion flag | Every file is `NSFileProtectionComplete`, and the tree is excluded from iCloud and Finder backup | REL, RN-UP | [ ] |
| Q11-P12-7 | H1 | Final review I1. On Maintenance plans, open a plan's actions and tap "Cancel plan", then confirm; repeat with "Delete plan"; separately dismiss each confirmation | Confirming cancels (or deletes) that plan, visibly and after a relaunch; dismissing changes nothing; Pause still works | REL, STD18, IPAD | [ ] |
| Q11-P12-8 | W2, A1 | Final review C1. With a second device (or the RN app) signed in to the same account: start the timer from the Job Timer widget, log a trip and an expense by Siri, then open the app online and wait for a sync; stop the timer from the widget and sync again | The timer session, trip and expense reach the server and the second device; a pull while they are pending does not drop them; the stop syncs too | REL, STD18 plus a second device, STG | [ ] |

## Exit checklist for Phase 12

- [ ] Every row above has device/staging evidence or an explicit, dated waiver recorded in
  the Phase 12 evidence index.
- [ ] G1 (native remote push) and G2 (native tax-settings editor) are built, or each has a
  dated waiver from Phase 12.00, before cutover.
- [ ] G6, OI-1, OI-2 and OI-3 are decided by their owners and the decision is linked here.
- [x] OI-4 items are fixed or re-owned by the Phase 11 final review (four fixed; item 2 re-owned as I2).
- [ ] I2 (the sync-push 4xx wedge) is fixed by Phase 12.00 before cutover. Fixed on
  native/phase-12 by 12.00b.1 (host evidence); tick this only after the device rows
  P12-B1-1 and P12-B1-2 (Phase 12 evidence index §23) pass.
- [ ] A failing row is recorded as a defect with the build number, never silently waived.
- [ ] The Phase 11 parity rows move from `In progress` to `Verified` only after their rows
  here pass.
