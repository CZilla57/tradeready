# Onboarding Improvements Design

Eight enhancements to the existing 5-step onboarding wizard that improve data quality, reduce friction, and increase feature discovery. No new screens or navigation routes — all changes are additive within the existing flow.

## Files touched

| File | Change |
|---|---|
| `screens/OnboardingScreen.tsx` | All UI changes (address, logo, validation, retry, dots, Stripe card) |
| `types/models.ts` | Add `logoPhoto?: string` to `Settings` |
| `utils/storage/defaults.ts` | Add `logoPhoto: ""` to `defaultSettings()`; add `SAMPLE_INVOICE_DESCS` map; `defaultInvoices()` gains `trade` param |
| `App.tsx` | No change — `OnboardingScreen` already receives `onComplete` and has access to `useAuth()` |

## 1. Step 1 — Business Info Enhancements

### Pre-fill email from auth

`OnboardingScreen` calls `useAuth()` to access `session.user.email`. On mount, if that email exists and `form.email` is still empty, pre-fill it. The user can edit or clear it.

### Address field

Add a multiline `address` field after the email field. Label: "Business address". Placeholder: "123 Main St, City, State ZIP". Optional — no validation gate. The value flows into `Settings.address`, which already exists in the type and defaults but has never been surfaced in any UI.

### Logo picker

Below the address field, an optional "Add your logo" section:

- Circular placeholder (camera icon) when no logo is set
- Tapping shows an `Alert` with "Take Photo" / "Choose from Library" / "Cancel" — same pattern as `JobDetailScreen`
- Uses `expo-image-picker` + `persistPhoto()` with folder `"logos"`
- Once picked, displays the image in the circle with an "x" remove button
- Stored as `logoPhoto` on `Settings`
- Type change: add `logoPhoto?: string` to `Settings` interface in `types/models.ts`
- Default change: add `logoPhoto: ""` to `defaultSettings()` in `defaults.ts`

## 2. AI Retry on Failure

All three AI features in onboarding currently swallow errors silently (returning `""` from `sendOnboardingAI`). Each gains a visible error state with a retry action.

### Trade tips (Step 2)

Track `tipsError` boolean. When `sendOnboardingAI` returns `""`, set `tipsError = true` and `tipsLoading = false`. Render inside the `aiCard`: muted text "Couldn't load tips" with an accent-colored "Retry" touchable on the same line. Retry resets `tipsError`, sets `tipsLoading = true`, clears `tipsTradeRef.current` to force the effect to re-fire.

### Rate suggestion (Step 2)

Track `rateError` boolean in `RateSuggestion`. On empty response, set `rateError = true`. Show "Couldn't check rates" + "Retry" link. Retry resets `lastQueryRef.current` and `rateError`, sets `loading = true`, re-fires the AI call.

### First steps (Step 4)

Track `actionsError` boolean in `StepDone`. On empty response, set `actionsError = true`. Show "Couldn't load suggestions" + "Retry" link. Retry sets `fetchedRef.current = false` and `actionsError = false`, then re-triggers the effect.

### Visual pattern

All three retry states share the same layout: a row inside the existing `aiCard` with muted error text and an accent-colored "Retry" `TouchableOpacity`. Add styles `retryRow`, `retryText`, `retryBtn`, `retryBtnText` to the stylesheet.

## 3. Input Validation — Soft Warnings

Non-blocking yellow warning text below fields. Never prevents "Continue."

### Tracked fields

Add a `touched` state object: `{ email: false, phone: false, laborRate: false }`. Each flips to `true` on the corresponding field's `onBlur`. Warnings render only when `touched[field] === true` and the value fails its check.

### Validation rules

| Field | Condition for warning | Message |
|---|---|---|
| Email | Non-empty and doesn't match `/^\S+@\S+\.\S+$/` | "This doesn't look like a valid email address." |
| Phone | Non-empty and fewer than 10 digits | "Phone number looks incomplete." |
| Labor rate | Parsed value outside $10–$500, or empty/NaN | "This rate seems unusual — double-check before continuing." |

### Style

Warning text: `fontSize.xs`, `color: colors.warning`, `marginTop: 2`. Email and phone warnings appear in Step 1. Rate warning appears in Step 2 below the rate input.

### Threading `touched` and `onBlur`

The `touched` state lives in the parent `OnboardingScreen` component. A `markTouched(field)` callback is passed down. `StepBusiness` receives `touched` and `markTouched` directly via its existing `StepProps`-like interface. `StepTrade` also receives them and forwards them to its child `RateSuggestion`. The existing `Field` component wrapper passes `onBlur={() => markTouched(fieldName)}` through to `BaseField`/`TextInput`. The rate `TextInput` in `RateSuggestion` gets `onBlur` directly.

## 4. Step-Jump Navigation via Progress Dots

### Behavior

Each progress dot becomes a `TouchableOpacity`. Tapping a dot navigates to that step with one constraint: if Step 1 fields are incomplete (business name or contact name empty), forward jumps to steps 2–4 are blocked. Backward jumps are always allowed. Steps 2+ have valid defaults, so no other gates.

### Implementation

Wrap each dot `View` in a `TouchableOpacity`. `onPress` calls `setStep(i)` guarded by:

```
function canNavigateTo(target: number): boolean {
  if (target <= step) return true; // backward always OK
  if (target >= 2) return form.businessName.trim().length > 0 && form.contactName.trim().length > 0;
  return true;
}
```

### Visual

Dots get `padding: 4` for a larger hit target. No other visual change — they already communicate position via the active/inactive color.

## 5. Stripe Connect Info Card (Step 4)

A new informational card on the Done screen, placed between the notification card and the AI first-steps card.

- Uses the same `aiCard` / card styling
- Icon: `💳`
- Title: "Accept payments"
- Body: "Connect your Stripe account in Settings → Payment Processor to send payment links with your invoices."
- No button, no API call — purely informational text

## 6. Trade-Matched Sample Invoice Descriptions

### Problem

Sample jobs are plumbing-themed but sample invoices have unrelated descriptions ("Lawn care contract," "Logo refresh").

### Solution

Add a `SAMPLE_INVOICE_DESCS` constant in `defaults.ts`: a `Record<TradeId, string[]>` mapping each trade to 4 invoice descriptions appropriate for that trade.

Examples:

- `plumbing`: "Kitchen faucet replacement", "Emergency pipe repair", "Water heater flush", "Bathroom remodel — rough-in"
- `electrical`: "Panel upgrade — 200A", "Recessed lighting install", "Outlet and switch replacement", "EV charger installation"
- `hvac`: "AC unit service call", "Furnace replacement", "Ductwork repair", "Thermostat installation"
- `carpenter`: "Custom shelving build", "Deck repair and staining", "Door frame replacement", "Cabinet installation"
- `bricklayer`: "Garden wall construction", "Chimney repointing", "Patio brickwork", "Foundation repair"
- `plasterer`: "Living room skim coat", "Ceiling repair", "Full room replaster", "Decorative cornice work"
- `landscaping`: "Spring cleanup and mulching", "Patio paver installation", "Weekly mowing contract — Q2", "Tree trimming and removal"
- `cleaning`: "Deep clean — 3BR house", "Post-construction cleanup", "Office weekly service", "Move-out clean"
- `painting`: "Interior 2-room repaint", "Exterior house painting", "Cabinet refinishing", "Deck staining"
- `handyman`: "Fence repair", "Drywall patch and paint", "Ceiling fan installation", "Gutter cleaning"
- `other`: "Service call", "Project estimate", "Maintenance visit", "Repair work"

### API change

`defaultInvoices()` signature changes from `(): Invoice[]` to `(trade?: TradeId): Invoice[]`. When `trade` is provided, descriptions come from `SAMPLE_INVOICE_DESCS[trade]`; otherwise falls back to the `"other"` descriptions.

Callers: `defaultInvoices` is called in `utils/storage/index.ts` as a fallback when no invoices exist in AsyncStorage. That call does NOT pass a trade and gets the `"other"` fallback descriptions.

### OnboardingScreen change

In `finish()`, explicitly save trade-matched sample data:
- When `dataChoice === "sample"`: call `saveInvoices(defaultInvoices(form.trade))` to persist invoices with trade-appropriate descriptions. This overwrites the generic defaults that were loaded as fallback.
- When `dataChoice === "fresh"`: call `clearSampleData()` as before (which wipes invoices, jobs, customers, expenses).

## Out of scope

- Full trade-specific sample jobs and customers (only invoice descriptions change)
- Stripe Connect flow during onboarding (informational only)
- Hard-blocking validation (all warnings are soft)
- New screens or navigation routes
- Logo display on invoices/estimates (separate feature — this just collects and stores it)
