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
