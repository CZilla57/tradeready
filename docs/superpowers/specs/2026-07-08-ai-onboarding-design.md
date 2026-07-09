# AI-Enhanced Onboarding

## Summary

Enhance the existing 5-step onboarding flow with three backend-AI features using the existing `/api/ai-chat` endpoint (Groq, server-side key, Supabase JWT auth). All AI calls are non-blocking and degrade silently on failure.

## Approach

Approach A — independent inline AI calls per step. Each feature fires its own `sendBackendGroqMessage` call. No batching, no streaming, no new backend work.

## Feature 1: Trade-Specific Tips (Step 2)

**Trigger:** User taps a trade chip in the trade grid.

**Prompt:** "Give 2-3 short, practical tips for someone starting a {trade} business using a job management app. Each tip should be one sentence. Focus on how they'll use features like job tracking, invoicing, and estimates in their trade."

**UI:**
- Card area below the trade grid, above the region/rate section.
- Loading state: `ActivityIndicator` + "Getting tips for your trade..." text.
- Success: 2-3 bullet tips in a card styled like the Welcome step's `featureList`.
- Failure: card hidden silently.
- Trade change: previous in-flight call ignored, new call fired.

**Non-blocking:** Continue button stays enabled regardless of loading state.

## Feature 2: AI Rate Suggestion (Step 2)

**New region input:** Free-text field above the existing rate input.
- Label: "Your region"
- Placeholder: "e.g., Dallas, TX"

**Trigger:** On blur of the region field, if region has 2+ characters and a trade is selected.

**Prompt:** "What is a typical hourly labor rate for a {trade} professional in {region}? Reply with ONLY a JSON object: {\"low\": number, \"typical\": number, \"high\": number}. No other text."

**UI:**
- Recommendation card below the rate input.
- Loading: inline spinner + "Checking rates in your area..."
- Success: "Typical rate in {region}: **$XX/hr**" with range note "(Range: $XX - $XX)" and a "Use this rate" button that sets the rate field.
- Failure: card hidden silently. User keeps the $85 default.
- Trade or region change: re-fires the call.

**Parsing:** Extract JSON from response. Regex fallback if Groq wraps in markdown. If both fail, hide card.

**Region persisted:** The region value is saved to settings during `finish()` and available app-wide afterward.

## Feature 3: Personalized Get-Started Actions (Step 4 — Done)

**Trigger:** User arrives at the Done step (step === 4).

**Prompt:** "A {trade} business owner named {firstName} just set up their account in a job management app. Their business is {businessName} in {region}. Suggest 3 specific first actions they should take in the app. Each action should be one short sentence starting with a verb. Reply with ONLY a JSON array of 3 strings."

**UI:**
- Replaces the static `doneBody` text below the notification card.
- Loading: existing static text shown as placeholder.
- Success: numbered list of 3 personalized actions in a card.
- Failure: falls back to the existing static text.

**Existing UI preserved:** "You're all set, {firstName}!" title and notification card are unchanged.

## Data & Settings Changes

**New field:** `region: string` added to:
- `Settings` type in `types/models.ts`
- `defaultSettings()` in `utils/storage/settings.ts`
- `OnboardingForm` interface in `OnboardingScreen.tsx`

**Downstream consumers:**
- `ChatScreen.tsx`: `buildSystemPrompt` injects `settings.region` so the AI coach knows the user's location.
- `SettingsScreen.tsx`: new text field in Business Info section for editing region post-onboarding.

**No SecureStore involvement.** Region is not sensitive — flows through normal AsyncStorage save/sync path.

## New Utility

```ts
// utils/aiService.ts
export async function sendOnboardingAI({ prompt }: { prompt: string }): Promise<string>
```

Thin wrapper around `sendBackendGroqMessage`. Sends one user message with the given prompt. Never throws — catches errors and returns `""`. Call sites check for empty string.

## File Changes

| File | Change |
|---|---|
| `types/models.ts` | Add `region: string` to Settings |
| `utils/storage/settings.ts` | Add `region` to `defaultSettings()` |
| `utils/aiService.ts` | Add `sendOnboardingAI()` helper |
| `screens/OnboardingScreen.tsx` | Add region field, wire up 3 AI calls, tip/rate/action UI cards |
| `screens/ChatScreen.tsx` | Inject `settings.region` into `buildSystemPrompt` |
| `screens/SettingsScreen.tsx` | Add region text field to Business Info section |

## No Changes To

- `backend/api/ai-chat.js` — existing endpoint handles all calls
- Storage sync — region flows through normal settings save/sync
- SecureStore — region is not sensitive

## Error Philosophy

All three AI calls are fire-and-forget enhancements. Every call site degrades silently — no error toasts, no broken UI. The onboarding flow works identically without AI, just less personalized.
