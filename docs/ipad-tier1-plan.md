# iPad Tier 1 — Native iPad Support Plan

**Goal:** TradeReady ships as a real iPad app that looks intentional, not like a
stretched phone. No master-detail, no two-column redesign — that is Tier 2/3 and
explicitly out of scope here.

**Created:** 2026-07-24
**Baseline verified same day:** HEAD `da41bb0` on `master`, tree clean,
`npm run typecheck` 0 errors, `npm test` 558 tests / 56 suites, `npm run lint`
0 warnings.

**Estimated effort:** 7 phases, ~1.5–2 working days plus one EAS build cycle.

---

## Scope boundaries

**In scope**
- `supportsTablet: true` and rotation unlocked on iOS
- A shared max-width content column so text/rows stop spanning ~1180pt
- Landscape-specific fixes to the handful of components that assume tall-and-narrow
- One EAS build + iPad smoke pass

**Out of scope (do not drift into these)**
- Master-detail / split views for Jobs, Invoices, Customers → Tier 3
- Two-column grids (MoneyScreen's 8 analytics cards, PricingCalculator) → Tier 2
- A breakpoint hook / responsive size system → Tier 2 (Tier 1 needs none, see Phase 1)
- Android tablet → deferred by owner decision 2026-07-14 (iOS-first)
- Unifying the two status-color systems → forbidden without separate approval

**Zero dependency changes.** No `package.json` edit, no `npx expo install`, no SDK
move. If any phase appears to need one, stop and report instead (Rule 3).

**Zero persisted data-shape changes.** No model fields, no AsyncStorage keys, no
sync logic. `utils/sync.ts` is not touched.

---

## Gating precondition — ALL PHASES HELD

**Owner decision 2026-07-24: hold the entire plan until build 6 clears App Review.**
Not just Phase 7 — nothing starts, including the phone-neutral Phase 1 token and the
Phase 2 audit. Rationale: avoid a divergent branch and split attention during an
active rejection cycle. Revisit once build 6 is approved.

Background on why Phase 7 in particular could not have shipped early anyway: flipping
`supportsTablet: true` opens a brand-new native-iPad review surface — every screen
becomes fair game on hardware nobody has smoke-tested. This becomes **build 7**.

Phase 7 additionally needs a fresh confirmation at the time it runs, since the
`app.json` edit changes native build behavior and cannot ship OTA (same lesson as the
2026-07-24 splash swap).

### Decisions already settled (2026-07-24)

| Decision | Answer |
|---|---|
| `layout.contentMaxWidth` | **700pt** — single value for all screens; per-context widths stay Tier 2 |
| Centering as an approved visual change | **Approved** (change-control gates visual changes even when phone-neutral) |
| Physical iPad for Phase 7 smoke | **Available** |
| Start timing | **Held until build 6 approval** |

---

## Why this is cheap: what the audit found

Verified 2026-07-24 by grep across `screens/`, `components/`, `utils/`:

| Check | Result |
|---|---|
| `Dimensions.get()` | **0 occurrences** |
| `useWindowDimensions()` | **0 occurrences** |
| `numColumns` grids to reflow | **0** |
| Fixed pixel widths | 49 — all small chrome (icon circles 20–40, avatars 80, dots 4–10, FAB 56, hairline dividers, label columns 76–88); all correct at any screen size |
| `maxWidth` in use today | 2 (`AddTripScreen.tsx:211` = 180, `ChatScreen.tsx:299` bubble = 82%) |
| Layout method | Flex + percentages throughout |
| Root wrapper consistency | 25 of 26 screens root at `<SafeAreaView style={styles.container} edges={["bottom"]}>`; 26 define `createStyles(colors, shadow)` |
| `contentContainerStyle` call sites | 30 |
| Render-based tests | 4 (`Field`, `UI`, `SyncBanner`, `useRefresh`); **0 snapshots** |

Two consequences that shape the plan:

- Nothing is *broken* at tablet width — there is no width math to unwind. The defect
  is purely that single-column layouts **stretch**.
- Test risk is near zero. The suite is almost entirely pure-logic utils with no
  snapshots, so layout edits will not fight the gate.

---

## Phase 1 — Responsive foundation (no screen touched)

**Why first:** establishes one shared token so the following phases are mechanical
edits rather than 26 independent judgement calls.

**Design decision — no breakpoint hook needed.** A style of
`{ width: "100%", maxWidth: N, alignSelf: "center" }` is automatically a **no-op on
phone**, because phone width is already below `N`. So Tier 1 needs no device
detection, no `useWindowDimensions`, and no re-render on rotation. This is the single
biggest cost saver in the plan and the reason Tier 1 is days not weeks.

**Design decision — apply to content containers, not a wrapper component.** A new
`<ContentWidth>` View inserted between `SafeAreaView` and its child would sit in the
middle of existing flex chains and risk collapsing ScrollView heights across 25
screens. Instead the token is applied to the *existing* 30 `contentContainerStyle`
call sites and to fixed header/filter rows. The flex chain is never altered.

**Files**
- `utils/theme.ts` — add a `layout` export alongside the existing static
  `spacing`/`radius`/`fontSize` tokens (they don't vary by theme, so this belongs
  with them, not in `ColorScheme`):
  - `layout.contentMaxWidth` — **700** (owner-confirmed 2026-07-24)
  - `layout.contentColumn` — `{ width: "100%", maxWidth: 700, alignSelf: "center" }`
- `__tests__/layout.test.js` — new: assert the token shape, and assert the no-op
  property (that `maxWidth` exceeds the widest phone logical width, 440pt for the
  Pro Max class, so no phone layout can be affected).

**Verification:** gate green (expect 559+ tests, still 0/0). Phone rendering provably
unchanged — no screen file modified in this phase.

**STOP** → report Confidence / Missing Context / Next Step.

---

## Phase 2 — iPad audit (evidence only, no code)

**Why:** the remaining phases should fix *observed* defects, not defects I predicted
from grep. This phase converts guesses into a prioritized list.

**Method — no EAS build required.** Expo Go is itself a universal iOS app, so
launching the project in **Expo Go on an iPad simulator** renders the app at full
iPad size without any `app.json` change or native rebuild. That is why the `app.json`
flip is deferred all the way to Phase 7: the entire layout audit and all layout fixes
happen before a single EAS build is spent.

Known Expo Go caveats — accept them, they don't affect layout:
- RevenueCat's native module is absent, so the dev bypass treats you as subscribed.
  PaywallScreen must therefore be inspected by navigating to it directly (the soft
  gate from Settings), not via the hard gate.
- Photo attach is unavailable/broken in this path (pre-existing, FA-035).

**Deliverable:** a screenshot per screen in both orientations (26 screens × 2), and a
written defect list bucketed as:
- **A** — fixed by the Phase 1 content column alone
- **B** — needs a landscape-specific fix (Phase 6)
- **C** — genuinely needs Tier 2 work; **log and defer, do not fix**

**Verification:** none — no code changed. Gate untouched.

**Hardware:** owner confirmed 2026-07-24 that a physical iPad is available. Phases 2–6
still use the simulator (faster iteration, no build needed); Phase 7 smoke-tests on the
real device.

**STOP** → present the defect list and get the A/B/C triage confirmed before writing
any screen code.

---

## Phase 3 — Pre-gate screens (highest review visibility)

**Why these three first:** `AuthScreen`, `OnboardingScreen`, `PaywallScreen` are the
only screens an App Review tester is *guaranteed* to see, and the paywall is already
the subject of the round-2 rejection. If the budget ran out after one phase, this is
the phase to have done.

**Files:** `screens/AuthScreen.tsx`, `screens/OnboardingScreen.tsx`,
`screens/PaywallScreen.tsx`

Notes specific to these:
- `AuthScreen` uses `useSafeAreaInsets()` directly rather than `SafeAreaView` — the
  one structural exception among the 26. Handle it on its own terms.
- `OnboardingScreen` has five `width: "100%"` cards plus an 80pt logo well; the
  cards are what stretch.
- All three already use `KeyboardAvoidingView`.

**Verification:** gate green; re-screenshot these three in both orientations against
the Phase 2 baseline.

**STOP** → report.

---

## Phase 4 — Main read & list screens

**Files:** `screens/TodayScreen.tsx`, `JobsScreen.tsx`, `JobDetailScreen.tsx`,
`InvoicesScreen.tsx`, `CustomersScreen.tsx`, `CustomerDetailScreen.tsx`,
`MoneyScreen.tsx`, `MileageLogScreen.tsx`, `PricebookScreen.tsx`,
`RecurringJobsScreen.tsx`, `RouteScreen.tsx`

Apply `layout.contentColumn` to scroll content containers and to fixed
header/filter/stat rows. Specific items to watch:
- `TodayScreen`'s stat row and weekly calendar strip
- The absolutely-positioned FABs (`JobsScreen.tsx:298`, `InvoicesScreen.tsx:577`) —
  these are pinned to the screen edge, not the content column, and should **stay**
  screen-anchored. Do not move them into the column.
- `MoneyScreen`'s 8 analytics cards get the column treatment only. The 2-col grid is
  Tier 2 — resist it here.

**Verification:** gate green; re-screenshot all 11 in both orientations.

**STOP** → report.

---

## Phase 5 — Forms, modals, and remaining screens

**Files:** `AddJobScreen.tsx`, `AddInvoiceScreen.tsx`, `AddCustomerScreen.tsx`,
`AddTripScreen.tsx`, `CreateInvoiceFromJobScreen.tsx`, `PricingCalculatorScreen.tsx`,
`PricebookEntryScreen.tsx`, `SendEstimateScreen.tsx`, `OutreachScreen.tsx`,
`ReviewRequestScreen.tsx`, `SettingsScreen.tsx`, `ChatScreen.tsx`, plus
`components/money/AddExpenseModal.tsx` and `components/PricebookPickerModal.tsx`

Notes:
- Six screens use `presentation: "modal"` (`AddJob`, `AddCustomer` ×2, `AddInvoice`
  ×2, `AddTrip`). On iPad these render as centered form sheets rather than full-screen
  — verify each still reads correctly; several may need *no* column at all because the
  sheet already constrains width.
- `ChatScreen`'s 82% bubble maxWidth becomes very wide at tablet size; the column
  fixes it, but confirm visually.
- `SettingsScreen` is the longest screen and mounts directly on the Tab with no stack.

**Verification:** gate green; re-screenshot all in both orientations.

**STOP** → report.

---

## Phase 6 — Landscape-specific fixes

These are the components that assume tall-and-narrow and are **not** fixed by a
max-width column. Driven by Phase 2's bucket B.

Known candidates, verified 2026-07-24:
- `JobDetailScreen.tsx:873` — `viewerImage: { width: "100%", height: "80%" }`. In
  landscape, 80% of a short viewport with 100% width distorts or overflows. Needs
  `resizeMode`-aware sizing.
- `components/DateTimePickerSheet.tsx` — the iOS bottom-sheet branch (inline calendar
  for `date`, spinner for `time`). A bottom sheet in iPad landscape has very little
  vertical room. This is a shared primitive used by 4+ call sites, so a change here is
  broad — treat carefully and keep the documented commit-on-Done behavior (owner
  requirement, 2026-07-16) intact.
- `KeyboardAvoidingView` behavior across the 10 screens that use it
  (`AddCustomer`, `AddInvoice`, `AddJob`, `Auth`, `Chat`, `CreateInvoiceFromJob`,
  `Onboarding`, `PricebookEntry`, `PricingCalculator`, `Settings`) — the iPad
  keyboard is proportionally shorter, and the floating/split keyboard changes the
  offset math.
- `components/KeyboardDoneBar.tsx` — used by 8 modules; verify it pins correctly at
  tablet width.

**Verification:** gate green; targeted re-test of each fixed component in landscape.

**STOP** → report.

---

## Phase 7 — Flip the switches, build, smoke, submit

**Requires explicit owner approval to start** (native-build-affecting `app.json`
change).

**Files:** `app.json` only
```
"orientation": "portrait"        →  "default"
"ios": { "supportsTablet": false →  true, "buildNumber": bump }
```

On rotation: leaving `orientation: "portrait"` while declaring `supportsTablet: true`
is possible, but reviewers commonly flag iPad apps that don't rotate, and Apple's HIG
expects it. The two flips travel together — which is precisely why Phase 6 exists.

**This cannot ship OTA.** `runtimeVersion` uses the `appVersion` policy and this is a
native config change, so it needs a full EAS build. Same constraint as today's splash
swap.

**Smoke pass on the physical iPad** (owner-confirmed available), not the simulator:
- All 26 screens, both orientations
- The three items from the current rejection specifically: paywall loads offerings,
  Manage Subscription works, expired-sub demo account behaves
- Rotation mid-flow on at least one form screen and one modal
- Verify the RevenueCat paths that Expo Go could not exercise in Phases 2–6

**Verification:** gate green before the build; documented smoke results after.

**STOP** → report, then owner decides on submission as build 7.

---

## Per-phase exit criteria (every phase)

- [ ] Change is inside that phase's stated scope
- [ ] No `package.json` / SDK / dependency change
- [ ] No persisted data-shape change; `utils/sync.ts` untouched
- [ ] No new `eslint-disable` / `@ts-ignore` / `@ts-expect-error`
- [ ] `npm run typecheck` → 0 errors
- [ ] `npm test` → all pass (baseline 558 / 56, rising with Phase 1's additions)
- [ ] `npm run lint` → 0 warnings
- [ ] Commit message: imperative, `feat:` / `fix:` / `chore:` prefix as fits
- [ ] Phase report: Confidence Level / Missing Context / Recommended Next Step
- [ ] **STOP** and wait for go-ahead

## Suggested branch

`feat/ipad-tier1`, off `master` at `da41bb0` or later (after build 6 clears).

---

## Skill-library drift noted while planning

`tradeready-change-control` still states the 2026-07-07 red-gate baseline
(~35 tsc errors, 23 lint warnings, 254 tests / 20 suites). Verified 2026-07-24:
the gate is **fully green at 558 tests / 56 suites, 0 tsc errors, 0 lint warnings**.
Baselines are owned by `tradeready-validation-and-diagnostics`; both files want
updating independently of this plan.
