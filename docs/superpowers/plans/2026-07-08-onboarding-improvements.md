# Onboarding Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enhance the 5-step onboarding wizard with address/logo fields, email pre-fill, input validation, AI retry, tappable progress dots, a Stripe nudge card, and trade-matched sample invoices.

**Architecture:** All UI changes in `OnboardingScreen.tsx`. Foundation changes span `types/models.ts`, `utils/storage/defaults.ts`, `components/Field.tsx`, and `utils/storage/index.ts`. No new screens, routes, or dependencies.

**Tech Stack:** React Native, Expo (expo-image-picker already installed), TypeScript interfaces, AsyncStorage

## Global Constraints

- All validation is soft (warnings only) — never block "Continue"
- Logo is optional — no gate on it
- No new npm dependencies
- Follow existing patterns: `useTheme()` + `useMemo(() => createStyles(...))` for styles, `sendOnboardingAI` for AI calls
- `colors.warning` (`#ff9500` light / `#ff9f0a` dark) for all warning text

---

### Task 1: Foundation — Types, Defaults, BaseField onBlur

**Files:**
- Modify: `types/models.ts:263-304` — add `logoPhoto` to `Settings`
- Modify: `utils/storage/defaults.ts:116-163` — add trade param + `SAMPLE_INVOICE_DESCS`; add `logoPhoto` to `defaultSettings()`
- Modify: `utils/storage/index.ts:19` — export `defaultInvoices`
- Modify: `components/Field.tsx:30-82` — add `onBlur` prop

**Interfaces:**
- Consumes: existing `Settings` interface, existing `defaultInvoices()`, existing `BaseField`
- Produces: `Settings.logoPhoto?: string`, `defaultInvoices(trade?: TradeId): Invoice[]`, `SAMPLE_INVOICE_DESCS` constant, `BaseField` with `onBlur` support

- [ ] **Step 1: Add `logoPhoto` to the `Settings` interface**

In `types/models.ts`, add after line 270 (`region?: string;`):

```typescript
  logoPhoto?: string;
```

- [ ] **Step 2: Add `logoPhoto` default and trade-matched invoices to defaults.ts**

In `utils/storage/defaults.ts`, add the import for `TradeId` at the top:

```typescript
import type { Invoice, Job, Customer, Settings, TradeId } from "../../types/models";
```

Add `logoPhoto: ""` to `defaultSettings()` after the `region: ""` line (around line 174):

```typescript
    logoPhoto: "",
```

Add the `SAMPLE_INVOICE_DESCS` constant before `defaultInvoices()` (before line 116):

```typescript
const SAMPLE_INVOICE_DESCS: Record<TradeId, string[]> = {
  plumbing: ["Kitchen faucet replacement", "Emergency pipe repair", "Water heater flush", "Bathroom remodel — rough-in"],
  electrical: ["Panel upgrade — 200A", "Recessed lighting install", "Outlet and switch replacement", "EV charger installation"],
  hvac: ["AC unit service call", "Furnace replacement", "Ductwork repair", "Thermostat installation"],
  carpenter: ["Custom shelving build", "Deck repair and staining", "Door frame replacement", "Cabinet installation"],
  bricklayer: ["Garden wall construction", "Chimney repointing", "Patio brickwork", "Foundation repair"],
  plasterer: ["Living room skim coat", "Ceiling repair", "Full room replaster", "Decorative cornice work"],
  landscaping: ["Spring cleanup and mulching", "Patio paver installation", "Weekly mowing contract — Q2", "Tree trimming and removal"],
  cleaning: ["Deep clean — 3BR house", "Post-construction cleanup", "Office weekly service", "Move-out clean"],
  painting: ["Interior 2-room repaint", "Exterior house painting", "Cabinet refinishing", "Deck staining"],
  handyman: ["Fence repair", "Drywall patch and paint", "Ceiling fan installation", "Gutter cleaning"],
  other: ["Service call", "Project estimate", "Maintenance visit", "Repair work"],
};
```

Change the `defaultInvoices()` signature and use the map:

```typescript
export function defaultInvoices(trade?: TradeId): Invoice[] {
  const descs = SAMPLE_INVOICE_DESCS[trade || "other"];
  return [
    {
      id: "1",
      customer: "Riverside Bakery",
      number: "INV-0038",
      amount: 2400,
      due: "2026-05-10",
      email: "owner@riversidebakery.com",
      phone: "(555) 301-2200",
      desc: descs[0],
      paid: false,
    },
    {
      id: "2",
      customer: "Green Thumb Landscaping",
      number: "INV-0041",
      amount: 875,
      due: "2026-06-01",
      email: "billing@greenthumbla.com",
      phone: "(555) 874-9900",
      desc: descs[1],
      paid: false,
    },
    {
      id: "3",
      customer: "Patel Family Dental",
      number: "INV-0043",
      amount: 5100,
      due: "2026-06-15",
      email: "admin@pateldental.com",
      phone: "(555) 440-1133",
      desc: descs[2],
      paid: false,
    },
    {
      id: "4",
      customer: "Blue Ridge Coffee Co.",
      number: "INV-0039",
      amount: 650,
      due: "2026-05-20",
      email: "mgr@blueridgecoffee.com",
      phone: "(555) 920-5544",
      desc: descs[3],
      paid: true,
    },
  ];
}
```

- [ ] **Step 3: Export `defaultInvoices` from the storage barrel**

In `utils/storage/index.ts`, change line 19:

```typescript
export { defaultSettings, defaultInvoices } from "./defaults";
```

- [ ] **Step 4: Add `onBlur` support to BaseField**

In `components/Field.tsx`, add `onBlur` to the `FieldProps` type (after `autoFocus?: boolean;`):

```typescript
  onBlur?: () => void;
```

Add `onBlur` to the destructured props in the function signature:

```typescript
export default function Field({
  label,
  value,
  onChangeText,
  placeholder,
  keyboardType,
  autoCapitalize,
  multiline,
  autoFocus,
  onBlur,
  flex,
  containerStyle,
  labelStyle,
  inputStyle,
}: FieldProps) {
```

Pass `onBlur` to the `TextInput`:

```typescript
      <TextInput
        style={[styles.input, multiline && styles.inputMulti, inputStyle]}
        value={value}
        onChangeText={onChangeText}
        onBlur={onBlur}
        placeholder={placeholder}
        placeholderTextColor={colors.textMuted}
        keyboardType={keyboardType || "default"}
        autoCapitalize={cap}
        autoCorrect={false}
        multiline={multiline}
        numberOfLines={multiline ? 3 : 1}
        autoFocus={autoFocus}
      />
```

- [ ] **Step 5: Verify nothing is broken**

Run: `npx jest --passWithNoTests 2>&1 | tail -5`
Expected: All existing tests pass.

- [ ] **Step 6: Commit**

```bash
git add types/models.ts utils/storage/defaults.ts utils/storage/index.ts components/Field.tsx
git commit -m "feat(onboarding): add logoPhoto to Settings, trade-matched invoice defaults, onBlur to BaseField

Foundation for onboarding improvements: Settings gains logoPhoto field,
defaultInvoices() accepts a trade parameter for trade-specific sample
invoice descriptions, and BaseField now forwards onBlur to TextInput.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 2: Step 1 — Pre-fill Email, Address Field, Logo Picker

**Files:**
- Modify: `screens/OnboardingScreen.tsx:1-22` — add imports
- Modify: `screens/OnboardingScreen.tsx:25-34` — add `address` and `logoUri` to form
- Modify: `screens/OnboardingScreen.tsx:43-59` — add `useAuth`, pre-fill email
- Modify: `screens/OnboardingScreen.tsx:76-93` — save address + logoPhoto in `finish()`
- Modify: `screens/OnboardingScreen.tsx:196-209` — rewrite `StepBusiness` with address + logo
- Modify: `screens/OnboardingScreen.tsx:505-580` — add new styles

**Interfaces:**
- Consumes: `useAuth()` from `../context/AuthContext`, `persistPhoto`/`deletePhoto` from `../utils/photoStorage`, `ImagePicker` from `expo-image-picker`, `Alert`/`Image` from `react-native`
- Produces: `StepBusiness` with address field and logo picker, `finish()` that saves `address` and `logoPhoto`

- [ ] **Step 1: Add new imports**

At the top of `OnboardingScreen.tsx`, add to the `react-native` import:

```typescript
import {
  View,
  Text,
  TextInput,
  TouchableOpacity,
  ScrollView,
  StyleSheet,
  KeyboardAvoidingView,
  Platform,
  ActivityIndicator,
  Alert,
  Image,
} from "react-native";
```

Add new imports after line 21:

```typescript
import { useAuth } from "../context/AuthContext";
import * as ImagePicker from "expo-image-picker";
import { persistPhoto, deletePhoto } from "../utils/photoStorage";
```

- [ ] **Step 2: Add `address` and `logoUri` to form state**

Update `OnboardingForm` interface:

```typescript
interface OnboardingForm {
  businessName: string;
  contactName: string;
  phone: string;
  email: string;
  address: string;
  trade: TradeId;
  laborRate: string;
  region: string;
  dataChoice: "sample" | "fresh";
}
```

Update the initial state in `OnboardingScreen`:

```typescript
  const [form, setForm] = useState<OnboardingForm>({
    businessName: "",
    contactName: "",
    phone: "",
    email: "",
    address: "",
    trade: "plumbing",
    laborRate: "85",
    region: "",
    dataChoice: "sample",
  });
  const [logoUri, setLogoUri] = useState<string | null>(null);
```

- [ ] **Step 3: Pre-fill email from auth session**

Inside `OnboardingScreen`, after the `logoUri` state, add `useAuth` and a pre-fill effect:

```typescript
  const { session } = useAuth();

  useEffect(() => {
    if (session?.user?.email && !form.email) {
      update("email", session.user.email);
    }
  }, []);
```

- [ ] **Step 4: Add logo picker handler**

Add this function inside `OnboardingScreen`, after `handleRequestNotif`:

```typescript
  function handlePickLogo() {
    Alert.alert("Add your logo", "", [
      {
        text: "Take Photo",
        onPress: async () => {
          const { status } = await ImagePicker.requestCameraPermissionsAsync();
          if (status !== "granted") {
            Alert.alert("Permission needed", "Camera access is required to take a photo.");
            return;
          }
          const result = await ImagePicker.launchCameraAsync({ mediaTypes: ["images"] as any, quality: 0.8 });
          if (!result.canceled) {
            const uri = await persistPhoto(result.assets[0].uri, "logos");
            setLogoUri(uri);
          }
        },
      },
      {
        text: "Choose from Library",
        onPress: async () => {
          const { status } = await ImagePicker.requestMediaLibraryPermissionsAsync();
          if (status !== "granted") {
            Alert.alert("Permission needed", "Photo library access is required.");
            return;
          }
          const result = await ImagePicker.launchImageLibraryAsync({ mediaTypes: ["images"] as any, quality: 0.8 });
          if (!result.canceled) {
            const uri = await persistPhoto(result.assets[0].uri, "logos");
            setLogoUri(uri);
          }
        },
      },
      { text: "Cancel", style: "cancel" },
    ]);
  }

  async function handleRemoveLogo() {
    if (logoUri) {
      await deletePhoto(logoUri);
      setLogoUri(null);
    }
  }
```

- [ ] **Step 5: Update `finish()` to save address and logoPhoto**

In `finish()`, update the `saveSettings` call to include `address` and `logoPhoto`:

```typescript
  async function finish() {
    setSaving(true);
    await saveSettings({
      ...defaultSettings(),
      businessName: form.businessName.trim(),
      contactName: form.contactName.trim(),
      phone: form.phone,
      email: form.email,
      address: form.address.trim(),
      trade: form.trade,
      laborRate: parseFloat(form.laborRate) || 85,
      region: form.region.trim(),
      logoPhoto: logoUri || "",
    });
    if (form.dataChoice === "fresh") {
      await clearSampleData();
    }
    await markOnboardingComplete();
    onComplete();
  }
```

- [ ] **Step 6: Pass logoUri and handlers to StepBusiness**

Update the `StepBusiness` rendering in the return JSX:

```typescript
          {step === 1 && (
            <StepBusiness
              form={form}
              update={update}
              logoUri={logoUri}
              onPickLogo={handlePickLogo}
              onRemoveLogo={handleRemoveLogo}
            />
          )}
```

- [ ] **Step 7: Rewrite StepBusiness with address field and logo picker**

Replace the `StepBusiness` function:

```typescript
interface StepBusinessProps extends StepProps {
  logoUri: string | null;
  onPickLogo: () => void;
  onRemoveLogo: () => void;
}

function StepBusiness({ form, update, logoUri, onPickLogo, onRemoveLogo }: StepBusinessProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  return (
    <View style={styles.stepContent}>
      <Text style={styles.stepTitle}>Your business</Text>
      <Text style={styles.stepSubtitle}>This appears on your invoices and estimates.</Text>
      <Field label="Business name *" value={form.businessName} onChangeText={v => update("businessName", v)} placeholder="ABC Plumbing LLC" />
      <Field label="Your name *" value={form.contactName} onChangeText={v => update("contactName", v)} placeholder="John Smith" />
      <Field label="Phone" value={form.phone} onChangeText={v => update("phone", formatPhone(v))} placeholder="(555) 000-0000" keyboardType="phone-pad" />
      <Field label="Email" value={form.email} onChangeText={v => update("email", v)} placeholder="you@example.com" keyboardType="email-address" autoCapitalize="none" />
      <Field label="Business address" value={form.address} onChangeText={v => update("address", v)} placeholder="123 Main St, City, State ZIP" multiline />

      <Text style={styles.logoLabel}>Your logo</Text>
      <Text style={styles.logoHint}>Optional — appears on invoices and estimates.</Text>
      <TouchableOpacity style={styles.logoPicker} onPress={onPickLogo} activeOpacity={0.7}>
        {logoUri ? (
          <Image source={{ uri: logoUri }} style={styles.logoImage} />
        ) : (
          <View style={styles.logoPlaceholder}>
            <Text style={styles.logoPlaceholderIcon}>📷</Text>
            <Text style={styles.logoPlaceholderText}>Add logo</Text>
          </View>
        )}
      </TouchableOpacity>
      {logoUri && (
        <TouchableOpacity onPress={onRemoveLogo} style={styles.logoRemoveBtn}>
          <Text style={styles.logoRemoveText}>Remove</Text>
        </TouchableOpacity>
      )}
    </View>
  );
}
```

- [ ] **Step 8: Add logo styles to createStyles**

Add these styles inside `createStyles`, after `actionsTitle`:

```typescript
    logoLabel: { fontSize: fontSize.sm, fontWeight: "600", color: colors.textSecondary, marginBottom: spacing.xs },
    logoHint: { fontSize: fontSize.xs, color: colors.textMuted, marginBottom: spacing.sm },
    logoPicker: { alignSelf: "flex-start", marginBottom: spacing.xs },
    logoImage: { width: 80, height: 80, borderRadius: 40, backgroundColor: colors.surface },
    logoPlaceholder: { width: 80, height: 80, borderRadius: 40, backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border, borderStyle: "dashed", alignItems: "center", justifyContent: "center" },
    logoPlaceholderIcon: { fontSize: 24, marginBottom: 2 },
    logoPlaceholderText: { fontSize: fontSize.xs, color: colors.textMuted },
    logoRemoveBtn: { alignSelf: "flex-start", marginTop: 4 },
    logoRemoveText: { fontSize: fontSize.xs, color: colors.danger },
```

- [ ] **Step 9: Remove the old `StepProps`-only StepBusiness interface usage**

Delete the old standalone `StepBusiness` function definition (the one with `StepProps` signature). The new `StepBusinessProps extends StepProps` version replaces it. Keep the `StepProps` interface — it is still used by `StepTrade`, `StepDataChoice`, and `RateSuggestion`.

- [ ] **Step 10: Commit**

```bash
git add screens/OnboardingScreen.tsx
git commit -m "feat(onboarding): add email pre-fill, address field, logo picker to Step 1

Pre-fills email from auth session, adds business address as a multiline
field, and adds an optional logo picker using expo-image-picker (same
pattern as job photos). Logo persisted via photoStorage utility.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 3: AI Retry on Failure

**Files:**
- Modify: `screens/OnboardingScreen.tsx` — `StepTrade` (tips retry), `RateSuggestion` (rate retry), `StepDone` (actions retry), `createStyles` (retry styles)

**Interfaces:**
- Consumes: `sendOnboardingAI`, existing tip/rate/action loading state
- Produces: visible retry UI for all three AI features

- [ ] **Step 1: Add retry styles to createStyles**

Add these styles inside `createStyles`, after the logo styles:

```typescript
    retryRow: { flexDirection: "row", alignItems: "center", gap: spacing.sm },
    retryText: { fontSize: fontSize.sm, color: colors.textMuted },
    retryBtn: { paddingVertical: 2, paddingHorizontal: 4 },
    retryBtnText: { fontSize: fontSize.sm, color: colors.accent, fontWeight: "600" },
```

- [ ] **Step 2: Add retry to trade tips in StepTrade**

In `StepTrade`, add a `tipsError` state:

```typescript
  const [tipsError, setTipsError] = useState(false);
```

Update the `useEffect` to detect failures. Replace the `.then(raw => { ... })` block:

```typescript
    sendOnboardingAI({
      prompt: `Give 2-3 short, practical tips for someone starting a ${tradeLabel} business using a job management app. Each tip should be one sentence. Focus on how they'll use features like job tracking, invoicing, and estimates in their trade. Reply with ONLY a JSON array of strings.`,
    }).then(raw => {
      if (tipsTradeRef.current !== form.trade) return;
      let parsed: string[] = [];
      try {
        const match = raw.match(/\[[\s\S]*\]/);
        if (match) {
          const arr = JSON.parse(match[0]);
          if (Array.isArray(arr)) parsed = arr.map(String).slice(0, 3);
        }
      } catch {}
      if (parsed.length > 0) {
        setTips(parsed);
        setTipsError(false);
      } else {
        setTipsError(true);
      }
      setTipsLoading(false);
    });
```

Add a `tipsRetryCount` state (the effect depends on `[form.trade]` and uses `tipsTradeRef` to skip when already fetched — a retry counter in the dependency array forces re-entry):

```typescript
  const [tipsRetryCount, setTipsRetryCount] = useState(0);
```

Update the effect dependency array:

```typescript
  }, [form.trade, tipsRetryCount]);
```

Add a retry handler:

```typescript
  function retryTips() {
    tipsTradeRef.current = "";
    setTipsError(false);
    setTips([]);
    setTipsRetryCount(c => c + 1);
  }
```

Update the render block. Replace the condition `{(tipsLoading || tips.length > 0) && (` with:

```typescript
      {(tipsLoading || tips.length > 0 || tipsError) && (
        <View style={styles.aiCard}>
          {tipsLoading ? (
            <View style={styles.aiLoadingRow}>
              <ActivityIndicator size="small" color={colors.accent} />
              <Text style={styles.aiLoadingText}>Getting tips for your trade...</Text>
            </View>
          ) : tipsError ? (
            <View style={styles.retryRow}>
              <Text style={styles.retryText}>Couldn't load tips</Text>
              <TouchableOpacity style={styles.retryBtn} onPress={retryTips}>
                <Text style={styles.retryBtnText}>Retry</Text>
              </TouchableOpacity>
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
```

- [ ] **Step 3: Add retry to RateSuggestion**

In `RateSuggestion`, add states:

```typescript
  const [rateError, setRateError] = useState(false);
  const [rateRetryCount, setRateRetryCount] = useState(0);
```

Update the effect's `.then` block to detect failure:

```typescript
      sendOnboardingAI({
        prompt: `What is a typical hourly labor rate for a ${tradeLabel} professional in ${region}? Reply with ONLY a JSON object: {"low": number, "typical": number, "high": number}. No other text.`,
      }).then(raw => {
        let parsed = null;
        try {
          const match = raw.match(/\{[\s\S]*\}/);
          if (match) {
            const obj = JSON.parse(match[0]);
            if (typeof obj.low === "number" && typeof obj.typical === "number" && typeof obj.high === "number") {
              parsed = { low: obj.low, typical: obj.typical, high: obj.high };
            }
          }
        } catch {}
        if (parsed) {
          setSuggestion(parsed);
          setRateError(false);
        } else {
          setRateError(true);
        }
        setLoading(false);
      });
```

Add `rateRetryCount` to the effect dependency array:

```typescript
  }, [form.trade, form.region, rateRetryCount]);
```

Add a retry handler:

```typescript
  function retryRate() {
    lastQueryRef.current = "";
    setRateError(false);
    setSuggestion(null);
    setRateRetryCount(c => c + 1);
  }
```

Add the retry UI after the loading block and before the suggestion block:

```typescript
      {rateError && !loading && (
        <View style={[styles.aiCard, { marginTop: spacing.sm }]}>
          <View style={styles.retryRow}>
            <Text style={styles.retryText}>Couldn't check rates</Text>
            <TouchableOpacity style={styles.retryBtn} onPress={retryRate}>
              <Text style={styles.retryBtnText}>Retry</Text>
            </TouchableOpacity>
          </View>
        </View>
      )}
```

- [ ] **Step 4: Add retry to StepDone first-steps**

In `StepDone`, add states:

```typescript
  const [actionsError, setActionsError] = useState(false);
  const [actionsRetryCount, setActionsRetryCount] = useState(0);
```

Update the effect. Replace the `.then` block:

```typescript
    sendOnboardingAI({
      prompt: `You are helping ${firstName}, who runs a ${tradeLabel} business called ${form.businessName.trim()}${regionStr}. They just finished setting up their account in a job management app. Write 3 specific first actions for them, addressed directly as "you". Each action should be one short sentence starting with a verb (e.g. "Add your first customer…"). Reply with ONLY a JSON array of 3 strings.`,
    }).then(raw => {
      let parsed: string[] = [];
      try {
        const match = raw.match(/\[[\s\S]*\]/);
        if (match) {
          const arr = JSON.parse(match[0]);
          if (Array.isArray(arr)) parsed = arr.map(String).slice(0, 3);
        }
      } catch {}
      if (parsed.length > 0) {
        setActions(parsed);
        setActionsError(false);
      } else {
        setActionsError(true);
      }
    });
```

Update the effect dependency array:

```typescript
  }, [firstName, form.businessName, form.region, form.trade, actionsRetryCount]);
```

Add a retry handler:

```typescript
  function retryActions() {
    fetchedRef.current = false;
    setActionsError(false);
    setActions([]);
    setActionsRetryCount(c => c + 1);
  }
```

Update the render block. Replace the `{actions.length > 0 ? (` conditional:

```typescript
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
      ) : actionsError ? (
        <View style={styles.aiCard}>
          <View style={styles.retryRow}>
            <Text style={styles.retryText}>Couldn't load suggestions</Text>
            <TouchableOpacity style={styles.retryBtn} onPress={retryActions}>
              <Text style={styles.retryBtnText}>Retry</Text>
            </TouchableOpacity>
          </View>
        </View>
      ) : (
        <Text style={styles.doneBody}>
          Head to Settings any time to update your pricing defaults, payment processor, or AI assistant keys.
        </Text>
      )}
```

- [ ] **Step 5: Commit**

```bash
git add screens/OnboardingScreen.tsx
git commit -m "feat(onboarding): add retry UI for all three AI features

Trade tips, rate suggestions, and first-steps actions now show a
'Couldn't load / Retry' row instead of silently vanishing on failure.
Uses a retryCount state to re-trigger each effect.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 4: Soft Input Validation Warnings

**Files:**
- Modify: `screens/OnboardingScreen.tsx` — add `touched` state, `markTouched` callback, warning rendering in `StepBusiness` and `RateSuggestion`, warning styles

**Interfaces:**
- Consumes: `BaseField` with `onBlur` (from Task 1), `colors.warning` from theme
- Produces: yellow warning text below email/phone/rate fields when values look wrong

- [ ] **Step 1: Add `touched` state and `markTouched` to OnboardingScreen**

In the parent `OnboardingScreen` function, after the `logoUri` state:

```typescript
  const [touched, setTouched] = useState<Record<string, boolean>>({});
  function markTouched(field: string) {
    setTouched(prev => ({ ...prev, [field]: true }));
  }
```

- [ ] **Step 2: Pass `touched` and `markTouched` to StepBusiness**

Update the `StepBusiness` rendering:

```typescript
          {step === 1 && (
            <StepBusiness
              form={form}
              update={update}
              logoUri={logoUri}
              onPickLogo={handlePickLogo}
              onRemoveLogo={handleRemoveLogo}
              touched={touched}
              markTouched={markTouched}
            />
          )}
```

Update `StepBusinessProps`:

```typescript
interface StepBusinessProps extends StepProps {
  logoUri: string | null;
  onPickLogo: () => void;
  onRemoveLogo: () => void;
  touched: Record<string, boolean>;
  markTouched: (field: string) => void;
}
```

Update the destructuring:

```typescript
function StepBusiness({ form, update, logoUri, onPickLogo, onRemoveLogo, touched, markTouched }: StepBusinessProps) {
```

- [ ] **Step 3: Add onBlur and warning text to email and phone fields in StepBusiness**

Replace the Phone and Email `Field` calls:

```typescript
      <Field label="Phone" value={form.phone} onChangeText={v => update("phone", formatPhone(v))} placeholder="(555) 000-0000" keyboardType="phone-pad" onBlur={() => markTouched("phone")} />
      {touched.phone && form.phone.length > 0 && form.phone.replace(/\D/g, "").length < 10 && (
        <Text style={styles.warningText}>Phone number looks incomplete.</Text>
      )}
      <Field label="Email" value={form.email} onChangeText={v => update("email", v)} placeholder="you@example.com" keyboardType="email-address" autoCapitalize="none" onBlur={() => markTouched("email")} />
      {touched.email && form.email.length > 0 && !/^\S+@\S+\.\S+$/.test(form.email) && (
        <Text style={styles.warningText}>This doesn't look like a valid email address.</Text>
      )}
```

- [ ] **Step 4: Pass `touched` and `markTouched` through StepTrade to RateSuggestion**

Update the `StepTrade` rendering in `OnboardingScreen`:

```typescript
          {step === 2 && <StepTrade form={form} update={update} touched={touched} markTouched={markTouched} />}
```

Update `StepTrade` to accept and forward validation props. Change the function signature (it currently uses `StepProps`) — either extend it inline or add a new interface:

```typescript
function StepTrade({ form, update, touched, markTouched }: StepProps & { touched: Record<string, boolean>; markTouched: (field: string) => void }) {
```

Pass them to `RateSuggestion`:

```typescript
      <RateSuggestion form={form} update={update} touched={touched} markTouched={markTouched} />
```

- [ ] **Step 5: Add rate warning to RateSuggestion**

Update `RateSuggestion` signature:

```typescript
function RateSuggestion({ form, update, touched, markTouched }: StepProps & { touched: Record<string, boolean>; markTouched: (field: string) => void }) {
```

Add `onBlur` to the rate `TextInput`:

```typescript
      <TextInput
        style={styles.rateInput}
        value={form.laborRate}
        onChangeText={v => update("laborRate", v)}
        onBlur={() => markTouched("laborRate")}
        keyboardType="decimal-pad"
        placeholder="85"
        placeholderTextColor={colors.textMuted}
      />
```

Add the warning text after the `rateNote`:

```typescript
      <Text style={styles.rateNote}>You can adjust this any time in Settings.</Text>
      {touched.laborRate && (isNaN(parseFloat(form.laborRate)) || parseFloat(form.laborRate) < 10 || parseFloat(form.laborRate) > 500) && (
        <Text style={styles.warningText}>This rate seems unusual — double-check before continuing.</Text>
      )}
```

- [ ] **Step 6: Add warning styles**

Add to `createStyles`:

```typescript
    warningText: { fontSize: fontSize.xs, color: colors.warning, marginTop: 2, marginBottom: spacing.xs },
```

- [ ] **Step 7: Commit**

```bash
git add screens/OnboardingScreen.tsx
git commit -m "feat(onboarding): add soft validation warnings for email, phone, rate

Non-blocking yellow warnings appear below fields after blur when values
look invalid (bad email format, <10 digit phone, rate outside $10-$500).
Warnings never block Continue.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 5: Tappable Progress Dots

**Files:**
- Modify: `screens/OnboardingScreen.tsx` — dots section in `OnboardingScreen` return JSX, `canNavigateTo` function, dot styles

**Interfaces:**
- Consumes: existing `step`, `setStep`, `form` state
- Produces: tappable dots that allow step-jumping with Step 1 validation gate

- [ ] **Step 1: Add `canNavigateTo` function**

In `OnboardingScreen`, after the `canContinue` function:

```typescript
  function canNavigateTo(target: number): boolean {
    if (target === step) return false;
    if (target <= step) return true;
    if (target >= 2) return form.businessName.trim().length > 0 && form.contactName.trim().length > 0;
    return true;
  }
```

- [ ] **Step 2: Replace dots View with TouchableOpacity**

Replace the dots block:

```typescript
      <View style={styles.dots}>
        {Array.from({ length: STEPS }).map((_, i) => (
          <TouchableOpacity
            key={i}
            onPress={() => canNavigateTo(i) && setStep(i)}
            activeOpacity={0.7}
            style={styles.dotTouchable}
          >
            <View style={[styles.dot, i <= step && styles.dotActive]} />
          </TouchableOpacity>
        ))}
      </View>
```

- [ ] **Step 3: Add `dotTouchable` style**

Add to `createStyles`:

```typescript
    dotTouchable: { padding: 4 },
```

- [ ] **Step 4: Commit**

```bash
git add screens/OnboardingScreen.tsx
git commit -m "feat(onboarding): make progress dots tappable for step-jumping

Dots are now TouchableOpacity with a 4px padding hit target. Forward
jumps past Step 1 are gated on business name + contact name being filled.
Backward jumps always allowed.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 6: Stripe Card + Trade-Matched Invoices in finish()

**Files:**
- Modify: `screens/OnboardingScreen.tsx:19` — add `saveInvoices`, `defaultInvoices` to imports
- Modify: `screens/OnboardingScreen.tsx` — `finish()` to save trade-matched invoices
- Modify: `screens/OnboardingScreen.tsx` — `StepDone` to include Stripe info card
- Modify: `screens/OnboardingScreen.tsx` — add `stripeCard*` styles

**Interfaces:**
- Consumes: `saveInvoices` from `../utils/storage`, `defaultInvoices` from `../utils/storage`
- Produces: trade-matched sample invoices persisted on finish; Stripe info card on Done screen

- [ ] **Step 1: Update imports**

Update the storage import line:

```typescript
import { saveSettings, saveInvoices, defaultSettings, defaultInvoices, markOnboardingComplete, clearSampleData } from "../utils/storage";
```

- [ ] **Step 2: Update `finish()` to save trade-matched invoices**

Replace the `finish()` function:

```typescript
  async function finish() {
    setSaving(true);
    await saveSettings({
      ...defaultSettings(),
      businessName: form.businessName.trim(),
      contactName: form.contactName.trim(),
      phone: form.phone,
      email: form.email,
      address: form.address.trim(),
      trade: form.trade,
      laborRate: parseFloat(form.laborRate) || 85,
      region: form.region.trim(),
      logoPhoto: logoUri || "",
    });
    if (form.dataChoice === "fresh") {
      await clearSampleData();
    } else {
      await saveInvoices(defaultInvoices(form.trade));
    }
    await markOnboardingComplete();
    onComplete();
  }
```

- [ ] **Step 3: Add Stripe info card to StepDone**

In the `StepDone` return JSX, add this block between the `notifCard` closing `</View>` and the `{actions.length > 0 ? (` conditional:

```typescript
      <View style={styles.stripeInfoCard}>
        <View style={styles.notifHeader}>
          <Text style={styles.notifIcon}>💳</Text>
          <View style={styles.notifText}>
            <Text style={styles.notifTitle}>Accept payments</Text>
            <Text style={styles.notifDesc}>Connect your Stripe account in Settings → Payment Processor to send payment links with your invoices.</Text>
          </View>
        </View>
      </View>
```

- [ ] **Step 4: Add `stripeInfoCard` style**

Add to `createStyles`:

```typescript
    stripeInfoCard: { width: "100%", backgroundColor: colors.surface, borderRadius: radius.lg, padding: spacing.md, marginBottom: spacing.lg, ...shadow.card },
```

- [ ] **Step 5: Commit**

```bash
git add screens/OnboardingScreen.tsx
git commit -m "feat(onboarding): add Stripe nudge card, save trade-matched sample invoices

Done screen now shows an informational card directing users to Settings
for Stripe Connect setup. finish() saves sample invoices with trade-
appropriate descriptions (e.g. plumbing jobs for plumbers, not
'Lawn care contract').

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 7: Manual Verification

**Files:** None (read-only)

**Interfaces:**
- Consumes: all prior tasks
- Produces: verified working onboarding flow

- [ ] **Step 1: Start the dev server**

Run: `npx expo start`

- [ ] **Step 2: Walk through onboarding as a new user**

Test each improvement:
1. **Email pre-fill** — After signing in, check that email field on Step 1 is pre-populated
2. **Address field** — Enter a business address, verify it's a multiline field
3. **Logo picker** — Tap the logo area, pick a photo, verify it shows in the circle, tap Remove
4. **Soft validation** — Enter a bad email (e.g., "foo"), leave the field, verify yellow warning. Enter 5 digits for phone, leave, verify warning. Enter $0 for rate, leave, verify warning. Verify "Continue" is still tappable
5. **Tappable dots** — On Step 0, try tapping dot 3 (should be blocked since Step 1 not filled). Fill Step 1, advance to Step 2, tap dot 1 to go back, then tap dot 3 to jump forward
6. **AI retry** — Disconnect network, navigate to Step 2, wait for tips to fail, verify "Couldn't load tips / Retry" shows. Reconnect, tap Retry, verify tips load
7. **Stripe card** — On Step 4 (Done), verify the payment info card with 💳 icon is present between notifications and first-steps
8. **Trade-matched invoices** — Select "Electrical" as trade, choose "Show me around", finish onboarding. Navigate to Invoices tab and verify descriptions say things like "Panel upgrade — 200A" not "Lawn care contract"

- [ ] **Step 3: Run tests**

Run: `npx jest --passWithNoTests 2>&1 | tail -10`
Expected: All existing tests pass.
