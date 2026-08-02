# iPad Tier 1 — Static Code Audit (Phase 2)

**Date:** 2026-08-02
**Method — DEVIATION FROM PLAN:** the plan called for Expo Go on an iPad
simulator with screenshots in both orientations. This box has no macOS / iOS
simulator (device smoke is owner-only, per `project_web_preview_not_usable`
memory). This audit is therefore a **static code read**: every file in
`screens/` (31 files) and the shared layout-relevant components were read in
full, and every claim below is a grep/line citation against the worktree at
branch `feat/ipad-tier1`, not a rendered screenshot. **Visual confirmation of
every bucket-A/B call is deferred to Phase 7's physical-iPad smoke.** Treat
the bucket assignments here as strong code-level predictions, not verified
fact.

No app code was changed to produce this document.

---

## 1. Screen count reality check

`screens/` currently holds **31 files**, not the plan's 26. Diffing the
plan's Phase 3/4/5 file lists (3 + 11 + 12 = 26) against the current
directory, five screens are net-new since 2026-07-24:

- `EstimateFollowUpScreen.tsx`
- `AddRecurringInvoiceScreen.tsx`
- `ExportDataScreen.tsx`
- `GlobalSearchScreen.tsx`
- `RecurringInvoicesScreen.tsx`

Correction to the brief's hint: `ReviewRequestScreen.tsx` was **already** in
the plan's Phase 5 list (the plan was written 2026-07-24, after that screen
existed) — it is not new. `EstimateFollowUpScreen.tsx` is the only one of the
brief's two named examples that's actually new; the rest of the five above
were found by the diff, not named in the brief.

All 31 screens are enumerated in the inventory below.

---

## 2. Screen inventory

Legend — **Bucket A**: fixed by `layout.contentColumn` alone (apply to the
named `contentContainerStyle` key(s) and any fixed rows outside the
scroll/list). **Bucket B**: also needs a landscape-specific fix (Phase 6) —
noted inline, detailed in §4. **Bucket C**: Tier 2, log only — detailed in
§5. Root wrapper conventions: unless noted, root is
`<SafeAreaView style={styles.container} edges={["bottom"]}>` per the stated
convention.

| # | Screen | Root wrapper | Scroll/list container (`contentContainerStyle` key) | Fixed rows outside scroll | Absolute-positioned | Nav modal? | Bucket |
|---|---|---|---|---|---|---|---|
| 1 | AddCustomerScreen | SafeAreaView(bottom) → KeyboardAvoidingView | ScrollView `styles.scroll` | — | — | **Yes** (JobStack + CustomerStack) | A |
| 2 | AddInvoiceScreen | SafeAreaView(bottom) → KAV | ScrollView `styles.scroll` | — | — | **Yes** (InvoiceStack + CustomerStack) | A |
| 3 | AddJobScreen | SafeAreaView(bottom) → KAV | ScrollView (ref) `styles.scroll` | — | — | **Yes** (JobStack) | A + B (DateTimePickerSheet ×4: date, start, end, recur-end) |
| 4 | AddRecurringInvoiceScreen | SafeAreaView(bottom) → KAV | ScrollView `styles.scroll` | — | — | **Yes** (InvoiceStack) | A + B (DateTimePickerSheet ×2) |
| 5 | AddTripScreen | SafeAreaView(bottom) | ScrollView `styles.content` | — | — | **Yes** (MoneyStack) | A (existing `maxWidth:180` chip at line 212 — small chrome, no change needed) |
| 6 | AuthScreen | **NOT SafeAreaView** — `KeyboardAvoidingView` + `useSafeAreaInsets()` padding (structural exception #1) | ScrollView `styles.scroll` (`flexGrow:1, justifyContent:'center'`) | — | password-eye toggle (small, in-input, screen-anchored — fine) | No | A — login `card` style has no `maxWidth`; will span edge-to-edge at tablet width |
| 7 | ChatScreen | SafeAreaView(bottom) → KAV | FlatList (inverted) `styles.listContent`; empty state uses `quickGrid` (`width:'100%'`) | `inputRow` composer footer, outside the FlatList | — | No | A + B `[tablet-width]` (bubble `maxWidth:"82%"` at line 329 becomes wide at tablet width regardless of rotation — plan already flagged this, confirmed still true; see §4.5 — Bucket A's column on `listContent` mitigates to ≈574pt effective) |
| 8 | CreateInvoiceFromJobScreen | SafeAreaView(bottom) → KAV | ScrollView `styles.scroll` | — | — | No | A |
| 9 | CustomerDetailScreen | SafeAreaView(bottom) | ScrollView — **NO `contentContainerStyle` prop at all** (line 363: `<ScrollView showsVerticalScrollIndicator={false}>`) | — | — | No | A — **deviation from the mechanical pattern**: there is no existing `contentContainerStyle` to touch; Phase 4 must either add one or wrap the hero/stats/section children in a column View. Also owns an in-screen merge-picker `Modal` (`mergeSheet`, no `maxWidth`) |
| 10 | CustomersScreen | SafeAreaView(bottom) | FlatList `styles.listContent` | `header` (title+count), `searchRow`, conditional `dupBanner`, conditional `archiveToggle` — all outside the FlatList | `Fab` at line 283 (stays anchored) | No | A |
| 11 | EstimateFollowUpScreen | SafeAreaView(bottom) | ScrollView `styles.scroll` | — | — | No | A |
| 12 | ExportDataScreen | SafeAreaView(bottom) | ScrollView `styles.scroll` | — | — | **Yes** (MoneyStack, has native title "Export Data") | A + B (DateTimePickerSheet ×1, custom range) |
| 13 | GlobalSearchScreen | SafeAreaView(bottom) | ScrollView `styles.scroll` | `searchRow` (SearchField), outside the ScrollView | — | No | A |
| 14 | InvoicesScreen | SafeAreaView(bottom) | FlatList `styles.listContent` | `statsRow`, `searchRow`, `filterRow` outside the list; conditional `bulkBar` footer | `Fab` at line 610 (stays anchored) | No | A — plus two in-screen bottom-sheet `Modal`s with no `maxWidth`: the invoice-detail sheet (`modalSheet`, `maxHeight:'80%'`) and `RecordPaymentSheet` |
| 15 | JobDetailScreen | SafeAreaView(bottom) | ScrollView `styles.scroll` | — | photo-delete btn, viewer-close btn (small, screen-anchored — fine) | No | A + **B** — `viewerImage: { width: "100%", height: "80%" }` at **line 1136** (usage at line 428); plan cited line 873, now stale |
| 16 | JobsScreen | SafeAreaView(bottom) | FlatList `styles.listContent` | `statsRow`, `searchRow`, `filterRow` outside the list | `Fab` at line 228 (stays anchored) | No | A |
| 17 | MileageLogScreen | SafeAreaView(bottom) | FlatList `styles.list` | horizontal `filterScroll` (self-contained), `summaryCard` — both outside the FlatList | `addBtn` pill, `position:absolute, alignSelf:'center'` (stays anchored) | No | A |
| 18 | MoneyScreen | SafeAreaView(bottom) | Overview tab: ScrollView (`styles.scrollContent`) — **NO `contentContainerStyle` prop** (lines 247-251); Expenses tab: FlatList `styles.expenseList` | `filterBar` (fixed-height wrapper, Fabric-bug workaround, see comment at line ~387) + `tabBar` — both outside either scrollable | — | No | A (add a `contentContainerStyle` to the overview ScrollView — same gap class as CustomerDetailScreen) + **C** (≈16 analytics cards across 4 `MoneySection` groups, not "8" as the plan stated — 2-col grid is Tier 2, see §5) |
| 19 | OnboardingScreen | SafeAreaView(**top+bottom**, not bottom-only) | ScrollView `styles.scroll` inside KAV | `dots` step indicator above the KAV; `footer` (Back/Next) below it | — | No (rendered inline via RootStack render-prop) | A — 5 `width:"100%"` cards as plan noted |
| 20 | OutreachScreen | SafeAreaView(bottom) | ScrollView `styles.scroll` | — | — | No | A |
| 21 | PaywallScreen | SafeAreaView(**top+bottom**) + `useSafeAreaInsets()` for the close-btn offset | ScrollView `styles.scroll` | — | `closeBtn` (top-right, screen-anchored — fine) | **Yes, as `PaywallModal`** (RootStack) — but the SAME component is also reached as the non-modal hard gate (`Paywall` route, no `presentation` option) | A — but reconsider on the `PaywallModal` path once reached: iPad form sheets already constrain width, so the column may be redundant there (test both nav paths in Phase 7) |
| 22 | PricebookEntryScreen | SafeAreaView(bottom) → KAV | ScrollView `styles.scroll` | — | — | No | A |
| 23 | PricebookScreen | SafeAreaView(bottom) | SectionList `styles.listContent` | `searchRow`, outside the list | **`fab` footer button bar** — `position:absolute, bottom, left:spacing.lg, right:spacing.lg` (lines ~207-212, usage line 139) — this is a **full-width button**, not a round FAB | No | A, but **non-mechanical**: `left`/`right` absolute offsets don't compose with `alignSelf:'center'+maxWidth` the way a `contentContainerStyle` swap does — Phase 4/5 needs a different centering technique here (e.g. constrain via a wrapping row, or switch to `alignSelf:'center', width:'100%', maxWidth:700` on the button itself instead of `left`/`right`) |
| 24 | PricingCalculatorScreen | SafeAreaView(bottom) | `tabs` fixed row above KAV; both tab bodies (`CalculatorTab`/`EstimateTab`) are ScrollViews sharing `styles.scroll` (the "2" contentContainerStyle occurrences) | `tabs` row, outside either ScrollView | — | No | A — plus in-screen `PricebookPickerModal` (sheet, no `maxWidth`). **C**: `SmallInput` rows could go 2-col at tablet width — explicitly out of scope per plan ("resist it here") |
| 25 | RecurringInvoicesScreen | SafeAreaView(bottom) | FlatList `styles.list` | — | `Fab` at line 169 (stays anchored) | No | A |
| 26 | RecurringJobsScreen | SafeAreaView(bottom) | FlatList `styles.list` | — | — (no Fab — series are created from AddJobScreen's "Repeat" toggle, not here) | No | A |
| 27 | ReviewRequestScreen | SafeAreaView(bottom) | ScrollView `styles.scroll` | — | — | No | A |
| 28 | RouteScreen | SafeAreaView(bottom) | ScrollView `styles.scroll` | — | — | No | A |
| 29 | SendEstimateScreen | SafeAreaView(bottom) | ScrollView `styles.scroll` | — | — | No | A |
| 30 | SettingsScreen | SafeAreaView(bottom) → KAV | ScrollView `styles.scroll` | — | — | No | A — plus an in-screen delete-account `Modal` (`modalCard`, no `maxWidth`, centered by `modalBackdrop`'s `justifyContent:'center'`). Longest screen (1231 lines), confirmed |
| 31 | TodayScreen | **NOT SafeAreaView** — root IS the `ScrollView` itself, styled with `useSafeAreaInsets().top` as inline padding (structural exception #2 — **the brief only names AuthScreen; there are two**) | The ScrollView itself, `styles.scrollContent` | none — unlike Jobs/Invoices/Customers, TodayScreen has NO header/stats/list split: header, week strip, stats row, and schedule all scroll together as one column | — | No | A — simpler than Jobs/Invoices/Customers in one respect: one column wrap covers header + stats + schedule together, no second wrapper needed for a separate fixed row |

### Structural-exception correction

The plan states "25 of 26 screens root at `<SafeAreaView>`... AuthScreen is
the one exception." Current reality, re-verified by grep
(`useSafeAreaInsets` in `screens/`): **three** files call
`useSafeAreaInsets()` — `AuthScreen.tsx`, `TodayScreen.tsx`, and
`PaywallScreen.tsx`. Of those, only **AuthScreen and TodayScreen** skip
`SafeAreaView` entirely (root is `KeyboardAvoidingView`/`ScrollView` with
manual inset padding). **PaywallScreen roots at `SafeAreaView` like every
other screen** and additionally calls `useSafeAreaInsets()` just to offset
its absolutely-positioned close button — that's a normal secondary use, not
a structural exception. `SafeAreaView` itself is used as the root in **29 of
31** screens (grep: `files_with_matches` = 29); the two missing are AuthScreen
and TodayScreen. **Net: two structural exceptions, not one.**

---

## 3. Phase ownership (updated for the 31-screen inventory)

**Phase 3 — Auth/Onboarding/Paywall (3 screens, unchanged):**
`AuthScreen.tsx`, `OnboardingScreen.tsx`, `PaywallScreen.tsx`

**Phase 4 — Main read/list screens (13 screens — 11 original + 2 new):**
`TodayScreen.tsx`, `JobsScreen.tsx`, `JobDetailScreen.tsx`,
`InvoicesScreen.tsx`, `CustomersScreen.tsx`, `CustomerDetailScreen.tsx`,
`MoneyScreen.tsx`, `MileageLogScreen.tsx`, `PricebookScreen.tsx`,
`RecurringJobsScreen.tsx`, `RouteScreen.tsx`, **`GlobalSearchScreen.tsx`**
(read/search results screen off Today), **`RecurringInvoicesScreen.tsx`**
(list screen, direct mirror of `RecurringJobsScreen.tsx`)

**Phase 5 — Forms, modals, and remaining (15 screens + 2 shared
components — 12 + 2 original, 3 screens new):** `AddJobScreen.tsx`,
`AddInvoiceScreen.tsx`, `AddCustomerScreen.tsx`, `AddTripScreen.tsx`,
`CreateInvoiceFromJobScreen.tsx`, `PricingCalculatorScreen.tsx`,
`PricebookEntryScreen.tsx`, `SendEstimateScreen.tsx`, `OutreachScreen.tsx`,
`ReviewRequestScreen.tsx`, `SettingsScreen.tsx`, `ChatScreen.tsx`,
**`EstimateFollowUpScreen.tsx`**, **`AddRecurringInvoiceScreen.tsx`**,
**`ExportDataScreen.tsx`**, plus `components/money/AddExpenseModal.tsx` and
`components/PricebookPickerModal.tsx`

3 + 13 + 15 = 31. ✓

### Navigation registration / modal presentation (App.tsx)

Re-verified against `App.tsx` (not just the plan's Phase-5 prose). Current
`presentation: "modal"` registrations — **9 registrations, 7 distinct
screens** (plan counted 6 registrations / 4 distinct screens):

| Line | Stack | Route | Screen |
|---|---|---|---|
| 146 | JobStack | AddJob | AddJobScreen |
| 150 | JobStack | AddCustomer | AddCustomerScreen |
| 199 | InvoiceStack | AddInvoice | AddInvoiceScreen |
| 209 | InvoiceStack | AddRecurringInvoice | AddRecurringInvoiceScreen (**new**) |
| 227 | CustomerStack | AddCustomer | AddCustomerScreen |
| 228 | CustomerStack | AddInvoice | AddInvoiceScreen |
| 263 | MoneyStack | AddTrip | AddTripScreen |
| 269 | MoneyStack | ExportData | ExportDataScreen (**new**) |
| 480 | RootStack | PaywallModal | PaywallScreen (not previously called out in the plan's modal list, though it likely predates 2026-07-24) |

On iPad these render as centered form sheets already width-constrained by
the OS — Phase 5 should verify per-screen whether the column token is
redundant once reached via the modal path (same caveat noted for
PaywallScreen above applies to all seven).

---

## 4. Bucket B — Phase 6 candidates (landscape-specific OR general tablet-width) — verified in code

Each item below is tagged **[landscape]** (the defect only manifests, or is
materially worse, in a short/landscape viewport) or **[tablet-width]** (the
defect is present at iPad width regardless of rotation — a portrait iPad is
already ~768-834pt wide, well past phone width, so there's nothing
orientation-specific about it). The plan scoped Phase 6 as "landscape-specific
fixes"; a **[tablet-width]** item below may already be substantially
addressed by Phase 4/5's content-column work, so treat those as **verify,
don't build an orientation-conditional fix** unless testing on the physical
iPad in Phase 7 shows otherwise.

### 4.1 JobDetailScreen photo viewer `[landscape]`
`screens/JobDetailScreen.tsx:1136` —
```
viewerImage: { width: "100%", height: "80%" },
```
Used at line 428 inside a full-screen `Modal` (`viewerBg`,
`backgroundColor: "rgba(0,0,0,0.95)"`). The plan cited line 873 — **stale,
re-verified at 1136** (file grew via the intervening feature batch). In
landscape on iPad, 80% of a short viewport combined with 100% width will
distort/overflow the photo since `contentFit="contain"` inside a
fixed-aspect box still obeys the box's own width/height ratio. Needs
`resizeMode`-aware sizing (e.g. cap both dimensions via `maxWidth`/`maxHeight`
percentages rather than a fixed width/height pairing). Confirmed unchanged
from the plan's underlying claim, only the line number moved.

### 4.2 components/DateTimePickerSheet.tsx — iOS bottom-sheet branch `[landscape]`
`components/DateTimePickerSheet.tsx:88-123`. The iOS branch renders a
`Modal` with `overlay` (`justifyContent:"flex-end"`, full-bleed) containing
`sheet` (`borderTopLeftRadius/borderTopRightRadius`, **no `maxHeight` and no
`maxWidth`** — style block at lines 141-154). Two render modes:
- `mode:"date"` → inline calendar (`display:"inline"`), which iOS sizes to
  roughly 320-350pt tall regardless of viewport — in a short iPad landscape
  window this can approach or exceed available height.
- `mode:"time"` → spinner (`display:"spinner"`), fixed ~216pt — safer, but
  still bottom-anchored full width.

**Call sites (re-verified, 5 files — not "4+" generically, but one file
alone contains 4 instances):**
- `screens/AddJobScreen.tsx` — 4 sheets (date, start time, end time,
  recurrence end date)
- `screens/AddRecurringInvoiceScreen.tsx` — 2 sheets (start date, end date)
- `screens/ExportDataScreen.tsx` — 1 sheet (custom range, shared for
  start/end via `pickerFor`)
- `components/money/AddExpenseModal.tsx` — 1 sheet (expense date)
- `components/RecordPaymentSheet.tsx` — 1 sheet (payment date)

The documented commit-on-Done behavior (owner requirement, 2026-07-16 — see
component header comment) **must not change**. Any Phase 6 fix should touch
only sizing/positioning (e.g. cap `sheet` height in landscape, or add a
`maxWidth` so it doesn't span edge-to-edge on iPad), not the onChange/onClose
commit contract.

### 4.3 KeyboardAvoidingView usage — re-verified, 11 screens (not 10) `[landscape]`
Grep for `KeyboardAvoidingView` in `screens/`:
`AddCustomerScreen`, `AddInvoiceScreen`, `AddJobScreen`,
**`AddRecurringInvoiceScreen`** (new since the plan's count of 10),
`AuthScreen`, `ChatScreen`, `CreateInvoiceFromJobScreen`, `OnboardingScreen`,
`PricebookEntryScreen`, `PricingCalculatorScreen`, `SettingsScreen`.

All use `behavior={Platform.OS === "ios" ? "padding" : undefined}` except
`ChatScreen` (`"padding" : "height"`, plus `keyboardVerticalOffset={headerHeight}`
via `useHeaderHeight()`) and `OnboardingScreen`/`AuthScreen`
(`"padding" : "height"`, no offset). iPad's floating/split keyboard and
shorter proportional height change the offset math referenced by the plan —
none of the `behavior`/offset props are conditioned on screen size today, so
this is confirmed still open for Phase 6.

### 4.4 components/KeyboardDoneBar.tsx — reach re-verified `[tablet-width]`
Grep for `<KeyboardDoneBar` (excluding the component's own usage-example
comment) — **direct screen usage in 7 screens**: `SettingsScreen`,
`PricingCalculatorScreen`, `PricebookEntryScreen`, `OnboardingScreen`,
`CustomerDetailScreen`, `ChatScreen`, `AddTripScreen` — **plus 3 shared
components** that mount their own bar: `components/money/TaxSettingsModal.tsx`,
`components/money/AddExpenseModal.tsx`, and `components/Field.tsx` itself
(every `Field` instance auto-mounts a per-field bar when
`needsDoneBar(keyboardType, multiline)` is true — see
`components/KeyboardDoneBar.tsx:37-45`). Because `Field.tsx` does this
automatically, the component's *effective* reach is much wider than 7 or 8
files — every screen using `Field` with a `decimal-pad`/`number-pad`/
`phone-pad`/`numeric` keyboard or `multiline` gets one implicitly. The bar
itself (`bar` style, `flexDirection:"row", justifyContent:"flex-end"`) has
no `maxWidth`, so at tablet width its "Done" button sits far from the input
column it serves once that column is centered — worth a look in Phase 6,
though it's a cosmetic misalignment, not a functional break. **Unlike 4.1-4.3
above, this is not orientation-driven** — the bar is exactly as
disconnected from the centered column in iPad portrait as it is in
landscape, since the mismatch is between the bar's own uncapped width and
the column's `maxWidth:700`, not anything to do with viewport height or
rotation.

### 4.5 ChatScreen bubble `maxWidth` `[tablet-width]`
`screens/ChatScreen.tsx:329` — `bubble: { maxWidth: "82%", ... }`. Also
general tablet-width, not orientation-driven — a portrait iPad is already
~768-834pt wide, so 82% is a wide bubble regardless of rotation; nothing
about this gets worse in landscape specifically. Bucket A substantially
mitigates it without any bubble-specific work: once Phase 5 applies
`layout.contentColumn` to `listContent` (§2, row 7), the FlatList itself is
capped at 700pt, so 82% of *that* is **≈574pt** — comparable to the
narrower-column behavior the 82% figure was presumably tuned against
originally. Phase 6 should treat this as **verify-only**: confirm bubble
width reads correctly once the Phase 5 column lands, rather than building a
dedicated fix.

### 4.6 Other notes (not Bucket B — cross-referenced here)
- **`screens/PricebookScreen.tsx`** `fab` style (§2, row 23): a full-width
  absolute button bar using `left`/`right` offsets rather than
  `alignSelf:'center'+maxWidth`. This is a **Bucket A** item, not Bucket B —
  no orientation or [landscape]/[tablet-width] tag applies — but it's noted
  here because it doesn't fit the mechanical "swap the `contentContainerStyle`
  value" pattern the other 30 screens do — Phase 4/5 needs a bespoke
  centering approach for this one style.
- No other percentage-HEIGHT patterns, bottom sheets, or portrait-only
  absolute positioning were found beyond the ones already listed above and
  in §4.1-4.2. `MileageLogScreen`'s `addBtn`, `Fab.tsx`'s FAB, and every
  small icon-button `position:absolute` use (photo delete/close buttons,
  password-eye toggle, Paywall close button) are correctly screen-anchored
  and should NOT be touched.

---

## 5. Bucket C (Tier 2 — log only, do not fix)

- **MoneyScreen** — ≈16 analytics cards across 4 `MoneySection` groups
  (Cash flow: 4, Customers & invoices: 3, Job pipeline: 5, Tools: 3), not
  "8" as the plan's Phase-4 note stated. A 2-col grid at tablet width is
  Tier 2 (explicitly out of scope — "resist it here").
- **PricingCalculatorScreen** — `SmallInput` rows (Hours/Rate,
  Overhead/Margin/Travel) could go 2- or 3-across at tablet width instead of
  wrapping; explicitly out of scope per the plan.
- **JobsScreen / InvoicesScreen / CustomersScreen** — master-detail / split
  view is Tier 3, not touched here at all.
- **CustomerDetailScreen** — hero + stats row could sit side-by-side with
  the invoice/job history at tablet width; Tier 2/3 (approaches
  master-detail).
- **SettingsScreen** — the single long column of cards could go 2-up per
  section at tablet width; Tier 2, and risky given the screen's dirty-guard/
  save-flow complexity — do not touch beyond the content column in Phase 5.

---

## 6. Plan-claim re-verification (grep, current worktree)

| Check | Plan (2026-07-24) | Current | Notes |
|---|---|---|---|
| `Dimensions.get(` | 0 | **1** (`App.tsx:554`, inside `FontScaleWatcher`) | Not a layout usage — reads `Dimensions.get("window").fontScale` to detect a live OS text-size change, unrelated to iPad width work. Effectively still 0 for layout purposes. |
| `useWindowDimensions()` | 0 | **0** | Confirmed unchanged. |
| `numColumns` grids | 0 | **0** | Confirmed unchanged. |
| `maxWidth` in use today | 2 (`AddTripScreen.tsx:211`=180, `ChatScreen.tsx:299` bubble=82%) | **2**, same values, lines shifted: `AddTripScreen.tsx:212`, `ChatScreen.tsx:329` — plus the **new** `utils/theme.ts:149` (the Phase 1 token itself, not a pre-existing app use) | Counts still hold; only line numbers drifted from intervening commits. |
| Root wrapper consistency | 25/26 SafeAreaView, 26 define `createStyles`, AuthScreen the one exception | **29/31 SafeAreaView**; **two** exceptions (AuthScreen, TodayScreen) | See §2 correction. All 31 screens define `createStyles(colors, shadow)`. |
| `contentContainerStyle` call sites | 30 | **35** occurrences across **30 of 31** screen files (0 in `components/`) | The missing file is `CustomerDetailScreen.tsx` (no `contentContainerStyle` prop anywhere in the file — its `ScrollView` takes none). `MoneyScreen.tsx` and 4 other files each have 2 occurrences (two separate scrollables); `MoneyScreen.tsx`'s *primary* overview `ScrollView` is itself among the ones lacking the prop — see §2 row 18. |
| Fixed pixel widths (small chrome) | 49 | Not re-run exhaustively — spot-checked via the maxWidth/FAB/icon-circle citations above; nothing found in the 31-screen read that contradicts "all correct at any screen size." | Out of scope to re-grep precisely; no evidence surfaced during the full-file reads of a regression here. |
| Render-based tests | 4 (`Field`, `UI`, `SyncBanner`, `useRefresh`) | Not re-verified — outside this task's scope (docs-only, no test suite changes) | Per `tradeready-validation-and-diagnostics`, current baseline is far larger (1635 tests / 106 suites per MEMORY.md) — the plan's "4 render tests" figure is almost certainly stale but re-counting is a job for the validation skill, not this audit. |

---

## 7. Self-review

- **Inventory completeness**: all 31 files currently in `screens/` are
  listed in §2's table (cross-checked row count = 31 against `ls screens/ |
  wc -l` = 31).
- **Style-key spot checks** (3, per task instructions):
  1. `JobDetailScreen.tsx:1136` `viewerImage: { width: "100%", height: "80%" }`
     — confirmed present exactly as cited, used at line 428.
  2. `AddTripScreen.tsx:212` `maxWidth: 180,` inside the `chip` style —
     confirmed present.
  3. `RecurringInvoicesScreen.tsx:169` `<Fab` — confirmed present
     (multi-line JSX; a same-line `Fab onPress` grep would have missed this
     one, which is why the FAB citations in §2 were re-verified with a
     `<Fab` pattern instead of a same-line match).
- All other line citations in this document were captured directly from
  `Read` tool output at the time of writing (not re-typed from memory), so
  they should be exact as of this commit; they will drift again the moment
  Phase 3+ starts editing these files, same as the plan's own citations
  drifted over the last 9 days.

---

## Phase 6 outcomes — device-smoke checklist

**Date:** 2026-08-02 · **Branch:** `feat/ipad-tier1`

Same method caveat as the rest of this document: **no simulator or physical
device exists on this box**, so everything below is code reasoning plus the
verify gate. Percentage arithmetic against known device point-sizes is exact;
anything involving the native picker's intrinsic height, keyboard geometry, or
contrast is a **prediction** and is listed in the Phase 7 checklist at the end.

Phase 6 changed **three** app files: `screens/JobDetailScreen.tsx`,
`components/DateTimePickerSheet.tsx`, `screens/ChatScreen.tsx` (plus
`__tests__/dateTimePickerSheet.test.ts`, extended). §4.3 and §4.4 were
verify-only by design and no code was touched for them.

### 6.1 — §4.1 JobDetailScreen photo viewer `[landscape]` — **CHANGED**

**Correction to §4.1's stated mechanism.** §4.1 predicted the image would
"distort/overflow… since `contentFit="contain"` inside a fixed-aspect box
still obeys the box's own width/height ratio". That is not how containment
works, and re-reading the call site confirms it cannot happen here:
`screens/JobDetailScreen.tsx:428` renders `Image` from **expo-image** (import
at line 19) with `contentFit="contain"`, which preserves the source aspect
ratio and never draws outside the box. **No distortion and no overflow are
possible in either orientation, before or after this change.**

**The defect that is real.** The box was `{ width: "100%", height: "80%" }` —
a 20% inset on the height axis and none on the width axis. That is a
portrait-tuned constant: in portrait, width is the scarce axis so the height
cap costs nothing; in landscape, **height is the scarce axis** and the cap
threw away a fifth of it while width stayed edge-to-edge. Worked example on an
11" iPad landscape (1194×834) with an ordinary 4:3 photo:

| | box | rendered photo |
|---|---|---|
| before | 1194 × 667 | 889 × 667 |
| after | 1194 × 834 | 1112 × 834 |

i.e. the photo was rendering **25% smaller (linear) than the screen allowed**,
purely because of the portrait-tuned cap.

**Change** — one style key, `viewerImage`:
`{ width: "100%", height: "80%" }` → `{ width: "100%", height: "100%" }`.
This is the resizeMode-aware reading of the fix: *because* the mode is
`contain`, the correct box is the full viewport on both axes and containment
does the letterboxing. (Had the mode been `cover`, the opposite would be true —
the box shape would dictate the crop and this change would be wrong.)

**Phone-unchanged argument.** With `contain`, an image whose aspect ratio is
**wider than the box's** is width-limited, so its rendered size depends on the
box *width* only and is completely independent of the box height; it is also
centered either way. Phone portrait 393×852: old box aspect 0.576, new box
aspect 0.461. Every ordinary camera photo is above both figures — 3:4 = 0.75,
2:3 = 0.667, 1:1, and all landscape ratios — so those render **pixel-identical,
same size and same position**. What changes is only the ultra-tall class that
was previously height-limited: a 9:16 phone screenshot goes 384×682 → 393×699
(+2.5%), and a 9:19.5 screenshot 315×682 → 393×851. That is the "letterboxing
difference from correct containment" the phase brief pre-approved, and it is
the desired direction (a screenshot should fill the viewer).

**Residual risk — the one thing to look at on device.** `viewerClose`
(`position:absolute, top:56, right:20`, 36pt) occupies y 56…92. Under the old
80% box the letterbox band above the photo was 10% of the viewport — 85pt in
phone portrait, 83pt in iPad landscape — so the button sat over black, with at
worst ~7–9pt of overlap for a height-limited photo. With a full-height box, any
photo narrower in aspect than the viewport now fills the height and the button
lands **on the photo**; a white glyph on `rgba(255,255,255,0.15)` over a bright
photo is low contrast. Reachability is unaffected (fixed position, `hitSlop`),
and this is a legibility judgement no static read can settle.

Two ways out, both cheap, for the owner to weigh in Phase 7:

- **Revert:** restore `height: "80%"` on `viewerImage` — one key, accepting the
  25% landscape size loss back.
- **Darken the scrim:** `viewerClose.backgroundColor`
  (`screens/JobDetailScreen.tsx:1153`, currently `rgba(255,255,255,0.15)`) → a
  darker value keeps the full-bleed photo *and* makes the button legible over
  it. This is also **one key, not a viewer redesign** — it was left out of
  Phase 6 only because it visibly changes the button on the phone viewer too
  (over the near-black `viewerBg` a light-translucent circle reads as a soft
  grey disc; a dark one would nearly disappear), so it needs a look on device
  before being chosen, and probably a border or shadow to work on both
  backgrounds.

### 6.2 — §4.2 `components/DateTimePickerSheet.tsx` `[landscape]` — **CHANGED**

**The defect is sharper than §4.2 stated.** §4.2 said the sheet "can approach
or exceed available height". What actually happens when it exceeds: `overlay`
is `justifyContent: "flex-end"` and RN's default `flexShrink` is **0**, so a
sheet taller than the overlay is laid out at a *negative* top offset — it
overflows off the **top**, which is precisely where `header` and its **Done**
button live. The iOS branch has no backdrop-press handler and no reachable
`onRequestClose` path on iOS, and the component's own header comment says "the
sheet has no cancel path" — so Done is the **only** dismissal control.
Overflowing it off-screen is not cosmetic; it is a modal the user cannot leave.

**Height budget** (the calendar figure is the one approximate number):
`mode:"date"` ≈ header 56 + inline calendar ~350 + `marginBottom` 8 +
`paddingBottom` 40 ≈ **455pt**; `mode:"time"` ≈ **320pt** (216pt spinner).

**Where the new cap binds — nowhere on iPad, nowhere in phone portrait:**

| Viewport | height | 85% cap | date sheet ≈455 |
|---|---|---|---|
| iPad mini landscape (shortest iPad) | 744 | 632 | fits — cap never binds |
| iPad 11" landscape | 834 | 709 | fits |
| iPad portrait (any) | ≥1024 | ≥870 | fits |
| iPhone SE portrait (shortest phone) | 667 | 567 | fits — cap never binds |
| **iPhone landscape** | **393** | **334** | **binds** |

So the cap is **insurance, not an iPad fix**: the only configuration it changes
is iPhone landscape, which Phase 7's `orientation: "portrait" → "default"` flip
newly makes reachable. Stated plainly so nobody later reads it as an iPad
claim.

**Three changes, all internal to the component, none at a call site:**

1. `sheet` gains `maxHeight: "85%"` — the header can no longer leave the
   screen. Same constant and same pattern as the already-shipped
   `components/money/TaxSettingsModal.tsx` sheet.
2. The **inline-calendar branch only** is wrapped in a plain
   `<ScrollView bounces={false} showsVerticalScrollIndicator={false}>`, so when
   the cap binds the bottom weeks stay reachable instead of being pushed below
   the fold. No explicit flex style is needed (and TaxSettingsModal's inner
   ScrollView has none either) because RN's ScrollView base style already
   carries `flexGrow: 1, flexShrink: 1, overflow: "scroll"` — it shrinks inside
   the capped column and becomes scrollable. When the cap does not bind the
   ScrollView is unconstrained, sizes to its content and cannot scroll, so it
   is a layout no-op on every iPad orientation and every phone portrait.
   The **spinner branch is deliberately left unwrapped** — it fits everywhere
   at ~320pt, and not wrapping it avoids nesting the wheels' own scroll views.
3. `sheet` gains `...layout.contentColumn` (§4.2's second suggestion) so the
   sheet stops spanning ~1180pt edge-to-edge on iPad. No-op below 700pt, so
   every phone width is untouched.

**Commit-on-Done preservation argument (owner requirement, 2026-07-16).** The
contract lives entirely in three places, and **all three are byte-identical
after the change**: the Done `TouchableOpacity`'s `onChange(pickerValue);
onClose();` body, the picker's own live
`onChange={(_, d) => { if (d) onChange(d); }}`, and `pickerValue`'s
`roundToMinuteInterval` pre-rounding. The Android branch is untouched. No prop
passed to `DateTimePicker` changed — the element is merely bound to a `const`
and then conditionally wrapped. The change is sizing/positioning only, exactly
as §4.2 required.

**The contract was already under test, and still is.**
`__tests__/UI.test.js:159` — "Done commits the currently displayed value before
closing (iOS)" — has covered exactly this since 2026-07-16 and cites the same
owner report; it renders the sheet in `mode:"date"`, presses Done, and asserts
`onChange(shown)` plus a single `onClose`. **It passes unchanged through the
ScrollView wrap**, which is the strongest single piece of evidence that the
commit path survived this phase. (An earlier draft of this section claimed the
contract had zero coverage before Phase 6. That was wrong and the error was
avoidable: the check looked at the sheet's own suite and the two modals that
mount it, but never grepped `__tests__/` for the component name.)

Four render tests were nevertheless added to
`__tests__/dateTimePickerSheet.test.ts`, co-located with the sheet's own suite
rather than duplicating the `UI.test.js` case: not-visible renders nothing; the
calendar branch keeps both the picker and Done reachable (the regression guard
specific to the ScrollView wrap, which `UI.test.js` does not assert); Done
commits the displayed value when the picker was never touched; and Done commits
the interval-rounded value in time mode (the `roundToMinuteInterval` path
through Done, which nothing covered before). No existing assertion anywhere was
changed or weakened.

**Note for the record:** Phase 6's brief described the contract as "value
commits only when Done is tapped, cancel/backdrop discards". That is not the
shipped behavior — the picker commits **live** through its own `onChange`, and
there is no backdrop/cancel path at all. Done's actual job is committing the
*untouched* fallback. Nothing in Phase 6 changes either half of that.

### 6.3 — §4.5 ChatScreen `[tablet-width]`

**(a) Bubble `maxWidth: "82%"` — VERIFIED, no change.** Phase 5 applied the
column to `listContent`, which is
`{ padding: spacing.md, paddingBottom: spacing.sm, ...layout.contentColumn }`.
Percentages resolve against the parent's **content box**, so the chain is:
FlatList content container capped at 700pt → minus `spacing.md` (16) padding
each side → `bubbleRow` = 668pt → bubble `maxWidth` = 0.82 × 668 =
**≈548pt**, at any iPad width and in either orientation. §4.5's "≈574pt" figure
took 82% of the outer 700 and omitted the 32pt of padding; **548pt is the
correct number**. Either way the conclusion stands — that is a normal chat
bubble width and needs no bubble-specific fix.

**(b) Empty state — CHANGED** (Phase 5 reviewer finding). The empty state is a
**sibling** of the FlatList (`isEmpty ? <EmptyState/> : <FlatList/>`), not a
cell inside it, so Phase 5's column on `listContent` never reached it and the
zero-message screen stretched full-width on iPad while the populated one sat at
700pt. Fixed by the standard trailing spread on the empty-state container:
`emptyWrap: { flex: 1, padding: spacing.lg, paddingTop: 48,
alignItems: "center", ...layout.contentColumn }`. `emptyWrap` — not
`quickGrid` — is the right container: it caps the title and subtitle too, and
`quickGrid`'s `width: "100%"` then resolves against the capped parent
automatically. **Phone unchanged:** `emptyWrap` previously took full width by
`alignItems: stretch` from its parent; `width: "100%"` reproduces that exactly,
`maxWidth: 700` cannot bind below 700pt, and `alignSelf: "center"` is a no-op
at full width. `flex: 1` is a main-axis (vertical) property and does not
interact with the cross-axis keys the token sets.

### 6.4 — §4.3 KeyboardAvoidingView + §4.4 KeyboardDoneBar — **VERIFY-ONLY, no code changed**

**No concrete defect is provable from code alone**, which is the bar Phase 6's
brief set for touching these. Both items are runtime-geometry problems: the
failure modes depend on the keyboard frame iOS reports, which cannot be
observed on this box, and a wrong offset change regresses phones — where the
current values are shipped and known-good.

**§4.3 count correction:** 11 *screens* use `KeyboardAvoidingView` but there
are **12 instances** — `SettingsScreen.tsx` has two (line 528 for the screen,
line 1078 inside the delete-account modal). Props re-verified:
`behavior={Platform.OS === "ios" ? "padding" : undefined}` in
AddCustomer(234) / AddInvoice(119) / AddJob(421) / AddRecurringInvoice(184) /
CreateInvoiceFromJob(284) / PricebookEntry(185) / PricingCalculator(405) /
Settings(528, 1078); `"padding" : "height"` in Auth(211), Onboarding(190) and
Chat(196); only **ChatScreen** passes `keyboardVerticalOffset`, and it passes
`useHeaderHeight()` (line 197) rather than a constant — the one value that
adapts to iPad chrome by itself.

What is *predicted* but unverifiable here: RN's `KeyboardAvoidingView` derives
its inset from the reported keyboard frame, so an iPad **floating** keyboard
(small, draggable, not docked at the bottom) and a **split** keyboard can make
it reserve space that does not correspond to what is actually covering the
input. This is RN-level behavior, not something this codebase configures — no
screen conditions `behavior` or the offset on screen size today.

**§4.4 KeyboardDoneBar:** the bar renders inside `InputAccessoryView`, whose
width is set by the **keyboard/window**, not by our content column — so a
`layout.contentColumn` spread on `bar` would not be honoured the way it is
elsewhere, and with `justifyContent: "flex-end"` the Done button tracks the
window's right edge while the input column is centred. Confirmed cosmetic, not
functional, and **not** orientation-driven. Two device-only unknowns: whether
the accessory bar appears at all with a floating keyboard, and that with a
**hardware keyboard attached** iPadOS shows no software keyboard and therefore
no accessory bar — in that state a `decimal-pad`/multiline field has no in-app
Done affordance and relies on the hardware keyboard. Worth confirming before
deciding whether §4.4 needs any Tier-1 work at all.

### Phase 7 physical-iPad smoke checklist (Phase 6 items only)

Photo viewer — `JobDetailScreen`:
- [ ] Open a **landscape** photo and a **portrait** photo in **iPad portrait**; confirm each is fully visible, correctly proportioned, and centered.
- [ ] Repeat in **iPad landscape**; confirm the photo now uses the full height (this is the change) and is not cropped.
- [ ] **Close-button legibility over a bright photo**, both orientations — the single judgement call of this phase. Also confirm it is still easy to hit.
- [ ] Rotate while the viewer is open, both directions.
- [ ] iPhone regression: a normal camera photo must look exactly as before.

Date/time picker — all 9 call sites (`AddJobScreen` ×4: date, start, end, recurrence end; `AddRecurringInvoiceScreen` ×2; `ExportDataScreen` ×1; `AddExpenseModal` ×1; `RecordPaymentSheet` ×1):
- [ ] iPad **landscape**, `mode:"date"`: sheet centered at 700pt (not edge-to-edge), header + Done visible, whole calendar visible without scrolling.
- [ ] iPad landscape, `mode:"time"`: spinner reads correctly, Done visible.
- [ ] **Month-swipe and the tap-to-expand year list still work** inside the newly wrapped calendar — the one gesture risk of the ScrollView wrap.
- [ ] **Commit-on-Done, untouched:** open a picker on a field with no value and tap Done immediately → the parent takes today/now.
- [ ] **Commit-on-Done, touched:** scroll to a value, tap Done → that value lands.
- [ ] Confirm there is still no backdrop dismissal (unchanged, but verify Phase 6 introduced none).
- [ ] Rotate with a picker open.
- [ ] iPhone regression: one date and one time picker in portrait must look identical to today.
- [ ] If iPhone **landscape** is exercised after the orientation flip: open `mode:"date"`, confirm Done is reachable and the calendar scrolls.

Chat — `ChatScreen`:
- [ ] **Empty state** on iPad, both orientations: title, subtitle, and quick-prompt buttons capped at 700pt and centered, matching the populated chat.
- [ ] **Populated state**: bubbles read at ≈548pt max; the empty→populated transition does not shift the column.
- [ ] Composer row stays aligned with the column in both states.

Keyboard (11 screens / 12 KAV instances, plus the Done bar):
- [ ] Docked keyboard on each KAV screen: focused field stays visible, no double gap, no content jump.
- [ ] **Floating keyboard**: does the layout over-reserve space? Does the Done bar appear?
- [ ] **Split keyboard**: same two questions.
- [ ] **Hardware keyboard attached**: confirm `decimal-pad` and multiline fields are still usable with no accessory bar.
- [ ] `ChatScreen` specifically — the only screen with a `keyboardVerticalOffset`; check the composer in both orientations and after rotating with the keyboard up.
- [ ] `SettingsScreen`'s delete-account modal (the second KAV instance) with the keyboard up.
- [ ] Done bar horizontal position at iPad width — cosmetic; decide then whether §4.4 warrants any work.
