# Sync/Offline Indicator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a floating sync/offline banner that shows online/offline status and pending sync queue count, with a "Sync Now" button for manual sync.

**Architecture:** A `useSyncStatus` hook polls network state and the AsyncStorage sync queue every 5 seconds. A `SyncStatusContext` wraps the app so any component can access sync status. A `SyncBanner` component renders as an animated overlay at the top of the screen, outside the navigation tree.

**Tech Stack:** React Native 0.81 / Expo 54 / React 19, expo-network, AsyncStorage, Animated API, TypeScript strict mode

## Global Constraints

- All `render()` and `renderHook()` calls must be `await`ed (RNTL v14 is async).
- Import `renderHook` and `act` from `@testing-library/react-native`, NOT from `@testing-library/react-hooks`.
- Tests use `jest.mock()` at module level; call `jest.clearAllMocks()` in `beforeEach`.
- Theme colors come from `useThemeContext()` which returns `{ colors, shadow, isDark }`. The `colors` object includes `danger`, `dangerBg`, `warning`, `warningBg`, `textPrimary`, `textMuted`, `surface`, `background`, `border`, `accent`.
- `useSafeAreaInsets()` from `react-native-safe-area-context` for status bar offset.
- Icons use `Ionicons` from `@expo/vector-icons`.
- `trySyncAwait()` from `utils/sync.ts` is the awaitable sync function.
- The sync queue key in AsyncStorage is `__syncQueue`; its value is a JSON array of `{ table, op, recordId, payload, ts }` objects.
- `expo-network` v8.0.8 — use `Network.getNetworkStateAsync()` which returns `{ isConnected, isInternetReachable, type }`.
- Context pattern follows `context/ThemeContext.tsx`: `createContext` with default, provider component, consumer hook.

---

### Task 1: Create `useSyncStatus` hook with tests

**Files:**
- Create: `tradeready/hooks/useSyncStatus.ts`
- Test: `tradeready/__tests__/useSyncStatus.test.ts`

**Interfaces:**
- Consumes: `trySyncAwait()` from `utils/sync.ts`, `Network.getNetworkStateAsync()` from `expo-network`, `AsyncStorage.getItem('__syncQueue')` from `@react-native-async-storage/async-storage`
- Produces: `useSyncStatus()` returning `SyncStatus { isOnline: boolean; pendingCount: number; syncing: boolean; syncNow: () => void }`

- [ ] **Step 1: Write the test file**

Create `tradeready/__tests__/useSyncStatus.test.ts`:

```ts
// RNTL v14 ships an async renderHook() — every test must await it.
import { renderHook, act } from '@testing-library/react-native';
import { useSyncStatus } from '../hooks/useSyncStatus';
import AsyncStorage from '@react-native-async-storage/async-storage';
import * as Network from 'expo-network';
import { trySyncAwait } from '../utils/sync';

jest.mock('expo-network', () => ({
  getNetworkStateAsync: jest.fn().mockResolvedValue({ isConnected: true, isInternetReachable: true }),
}));
jest.mock('../utils/sync', () => ({ trySyncAwait: jest.fn().mockResolvedValue(undefined) }));

beforeEach(() => {
  jest.clearAllMocks();
  jest.useFakeTimers();
  (AsyncStorage.getItem as jest.Mock).mockResolvedValue(null);
});

afterEach(() => {
  jest.useRealTimers();
});

describe('useSyncStatus', () => {
  it('initial state is online with zero pending', async () => {
    const { result } = await renderHook(() => useSyncStatus());
    expect(result.current.isOnline).toBe(true);
    expect(result.current.pendingCount).toBe(0);
    expect(result.current.syncing).toBe(false);
  });

  it('reports offline when getNetworkStateAsync says disconnected', async () => {
    (Network.getNetworkStateAsync as jest.Mock).mockResolvedValue({ isConnected: false });
    const { result } = await renderHook(() => useSyncStatus());

    await act(async () => { jest.advanceTimersByTime(100); });

    expect(result.current.isOnline).toBe(false);
  });

  it('reports correct pendingCount from parsed __syncQueue', async () => {
    const queue = [
      { table: 'jobs', op: 'upsert', recordId: '1', payload: {}, ts: '2026-01-01' },
      { table: 'invoices', op: 'upsert', recordId: '2', payload: {}, ts: '2026-01-01' },
    ];
    (AsyncStorage.getItem as jest.Mock).mockResolvedValue(JSON.stringify(queue));

    const { result } = await renderHook(() => useSyncStatus());

    await act(async () => { jest.advanceTimersByTime(100); });

    expect(result.current.pendingCount).toBe(2);
  });

  it('returns pendingCount 0 when queue is empty or missing', async () => {
    (AsyncStorage.getItem as jest.Mock).mockResolvedValue(null);
    const { result } = await renderHook(() => useSyncStatus());

    await act(async () => { jest.advanceTimersByTime(100); });

    expect(result.current.pendingCount).toBe(0);
  });

  it('syncNow calls trySyncAwait and re-polls queue after', async () => {
    const queue = [{ table: 'jobs', op: 'upsert', recordId: '1', payload: {}, ts: '2026-01-01' }];
    (AsyncStorage.getItem as jest.Mock).mockResolvedValue(JSON.stringify(queue));

    const { result } = await renderHook(() => useSyncStatus());
    await act(async () => { jest.advanceTimersByTime(100); });

    expect(result.current.pendingCount).toBe(1);

    (AsyncStorage.getItem as jest.Mock).mockResolvedValue('[]');

    await act(async () => { result.current.syncNow(); });

    expect(trySyncAwait).toHaveBeenCalled();
    expect(result.current.pendingCount).toBe(0);
  });

  it('syncing is true during sync and false after', async () => {
    let resolveSync!: () => void;
    (trySyncAwait as jest.Mock).mockImplementation(() => new Promise(r => { resolveSync = r; }));

    const { result } = await renderHook(() => useSyncStatus());

    act(() => { result.current.syncNow(); });

    expect(result.current.syncing).toBe(true);

    await act(async () => { resolveSync(); });

    expect(result.current.syncing).toBe(false);
  });

  it('syncing returns to false even if trySyncAwait throws', async () => {
    (trySyncAwait as jest.Mock).mockRejectedValueOnce(new Error('sync failed'));

    const { result } = await renderHook(() => useSyncStatus());

    await act(async () => { result.current.syncNow(); });

    expect(result.current.syncing).toBe(false);
  });

  it('clears interval on unmount', async () => {
    const clearSpy = jest.spyOn(global, 'clearInterval');
    const { unmount } = await renderHook(() => useSyncStatus());

    unmount();

    expect(clearSpy).toHaveBeenCalled();
    clearSpy.mockRestore();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx jest __tests__/useSyncStatus.test.ts --no-coverage`
Expected: FAIL — `Cannot find module '../hooks/useSyncStatus'`

- [ ] **Step 3: Write the hook implementation**

Create `tradeready/hooks/useSyncStatus.ts`:

```ts
import { useState, useEffect, useCallback, useRef } from 'react';
import * as Network from 'expo-network';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { trySyncAwait } from '../utils/sync';

const QUEUE_KEY = '__syncQueue';
const POLL_INTERVAL = 5000;

export interface SyncStatus {
  isOnline: boolean;
  pendingCount: number;
  syncing: boolean;
  syncNow: () => void;
}

async function poll(): Promise<{ isOnline: boolean; pendingCount: number }> {
  const [net, raw] = await Promise.all([
    Network.getNetworkStateAsync(),
    AsyncStorage.getItem(QUEUE_KEY),
  ]);
  const isOnline = net.isConnected ?? false;
  let pendingCount = 0;
  if (raw) {
    try { pendingCount = JSON.parse(raw).length; } catch {}
  }
  return { isOnline, pendingCount };
}

export function useSyncStatus(): SyncStatus {
  const [isOnline, setIsOnline] = useState(true);
  const [pendingCount, setPendingCount] = useState(0);
  const [syncing, setSyncing] = useState(false);
  const mountedRef = useRef(true);

  const runPoll = useCallback(async () => {
    try {
      const result = await poll();
      if (mountedRef.current) {
        setIsOnline(result.isOnline);
        setPendingCount(result.pendingCount);
      }
    } catch {}
  }, []);

  useEffect(() => {
    mountedRef.current = true;
    runPoll();
    const id = setInterval(runPoll, POLL_INTERVAL);
    return () => {
      mountedRef.current = false;
      clearInterval(id);
    };
  }, [runPoll]);

  const syncNow = useCallback(() => {
    if (syncing) return;
    setSyncing(true);
    (async () => {
      try {
        await trySyncAwait();
      } catch {}
      await runPoll();
    })().finally(() => {
      if (mountedRef.current) setSyncing(false);
    });
  }, [syncing, runPoll]);

  return { isOnline, pendingCount, syncing, syncNow };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx jest __tests__/useSyncStatus.test.ts --no-coverage`
Expected: PASS — all 8 tests green

- [ ] **Step 5: Commit**

```bash
git add hooks/useSyncStatus.ts __tests__/useSyncStatus.test.ts
git commit -m "feat: add useSyncStatus polling hook with tests"
```

---

### Task 2: Create `SyncStatusContext` provider

**Files:**
- Create: `tradeready/context/SyncStatusContext.tsx`

**Interfaces:**
- Consumes: `useSyncStatus()` from `hooks/useSyncStatus.ts` returning `SyncStatus`
- Produces: `SyncStatusProvider` component, `useSyncStatusContext()` hook returning `SyncStatus`

- [ ] **Step 1: Create the context file**

Create `tradeready/context/SyncStatusContext.tsx`:

```tsx
import React, { createContext, useContext } from 'react';
import { useSyncStatus, type SyncStatus } from '../hooks/useSyncStatus';

const defaultStatus: SyncStatus = {
  isOnline: true,
  pendingCount: 0,
  syncing: false,
  syncNow: () => {},
};

const SyncStatusContext = createContext<SyncStatus>(defaultStatus);

export function SyncStatusProvider({ children }: { children: React.ReactNode }) {
  const status = useSyncStatus();
  return (
    <SyncStatusContext.Provider value={status}>
      {children}
    </SyncStatusContext.Provider>
  );
}

export function useSyncStatusContext(): SyncStatus {
  return useContext(SyncStatusContext);
}
```

- [ ] **Step 2: Verify TypeScript compiles**

Run: `npx tsc --noEmit`
Expected: 0 errors

- [ ] **Step 3: Commit**

```bash
git add context/SyncStatusContext.tsx
git commit -m "feat: add SyncStatusContext provider"
```

---

### Task 3: Create `SyncBanner` animated component with tests

**Files:**
- Create: `tradeready/components/SyncBanner.tsx`
- Test: `tradeready/__tests__/SyncBanner.test.tsx`

**Interfaces:**
- Consumes: `useSyncStatusContext()` from `context/SyncStatusContext.tsx` returning `SyncStatus`, `useThemeContext()` from `context/ThemeContext.tsx` returning `{ colors }`, `useSafeAreaInsets()` from `react-native-safe-area-context`
- Produces: `<SyncBanner />` component (no props — reads from context)

- [ ] **Step 1: Write the test file**

Create `tradeready/__tests__/SyncBanner.test.tsx`:

```tsx
// RNTL v14 ships an async render() — every test must await it.
import React from 'react';
import { render, fireEvent } from '@testing-library/react-native';
import { SyncBanner } from '../components/SyncBanner';

const mockSyncNow = jest.fn();
let mockStatus = { isOnline: true, pendingCount: 0, syncing: false, syncNow: mockSyncNow };

jest.mock('../context/SyncStatusContext', () => ({
  useSyncStatusContext: () => mockStatus,
}));
jest.mock('../context/ThemeContext', () => ({
  useThemeContext: () => ({
    colors: {
      danger: '#ff3b30',
      dangerBg: '#fff1f0',
      warning: '#ff9500',
      warningBg: '#fff8ed',
      textPrimary: '#1c1c1e',
      surface: '#ffffff',
    },
  }),
}));
jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 44, bottom: 0, left: 0, right: 0 }),
}));

beforeEach(() => {
  jest.clearAllMocks();
  mockStatus = { isOnline: true, pendingCount: 0, syncing: false, syncNow: mockSyncNow };
});

describe('SyncBanner', () => {
  it('renders nothing when online with zero pending changes', async () => {
    const { queryByText } = await render(<SyncBanner />);
    expect(queryByText("You're offline")).toBeNull();
    expect(queryByText(/changes pending/)).toBeNull();
  });

  it('shows "You\'re offline" text when isOnline is false', async () => {
    mockStatus = { ...mockStatus, isOnline: false };
    const { getByText } = await render(<SyncBanner />);
    expect(getByText("You're offline")).toBeTruthy();
  });

  it('shows pending changes with Sync Now button when pendingCount > 0 and online', async () => {
    mockStatus = { ...mockStatus, pendingCount: 3 };
    const { getByText } = await render(<SyncBanner />);
    expect(getByText('3 changes pending')).toBeTruthy();
    expect(getByText('Sync Now')).toBeTruthy();
  });

  it('Sync Now button calls syncNow', async () => {
    mockStatus = { ...mockStatus, pendingCount: 2 };
    const { getByText } = await render(<SyncBanner />);
    fireEvent.press(getByText('Sync Now'));
    expect(mockSyncNow).toHaveBeenCalledTimes(1);
  });

  it('shows ActivityIndicator while syncing is true', async () => {
    mockStatus = { ...mockStatus, pendingCount: 1, syncing: true };
    const { getByTestId, queryByText } = await render(<SyncBanner />);
    expect(getByTestId('sync-spinner')).toBeTruthy();
    expect(queryByText('Sync Now')).toBeNull();
  });

  it('does not show Sync Now button when offline', async () => {
    mockStatus = { ...mockStatus, isOnline: false, pendingCount: 5 };
    const { queryByText, getByText } = await render(<SyncBanner />);
    expect(getByText("You're offline")).toBeTruthy();
    expect(queryByText('Sync Now')).toBeNull();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx jest __tests__/SyncBanner.test.tsx --no-coverage`
Expected: FAIL — `Cannot find module '../components/SyncBanner'`

- [ ] **Step 3: Write the SyncBanner component**

Create `tradeready/components/SyncBanner.tsx`:

```tsx
import React, { useEffect, useRef } from 'react';
import { Animated, View, Text, TouchableOpacity, ActivityIndicator, StyleSheet } from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useSyncStatusContext } from '../context/SyncStatusContext';
import { useThemeContext } from '../context/ThemeContext';

export function SyncBanner() {
  const { isOnline, pendingCount, syncing, syncNow } = useSyncStatusContext();
  const { colors } = useThemeContext();
  const insets = useSafeAreaInsets();

  const visible = !isOnline || pendingCount > 0;
  const translateY = useRef(new Animated.Value(-100)).current;

  useEffect(() => {
    Animated.timing(translateY, {
      toValue: visible ? 0 : -100,
      duration: 300,
      useNativeDriver: true,
    }).start();
  }, [visible, translateY]);

  const isOffline = !isOnline;
  const bgColor = isOffline ? colors.dangerBg : colors.warningBg;
  const accentColor = isOffline ? colors.danger : colors.warning;

  const icon = isOffline ? 'cloud-offline-outline' : 'cloud-upload-outline';
  const message = isOffline ? "You're offline" : `${pendingCount} change${pendingCount === 1 ? '' : 's'} pending`;

  return (
    <Animated.View
      style={[
        styles.container,
        {
          transform: [{ translateY }],
          paddingTop: insets.top + 4,
          backgroundColor: bgColor,
          borderBottomColor: accentColor,
        },
      ]}
      pointerEvents={visible ? 'auto' : 'none'}
    >
      <View style={styles.content}>
        <Ionicons name={icon as any} size={18} color={accentColor} />
        <Text style={[styles.text, { color: colors.textPrimary }]}>{message}</Text>
        {isOnline && pendingCount > 0 && (
          syncing ? (
            <ActivityIndicator size="small" color={accentColor} testID="sync-spinner" />
          ) : (
            <TouchableOpacity onPress={syncNow} style={[styles.button, { backgroundColor: accentColor }]}>
              <Text style={styles.buttonText}>Sync Now</Text>
            </TouchableOpacity>
          )
        )}
      </View>
    </Animated.View>
  );
}

const styles = StyleSheet.create({
  container: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    borderBottomWidth: 1,
    zIndex: 999,
  },
  content: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 16,
    paddingBottom: 8,
    gap: 8,
  },
  text: {
    fontSize: 14,
    fontWeight: '600',
  },
  button: {
    borderRadius: 12,
    paddingHorizontal: 12,
    paddingVertical: 4,
  },
  buttonText: {
    color: '#fff',
    fontSize: 13,
    fontWeight: '700',
  },
});
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx jest __tests__/SyncBanner.test.tsx --no-coverage`
Expected: PASS — all 6 tests green

- [ ] **Step 5: Commit**

```bash
git add components/SyncBanner.tsx __tests__/SyncBanner.test.tsx
git commit -m "feat: add SyncBanner animated component with tests"
```

---

### Task 4: App.tsx integration + SettingsScreen cleanup

**Files:**
- Modify: `tradeready/App.tsx:404-417` (AppRoot function — wrap with SyncStatusProvider, add SyncBanner)
- Modify: `tradeready/screens/SettingsScreen.tsx:1-23` (imports) and `tradeready/screens/SettingsScreen.tsx:459-477` (sign-out handler)

**Interfaces:**
- Consumes: `SyncStatusProvider` and `useSyncStatusContext()` from `context/SyncStatusContext.tsx`, `SyncBanner` from `components/SyncBanner.tsx`
- Produces: No new interfaces — integration only

- [ ] **Step 1: Update App.tsx — add imports**

Add these imports to the top of `tradeready/App.tsx` (after the existing `ThemeProvider` import on line 10):

```ts
import { SyncStatusProvider } from "./context/SyncStatusContext";
import { SyncBanner } from "./components/SyncBanner";
```

- [ ] **Step 2: Update App.tsx — wrap AppRoot with SyncStatusProvider + SyncBanner**

In the `AppRoot` function (line 404), change the `content` variable from:

```tsx
const content = (
    <SafeAreaProvider>
      <ErrorBoundary>
        <ThemeProvider>
          <AuthProvider>
            <SubscriptionProvider>
              <RootNavigator />
            </SubscriptionProvider>
          </AuthProvider>
        </ThemeProvider>
      </ErrorBoundary>
    </SafeAreaProvider>
  );
```

to:

```tsx
const content = (
    <SafeAreaProvider>
      <ErrorBoundary>
        <ThemeProvider>
          <SyncStatusProvider>
            <AuthProvider>
              <SubscriptionProvider>
                <RootNavigator />
              </SubscriptionProvider>
            </AuthProvider>
            <SyncBanner />
          </SyncStatusProvider>
        </ThemeProvider>
      </ErrorBoundary>
    </SafeAreaProvider>
  );
```

The `SyncStatusProvider` wraps `AuthProvider` + `SubscriptionProvider` + `RootNavigator`, and `SyncBanner` is a sibling of the navigation tree so it overlays all screens. Both sit inside `ThemeProvider` so they can access theme colors.

- [ ] **Step 3: Update SettingsScreen.tsx — add import**

Add the import at the top of `tradeready/screens/SettingsScreen.tsx`:

```ts
import { useSyncStatusContext } from '../context/SyncStatusContext';
```

- [ ] **Step 4: Update SettingsScreen.tsx — use context in sign-out handler**

In the SettingsScreen component function body, add this line (near the other hooks at the top of the component):

```ts
const { pendingCount } = useSyncStatusContext();
```

Then replace the sign-out `onPress` handler (lines 461-476) from:

```ts
onPress={async () => {
  const raw = await AsyncStorage.getItem("__syncQueue");
  const queue = raw ? JSON.parse(raw) : [];
  const doSignOut = async () => { resetUser(); await clearAllUserData(); await supabase.auth.signOut(); };
  if (queue.length > 0) {
    Alert.alert("Unsynced changes", "You have changes that haven't been saved to the cloud yet. Sync now to keep them.", [
      { text: "Cancel", style: "cancel" },
      { text: "Sync & sign out", onPress: async () => { const { data: { session } } = await supabase.auth.getSession(); if (session?.user?.id) await syncIfOnline(session.user.id); await doSignOut(); } },
      { text: "Sign out anyway", style: "destructive", onPress: doSignOut },
    ]);
  } else {
    Alert.alert("Sign out", "Are you sure you want to sign out?", [
      { text: "Cancel", style: "cancel" },
      { text: "Sign out", style: "destructive", onPress: doSignOut },
    ]);
  }
}}
```

with:

```ts
onPress={() => {
  const doSignOut = async () => { resetUser(); await clearAllUserData(); await supabase.auth.signOut(); };
  if (pendingCount > 0) {
    Alert.alert("Unsynced changes", "You have changes that haven't been saved to the cloud yet. Sync now to keep them.", [
      { text: "Cancel", style: "cancel" },
      { text: "Sync & sign out", onPress: async () => { const { data: { session } } = await supabase.auth.getSession(); if (session?.user?.id) await syncIfOnline(session.user.id); await doSignOut(); } },
      { text: "Sign out anyway", style: "destructive", onPress: doSignOut },
    ]);
  } else {
    Alert.alert("Sign out", "Are you sure you want to sign out?", [
      { text: "Cancel", style: "cancel" },
      { text: "Sign out", style: "destructive", onPress: doSignOut },
    ]);
  }
}}
```

Note: The handler changes from `async` to synchronous since we no longer need to `await AsyncStorage.getItem`. The `syncIfOnline` import is still needed for the "Sync & sign out" option. The `AsyncStorage` import may still be needed for other uses in the file — do not remove it without checking.

- [ ] **Step 5: Verify TypeScript compiles**

Run: `npx tsc --noEmit`
Expected: 0 errors

- [ ] **Step 6: Commit**

```bash
git add App.tsx screens/SettingsScreen.tsx
git commit -m "feat: integrate SyncStatusProvider and SyncBanner into App.tsx, clean up SettingsScreen sign-out"
```

---

### Task 5: Final verification

**Files:** None (verification only)

**Interfaces:** N/A

- [ ] **Step 1: Run the full test suite**

Run: `npx jest --no-coverage`
Expected: All tests pass (369 existing + 14 new = 383 tests)

- [ ] **Step 2: Run TypeScript type check**

Run: `npx tsc --noEmit`
Expected: 0 errors

- [ ] **Step 3: Run ESLint**

Run: `npx eslint . --ext .ts,.tsx,.js,.jsx`
Expected: 0 errors, 0 warnings

- [ ] **Step 4: Record final gate status**

Record in progress ledger: test count, type errors, lint status.
