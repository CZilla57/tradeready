# AI-Enhanced Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three backend-AI features to the onboarding flow — trade-specific tips, region-based rate suggestions, and personalized get-started actions — plus persist the user's region in settings.

**Architecture:** Each feature makes an independent one-shot call to the existing `sendBackendGroqMessage` (Vercel → Groq). A new `sendOnboardingAI` wrapper in `utils/aiService.ts` handles the single-message + never-throw contract. The `region` field is added to Settings and saved alongside existing business info.

**Tech Stack:** React Native / Expo, TypeScript, existing Vercel backend (`/api/ai-chat`), Groq llama-3.1-8b-instant

## Global Constraints

- Never throw from `sendOnboardingAI` — catch all errors, return `""`.
- All AI UI is non-blocking — Continue button stays enabled regardless of AI loading state.
- All AI UI degrades silently — on failure, hide the card or show existing static text.
- Follow existing theme/style patterns: `useTheme()`, `useMemo(() => createStyles(...))`, `colors`/`shadow` from theme.
- `region` is NOT sensitive — goes through normal AsyncStorage/sync path, NOT SecureStore.

## File Map

| File | Action | Responsibility |
|---|---|---|
| `types/models.ts` | Modify | Add `region: string` to `Settings` interface |
| `utils/storage/defaults.ts` | Modify | Add `region: ""` to `defaultSettings()` |
| `utils/aiService.ts` | Modify | Add `sendOnboardingAI()` helper |
| `screens/OnboardingScreen.tsx` | Modify | Region input, 3 AI calls, tip/rate/action UI cards |
| `screens/ChatScreen.tsx` | Modify | Inject `settings.region` into `buildSystemPrompt` |
| `screens/SettingsScreen.tsx` | Modify | Add region text field to "Your business" card |

---

### Task 1: Add `region` to Settings type and defaults

**Files:**
- Modify: `types/models.ts:231-271` (Settings interface)
- Modify: `utils/storage/defaults.ts:165-204` (defaultSettings function)

**Interfaces:**
- Produces: `Settings.region: string` — consumed by Tasks 2, 3, 4, 5

- [ ] **Step 1: Add `region` to the Settings interface**

In `types/models.ts`, add `region: string;` after the `address` field (line 237), inside the "Business info" group:

```ts
  address: string;
  region: string;
  trade: TradeId;
```

- [ ] **Step 2: Add `region` to defaultSettings()**

In `utils/storage/defaults.ts`, add `region: "",` after the `address` field (line 172):

```ts
    address: "",
    region: "",
    trade: "plumbing",
```

- [ ] **Step 3: Verify typecheck passes**

Run: `cd tradeready && npx tsc --noEmit 2>&1 | head -20`

Expected: No NEW errors related to `region`. (Existing TS migration errors may appear — ignore those, but confirm no new "Property 'region' does not exist" or similar.)

- [ ] **Step 4: Commit**

```bash
git add types/models.ts utils/storage/defaults.ts
git commit -m "feat(settings): add region field to Settings type and defaults"
```

---

### Task 2: Add `sendOnboardingAI` helper

**Files:**
- Modify: `utils/aiService.ts:104-142` (after `sendClaudeMessage`, before `SendBackendGroqMessageParams`)

**Interfaces:**
- Consumes: `sendBackendGroqMessage` from same file
- Produces: `sendOnboardingAI({ prompt: string }): Promise<string>` — consumed by Task 4 (OnboardingScreen)

- [ ] **Step 1: Add the `sendOnboardingAI` export**

Append this after the existing `sendBackendGroqMessage` function at the end of `utils/aiService.ts`:

```ts
export async function sendOnboardingAI({ prompt }: { prompt: string }): Promise<string> {
  try {
    return await sendBackendGroqMessage({
      messages: [{ role: "user", text: prompt }],
    });
  } catch {
    return "";
  }
}
```

- [ ] **Step 2: Verify typecheck passes**

Run: `cd tradeready && npx tsc --noEmit 2>&1 | grep -i "aiService" | head -10`

Expected: No new errors in aiService.ts.

- [ ] **Step 3: Commit**

```bash
git add utils/aiService.ts
git commit -m "feat(ai): add sendOnboardingAI helper — never-throw one-shot wrapper"
```

---

### Task 3: Add region field to SettingsScreen and ChatScreen

**Files:**
- Modify: `screens/SettingsScreen.tsx:226-244` ("Your business" card section)
- Modify: `screens/ChatScreen.tsx:85-103` (buildSystemPrompt function)

**Interfaces:**
- Consumes: `Settings.region` from Task 1

- [ ] **Step 1: Add region field to SettingsScreen**

In `screens/SettingsScreen.tsx`, add a region `Field` inside the "Your business" card, after the `paymentNotes` field (line 232) and before the trade label (line 233):

```tsx
          <Field label="Payment instructions" value={s.paymentNotes} onChangeText={(v) => update("paymentNotes", v)} multiline autoCapitalize="sentences" colors={colors} shadow={shadow} />
          <Field label="Region" value={s.region || ""} onChangeText={(v) => update("region", v)} placeholder="e.g., Dallas, TX" colors={colors} shadow={shadow} />
          <Text style={[styles.fieldLabel, { marginTop: spacing.sm }]}>Your trade</Text>
```

- [ ] **Step 2: Inject region into ChatScreen's buildSystemPrompt**

In `screens/ChatScreen.tsx`, modify `buildSystemPrompt` (line 88) to include the region when present. Change:

```ts
  let prompt = `Assistant for ${who}. Rates: $${s.laborRate || 85}/hr labor, ${s.materialMarkup || 20}% materials markup, ${s.overheadPercent || 15}% overhead, ${s.marginPercent || 20}% margin, $${s.minimumJobFee || 75} min fee. Be brief. Itemize estimates. USD only.`;
```

to:

```ts
  const regionStr = s.region ? ` Region: ${s.region}.` : "";
  let prompt = `Assistant for ${who}.${regionStr} Rates: $${s.laborRate || 85}/hr labor, ${s.materialMarkup || 20}% materials markup, ${s.overheadPercent || 15}% overhead, ${s.marginPercent || 20}% margin, $${s.minimumJobFee || 75} min fee. Be brief. Itemize estimates. USD only.`;
```

- [ ] **Step 3: Verify typecheck passes**

Run: `cd tradeready && npx tsc --noEmit 2>&1 | grep -E "SettingsScreen|ChatScreen" | head -10`

Expected: No new errors.

- [ ] **Step 4: Commit**

```bash
git add screens/SettingsScreen.tsx screens/ChatScreen.tsx
git commit -m "feat(settings): add region field to SettingsScreen and ChatScreen system prompt"
```

---

### Task 4: Add AI features to OnboardingScreen

**Files:**
- Modify: `screens/OnboardingScreen.tsx` (the full file — form state, StepTrade, StepDone, styles)

**Interfaces:**
- Consumes: `sendOnboardingAI` from Task 2, `Settings.region` from Task 1
- Consumes: `TRADE_TYPES` from `utils/pricingEngine`

This is the largest task. It modifies the `OnboardingScreen` in four sub-steps: form state, StepTrade AI tips, StepTrade region + rate suggestion, and StepDone personalized actions.

- [ ] **Step 1: Add `region` to OnboardingForm and import `sendOnboardingAI`**

In `screens/OnboardingScreen.tsx`:

Add `sendOnboardingAI` to imports at the top. After the existing import of `requestPermissions` (line 20), add:

```ts
import { sendOnboardingAI } from "../utils/aiService";
```

Add `region` to the `OnboardingForm` interface (line 24-31):

```ts
interface OnboardingForm {
  businessName: string;
  contactName: string;
  phone: string;
  email: string;
  trade: TradeId;
  laborRate: string;
  region: string;
  dataChoice: "sample" | "fresh";
}
```

Add `region: ""` to the initial form state (line 48-56):

```ts
  const [form, setForm] = useState<OnboardingForm>({
    businessName: "",
    contactName: "",
    phone: "",
    email: "",
    trade: "plumbing",
    laborRate: "85",
    region: "",
    dataChoice: "sample",
  });
```

Save `region` in the `finish()` function (line 73-89). Add `region: form.region.trim(),` to the settings object:

```ts
  async function finish() {
    setSaving(true);
    await saveSettings({
      ...defaultSettings(),
      businessName: form.businessName.trim(),
      contactName: form.contactName.trim(),
      phone: form.phone,
      email: form.email,
      trade: form.trade,
      laborRate: parseFloat(form.laborRate) || 85,
      region: form.region.trim(),
    });
    if (form.dataChoice === "fresh") {
      await clearSampleData();
    }
    await markOnboardingComplete();
    onComplete();
  }
```

- [ ] **Step 2: Add AI trade tips to StepTrade**

Replace the `StepTrade` component (lines 207-237) with a version that fires an AI call when the trade changes and displays tips:

```tsx
function StepTrade({ form, update }: StepProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const [tips, setTips] = useState<string[]>([]);
  const [tipsLoading, setTipsLoading] = useState(false);
  const tipsTradeRef = useRef<string>("");

  useEffect(() => {
    if (form.trade === tipsTradeRef.current) return;
    tipsTradeRef.current = form.trade;
    setTips([]);
    setTipsLoading(true);
    const tradeLabel = TRADE_TYPES.find(t => t.id === form.trade)?.label || form.trade;
    sendOnboardingAI({
      prompt: `Give 2-3 short, practical tips for someone starting a ${tradeLabel} business using a job management app. Each tip should be one sentence. Focus on how they'll use features like job tracking, invoicing, and estimates in their trade. Reply with ONLY a JSON array of strings.`,
    }).then(raw => {
      if (tipsTradeRef.current !== form.trade) return;
      try {
        const match = raw.match(/\[[\s\S]*\]/);
        if (match) {
          const parsed = JSON.parse(match[0]);
          if (Array.isArray(parsed)) setTips(parsed.map(String).slice(0, 3));
        }
      } catch {}
      setTipsLoading(false);
    });
  }, [form.trade]);

  return (
    <View style={styles.stepContent}>
      <Text style={styles.stepTitle}>Your trade</Text>
      <Text style={styles.stepSubtitle}>Used to tailor job categories and smart pricing defaults.</Text>
      <View style={styles.tradeGrid}>
        {TRADE_TYPES.map(t => (
          <TouchableOpacity
            key={t.id}
            style={[styles.tradeBtn, form.trade === t.id && styles.tradeBtnActive]}
            onPress={() => update("trade", t.id)}
          >
            <Text style={[styles.tradeLabel, form.trade === t.id && styles.tradeLabelActive]}>{t.label}</Text>
          </TouchableOpacity>
        ))}
      </View>

      {(tipsLoading || tips.length > 0) && (
        <View style={styles.aiCard}>
          {tipsLoading ? (
            <View style={styles.aiLoadingRow}>
              <ActivityIndicator size="small" color={colors.accent} />
              <Text style={styles.aiLoadingText}>Getting tips for your trade...</Text>
            </View>
          ) : (
            tips.map((tip, i) => (
              <View key={i} style={styles.tipRow}>
                <Text style={styles.tipBullet}>💡</Text>
                <Text style={styles.tipText}>{tip}</Text>
              </View>
            ))
          )}
        </View>
      )}

      <Text style={[styles.rateLabel, { marginTop: spacing.md }]}>Your region</Text>
      <TextInput
        style={styles.rateInput}
        value={form.region}
        onChangeText={v => update("region", v)}
        placeholder="e.g., Dallas, TX"
        placeholderTextColor={colors.textMuted}
      />
      <Text style={styles.rateNote}>Used to suggest competitive rates for your area.</Text>

      <RateSuggestion form={form} update={update} />
    </View>
  );
}
```

Note: `useRef` and `useEffect` need to be added to the React import at the top of the file (line 1):

```ts
import React, { useState, useRef, useEffect, useMemo } from "react";
```

- [ ] **Step 3: Add the RateSuggestion component**

Add a new `RateSuggestion` component after `StepTrade` and before `StepDataChoice`. This component handles the region input blur → AI rate suggestion flow:

```tsx
function RateSuggestion({ form, update }: StepProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const [suggestion, setSuggestion] = useState<{ low: number; typical: number; high: number } | null>(null);
  const [loading, setLoading] = useState(false);
  const lastQueryRef = useRef("");

  function fetchRate() {
    const region = form.region.trim();
    const queryKey = `${form.trade}|${region}`;
    if (region.length < 2 || queryKey === lastQueryRef.current) return;
    lastQueryRef.current = queryKey;
    setSuggestion(null);
    setLoading(true);
    const tradeLabel = TRADE_TYPES.find(t => t.id === form.trade)?.label || form.trade;
    sendOnboardingAI({
      prompt: `What is a typical hourly labor rate for a ${tradeLabel} professional in ${region}? Reply with ONLY a JSON object: {"low": number, "typical": number, "high": number}. No other text.`,
    }).then(raw => {
      try {
        const match = raw.match(/\{[\s\S]*\}/);
        if (match) {
          const parsed = JSON.parse(match[0]);
          if (typeof parsed.typical === "number") {
            setSuggestion({ low: parsed.low, typical: parsed.typical, high: parsed.high });
          }
        }
      } catch {}
      setLoading(false);
    });
  }

  return (
    <>
      <Text style={[styles.rateLabel, { marginTop: spacing.md }]}>Your hourly labor rate ($)</Text>
      <TextInput
        style={styles.rateInput}
        value={form.laborRate}
        onChangeText={v => update("laborRate", v)}
        keyboardType="decimal-pad"
        placeholder="85"
        placeholderTextColor={colors.textMuted}
        onBlur={fetchRate}
      />
      <Text style={styles.rateNote}>You can adjust this any time in Settings.</Text>

      {loading && (
        <View style={[styles.aiCard, { marginTop: spacing.sm }]}>
          <View style={styles.aiLoadingRow}>
            <ActivityIndicator size="small" color={colors.accent} />
            <Text style={styles.aiLoadingText}>Checking rates in your area...</Text>
          </View>
        </View>
      )}

      {suggestion && !loading && (
        <View style={[styles.aiCard, { marginTop: spacing.sm }]}>
          <Text style={styles.rateSuggestTitle}>
            Typical rate in {form.region.trim()}: ${suggestion.typical}/hr
          </Text>
          <Text style={styles.rateSuggestRange}>
            Range: ${suggestion.low} – ${suggestion.high}
          </Text>
          <TouchableOpacity
            style={styles.useRateBtn}
            onPress={() => update("laborRate", String(suggestion.typical))}
            activeOpacity={0.85}
          >
            <Text style={styles.useRateBtnText}>Use this rate</Text>
          </TouchableOpacity>
        </View>
      )}
    </>
  );
}
```

**Important:** The rate label, rate input, and rate note are now inside `RateSuggestion` instead of `StepTrade`, so remove them from `StepTrade` (they were at lines 225-236 of the original). The region field is in `StepTrade` and the rate field is in `RateSuggestion`. But we also need to trigger the rate fetch when the region field loses focus. Change the region `TextInput` in `StepTrade` to call `fetchRate` on blur — but since `fetchRate` lives in `RateSuggestion`, we instead trigger it by having `RateSuggestion` watch `form.region` via `onBlur` on the rate input. The rate fetch fires when the user focuses the rate input (which naturally happens after typing a region).

Actually, the simpler approach: move the `onBlur` to the region TextInput, but since `RateSuggestion` is a sibling not a parent, we fire the rate fetch inside `RateSuggestion` using a `useEffect` that watches `form.region` with a debounce-on-blur pattern. Instead, let's keep it simple: `RateSuggestion` has a `useEffect` on `[form.trade, form.region]` that fires after a 1-second debounce:

Replace `RateSuggestion`'s `fetchRate`/`onBlur` approach with this `useEffect` at the top of the component:

```tsx
function RateSuggestion({ form, update }: StepProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const [suggestion, setSuggestion] = useState<{ low: number; typical: number; high: number } | null>(null);
  const [loading, setLoading] = useState(false);
  const lastQueryRef = useRef("");

  useEffect(() => {
    const region = form.region.trim();
    if (region.length < 2) return;
    const queryKey = `${form.trade}|${region}`;
    if (queryKey === lastQueryRef.current) return;

    const timeout = setTimeout(() => {
      lastQueryRef.current = queryKey;
      setSuggestion(null);
      setLoading(true);
      const tradeLabel = TRADE_TYPES.find(t => t.id === form.trade)?.label || form.trade;
      sendOnboardingAI({
        prompt: `What is a typical hourly labor rate for a ${tradeLabel} professional in ${region}? Reply with ONLY a JSON object: {"low": number, "typical": number, "high": number}. No other text.`,
      }).then(raw => {
        try {
          const match = raw.match(/\{[\s\S]*\}/);
          if (match) {
            const parsed = JSON.parse(match[0]);
            if (typeof parsed.typical === "number") {
              setSuggestion({ low: parsed.low, typical: parsed.typical, high: parsed.high });
            }
          }
        } catch {}
        setLoading(false);
      });
    }, 1000);

    return () => clearTimeout(timeout);
  }, [form.trade, form.region]);

  return (
    <>
      <Text style={[styles.rateLabel, { marginTop: spacing.md }]}>Your hourly labor rate ($)</Text>
      <TextInput
        style={styles.rateInput}
        value={form.laborRate}
        onChangeText={v => update("laborRate", v)}
        keyboardType="decimal-pad"
        placeholder="85"
        placeholderTextColor={colors.textMuted}
      />
      <Text style={styles.rateNote}>You can adjust this any time in Settings.</Text>

      {loading && (
        <View style={[styles.aiCard, { marginTop: spacing.sm }]}>
          <View style={styles.aiLoadingRow}>
            <ActivityIndicator size="small" color={colors.accent} />
            <Text style={styles.aiLoadingText}>Checking rates in your area...</Text>
          </View>
        </View>
      )}

      {suggestion && !loading && (
        <View style={[styles.aiCard, { marginTop: spacing.sm }]}>
          <Text style={styles.rateSuggestTitle}>
            Typical rate in {form.region.trim()}: ${suggestion.typical}/hr
          </Text>
          <Text style={styles.rateSuggestRange}>
            Range: ${suggestion.low} – ${suggestion.high}
          </Text>
          <TouchableOpacity
            style={styles.useRateBtn}
            onPress={() => update("laborRate", String(suggestion.typical))}
            activeOpacity={0.85}
          >
            <Text style={styles.useRateBtnText}>Use this rate</Text>
          </TouchableOpacity>
        </View>
      )}
    </>
  );
}
```

- [ ] **Step 4: Update StepDone with personalized actions**

Replace the `StepDone` component (lines 282-315) with a version that fetches personalized get-started actions:

```tsx
function StepDone({ form, notifAsked, notifGranted, onRequestNotif }: StepDoneProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const firstName = form.contactName.trim().split(" ")[0] || "there";
  const [actions, setActions] = useState<string[]>([]);
  const fetchedRef = useRef(false);

  useEffect(() => {
    if (fetchedRef.current) return;
    fetchedRef.current = true;
    const tradeLabel = TRADE_TYPES.find(t => t.id === form.trade)?.label || form.trade;
    const regionStr = form.region.trim() ? ` in ${form.region.trim()}` : "";
    sendOnboardingAI({
      prompt: `A ${tradeLabel} business owner named ${firstName} just set up their account in a job management app. Their business is ${form.businessName.trim()}${regionStr}. Suggest 3 specific first actions they should take in the app. Each action should be one short sentence starting with a verb. Reply with ONLY a JSON array of 3 strings.`,
    }).then(raw => {
      try {
        const match = raw.match(/\[[\s\S]*\]/);
        if (match) {
          const parsed = JSON.parse(match[0]);
          if (Array.isArray(parsed)) setActions(parsed.map(String).slice(0, 3));
        }
      } catch {}
    });
  }, []);

  return (
    <View style={styles.doneContent}>
      <Text style={styles.doneEmoji}>✅</Text>
      <Text style={styles.doneTitle}>You're all set, {firstName}!</Text>
      <View style={styles.notifCard}>
        <View style={styles.notifHeader}>
          <Text style={styles.notifIcon}>🔔</Text>
          <View style={styles.notifText}>
            <Text style={styles.notifTitle}>Invoice reminders</Text>
            <Text style={styles.notifDesc}>Get notified when invoices go overdue so nothing slips through the cracks.</Text>
          </View>
        </View>
        {notifAsked ? (
          <View style={styles.notifResult}>
            <Text style={styles.notifResultText}>
              {notifGranted ? "✅ Notifications enabled" : "Notifications off — enable in device Settings any time."}
            </Text>
          </View>
        ) : (
          <TouchableOpacity style={styles.notifBtn} onPress={onRequestNotif} activeOpacity={0.85}>
            <Text style={styles.notifBtnText}>Enable Notifications</Text>
          </TouchableOpacity>
        )}
      </View>
      {actions.length > 0 ? (
        <View style={styles.aiCard}>
          <Text style={styles.actionsTitle}>Your first steps</Text>
          {actions.map((action, i) => (
            <View key={i} style={styles.tipRow}>
              <Text style={styles.tipBullet}>{i + 1}.</Text>
              <Text style={styles.tipText}>{action}</Text>
            </View>
          ))}
        </View>
      ) : (
        <Text style={styles.doneBody}>
          Head to Settings any time to update your pricing defaults, payment processor, or AI assistant keys.
        </Text>
      )}
    </View>
  );
}
```

Note: `StepDone` now uses `form` (for trade, businessName, region), so update the `StepDoneProps` interface to include `form`:

```ts
interface StepDoneProps {
  form: OnboardingForm;
  notifAsked: boolean;
  notifGranted: boolean;
  onRequestNotif: () => void;
}
```

And update the StepDone rendering in the main component (line 121-128) to pass `form`:

```tsx
          {step === 4 && (
            <StepDone
              form={form}
              notifAsked={notifAsked}
              notifGranted={notifGranted}
              onRequestNotif={handleRequestNotif}
            />
          )}
```

This is already passing `form` in the original — but the original `StepDone` only reads `form.contactName`. The new version also reads `form.trade`, `form.businessName`, and `form.region`.

- [ ] **Step 5: Add new styles to `createStyles`**

Add these styles to the `createStyles` function in `OnboardingScreen.tsx`, inside the `StyleSheet.create({...})` call:

```ts
    aiCard: { backgroundColor: colors.surface, borderRadius: radius.lg, padding: spacing.md, marginTop: spacing.md, ...shadow.card },
    aiLoadingRow: { flexDirection: "row", alignItems: "center", gap: spacing.sm },
    aiLoadingText: { fontSize: fontSize.sm, color: colors.textMuted, fontStyle: "italic" },
    tipRow: { flexDirection: "row", gap: spacing.sm, marginTop: spacing.xs },
    tipBullet: { fontSize: fontSize.sm },
    tipText: { flex: 1, fontSize: fontSize.sm, color: colors.textSecondary, lineHeight: 20 },
    rateSuggestTitle: { fontSize: fontSize.md, fontWeight: "600", color: colors.textPrimary },
    rateSuggestRange: { fontSize: fontSize.sm, color: colors.textSecondary, marginTop: 2 },
    useRateBtn: { marginTop: spacing.sm, backgroundColor: colors.accent, borderRadius: radius.md, paddingVertical: 10, alignItems: "center" },
    useRateBtnText: { color: "#fff", fontSize: fontSize.sm, fontWeight: "600" },
    actionsTitle: { fontSize: fontSize.md, fontWeight: "600", color: colors.textPrimary, marginBottom: spacing.sm },
```

- [ ] **Step 6: Verify typecheck passes**

Run: `cd tradeready && npx tsc --noEmit 2>&1 | grep -i "OnboardingScreen" | head -10`

Expected: No new errors in OnboardingScreen.tsx.

- [ ] **Step 7: Commit**

```bash
git add screens/OnboardingScreen.tsx
git commit -m "feat(onboarding): add AI trade tips, region-based rate suggestions, and personalized get-started actions"
```

---

### Task 5: Manual verification

**Files:** None (testing only)

- [ ] **Step 1: Start the dev server**

Run: `cd tradeready && npx expo start`

- [ ] **Step 2: Walk through the onboarding flow**

Test the full flow on a device/simulator:

1. Sign in → lands on onboarding
2. Step 0 (Welcome): unchanged, tap "Let's get started"
3. Step 1 (Business): enter name + business name, tap "Continue"
4. Step 2 (Trade):
   - Select a trade → tips card appears with loading then 2-3 tips
   - Switch trade → old tips disappear, new ones load
   - Type a region (e.g., "Houston, TX")
   - Wait ~1s → rate suggestion card appears with typical rate and range
   - Tap "Use this rate" → labor rate field updates
   - Tap "Continue"
5. Step 3 (Data choice): unchanged
6. Step 4 (Done):
   - Personalized actions card appears with 3 items
   - Notification card still works
   - Tap "Start using TradeReady"
7. Verify region is saved: go to Settings → "Your business" → region field shows the value entered during onboarding

- [ ] **Step 3: Test failure cases**

1. Disconnect from the internet or block the backend URL
2. Walk through onboarding again
3. Verify: no error toasts, no broken UI, tips/rate/actions cards simply don't appear
4. Continue button always works regardless

- [ ] **Step 4: Test ChatScreen region injection**

1. Open the AI Chat tab
2. Ask "Where am I based?"
3. Verify the AI knows your region (it's in the system prompt now)
