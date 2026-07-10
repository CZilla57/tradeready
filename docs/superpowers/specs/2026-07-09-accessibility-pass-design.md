# Accessibility Pass — Shared Components

**Date:** 2026-07-09
**Scope:** Props-only a11y labeling on 7 shared components (Approach A)
**Consumer changes:** None — all labels derived from existing props

## Goal

Add `accessibilityLabel`, `accessibilityRole`, and `accessibilityState` to the shared UI components so screen readers (VoiceOver / TalkBack) can announce every interactive element. This pass targets the shared components only; screen-specific inline touchables are a future follow-up.

## Why shared components first

`UI.tsx` is imported by 13 screens; `Field.tsx` by 6. Labeling these covers ~60% of interactive elements across the app with changes to only 3 files and zero consumer modifications.

## Components

### 1. Button (`components/UI.tsx`)

**Element:** `TouchableOpacity`

| Prop | Value |
|------|-------|
| `accessibilityRole` | `"button"` |
| `accessibilityLabel` | `{label}` (existing prop) |
| `accessibilityState` | `{{ disabled: !!loading, busy: !!loading }}` |

Screen reader announces: "Save, button" or "Save, button, busy" when loading.

### 2. Badge (`components/UI.tsx`)

**Element:** outer `View`

| Prop | Value |
|------|-------|
| `accessibilityRole` | `"text"` |
| `accessibilityLabel` | `{label}` (existing prop) |

### 3. StatCard (`components/UI.tsx`)

**Element:** outer `View`

| Prop | Value |
|------|-------|
| `accessible` | `{true}` |
| `accessibilityLabel` | `` {`${label}: ${value}`} `` |

`accessible={true}` groups the two child `Text` nodes into one focusable element. Reads as a single announcement ("Outstanding: $4,200") instead of two disconnected text nodes. No `accessibilityRole` — "summary" is iOS-only and not a valid RN role on Android.

### 4. Card (`components/UI.tsx`)

**Element:** `TouchableOpacity` (when `onPress` provided)

| Prop | Value |
|------|-------|
| `accessibilityRole` | `"button"` (only when tappable) |

No label added — Card is a generic container; children provide their own labels. Static cards (no `onPress`) get no a11y changes.

### 5. Field (`components/Field.tsx`)

**Element:** `TextInput`

| Prop | Value |
|------|-------|
| `accessibilityLabel` | `{label}` (existing prop, e.g. "Email", "Business name") |

Highest-impact single change: every Field-using form gets labeled inputs automatically.

### 6. SectionHeader (`components/UI.tsx`)

**Element:** `Text`

| Prop | Value |
|------|-------|
| `accessibilityRole` | `"header"` |

Enables VoiceOver rotor section-jumping.

### 7. EmptyState (`components/UI.tsx`)

No changes. Plain `Text` inside a `View` — already readable by screen readers.

### 8. Divider (`components/UI.tsx`)

**Element:** `View`

| Prop | Value |
|------|-------|
| `accessibilityElementsHidden` | `{true}` |
| `importantForAccessibility` | `"no"` |

Decorative separator — hidden from screen readers entirely.

### 9. DateTimePickerSheet (`components/DateTimePickerSheet.tsx`)

**iOS Modal Done button (`TouchableOpacity`):**

| Prop | Value |
|------|-------|
| `accessibilityRole` | `"button"` |
| `accessibilityLabel` | `"Done"` |

**iOS `Modal`:**

| Prop | Value |
|------|-------|
| `accessibilityLabel` | `{title}` (existing prop, e.g. "Select date") |

## Files changed

1. `components/UI.tsx` — Badge, Button, Card, StatCard, SectionHeader, Divider
2. `components/Field.tsx` — TextInput label
3. `components/DateTimePickerSheet.tsx` — Modal + Done button

## What this does NOT cover

- Inline `TouchableOpacity` in individual screens (job cards, invoice rows, filter tabs, icon buttons)
- `TextInput` fields not using the shared `Field` component (search bars, PricingCalculator numeric inputs, Auth form)
- `Switch` toggles in Settings/AddJob/Outreach/PricingCalculator
- Dynamic type / font scaling
- Color contrast fixes
- `RefreshControl` (pull-to-refresh)

These are separate follow-up passes.

## Verification

- `npm run typecheck` — must stay green (0 errors)
- `npm test` — must stay at 347 tests passing
- `npm run lint` — must stay clean
- No visual changes — a11y props are invisible to sighted users
