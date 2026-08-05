# Settings Hub + Focused Subpages — Design

**Date:** 2026-08-05
**Status:** Owner-approved design; not yet implemented
**Scope:** SettingsScreen.tsx becomes a menu hub; its 13 sections split into 11 focused subpage screens registered on TodayStack; shared draft/guard machinery extracted to hooks/useSettingsDraft.ts; settingsValidation split into composable helpers; SetupChecklistCard deep-links; bookingLinkSettings.test.tsx re-pointed; new hub + hook tests

## Problem

`screens/SettingsScreen.tsx` is a 1,390-line single scroll holding thirteen
sections: business profile, pricing defaults, invoice numbering, appearance,
payment processor, booking link, AI assistant, notification rules + automation
toggles + message templates, review requests, subscription, support, legal, and
account management. Finding any one setting means scrolling past all the
others, and every new feature that adds a toggle (estimate follow-ups,
auto-invoice, booking link…) makes it longer. The screen should become a menu
of focused subpages.

## Decisions (owner-approved 2026-08-05)

1. **Per-page Save model.** Each form subpage keeps today's exact semantics —
   edits live in a full-`Settings` draft, a header Save commits them,
   `beforeRemove` prompts Keep/Discard on leaving dirty, and malformed values
   are hard-blocked at save. (Chosen over auto-save, which would replace the
   owner-hardened save-time validation gate, and over a hybrid with two
   interaction models.)
2. **The route name `Settings` stays** and becomes the hub, so both existing
   entry points (Today's header gear, SetupChecklistCard) keep working.
3. **Booking link gets its own row/page** (it's lead-gen, not payments; it was
   not in the owner's original grouping list — explicitly approved).
4. **Support and Legal get no subpages** — they are single actions (compose
   support email, open privacy/terms URLs) and live as action rows directly on
   the hub.
5. **Sign out lives on the Account page**, not the hub — destructive actions
   sit one deliberate tap deeper.
6. **Setup-checklist tasks deep-link** to the owning subpage instead of the
   hub (approved scope addition).

## Structure

Hub = a menu screen at route `Settings` (replacing the monolith): grouped rows
with Ionicons icon, label, chevron, and a status subtitle where cheap.
New routes are added to `TodayStackParamList` (all `undefined` params) and
registered in App.tsx's TodayStack. Screen files are flat in `screens/` per
repo convention.

| Hub row | Route / screen file | Contents | Save model |
|---|---|---|---|
| Business profile | `SettingsBusiness` / SettingsBusinessScreen.tsx | businessName, contactName, phone, email, address, paymentNotes, region, trade picker, logo picker + lifecycle | Draft + Save |
| Pricing defaults | `SettingsPricing` / SettingsPricingScreen.tsx | laborRate, materialMarkup, overheadPercent, marginPercent, minimumJobFee, emergencyMultiplier, mileageRate | Draft + Save |
| Invoice numbering | `SettingsInvoiceNumbering` / SettingsInvoiceNumberingScreen.tsx | invoicePrefix, invoiceStartNumber, preview note | Draft + Save |
| Appearance | `SettingsAppearance` / SettingsAppearanceScreen.tsx | light / system / dark radio | Immediate (`setTheme`; theme is not part of `Settings`) |
| Payments | `SettingsPayments` / SettingsPaymentsScreen.tsx | provider picker + non-Stripe provider key (draft) AND Stripe connect/status/disconnect (immediate) — same mix as today | Mixed |
| Booking link | `SettingsBooking` / SettingsBookingScreen.tsx | create / share / accepting-requests toggle / regenerate | Immediate |
| AI Assistant | `SettingsAI` / SettingsAIScreen.tsx | Advanced toggle (local UI state) + Groq / Anthropic key fields | Draft + Save |
| Notifications | `SettingsNotifications` / SettingsNotificationsScreen.tsx | overdue day-count rules (draft-text machinery + KeyboardDoneBar), autoOutreachEnabled, autoSendEmailEnabled, appointmentRemindersEnabled, estimateFollowUpsEnabled, autoInvoiceOnComplete, confirmation + on-my-way templates | Draft + Save |
| Review requests | `SettingsReviews` / SettingsReviewsScreen.tsx | reviewRequestEnabled, googleReviewLink, reviewRequestDelayHours, reviewRequestTemplate | Draft + Save |
| Subscription | `SettingsSubscription` / SettingsSubscriptionScreen.tsx | trial/active status, Manage subscription / Subscribe | Immediate |
| Contact Support | *(hub action row — `composeEmail` to support)* | | |
| Privacy Policy / Terms | *(hub action rows — `Linking.openURL`)* | | |
| Account | `SettingsAccount` / SettingsAccountScreen.tsx | Clear Sample Data, Sign Out (incl. unsynced-changes Sync-&-sign-out flow), Delete Account + typed-confirm modal | Immediate / destructive |

Hub subtitles: Payments shows Stripe connect state ("Connected — {name}" /
"Not connected"); Subscription shows "Free trial active" / "Active" /
"Not subscribed" (from `useSubscription`, no network). Other rows have no
subtitle in v1.

## Shared machinery: hooks/useSettingsDraft.ts

One hook replaces the screen-level machinery for every draft page:

```ts
const { s, update, dirty, saving, handleSave } = useSettingsDraft(navigation, {
  validate?: (flushed: Settings) => string[],  // save-time hard block (header Save only — see below)
  flush?: (s: Settings) => Settings,           // e.g. applyRuleDrafts
  onSaved?: (saved: Settings) => void,         // fires on BOTH save paths (header Save and guard-Save)
  onDiscarded?: (saved: Settings) => void,     // fires on the guard's Discard path
  onLoaded?: (loaded: Settings) => void,       // page-local seeding (logo paths)
});
```

Callback contract (what pages hang where):

- `onSaved` — Pricing: `markSetupTaskDone("rate")`. Business:
  `cleanupLogoFiles(saved.logoPhoto)`. Notifications: clear `ruleDrafts` (the
  hook resets `s` to the flushed value; page-local draft state is the page's
  to clear).
- `onDiscarded` — Business: `cleanupLogoFiles(saved.logoPhoto)`, matching
  today's guard-Discard cleanup of logo files copied during the abandoned
  edit. The generic guard carries no logo knowledge.
- **Guard-Save skips `validate`, exactly as today** — the current
  `beforeRemove` Save path flushes and saves without running
  `validateSettingsInput`. Preserve this asymmetry; do not "fix" it (blocking
  a removal on a validation alert has no clean resume path).

The hook owns, exactly as the current screen does:

- `loadSettings()` on mount; page renders null until `s` is set.
- Full-`Settings` draft `s` vs `savedSnapshot`, with ref mirrors for the
  once-registered listeners.
- `dirty` = `!settingsEqual(flush(s), savedSnapshot)` — flushed, so an
  in-progress rule-day edit still counts.
- The header **Save** button (`navigation.setOptions` headerRight, the
  paddingLeft/alignSelf centering pattern), enabled exactly when dirty.
- Tab-switch blur-pop: on blur, if the active tab isn't `Today`, `popToTop()`.
  The parent-state check inherently keeps root-stack covers (PaywallModal)
  from popping the screen.
- THE `beforeRemove` unsaved-edits prompt — single path for back, swipe-back,
  and the tab-switch pop; Save resumes the intercepted action after
  `saveSettings(flushed)` + `syncNotifications()`; Discard resumes raw.
  `suppressDirtyWarnRef` becomes **internal** to the hook (only needed for the
  guard's own resumed dispatches — see "What gets simpler" below).
- `handleSave`: validate (alert + abort on problems) → `saveSettings(flushed)`
  → `syncNotifications()` → `onSaved` → snapshot reset → "Saved" alert.

Because the guard prevents ever leaving a page dirty, only one page's
full-object draft can exist at a time — whole-object saves stay safe. The
stack below a subpage is always just the hub (linear stack), which holds no
draft.

Hub and immediate-action pages don't use the draft hook but DO need the
tab-switch blur-pop; that piece is exported separately (e.g.
`useSettingsTabPop(navigation)`) and composed into `useSettingsDraft`.

## Machinery that moves wholesale (not into the hook)

- **Logo lifecycle → SettingsBusinessScreen:** `touchedLogoPathsRef` seeding
  (via `onLoaded`), `cleanupLogoFiles` at commit/discard points,
  `sweepOrphanedLogos` + the `bootstrapping` gate, and the
  capture-raw-path-before-dangling-check ordering. Behavior shift: the orphan
  sweep now runs when the Business page opens rather than on every Settings
  open — acceptable; the sweep is documented best-effort ("the next launch
  sweeps instead"). All existing comments move with the code.
- **Rule-draft machinery → SettingsNotificationsScreen:** `ruleDrafts`,
  `updateRule`/`commitRule`/`addRule`/`removeRule`, `applyRuleDrafts` (passed
  to the hook as `flush`), and `KeyboardDoneBar nativeID="settingsDone"`.
- **Stripe machinery → SettingsPaymentsScreen:** `fetchStripeStatus` +
  AppState re-fetch listener (onboarding returns from the browser),
  connect/disconnect handlers. The **hub also fetches connect-status** on
  mount/focus to render the Payments subtitle — which preserves today's
  checklist-signal timing (see below).
- **Account actions → SettingsAccountScreen:** clear-sample-data alert,
  sign-out with `pendingCount` unsynced-changes flow (`useSyncStatusContext`),
  `performDeleteAccount` + the typed-confirm (`DELETE_CONFIRM_PHRASE`) modal.

## What gets simpler (deliberate deletions)

- **Booking-link snapshot patching dies.** Today's handlers patch `bookingLink`
  into both `s` and `savedSnapshot` to keep a coexisting draft from clobbering
  the just-persisted link on a later "Save settings" (the Task-10 data-loss
  fix). On a dedicated immediate-action page there is no coexisting draft, so
  the handlers become plain load→mutate→save→setState. The RNTL suite keeps a
  regression guard in spirit by asserting a booking action never marks any
  draft dirty (the page has none to dirty).
- **Sign-out/delete suppress flag dies.** `suppressDirtyWarnRef` existed
  partly so root resets (sign-out, delete) pass the guard silently. On the
  Account page no guard exists and no draft page can be in the stack beneath
  it, so root resets can't trip any prompt. The flag survives only inside
  `useSettingsDraft` for guard-resumed dispatches.
- **The bottom "Save settings" button dies.** Each draft page's header Save is
  the sole commit point.

## Validation split

`utils/settingsValidation.ts` refactors into composable helpers with
`validateSettingsInput` preserved as their composition (existing util tests
pass unchanged):

- `validateEmailPhone({ email, phone })` → used by SettingsBusiness's
  `validate`.
- `validateLaborRate(laborRate)` → used by SettingsPricing's `validate`.

Validation is page-scoped on purpose: a pre-existing bad value in storage
(e.g. laborRate 0 skipped during onboarding) must not block saving the
Business page, which has no labor-rate field to fix.

## Setup-checklist signals and deep-links

- `markSetupTaskDone("rate")` moves from "any Settings save" to **Pricing page
  save** (`onSaved`). Stricter and more honest for a task named "review your
  pricing defaults". (`utils/setupChecklist.ts` itself is unchanged; "rate"
  remains stored-not-derived.)
- `markSetupTaskDone("stripe")` continues to fire whenever connect-status
  returns connected — now from the hub's subtitle fetch AND the Payments
  page's fetch, so the signal timing matches today (fired on opening
  Settings).
- `SetupChecklistCard`'s prop changes to `onOpenSettings: (task: SetupTaskId)
  => void`; TodayScreen maps contact/logo → `SettingsBusiness`, rate →
  `SettingsPricing`, stripe → `SettingsPayments`. The notifications task stays
  in-card (permission prompt, unchanged). The gear still navigates to the hub.

## Invariants preserved (verify against tradeready-architecture-contract)

- No persisted data-shape change: `Settings`, AsyncStorage keys, and
  SECURE_FIELDS stripping are untouched; every page saves through the existing
  `saveSettings`.
- Local-first: no new network on any render path (hub's Stripe fetch is
  fire-and-forget status decoration, same as today's Settings mount fetch).
- Theming: every new screen uses the `createStyles(colors, shadow)` +
  `useMemo` factory pattern; styles are copied per page from the current
  monolith (shared UI.tsx components reused; no new shared style module in v1
  — the per-screen createStyles convention holds).
- Subscribe button still reaches PaywallModal via
  `navigation.getParent()?.getParent()?.navigate("PaywallModal", …)` — the
  TodayStack → MainTabs → RootStack nesting depth is unchanged for subpages.
- iPad: `layout.contentColumn` in each page's scroll container, as today.
- KeyboardAvoidingView pattern (not automaticallyAdjustKeyboardInsets) on
  every form page, per the device finding noted in the monolith.

## Testing

- `__tests__/bookingLinkSettings.test.tsx` re-points at SettingsBookingScreen
  and slims to the surviving behaviors (create, share, toggle, regenerate,
  invalid-state alerts, never-dirties assertion).
- `TodayScreenSettingsGear.test.tsx` unchanged (route name preserved).
- New: hub RNTL suite (all rows render; each row navigates to its route;
  support/legal/account rows call composeEmail / openURL / navigate);
  `useSettingsDraft` behavior tests via a minimal harness screen (dirty
  tracking, flush folding, validate blocking, guard prompt paths, save
  side-effects incl. syncNotifications and onSaved); per-page smoke suites
  where cheap (Pricing validate wiring, Notifications rule flush).
- Existing `settingsDirty.test.js` / `settingsValidation.test.js` unchanged
  (validation refactor keeps `validateSettingsInput`'s contract).
- Gate green (tsc 0 / all suites / lint 0) before commit. JS-only → rides the
  next OTA.

## Out of scope

- Auto-save / per-field validation (rejected — see Decisions).
- Any change to what settings exist or their shapes.
- Visual redesign of shared components; hub styling reuses existing list-row
  patterns from the monolith.
- Search within settings, per-page reset-to-defaults, or hub reordering.

## Risks

- **Relocation regressions** in the subtle machinery (logo lifecycle, rule
  drafts, guard). Mitigation: move code with its comments wholesale, keep the
  hook a faithful extraction (not a redesign), cover with the new tests.
- **TodayStack registration bloat** (11 new routes) — mechanical; a missed
  registration is a runtime navigation crash, so the hub test asserts every
  row's target route resolves.
- **Checklist-signal drift**: "rate" now requires visiting the Pricing page;
  accepted as deliberate (Decision + section above).
