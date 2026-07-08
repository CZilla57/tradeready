# Mileage Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an odometer-based mileage deduction log (from-job → to-job legs) under the Money tab that shows a configurable IRS-rate tax deduction total.

**Architecture:** A new local-only `Trip` collection modeled on `recurringJobs` (AsyncStorage, cleared on sign-out, NOT wired into the Supabase sync engine). Pure deduction math lives in a new `utils/mileageUtils.ts` (unit-tested). UI is a Money-tab card → a full log screen → an add/edit trip screen, plus one new Settings field for the per-mile rate.

**Tech Stack:** Expo 54 / React Native 0.81 / React 19 / TypeScript, React Navigation native-stack, AsyncStorage, Jest (jest-expo).

## Global Constraints

- **Never commit on a red gate.** Every task ends with `npm run typecheck` (0 errors), `npm test` (all pass), and `npm run lint` (0 warnings) all green before `git commit`. (Owner non-negotiable — tradeready-change-control.)
- **No dependency or Expo SDK changes.** This feature adds zero packages. (Owner non-negotiable.)
- **All new source is `.ts` / `.tsx`.** The repo is post-TypeScript-migration.
- **Do not touch** `travelFeePerMile` / `travelMiles` (customer travel fee — a different concept) or the `fuel` expense category. Mileage must NOT auto-post to expenses.
- **Do not wire `trips` into `COLLECTION_TABLES`** or create a Supabase table. Local-only by design.
- **Read the per-mile rate defensively everywhere** as `settings.mileageRate ?? DEFAULT_MILEAGE_RATE` — `loadSettings` returns stored settings without merging defaults, so pre-existing users won't have the field.
- Commit trailer on every commit: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Run all commands from `C:\Users\Chadr\OneDrive\Documents\TraderPro App\tradeready\`.

---

## File Structure

**Create:**
- `utils/mileageUtils.ts` — pure math + constants (miles, summary, formatting, id, `HOME_LABEL`, `DEFAULT_MILEAGE_RATE`).
- `utils/storage/trips.ts` — `loadTrips` / `saveTrips` (local-only).
- `__tests__/mileageUtils.test.js` — regression suite for the math.
- `screens/MileageLogScreen.tsx` — period-filtered log + summary.
- `screens/AddTripScreen.tsx` — add/edit a trip.
- `components/money/MileageCard.tsx` — Money-tab summary card.

**Modify:**
- `types/models.ts` — add `Trip` interface; add `mileageRate` to `Settings`.
- `utils/storage/keys.ts` — add `trips` key.
- `utils/storage/index.ts` — re-export `loadTrips` / `saveTrips`.
- `utils/storage/defaults.ts` — add `mileageRate` to `defaultSettings`.
- `utils/sync.ts` — add `'trips'` to the sign-out `multiRemove` list (~line 211).
- `screens/MoneyScreen.tsx` — accept `navigation`, render `<MileageCard>`.
- `screens/SettingsScreen.tsx` — add the "Mileage rate" field.
- `App.tsx` — register `MileageLog` + `AddTrip` in `MoneyStack`.

---

## Task 1: Data shapes — `Trip` type + `mileageRate` setting

**Files:**
- Modify: `types/models.ts`
- Modify: `utils/storage/defaults.ts:165-197`

**Interfaces:**
- Produces: `Trip` interface and `Settings.mileageRate: number`, consumed by every later task.

- [ ] **Step 1: Add the `Trip` interface to `types/models.ts`**

Insert after the `Expense` / `ExpenseDraft` block (after line 169):

```ts
/**
 * A logged business drive for mileage tax deduction. LOCAL-ONLY (like
 * RecurringJob): stored in AsyncStorage, cleared on sign-out, NOT synced to
 * Supabase. Either endpoint may be a linked job (fromJobId/toJobId set) or
 * "Home / Shop" (null). Labels are denormalized for display, matching the
 * Job.customerName pattern.
 */
export interface Trip {
  id: string;
  date: DateString;              // "YYYY-MM-DD"
  odometerStart: number;
  odometerEnd: number;
  miles: number;                 // derived + stored: max(0, end - start)
  fromJobId: string | null;      // null = "Home / Shop"
  fromLabel: string;
  toJobId: string | null;        // null = "Home / Shop"
  toLabel: string;
  purpose: string;
  createdAt: DateString;
}
```

- [ ] **Step 2: Add `mileageRate` to the `Settings` interface**

In `types/models.ts`, inside `interface Settings`, in the "Pricing defaults" group, add after `emergencyMultiplier: number;` (line 226):

```ts
  /** $ per mile for the mileage tax-deduction estimate (Money → Mileage). */
  mileageRate: number;
```

- [ ] **Step 3: Add the default to `defaultSettings`**

In `utils/storage/defaults.ts`, in the "Pricing defaults" block, add after the `emergencyMultiplier: 1.5,` line (line 182):

```ts
    mileageRate: 0.70,      // $ per mile — IRS standard mileage rate; user sets per tax year
```

- [ ] **Step 4: Verify the gate is green**

Run: `npm run typecheck && npm test && npm run lint`
Expected: typecheck 0 errors, tests pass, lint 0 warnings.

- [ ] **Step 5: Commit**

```bash
git add types/models.ts utils/storage/defaults.ts
git commit -m "$(cat <<'EOF'
feat: add Trip type and mileageRate setting

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Mileage math + tests (`utils/mileageUtils.ts`)

**Files:**
- Create: `utils/mileageUtils.ts`
- Test: `__tests__/mileageUtils.test.js`

**Interfaces:**
- Consumes: `Trip` from Task 1.
- Produces:
  - `DEFAULT_MILEAGE_RATE: number` (= 0.70)
  - `HOME_LABEL: string` (= "Home / Shop")
  - `computeTripMiles(start: number, end: number): number`
  - `mileageSummary(trips: Trip[], start: Date, end: Date, rate: number): { tripCount: number; totalMiles: number; deduction: number }`
  - `formatMiles(miles: number): string`
  - `generateTripId(): string`

- [ ] **Step 1: Write the failing test**

Create `__tests__/mileageUtils.test.js`:

```js
const {
  computeTripMiles,
  mileageSummary,
  formatMiles,
  DEFAULT_MILEAGE_RATE,
} = require('../utils/mileageUtils');

const trip = (over) => ({
  id: 'x', date: '2026-03-10', odometerStart: 0, odometerEnd: 0, miles: 0,
  fromJobId: null, fromLabel: 'Home / Shop', toJobId: null, toLabel: 'Home / Shop',
  purpose: '', createdAt: '2026-03-10', ...over,
});

describe('computeTripMiles', () => {
  test('end minus start', () => expect(computeTripMiles(45210, 45240)).toBe(30));
  test('end < start clamps to 0', () => expect(computeTripMiles(45240, 45210)).toBe(0));
  test('equal readings = 0', () => expect(computeTripMiles(100, 100)).toBe(0));
});

describe('mileageSummary', () => {
  const start = new Date(2026, 0, 1);
  const end = new Date(2026, 11, 31, 23, 59, 59);
  const trips = [
    trip({ date: '2026-03-10', miles: 20 }),
    trip({ date: '2026-06-01', miles: 30 }),
    trip({ date: '2025-12-31', miles: 99 }), // out of range
  ];
  test('sums in-range miles and applies rate', () => {
    const s = mileageSummary(trips, start, end, 0.70);
    expect(s.tripCount).toBe(2);
    expect(s.totalMiles).toBe(50);
    expect(s.deduction).toBeCloseTo(35, 2);
  });
  test('default rate constant is a number', () => {
    expect(typeof DEFAULT_MILEAGE_RATE).toBe('number');
  });
});

describe('formatMiles', () => {
  test('one decimal + suffix', () => expect(formatMiles(12)).toBe('12.0 mi'));
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm test -- mileageUtils`
Expected: FAIL — "Cannot find module '../utils/mileageUtils'".

- [ ] **Step 3: Write the implementation**

Create `utils/mileageUtils.ts`:

```ts
// utils/mileageUtils.ts
// Pure math + constants for the mileage tax-deduction log. No I/O, no React —
// mirrors the formula-utility style of pricingEngine / invoiceStats so it is
// unit-testable in isolation.

import type { Trip } from '../types/models';

/** IRS standard mileage rate default ($/mile). User overrides per tax year in Settings. */
export const DEFAULT_MILEAGE_RATE = 0.70;

/** Label used when a trip endpoint is the user's base rather than a job. */
export const HOME_LABEL = 'Home / Shop';

export interface MileageSummary {
  tripCount: number;
  totalMiles: number;
  deduction: number;
}

/** Miles for one trip: end − start, never negative, rounded to 0.1. */
export function computeTripMiles(start: number, end: number): number {
  const raw = (Number(end) || 0) - (Number(start) || 0);
  return Math.round(Math.max(0, raw) * 10) / 10;
}

/** Total miles + dollar deduction for trips whose date falls within [start, end]. */
export function mileageSummary(
  trips: Trip[],
  start: Date,
  end: Date,
  rate: number,
): MileageSummary {
  const inRange = trips.filter((t) => {
    const d = new Date(t.date);
    return d >= start && d <= end;
  });
  const totalMiles =
    Math.round(inRange.reduce((sum, t) => sum + (Number(t.miles) || 0), 0) * 10) / 10;
  const deduction = Math.round(totalMiles * (Number(rate) || 0) * 100) / 100;
  return { tripCount: inRange.length, totalMiles, deduction };
}

/** Display miles as "12.0 mi". */
export function formatMiles(miles: number): string {
  return `${(Number(miles) || 0).toFixed(1)} mi`;
}

/** Collision-resistant local id, matching generateExpenseId's style. */
export function generateTripId(): string {
  return Date.now().toString() + Math.random().toString(36).slice(2, 7);
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npm test -- mileageUtils`
Expected: PASS (all describe blocks green).

- [ ] **Step 5: Verify the full gate**

Run: `npm run typecheck && npm run lint`
Expected: 0 errors, 0 warnings.

- [ ] **Step 6: Commit**

```bash
git add utils/mileageUtils.ts __tests__/mileageUtils.test.js
git commit -m "$(cat <<'EOF'
feat: add mileageUtils deduction math with tests

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Local-only storage (`utils/storage/trips.ts`)

**Files:**
- Create: `utils/storage/trips.ts`
- Modify: `utils/storage/keys.ts:6-14`
- Modify: `utils/storage/index.ts:20`
- Modify: `utils/sync.ts` (~line 211)

**Interfaces:**
- Consumes: `Trip` (Task 1), `KEYS` from `./keys`.
- Produces: `loadTrips(): Promise<Trip[]>`, `saveTrips(trips: Trip[]): Promise<void>` — consumed by Tasks 4–6.

- [ ] **Step 1: Add the storage key**

In `utils/storage/keys.ts`, add to the `KEYS` object after `recurringJobs: "recurringJobs",`:

```ts
  trips: "trips",
```

- [ ] **Step 2: Create the storage module**

Create `utils/storage/trips.ts` (modeled exactly on `recurringJobs.ts` — no `enqueueCollectionChanges`, no `trySync`, so it stays local-only):

```ts
import AsyncStorage from "@react-native-async-storage/async-storage";
import { KEYS } from "./keys";
import type { Trip } from "../../types/models";

export async function loadTrips(): Promise<Trip[]> {
  try {
    const raw = await AsyncStorage.getItem(KEYS.trips);
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

export async function saveTrips(trips: Trip[]): Promise<void> {
  await AsyncStorage.setItem(KEYS.trips, JSON.stringify(trips));
}
```

- [ ] **Step 3: Re-export from the storage barrel**

In `utils/storage/index.ts`, after the `loadRecurringJobs, saveRecurringJobs` line (line 20):

```ts
export { loadTrips, saveTrips } from "./trips";
```

- [ ] **Step 4: Clear trips on sign-out**

In `utils/sync.ts` (~line 211), extend the sign-out purge list to include `'trips'`:

```ts
        await AsyncStorage.multiRemove([...COLLECTION_TABLES, 'customerNotes', 'recurringJobs', 'trips']);
```

- [ ] **Step 5: Verify the gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: 0 errors, tests pass, 0 warnings.

- [ ] **Step 6: Commit**

```bash
git add utils/storage/trips.ts utils/storage/keys.ts utils/storage/index.ts utils/sync.ts
git commit -m "$(cat <<'EOF'
feat: add local-only trips storage collection

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Add/Edit Trip screen (`screens/AddTripScreen.tsx`)

**Files:**
- Create: `screens/AddTripScreen.tsx`

**Interfaces:**
- Consumes: `loadTrips` / `saveTrips` (Task 3), `loadJobs` (existing `utils/storage`), `computeTripMiles` / `formatMiles` / `generateTripId` / `HOME_LABEL` (Task 2), `Trip` / `Job` types.
- Produces: a screen registered as `"AddTrip"` in Task 6; reads optional `route.params.tripId` for edit mode.

- [ ] **Step 1: Create the screen**

Create `screens/AddTripScreen.tsx`:

```tsx
import React, { useState, useEffect, useMemo, useLayoutEffect } from 'react';
import { View, Text, TextInput, TouchableOpacity, ScrollView, StyleSheet, Alert } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { spacing, radius, fontSize } from '../utils/theme';
import type { ColorScheme, ShadowScheme } from '../utils/theme';
import { useTheme } from '../hooks/useTheme';
import { loadJobs, loadTrips, saveTrips } from '../utils/storage';
import { computeTripMiles, formatMiles, generateTripId, HOME_LABEL } from '../utils/mileageUtils';
import type { Job, Trip } from '../types/models';

interface Endpoint { jobId: string | null; label: string; }

export default function AddTripScreen({ navigation, route }: any) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const editingId: string | undefined = route.params?.tripId;

  const [jobs, setJobs] = useState<Job[]>([]);
  const [date, setDate] = useState<string>(new Date().toISOString().slice(0, 10));
  const [from, setFrom] = useState<Endpoint>({ jobId: null, label: HOME_LABEL });
  const [to, setTo] = useState<Endpoint>({ jobId: null, label: HOME_LABEL });
  const [odoStart, setOdoStart] = useState<string>('');
  const [odoEnd, setOdoEnd] = useState<string>('');
  const [purpose, setPurpose] = useState<string>('');

  useEffect(() => {
    loadJobs().then(setJobs);
    if (editingId) {
      loadTrips().then((trips) => {
        const t = trips.find((x) => x.id === editingId);
        if (!t) return;
        setDate(t.date);
        setFrom({ jobId: t.fromJobId, label: t.fromLabel });
        setTo({ jobId: t.toJobId, label: t.toLabel });
        setOdoStart(String(t.odometerStart || ''));
        setOdoEnd(String(t.odometerEnd || ''));
        setPurpose(t.purpose || '');
      });
    }
  }, [editingId]);

  useLayoutEffect(() => {
    navigation.setOptions({ title: editingId ? 'Edit Trip' : 'Add Trip' });
  }, [navigation, editingId]);

  const startNum = parseFloat(odoStart) || 0;
  const endNum = parseFloat(odoEnd) || 0;
  const miles = computeTripMiles(startNum, endNum);
  const invalid = odoEnd !== '' && endNum < startNum;

  const renderEndpoints = (current: Endpoint, setter: (e: Endpoint) => void) => (
    <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.chipRow}>
      <TouchableOpacity
        style={[styles.chip, current.jobId === null && styles.chipActive]}
        onPress={() => setter({ jobId: null, label: HOME_LABEL })}
      >
        <Text style={[styles.chipText, current.jobId === null && styles.chipTextActive]}>{HOME_LABEL}</Text>
      </TouchableOpacity>
      {jobs.map((j) => {
        const label = j.customerName || j.title || 'Job';
        return (
          <TouchableOpacity
            key={j.id}
            style={[styles.chip, current.jobId === j.id && styles.chipActive]}
            onPress={() => setter({ jobId: j.id, label })}
          >
            <Text style={[styles.chipText, current.jobId === j.id && styles.chipTextActive]} numberOfLines={1}>
              {label}
            </Text>
          </TouchableOpacity>
        );
      })}
    </ScrollView>
  );

  const handleSave = async () => {
    if (!odoStart || !odoEnd) {
      Alert.alert('Missing readings', 'Enter both start and end odometer readings.');
      return;
    }
    if (invalid) {
      Alert.alert('Check readings', 'End reading must be greater than or equal to the start reading.');
      return;
    }
    const trips = await loadTrips();
    const existing = editingId ? trips.find((t) => t.id === editingId) : undefined;
    const record: Trip = {
      id: editingId || generateTripId(),
      date,
      odometerStart: startNum,
      odometerEnd: endNum,
      miles,
      fromJobId: from.jobId,
      fromLabel: from.label,
      toJobId: to.jobId,
      toLabel: to.label,
      purpose: purpose.trim(),
      createdAt: existing?.createdAt || new Date().toISOString(),
    };
    const next = editingId ? trips.map((t) => (t.id === editingId ? record : t)) : [record, ...trips];
    await saveTrips(next);
    navigation.goBack();
  };

  const handleDelete = () => {
    Alert.alert('Delete trip', 'Remove this trip from your mileage log?', [
      { text: 'Cancel', style: 'cancel' },
      {
        text: 'Delete',
        style: 'destructive',
        onPress: async () => {
          const trips = await loadTrips();
          await saveTrips(trips.filter((t) => t.id !== editingId));
          navigation.goBack();
        },
      },
    ]);
  };

  return (
    <SafeAreaView style={styles.container} edges={['bottom']}>
      <ScrollView contentContainerStyle={styles.content}>
        <Text style={styles.label}>Date</Text>
        <TextInput style={styles.input} value={date} onChangeText={setDate} placeholder="YYYY-MM-DD" placeholderTextColor={colors.textMuted} />

        <Text style={styles.label}>From</Text>
        {renderEndpoints(from, setFrom)}

        <Text style={styles.label}>To</Text>
        {renderEndpoints(to, setTo)}

        <Text style={styles.label}>Odometer start</Text>
        <TextInput style={styles.input} value={odoStart} onChangeText={setOdoStart} keyboardType="decimal-pad" placeholder="e.g. 45210" placeholderTextColor={colors.textMuted} />

        <Text style={styles.label}>Odometer end</Text>
        <TextInput style={styles.input} value={odoEnd} onChangeText={setOdoEnd} keyboardType="decimal-pad" placeholder="e.g. 45240" placeholderTextColor={colors.textMuted} />

        <Text style={[styles.milesPreview, invalid && styles.milesInvalid]}>
          {invalid ? 'End reading is less than start' : `Trip distance: ${formatMiles(miles)}`}
        </Text>

        <Text style={styles.label}>Purpose (optional)</Text>
        <TextInput style={[styles.input, styles.multiline]} value={purpose} onChangeText={setPurpose} placeholder="e.g. Drive to job site" placeholderTextColor={colors.textMuted} multiline />

        <TouchableOpacity style={styles.saveBtn} onPress={handleSave} activeOpacity={0.85}>
          <Text style={styles.saveBtnText}>{editingId ? 'Save Changes' : 'Add Trip'}</Text>
        </TouchableOpacity>

        {editingId && (
          <TouchableOpacity style={styles.deleteBtn} onPress={handleDelete} activeOpacity={0.85}>
            <Text style={styles.deleteBtnText}>Delete Trip</Text>
          </TouchableOpacity>
        )}
        <View style={{ height: 60 }} />
      </ScrollView>
    </SafeAreaView>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    content: { padding: spacing.lg },
    label: { color: colors.textSecondary, fontSize: fontSize.sm, fontWeight: '600', marginBottom: spacing.xs, marginTop: spacing.md },
    input: {
      backgroundColor: colors.surface,
      borderWidth: 1,
      borderColor: colors.border,
      borderRadius: radius.md,
      paddingHorizontal: spacing.md,
      paddingVertical: spacing.sm,
      color: colors.textPrimary,
      fontSize: fontSize.md,
    },
    multiline: { minHeight: 70, textAlignVertical: 'top' },
    chipRow: { gap: spacing.sm, paddingVertical: spacing.xs },
    chip: {
      paddingHorizontal: 14,
      paddingVertical: 8,
      borderRadius: radius.full,
      backgroundColor: colors.surface,
      borderWidth: 1,
      borderColor: colors.border,
      maxWidth: 180,
    },
    chipActive: { backgroundColor: colors.accentBg, borderColor: colors.accent },
    chipText: { color: colors.textSecondary, fontSize: fontSize.sm, fontWeight: '500' },
    chipTextActive: { color: colors.accent, fontWeight: '600' },
    milesPreview: { color: colors.textPrimary, fontSize: fontSize.md, fontWeight: '600', marginTop: spacing.md },
    milesInvalid: { color: colors.danger },
    saveBtn: { backgroundColor: colors.accent, borderRadius: radius.md, paddingVertical: 14, alignItems: 'center', marginTop: spacing.xl },
    saveBtnText: { color: '#fff', fontSize: fontSize.md, fontWeight: '700' },
    deleteBtn: { borderRadius: radius.md, paddingVertical: 14, alignItems: 'center', marginTop: spacing.md },
    deleteBtnText: { color: colors.danger, fontSize: fontSize.md, fontWeight: '600' },
  });
}
```

- [ ] **Step 2: Verify the gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: 0 errors, tests pass, 0 warnings. (Screen is not yet reachable — that's fine; it's wired in Task 6.)

- [ ] **Step 3: Commit**

```bash
git add screens/AddTripScreen.tsx
git commit -m "$(cat <<'EOF'
feat: add AddTrip screen for logging mileage

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Mileage log screen + Money-tab card

**Files:**
- Create: `screens/MileageLogScreen.tsx`
- Create: `components/money/MileageCard.tsx`

**Interfaces:**
- Consumes: `loadTrips` / `loadSettings` (storage), `mileageSummary` / `formatMiles` / `DEFAULT_MILEAGE_RATE` (Task 2), `getDateRange` / `DATE_FILTERS` (moneyUtils), `formatMoney` (format).
- Produces: `MileageLogScreen` (registered `"MileageLog"` in Task 6) and `MileageCard` (`{ start: Date; end: Date; onPress: () => void }`, consumed by Task 6's MoneyScreen edit).

- [ ] **Step 1: Create `components/money/MileageCard.tsx`**

```tsx
import React, { useState, useCallback, useMemo } from 'react';
import { View, Text, TouchableOpacity, StyleSheet } from 'react-native';
import { useFocusEffect } from '@react-navigation/native';
import { spacing, radius, fontSize } from '../../utils/theme';
import type { ColorScheme, ShadowScheme } from '../../utils/theme';
import { useTheme } from '../../hooks/useTheme';
import { formatMoney } from '../../utils/format';
import { loadTrips, loadSettings } from '../../utils/storage';
import { mileageSummary, formatMiles, DEFAULT_MILEAGE_RATE } from '../../utils/mileageUtils';
import type { Trip } from '../../types/models';

interface Props { start: Date; end: Date; onPress: () => void; }

export function MileageCard({ start, end, onPress }: Props) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const [trips, setTrips] = useState<Trip[]>([]);
  const [rate, setRate] = useState<number>(DEFAULT_MILEAGE_RATE);

  useFocusEffect(
    useCallback(() => {
      loadTrips().then(setTrips);
      loadSettings().then((s) => setRate(s.mileageRate ?? DEFAULT_MILEAGE_RATE));
    }, []),
  );

  const summary = mileageSummary(trips, start, end, rate);

  return (
    <TouchableOpacity style={styles.card} onPress={onPress} activeOpacity={0.85}>
      <View style={styles.headerRow}>
        <Text style={styles.title}>🚗 Mileage deduction</Text>
        <Text style={styles.chevron}>›</Text>
      </View>
      <Text style={styles.amount}>{formatMoney(summary.deduction)}</Text>
      <Text style={styles.sub}>
        {formatMiles(summary.totalMiles)} · {summary.tripCount} trip{summary.tripCount === 1 ? '' : 's'} · {formatMoney(rate)}/mi
      </Text>
    </TouchableOpacity>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    card: {
      marginHorizontal: spacing.lg,
      marginBottom: spacing.md,
      backgroundColor: colors.surface,
      borderRadius: radius.lg,
      padding: spacing.lg,
      borderWidth: 1,
      borderColor: colors.border,
      ...shadow.card,
    },
    headerRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
    title: { color: colors.textPrimary, fontSize: fontSize.md + 1, fontWeight: '600' },
    chevron: { color: colors.textMuted, fontSize: fontSize.lg + 4, fontWeight: '400' },
    amount: { color: colors.accent, fontSize: fontSize.xl, fontWeight: '700', marginTop: spacing.sm },
    sub: { color: colors.textSecondary, fontSize: fontSize.sm, marginTop: spacing.xs },
  });
}
```

- [ ] **Step 2: Create `screens/MileageLogScreen.tsx`**

```tsx
import React, { useState, useMemo, useCallback } from 'react';
import { View, Text, FlatList, TouchableOpacity, ScrollView, StyleSheet } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useFocusEffect } from '@react-navigation/native';
import { spacing, radius, fontSize } from '../utils/theme';
import type { ColorScheme, ShadowScheme } from '../utils/theme';
import { useTheme } from '../hooks/useTheme';
import { DATE_FILTERS, getDateRange } from '../utils/moneyUtils';
import { formatMoney } from '../utils/format';
import { loadTrips, loadSettings } from '../utils/storage';
import { mileageSummary, formatMiles, DEFAULT_MILEAGE_RATE } from '../utils/mileageUtils';
import type { Trip } from '../types/models';

export default function MileageLogScreen({ navigation }: any) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const [trips, setTrips] = useState<Trip[]>([]);
  const [rate, setRate] = useState<number>(DEFAULT_MILEAGE_RATE);
  const [activeFilter, setActiveFilter] = useState<string>('this_year');

  useFocusEffect(
    useCallback(() => {
      loadTrips().then(setTrips);
      loadSettings().then((s) => setRate(s.mileageRate ?? DEFAULT_MILEAGE_RATE));
    }, []),
  );

  const { start, end } = getDateRange(activeFilter);
  const summary = mileageSummary(trips, start, end, rate);
  const inRange = useMemo(
    () =>
      trips
        .filter((t) => { const d = new Date(t.date); return d >= start && d <= end; })
        .sort((a, b) => (a.date < b.date ? 1 : -1)),
    [trips, start, end],
  );

  return (
    <SafeAreaView style={styles.container} edges={['bottom']}>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} style={styles.filterScroll} contentContainerStyle={styles.filterScrollContent}>
        {DATE_FILTERS.map((f) => (
          <TouchableOpacity
            key={f.id}
            style={[styles.filterChip, activeFilter === f.id && styles.filterChipActive]}
            onPress={() => setActiveFilter(f.id)}
          >
            <Text style={[styles.filterChipText, activeFilter === f.id && styles.filterChipTextActive]}>{f.label}</Text>
          </TouchableOpacity>
        ))}
      </ScrollView>

      <View style={styles.summaryCard}>
        <Text style={styles.summaryLabel}>Estimated deduction</Text>
        <Text style={styles.summaryAmount}>{formatMoney(summary.deduction)}</Text>
        <Text style={styles.summarySub}>
          {formatMiles(summary.totalMiles)} · {summary.tripCount} trip{summary.tripCount === 1 ? '' : 's'} · {formatMoney(rate)}/mi
        </Text>
      </View>

      <FlatList
        data={inRange}
        keyExtractor={(item) => item.id}
        renderItem={({ item }) => (
          <TouchableOpacity style={styles.row} onPress={() => navigation.navigate('AddTrip', { tripId: item.id })} activeOpacity={0.7}>
            <View style={{ flex: 1 }}>
              <Text style={styles.rowRoute} numberOfLines={1}>{item.fromLabel} → {item.toLabel}</Text>
              <Text style={styles.rowMeta}>{item.date}{item.purpose ? ` · ${item.purpose}` : ''}</Text>
            </View>
            <Text style={styles.rowMiles}>{formatMiles(item.miles)}</Text>
          </TouchableOpacity>
        )}
        contentContainerStyle={styles.list}
        ListEmptyComponent={
          <View style={styles.empty}>
            <Text style={styles.emptyIcon}>🚗</Text>
            <Text style={styles.emptyTitle}>No trips logged</Text>
            <Text style={styles.emptyBody}>Tap "+ Add trip" to log your first business drive for this period.</Text>
          </View>
        }
        ListFooterComponent={<View style={{ height: 100 }} />}
      />

      <TouchableOpacity style={styles.addBtn} onPress={() => navigation.navigate('AddTrip')} activeOpacity={0.85}>
        <Text style={styles.addBtnText}>+ Add trip</Text>
      </TouchableOpacity>
    </SafeAreaView>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    filterScroll: { paddingLeft: spacing.lg, marginTop: spacing.md, marginBottom: spacing.sm, maxHeight: 44 },
    filterScrollContent: { paddingRight: spacing.lg, gap: spacing.sm, alignItems: 'flex-start' as const },
    filterChip: { paddingHorizontal: 14, paddingVertical: 7, borderRadius: radius.full, backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border, marginRight: spacing.sm },
    filterChipActive: { backgroundColor: colors.accentBg, borderColor: colors.accent },
    filterChipText: { color: colors.textSecondary, fontSize: fontSize.sm, fontWeight: '500' },
    filterChipTextActive: { color: colors.accent, fontWeight: '600' },
    summaryCard: { marginHorizontal: spacing.lg, marginBottom: spacing.md, backgroundColor: colors.surface, borderRadius: radius.lg, padding: spacing.lg, borderWidth: 1, borderColor: colors.border, ...shadow.card },
    summaryLabel: { color: colors.textSecondary, fontSize: fontSize.sm, fontWeight: '600' },
    summaryAmount: { color: colors.accent, fontSize: fontSize.xxl, fontWeight: '800', marginTop: spacing.xs },
    summarySub: { color: colors.textSecondary, fontSize: fontSize.sm, marginTop: spacing.xs },
    list: { paddingHorizontal: spacing.lg },
    row: { flexDirection: 'row', alignItems: 'center', backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, marginBottom: spacing.sm },
    rowRoute: { color: colors.textPrimary, fontSize: fontSize.md, fontWeight: '600' },
    rowMeta: { color: colors.textSecondary, fontSize: fontSize.sm, marginTop: 2 },
    rowMiles: { color: colors.textPrimary, fontSize: fontSize.md, fontWeight: '700', marginLeft: spacing.md },
    empty: { alignItems: 'center', paddingVertical: 60, paddingHorizontal: 40 },
    emptyIcon: { fontSize: 48, marginBottom: spacing.md },
    emptyTitle: { color: colors.textPrimary, fontSize: fontSize.lg, fontWeight: '600', marginBottom: spacing.sm },
    emptyBody: { color: colors.textSecondary, fontSize: fontSize.sm, textAlign: 'center', lineHeight: 20 },
    addBtn: { position: 'absolute', bottom: spacing.xl, alignSelf: 'center', backgroundColor: colors.accent, borderRadius: radius.full, paddingVertical: 14, paddingHorizontal: 28, ...shadow.card },
    addBtnText: { color: '#fff', fontSize: fontSize.md, fontWeight: '700' },
  });
}
```

> **Note:** if `fontSize.xxl` does not exist in `utils/theme`, use `fontSize.xl` instead — check the exported `fontSize` object before running.

- [ ] **Step 3: Verify the gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: 0 errors, tests pass, 0 warnings.

- [ ] **Step 4: Commit**

```bash
git add screens/MileageLogScreen.tsx components/money/MileageCard.tsx
git commit -m "$(cat <<'EOF'
feat: add mileage log screen and Money-tab card

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Wire navigation, Money screen, and Settings

**Files:**
- Modify: `App.tsx:30-33,152-157`
- Modify: `screens/MoneyScreen.tsx:72,185`
- Modify: `screens/SettingsScreen.tsx:257-259`

**Interfaces:**
- Consumes: `AddTripScreen`, `MileageLogScreen` (Tasks 4–5), `MileageCard` (Task 5), `mileageRate` setting (Task 1).
- Produces: the fully reachable feature.

- [ ] **Step 1: Import the new screens in `App.tsx`**

After the `RecurringJobsScreen` import (line 33):

```tsx
import MileageLogScreen           from "./screens/MileageLogScreen";
import AddTripScreen              from "./screens/AddTripScreen";
```

- [ ] **Step 2: Register them in `MoneyStack`**

Replace the `MoneyStack.Navigator` body (lines 153–155) so it reads:

```tsx
    <MoneyStack.Navigator screenOptions={navOpts}>
      <MoneyStack.Screen name="MoneyHome"   component={MoneyScreen}       options={{ title: "Money" }} />
      <MoneyStack.Screen name="MileageLog"  component={MileageLogScreen}  options={{ title: "Mileage" }} />
      <MoneyStack.Screen name="AddTrip"     component={AddTripScreen}     options={{ presentation: "modal" }} />
    </MoneyStack.Navigator>
```

- [ ] **Step 3: Render the card in `MoneyScreen.tsx`**

Change the function signature (line 72):

```tsx
export default function MoneyScreen({ navigation }: any) {
```

Add the import near the other money-component imports (after line 26, the `TopCustomersCard` import):

```tsx
import { MileageCard }       from '../components/money/MileageCard';
```

In the Overview tab, add the card right after `<ReceivablesCard ... />` (line 185):

```tsx
          <MileageCard start={start} end={end} onPress={() => navigation.navigate('MileageLog')} />
```

- [ ] **Step 4: Add the Settings field**

In `screens/SettingsScreen.tsx`, immediately before the `<Divider />` that follows the Pricing-defaults card (line 259), insert:

```tsx
        <Divider />

        <SectionHeader title="Mileage deduction" />
        <Text style={styles.ruleSubtitle}>
          Used to estimate your tax deduction from logged trips (Money → Mileage). Set this to the standard mileage rate for your tax year.
        </Text>
        <View style={styles.card}>
          <Field label="Mileage rate ($ per mile)" value={String(s.mileageRate ?? 0.70)} onChangeText={(v) => update("mileageRate", parseFloat(v) || 0)} keyboardType="decimal-pad" colors={colors} shadow={shadow} />
        </View>
```

- [ ] **Step 5: Verify the gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: 0 errors, tests pass, 0 warnings.

- [ ] **Step 6: Verify in the running app**

Run the app (`npx expo start`) and confirm:
- Money tab shows the "Mileage deduction" card ($0.00 initially).
- Tapping it opens the Mileage log; "+ Add trip" opens the form.
- Logging a trip (From Home/Shop → a job, odometer 45210 → 45240) shows "30.0 mi" preview, saves, and the deduction updates (30 × rate).
- Settings shows the "Mileage rate" field defaulting to 0.70; editing it changes the deduction total.
- End < start shows the inline "End reading is less than start" warning and blocks save.

- [ ] **Step 7: Commit**

```bash
git add App.tsx screens/MoneyScreen.tsx screens/SettingsScreen.tsx
git commit -m "$(cat <<'EOF'
feat: wire mileage tracking into Money tab and Settings

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Documentation

**Files:**
- Modify: `README.md` and/or `ARCHITECTURE.md` (per tradeready-docs-and-writing conventions)

**Interfaces:** none.

- [ ] **Step 1: Update docs**

Add mileage tracking to the feature list / architecture notes: a local-only `Trip` collection under the Money tab, odometer-based, IRS-rate deduction via `settings.mileageRate`, not synced to Supabase. Note the deliberate separation from `travelFeePerMile` and the `fuel` expense category, and the documented upgrade path to sync (add a `trips` table + `COLLECTION_TABLES` entry).

- [ ] **Step 2: Verify the gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: 0 errors, tests pass, 0 warnings.

- [ ] **Step 3: Commit**

```bash
git add README.md ARCHITECTURE.md
git commit -m "$(cat <<'EOF'
docs: document mileage tracking feature

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Preflight (run before Task 1)

Because the owner rule is **never commit on a red gate**, confirm the baseline is green before starting:

```bash
npm run typecheck && npm test && npm run lint
```

If this is **red** (e.g. the known post-TS-migration errors from tradeready-ts-migration-campaign), **STOP** and resolve the gate first (that is a separate campaign). Do not begin Task 1 on a red baseline — you would be unable to commit any task without violating the owner's non-negotiable.

---

## Self-Review

**Spec coverage:**
- Odometer start/end capture → Task 4 (form) + `computeTripMiles` (Task 2). ✓
- From-job → to-job legs (either end Home/Shop) → `Trip` shape (Task 1) + endpoint chips (Task 4). ✓
- Configurable rate + total in Money tab, no auto-post → `mileageRate` (Task 1), `mileageSummary` (Task 2), `MileageCard` (Task 5), Settings field (Task 6); expenses untouched. ✓
- Sub-screen under Money tab, no 8th tab → MoneyStack registration (Task 6). ✓
- Local-only like recurringJobs → `trips.ts` + sign-out purge, not in COLLECTION_TABLES (Task 3). ✓
- Tests matching the formula suite → `__tests__/mileageUtils.test.js` (Task 2). ✓
- Guardrails (no deps, TS, green gate) → Global Constraints + per-task gate steps. ✓

**Placeholder scan:** No TBD/TODO; all code steps contain full code. The only conditional is the `fontSize.xxl` note in Task 5, which gives an explicit fallback. ✓

**Type consistency:** `Trip` fields, `mileageSummary` signature, `MileageCard` props, `HOME_LABEL` / `DEFAULT_MILEAGE_RATE` names are identical across Tasks 1–6. `loadTrips` / `saveTrips` names consistent between Task 3 (def) and Tasks 4–5 (use). ✓
